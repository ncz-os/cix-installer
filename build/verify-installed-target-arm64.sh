#!/bin/bash
# verify-installed-target-arm64.sh -- assert the INSTALLED target rootfs
# actually carries the Sky1 accelerator userspace the install chain claims.
#
# Companion to kvm-install-gate-gpt.sh. The gate builds a raw ext4 image of
# the installed root partition ($EVIDENCE_ROOT), copies the install logs out
# of it with debugfs, and deletes it. Before it is deleted, this script reads
# the same image (rootless, debugfs only) and asserts:
#   (i)   Sky1 firmware: 16 .fwb + dsp_fw.bin + arm/mali/arch12.8/mali_csffw.bin
#   (ii)  NPU: /usr/src/aipu-6.2.0, /usr/sbin/dkms, and a DKMS-built aipu.ko
#         for the installed Sky1 kernel whose embedded version is 6.2.0
#         (never the 5.11.0 in-tree generation)
#   (iii) VPU: amvx module registered in modules.dep, the load-modules.sh
#         helper that creates /dev/video-cixdec0, and a distro ffmpeg whose
#         libavcodec carries the *_v4l2m2m codecs
#   (iv)  browsers: google-chrome-stable and chromium-ncz-sky1 installed
#   (info) VA-API driver files (reported, never a failure)
#
# Usage: verify-installed-target-arm64.sh <EVIDENCE_ROOT_RAW> <DEBUGFS>
# Exit:  0 all required artifacts present, 1 at least one missing (every miss
#        is printed as "GATE: missing [class]: what"), 2 bad invocation.
set -uo pipefail

EVIDENCE_ROOT="${1:?usage: verify-installed-target-arm64.sh EVIDENCE_ROOT_RAW DEBUGFS}"
DEBUGFS="${2:?usage: verify-installed-target-arm64.sh EVIDENCE_ROOT_RAW DEBUGFS}"
[ -f "$EVIDENCE_ROOT" ] || { echo "GATE FAIL: $EVIDENCE_ROOT is not a regular file" >&2; exit 2; }
[ -x "$DEBUGFS" ] || { echo "GATE FAIL: $DEBUGFS is not executable" >&2; exit 2; }

TMP="$(mktemp -d -t verify-target.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

FAIL=0
gate_miss() { echo "GATE: missing [$1]: $2" >&2; FAIL=1; }

# debugfs prints "<path>: File not found by ext2_lookup" (rc stays 0) for a
# missing path and an "Inode:" line for a present one. Key on the positive
# marker; never on the absence of an error string.
dfs() { "$DEBUGFS" -R "$1" "$EVIDENCE_ROOT" 2>&1; }
exists() { dfs "stat $1" | grep -q '^Inode:'; }
# dump <path-in-image> <local-file>; success only if a non-empty file landed.
fetch() {
    rm -f "$2"
    "$DEBUGFS" -R "dump $1 $2" "$EVIDENCE_ROOT" >/dev/null 2>&1
    [ -s "$2" ]
}
# Names in a directory ("ls -p" fields: /inode/mode/uid/gid/name/size/).
lsnames() { dfs "ls -p $1" | awk -F/ 'NF>=6 && $6!="." && $6!=".." {print $6}'; }

# Decompress a dumped module in place by suffix; echo the resulting path.
# Returns non-zero (and prints nothing) if the needed tool is missing.
plain_module() {
    local f="$1"
    case "$f" in
        *.xz)  command -v xz   >/dev/null 2>&1 && xz   -dc "$f" > "${f%.xz}"  && echo "${f%.xz}"  ;;
        *.zst) command -v zstd >/dev/null 2>&1 && zstd -dqc "$f" > "${f%.zst}" && echo "${f%.zst}" ;;
        *.gz)  gzip -dc "$f" > "${f%.gz}" && echo "${f%.gz}" ;;
        *)     echo "$f" ;;
    esac
}

# --- (i) firmware ---------------------------------------------------------
FW=/usr/lib/firmware
exists "$FW" || FW=/lib/firmware
echo "[verify-target] (i) Sky1 firmware under $FW"
n=0
for f in av1dec avs2dec avsdec h264dec h264enc hevcdec hevcenc jpegdec jpegenc \
         mpeg2dec mpeg4dec vc1dec vp8dec vp8enc vp9dec vp9enc; do
    if exists "$FW/$f.fwb"; then n=$((n + 1)); else gate_miss firmware "$FW/$f.fwb"; fi
done
for f in dsp_fw.bin arm/mali/arch12.8/mali_csffw.bin; do
    exists "$FW/$f" || gate_miss firmware "$FW/$f"
done
echo "[verify-target]     .fwb present: $n/16"

# --- kernel version (newest Sky1 kernel in the image) --------------------
# The kernel this image ships and boots is recorded in KVER_NEXT (the payload's
# edge kernel). The rootfs can also carry an older/experimental Sky1 kernel from
# the baked base layer (2026-09-29: 7.3.0-rc3 next to 7.2.8), so "newest
# directory" would verify the wrong one. Fall back to newest only if KVER_NEXT
# is unreadable.
KVER=""
if fetch /usr/local/lib/cix-installer/KVER_NEXT "$TMP/KVER_NEXT"; then
    KVER="$(tr -d '[:space:]' < "$TMP/KVER_NEXT")"
    exists "/usr/lib/modules/$KVER" || { gate_miss kernel "KVER_NEXT names $KVER but /usr/lib/modules/$KVER is absent"; KVER=""; }
fi
[ -n "$KVER" ] || KVER="$(lsnames /usr/lib/modules | grep -E -- '-sky1-ncz$' | sort -V | tail -1)"
if [ -z "$KVER" ]; then
    gate_miss kernel "no *-sky1-ncz directory under /usr/lib/modules"
else
    echo "[verify-target]     installed Sky1 kernel: $KVER"
fi
MODDEP=""
if [ -n "$KVER" ] && fetch "/usr/lib/modules/$KVER/modules.dep" "$TMP/modules.dep"; then
    MODDEP="$TMP/modules.dep"
elif [ -n "$KVER" ]; then
    gate_miss kernel "/usr/lib/modules/$KVER/modules.dep (missing or empty; depmod never ran)"
fi
# modules.dep line: "<relpath>.ko[.ext]: deps"
mod_path() { [ -n "$MODDEP" ] && grep -E "(^|/)$1\.ko(\.[a-z]+)?:" "$MODDEP" | head -1 | cut -d: -f1; }

# --- (ii) NPU -------------------------------------------------------------
echo "[verify-target] (ii) NPU (aipu 6.2.0)"
exists /usr/src/aipu-6.2.0 || gate_miss npu "/usr/src/aipu-6.2.0"
exists /usr/sbin/dkms || exists /usr/bin/dkms || gate_miss npu "dkms binary"
AIPU_REL="$(mod_path aipu)"
if [ -z "$AIPU_REL" ]; then
    [ -n "$MODDEP" ] && gate_miss npu "aipu module not registered in /usr/lib/modules/$KVER/modules.dep"
else
    case "$AIPU_REL" in
        updates/*) : ;;
        *) gate_miss npu "aipu is at $AIPU_REL, not a DKMS/updates build (expected updates/dkms/aipu.ko*)" ;;
    esac
    ext="${AIPU_REL##*/}"; ext="$TMP/${ext}"
    if ! fetch "/usr/lib/modules/$KVER/$AIPU_REL" "$ext"; then
        gate_miss npu "cannot read /usr/lib/modules/$KVER/$AIPU_REL"
    elif ! ko="$(plain_module "$ext")" || [ -z "$ko" ]; then
        gate_miss npu "cannot decompress $AIPU_REL (missing xz/zstd tool)"
    else
        # The aipu module carries no MODULE_VERSION tag. Its KMD version is the
        # %s argument of the probe banner "AIPU KMD (v%s) probe start...", stored
        # as a standalone string immediately before the format string, so the
        # old generation reads "5.11.0" there and the matched one "6.2.0".
        strs="$(grep -aoE '[[:print:]]{3,}' "$ko")"
        if printf '%s\n' "$strs" | grep -A1 -xE '6\.2\.0' | grep -q 'AIPU KMD (v%s)'; then
            echo "[verify-target]     aipu $AIPU_REL KMD version 6.2.0"
        elif printf '%s\n' "$strs" | grep -qxE '5\.11\.0'; then
            gate_miss npu "aipu $AIPU_REL is KMD 5.11.0 (old generation)"
        else
            gate_miss npu "aipu $AIPU_REL does not carry KMD version 6.2.0 before its probe banner"
        fi
        # DKMS must also hold it as built for this kernel.
        exists "/var/lib/dkms/aipu/6.2.0/$KVER" || gate_miss npu "/var/lib/dkms/aipu/6.2.0/$KVER (dkms state for the shipped kernel)"
    fi
fi

# --- (iii) VPU ------------------------------------------------------------
echo "[verify-target] (iii) VPU (amvx)"
AMVX_REL="$(mod_path amvx)"
if [ -n "$AMVX_REL" ]; then
    echo "[verify-target]     amvx module: $AMVX_REL"
elif [ -n "$MODDEP" ]; then
    gate_miss vpu "amvx module not registered in modules.dep for $KVER"
fi
# The /dev/video-cixdec0 symlink is created by the load-modules.sh helper.
if fetch /usr/bin/load-modules.sh "$TMP/load-modules.sh" && grep -q 'video-cixdec0' "$TMP/load-modules.sh"; then
    echo "[verify-target]     /usr/bin/load-modules.sh creates /dev/video-cixdec0"
else
    gate_miss vpu "/usr/bin/load-modules.sh with the video-cixdec0 symlink logic"
fi
exists /usr/bin/ffmpeg || gate_miss vpu "/usr/bin/ffmpeg"
avc=""
for d in /usr/lib/aarch64-linux-gnu /usr/lib; do
    avc="$(lsnames $d | grep -E '^libavcodec\.so\.[0-9.]+$' | sort -V | tail -1)"
    [ -n "$avc" ] && { avc="$d/$avc"; break; }
done
if [ -z "$avc" ]; then
    gate_miss vpu "libavcodec shared library"
elif fetch "$avc" "$TMP/libavcodec.so" && grep -aq 'h264_v4l2m2m' "$TMP/libavcodec.so"; then
    echo "[verify-target]     $avc carries h264_v4l2m2m"
else
    gate_miss vpu "$avc without the h264_v4l2m2m codec"
fi

# --- (iv) browsers --------------------------------------------------------
echo "[verify-target] (iv) browsers"
if fetch /var/lib/dpkg/status "$TMP/dpkg-status"; then
    for pkg in google-chrome-stable chromium-ncz-sky1; do
        if awk -v p="$pkg" '
            BEGIN { RS=""; FS="\n" }
            { pk=""; st=""
              for (i = 1; i <= NF; i++) {
                  if ($i ~ /^Package: /) pk = substr($i, 10)
                  if ($i ~ /^Status: /)  st = substr($i, 9)
              }
              if (pk == p && st == "install ok installed") found = 1 }
            END { exit(found ? 0 : 1) }' "$TMP/dpkg-status"; then
            echo "[verify-target]     dpkg: $pkg installed"
        else
            gate_miss browser "$pkg (no 'install ok installed' dpkg stanza)"
        fi
    done
else
    gate_miss browser "/var/lib/dpkg/status unreadable"
fi

# --- (info) VA-API ---------------------------------------------------------
va=""
for d in /usr/lib/aarch64-linux-gnu/dri /usr/lib/dri; do
    va="$va $(lsnames $d | grep -E '_drv_video\.so$' | tr '\n' ' ')"
done
echo "[verify-target] (info) VA-API drivers:${va:- none}"

if [ "$FAIL" -ne 0 ]; then
    echo "GATE: arm64 installed-target accelerator check FAILED (see GATE: lines above)" >&2
    exit 1
fi
echo "[verify-target] OK: arm64 installed-target accelerator artifacts present"
exit 0
