#!/bin/bash
# test-no-pin-literals.sh -- no test or test fixture hard-codes the current
# Debian snapshot pin (docs/BUILD-STABILITY.md M4, failure class C4).
#
# A re-pin changes release.conf NCZ_BASE_MIRROR_SNAPSHOT (and the manifests that
# must agree with it).  It must never need a test edit: tests read the pin from
# release.conf (ncz_pin_snapshot) and the manifests at run time, and fixtures
# that need a snapshot id use a synthetic one.  This lint fails if the value of
# NCZ_BASE_MIRROR_SNAPSHOT appears literally in any build/test-*.sh or in any
# file under build/testdata/.
#
#   * the real tree passes, and the scan covers a non-empty file set;
#   * a fixture tree whose test (or testdata file) carries the current pin
#     literal fails and names the file;
#   * the pin in a non-test build script, or a different (synthetic) snapshot id
#     in a test, is not a finding;
#   * a release.conf without exactly one well-formed pin fails closed (an empty
#     pattern must not pass vacuously).
#
# Usage: bash build/test-no-pin-literals.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1" >&2; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/     /' >&2; }
W="$(mktemp -d "${TMPDIR:-$HOME}/ncz-pinlit.XXXXXX")"
trap 'rm -rf "$W"' EXIT
# shellcheck source=build/lib/mirror-apt-opts.sh
. "$ROOT/build/lib/mirror-apt-opts.sh"

# scan_pin_literals ROOT -- rc 0 clean, 1 findings (printed), 2 no valid pin.
# Prints "scanned N" on stderr so callers can reject a vacuous pass.
scan_pin_literals() {
    local root="$1" pin f n=0 hits=0
    pin="$(ncz_pin_snapshot "$root")" || { echo "no valid NCZ_BASE_MIRROR_SNAPSHOT in $root/release.conf" >&2; return 2; }
    [ -n "$pin" ] || return 2
    while IFS= read -r -d '' f; do
        n=$((n + 1))
        if grep -qF -- "$pin" "$f"; then
            hits=$((hits + 1))
            grep -nF -- "$pin" "$f" | sed "s|^|${f#"$root"/}:|"
        fi
    done < <({ find "$root/build" -maxdepth 1 -type f -name 'test-*.sh' -print0
               [ -d "$root/build/testdata" ] && find "$root/build/testdata" -type f -print0; } 2>/dev/null)
    echo "scanned $n" >&2
    [ "$hits" = 0 ]
}

run() {  # label want-rc root
    local label="$1" want="$2" rc=0
    OUT="$(scan_pin_literals "$3" 2>"$W/err")" || rc=$?
    ERR="$(cat "$W/err")"
    if [ "$rc" = "$want" ]; then ok "$label (rc=$rc)"; else bad "$label: rc=$rc, wanted $want" "$(printf '%s\n%s' "$OUT" "$ERR")"; fi
}

PIN="$(ncz_pin_snapshot "$ROOT")" || { echo "FAIL: release.conf has no valid snapshot pin" >&2; exit 1; }

# --- the real tree ------------------------------------------------------------------------
run "no build/test-*.sh or build/testdata file carries the current pin literal" 0 "$ROOT"
n="$(sed -n 's/^scanned //p' <<<"$ERR")"
[ "${n:-0}" -gt 100 ] && ok "the scan covered $n files (not vacuous)" || bad "scan covered only ${n:-0} files"

# --- fixture trees ------------------------------------------------------------------------
mkfix() {  # dir -- a minimal tree with the REAL release.conf (so the current pin)
    mkdir -p "$1/build/testdata/sub"
    cp "$ROOT/release.conf" "$1/"
    printf '#!/bin/bash\necho clean\n' > "$1/build/test-clean.sh"
    printf 'clean fixture\n' > "$1/build/testdata/sub/data.txt"
}
mkfix "$W/clean"
run "control: a clean fixture tree passes" 0 "$W/clean"

mkfix "$W/lit-test"
printf '[ "$(ncz_pin_snapshot)" = "%s" ]\n' "$PIN" >> "$W/lit-test/build/test-clean.sh"
run "a test carrying the current pin literal FAILS" 1 "$W/lit-test"
grep -q '^build/test-clean.sh:3:' <<<"$OUT" && ok "  finding names build/test-clean.sh:3" || bad "finding does not name the file/line" "$OUT"

mkfix "$W/lit-url"
printf 'M=https://snapshot.debian.org/archive/debian/%s\n' "$PIN" >> "$W/lit-url/build/test-clean.sh"
run "a test carrying the pinned snapshot URL FAILS" 1 "$W/lit-url"

mkfix "$W/lit-data"
printf 'snapshot\t%s\n' "$PIN" > "$W/lit-data/build/testdata/sub/pin.tsv"
run "a testdata file carrying the current pin literal FAILS" 1 "$W/lit-data"
grep -q '^build/testdata/sub/pin.tsv:1:' <<<"$OUT" && ok "  finding names build/testdata/sub/pin.tsv" || bad "finding does not name the testdata file" "$OUT"

mkfix "$W/nontest"
printf 'PIN=%s\n' "$PIN" > "$W/nontest/build/pin-helper.sh"
run "the pin in a non-test build script is not a finding" 0 "$W/nontest"

mkfix "$W/synthetic"
printf 'printf %s\n' "'NCZ_BASE_MIRROR_SNAPSHOT=\"20260101T000000Z\"'" >> "$W/synthetic/build/test-clean.sh"
if [ "$PIN" != 20260101T000000Z ]; then
    run "a synthetic (non-pin) snapshot id in a test is not a finding" 0 "$W/synthetic"
else
    bad "the real pin equals the synthetic fixture id; pick another synthetic id"
fi

mkfix "$W/nopin"
sed -i '/^NCZ_BASE_MIRROR_SNAPSHOT=/d' "$W/nopin/release.conf"
run "no pin in release.conf fails closed" 2 "$W/nopin"
mkfix "$W/badpin"
sed -i 's/^NCZ_BASE_MIRROR_SNAPSHOT=.*/NCZ_BASE_MIRROR_SNAPSHOT=""/' "$W/badpin/release.conf"
run "an empty pin fails closed (no vacuous empty-pattern scan)" 2 "$W/badpin"

echo
echo "== no-pin-literals tests: $PASS passed, $FAIL failed =="
[ "$FAIL" = 0 ]
