#!/bin/bash
# 12-sky1-firmware.sh — install Sky1 SoC firmware blobs to /lib/firmware
#
# The Sky1-Linux in-tree drivers need firmware at runtime:
#   panthor (Mali-G720 GPU)        → mali_csffw.bin
#   cix_dsp_rproc (HiFi5 DSP)      → dsp_fw.bin
#   in-tree VPU (CONFIG_VIDEO_LINLON) → 13× *.fwb codec firmware
#   rtw89 (Realtek WiFi, if used)  → rtw8852b*.bin
#
# Source: github.com/Sky1-Linux/sky1-firmware (git tracked) staged into
# the ISO under /cdrom/ncz-payload/assets/sky1-firmware/ by the build pipeline
# (build/build-squashfs-layers.sh + build/build-iso-di.sh + the new
# build/iso/{import-substrate,stage-ncz-payload,write-image}.py
# assembly writer; see docs/ISO-BUILD-GUARDRAILS.md), copied into
# /usr/local/lib/cix-installer/assets/sky1-firmware by late.sh. This hook
# drops it into /lib/firmware on the target.
# NCZ-PLATFORM-GUARD: sky1-arm64 only (docs/PLATFORM-SPLIT-DESIGN.md). Arch order matches
# run-all.sh: NCZ_TARGET_ARCH, then the late.sh BUILD_ARCH stamp, then dpkg. An
# undetectable arch does NOT skip (legacy behavior).
_ncz_pg_arch="${NCZ_TARGET_ARCH:-}"
[ -n "$_ncz_pg_arch" ] || _ncz_pg_arch=$(cat /usr/local/lib/cix-installer/BUILD_ARCH 2>/dev/null | tr -d '[:space:]')
[ -n "$_ncz_pg_arch" ] || _ncz_pg_arch=$(dpkg --print-architecture 2>/dev/null || true)
case "$_ncz_pg_arch" in
    arm64|aarch64|"") ;;
    *) echo "[${0##*/}] platform guard: arch=$_ncz_pg_arch is not sky1-arm64; skipping"; exit 0 ;;
esac
unset _ncz_pg_arch
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

# r127: upstream signed wireless-regdb. The previously shipped
# /lib/firmware/regulatory.db was stale and cfg80211 rejected it ("malformed
# or signature is missing/invalid"), pinning Wi-Fi to the world domain
# (country 00 — reduced channels/TX power). Overwrite with the current
# upstream signed DB so the cix kernel validates it and the proper regdomain
# (e.g. US/DFS-FCC) can apply. Force-copy (-f, not -n) to replace the stale one.
REGDB_SRC=/usr/local/lib/cix-installer/assets/firmware/regdb
if [ -f "$REGDB_SRC/regulatory.db" ] && [ -f "$REGDB_SRC/regulatory.db.p7s" ]; then
    echo "[12] installing upstream wireless-regdb → $DEST/regulatory.db{,.p7s}"
    install -m 0644 "$REGDB_SRC/regulatory.db" "$REGDB_SRC/regulatory.db.p7s" "$DEST/" 2>/dev/null || true
    echo "    regulatory.db: $(stat -c%s "$DEST/regulatory.db" 2>/dev/null || echo 0) bytes"
else
    echo "[12] note: $REGDB_SRC absent — keeping existing regulatory.db (Wi-Fi may stay in world domain)"
fi

# ----------------------------------------------------------------------
# 2026-09-28 arm64 gate: the missing-source-dir branch below used to be
# `WARN + exit 0`, which is how the 2026-09-27 arm64 install shipped
# without VPU codecs / DSP fw / Mali CSF firmware while every gate
# reported success. Same detection shape as 10-our-kernel.sh /
# 36-telemetry.sh: env var first, then the late.sh-stamped BUILD_ARCH
# file, then dpkg as a last-resort fallback. The arm64 gate is
# introduced AFTER the rtl_nic + regdb best-effort blocks above so amd64
# behaviour is unchanged (those blocks still run on amd64, and on amd64
# we exit 0 here without ever touching the arm64 fail-loud branches).
_ncz_arch="${NCZ_TARGET_ARCH:-}"
if [ -z "$_ncz_arch" ] && [ -r /usr/local/lib/cix-installer/BUILD_ARCH ]; then
    _ncz_arch=$(tr -d '[:space:]' < /usr/local/lib/cix-installer/BUILD_ARCH)
fi
if [ -z "$_ncz_arch" ]; then
    _ncz_arch=$(dpkg --print-architecture 2>/dev/null || true)
fi
case "$_ncz_arch" in
    arm64) ;;
    *)
        echo "[12] arch=$_ncz_arch -- rtl_nic + regdb done above, Sky1 firmware not applicable"
        exit 0
        ;;
esac

# arm64: every required blob MUST be present, both at the source-side
# ($SRC exists & non-empty) and at the destination-side (after the cp
# below, the same key blobs must resolve under $DEST). The 16 .fwb
# codecs are what the in-tree VPU (CONFIG_VIDEO_LINLON) needs;
# dsp_fw.bin is the HiFi5 DSP remoteproc binary; mali_csffw.bin is the
# Mali-G720 CSF firmware (panthor requests arm/mali/arch12.8/...).
REQUIRED_FWB="av1dec.fwb avs2dec.fwb avsdec.fwb h264dec.fwb h264enc.fwb hevcdec.fwb hevcenc.fwb jpegdec.fwb jpegenc.fwb mpeg2dec.fwb mpeg4dec.fwb vc1dec.fwb vp8dec.fwb vp8enc.fwb vp9dec.fwb vp9enc.fwb"
REQUIRED_OTHER="dsp_fw.bin arm/mali/arch12.8/mali_csffw.bin"

_missing=0
if [ ! -d "$SRC" ] || [ -z "$(ls -A "$SRC" 2>/dev/null)" ]; then
    echo "[12] FATAL: $SRC missing or empty — arm64 ISO requires Sky1 firmware (VPU codecs, DSP fw, Mali CSF)."
    echo "[12] The build-side pre-flight (build/verify-arm64-inputs.sh) should have caught this;"
    echo "[12] if you got here, that gate was skipped — fix the build, not this hook."
    echo "[12] Required source-side items:"
    for f in $REQUIRED_FWB $REQUIRED_OTHER; do echo "    - $SRC/$f"; done
    exit 1
fi
for f in $REQUIRED_FWB; do
    if [ ! -s "$SRC/$f" ]; then
        echo "[12] FATAL: required source blob missing or empty: $SRC/$f"
        _missing=1
    fi
done
for f in $REQUIRED_OTHER; do
    if [ ! -s "$SRC/$f" ]; then
        echo "[12] FATAL: required source blob missing or empty: $SRC/$f"
        _missing=1
    fi
done
if [ "$_missing" -ne 0 ]; then
    echo "[12] one or more arm64 firmware blobs are absent from the staged source tree;"
    echo "[12] restore the assets/sky1-firmware tree from your build-inputs store"
    echo "[12] (build/stage-arm64-assets.sh extracts it from the pinned assets/sky1-firmware.tar.zst)."
    exit 1
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
_dst_missing=0
for f in mali_csffw.bin arm/mali_csffw.bin arm/mali/mali_csffw.bin dsp_fw.bin h264dec.fwb hevcdec.fwb av1dec.fwb; do
    if [ -e "$DEST/$f" ]; then
        echo "      ✓ $f"
    else
        echo "      ✗ $f (missing — driver may fail to init)"
        _dst_missing=1
    fi
done
# arm64: every required blob must end up under $DEST too. The 16 .fwb
# codecs + dsp_fw.bin + arm/mali/arch12.8/mali_csffw.bin are the
# non-negotiable set; the source-side check above already proved the
# source tree has them, so a missing destination is a copy defect
# (read-only $DEST, full disk, etc.) that must surface.
_required_dst="$REQUIRED_FWB $REQUIRED_OTHER"
for f in $_required_dst; do
    if [ ! -e "$DEST/$f" ]; then
        echo "[12] FATAL: required destination blob missing after copy: $DEST/$f"
        _dst_missing=1
    fi
done
if [ "$_dst_missing" -ne 0 ]; then
    echo "[12] one or more required firmware blobs did not land in $DEST;"
    echo "[12] check that $DEST is writable and has space."
    exit 1
fi

# r49: a kernel may lack CONFIG_FW_LOADER_COMPRESS_ZSTD,
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

