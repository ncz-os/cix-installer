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

# ----------------------------------------------------------------------
# r79: Realtek rtl_nic firmware (upstream linux-firmware). The Orion O6
# NIC (RTL8125/8126 class) needs an rtl_nic/*.fw blob for the in-tree
# r8169 driver (CONFIG_R8169=y, built-in) to bring up link. The MS-R1's
# RTL8127 happens to link without a blob, so the absence was invisible
# until O6 — where it showed up as a no-link install/runtime regression.
# Only the firmware was missing; the driver was always present.
#
# Done BEFORE the sky1-firmware early-exit below (sky1-firmware may be
# absent in some modes) and kept best-effort so it can never abort this
# Phase-1 (required) hook.
RTL_SRC=/usr/local/lib/cix-installer/assets/firmware/rtl_nic
if [ -d "$RTL_SRC" ] && [ -n "$(ls -A "$RTL_SRC" 2>/dev/null)" ]; then
    echo "[12] installing Realtek rtl_nic firmware → $DEST/rtl_nic"
    mkdir -p "$DEST/rtl_nic"
    cp -fn "$RTL_SRC"/*.fw "$DEST/rtl_nic/" 2>/dev/null || true
    echo "    rtl_nic blobs present: $(ls "$DEST/rtl_nic" 2>/dev/null | wc -l)"
else
    echo "[12] WARN: $RTL_SRC missing/empty — Orion O6 NIC may not link post-install"
fi

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
    # 7.0.12-cix-sky1-next panthor requests the arch-versioned path
    # arm/mali/arch12.8/mali_csffw.bin. The real blob is staged there in
    # assets, but symlink as a fallback so panthor always resolves it.
    mkdir -p "$DEST/arm/mali/arch12.8"
    [ -e "$DEST/arm/mali/arch12.8/mali_csffw.bin" ] || \
        ln -sfn ../mali_csffw.bin "$DEST/arm/mali/arch12.8/mali_csffw.bin"
    echo "    arch12.8: /lib/firmware/arm/mali/arch12.8/mali_csffw.bin (panthor 7.0.12)"
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
# so .zst-compressed firmware blobs (Ubuntu resolute default for linux-firmware)
# fail to load with -2 (ENOENT). MT7921e WiFi was bricked in r45-r48 because of
# this. Decompress all .zst firmware in-place so the bare-name kernel requests
# work.
# r105: the MS-R1 WiFi/BT MT7922 blobs now ship pre-DECOMPRESSED in
# assets/sky1-firmware/mediatek/ (no .zst), so this loop is belt-and-suspenders.
# It also no longer ASSUMES zstd is in the rootfs (it was NOT in the r104 server
# image -> wifi silently stayed broken): fall back to unzstd, then python.
echo "[12] decompressing any .zst firmware blobs in /lib/firmware"
_unzst() {  # $1=src.zst $2=dst ; return 0 on success
    if command -v zstd  >/dev/null 2>&1; then zstd -dqf "$1" -o "$2" 2>/dev/null && return 0; fi
    if command -v unzstd >/dev/null 2>&1; then unzstd -qf -o "$2" "$1" 2>/dev/null && return 0; fi
    # Python 3.14+ ships compression.zstd in the stdlib.
    python3 - "$1" "$2" <<'PY' 2>/dev/null && return 0
import sys
src, dst = sys.argv[1], sys.argv[2]
data = open(src, "rb").read()
try:
    from compression import zstd as z          # py3.14+
    out = z.decompress(data)
except Exception:
    import zstandard                            # optional 3rd-party
    out = zstandard.ZstdDecompressor().decompress(data)
open(dst, "wb").write(out)
PY
    return 1
}
DECOMPRESSED=0
while IFS= read -r f; do
    if _unzst "$f" "${f%.zst}"; then
        rm -f "$f"
        DECOMPRESSED=$((DECOMPRESSED + 1))
    else
        echo "    WARN: could not decompress $f (no zstd/unzstd/python zstd) — kernel may fail to load it"
    fi
done < <(find /lib/firmware -name '*.zst' -type f 2>/dev/null)
echo "    decompressed $DECOMPRESSED .zst blob(s); MT7922 WiFi/BT ship pre-decompressed as .bin"

