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
#
# Append to ALL initrds present (text + gtk) so preseed.cfg is
# available regardless of which menu entry the user picks.
PRESEED_WORK="$STAGING/.preseed-cpio"
rm -rf "$PRESEED_WORK"
mkdir -p "$PRESEED_WORK"
cp "$ROOT/preseed/preseed.cfg" "$PRESEED_WORK/preseed.cfg"
PRESEED_GZ="$STAGING/.preseed.cpio.gz"
( cd "$PRESEED_WORK" && echo preseed.cfg | cpio -o -H newc --quiet | gzip ) > "$PRESEED_GZ"

INITRDS_PATCHED=0
for candidate in "$STAGING/install.a64/initrd.gz" \
                 "$STAGING/install.a64/gtk/initrd.gz"; do
    if [ -f "$candidate" ]; then
        cat "$PRESEED_GZ" >> "$candidate"
        echo "    preseed appended to $candidate"
        INITRDS_PATCHED=$((INITRDS_PATCHED+1))
    fi
done
[ $INITRDS_PATCHED -eq 0 ] && { echo "ERROR: no d-i initrd found in ISO layout"; ls -R "$STAGING/install.a64" 2>&1 | head -20; exit 1; }
rm -rf "$PRESEED_WORK" "$PRESEED_GZ"

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
cp -rL "$ROOT/assets/agent-stack" "$EXTRA/assets/"
# assets/branding — committed images, themes
[ -d "$ROOT/assets/branding" ] && cp -rL "$ROOT/assets/branding" "$EXTRA/assets/" || true

# assets/cix-debs — gitignored, supplied at build time
if [ -d "$ROOT/assets/cix-debs" ] && [ "$(ls -A $ROOT/assets/cix-debs 2>/dev/null)" ]; then
    cp -rL "$ROOT/assets/cix-debs" "$EXTRA/assets/"
    echo "    cix-debs: $(ls $EXTRA/assets/cix-debs | wc -l) files, $(du -sh $EXTRA/assets/cix-debs | cut -f1)"
else
    echo "    WARN: assets/cix-debs/ empty — install will skip Cix proprietary layer"
fi

# assets/kernel — gitignored, supplied at build time
if [ -d "$ROOT/assets/kernel" ] && [ "$(ls -A $ROOT/assets/kernel 2>/dev/null)" ]; then
    cp -rL "$ROOT/assets/kernel" "$EXTRA/assets/"
    echo "    kernel: $(du -sh $EXTRA/assets/kernel | cut -f1)"
else
    echo "    WARN: assets/kernel/ empty — install will keep Debian's linux-image-arm64"
fi

# ----------------------------------------------------------------------
# Step 5 — patch GRUB cmdline to default to auto-install
# ----------------------------------------------------------------------
echo "[5] prepending nclawzero auto-install entry to GRUB menu"
GRUB_CFG="$STAGING/boot/grub/grub.cfg"
if [ ! -f "$GRUB_CFG" ]; then
    echo "ERROR: $GRUB_CFG not found" >&2
    ls -la "$STAGING/boot/grub/" 2>&1 | head -5
    exit 1
fi

# Build the new grub.cfg by prepending our auto-install entry +
# header (timeout, default) to the stock Debian d-i menu.
NEW_CFG=$(mktemp)
cat > "$NEW_CFG" <<'GRUB'
# nclawzero installer — auto-install via preseed.
# Default boots in 5 seconds. Other Debian d-i entries kept below.
set timeout=5
set default=0
set menu_color_normal=cyan/blue
set menu_color_highlight=white/blue
insmod gzio

menuentry "*** Install nclawzero (auto, preseed)" {
    set background_color=black
    echo "Loading nclawzero installer kernel..."
    linux  /install.a64/vmlinuz auto=true priority=critical preseed/file=/cdrom/cixmini/preseed.cfg interface=auto netcfg/dhcp_timeout=60 console=ttyAMA0,115200 console=tty0
    echo "Loading initrd..."
    initrd /install.a64/initrd.gz
}

GRUB
cat "$GRUB_CFG" >> "$NEW_CFG"
mv "$NEW_CFG" "$GRUB_CFG"
echo "    GRUB cfg patched ($(wc -l < $GRUB_CFG) lines)"

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

# Volume label: ISO 9660 limits to 32 chars, all-uppercase/digits/_
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
