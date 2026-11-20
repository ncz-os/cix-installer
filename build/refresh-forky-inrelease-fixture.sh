#!/bin/bash
# refresh-forky-inrelease-fixture.sh -- (re)generate the pinned-InRelease test
# fixture build/testdata/forky-snapshot/InRelease FROM THE PIN, never by hand
# (docs/BUILD-STABILITY.md M4, failure class C4).
#
# build/test-no-ubuntu.sh verifies that the PRODUCTION keyring accepts the real
# signed Debian InRelease of the pinned snapshot.  That file cannot be
# synthesized (it carries Debian's signature), so it is a pin-bound artifact:
# on a re-pin it is replaced by this script, not edited in a test.  The script
# writes nothing unless the candidate bytes pass every assertion:
#
#   * release.conf has exactly one well-formed NCZ_BASE_MIRROR_SNAPSHOT
#     (ncz_pin_snapshot), and manifests/forky-snapshot.tsv `snapshot` equals it
#     (stale trust metadata is refused, not papered over);
#   * the committed keyring's sha256 equals forky-snapshot.tsv keyring_sha256;
#   * the candidate's size and sha256 equal inrelease_size/inrelease_sha256
#     (the checksum assertion on the generator);
#   * gpgv with that keyring reports VALIDSIG, and every VALIDSIG signing key
#     is listed in signer_keys (at least one).
#
# Usage: build/refresh-forky-inrelease-fixture.sh [--root DIR] [--from FILE|URL] [--out FILE] [--check]
#   (default)  fetch <pinned snapshot>/<inrelease_path> from snapshot.debian.org,
#              verify, and atomically write --out
#              (default DIR/build/testdata/forky-snapshot/InRelease).
#   --from     use a local file (or another URL) as the candidate instead.
#   --check    verify the existing --out against the pin; no fetch, no write.
#   --root     the tree whose release.conf/manifests are the trust root
#              (default: this checkout).  Used by the tests' isolated roots.
# Exit: 0 ok, 1 verification failed (nothing written), 2 usage/tool error.
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
FROM="" OUT="" CHECK=0
while [ $# -gt 0 ]; do
    case "$1" in
        --root)  ROOT="${2:?--root needs a directory}"; shift 2 ;;
        --from)  FROM="${2:?--from needs a file or URL}"; shift 2 ;;
        --out)   OUT="${2:?--out needs a file}"; shift 2 ;;
        --check) CHECK=1; shift ;;
        -h|--help) sed -n '2,29p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "usage: $0 [--root DIR] [--from FILE|URL] [--out FILE] [--check]" >&2; exit 2 ;;
    esac
done
[ "$CHECK" = 1 ] && [ -n "$FROM" ] && { echo "ERROR: --check verifies --out; it takes no --from" >&2; exit 2; }
for t in gpgv sha256sum; do
    command -v "$t" >/dev/null 2>&1 || { echo "ERROR: required tool not found: $t" >&2; exit 2; }
done
fail() { echo "FAIL: $*" >&2; exit 1; }

# shellcheck source=build/lib/mirror-apt-opts.sh
. "$HERE/lib/mirror-apt-opts.sh"
PIN="$(ncz_pin_snapshot "$ROOT")" || fail "$ROOT/release.conf has no single well-formed NCZ_BASE_MIRROR_SNAPSHOT"
TSV="$ROOT/manifests/forky-snapshot.tsv"
[ -f "$TSV" ] || fail "missing $TSV"
tsv() { awk -F'\t' -v k="$1" '$1==k{print $2; n++} END{exit n==1?0:1}' "$TSV"; }
SNAP="$(tsv snapshot)"            || fail "forky-snapshot.tsv: no single 'snapshot' row"
REL="$(tsv inrelease_path)"       || fail "forky-snapshot.tsv: no single 'inrelease_path' row"
WANT_SHA="$(tsv inrelease_sha256)" || fail "forky-snapshot.tsv: no single 'inrelease_sha256' row"
WANT_SIZE="$(tsv inrelease_size)"  || fail "forky-snapshot.tsv: no single 'inrelease_size' row"
KEYREL="$(tsv keyring)"           || fail "forky-snapshot.tsv: no single 'keyring' row"
KEY_SHA="$(tsv keyring_sha256)"   || fail "forky-snapshot.tsv: no single 'keyring_sha256' row"
SIGNERS="$(tsv signer_keys)"      || fail "forky-snapshot.tsv: no single 'signer_keys' row"
[ "$SNAP" = "$PIN" ] || fail "forky-snapshot.tsv snapshot '$SNAP' != release.conf pin '$PIN' (re-pin the trust metadata first)"
case "$WANT_SHA" in *[!0-9a-f]*|"") fail "forky-snapshot.tsv inrelease_sha256 is not a hex digest" ;; esac
[ "${#WANT_SHA}" = 64 ] || fail "forky-snapshot.tsv inrelease_sha256 is not 64 hex digits"
case "$WANT_SIZE" in *[!0-9]*|"") fail "forky-snapshot.tsv inrelease_size is not a number" ;; esac
case "$REL" in /*|*..*) fail "forky-snapshot.tsv inrelease_path '$REL' is not a relative archive path" ;; esac
KEYRING="$ROOT/$KEYREL"
[ -f "$KEYRING" ] || fail "keyring $KEYRING missing"
[ "$(sha256sum "$KEYRING" | cut -d' ' -f1)" = "$KEY_SHA" ] || fail "keyring $KEYREL sha256 != forky-snapshot.tsv keyring_sha256"
OUT="${OUT:-$ROOT/build/testdata/forky-snapshot/InRelease}"

W="$(mktemp -d "${TMPDIR:-$HOME}/ncz-inrel-fixture.XXXXXX")" || exit 2
trap 'rm -rf "$W"' EXIT

verify() {  # file -- the checksum + signature assertions
    local f="$1" got sig n=0 fpr
    [ -f "$f" ] || fail "candidate $f does not exist"
    got="$(wc -c < "$f" | tr -d ' ')"
    [ "$got" = "$WANT_SIZE" ] || fail "candidate size $got != forky-snapshot.tsv inrelease_size $WANT_SIZE"
    got="$(sha256sum "$f" | cut -d' ' -f1)"
    [ "$got" = "$WANT_SHA" ] || fail "candidate sha256 $got != forky-snapshot.tsv inrelease_sha256 $WANT_SHA"
    [ -d "$W/gnupg" ] || mkdir -m 700 "$W/gnupg"
    sig="$(GNUPGHOME="$W/gnupg" gpgv --status-fd 1 --keyring "$KEYRING" "$f" 2>/dev/null)" \
        || fail "gpgv rejects the candidate with keyring $KEYREL"
    while read -r fpr; do
        n=$((n + 1))
        case " $SIGNERS " in *" $fpr "*) ;; *) fail "signed by $fpr, which is not in forky-snapshot.tsv signer_keys" ;; esac
    done < <(printf '%s\n' "$sig" | awk '$1=="[GNUPG:]" && $2=="VALIDSIG"{print $3}')
    [ "$n" -gt 0 ] || fail "gpgv reported no VALIDSIG"
}

if [ "$CHECK" = 1 ]; then
    verify "$OUT"
    echo "ok: $OUT is the signed InRelease of pin $PIN ($WANT_SIZE bytes, sha256 $WANT_SHA)"
    exit 0
fi

CAND="$W/InRelease"
SRC="${FROM:-https://snapshot.debian.org/archive/debian/$PIN/$REL}"
case "$SRC" in
    http://*|https://*)
        command -v curl >/dev/null 2>&1 || { echo "ERROR: curl is needed to fetch $SRC" >&2; exit 2; }
        curl -sfL --max-time 120 -o "$CAND" "$SRC" || fail "could not fetch $SRC" ;;
    *)  cp -- "$SRC" "$CAND" 2>/dev/null || fail "cannot read $SRC" ;;
esac
verify "$CAND"
mkdir -p "$(dirname "$OUT")" || exit 2
tmp="$(mktemp "$(dirname "$OUT")/.InRelease.XXXXXX")" || exit 2
cp -- "$CAND" "$tmp" && chmod 644 "$tmp" && mv -f -- "$tmp" "$OUT" || { rm -f "$tmp"; echo "ERROR: could not write $OUT" >&2; exit 2; }
echo "wrote $OUT: signed InRelease of pin $PIN ($WANT_SIZE bytes, sha256 $WANT_SHA)"
