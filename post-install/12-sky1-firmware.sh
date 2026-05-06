#!/bin/bash
# 12-sky1-firmware.sh — install Sky1 SoC firmware blobs to /lib/firmware
#
# The Sky1-Linux 6.18 in-tree drivers need firmware at runtime:
#   panthor (Mali-G720 GPU)        → mali_csffw.bin
#   cix_dsp_rproc (HiFi5 DSP)      → dsp_fw.bin
#   in-tree VPU (CONFIG_VIDEO_LINLON) → 13× *.fwb codec firmware
#   rtw89 (Realtek WiFi, if used)  → rtw8852b*.bin
#
# Source: github.com/Sky1-Linux/sky1-firmware (git tracked) staged into
# the ISO under /cdrom/cixmini/assets/sky1-firmware/ by build-iso.sh,
# copied into /usr/local/lib/cix-installer/assets/sky1-firmware by
# late.sh. This hook drops it into /lib/firmware on the target.
set -euo pipefail

SRC=/usr/local/lib/cix-installer/assets/sky1-firmware
DEST=/lib/firmware

if [ ! -d "$SRC" ] || [ -z "$(ls -A "$SRC" 2>/dev/null)" ]; then
    echo "[12] WARN: $SRC missing or empty — skipping (GPU/DSP/VPU drivers will fail at runtime)"
    exit 0
fi

echo "[12] copying Sky1 firmware blobs $SRC → $DEST"
mkdir -p "$DEST"
cp -rn "$SRC"/* "$DEST"/
echo "    installed: $(find "$DEST" -newer "$SRC" -type f 2>/dev/null | wc -l) files"

# panthor (Mali-G720) request_firmware() path fix.
# Our sky1-firmware ships mali_csffw.bin at arm/mali/mali_csffw.bin, but:
#   - cix-sky1 LTS kernel's panthor requests bare 'mali_csffw.bin'
#     (dmesg: panthor CIXH5000:00: [drm] *ERROR* Failed to load firmware
#     image 'mali_csffw.bin' / probe with driver panthor failed -2)
#   - upstream panthor (6.10+) requests 'arm/mali_csffw.bin'
# Drop both symlinks so either driver flavour resolves the file.
if [ -f "$DEST/arm/mali/mali_csffw.bin" ]; then
    ln -sfn arm/mali/mali_csffw.bin "$DEST/mali_csffw.bin"
    ln -sfn mali/mali_csffw.bin     "$DEST/arm/mali_csffw.bin"
    echo "    symlinks: /lib/firmware/mali_csffw.bin + /lib/firmware/arm/mali_csffw.bin"
fi

echo "    key blobs:"
for f in mali_csffw.bin arm/mali_csffw.bin arm/mali/mali_csffw.bin dsp_fw.bin h264dec.fwb hevcdec.fwb av1dec.fwb; do
    if [ -e "$DEST/$f" ]; then
        echo "      ✓ $f"
    else
        echo "      ✗ $f (missing — driver may fail to init)"
    fi
done

# r49: kernel 6.18.26-cix-sky1-lts may lack CONFIG_FW_LOADER_COMPRESS_ZSTD,
# so .zst-compressed firmware blobs (Ubuntu questing default for linux-firmware)
# fail to load with -2 (ENOENT). MT7921e WiFi was bricked in r45-r48 because of
# this. Decompress all .zst firmware in-place so the bare-name kernel requests
# work. zstd is in the rootfs (we added it via TYPHON SERVER_PACKAGES).
echo "[12] decompressing .zst firmware blobs in /lib/firmware"
DECOMPRESSED=0
find /lib/firmware -name '*.zst' -type f 2>/dev/null | while read -r f; do
    if zstd -dqf "$f" -o "${f%.zst}" 2>/dev/null; then
        rm -f "$f"
        DECOMPRESSED=$((DECOMPRESSED + 1))
    fi
done
echo "    decompressed firmware blobs (e.g. mediatek/WIFI_*MT7922* for MS-R1 WiFi)"

