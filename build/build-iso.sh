#!/bin/bash
# build-iso.sh — repack Ubuntu Server live-arm64 ISO with our customizations.
#
# Pivoted 2026-05-03 from Debian d-i (preseed) to Ubuntu Server (subiquity
# autoinstall via cloud-init). Reasons:
#   - Debian d-i + 7.0.1 kernel = panic in 60s on trixie userspace
#   - Ubuntu 25.04+ has Mesa 24.x with Mali-G720 panthor support
#   - Sky1-Linux issue #12 confirms Ubuntu 26.04 works on MS-R1
#   - subiquity is text-mode + autoinstall via YAML user-data
#
# DUAL-KERNEL still ships:
#   - 6.18.26 LTS (linux-cix-sky1)
#   - 7.0.1-next (linux-cix-sky1-next, explicit test entry)
#
# Process:
#   1. Extract Ubuntu Server live ISO (has /casper/ squashfs + /boot/grub/)
#   2. Replace /casper/vmlinuz with our Sky1 LTS kernel + inject modules cpio
#      onto /casper/initrd (LIVE session runs our kernel, not Ubuntu stock)
#   3. Stage /cixmini/ on ISO with all post-install assets
#   4. Stage /cloud-init/ with user-data (autoinstall) + meta-data
#   5. Replace /boot/grub/grub.cfg with our menu (LTS default, NEXT test,
#      SAFE rescue) — kernel cmdline includes `autoinstall ds=nocloud-net...`
#   6. Repack as UEFI-bootable hybrid ISO via xorriso

set -euo pipefail

UPSTREAM=""
ROOT=""
VERSION=""
OUTPUT=""

while [ $# -gt 0 ]; do
    case "$1" in
        --upstream) UPSTREAM="$2"; shift 2 ;;
        --root)     ROOT="$2"; shift 2 ;;
        --version)  VERSION="$2"; shift 2 ;;
        --output)   OUTPUT="$2"; shift 2 ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

[ -f "$UPSTREAM" ] || { echo "ERROR: --upstream not a file"; exit 1; }
[ -d "$ROOT" ]     || { echo "ERROR: --root not a dir"; exit 1; }
[ -n "$VERSION" ]  || { echo "ERROR: --version required"; exit 1; }
[ -n "$OUTPUT" ]   || { echo "ERROR: --output required"; exit 1; }

STAGING="$ROOT/build/iso-staging"
EXTRA="$STAGING/cixmini"
CLOUDINIT="$STAGING/cloud-init"

# Tools
for t in xorriso 7z cpio gzip find depmod dd; do
    command -v "$t" >/dev/null 2>&1 || { echo "ERROR: missing tool: $t"; exit 1; }
done

# Build identification — used in GRUB banner + cixmini sidecars + autoinstall.
BUILD_DATE=$(date -u +"%Y-%m-%d %H:%M:%S UTC")
BUILD_HOST=$(hostname -s 2>/dev/null || echo unknown)

pad_initramfs_for_concat() {
    # Linux accepts multiple initramfs members, but an uncompressed newc member
    # must end cleanly before the next compressed member starts. Ubuntu's
    # /casper/initrd is an uncompressed cpio, so make the boundary explicit.
    local initrd="$1"
    local size pad

    size=$(wc -c < "$initrd" | tr -d ' ')
    pad=$(( (512 - (size % 512)) % 512 ))
    if [ "$pad" -gt 0 ]; then
        dd if=/dev/zero bs=1 count="$pad" >> "$initrd" 2>/dev/null
        echo "    padded $(basename "$initrd") with $pad NUL bytes before appended archive"
    else
        echo "    $(basename "$initrd") already ends on a 512-byte cpio boundary"
    fi
}

module_or_builtin_exists() {
    local modules_dir="$1"
    local mod="$2"
    local mod_us="${mod//-/_}"

    if find "$modules_dir" -type f \( \
        -name "$mod.ko" -o -name "$mod.ko.*" -o \
        -name "$mod_us.ko" -o -name "$mod_us.ko.*" \
    \) -print -quit | grep -q .; then
        return 0
    fi

    if [ -f "$modules_dir/modules.builtin" ] && \
       grep -Eq "(^|/)($mod|$mod_us)\\.ko(\\.|$)" "$modules_dir/modules.builtin"; then
        return 0
    fi

    return 1
}

check_casper_kernel_support() {
    local modules_dir="$1"
    local kver="$2"
    local missing=""
    local mod

    for mod in loop squashfs overlay; do
        if module_or_builtin_exists "$modules_dir" "$mod"; then
            echo "      casper dependency $mod: present"
        else
            missing="$missing $mod"
        fi
    done

    if [ -n "$missing" ]; then
        echo "ERROR: kernel $kver lacks required casper support:$missing"
        echo "       These must be built-in or present under lib/modules/$kver."
        exit 1
    fi
}

write_cixmini_live_initramfs_hooks() {
    local work="$1"
    local hook

    mkdir -p "$work/scripts/init-top" "$work/scripts/init-premount" "$work/etc/modprobe.d"

    # Keep the known bad Type-C controller out of the initramfs coldplug path
    # even if a future GRUB edit drops module_blacklist=.
    cat > "$work/etc/modprobe.d/cixmini-live-blacklist.conf" <<'EOF'
blacklist typec_rts5453
blacklist rts5453
EOF

    hook="$work/scripts/init-top/cixmini-live-early"
    cat > "$hook" <<'EOF'
#!/bin/sh
PREREQ=""

prereqs() {
    echo "$PREREQ"
}

case "$1" in
    prereqs)
        prereqs
        exit 0
        ;;
esac

PATH=/sbin:/bin:/usr/sbin:/usr/bin

log_kmsg() {
    [ -c /dev/kmsg ] && printf '%s\n' "$*" > /dev/kmsg 2>/dev/null || true
}

load_one() {
    modprobe -q "$1" 2>/dev/null || true
}

log_kmsg "cixmini-live: loading early casper/display modules"

# Casper needs these before it can mount the ISO squashfs root if they are not
# built into the kernel.
for mod in loop squashfs overlay; do
    load_one "$mod"
done

# Sky1 display stack. Include both historical and kbuild names because the
# upstream tree and module aliases have used both spellings.
# Panthor is left for the live root; it is not needed for fbcon and may need
# firmware that is not in the initramfs.
for mod in drm drm_kms_helper cix_display linlondp linlon-dp trilin_dpsub trilin-dpsub trilin_dp_cix; do
    load_one "$mod"
done

dmesg -n 8 2>/dev/null || true
log_kmsg "cixmini-live: early module load complete"
exit 0
EOF
    chmod 0755 "$hook"
    cp "$hook" "$work/scripts/init-premount/cixmini-live-early"
}

build_live_overlay_cpio() {
    local label="$1"
    local kver="$2"
    local modules_tgz="$3"
    local out_gz="$4"
    local work="$STAGING/.${label}-live-overlay"
    local modules_dir="$work/lib/modules/$kver"
    local modcount

    rm -rf "$work"
    mkdir -p "$work"

    tar xzf "$modules_tgz" -C "$work"
    [ -d "$modules_dir" ] || { echo "ERROR: $label modules tarball didn't extract to lib/modules/$kver"; exit 1; }

    depmod -a -b "$work" "$kver"
    [ -f "$modules_dir/modules.dep" ] || { echo "ERROR: depmod did not create modules.dep for $kver"; exit 1; }
    [ -f "$modules_dir/modules.alias" ] || { echo "ERROR: depmod did not create modules.alias for $kver"; exit 1; }

    modcount=$(find "$modules_dir" -type f \( -name '*.ko' -o -name '*.ko.*' \) | wc -l | tr -d ' ')
    if [ "$modcount" -lt 50 ]; then
        echo "ERROR: suspiciously small module set for $kver ($modcount modules)"
        exit 1
    fi
    echo "    $label modules: $modcount .ko files under lib/modules/$kver"

    check_casper_kernel_support "$modules_dir" "$kver"
    write_cixmini_live_initramfs_hooks "$work"

    ( cd "$work" && find lib scripts etc -print | cpio -o -H newc --quiet | gzip -9 -n ) > "$out_gz"
    gzip -t "$out_gz"
    echo "    $label live overlay cpio: $(du -h "$out_gz" | cut -f1)"

    rm -rf "$work"
}

append_live_overlay_to_initrd() {
    local initrd="$1"
    local overlay_gz="$2"

    pad_initramfs_for_concat "$initrd"
    cat "$overlay_gz" >> "$initrd"
    echo "    appended $(basename "$overlay_gz") to $(basename "$initrd") ($(du -h "$initrd" | cut -f1))"
}

# Detect KVERs from assemble-kernel-assets.sh sidecars.
# RULE: dual kernel required, no LTS-only fallback.
KVER_LTS=""
KVER_NEXT=""
for label in lts next; do
    KVER_FILE="$ROOT/assets/kernel/$label/KVER"
    IMG_FILE="$ROOT/assets/kernel/$label/Image-cixmini.bin"
    MOD_FILE="$ROOT/assets/kernel/$label/modules-cixmini.tgz"
    missing=""
    [ -f "$KVER_FILE" ] || missing="$missing KVER"
    [ -f "$IMG_FILE" ] || missing="$missing Image-cixmini.bin"
    [ -f "$MOD_FILE" ] || missing="$missing modules-cixmini.tgz"
    if [ -n "$missing" ]; then
        echo "ERROR: dual-kernel RULE violation — assets/kernel/$label/ missing:$missing"
        exit 1
    fi
done
KVER_LTS=$(cat "$ROOT/assets/kernel/lts/KVER")
KVER_NEXT=$(cat "$ROOT/assets/kernel/next/KVER")
echo "[info] LTS kernel KVER:  $KVER_LTS"
echo "[info] NEXT kernel KVER: $KVER_NEXT (explicit test entry)"

# ----------------------------------------------------------------------
# Step 1 — fresh staging dir
# ----------------------------------------------------------------------
echo "[1] preparing staging at $STAGING"
rm -rf "$STAGING"
mkdir -p "$STAGING"

# ----------------------------------------------------------------------
# Step 2 — extract upstream Ubuntu Server ISO
# ----------------------------------------------------------------------
echo "[2] extracting upstream Ubuntu Server ISO via 7z"
7z x -y -o"$STAGING" "$UPSTREAM" >/dev/null

# Verify Ubuntu Server layout
[ -d "$STAGING/casper" ] || { echo "ERROR: no /casper/ — not an Ubuntu Server live ISO?"; exit 1; }
[ -f "$STAGING/casper/vmlinuz" ] || { echo "ERROR: no /casper/vmlinuz"; exit 1; }
[ -f "$STAGING/casper/initrd" ] || { echo "ERROR: no /casper/initrd"; exit 1; }

# ----------------------------------------------------------------------
# Step 3 — stage cloud-init autoinstall config + d-i banner script
# ----------------------------------------------------------------------
echo "[3] staging cloud-init autoinstall config"
mkdir -p "$CLOUDINIT"
cp "$ROOT/autoinstall/user-data" "$CLOUDINIT/user-data"
cp "$ROOT/autoinstall/meta-data" "$CLOUDINIT/meta-data"
echo "    user-data + meta-data → /cloud-init/"

# ----------------------------------------------------------------------
# Step 3.5 — swap /casper/vmlinuz to our Sky1 LTS kernel + inject modules
#
# Ubuntu's stock arm64 kernel won't drive Sky1 SoC (no panthor, no
# linlondp, no trilin_dp_cix, no rts5453 blacklist, no MartJohnson
# cmdline workarounds). Replace it with our linux-cix-sky1 LTS kernel
# so the LIVE session (where subiquity runs) is on our kernel from
# the start.
# ----------------------------------------------------------------------
echo "[3.5] swapping /casper kernel to linux-cix-sky1 LTS ($KVER_LTS)"

# Save the upstream initrd as base for the BETA initrd path
cp "$STAGING/casper/initrd" "$STAGING/casper/initrd-base"

# Replace vmlinuz with our LTS Image
install -m 0644 "$ROOT/assets/kernel/lts/Image-cixmini.bin" "$STAGING/casper/vmlinuz"
echo "    replaced /casper/vmlinuz ($(du -h "$STAGING/casper/vmlinuz" | cut -f1))"

# Inject a Sky1 live overlay cpio onto initrd.  The overlay contains:
#   - lib/modules/$KVER_LTS with fresh depmod indexes
#   - initramfs-tools init-top/init-premount hooks that load casper's
#     loop/squashfs/overlay dependencies plus the Sky1 display stack before
#     casper/subiquity can redirect or hide the visible VT.
MOD_GZ="$STAGING/.lts-live-overlay.cpio.gz"
build_live_overlay_cpio "LTS" "$KVER_LTS" "$ROOT/assets/kernel/lts/modules-cixmini.tgz" "$MOD_GZ"
append_live_overlay_to_initrd "$STAGING/casper/initrd" "$MOD_GZ"
rm -f "$MOD_GZ"

# ----------------------------------------------------------------------
# Step 3.6 — build NEXT (7.0.1) live path (initrd-next + vmlinuz-next)
# ----------------------------------------------------------------------
echo "[3.6] building NEXT live path: linux-cix-sky1-next ($KVER_NEXT)"

install -m 0644 "$ROOT/assets/kernel/next/Image-cixmini.bin" "$STAGING/casper/vmlinuz-next"

# Start NEXT initrd from the upstream base copy + append NEXT modules
mv "$STAGING/casper/initrd-base" "$STAGING/casper/initrd-next"
NEXT_MOD_GZ="$STAGING/.next-live-overlay.cpio.gz"
build_live_overlay_cpio "NEXT" "$KVER_NEXT" "$ROOT/assets/kernel/next/modules-cixmini.tgz" "$NEXT_MOD_GZ"
append_live_overlay_to_initrd "$STAGING/casper/initrd-next" "$NEXT_MOD_GZ"
rm -f "$NEXT_MOD_GZ"
echo "    /casper/initrd-next: $(du -h "$STAGING/casper/initrd-next" | cut -f1)"

# ----------------------------------------------------------------------
# Step 4 — stage /cixmini extras on the ISO
# ----------------------------------------------------------------------
echo "[4] staging /cixmini extras"
mkdir -p "$EXTRA/post-install" "$EXTRA/assets"
cp -r "$ROOT/post-install/"*.sh "$EXTRA/post-install/"
chmod 755 "$EXTRA/post-install/"*.sh

echo "$VERSION"     > "$EXTRA/BUILD_VERSION"
echo "$BUILD_DATE"  > "$EXTRA/BUILD_DATE"
echo "$BUILD_HOST"  > "$EXTRA/BUILD_HOST"
echo "$KVER_LTS"    > "$EXTRA/KVER_LTS"
echo "$KVER_NEXT"   > "$EXTRA/KVER_NEXT"
echo "    build id: $VERSION  ($BUILD_DATE on $BUILD_HOST)"

# Stage agent stack + branding + cix-debs (existing)
[ -d "$ROOT/assets/agent-stack" ] && cp -rL "$ROOT/assets/agent-stack" "$EXTRA/assets/"
if [ -d "$ROOT/assets/branding" ]; then
    mkdir -p "$EXTRA/assets/branding"
    for sub in logo plymouth gdm wallpaper; do
        if [ -d "$ROOT/assets/branding/$sub" ]; then
            cp -rL "$ROOT/assets/branding/$sub" "$EXTRA/assets/branding/"
        fi
    done
    [ -f "$ROOT/assets/branding/README.md" ] && cp "$ROOT/assets/branding/README.md" "$EXTRA/assets/branding/" || true
fi
if [ -d "$ROOT/assets/cix-debs" ] && [ "$(ls -A $ROOT/assets/cix-debs 2>/dev/null)" ]; then
    cp -rL "$ROOT/assets/cix-debs" "$EXTRA/assets/"
fi

# Stage BOTH kernel sets — post-install reads from /cixmini/assets/kernel/{lts,next}/
if [ -d "$ROOT/assets/kernel" ] && [ "$(ls -A $ROOT/assets/kernel 2>/dev/null)" ]; then
    cp -rL "$ROOT/assets/kernel" "$EXTRA/assets/"
    echo "    kernel: $(du -sh $EXTRA/assets/kernel | cut -f1)"
fi

# Sky1 firmware
if [ -d "$ROOT/assets/sky1-firmware" ] && [ "$(ls -A $ROOT/assets/sky1-firmware 2>/dev/null)" ]; then
    cp -rL "$ROOT/assets/sky1-firmware" "$EXTRA/assets/"
    echo "    sky1-firmware: $(du -sh $EXTRA/assets/sky1-firmware | cut -f1)"
fi

# ----------------------------------------------------------------------
# Step 5 — build a fresh 600MB FAT16 ESP with rEFInd + kernels embedded
# ----------------------------------------------------------------------
# r22 with systemd-boot: SAFE entry dropped to busybox (kernel + initrd +
# framebuffer all working!) but install entries still appeared black.
# DIAGNOSIS: the cmdline in r17-r22 has been MISSING `boot=casper` —
# without it, Ubuntu's casper init scripts never run; default initramfs-
# tools init panics or drops to emergency shell because root= is unset.
#
# r23 fix: switch back to rEFInd (user preference — more resilient on
# Sky1 UEFI per their testing) AND add `boot=casper` to all install +
# SAFE entries. Casper init then activates properly, finds the live
# media (squashfs on the ISO9660 partition via Linux iso9660 module),
# and either auto-installs or boots a live session.
echo "[5] building fresh 600MB FAT16 ESP with rEFInd + kernels embedded"

REFIND_BIN="$ROOT/build/refind-bin/refind_aa64.efi"
REFIND_ISO9660="$ROOT/build/refind-bin/iso9660_aa64.efi"
[ -f "$REFIND_BIN" ]     || { echo "ERROR: missing $REFIND_BIN"; exit 1; }
[ -f "$REFIND_ISO9660" ] || { echo "ERROR: missing $REFIND_ISO9660"; exit 1; }

ESP_IMG="$STAGING/[BOOT]/Boot-NoEmul.img"
[ -f "$ESP_IMG" ] || { echo "ERROR: no Boot-NoEmul.img in upstream ISO"; exit 1; }

# Source kernel + initrd files (already placed by Step 3.5 / 3.6).
LTS_VMLINUZ="$STAGING/casper/vmlinuz"
LTS_INITRD="$STAGING/casper/initrd"
NEXT_VMLINUZ="$STAGING/casper/vmlinuz-next"
NEXT_INITRD="$STAGING/casper/initrd-next"
for f in "$LTS_VMLINUZ" "$LTS_INITRD" "$NEXT_VMLINUZ" "$NEXT_INITRD"; do
    [ -f "$f" ] || { echo "ERROR: missing kernel/initrd source: $f"; exit 1; }
done

# r22: cmdline matches the running r6 install's /proc/cmdline VERBATIM
# (extracted by SSH to cixmini.local 2026-05-03). Includes splash+quiet,
# module_blacklist, and r6's MartJohnson Sky1 trio. The `splash quiet`
# pair does NOT hide kernel earlyprintk — kernel earlyprintk is just
# never visible on this hardware's framebuffer regardless. Plymouth is
# what makes the screen show anything during boot.
MARTJOHNSON_R6="loglevel=4 console=tty0 console=ttyAMA2,115200 efi=noruntime acpi=force arm-smmu-v3.disable_bypass=0 audit_backlog_limit=8192 clk_ignore_unused keep_bootcon panic=30 module_blacklist=typec_rts5453,rts5453 splash quiet"

# r18-equivalent extras — opt-in profiles to retest nomodeset / blacklist.
TEST_E_FIX="nomodeset modprobe.blacklist=typec_rts5453,rts5453"

# CRITICAL: boot=casper tells Ubuntu's casper initrd to actually run its
# live-boot scripts. Without it, default initramfs-tools panics with no
# root= — what dropped r22's SAFE entry to busybox. Required on EVERY
# entry that uses casper's initrd.
#
# r24 additions:
#   - live-media-path=/casper        — explicit hint where squashfs lives
#   - rootdelay=10                   — wait 10s for USB block dev to enum
#                                      before casper starts scanning
CASPER_BOOT="boot=casper live-media-path=/casper rootdelay=10"

# Subiquity autoinstall datasource. Semicolon doesn't need escaping inside
# rEFInd's quoted options string.
SUBIQUITY_OPTS='autoinstall ds=nocloud;s=/cdrom/cloud-init/'

# ---- write refind.conf — kernels are on ESP, paths are root-relative ----
REFIND_CONF=/tmp/refind-r23.conf
cat > "$REFIND_CONF" <<REFINDCONF
# rEFInd configuration for nclawzero installer (cixmini r23)
# Build: $VERSION  ($BUILD_DATE)  Host: $BUILD_HOST
# Kernels: LTS=$KVER_LTS  NEXT=$KVER_NEXT
# CRITICAL: every install + SAFE entry includes 'boot=casper' so Ubuntu's
# casper initrd actually runs (without it, init panics -> busybox).
timeout 10
log_level 4
showtools none
fold_linux_kernels false
scan_all_linux_kernels false

default_selection 1

menuentry "Install nclawzero LTS 6.18.26 (DEFAULT)" {
    loader  /vmlinuz
    initrd  /initrd
    options "$CASPER_BOOT $SUBIQUITY_OPTS $MARTJOHNSON_R6"
}

menuentry "Install nclawzero NEXT 7.0.1" {
    loader  /vmlinuz-next
    initrd  /initrd-next
    options "$CASPER_BOOT $SUBIQUITY_OPTS $MARTJOHNSON_R6"
}

menuentry "Install LTS + nomodeset + modprobe.blacklist" {
    loader  /vmlinuz
    initrd  /initrd
    options "$CASPER_BOOT $SUBIQUITY_OPTS $MARTJOHNSON_R6 $TEST_E_FIX"
}

menuentry "Install NEXT + nomodeset + modprobe.blacklist" {
    loader  /vmlinuz-next
    initrd  /initrd-next
    options "$CASPER_BOOT $SUBIQUITY_OPTS $MARTJOHNSON_R6 $TEST_E_FIX"
}

menuentry "SAFE — live session LTS (no install)" {
    loader  /vmlinuz
    initrd  /initrd
    options "$CASPER_BOOT $MARTJOHNSON_R6"
}

menuentry "SAFE — live session NEXT (no install)" {
    loader  /vmlinuz-next
    initrd  /initrd-next
    options "$CASPER_BOOT $MARTJOHNSON_R6"
}

# DIAG busybox-drop: kernel + casper initrd, NO boot=casper. Default
# initramfs-tools init has graceful no-root fallback that drops to a
# busybox shell rather than panicking. Use this to inspect /dev/sd*,
# the ISO9660 partition contents, /proc/cmdline, etc. — so we can see
# WHAT casper would have failed on.
menuentry "DIAG — drop to busybox (LTS, inspect why casper fails)" {
    loader  /vmlinuz
    initrd  /initrd
    options "$MARTJOHNSON_R6"
}

menuentry "DIAG — drop to busybox (NEXT, inspect why casper fails)" {
    loader  /vmlinuz-next
    initrd  /initrd-next
    options "$MARTJOHNSON_R6"
}
REFINDCONF
echo "    refind.conf written ($(wc -l < "$REFIND_CONF") lines)"

# ---- build a fresh 600MB FAT16 ESP from scratch ----
echo "    creating fresh 600MB FAT16 ESP image"
NEW_ESP_IMG="$STAGING/[BOOT]/Boot-NoEmul-r23.img"
rm -f "$NEW_ESP_IMG"

dd if=/dev/zero of="$NEW_ESP_IMG" bs=1M count=600 status=none
mkfs.vfat -F 16 -n "ESP" "$NEW_ESP_IMG" >/dev/null

# Layout on the new ESP:
#   /EFI/BOOT/BOOTAA64.EFI       — rEFInd (UEFI auto-load path)
#   /EFI/BOOT/refind.conf        — rEFInd config / our menu
#   /EFI/BOOT/drivers_aa64/      — rEFInd filesystem drivers
#   /vmlinuz                     — LTS kernel
#   /initrd                      — LTS initrd (with our overlay cpio)
#   /vmlinuz-next                — NEXT kernel
#   /initrd-next                 — NEXT initrd

MTOOLS_SKIP_CHECK=1 mmd   -i "$NEW_ESP_IMG" '::/EFI'
MTOOLS_SKIP_CHECK=1 mmd   -i "$NEW_ESP_IMG" '::/EFI/BOOT'
MTOOLS_SKIP_CHECK=1 mmd   -i "$NEW_ESP_IMG" '::/EFI/BOOT/drivers_aa64'

MTOOLS_SKIP_CHECK=1 mcopy -i "$NEW_ESP_IMG" "$REFIND_BIN"      '::/EFI/BOOT/BOOTAA64.EFI'
MTOOLS_SKIP_CHECK=1 mcopy -i "$NEW_ESP_IMG" "$REFIND_CONF"     '::/EFI/BOOT/refind.conf'
MTOOLS_SKIP_CHECK=1 mcopy -i "$NEW_ESP_IMG" "$REFIND_ISO9660"  '::/EFI/BOOT/drivers_aa64/iso9660_aa64.efi'

# Embed kernels + initrds at ESP root (paths match loader entries)
echo "    embedding kernels + initrds onto ESP"
MTOOLS_SKIP_CHECK=1 mcopy -i "$NEW_ESP_IMG" "$LTS_VMLINUZ"   '::/vmlinuz'
MTOOLS_SKIP_CHECK=1 mcopy -i "$NEW_ESP_IMG" "$LTS_INITRD"    '::/initrd'
MTOOLS_SKIP_CHECK=1 mcopy -i "$NEW_ESP_IMG" "$NEXT_VMLINUZ"  '::/vmlinuz-next'
MTOOLS_SKIP_CHECK=1 mcopy -i "$NEW_ESP_IMG" "$NEXT_INITRD"   '::/initrd-next'

echo "    new ESP layout:"
MTOOLS_SKIP_CHECK=1 mdir -i "$NEW_ESP_IMG" -/ 2>/dev/null | sed 's/^/      /' | head -60

# Replace upstream Boot-NoEmul.img with our new 600 MB ESP
mv "$NEW_ESP_IMG" "$ESP_IMG"
echo "    replaced $ESP_IMG ($(du -h "$ESP_IMG" | cut -f1))"

# Sanity: verify the swap landed
ESP_BOOTAA64_SIZE=$(MTOOLS_SKIP_CHECK=1 mdir -i "$ESP_IMG" '::/EFI/BOOT/BOOTAA64.EFI' 2>/dev/null | awk 'tolower($1)=="bootaa64" && tolower($2)=="efi"{print $3}' | tr -d ' ')
echo "    /EFI/BOOT/BOOTAA64.EFI (rEFInd) = $ESP_BOOTAA64_SIZE bytes"
case "$ESP_BOOTAA64_SIZE" in
    ''|*[!0-9]*) echo "ERROR: could not parse BOOTAA64.EFI size: '$ESP_BOOTAA64_SIZE'"; exit 1 ;;
esac
[ "$ESP_BOOTAA64_SIZE" -gt 100000 ] || { echo "ERROR: BOOTAA64.EFI too small ($ESP_BOOTAA64_SIZE bytes)"; exit 1; }

# Nuke upstream GRUB tree so nothing tries to auto-discover stale config.
rm -rf "$STAGING/boot/grub"
echo "    cleared $STAGING/boot/grub (no fallback GRUB cfg)"


# ----------------------------------------------------------------------
# Step 6 — rebuild md5sum.txt
# ----------------------------------------------------------------------
echo "[6] regenerating md5sum.txt"
( cd "$STAGING" && find . -type f \! -name md5sum.txt -print0 | xargs -0 md5sum > md5sum.txt )

# ----------------------------------------------------------------------
# Step 7 — repack as UEFI-bootable hybrid ISO via xorriso
# ----------------------------------------------------------------------
echo "[7] repacking via xorriso → $OUTPUT"
mkdir -p "$(dirname "$OUTPUT")"

EFI_IMG=""
# Ubuntu Server ISO: EFI bootloader sits at [BOOT]/Boot-NoEmul.img
# Debian d-i ISO: at boot/grub/efi.img
# Fall through both layouts.
for candidate in "$STAGING/[BOOT]/Boot-NoEmul.img" \
                 "$STAGING/boot/grub/efi.img" \
                 "$STAGING/efi.img"; do
    [ -f "$candidate" ] && EFI_IMG="$candidate" && break
done
[ -z "$EFI_IMG" ] && { echo "ERROR: no EFI image found"; exit 1; }
EFI_IMG_REL="${EFI_IMG#$STAGING/}"
echo "    EFI bootloader: $EFI_IMG_REL"

VOLID="NCLAWZERO_CIXMINI"

xorriso -as mkisofs \
    -r -V "$VOLID" \
    -J -joliet-long \
    -e "$EFI_IMG_REL" \
    -no-emul-boot \
    -isohybrid-gpt-basdat \
    -o "$OUTPUT" \
    "$STAGING"

echo ""
echo "OUTPUT: $OUTPUT"
ls -lh "$OUTPUT"
