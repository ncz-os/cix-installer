#!/bin/bash
# test-verify-build-input.sh -- behavioural tests for build/lib/verify-build-input.sh
#
# The bad directions matter: a mismatch MUST be refused, and a missing pin MUST be
# distinguishable from a match so the caller can decide between "refuse" and "warn".
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  PASS  $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL  $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'; }
rc_of() { "$@" >/dev/null 2>&1; echo $?; }

# shellcheck source=../build/lib/verify-build-input.sh
. "$HERE/lib/verify-build-input.sh"

printf 'reviewed bytes\n' > "$T/good.bin"
GOOD_SHA="$(sha256sum "$T/good.bin" | cut -d' ' -f1)"
printf 'other bytes\n' > "$T/bad.bin"
printf '# arch\tdest\tsha256\tsize\tnote\namd64\tassets/python311/good.tar.gz\t%s\t15\ta note\n' "$GOOD_SHA" > "$T/pins.tsv"

[ "$(rc_of ncz_verify_build_input "$T/pins.tsv" assets/python311/good.tar.gz "$T/good.bin")" = 0 ] \
    && ok "a file matching its pin returns 0" || bad "match did not return 0"

out="$(ncz_verify_build_input "$T/pins.tsv" assets/python311/good.tar.gz "$T/bad.bin" 2>&1)"; rc=$?
[ "$rc" = 1 ] && ok "a mismatched file returns 1" || bad "mismatch returned rc=$rc, wanted 1"
case "$out" in *"!= pinned"*) ok "  the mismatch names both digests" ;; *) bad "mismatch message lacks the digests" "$out" ;; esac

[ "$(rc_of ncz_verify_build_input "$T/pins.tsv" assets/python311/absent.tar.gz "$T/good.bin")" = 2 ] \
    && ok "an unpinned dest returns 2 (warn, do not refuse)" || bad "unpinned dest did not return 2"

[ "$(rc_of ncz_verify_build_input "$T/pins.tsv" assets/python311/good.tar.gz "$T/missing.bin")" = 1 ] \
    && ok "a missing file returns 1" || bad "missing file did not return 1"

[ "$(rc_of ncz_verify_build_input "$T/no-such-pins.tsv" assets/python311/good.tar.gz "$T/good.bin")" = 1 ] \
    && ok "a missing pin file returns 1 (cannot prove anything)" || bad "missing pin file did not return 1"

printf 'commented\tdest\n# amd64\tassets/python311/commented.tar.gz\t%s\t1\tnote\n' "$GOOD_SHA" > "$T/commented.tsv"
[ "$(rc_of ncz_verify_build_input "$T/commented.tsv" assets/python311/commented.tar.gz "$T/good.bin")" = 2 ] \
    && ok "a commented-out row does not count as a pin" || bad "a comment was treated as a pin"


echo "=== the verifier is wired into the real fetcher, not only tested here ==="
FETCH="$HERE/build-python311-assets.sh"
grep -q 'lib/verify-build-input.sh' "$FETCH" && ok "build-python311-assets.sh sources the verifier" || bad "fetch script does not source the verifier"
grep -q 'ncz_verify_build_input "$REPO/manifests/build-inputs.tsv" "assets/python311/$NAME"' "$FETCH" \
    && ok "the CPython tarball is checked against its pin" || bad "CPython download is not pin-checked"
grep -q 'ncz_verify_build_input "$REPO/manifests/build-inputs.tsv" "assets/python311/uv"' "$FETCH" \
    && ok "the uv binary is checked against its pin" || bad "uv is not pin-checked"
grep -q 'refusing an unpinned' "$FETCH" && ok "a mismatch refuses the fetch" || bad "no refusal path"
grep -q 'WARNING: no pin for assets/python311' "$FETCH" && ok "a first vendoring warns instead of failing" || bad "no warn path for first vendoring"

echo "test-verify-build-input: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
