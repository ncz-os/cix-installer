#!/bin/bash
# test-boot-splash-select.sh -- 60-boot-splash.sh must run the KMS splash, never
# the Wayland SESSION splash.
#
# The payload ships /opt/singularity/bin/singularity-boot-splash (KMS: drmSetMaster,
# --device/--wait-seconds/--handoff/--greeter-ready) AND /opt/singularity/bin/
# singularity-splash (a GTK4/glycin Wayland client used after greeter login).
# The old "singularity-splash first" preference ran the Wayland client at early
# boot, where it printed "splash: cannot connect to Wayland display" and exited,
# leaving the MS-R1 screen black until the greeter painted. The KMS splash's
# canonical name is guaranteed by build/build-singularity.sh (it asserts
# /opt/singularity/bin/singularity-boot-splash), so the hook selects by name and
# never probes binary contents.
#
# Run: bash build/test-boot-splash-select.sh    Exit 0 = pass, 1 = fail.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${NCZ_TEST_ROOT:-$(cd "$HERE/.." && pwd)}"
G="$ROOT/post-install/60-boot-splash.sh"
WRAP="$(mktemp -t splash-wrap.XXXXXX)"
trap 'rm -f "$WRAP"' EXIT
PASS=0; FAIL=0
ok()  { echo "  PASS  $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); }

[ -f "$G" ] || { echo "FATAL: $G not found" >&2; exit 2; }

# The installer-time selection must be the canonical KMS name, unconditionally.
if grep -qE '^BSP=/opt/singularity/bin/singularity-boot-splash$' "$G"; then
    ok "installer selects the canonical KMS boot-splash name"
else
    bad "installer does not hard-select singularity-boot-splash"
fi

# The installer must never *choose* singularity-splash as the splash binary.
if grep -qE '^[[:space:]]*BSP=.*singularity-splash' "$G"; then
    bad "installer can still select the Wayland session splash as BSP"
else
    ok "installer never selects singularity-splash as the boot splash"
fi

# The runtime wrapper must pick the same canonical name.
awk '/cat > \/usr\/local\/bin\/ncz-boot-splash <<.WRAPPER.$/ {f=1; next} f && /^WRAPPER$/ {exit} f {print}' "$G" > "$WRAP"
grep -qE '^BSP=/opt/singularity/bin/singularity-boot-splash$' "$WRAP" \
    && ok "runtime wrapper hard-selects the canonical KMS boot-splash name" \
    || bad "runtime wrapper does not select singularity-boot-splash"
if grep -qE '^[[:space:]]*BSP=.*singularity-splash' "$WRAP"; then
    bad "runtime wrapper can select the Wayland session splash"
else
    ok "runtime wrapper never selects singularity-splash"
fi

# No fragile binary-content probe may remain.
if grep -q 'ncz_splash_is_kms' "$G"; then
    bad "binary-capability grep probe still present"
else
    ok "no binary-content capability probe (name is guaranteed by the build)"
fi

# The staged-asset fallback must still be reachable when the payload lacks it.
grep -q 'assets/singularity-boot-splash/singularity-boot-splash' "$G" \
    && ok "staged-asset fallback path intact" \
    || bad "staged-asset fallback path missing"

echo "boot-splash-select tests: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
