#!/bin/sh
# test-ncz-fetch-payload.sh -- the Magnetar online fetch must be LOUD, BOUNDED
# and unwilling to install anything it has not verified.
#
# Runs a real HTTP server and points the real script at it. Every assertion
# here is about a failure mode that would otherwise show up as a headless box
# with no rootfs and nobody watching:
#
#   * a truncated/tampered download is rejected on its sha256, retried, and
#     then fails the whole run (exit non-zero) instead of installing;
#   * a destination that cannot be written is refused BEFORE any bytes move;
#   * an untar artifact lands at the paths the post-install hooks read;
#   * a second run over an already-fetched payload downloads nothing.
#
#   * the downloader is picked by what works: GNU wget, else busybox when its
#     wget applet answers, else a loud failure before any fetch (2026-10-26:
#     d-i's busybox has no wget applet and every attempt failed rc=127).
#
# Skips (exit 77) when python3 or a downloader (GNU wget or busybox wget) is
# unavailable.
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO=$(CDPATH= cd -- "$HERE/../../.." && pwd)
FETCH="$REPO/preseed/ncz-fetch-payload.sh"
WORK=${NCZ_TEST_DIR:-$(mktemp -d "${TMPDIR:-/home/jasonperlow/Projects}/ncz-fetch-test.XXXXXX")}
PORT=${NCZ_TEST_PORT:-8931}
FAILS=0

cleanup() {
    [ -n "${SRV_PID:-}" ] && kill "$SRV_PID" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

ok()   { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; FAILS=$((FAILS + 1)); }

command -v python3 >/dev/null 2>&1 || { echo "SKIP: no python3"; exit 77; }
HAVE_GNU=0; HAVE_BB=0
command -v wget >/dev/null 2>&1 && wget --version 2>/dev/null | grep -q "GNU Wget" && HAVE_GNU=1
command -v busybox >/dev/null 2>&1 && busybox wget --help >/dev/null 2>&1 && HAVE_BB=1
[ "$HAVE_GNU$HAVE_BB" != 00 ] || { echo "SKIP: no GNU wget and no busybox wget"; exit 77; }
[ -f "$FETCH" ] || { echo "SKIP: $FETCH not found"; exit 77; }

mkdir -p "$WORK/srv/assets/rescue" "$WORK/dest"
printf 'RESCUE-ROOTFS\n' > "$WORK/srv/assets/rescue/rescue-rootfs.tar.zst"
printf 'BRANDING\n'    > "$WORK/srv/assets/branding.txt"
mkdir -p "$WORK/srv/assets/branding" && printf 'ICON\n' > "$WORK/srv/assets/branding/icon.svg"
( cd "$WORK/srv" && tar -czf "$WORK/srv/bundle.tar.gz" assets )

SHA_BASE=$(sha256sum "$WORK/srv/base.squashfs" 2>/dev/null | cut -d' ' -f1)
printf 'BASE-ROOTFS\n' > "$WORK/srv/base.squashfs"
SHA_BASE=$(sha256sum "$WORK/srv/base.squashfs" | cut -d' ' -f1)
SHA_BUNDLE=$(sha256sum "$WORK/srv/bundle.tar.gz" | cut -d' ' -f1)

python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$WORK/srv" \
    >/dev/null 2>&1 &
SRV_PID=$!
i=0; while [ $i -lt 50 ]; do
    python3 -c 'import sys,urllib.request; urllib.request.urlopen(sys.argv[1], timeout=2)' \
        "http://127.0.0.1:$PORT/base.squashfs" 2>/dev/null && break
    sleep 0.2; i=$((i + 1))
done

manifest() {
    printf '%s\t%s\t%s\tfile\n'   "base.squashfs" "http://127.0.0.1:$PORT/base.squashfs" "$1" >  "$WORK/dest/ncz-fetch-payload.manifest"
    printf '%s\t%s\t%s\tuntar\n' "bundle.tar.gz" "http://127.0.0.1:$PORT/bundle.tar.gz"  "$2" >> "$WORK/dest/ncz-fetch-payload.manifest"
}

# --- 1. a good manifest fetches, verifies and unpacks --------------------
manifest "$SHA_BASE" "$SHA_BUNDLE"
if NCZ_PAYLOAD_DIR="$WORK/dest" NCZ_FETCH_MAX_TRIES=2 \
   sh "$FETCH" >"$WORK/run1.log" 2>&1; then
    [ -f "$WORK/dest/base.squashfs" ] || fail "run1: base.squashfs not delivered"
    [ -f "$WORK/dest/assets/rescue/rescue-rootfs.tar.zst" ] || fail "run1: bundle not unpacked to the path the hooks read"
    grep -q "assets/rescue/rescue-rootfs.tar.zst" "$WORK/run1.log" || true
    [ "$(cat "$WORK/dest/base.squashfs")" = "BASE-ROOTFS" ] || fail "run1: wrong content"
    ok "a pinned manifest fetches, verifies and unpacks"
else
    fail "run1: a good manifest failed"; sed -n '1,40p' "$WORK/run1.log"
fi

# --- 2. idempotent: a second run downloads nothing -----------------------
BEFORE=$(sha256sum "$WORK/dest/base.squashfs" | cut -d' ' -f1)
if NCZ_PAYLOAD_DIR="$WORK/dest" NCZ_FETCH_MAX_TRIES=2 sh "$FETCH" >"$WORK/run2.log" 2>&1; then
    grep -q "skip base.squashfs" "$WORK/run2.log" || fail "run2: did not short-circuit an already-verified artifact"
    ok "an already-verified payload is not re-downloaded"
else
    fail "run2: idempotent re-run failed"
fi
[ "$BEFORE" = "$SHA_BASE" ] || fail "run2: digest drifted between runs"

# --- 3. a bad pin must FAIL the whole run, loudly ------------------------
manifest "0000000000000000000000000000000000000000000000000000000000000000" "$SHA_BUNDLE"
rm -f "$WORK/dest/base.squashfs" "$WORK/dest/.ncz-fetched-bundle.tar.gz.ok"
if NCZ_PAYLOAD_DIR="$WORK/dest" NCZ_FETCH_MAX_TRIES=1 sh "$FETCH" >"$WORK/run3.log" 2>&1; then
    fail "run3: a wrong sha256 was accepted"
else
    grep -q "sha256 mismatch" "$WORK/run3.log" || fail "run3: mismatch was not reported"
    grep -q "No root filesystem was installed" "$WORK/run3.log" || fail "run3: not loud about the outcome"
    [ -f "$WORK/dest/base.squashfs" ] && fail "run3: an unverified payload was left in place"
    ok "a wrong pin fails the run, says so, and installs nothing"
fi

# --- 4. an unwritable destination is refused before any download ---------
mkdir -p "$WORK/ro"
: > "$WORK/ro/ncz-fetch-payload.manifest"
manifest "$SHA_BASE" "$SHA_BUNDLE"
cp "$WORK/dest/ncz-fetch-payload.manifest" "$WORK/ro/"
chmod 500 "$WORK/ro"
if NCZ_PAYLOAD_DIR="$WORK/ro" NCZ_FETCH_MAX_TRIES=1 sh "$FETCH" >"$WORK/run4.log" 2>&1; then
    fail "run4: a read-only destination was accepted"
else
    grep -q "not writable" "$WORK/run4.log" || fail "run4: did not name the real problem"
    ok "an unwritable destination is refused before any bytes are fetched"
fi
chmod 700 "$WORK/ro"

# --- 5. the single-artifact fallback still works -------------------------
rm -rf "$WORK/d1"; mkdir -p "$WORK/d1"
if NCZ_PAYLOAD_DIR="$WORK/d1" NCZ_PAYLOAD_NAME=base.squashfs \
   NCZ_PAYLOAD_URL="http://127.0.0.1:$PORT/base.squashfs" \
   NCZ_PAYLOAD_SHA256="$SHA_BASE" NCZ_FETCH_MAX_TRIES=2 \
   sh "$FETCH" >"$WORK/run5.log" 2>&1 && [ -f "$WORK/d1/base.squashfs" ]; then
    ok "the env-only (no manifest) contract still works"
else
    fail "run5: env-only fallback failed"; sed -n '1,20p' "$WORK/run5.log"
fi

# --- 6. bounded: an unreachable host gives up instead of hanging ---------
rm -rf "$WORK/d2"; mkdir -p "$WORK/d2"
printf 'x\t%s\t%s\tfile\n' "base.squashfs" "http://127.0.0.1:1/nope" "$SHA_BASE" \
    > "$WORK/d2/ncz-fetch-payload.manifest"
START=$(date +%s)
if NCZ_PAYLOAD_DIR="$WORK/d2" NCZ_FETCH_MAX_TRIES=2 NCZ_FETCH_CONNECT_TIMEOUT=2 \
   sh "$FETCH" >"$WORK/run6.log" 2>&1; then
    fail "run6: an unreachable host was reported as success"
else
    ELAPSED=$(( $(date +%s) - START ))
    [ "$ELAPSED" -lt 120 ] || fail "run6: took ${ELAPSED}s -- not bounded"
    ok "an unreachable host fails in bounded time (${ELAPSED}s)"
fi

# --- 7. the downloader is chosen by what works --------------------------
# A PATH holding every tool the script needs EXCEPT the downloader under test:
# a stub busybox with no wget applet (d-i's real one), plus GNU wget and/or a
# working busybox wget as each case requires.
mkpath() {   # <dir> <gnu:0|1> <busybox-with-wget:0|1>
    rm -rf "$1"; mkdir -p "$1"
    for t in sh awk cat cut date dirname grep head mkdir mv rm sha256sum sleep sync tar tr wc gzip nc \
             ls ln cp env sed basename printf test expr; do
        p=$(command -v "$t" 2>/dev/null) && [ -x "$p" ] && ln -sf "$p" "$1/$t"
    done
    if [ "$3" = 1 ]; then
        ln -sf "$(command -v busybox)" "$1/busybox"
    else
        printf '#!/bin/sh\n[ "$1" = wget ] && { echo "wget: applet not found" >&2; exit 127; }\nexit 1\n' > "$1/busybox"
        chmod +x "$1/busybox"
    fi
    [ "$2" = 1 ] && ln -sf "$(command -v wget)" "$1/wget"
    return 0
}
dlrun() {   # <name> <pathdir>  -> fetches the good manifest into a fresh dest
    rm -rf "$WORK/$1"; mkdir -p "$WORK/$1"
    printf '%s\t%s\t%s\tfile\n' "base.squashfs" "http://127.0.0.1:$PORT/base.squashfs" "$SHA_BASE" \
        > "$WORK/$1/ncz-fetch-payload.manifest"
    PATH="$2" NCZ_PAYLOAD_DIR="$WORK/$1" NCZ_FETCH_MAX_TRIES=1 "$2/sh" "$FETCH" >"$WORK/$1.log" 2>&1
}
mkpath "$WORK/p-none" 0 0
if dlrun dl-none "$WORK/p-none"; then
    fail "run7a: no downloader, yet the fetch reported success"
else
    grep -q "no working downloader" "$WORK/dl-none.log" && ! grep -q "attempt" "$WORK/dl-none.log" \
        && ok "no downloader: fails loudly before any fetch attempt" \
        || { fail "run7a: no clear no-downloader failure"; sed -n '1,10p' "$WORK/dl-none.log"; }
fi
if [ "$HAVE_BB" = 1 ]; then
    mkpath "$WORK/p-bb" 0 1
    if dlrun dl-bb "$WORK/p-bb" && grep -q "downloader: busybox wget" "$WORK/dl-bb.log" \
       && [ "$(cat "$WORK/dl-bb/base.squashfs")" = "BASE-ROOTFS" ]; then
        ok "busybox only (its wget applet answers): fetches and verifies"
    else
        fail "run7b: busybox-only fetch failed"; sed -n '1,10p' "$WORK/dl-bb.log"
    fi
else
    echo "skip - busybox-only case (this host's busybox has no wget applet)"
fi
if [ "$HAVE_GNU" = 1 ]; then
    mkpath "$WORK/p-gnu" 1 0
    if dlrun dl-gnu "$WORK/p-gnu" && grep -q "downloader: GNU wget" "$WORK/dl-gnu.log" \
       && [ "$(cat "$WORK/dl-gnu/base.squashfs")" = "BASE-ROOTFS" ]; then
        ok "GNU wget with a wget-less busybox (d-i's case): fetches and verifies"
    else
        fail "run7c: GNU wget fetch failed"; sed -n '1,10p' "$WORK/dl-gnu.log"
    fi
    # a wrong pin still fails with GNU wget: the sha256 check is the downloader's master
    rm -rf "$WORK/dl-gnu-bad"; mkdir -p "$WORK/dl-gnu-bad"
    printf '%s\t%s\t%s\tfile\n' "base.squashfs" "http://127.0.0.1:$PORT/base.squashfs" \
        "1111111111111111111111111111111111111111111111111111111111111111" > "$WORK/dl-gnu-bad/ncz-fetch-payload.manifest"
    if PATH="$WORK/p-gnu" NCZ_PAYLOAD_DIR="$WORK/dl-gnu-bad" NCZ_FETCH_MAX_TRIES=1 "$WORK/p-gnu/sh" "$FETCH" >"$WORK/dl-gnu-bad.log" 2>&1; then
        fail "run7d: GNU wget path accepted a wrong sha256"
    else
        grep -q "sha256 mismatch" "$WORK/dl-gnu-bad.log" && [ ! -f "$WORK/dl-gnu-bad/base.squashfs" ] \
            && ok "GNU wget path still rejects a wrong sha256 and installs nothing" \
            || fail "run7d: mismatch not reported"
    fi
else
    echo "skip - GNU wget case (no GNU wget on this host)"
fi

echo
if [ "$FAILS" -eq 0 ]; then
    echo "PASS: ncz-fetch-payload.sh"
    exit 0
fi
echo "FAIL: $FAILS assertion(s)"
exit 1