#!/bin/bash
# verify-drivers.sh — driver fidelity check for a freshly-installed NCZ-OS
# system. Run as root on the target. Prints PASS/FAIL per subsystem; the Sky1
# subsystem checks (NPU, GPU, VPU, WiFi, Bluetooth, audio) run on arm64 only.
# Audio is expected WARN (known-open).
#
# Expected kernel, first match wins:
#   1. $NCZ_EXPECTED_KVER
#   2. the KVER_NEXT sidecar the installer wrote for this install
#      (/etc/cix-installer/KVER_NEXT, /usr/local/lib/cix-installer/KVER_NEXT)
#   3. from a repository checkout (this script under tools/): the kernel the
#      image build uses -- assets/kernel/mainline/KVER (arm64) or
#      assets/kernel/amd64-stable/KVER (amd64), as build/build-image.sh
#      resolves it -- then the manifests/components.tsv kernel row
#      (sky1-mainline-kernel / amd64-stable-kernel).
#
# Usage: verify-drivers.sh [--expected-kernel]
#   --expected-kernel  print the expected kernel release and exit (0 found, 1 not)
# Test knobs (build/test-verify-drivers.sh): NCZ_VD_ROOT (prefix for the
# sidecar paths), NCZ_VD_REPO (repository root), NCZ_VD_ARCH (arm64|amd64).
set -u
GRN=$'\e[32m'; RED=$'\e[31m'; YEL=$'\e[33m'; RST=$'\e[0m'
pass(){ echo "${GRN}PASS${RST} $*"; }
fail(){ echo "${RED}FAIL${RST} $*"; }
warn(){ echo "${YEL}WARN${RST} $*"; }
hr(){ echo "------------------------------------------------------------"; }

VD_ROOT="${NCZ_VD_ROOT:-}"
VD_REPO="${NCZ_VD_REPO:-$(cd "$(dirname "$(readlink -f "$0")")/.." 2>/dev/null && pwd)}"
VD_ARCH="${NCZ_VD_ARCH:-}"
if [ -z "$VD_ARCH" ]; then
    case "$(uname -m)" in aarch64|arm64) VD_ARCH=arm64 ;; x86_64|amd64) VD_ARCH=amd64 ;; *) VD_ARCH="$(uname -m)" ;; esac
fi

expected_kver() {
    local f k row kfile
    if [ -n "${NCZ_EXPECTED_KVER:-}" ]; then echo "$NCZ_EXPECTED_KVER"; return 0; fi
    for f in "$VD_ROOT/etc/cix-installer/KVER_NEXT" "$VD_ROOT/usr/local/lib/cix-installer/KVER_NEXT"; do
        k=$(tr -d '[:space:]' < "$f" 2>/dev/null)
        [ -n "$k" ] && { echo "$k"; return 0; }
    done
    case "$VD_ARCH" in
        arm64) kfile=assets/kernel/mainline/KVER; row=sky1-mainline-kernel ;;
        amd64) kfile=assets/kernel/amd64-stable/KVER; row=amd64-stable-kernel ;;
        *) return 1 ;;
    esac
    k=$(tr -d '[:space:]' < "$VD_REPO/$kfile" 2>/dev/null)
    [ -n "$k" ] && { echo "$k"; return 0; }
    k=$(awk -F'\t' -v r="$row" '$1==r {print $7; exit}' "$VD_REPO/manifests/components.tsv" 2>/dev/null)
    [ -n "$k" ] && { echo "$k"; return 0; }
    return 1
}

if [ "${1:-}" = "--expected-kernel" ]; then
    expected_kver
    exit $?
fi

echo "=== NCZ-OS driver fidelity check  $(date) ==="
echo "kernel: $(uname -r)   arch: $VD_ARCH   variant: $(cat "$VD_ROOT/usr/local/lib/cix-installer/BUILD_VARIANT" 2>/dev/null)   build: $(cat "$VD_ROOT/etc/cix-installer/BUILD_VERSION" 2>/dev/null)"
hr
# --- Kernel is the one this install was built with ---
WANT_KVER=$(expected_kver)
if [ -z "$WANT_KVER" ]; then
    warn "running $(uname -r) (expected kernel unknown: no KVER_NEXT sidecar and no repository manifests)"
elif [ "$(uname -r)" = "$WANT_KVER" ]; then
    pass "running the installed NCZ kernel $WANT_KVER"
else
    warn "running $(uname -r) (expected $WANT_KVER as default)"
fi

if [ "$VD_ARCH" != arm64 ]; then
    hr; echo "Sky1 subsystem checks skipped (arch $VD_ARCH)"
    hr; echo "=== done ==="
    exit 0
fi

# --- NPU (armchina Zhouyi V3; vendor aipu.ko via DKMS, see post-install/80-npu.sh) ---
hr; echo "[NPU]"
if [ -e /dev/aipu ]; then pass "/dev/aipu present"; else fail "/dev/aipu MISSING"; fi
MOD=$(lsmod | awk '$1=="aipu"{print $1}')
[ -n "$MOD" ] && pass "aipu loaded" || fail "aipu NOT loaded"
KO=$(modinfo aipu 2>/dev/null | awk '/^filename/{print $2}')
echo "    module: $KO"
case "$KO" in *updates*) pass "loaded from updates/ (DKMS or validated overlay)";; *) warn "not from updates/: $KO";; esac
dmesg 2>/dev/null | grep -iE "armchina|aipu|zhouyi" | grep -iE "v3|prob|version" | tail -3
dmesg 2>/dev/null | grep -iE "unidentified hardware version|dma_alloc.*idx 2|aipu.*fail" | tail -3 | sed 's/^/    !! /'

# --- GPU: mali_kbase is the default stack, panthor is opt-in (sky1.gpu=panthor) ---
hr; echo "[GPU]"
GPU=""
if lsmod | grep -qE "^mali_kbase"; then GPU=mali; pass "mali_kbase loaded (default GPU stack)"
elif lsmod | grep -qE "^panthor"; then GPU=panthor; pass "panthor loaded (opt-in GPU stack)"
else fail "no GPU kernel driver loaded (mali_kbase or panthor)"; fi
ls /dev/dri/renderD* >/dev/null 2>&1 && pass "render node $(ls /dev/dri/renderD* 2>/dev/null)" || warn "no /dev/dri render node"
if [ "$GPU" = panthor ]; then
    dmesg 2>/dev/null | grep -iE "panthor" | grep -iE "fw|firmware|csffw|G720|init" | tail -3
    dmesg 2>/dev/null | grep -iE "panthor.*(fail|error|ERROR)" | tail -2 | sed 's/^/    !! /'
    [ -e /lib/firmware/arm/mali/arch12.8/mali_csffw.bin ] && pass "arch12.8/mali_csffw.bin deployed" || fail "arch12.8 fw MISSING"
elif [ "$GPU" = mali ]; then
    dmesg 2>/dev/null | grep -iE "mali.*(fail|error|ERROR)" | tail -2 | sed 's/^/    !! /'
fi

# --- Vulkan ---
hr; echo "[Vulkan]"
if command -v vulkaninfo >/dev/null 2>&1; then
  if [ "$GPU" = panthor ]; then
    VK=$(VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/panfrost_icd.json vulkaninfo 2>/dev/null | grep -iE "deviceName|Mali" | head -2)
  else
    VK=$(vulkaninfo 2>/dev/null | grep -iE "deviceName|Mali" | head -2)
  fi
  [ -n "$VK" ] && { pass "vulkan device enumerated"; echo "    $VK"; } || warn "vulkaninfo ran but no device (check ICD/env)"
else warn "vulkaninfo not installed (install vulkan-tools to verify)"; fi

# --- VPU (Linlon MVX, amvx.ko; see post-install/81-vpu.sh) ---
hr; echo "[VPU]"
lsmod | grep -qE "^amvx" && pass "amvx loaded" || warn "amvx NOT loaded"
ls /dev/video* >/dev/null 2>&1 && pass "v4l2 nodes: $(ls /dev/video* 2>/dev/null | tr '\n' ' ')" || warn "no /dev/video* nodes"

# --- WiFi (MT7922) ---
hr; echo "[WiFi]"
lsmod | grep -qiE "mt7921|mt792|mt76" && pass "mt79xx wifi module loaded" || fail "wifi module NOT loaded"
ip -o link 2>/dev/null | awk -F': ' '/wl/{print "    iface: "$2}'
dmesg 2>/dev/null | grep -iE "mt7921|mt7922" | grep -iE "fail|error|firmware" | tail -2 | sed 's/^/    !! /'

# --- Bluetooth ---
hr; echo "[Bluetooth]"
command -v hciconfig >/dev/null 2>&1 && hciconfig 2>/dev/null | grep -q hci && pass "hci device present" || \
  { ls /sys/class/bluetooth/* >/dev/null 2>&1 && pass "bluetooth device in sysfs" || warn "no bluetooth device"; }

# --- Audio (KNOWN-OPEN) ---
hr; echo "[Audio]  (known-open)"
if aplay -l >/dev/null 2>&1 && aplay -l 2>/dev/null | grep -q card; then pass "sound card registered"; aplay -l 2>/dev/null | grep card | sed 's/^/    /'; else warn "no sound card registered (expected; audio is the open item)"; fi

hr; echo "=== done ==="
