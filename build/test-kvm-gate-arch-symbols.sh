#!/bin/bash
# test-kvm-gate-arch-symbols.sh — the KVM gate's per-arch symbol rules, proven both ways.
#
# The gate enforces a different minimum per architecture, taken from the two real kernel
# configs (arm64 Sky1 7.3.1: ISO9660_FS=y; amd64 T2 r295: ISO9660_FS=m):
#   * arm64 must have ISO9660 builtin -- the installer mounts the ISO before modules load
#   * x86 may carry it as a module  -- an installed T2 system does exactly that
#   * the Sky1 PCI-collision lint applies to arm64 only, because those drivers are =m on
#     amd64 and harmless there (no Sky1 PCI IDs)
# Both the pass and the fail side of each rule are exercised here, so a gate that silently
# accepts everything, or rejects everything, cannot pass this test.
set -u
cd "$(dirname "$0")/.." || exit 1

GATE=build/kvm-kernel-gate.sh
TMP=$(mktemp -d "${TMPDIR:-/tmp}/kvm-gate-symbols.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf 'FAIL %s\n' "$1"; }

# Minimal configs: only the symbols the gate reads.
mkcfg() { # <path> <iso9660-value> <collider: yes|no>
  {
    echo "CONFIG_DEVTMPFS=y"
    echo "CONFIG_DEVTMPFS_MOUNT=y"
    echo "CONFIG_BLK_DEV_LOOP=y"
    [ "$2" = "unset" ] || echo "CONFIG_ISO9660_FS=$2"
    if [ "$3" = "yes" ]; then
      echo "CONFIG_USB_CDNS3_PCI_WRAP=m"
      echo "CONFIG_USB_CDNSP_PCI=m"
      echo "CONFIG_USB_CDNS2_UDC=m"
    fi
  } > "$1"
}

: > "$TMP/dummy-image"   # never booted: GATE_SKIP_BOOT=1 stops after the lint

# run <arch> <config> -> exit code, output in $TMP/out
run() {
  GATE_ARCH="$1" GATE_SKIP_BOOT=1 bash "$GATE" "$TMP/dummy-image" "$2" > "$TMP/out" 2>&1
  return $?
}

check_pass() { # <desc> <arch> <iso> <collider>
  mkcfg "$TMP/c" "$3" "$4"
  if run "$2" "$TMP/c"; then ok "$1"; else bad "$1 (expected PASS)"; sed -n '1,12p' "$TMP/out"; fi
}

check_fail() { # <desc> <arch> <iso> <collider> <expected-substring>
  mkcfg "$TMP/c" "$3" "$4"
  if run "$2" "$TMP/c"; then
    bad "$1 (expected FAIL, gate passed)"
  elif grep -qF "$5" "$TMP/out"; then
    ok "$1"
  else
    bad "$1 (failed, but not for $5)"; sed -n '1,12p' "$TMP/out"
  fi
}

# --- ISO9660: builtin required on arm64, module acceptable on x86 -----------------
check_pass "arm64 + ISO9660=y passes"                    arm64 y     no
check_fail "arm64 + ISO9660=m is rejected"               arm64 m     no  "CONFIG_ISO9660_FS=y"
check_pass "amd64 + ISO9660=m passes (module allowed)"   amd64 m     no
check_pass "amd64 + ISO9660=y passes"                    amd64 y     no
check_fail "amd64 + ISO9660 absent is rejected"          amd64 unset no  "ISO9660_FS"

# --- Sky1 PCI collision lint: arm64 only ------------------------------------------
check_fail "arm64 + Sky1 colliders is DENIED"            arm64 y     yes "DENIED"
check_pass "amd64 + Sky1 colliders is ignored"           amd64 m     yes

# --- the shared minimum still applies on both arches ------------------------------
mkcfg "$TMP/c" "y" "no"
grep -v "CONFIG_BLK_DEV_LOOP" "$TMP/c" > "$TMP/c2" && mv "$TMP/c2" "$TMP/c"
if run amd64 "$TMP/c"; then bad "amd64 without BLK_DEV_LOOP must fail"; else ok "amd64 without BLK_DEV_LOOP fails"; fi
mkcfg "$TMP/c" "y" "no"
grep -v "CONFIG_DEVTMPFS_MOUNT" "$TMP/c" > "$TMP/c2" && mv "$TMP/c2" "$TMP/c"
if run arm64 "$TMP/c"; then bad "arm64 without DEVTMPFS_MOUNT must fail"; else ok "arm64 without DEVTMPFS_MOUNT fails"; fi

# --- accelerator policy, all combinations (no qemu involved) ----------------------
# shellcheck disable=SC1090  # the gate returns immediately when sourced
. ./build/kvm-kernel-gate.sh >/dev/null 2>&1
eq() { # <expected> <actual> <desc>
  if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got $2, want $1)"; fi
}
eq tcg "$(gate_accel arm64 x86_64 1)" "arm64 guest on x86 host: tcg (cross-arch)"
eq tcg "$(gate_accel amd64 aarch64 1)" "amd64 guest on arm64 host: tcg (cross-arch)"
eq kvm "$(gate_accel amd64 x86_64 1)" "amd64 guest on x86 host: kvm"
eq kvm "$(gate_accel arm64 aarch64 1)" "arm64 guest on arm64 host: kvm"
eq tcg "$(gate_accel amd64 x86_64 0)" "amd64 guest on x86 host without /dev/kvm: tcg"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
