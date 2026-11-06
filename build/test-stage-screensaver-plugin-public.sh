#!/bin/bash
# test-stage-screensaver-plugin-public.sh -- offline tests for the public
# fallback path of build/stage-screensaver-plugin.sh.
#
# These tests never touch the network: a stub `curl` is placed first on PATH
# and records its argv, and the "published" debs are real tiny dpkg-deb
# packages built in a scratch dir. The lock file used by the tests is a
# fixture whose SHA256 values are computed from those packages at runtime.
#
# Skips (77) when dpkg-deb is unavailable. Uses $TMPDIR (already owned by the
# caller / Projects) and never writes outside it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAGE="$ROOT/build/stage-screensaver-plugin.sh"

if ! command -v dpkg-deb >/dev/null 2>&1; then
    echo "SKIP: dpkg-deb not available" >&2
    exit 77
fi

TMPDIR="${TMPDIR:-/tmp}"
WORK="$(mktemp -d "$TMPDIR/ncz-ssplugin-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok - $*"; }

# ---------------------------------------------------------------------------
# Fixtures: build tiny real debs for amd64 and arm64.
# ---------------------------------------------------------------------------
build_deb() {
    # build_deb OUTDIR ARCH VERSION MAINTAINER -> prints path to .deb
    local outdir="$1" arch="$2" version="$3" maint="$4"
    local pkg="ncz-screensavers-plugin"
    local d="$outdir/build-$arch"
    rm -rf "$d"; mkdir -p "$d/DEBIAN" "$d/usr/share/ncz-screensavers-plugin"
    cat > "$d/DEBIAN/control" <<EOF
Package: $pkg
Version: $version
Architecture: $arch
Maintainer: $maint
Description: test fixture
EOF
    echo "fixture $arch $version" > "$d/usr/share/ncz-screensavers-plugin/README"
    local deb="$outdir/${pkg}_${version}_${arch}.deb"
    dpkg-deb --build --root-owner-group "$d" "$deb" >/dev/null
    printf '%s' "$deb"
}

sha256_of() { sha256sum "$1" | awk '{print $1}'; }

MAINT="Jason Perlow <jperlow@gmail.com>"
VERSION="0.3.23"
PKG="ncz-screensavers-plugin"

FIX="$WORK/fixtures"
mkdir -p "$FIX"
DEB_AMD64="$(build_deb "$FIX" amd64 "$VERSION" "$MAINT")"
DEB_ARM64="$(build_deb "$FIX" arm64 "$VERSION" "$MAINT")"
SHA_AMD64="$(sha256_of "$DEB_AMD64")"
SHA_ARM64="$(sha256_of "$DEB_ARM64")"

# Fixture lock file with dynamic SHAs.
LOCK="$WORK/fixture.lock"
cat > "$LOCK" <<EOF
NCZ_SSPLUGIN_PKG=$PKG
NCZ_SSPLUGIN_VERSION=$VERSION
NCZ_SSPLUGIN_MAINTAINER="$MAINT"
NCZ_SSPLUGIN_STORE_DIR=$VERSION
NCZ_SSPLUGIN_SOURCE="test fixture"
NCZ_SSPLUGIN_SHA256_amd64=$SHA_AMD64
NCZ_SSPLUGIN_SHA256_arm64=$SHA_ARM64
NCZ_SSPLUGIN_PAYLOAD_amd64=testpayload-amd64
NCZ_SSPLUGIN_PAYLOAD_arm64=testpayload-arm64
NCZ_SSPLUGIN_ABI_LIB=/opt/singularity/lib/libsingularity.so.0
NCZ_SSPLUGIN_LIBSINGULARITY_SHA256_amd64=$(printf 'a%.0s' $(seq 1 64))
NCZ_SSPLUGIN_LIBSINGULARITY_SHA256_arm64=$(printf 'b%.0s' $(seq 1 64))
EOF

# ---------------------------------------------------------------------------
# Stub curl: records argv, serves files from a directory, or fails.
# ---------------------------------------------------------------------------
STUB="$WORK/stub"
mkdir -p "$STUB"
CURL_LOG="$WORK/curl.log"
CURL_SERVE="$WORK/serve"
mkdir -p "$CURL_SERVE"
CURL_MODE="ok"   # ok | fail
cat > "$STUB/curl" <<'STUBEOF'
#!/bin/bash
# stub curl: log argv, then either copy the last arg's basename from
# $CURL_SERVE to the -o/--output target, or exit 22.
printf '%s\n' "$*" >> "$CURL_LOG"
out=""
prev=""
for a in "$@"; do
    if [ "$prev" = "-o" ] || [ "$prev" = "--output" ]; then out="$a"; fi
    prev="$a"
done
if [ "${CURL_MODE:-ok}" = "fail" ]; then
    exit 22
fi
base="$(basename "$out")"
# The stub is given the URL as the last argument; derive the served file from
# the URL basename.
url=""
for a in "$@"; do
    case "$a" in https://*) url="$a" ;; esac
done
[ -n "$url" ] || { echo "stub curl: no url" >&2; exit 2; }
served="$CURL_SERVE/$(basename "$url")"
[ -f "$served" ] || { echo "stub curl: no served file for $url" >&2; exit 22; }
cp "$served" "$out"
STUBEOF
chmod +x "$STUB/curl"
export CURL_LOG CURL_SERVE CURL_MODE

# ---------------------------------------------------------------------------
# Helper: run the stage script with a controlled environment.
# ---------------------------------------------------------------------------
run_stage() {
    # run_stage SRC_ROOT OUT [ARCH...]
    local src="$1" out="$2"; shift 2
    PATH="$STUB:$PATH" \
    NCZ_SSPLUGIN_LOCK="$LOCK" \
    NCZ_SSPLUGIN_SRC_ROOT="$src" \
    NCZ_SSPLUGIN_OUT="$out" \
    bash "$STAGE" "$@"
}

# ===========================================================================
# Test 1: valid local store -> no network fetch.
# ===========================================================================
T1="$WORK/t1"; mkdir -p "$T1/store/$VERSION" "$T1/out"
cp "$DEB_AMD64" "$T1/store/$VERSION/${PKG}_${VERSION}_amd64.deb"
: > "$CURL_LOG"
if ! run_stage "$T1/store" "$T1/out" amd64 >/dev/null 2>&1; then
    fail "t1: stage failed with valid local store"
fi
[ -s "$T1/out/${PKG}_${VERSION}_amd64.deb" ] || fail "t1: deb not staged"
[ ! -s "$CURL_LOG" ] || fail "t1: curl was invoked despite valid local store"
pass "valid local store: no network fetch"

# ===========================================================================
# Test 2: missing local file -> fetch exact public URL with required flags.
# ===========================================================================
T2="$WORK/t2"; mkdir -p "$T2/store" "$T2/out"
cp "$DEB_AMD64" "$CURL_SERVE/${PKG}_${VERSION}_amd64.deb"
: > "$CURL_LOG"
if ! run_stage "$T2/store" "$T2/out" amd64 >/dev/null 2>&1; then
    fail "t2: stage failed on public fallback"
fi
[ -s "$T2/out/${PKG}_${VERSION}_amd64.deb" ] || fail "t2: deb not staged from public"
[ "$(sha256_of "$T2/out/${PKG}_${VERSION}_amd64.deb")" = "$SHA_AMD64" ] || fail "t2: staged sha mismatch"
log="$(cat "$CURL_LOG")"
case "$log" in
    *"https://packages.buildkite.com/ncz-os/ncz/any/pool/any/main/n/ncz-screensavers-plugin/${PKG}_${VERSION}_amd64.deb"*) ;;
    *) fail "t2: curl did not request the exact public URL: $log" ;;
esac
case "$log" in *"--proto =https"*) ;; *) fail "t2: missing --proto =https" ;; esac
case "$log" in *"--proto-redir =https"*) ;; *) fail "t2: missing --proto-redir =https" ;; esac
case "$log" in *"--fail"*) ;; *) fail "t2: missing --fail" ;; esac
case "$log" in *"--location"*) ;; *) fail "t2: missing --location" ;; esac
case "$log" in *"--connect-timeout 10"*) ;; *) fail "t2: missing --connect-timeout 10" ;; esac
case "$log" in *"--max-time 60"*) ;; *) fail "t2: missing --max-time 60" ;; esac
pass "missing local: fetch exact public URL with required flags"

# ===========================================================================
# Test 3: bad public hash -> fail, prior OUTPUT preserved, temp cleaned.
# ===========================================================================
T3="$WORK/t3"; mkdir -p "$T3/store" "$T3/out"
# Pre-existing good deb in OUT (prior output).
cp "$DEB_AMD64" "$T3/out/${PKG}_${VERSION}_amd64.deb"
PRIOR_SHA="$(sha256_of "$T3/out/${PKG}_${VERSION}_amd64.deb")"
# Serve a corrupt file (different content, wrong hash).
head -c 100 /dev/urandom > "$CURL_SERVE/${PKG}_${VERSION}_amd64.deb"
: > "$CURL_LOG"
if run_stage "$T3/store" "$T3/out" amd64 >/dev/null 2>&1; then
    fail "t3: stage succeeded with bad public hash"
fi
[ "$(sha256_of "$T3/out/${PKG}_${VERSION}_amd64.deb")" = "$PRIOR_SHA" ] || fail "t3: prior output was clobbered"
# No leftover temp files or stage dirs.
leftover="$(find "$T3/out" -name '*.tmp.*' 2>/dev/null || true)"
[ -z "$leftover" ] || fail "t3: temp files left behind: $leftover"
[ ! -e "$T3/out/.ssplugin-stage"* ] 2>/dev/null || fail "t3: stage dir left behind"
pass "bad public hash: fail, prior output preserved, temp cleaned"

# ===========================================================================
# Test 4: wrong arch with matching hash/control -> reject.
# ===========================================================================
T4="$WORK/t4"; mkdir -p "$T4/store" "$T4/out"
# Serve the arm64 deb under the amd64 filename: hash won't match the amd64 pin.
cp "$DEB_ARM64" "$CURL_SERVE/${PKG}_${VERSION}_amd64.deb"
: > "$CURL_LOG"
if run_stage "$T4/store" "$T4/out" amd64 >/dev/null 2>&1; then
    fail "t4: stage succeeded with wrong-arch deb"
fi
[ ! -s "$T4/out/${PKG}_${VERSION}_amd64.deb" ] || fail "t4: wrong-arch deb was staged"
pass "wrong arch with matching hash: rejected"

# ===========================================================================
# Test 5: unknown arch -> rc 2, no download attempt.
# ===========================================================================
T5="$WORK/t5"; mkdir -p "$T5/store" "$T5/out"
: > "$CURL_LOG"
rc=0
run_stage "$T5/store" "$T5/out" mips >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] || fail "t5: expected rc 2 for unknown arch, got $rc"
[ ! -s "$CURL_LOG" ] || fail "t5: curl was invoked for unknown arch"
pass "unknown arch: rc 2, no download attempt"

# ===========================================================================
# Test 6: corrupt local file -> fail without public fallback.
# ===========================================================================
T6="$WORK/t6"; mkdir -p "$T6/store/$VERSION" "$T6/out"
head -c 100 /dev/urandom > "$T6/store/$VERSION/${PKG}_${VERSION}_amd64.deb"
# Serve a valid file publicly; it must NOT be used.
cp "$DEB_AMD64" "$CURL_SERVE/${PKG}_${VERSION}_amd64.deb"
: > "$CURL_LOG"
if run_stage "$T6/store" "$T6/out" amd64 >/dev/null 2>&1; then
    fail "t6: stage succeeded with corrupt local file"
fi
[ ! -s "$CURL_LOG" ] || fail "t6: curl was invoked despite corrupt local file"
[ ! -s "$T6/out/${PKG}_${VERSION}_amd64.deb" ] || fail "t6: corrupt local was staged"
pass "corrupt local: fail without public fallback"

# ===========================================================================
# Test 6b: zero-byte local file -> fail without public fallback.
# ===========================================================================
T6B="$WORK/t6b"; mkdir -p "$T6B/store/$VERSION" "$T6B/out"
: > "$T6B/store/$VERSION/${PKG}_${VERSION}_amd64.deb"
# Serve a valid file publicly; it must NOT be used.
cp "$DEB_AMD64" "$CURL_SERVE/${PKG}_${VERSION}_amd64.deb"
: > "$CURL_LOG"
if run_stage "$T6B/store" "$T6B/out" amd64 >/dev/null 2>&1; then
    fail "t6b: stage succeeded with zero-byte local file"
fi
[ ! -s "$CURL_LOG" ] || fail "t6b: curl was invoked despite zero-byte local file"
[ ! -s "$T6B/out/${PKG}_${VERSION}_amd64.deb" ] || fail "t6b: zero-byte local was staged"
pass "zero-byte corrupt local: fail without public fallback"

# ===========================================================================
# Test 6c: unknown arch mixed with valid arch -> rc 2, no fetch.
# ===========================================================================
T6C="$WORK/t6c"; mkdir -p "$T6C/store" "$T6C/out"
cp "$DEB_AMD64" "$CURL_SERVE/${PKG}_${VERSION}_amd64.deb"
: > "$CURL_LOG"
rc=0
run_stage "$T6C/store" "$T6C/out" amd64 s390x >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] || fail "t6c: expected rc 2 for mixed unknown arch, got $rc"
[ ! -s "$CURL_LOG" ] || fail "t6c: curl was invoked despite unknown arch"
[ ! -s "$T6C/out/${PKG}_${VERSION}_amd64.deb" ] || fail "t6c: staged despite unknown arch"
pass "unknown arch mixed with valid: rc 2, no fetch"

# ===========================================================================
# Test 7: transfer failure -> cleanup, no partial output.
# ===========================================================================
T7="$WORK/t7"; mkdir -p "$T7/store" "$T7/out"
cp "$DEB_AMD64" "$CURL_SERVE/${PKG}_${VERSION}_amd64.deb"
: > "$CURL_LOG"
CURL_MODE=fail
if run_stage "$T7/store" "$T7/out" amd64 >/dev/null 2>&1; then
    CURL_MODE=ok
    fail "t7: stage succeeded despite transfer failure"
fi
CURL_MODE=ok
[ ! -s "$T7/out/${PKG}_${VERSION}_amd64.deb" ] || fail "t7: partial output left behind"
leftover="$(find "$T7/out" -name '*.tmp.*' 2>/dev/null || true)"
[ -z "$leftover" ] || fail "t7: temp files left behind: $leftover"
[ ! -e "$T7/out/.ssplugin-stage"* ] 2>/dev/null || fail "t7: stage dir left behind"
pass "transfer failure: cleanup, no partial output"

# ===========================================================================
# Test 8: idempotent -- identical destination left in place.
# ===========================================================================
T8="$WORK/t8"; mkdir -p "$T8/store/$VERSION" "$T8/out"
cp "$DEB_AMD64" "$T8/store/$VERSION/${PKG}_${VERSION}_amd64.deb"
cp "$DEB_AMD64" "$T8/out/${PKG}_${VERSION}_amd64.deb"
MTIME_BEFORE="$(stat -c %Y "$T8/out/${PKG}_${VERSION}_amd64.deb" 2>/dev/null || stat -f %m "$T8/out/${PKG}_${VERSION}_amd64.deb")"
sleep 1
if ! run_stage "$T8/store" "$T8/out" amd64 >/dev/null 2>&1; then
    fail "t8: stage failed on idempotent run"
fi
MTIME_AFTER="$(stat -c %Y "$T8/out/${PKG}_${VERSION}_amd64.deb" 2>/dev/null || stat -f %m "$T8/out/${PKG}_${VERSION}_amd64.deb")"
[ "$MTIME_BEFORE" = "$MTIME_AFTER" ] || fail "t8: identical destination was rewritten"
pass "idempotent: identical destination left in place"

echo "all tests passed"
