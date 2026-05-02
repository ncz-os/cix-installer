#!/bin/bash
# build-iso.sh — repack Debian netinst-arm64 ISO with our customizations.
#
# Process:
#   1. Extract the upstream ISO contents to a staging dir
#   2. Inject preseed.cfg into the initrd of d-i
#   3. Patch GRUB cmdline to autoload the preseed (auto + url=...)
#   4. Stage our /cixmini/ subdir on the ISO with assets + post-install
#      hooks (preseed late_command picks them up via /cdrom/cixmini)
#   5. Repack as UEFI-bootable hybrid ISO via xorriso
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
# Step 3 — inject preseed.cfg into d-i initrd
#
# The d-i initrd (initrd.gz under install.a64/ on bookworm-arm64)
# auto-loads /preseed.cfg if present.
# ----------------------------------------------------------------------
echo "[3] injecting preseed.cfg via concatenated cpio (no extraction needed)"
# Linux initramfs supports concatenated cpio archives — kernel's
# init/initramfs.c reads multiple back-to-back cpio streams and overlays
# them in order. So instead of extracting the d-i initrd (which fails
# without root because it contains device nodes), we just append a
# tiny cpio that contains only preseed.cfg.
INITRD=""
for candidate in "$STAGING/install.a64/initrd.gz" \
                 "$STAGING/install.a64/gtk/initrd.gz"; do
    [ -f "$candidate" ] && INITRD="$candidate"
done
[ -z "$INITRD" ] && { echo "ERROR: couldn't find d-i initrd in ISO layout"; ls -R "$STAGING/install.a64" 2>&1 | head -20; exit 1; }
echo "    initrd: $INITRD"

PRESEED_WORK="$STAGING/.preseed-cpio"
rm -rf "$PRESEED_WORK"
mkdir -p "$PRESEED_WORK"
cp "$ROOT/preseed/preseed.cfg" "$PRESEED_WORK/preseed.cfg"
# Build cpio of just preseed.cfg, gzip it, append to initrd
( cd "$PRESEED_WORK" && echo preseed.cfg | cpio -o -H newc --quiet | gzip ) > "$STAGING/.preseed.cpio.gz"
cat "$STAGING/.preseed.cpio.gz" >> "$INITRD"
rm -rf "$PRESEED_WORK" "$STAGING/.preseed.cpio.gz"
echo "    preseed.cfg appended"

# ----------------------------------------------------------------------
# Step 4 — stage our extras at /cixmini on the ISO
#
# preseed late_command copies /cdrom/cixmini → /target/usr/local/lib/
# cix-installer, then runs run-all.sh in the target chroot.
# ----------------------------------------------------------------------
echo "[4] staging /cixmini extras"
mkdir -p "$EXTRA/post-install" "$EXTRA/assets"
cp -r "$ROOT/post-install/"*.sh "$EXTRA/post-install/"
chmod 755 "$EXTRA/post-install/"*.sh

# assets/agent-stack — committed quadlet files
cp -r "$ROOT/assets/agent-stack" "$EXTRA/assets/"
# assets/branding — committed images, themes
[ -d "$ROOT/assets/branding" ] && cp -r "$ROOT/assets/branding" "$EXTRA/assets/" || true

# assets/cix-debs — gitignored, supplied at build time
if [ -d "$ROOT/assets/cix-debs" ] && [ "$(ls -A $ROOT/assets/cix-debs 2>/dev/null)" ]; then
    cp -r "$ROOT/assets/cix-debs" "$EXTRA/assets/"
    echo "    cix-debs: $(ls $EXTRA/assets/cix-debs | wc -l) files, $(du -sh $EXTRA/assets/cix-debs | cut -f1)"
else
    echo "    WARN: assets/cix-debs/ empty — install will skip Cix proprietary layer"
fi

# assets/kernel — gitignored, supplied at build time
if [ -d "$ROOT/assets/kernel" ] && [ "$(ls -A $ROOT/assets/kernel 2>/dev/null)" ]; then
    cp -r "$ROOT/assets/kernel" "$EXTRA/assets/"
    echo "    kernel: $(du -sh $EXTRA/assets/kernel | cut -f1)"
else
    echo "    WARN: assets/kernel/ empty — install will keep Debian's linux-image-arm64"
fi

# ----------------------------------------------------------------------
# Step 5 — patch GRUB cmdline to default to auto-install
# ----------------------------------------------------------------------
echo "[5] patching GRUB to auto-launch with preseed"
GRUB_CFG=""
for candidate in "$STAGING/boot/grub/grub.cfg" \
                 "$STAGING/EFI/debian/grub.cfg"; do
    [ -f "$candidate" ] && GRUB_CFG="$candidate"
done
if [ -n "$GRUB_CFG" ]; then
    # Add an auto-install menu entry at the top
    sed -i '0,/menuentry/{s|menuentry|menuentry "*** Install nclawzero (auto, preseed)" {\n    set background_color=black\n    linux /install.a64/vmlinuz auto=true priority=critical preseed/file=/cdrom/cixmini/preseed.cfg interface=auto netcfg/dhcp_timeout=60 quiet\n    initrd /install.a64/initrd.gz\n}\nmenuentry|}' "$GRUB_CFG" || true
    # Set timeout 5s + first entry default
    sed -i 's/^set default=.*/set default="0"/; s/^set timeout=.*/set timeout=5/' "$GRUB_CFG" || true
fi

# ----------------------------------------------------------------------
# Step 6 — rebuild md5sum.txt (d-i checks integrity)
# ----------------------------------------------------------------------
echo "[6] regenerating md5sum.txt"
( cd "$STAGING" && find . -type f \! -name md5sum.txt -print0 | xargs -0 md5sum > md5sum.txt )

# ----------------------------------------------------------------------
# Step 7 — repack as UEFI-bootable hybrid ISO via xorriso
# ----------------------------------------------------------------------
echo "[7] repacking via xorriso → $OUTPUT"
mkdir -p "$(dirname "$OUTPUT")"

# Find the EFI image (varies by Debian release layout)
EFI_IMG=""
for candidate in "$STAGING/boot/grub/efi.img" \
                 "$STAGING/efi.img"; do
    [ -f "$candidate" ] && EFI_IMG="$candidate"
done
[ -z "$EFI_IMG" ] && { echo "ERROR: no EFI image found"; exit 1; }
EFI_IMG_REL="${EFI_IMG#$STAGING/}"

xorriso -as mkisofs \
    -r -V "nclawzero-cixmini-$VERSION" \
    -J -joliet-long \
    -e "$EFI_IMG_REL" \
    -no-emul-boot \
    -isohybrid-gpt-basdat \
    -o "$OUTPUT" \
    "$STAGING"

echo ""
echo "OUTPUT: $OUTPUT"
ls -lh "$OUTPUT"
