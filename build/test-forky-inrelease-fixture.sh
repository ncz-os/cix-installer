#!/bin/bash
# test-forky-inrelease-fixture.sh -- build/refresh-forky-inrelease-fixture.sh
# generates the pinned-InRelease fixture from the pin and refuses anything that
# does not verify (docs/BUILD-STABILITY.md M4).
#
#   * the real tree: --check accepts the committed fixture, and regenerating it
#     from those bytes is byte-identical (this is the one check that legitimately
#     follows the pin's content: a re-pin replaces the fixture with the script);
#   * an isolated trust root with a throwaway keyring and a SYNTHETIC snapshot id
#     (no dependence on the real pin): a correctly signed InRelease is written
#     and matches the trust metadata;
#   * the checksum assertion: a tampered candidate, a validly signed candidate
#     whose sha256 is not the recorded one, and a short read are refused and
#     nothing is written;
#   * a signer outside signer_keys, a keyring whose sha256 drifted, trust
#     metadata for a different snapshot than release.conf, and a stale --out
#     under --check all fail.
#
# Usage: bash build/test-forky-inrelease-fixture.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
GEN="$ROOT/build/refresh-forky-inrelease-fixture.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1" >&2; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/     /' >&2; }
expect_rc() {  # label want-rc cmd...
    local label="$1" want="$2" rc=0; shift 2
    LAST="$("$@" 2>&1)" || rc=$?
    if [ "$rc" = "$want" ]; then ok "$label (rc=$rc)"; else bad "$label: rc=$rc, wanted $want" "$LAST"; fi
}
for t in gpg gpgv sha256sum cmp; do
    command -v "$t" >/dev/null 2>&1 || { echo "FAIL: required test tool not available: $t" >&2; exit 1; }
done
W="$(mktemp -d "${TMPDIR:-$HOME}/ncz-inrel-test.XXXXXX")"
trap 'rm -rf "$W"' EXIT
sha() { sha256sum "$1" | cut -d' ' -f1; }

# --- the real tree --------------------------------------------------------------------------
REAL="$ROOT/build/testdata/forky-snapshot/InRelease"
expect_rc "real tree: --check accepts the committed pinned InRelease" 0 bash "$GEN" --check
expect_rc "real tree: regenerate from the committed bytes" 0 bash "$GEN" --from "$REAL" --out "$W/real/InRelease"
cmp -s "$REAL" "$W/real/InRelease" && ok "  regenerated fixture is byte-identical" || bad "regenerated fixture differs"

# --- isolated trust root: throwaway keyring, synthetic snapshot id ---------------------------
SYN_PIN=20260101T000000Z
export GNUPGHOME="$W/gnupg"; mkdir -m 700 "$GNUPGHOME"
for who in signer rogue; do
    printf '%%no-protection\nKey-Type: RSA\nKey-Length: 2048\nName-Real: NCZ Fixture %s\nName-Email: %s@ncz.invalid\nExpire-Date: 0\n%%commit\n' "$who" "$who" > "$W/kp.$who"
    gpg --batch --gen-key "$W/kp.$who" >/dev/null 2>&1 || { echo "FAIL: gpg key generation failed" >&2; exit 1; }
done
fpr() { gpg --with-colons --fingerprint "$1@ncz.invalid" 2>/dev/null | awk -F: '/^fpr:/{print $10; exit}'; }
SFPR="$(fpr signer)"; RFPR="$(fpr rogue)"
mkdir -p "$W/src"
printf 'Origin: Debian\nLabel: Debian\nSuite: testing\nCodename: forky\nDate: Thu, 01 Jan 2026 00:00:00 UTC\nSHA256:\n %s 0 main/binary-amd64/Packages\n' "$(printf '' | sha256sum | cut -d' ' -f1)" > "$W/src/Release"
gpg --batch --yes --local-user "$SFPR" --clearsign -o "$W/src/InRelease" "$W/src/Release" >/dev/null 2>&1
sed 's/^Codename: forky/Codename: forkz/' "$W/src/Release" > "$W/src/Release.other"
gpg --batch --yes --local-user "$SFPR" --clearsign -o "$W/src/InRelease.other" "$W/src/Release.other" >/dev/null 2>&1
gpg --batch --yes --local-user "$RFPR" --clearsign -o "$W/src/InRelease.rogue" "$W/src/Release" >/dev/null 2>&1

mkroot() {  # dir inrelease-for-digests [keys...] -- isolated trust root
    local d="$1" ir="$2"; shift 2
    mkdir -p "$d/manifests/keys"
    printf 'NCZ_BASE_NAME="Debian"\nNCZ_BASE_CODENAME="forky"\nNCZ_BASE_MIRROR_SNAPSHOT="%s"\n' "$SYN_PIN" > "$d/release.conf"
    gpg --batch --export "$@" > "$d/manifests/keys/test-keyring.gpg"
    printf 'snapshot\t%s\ncodename\tforky\ninrelease_path\tdists/forky/InRelease\ninrelease_sha256\t%s\ninrelease_size\t%s\nkeyring\tmanifests/keys/test-keyring.gpg\nkeyring_sha256\t%s\nsigner_keys\t%s\n' \
        "$SYN_PIN" "$(sha "$ir")" "$(wc -c < "$ir" | tr -d ' ')" "$(sha "$d/manifests/keys/test-keyring.gpg")" "$SFPR" > "$d/manifests/forky-snapshot.tsv"
}
mkroot "$W/syn" "$W/src/InRelease" "$SFPR"
SOUT="$W/syn/build/testdata/forky-snapshot/InRelease"
expect_rc "synthetic pin: a correctly signed InRelease is generated" 0 bash "$GEN" --root "$W/syn" --from "$W/src/InRelease"
[ -f "$SOUT" ] && [ "$(sha "$SOUT")" = "$(awk -F'\t' '$1=="inrelease_sha256"{print $2}' "$W/syn/manifests/forky-snapshot.tsv")" ] \
    && ok "  written to the root's testdata path with the recorded sha256" || bad "generated fixture missing or wrong sha256"
expect_rc "synthetic pin: --check accepts the generated fixture" 0 bash "$GEN" --root "$W/syn" --check

# checksum assertion on the generator: nothing is written on any refusal
refused() {  # label root from [want-msg]
    local o="$W/out.$RANDOM/InRelease"
    expect_rc "$1" 1 bash "$GEN" --root "$2" --from "$3" --out "$o"
    [ ! -e "$o" ] && ok "  nothing written" || bad "a refused candidate was written to $o"
    if [ -n "${4:-}" ]; then grep -q -- "$4" <<<"$LAST" && ok "  reason: $4" || bad "reason '$4' missing" "$LAST"; fi
}
sed 's/^Suite: testing/Suite: testinG/' "$W/src/InRelease" > "$W/src/InRelease.tampered"
refused "a tampered candidate (same size) FAILS" "$W/syn" "$W/src/InRelease.tampered" "sha256"
refused "a validly signed candidate with a different sha256 FAILS" "$W/syn" "$W/src/InRelease.other"
head -c 100 "$W/src/InRelease" > "$W/src/InRelease.short"
refused "a truncated candidate FAILS" "$W/syn" "$W/src/InRelease.short" "size"

# digests recorded for the tampered bytes: only the signature check can refuse them
mkroot "$W/badsig" "$W/src/InRelease.tampered" "$SFPR"
refused "a candidate matching the digests but with a broken signature FAILS" "$W/badsig" "$W/src/InRelease.tampered" "gpgv rejects"

# signer_keys: the rogue key is in the keyring and the digests match, but it is not a listed signer
mkroot "$W/rogue" "$W/src/InRelease.rogue" "$SFPR" "$RFPR"
refused "a signature by a key outside signer_keys FAILS" "$W/rogue" "$W/src/InRelease.rogue" "not in forky-snapshot.tsv signer_keys"

# keyring drift
mkroot "$W/keydrift" "$W/src/InRelease" "$SFPR"
gpg --batch --export "$SFPR" "$RFPR" > "$W/keydrift/manifests/keys/test-keyring.gpg"
refused "a keyring whose sha256 drifted from the trust metadata FAILS" "$W/keydrift" "$W/src/InRelease" "keyring"

# trust metadata for another snapshot than release.conf
mkroot "$W/stale" "$W/src/InRelease" "$SFPR"
sed -i 's/^NCZ_BASE_MIRROR_SNAPSHOT=.*/NCZ_BASE_MIRROR_SNAPSHOT="20260202T000000Z"/' "$W/stale/release.conf"
refused "forky-snapshot.tsv for a different snapshot than release.conf FAILS" "$W/stale" "$W/src/InRelease" "re-pin the trust metadata"

# malformed pin
mkroot "$W/badpin" "$W/src/InRelease" "$SFPR"
sed -i 's/^NCZ_BASE_MIRROR_SNAPSHOT=.*/NCZ_BASE_MIRROR_SNAPSHOT="20260101T000000Zjunk"/' "$W/badpin/release.conf"
refused "a malformed release.conf pin FAILS" "$W/badpin" "$W/src/InRelease"

# --check on a stale fixture (the previous pin's bytes)
mkdir -p "$W/syn/build/testdata/forky-snapshot"; cp "$W/src/InRelease.other" "$SOUT"
expect_rc "--check FAILS on a fixture that is not the pinned InRelease" 1 bash "$GEN" --root "$W/syn" --check
expect_rc "--check with --from is a usage error" 2 bash "$GEN" --root "$W/syn" --check --from "$W/src/InRelease"

echo
echo "== forky-inrelease-fixture tests: $PASS passed, $FAIL failed =="
[ "$FAIL" = 0 ]
