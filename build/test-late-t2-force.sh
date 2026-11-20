#!/bin/bash
# test-late-t2-force.sh -- the KVM-gate T2-DKMS force wiring in preseed/late.sh
# (marker block t2-dkms-force-env; operator ORDER #27(2), 2026-11-14).
#
# The gate appends ncz_t2_dkms_force=1 to the rEFInd Install entry options;
# late.sh runs in the d-i environment (where /proc is mounted) and exports
# NCZ_T2_DKMS_FORCE=1 into the chrooted hook chain, which cannot rely on
# /proc. post-install/56-t2-dkms.sh then builds t2smc/t2gmux inside the VM
# so build/check-t2-dkms-modules.sh can assert they exist for the shipped
# kernel.
#
# The test sources ONLY the marker block against fixture cmdline files
# (NCZ_CMDLINE_FILE override) -- it never runs late.sh.
#
# Run: bash build/test-late-t2-force.sh     Exit 0 = pass, 1 = fail.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${NCZ_TEST_ROOT:-$(cd "$HERE/.." && pwd)}"
LATE="$ROOT/preseed/late.sh"
W="$(mktemp -d -t t2-force.XXXXXX)"; trap 'rm -rf "$W"' EXIT
PASS=0; FAIL=0
ok()  { echo "  PASS  $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); }

bash -n "$LATE" && ok "late.sh parses" || bad "late.sh syntax"

BLOCK="$W/block.sh"
sed -n '/^# BEGIN t2-dkms-force-env$/,/^# END t2-dkms-force-env$/p' "$LATE" | sed '1d;$d' > "$BLOCK"
if [ ! -s "$BLOCK" ]; then
    bad "t2-dkms-force-env marker block missing from preseed/late.sh"
    echo "test-late-t2-force: $PASS passed, $FAIL failed"
    exit 1
fi
ok "t2-dkms-force-env marker block extracted"

# run_block CMDLINE_CONTENT [PRESET_ENV]
# Runs the block in a subshell against a fixture cmdline; prints the
# resulting NCZ_T2_DKMS_FORCE (empty when unset).
run_block() {
    printf '%s\n' "$1" > "$W/cmdline"
    (
        NCZ_T2_DKMS_FORCE="${2:-}"; export NCZ_T2_DKMS_FORCE
        NCZ_CMDLINE_FILE="$W/cmdline"
        . "$BLOCK" >/dev/null 2>&1
        printf '%s' "${NCZ_T2_DKMS_FORCE:-}"
    )
}

[ "$(run_block 'BOOT_IMAGE=/linux ncz_t2_dkms_force=1 console=tty0')" = 1 ] \
    && ok "cmdline ncz_t2_dkms_force=1 exports NCZ_T2_DKMS_FORCE=1" \
    || bad "force token on cmdline did not export the env"
[ "$(run_block 'ncz_t2_dkms_force=1 ncz_unattended=1')" = 1 ] \
    && ok "force token as first cmdline word works" \
    || bad "force token at cmdline start not seen"
[ "$(run_block 'BOOT_IMAGE=/linux ncz_unattended=1 ncz_components=desktop')" = "" ] \
    && ok "cmdline without the token leaves the env unset" \
    || bad "env set without the cmdline token"
[ "$(run_block 'quiet ncz_t2_dkms_force=0')" = "" ] \
    && ok "ncz_t2_dkms_force=0 does not force" \
    || bad "force=0 exported the env"
[ "$(run_block 'quiet' 1)" = 1 ] \
    && ok "already-set env passes through untouched" \
    || bad "preset env was clobbered"
[ "$(run_block '')" = "" ] \
    && ok "empty cmdline is a no-op" \
    || bad "empty cmdline exported the env"

echo "test-late-t2-force: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
