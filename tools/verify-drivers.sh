#!/bin/bash
# verify-drivers.sh — full driver fidelity check for a freshly-installed
# cixmini (CIX Sky1) running 7.0.12-cix-sky1-next. Run as root on the target.
# Prints PASS/FAIL per subsystem. Audio is expected FAIL (known-open).
GRN=$'\e[32m'; RED=$'\e[31m'; YEL=$'\e[33m'; RST=$'\e[0m'
pass(){ echo "${GRN}PASS${RST} $*"; }
fail(){ echo "${RED}FAIL${RST} $*"; }
warn(){ echo "${YEL}WARN${RST} $*"; }
hr(){ echo "------------------------------------------------------------"; }

echo "=== cixmini driver fidelity check  $(date) ==="
echo "kernel: $(uname -r)   variant: $(cat /usr/local/lib/cix-installer/BUILD_VARIANT 2>/dev/null)   build: $(cat /etc/cix-installer/BUILD_VERSION 2>/dev/null)"
hr
# --- Kernel is the headline 7.0.12 ---
case "$(uname -r)" in 7.0.12-cix-sky1-next) pass "running headline kernel 7.0.12-cix-sky1-next";; *) warn "running $(uname -r) (expected 7.0.12-cix-sky1-next as default)";; esac

# --- NPU (armchina Zhouyi V3) ---
hr; echo "[NPU]"
if [ -e /dev/aipu ]; then pass "/dev/aipu present"; else fail "/dev/aipu MISSING"; fi
MOD=$(lsmod | awk '$1=="armchina_npu"{print $1}')
[ -n "$MOD" ] && pass "armchina_npu loaded" || fail "armchina_npu NOT loaded"
KO=$(modinfo armchina_npu 2>/dev/null | awk '/^filename/{print $2}')
echo "    module: $KO"
case "$KO" in *updates*) pass "loaded from updates/ overlay (validated build)";; *) warn "not from updates/ overlay: $KO";; esac
dmesg 2>/dev/null | grep -iE "armchina|aipu|zhouyi" | grep -iE "v3|prob|version" | tail -3
dmesg 2>/dev/null | grep -iE "unidentified hardware version|dma_alloc.*idx 2|aipu.*fail" | tail -3 | sed 's/^/    !! /'

# --- GPU (panthor Mali-G720) + arch12.8 fw ---
hr; echo "[GPU/panthor]"
lsmod | grep -qE "^panthor" && pass "panthor loaded" || fail "panthor NOT loaded"
ls /dev/dri/renderD* >/dev/null 2>&1 && pass "render node $(ls /dev/dri/renderD* 2>/dev/null)" || fail "no /dev/dri render node"
dmesg 2>/dev/null | grep -iE "panthor" | grep -iE "fw|firmware|csffw|G720|init" | tail -3
dmesg 2>/dev/null | grep -iE "panthor.*(fail|error|ERROR)" | tail -2 | sed 's/^/    !! /'
[ -e /lib/firmware/arm/mali/arch12.8/mali_csffw.bin ] && pass "arch12.8/mali_csffw.bin deployed" || fail "arch12.8 fw MISSING"

# --- panvk Vulkan compute ---
hr; echo "[panvk/Vulkan]"
if command -v vulkaninfo >/dev/null 2>&1; then
  VK=$(VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/panfrost_icd.json vulkaninfo 2>/dev/null | grep -iE "deviceName|Mali" | head -2)
  [ -n "$VK" ] && { pass "vulkan device enumerated"; echo "    $VK"; } || warn "vulkaninfo ran but no device (check ICD/env)"
else warn "vulkaninfo not installed (install vulkan-tools to verify)"; fi

# --- VPU (Linlon video codec) ---
hr; echo "[VPU]"
lsmod | grep -qiE "linlon|cix_vpu|vpu" && pass "vpu module loaded" || warn "no vpu module (linlon/cix_vpu)"
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
hr; echo "[Audio]  (known-open on 7.0.12)"
if aplay -l >/dev/null 2>&1 && aplay -l 2>/dev/null | grep -q card; then pass "sound card registered"; aplay -l 2>/dev/null | grep card | sed 's/^/    /'; else warn "no sound card registered (expected; audio is the open item)"; fi

hr; echo "=== done ==="
