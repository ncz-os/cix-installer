#!/bin/bash
# test-gpu-status-arch.sh -- ncz-gpu-status reports the real GPU stack on
# machines that are not Sky1 (r201).
#
# On the MacBookPro16,1 and GU502LV (amd64) `ncz-gpu-status` printed
# "selected : mali (from built-in default)": the Sky1 Mali/Panthor switcher
# report ran on every architecture. This test runs the real
# assets/gpu/ncz-gpu-status against a fixture /sys (NCZ_SYSROOT) with the arch
# forced (NCZ_GPU_STATUS_ARCH).
#
# Run: bash build/test-gpu-status-arch.sh     Exit 0 = pass, 1 = fail.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${NCZ_TEST_ROOT:-$(cd "$HERE/.." && pwd)}"
S="$ROOT/assets/gpu/ncz-gpu-status"
W="$(mktemp -d -t gpu-status-arch.XXXXXX)"; trap 'rm -rf "$W"' EXIT
PASS=0; FAIL=0
ok()  { echo "  PASS  $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'; }

# card ROOT N PCI VENDOR DEVICE DRIVER BOOTVGA
card() {
    local r="$1" n="$2" dev
    dev="$1/sys/devices/pci0000:00/$3"
    mkdir -p "$dev" "$r/sys/bus/pci/drivers/$6" "$r/sys/class/drm" "$r/sys/devices/drm/card$n" "$r/sys/bus/platform/devices"
    echo "$4" > "$dev/vendor"; echo "$5" > "$dev/device"; echo "$7" > "$dev/boot_vga"
    [ "$6" = none ] || ln -s "$r/sys/bus/pci/drivers/$6" "$dev/driver"
    ln -s "$dev" "$r/sys/devices/drm/card$n/device"
    ln -s "$r/sys/devices/drm/card$n" "$r/sys/class/drm/card$n"
    mkdir -p "$r/sys/devices/drm/card$n-eDP-1"; ln -s "$r/sys/devices/drm/card$n-eDP-1" "$r/sys/class/drm/card$n-eDP-1"
    mkdir -p "$r/sys/devices/drm/renderD$((128 + n))"; ln -s "$dev" "$r/sys/devices/drm/renderD$((128 + n))/device"
    ln -s "$r/sys/devices/drm/renderD$((128 + n))" "$r/sys/class/drm/renderD$((128 + n))"
}

echo "=== amd64 PRIME laptop (GU502LV shape: Intel iGPU + NVIDIA on nouveau) ==="
R="$W/gu502lv"; card "$R" 0 0000:00:02.0 0x8086 0x9bc4 i915 1; card "$R" 1 0000:01:00.0 0x10de 0x1f15 nouveau 0
out=$(NCZ_GPU_STATUS_ARCH=x86_64 NCZ_SYSROOT="$R" sh "$S" 2>&1); rc=$?
[ "$rc" = 0 ] && ok "exit 0" || bad "exit $rc" "$out"
printf '%s\n' "$out" | grep -qE '^selected|mali \(from|^userspace +: vendor Mali' && bad "still reports the Sky1 Mali selection" "$out" || ok "no Mali/'selected' line"
printf '%s\n' "$out" | grep -q 'switcher (sky1.gpu=) does not apply' && ok "says the Sky1 switcher does not apply" || bad "no not-Sky1 notice" "$out"
printf '%s\n' "$out" | grep -qE '^gpu card0 +: driver=i915 \(Intel.*device=0000:00:02.0 \[8086:9bc4\] boot_vga$' && ok "card0: i915 Intel, ids, boot_vga" || bad "card0 line wrong" "$out"
printf '%s\n' "$out" | grep -qE '^gpu card1 +: driver=nouveau .*\[10de:1f15\]$' && ok "card1: nouveau with ids" || bad "card1 line wrong" "$out"
printf '%s\n' "$out" | grep -q 'card0-eDP-1' && bad "connector listed as a GPU" "$out" || ok "connectors are not listed as GPUs"
printf '%s\n' "$out" | grep -q 'renderD128(i915) .*renderD129(nouveau)' && ok "render nodes with their drivers" || bad "render nodes wrong" "$out"

echo "=== amd64 T2 (MacBookPro16,1 shape: amdgpu) and an unbound card ==="
R="$W/mbp16"; card "$R" 0 0000:03:00.0 0x1002 0x7340 amdgpu 1; card "$R" 1 0000:00:02.0 0x8086 0x3e9b none 0
out=$(NCZ_GPU_STATUS_ARCH=x86_64 NCZ_SYSROOT="$R" sh "$S" 2>&1)
printf '%s\n' "$out" | grep -qE '^gpu card0 +: driver=amdgpu \(AMD' && ok "amdgpu reported as AMD" || bad "amdgpu line wrong" "$out"
printf '%s\n' "$out" | grep -qE '^gpu card1 +: driver=none \(NO DRIVER BOUND\)' && ok "unbound card reported as NO DRIVER BOUND" || bad "unbound card line wrong" "$out"

echo "=== no DRM card at all ==="
R="$W/empty"; mkdir -p "$R/sys/class/drm" "$R/sys/bus/platform/devices"
out=$(NCZ_GPU_STATUS_ARCH=x86_64 NCZ_SYSROOT="$R" sh "$S" 2>&1)
printf '%s\n' "$out" | grep -q 'no DRM card' && ok "says no DRM card" || bad "empty /sys handled wrong" "$out"

echo "=== arm64 without the CIX GPU device is not Sky1 ==="
out=$(NCZ_GPU_STATUS_ARCH=aarch64 NCZ_SYSROOT="$W/empty" sh "$S" 2>&1)
printf '%s\n' "$out" | grep -q 'does not apply' && ok "generic arm64 gets the generic report" || bad "generic arm64 treated as Sky1" "$out"

echo "=== Sky1 keeps the switcher report ==="
R="$W/sky1"; mkdir -p "$R/sys/bus/platform/devices/CIXH5000:00" "$R/sys/class/drm"
out=$(NCZ_GPU_STATUS_ARCH=aarch64 NCZ_SYSROOT="$R" sh "$S" 2>&1)
printf '%s\n' "$out" | grep -q '^selected      :' && ok "Sky1 still prints the selected stack" || bad "Sky1 report lost" "$out"
printf '%s\n' "$out" | grep -q 'does not apply' && bad "Sky1 told the switcher does not apply" || ok "Sky1 not given the generic notice"

echo "=== --require-hardware is unchanged for every arch (runs before the arch split) ==="
a=$(grep -n '^if \[ "\$REQUIRE_HW" = 1 \]' "$S" | head -1 | cut -d: -f1); b=$(grep -n '^_sky1=0' "$S" | head -1 | cut -d: -f1)
[ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ] && ok "health check block precedes the arch split" || bad "arch split moved before --require-hardware"

echo "gpu-status arch tests: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
