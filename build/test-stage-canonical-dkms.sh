#!/bin/bash
# test-stage-canonical-dkms.sh -- contract test: build/stage-canonical-assets.sh
# must restage EVERY DKMS deb that build/verify-dkms-deb-sources.py checks
# (except npu, which is the vendor cix-npu-driver-dkms), and the stale-deb
# failure in verify-arm64-inputs.sh must say how to fix it.
#
# The r200 stage script built only mali/panthor/npu, so a stale
# cix-vpu-driver-dkms deb (same filename, older source) was never replaced and
# the new gate then failed with a message that did not name the fix.
# Panthor left the set entirely (order 01:35Z 2026-11-15): the stage script
# must NOT build or restage panthor-cix-dkms.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STAGE="${NCZ_STAGE_UNDER_TEST:-$ROOT/build/stage-canonical-assets.sh}"
VERIFY="${NCZ_VERIFY_UNDER_TEST:-$ROOT/build/verify-arm64-inputs.sh}"
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

call=$(grep -E '^[[:space:]]*if bash "\$REPO/build/build-dkms-debs\.sh"' "$STAGE")
for drv in mali vpu; do
    case " $call " in *" $drv "*) ok "stage builds $drv DKMS deb" ;; *) bad "stage does not build $drv DKMS deb" ;; esac
done
case " $call " in *" panthor "*) bad "stage builds panthor (Panthor is not shipped)" ;; *) ok "stage does not build the panthor deb" ;; esac
case " $call " in *" npu "*) bad "stage builds npu (retired cix-npu-kmd tree must not be staged)" ;; *) ok "stage does not build the retired npu tree" ;; esac
for pkg in cix-gpu-kmd-dkms cix-vpu-driver-dkms; do
    if grep -q "build/dkms-debs\"/${pkg}_\*\.deb" "$STAGE"; then ok "stage restages $pkg"
    else bad "stage does not restage $pkg"; fi
done
if grep -q 'rm -f "\$ASSETS/cix-debs"/panthor-cix-dkms_\*\.deb' "$STAGE"; then ok "stage removes stale panthor-cix-dkms debs"
else bad "stage does not remove stale panthor-cix-dkms debs"; fi
if grep -q 'EXPECTED_DKMS=.*cix-vpu-driver' "$STAGE"; then ok "completeness gate expects the vpu deb"
else bad "completeness gate does not expect the vpu deb"; fi
if grep -q 'EXPECTED_DKMS=.*panthor' "$STAGE"; then bad "completeness gate still expects the panthor deb"
else ok "completeness gate does not expect the panthor deb"; fi
if grep -q 'cix-debs.dkms-source.*stage-canonical-assets\.sh' "$VERIFY"; then ok "stale-deb failure names the fix"
else bad "stale-deb failure does not name the fix"; fi

echo "--- $pass passed, $fail failed"
[ "$fail" -eq 0 ]
