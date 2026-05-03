#!/bin/bash
# build-iso.sh — repack Debian netinst-arm64 ISO with our customizations.
#
# DUAL-KERNEL build (2026-05-03+):
#   - 6.18.26 LTS  → primary kernel, d-i + installed-default
#   - 7.0.1 next   → BETA, installed alongside; user picks at systemd-boot
#
# Process:
#   1. Extract upstream ISO contents to a staging dir
#   2. Inject preseed.cfg + theme into the d-i initrd
#   3. Replace d-i vmlinuz with our LTS kernel + inject LTS modules
#   4. Stage /cixmini/ subdir on the ISO with assets + post-install hooks
#   5. Patch GRUB menu (LTS default + optional BETA 7.0.1)
#   6. Repack as UEFI-bootable hybrid ISO via xorriso
#
# Reference: https://wiki.debian.org/DebianInstaller/Preseed/EditIso

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

# Sanity: tools we need
for t in xorriso 7z cpio gzip find; do
    command -v "$t" >/dev/null 2>&1 || { echo "ERROR: missing tool: $t"; exit 1; }
done

# Detect KVERs from assemble-kernel-assets.sh sidecars. assemble writes
# assets/kernel/{lts,next}/KVER with the exact uname -r value of each
# baked kernel — single source of truth, no hardcoded version strings
# scattered across this script + post-install hooks.
KVER_LTS=""
KVER_NEXT=""
if [ -f "$ROOT/assets/kernel/lts/KVER" ]; then
    KVER_LTS=$(cat "$ROOT/assets/kernel/lts/KVER")
    echo "[info] LTS kernel KVER:  $KVER_LTS"
fi
if [ -f "$ROOT/assets/kernel/next/KVER" ]; then
    KVER_NEXT=$(cat "$ROOT/assets/kernel/next/KVER")
    echo "[info] NEXT kernel KVER: $KVER_NEXT (BETA)"
fi
if [ -z "$KVER_LTS" ]; then
    echo "WARN: assets/kernel/lts/KVER missing — d-i will run Debian's stock arm64 kernel"
    echo "      run assemble-kernel-assets.sh after Yocto bake to populate"
fi

# ----------------------------------------------------------------------
# Step 1 — fresh staging dir
# ----------------------------------------------------------------------
echo "[1] preparing staging at $STAGING"
rm -rf "$STAGING"
mkdir -p "$STAGING"

# ----------------------------------------------------------------------
# Step 2 — extract upstream ISO contents (via 7z to preserve UEFI bits)
# ----------------------------------------------------------------------
echo "[2] extracting upstream ISO via 7z"
7z x -y -o"$STAGING" "$UPSTREAM" >/dev/null

# ----------------------------------------------------------------------
# Step 3 — inject preseed.cfg + theme into d-i initrd
# ----------------------------------------------------------------------
echo "[3] injecting preseed.cfg via concatenated cpio"
# Drop gtk variant (text-mode only)
if [ -d "$STAGING/install.a64/gtk" ]; then
    rm -rf "$STAGING/install.a64/gtk"
    echo "    removed install.a64/gtk/"
fi

PRESEED_WORK="$STAGING/.preseed-cpio"
rm -rf "$PRESEED_WORK"
mkdir -p "$PRESEED_WORK"
cp "$ROOT/preseed/preseed.cfg" "$PRESEED_WORK/preseed.cfg"

# d-i UI theme
mkdir -p "$PRESEED_WORK/lib/debian-installer-startup.d"
cat > "$PRESEED_WORK/lib/debian-installer-startup.d/S05nclawzero-theme" <<'NEWT'
export NEWT_COLORS="
root=,blue
window=,black
border=brightcyan,black
title=brightcyan,black
textbox=white,black
button=black,brightcyan
actbutton=white,brightcyan
listbox=brightcyan,black
actlistbox=black,brightcyan
actsellistbox=black,brightcyan
sellistbox=white,black
checkbox=brightcyan,black
actcheckbox=black,brightcyan
roottext=brightcyan,blue
emptyscale=,black
fullscale=,brightcyan
helpline=white,black
shadow=,black
entry=white,black
disentry=brightcyan,black
"
NEWT
chmod 644 "$PRESEED_WORK/lib/debian-installer-startup.d/S05nclawzero-theme"

PRESEED_GZ="$STAGING/.preseed.cpio.gz"
( cd "$PRESEED_WORK" && find . -mindepth 1 ! -name '.' | cpio -o -H newc --quiet | gzip ) > "$PRESEED_GZ"

if [ ! -f "$STAGING/install.a64/initrd.gz" ]; then
    echo "ERROR: install.a64/initrd.gz not found"
    exit 1
fi
cat "$PRESEED_GZ" >> "$STAGING/install.a64/initrd.gz"
echo "    preseed appended to install.a64/initrd.gz"
rm -rf "$PRESEED_WORK" "$PRESEED_GZ"

# ----------------------------------------------------------------------
# Step 3.5 — swap d-i kernel to our LTS Sky1 6.18.26 kernel
#
# d-i userspace is kernel-agnostic — what matters is that
# /lib/modules/<uname -r>/ inside the running kernel matches. We swap
# vmlinuz + append a cpio with our modules at the right path.
#
# d-i runs LTS only. The NEXT 7.0.1 BETA kernel is staged onto the
# ISO at /cixmini/assets/kernel/next/ for post-install to drop on
# the target system; it is NOT used during install (BETA is for
# post-install A/B testing, not for the install process itself).
# ----------------------------------------------------------------------
if [ -n "$KVER_LTS" ] && \
   [ -f "$ROOT/assets/kernel/lts/Image-cixmini.bin" ] && \
   [ -f "$ROOT/assets/kernel/lts/modules-cixmini.tgz" ]; then
    echo "[3.5] swapping d-i kernel to linux-cix-sky1 LTS ($KVER_LTS)"

    install -m 0644 "$ROOT/assets/kernel/lts/Image-cixmini.bin" "$STAGING/install.a64/vmlinuz"
    echo "    replaced install.a64/vmlinuz ($(du -h "$STAGING/install.a64/vmlinuz" | cut -f1))"

    MOD_WORK="$STAGING/.modules-cpio"
    rm -rf "$MOD_WORK"
    mkdir -p "$MOD_WORK"
    tar xzf "$ROOT/assets/kernel/lts/modules-cixmini.tgz" -C "$MOD_WORK"
    if [ ! -d "$MOD_WORK/lib/modules/$KVER_LTS" ]; then
        echo "ERROR: lts modules tarball didn't extract to lib/modules/$KVER_LTS"
        ls "$MOD_WORK/lib/modules/" 2>&1
        exit 1
    fi

    # Run depmod against the staged tree so udev MODALIAS matching works
    # in the d-i runtime (Yocto only ships static index files).
    if ! command -v depmod >/dev/null; then
        echo "ERROR: depmod not on PATH; install kmod package on builder"
        exit 1
    fi
    depmod -a -b "$MOD_WORK" "$KVER_LTS"
    echo "    depmod-generated index files for $KVER_LTS:"
    ls -la "$MOD_WORK/lib/modules/$KVER_LTS/" | grep -E "modules\.(alias|dep|devname|softdep|symbols)" | awk '{print "      " $NF " (" $5 " bytes)"}'

    MOD_GZ="$STAGING/.modules.cpio.gz"
    ( cd "$MOD_WORK" && find lib -print | cpio -o -H newc --quiet | gzip ) > "$MOD_GZ"
    echo "    modules cpio: $(du -h "$MOD_GZ" | cut -f1)"

    cat "$MOD_GZ" >> "$STAGING/install.a64/initrd.gz"
    echo "    modules appended to install.a64/initrd.gz ($(du -h "$STAGING/install.a64/initrd.gz" | cut -f1))"
    rm -rf "$MOD_WORK" "$MOD_GZ"
else
    echo "    WARN: assets/kernel/lts/ missing — d-i will run Debian's stock 6.1 arm64 kernel"
fi

# ----------------------------------------------------------------------
# Step 4 — stage /cixmini extras on the ISO
# ----------------------------------------------------------------------
echo "[4] staging /cixmini extras"
mkdir -p "$EXTRA/post-install" "$EXTRA/assets"
cp -r "$ROOT/post-install/"*.sh "$EXTRA/post-install/"
chmod 755 "$EXTRA/post-install/"*.sh

# Build identification — single-line files consumed by:
#   - GRUB menu title on the installer USB itself
#   - late.sh (copies to /etc/cix-installer/ on installed system)
#   - 70-bootloader.sh (embeds in systemd-boot loader entry titles)
BUILD_DATE=$(date -u +"%Y-%m-%d %H:%M:%S UTC")
BUILD_HOST=$(hostname -s 2>/dev/null || echo unknown)
echo "$VERSION"     > "$EXTRA/BUILD_VERSION"
echo "$BUILD_DATE"  > "$EXTRA/BUILD_DATE"
echo "$BUILD_HOST"  > "$EXTRA/BUILD_HOST"
echo "$KVER_LTS"    > "$EXTRA/KVER_LTS"
echo "$KVER_NEXT"   > "$EXTRA/KVER_NEXT"
echo "    build id: $VERSION  ($BUILD_DATE on $BUILD_HOST)"

cp "$ROOT/preseed/late.sh" "$EXTRA/late.sh"
chmod 755 "$EXTRA/late.sh"

# Stage agent stack + branding + cix-debs (existing logic)
[ -d "$ROOT/assets/agent-stack" ] && cp -rL "$ROOT/assets/agent-stack" "$EXTRA/assets/"
if [ -d "$ROOT/assets/branding" ]; then
    mkdir -p "$EXTRA/assets/branding"
    for sub in logo plymouth gdm wallpaper; do
        if [ -d "$ROOT/assets/branding/$sub" ]; then
            cp -rL "$ROOT/assets/branding/$sub" "$EXTRA/assets/branding/"
        fi
    done
    [ -f "$ROOT/assets/branding/README.md" ] && cp "$ROOT/assets/branding/README.md" "$EXTRA/assets/branding/" || true
    bytes=$(du -sh "$EXTRA/assets/branding" 2>/dev/null | cut -f1)
    echo "    branding: $bytes"
fi
if [ -d "$ROOT/assets/cix-debs" ] && [ "$(ls -A $ROOT/assets/cix-debs 2>/dev/null)" ]; then
    cp -rL "$ROOT/assets/cix-debs" "$EXTRA/assets/"
    echo "    cix-debs: $(ls $EXTRA/assets/cix-debs | wc -l) files, $(du -sh $EXTRA/assets/cix-debs | cut -f1)"
fi

# Stage BOTH kernel sets — post-install reads them from /cdrom/cixmini/assets/kernel/{lts,next}/.
if [ -d "$ROOT/assets/kernel" ] && [ "$(ls -A $ROOT/assets/kernel 2>/dev/null)" ]; then
    cp -rL "$ROOT/assets/kernel" "$EXTRA/assets/"
    echo "    kernel: $(du -sh $EXTRA/assets/kernel | cut -f1)"
    if [ -d "$EXTRA/assets/kernel/lts" ]; then
        echo "      lts/  $(du -sh $EXTRA/assets/kernel/lts | cut -f1)"
    fi
    if [ -d "$EXTRA/assets/kernel/next" ]; then
        echo "      next/ $(du -sh $EXTRA/assets/kernel/next | cut -f1) [BETA]"
    fi
else
    echo "    WARN: assets/kernel/ empty"
fi

# Sky1 firmware (panthor mali_csffw, cix_dsp_rproc dsp_fw, linlon vpu *.fwb)
if [ -d "$ROOT/assets/sky1-firmware" ] && [ "$(ls -A $ROOT/assets/sky1-firmware 2>/dev/null)" ]; then
    cp -rL "$ROOT/assets/sky1-firmware" "$EXTRA/assets/"
    echo "    sky1-firmware: $(du -sh $EXTRA/assets/sky1-firmware | cut -f1)"
else
    echo "    WARN: assets/sky1-firmware/ empty — GPU/DSP/VPU drivers will fail to init"
fi

# ----------------------------------------------------------------------
# Step 5 — patch GRUB menu
#
# d-i menu structure (this ISO):
#   1. Install with LTS 6.18.26 (default, recommended)
#   2. [BETA] Install with 7.0.1-next (only present if NEXT kernel was baked)
#   3. SAFE rescue (rescue.target + d-i base, kernel 6.18.26)
#
# The BETA d-i entry runs d-i with the 7.0.1 kernel — useful for the
# user to verify 7.0.1 boots on their MS-R1 firmware before committing
# to install. The installed system always gets BOTH kernels regardless
# of which d-i menu entry was used.
# ----------------------------------------------------------------------
echo "[5] writing GRUB menu (dual-kernel + BETA gating)"
GRUB_CFG="$STAGING/boot/grub/grub.cfg"
[ -f "$GRUB_CFG" ] || { echo "ERROR: $GRUB_CFG not found"; exit 1; }

# MartJohnson's working MS-R1 cmdline (issue #12, 2026-04-30 update):
#   loglevel=4 console=tty0 console=ttyAMA2,115200 efi=noruntime acpi=force
#   arm-smmu-v3.disable_bypass=0 audit_backlog_limit=8192 clk_ignore_unused
#   keep_bootcon panic=30
#
# Critical flags vs the old (failing) cmdline:
#   efi=noruntime              — disables EFI runtime services that MS-R1 BIOS impl is buggy on
#   acpi=force                 — overrides default ACPI-table preference checks
#   arm-smmu-v3.disable_bypass=0 — keep SMMU bypass active (IORT compatibility)
#   audit_backlog_limit=8192   — boot-time audit subsystem doesn't drop early msgs
#   clk_ignore_unused          — Cix Sky1 hard requirement (clock auto-disable breaks SCMI)
#   keep_bootcon               — early boot console persists past handoff
#   panic=30                   — 30s grace before reboot on panic (room to read msg)
#
# BETA cmdline adds nothing extra — same flags work for both 6.18 LTS
# and 7.0 next per MartJohnson 2026-04-30.
MARTJOHNSON_CMDLINE="loglevel=4 console=tty0 console=ttyAMA2,115200 efi=noruntime acpi=force arm-smmu-v3.disable_bypass=0 audit_backlog_limit=8192 clk_ignore_unused keep_bootcon panic=30"
DI_PRESEED="auto=true priority=high preseed/file=/preseed.cfg interface=auto netcfg/dhcp_timeout=120"

# Heredoc UNQUOTED — $VERSION, $BUILD_DATE, $KVER_LTS, $KVER_NEXT,
# $MARTJOHNSON_CMDLINE, $DI_PRESEED expand at build time. No GRUB-script
# inner $vars to escape (we use plain literals everywhere).
{
cat <<GRUB
# nclawzero installer — character-mode auto-install via preseed.
# Build: $VERSION  ($BUILD_DATE)  Host: $BUILD_HOST
# Kernels: LTS=$KVER_LTS  NEXT=${KVER_NEXT:-(not baked)}
set timeout=10
set default=0
set menu_color_normal=light-cyan/black
set menu_color_highlight=black/light-cyan
set color_normal=light-cyan/black
set color_highlight=black/light-cyan
insmod gzio
clear

echo ""
echo "  ┌─────────────────────────────────────────────────────────┐"
echo "  │                    n c l a w z e r o                    │"
echo "  │             cixmini installer — Cix Sky1 / CP8180       │"
echo "  │                                                         │"
echo "  │   build $VERSION                                        "
echo "  │   $BUILD_DATE                                           "
echo "  │                                                         │"
echo "  │   default kernel: 6.18.26 LTS (production-stable)       │"
echo "  │   beta kernel:    7.0.1-next   (testing, may not boot)  │"
echo "  └─────────────────────────────────────────────────────────┘"
echo ""

menuentry "Install nclawzero (cixmini, 6.18.26 LTS — default, RECOMMENDED) — $VERSION" {
    set background_color=black
    echo "Loading linux-cix-sky1 LTS ($KVER_LTS)..."
    linux  /install.a64/vmlinuz $DI_PRESEED $MARTJOHNSON_CMDLINE
    echo "Loading initrd..."
    initrd /install.a64/initrd.gz
}
GRUB

# Optional BETA d-i entry — only if the NEXT kernel was baked AND its
# Image-cixmini.bin is staged in the ISO. We point at a SECOND vmlinuz
# (install.a64/vmlinuz-next) so swapping kernels at d-i time doesn't
# require rebuilding the ISO.
if [ -n "$KVER_NEXT" ] && [ -f "$ROOT/assets/kernel/next/Image-cixmini.bin" ]; then
    echo "    [grub] adding BETA 7.0.1 d-i entry"
    install -m 0644 "$ROOT/assets/kernel/next/Image-cixmini.bin" "$STAGING/install.a64/vmlinuz-next"
    # Build a SECOND initrd that injects the NEXT modules instead of LTS.
    # Reuses the original (post-preseed) initrd state but appends NEXT
    # modules instead of LTS modules.
    NEXT_MOD_WORK="$STAGING/.next-modules-cpio"
    rm -rf "$NEXT_MOD_WORK"
    mkdir -p "$NEXT_MOD_WORK"
    tar xzf "$ROOT/assets/kernel/next/modules-cixmini.tgz" -C "$NEXT_MOD_WORK"
    depmod -a -b "$NEXT_MOD_WORK" "$KVER_NEXT"
    NEXT_MOD_GZ="$STAGING/.next-modules.cpio.gz"
    ( cd "$NEXT_MOD_WORK" && find lib -print | cpio -o -H newc --quiet | gzip ) > "$NEXT_MOD_GZ"
    # initrd.gz already has preseed.cpio.gz + LTS modules.cpio.gz appended.
    # To get a NEXT-modules variant, start fresh from the upstream initrd
    # (in 7z extracted it again) — but that would lose the preseed cpio.
    # Easier path: copy current initrd.gz then append NEXT modules.
    # Note: this means the BETA initrd has BOTH LTS and NEXT modules
    # mounted at /lib/modules/{KVER_LTS,KVER_NEXT}/. The kernel is what
    # picks which dir to use via uname -r. Harmless overhead (~150MB);
    # avoids needing a separate base-initrd extraction.
    cp "$STAGING/install.a64/initrd.gz" "$STAGING/install.a64/initrd-next.gz"
    cat "$NEXT_MOD_GZ" >> "$STAGING/install.a64/initrd-next.gz"
    rm -rf "$NEXT_MOD_WORK" "$NEXT_MOD_GZ"
    echo "    initrd-next.gz (with NEXT modules): $(du -h "$STAGING/install.a64/initrd-next.gz" | cut -f1)"

cat <<GRUB

menuentry "[BETA — UNSTABLE] Install with 7.0.1-next ($KVER_NEXT) — KNOWN-BUGGY on MS-R1" {
    set background_color=black
    echo ""
    echo "*** BETA 7.0.1-next kernel — known issues on MS-R1: ***"
    echo "    - SCMI transition errors (BIOS missing required updates)"
    echo "    - Occasional boot freezes / shutdown crashes"
    echo "    - Audio NOT functional (alc269 patch deferred)"
    echo "    Use 6.18.26 LTS for production. This entry is for"
    echo "    A/B testing the 7.0 path only."
    echo ""
    echo "Loading linux-cix-sky1-next BETA ($KVER_NEXT)..."
    linux  /install.a64/vmlinuz-next $DI_PRESEED $MARTJOHNSON_CMDLINE
    echo "Loading initrd-next..."
    initrd /install.a64/initrd-next.gz
}
GRUB
fi

cat <<GRUB

menuentry "SAFE — rescue shell (kernel $KVER_LTS, no auto-install)" {
    set background_color=black
    echo "Loading rescue mode (kernel $KVER_LTS)..."
    linux  /install.a64/vmlinuz rescue/enable=true $MARTJOHNSON_CMDLINE
    echo "Loading initrd..."
    initrd /install.a64/initrd.gz
}
GRUB
} > "$GRUB_CFG"
echo "    GRUB cfg written ($(wc -l < "$GRUB_CFG") lines)"

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
for candidate in "$STAGING/boot/grub/efi.img" \
                 "$STAGING/efi.img"; do
    [ -f "$candidate" ] && EFI_IMG="$candidate"
done
[ -z "$EFI_IMG" ] && { echo "ERROR: no EFI image found"; exit 1; }
EFI_IMG_REL="${EFI_IMG#$STAGING/}"

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
