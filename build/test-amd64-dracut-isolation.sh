#!/bin/bash
# test-amd64-dracut-isolation.sh -- regression test for item C.2:
# the Sky1-only dracut configuration (assets/dracut/10-ncz-sky1.conf, which
# carries the linlon-dp/trilin-dpsub display + USB-ethernet module set) must
# never be staged into an amd64 base image.
#
# Before the fix, build/build-squashfs-layers.sh's asset allowlist copied
# assets/dracut into EVERY base, amd64 included. 94-dracut-config's platform
# guard stops the hook from INSTALLING it on amd64, but the file still landed
# in the amd64 payload, and any future consumer would hand it to dracut, which
# logs "linlon_dp: module not found" on an x86 kernel.
#
# Runnable on any host: it extracts the REAL staging loop from
# build/build-squashfs-layers.sh and drives it with a fixture tree and a
# stubbed `sudo` (no root, no amd64 hardware, no squashfs build).
#
# Exit 0 = every case passed; exit 1 = at least one case failed; exit 2 = the
# script under test could not be extracted.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
LAYERS="${LAYERS:-$REPO/build/build-squashfs-layers.sh}"
HOOK="$REPO/post-install/94-dracut-config.sh"
AMD_LIST="$REPO/post-install/hooks.list.amd64"
SKY_LIST="$REPO/post-install/hooks.list.sky1-arm64"
CONF="$REPO/assets/dracut/10-ncz-sky1.conf"

[ -r "$LAYERS" ] || { echo "FATAL: cannot read $LAYERS" >&2; exit 2; }
[ -r "$HOOK" ]   || { echo "FATAL: cannot read $HOOK" >&2; exit 2; }

PASS=0; FAIL=0
ok()  { echo "ok   $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL $1"; FAIL=$((FAIL+1)); }

# --- static evidence: the config is Sky1-only and the hook is arm64-scoped ---
if grep -q 'linlon-dp' "$CONF"; then
    ok "assets/dracut/10-ncz-sky1.conf names the Sky1 linlon-dp module"
else
    bad "assets/dracut/10-ncz-sky1.conf does not name linlon-dp (fixture moved?)"
fi
# shellcheck disable=SC2016  # $_ncz_pg_arch is a literal grep pattern, not a shell var
if grep -q 'NCZ-PLATFORM-GUARD' "$HOOK" \
   && grep -qE '^[[:space:]]*case "\$_ncz_pg_arch" in' "$HOOK"; then
    ok "94-dracut-config.sh carries the sky1 platform guard"
else
    bad "94-dracut-config.sh is missing the NCZ-PLATFORM-GUARD early exit"
fi
if grep -qxF '94-dracut-config.sh' "$SKY_LIST"; then
    ok "94-dracut-config.sh is on the sky1-arm64 hook list"
else
    bad "94-dracut-config.sh is not on the sky1-arm64 hook list"
fi
if ! grep -qxF '94-dracut-config.sh' "$AMD_LIST"; then
    ok "94-dracut-config.sh is NOT on the amd64 hook list"
else
    bad "94-dracut-config.sh is on the amd64 hook list"
fi

# --- functional evidence: drive the real asset-staging loop ---
# Extract `for a in cix-debs kernel ...; do ...; done` from the base build.
LOOP="$(awk '/for a in cix-debs kernel/{f=1} f{print} f&&/^[[:space:]]*done[[:space:]]*$/{exit}' "$LAYERS")"
if [ -z "$LOOP" ]; then
    echo "FATAL: could not extract the base asset-staging loop from $LAYERS" >&2
    exit 2
fi

stage_into() { # <arch> <fixture-root> <fixture-work>
    local arch="$1" froot="$2" fwork="$3"
    (
        set +e
        # ROOT/WORK/NCZ_TARGET_ARCH and the sudo() stub are consumed by the
        # eval'd staging loop below; shellcheck cannot see into the eval.
        # shellcheck disable=SC2034,SC2329
        ROOT="$froot" WORK="$fwork" NCZ_TARGET_ARCH="$arch"
        # Rootless copy: the loop's `sudo cp -a` runs as the invoking user.
        # shellcheck disable=SC2329  # invoked indirectly by the eval'd loop
        sudo() { "$@"; }
        eval "$LOOP"
    ) 2>/dev/null
}

run_case() { # <arch> -- prints the staged top-level asset names for that arch
    local arch="$1" tmp
    tmp="$(mktemp -d -t ncz-dracut-stage.XXXXXX)"
    mkdir -p "$tmp/root/assets/dracut" "$tmp/root/assets/branding"
    mkdir -p "$tmp/work/base/usr/local/lib/cix-installer/assets"
    printf 'add_drivers+=" linlon-dp trilin-dpsub "\n' > "$tmp/root/assets/dracut/10-ncz-sky1.conf"
    : > "$tmp/root/assets/branding/marker"
    stage_into "$arch" "$tmp/root" "$tmp/work"
    ls "$tmp/work/base/usr/local/lib/cix-installer/assets" 2>/dev/null
    rm -rf "$tmp"
}

AMD_STAGED="$(run_case amd64)"
ARM_STAGED="$(run_case arm64)"

if printf '%s\n' "$ARM_STAGED" | grep >/dev/null -xF 'dracut'; then
    ok "arm64 base stages assets/dracut (the test is not vacuous)"
else
    bad "arm64 base did NOT stage assets/dracut -- the extraction/fixture is broken"
fi
if printf '%s\n' "$AMD_STAGED" | grep >/dev/null -xF 'dracut'; then
    bad "amd64 base staged assets/dracut (Sky1 dracut config leaked onto x86)"
else
    ok "amd64 base does NOT stage assets/dracut"
fi

# Prove the amd64 staged tree carries no Sky1-only module reference at all.
tmp="$(mktemp -d -t ncz-dracut-scan.XXXXXX)"
mkdir -p "$tmp/root/assets/dracut" "$tmp/root/assets/branding"
mkdir -p "$tmp/work/base/usr/local/lib/cix-installer/assets"
printf 'add_drivers+=" linlon-dp trilin-dpsub "\n' > "$tmp/root/assets/dracut/10-ncz-sky1.conf"
: > "$tmp/root/assets/branding/marker"
stage_into amd64 "$tmp/root" "$tmp/work"
if grep -rIq 'linlon' "$tmp/work" 2>/dev/null; then
    bad "amd64 staged tree still contains a linlon reference: $(grep -rIl 'linlon' "$tmp/work" 2>/dev/null | head -3 | tr '\n' ' ')"
else
    ok "no linlon reference anywhere in the simulated amd64 staged tree"
fi
rm -rf "$tmp"

echo
echo "amd64-dracut-isolation tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
