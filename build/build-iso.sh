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
#
# RULE (effective 2026-05-03): every cixmini ISO MUST ship BOTH kernels.
# Hard-fail if either set is missing — no LTS-only fallback. r6 violated
# this and shipped LTS-only; when LTS wedged on the IRQ 151 conflict, no
# BETA boot option was available to A/B test. See feedback_dual_kernel_cixmini.md.
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
        echo "       Run assemble-kernel-assets.sh after baking BOTH kernels."
        echo "       This RULE forbids fallback to single-kernel ISOs."
        echo "       (See ~/.claude/projects/-Users-jperlow/memory/feedback_dual_kernel_cixmini.md)"
        exit 1
    fi
done
KVER_LTS=$(cat "$ROOT/assets/kernel/lts/KVER")
KVER_NEXT=$(cat "$ROOT/assets/kernel/next/KVER")
echo "[info] LTS kernel KVER:  $KVER_LTS"
echo "[info] NEXT kernel KVER: $KVER_NEXT (BETA)"

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
MARTJOHNSON_CMDLINE="loglevel=4 console=tty0 console=ttyAMA2,115200 efi=noruntime acpi=force arm-smmu-v3.disable_bypass=0 audit_backlog_limit=8192 clk_ignore_unused keep_bootcon panic=30 module_blacklist=typec_rts5453,rts5453"
DI_PRESEED="auto=true priority=high preseed/file=/preseed.cfg interface=auto netcfg/dhcp_timeout=120"

# Compute conditional banner lines BEFORE the heredoc, then expand into
# the heredoc body. GRUB doesn't have bash-style parameter expansion,
# so we must materialize bash-side and emit GRUB-side echo commands.
NEXT_BANNER_LINE=""
if [ -n "$KVER_NEXT" ]; then
    NEXT_BANNER_LINE='echo "  │   also installed: 7.0.1-next BETA — UNSTABLE on MS-R1   │"'
fi

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
echo "  │   d-i kernel:     6.18.26 LTS (production-stable)      │"
$NEXT_BANNER_LINE
echo "  │   BETA appears as a separate entry in systemd-boot      │"
echo "  │   on first reboot — pick LTS unless A/B-testing 7.0     │"
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

# d-i ALWAYS runs on LTS only — running d-i with the known-buggy NEXT
# kernel (SCMI errors, boot freezes per Sky1-Linux issue #12) risks
# wedging the install itself. The user picks BETA only at post-install
# systemd-boot, where a wedge is recoverable (reboot → pick LTS).
#
# The NEXT kernel artifacts are staged into /cixmini/assets/kernel/next/
# on the ISO so post-install (10-our-kernel.sh) installs both kernels;
# the user just doesn't choose NEXT during d-i.

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
