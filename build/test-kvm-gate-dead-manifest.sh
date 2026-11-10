#!/bin/sh
# test-kvm-gate-dead-manifest.sh -- the server-offline-negative gate set needs
# the pinned payload source DEAD. In online mode the medium's
# ncz-fetch-payload.manifest pins a LIVE published URL, so "the payload server
# is OFF" does not make the guest fail: the negative contract ("the fetcher
# gives up loud and bounded, nothing installed") would never be exercised.
# build/kvm-gate-dead-manifest.sh rewrites the manifest inside the run's image
# copy to a refused endpoint (default http://10.0.2.2:1) before boot; this test
# proves the rewrite round-trips through a real ext4 image, preserves names,
# sha256s and modes, removes the live pins, and that the rewritten manifest
# actually makes the real fetcher fail loudly (both directions).
#
# Skips (exit 77) when debugfs or mkfs.ext4 is unavailable.
set -u

HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
REPO=$(CDPATH='' cd -- "$HERE/.." && pwd)
REWRITE="$HERE/kvm-gate-dead-manifest.sh"
FETCH="$REPO/preseed/ncz-fetch-payload.sh"
DEBUGFS=${DEBUGFS:-$(command -v debugfs 2>/dev/null || echo /usr/sbin/debugfs)}
WORK=${NCZ_TEST_DIR:-$(mktemp -d "${TMPDIR:-/home/jasonperlow/Projects}/ncz-dead-manifest-test.XXXXXX")}
FAILS=0

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

ok()   { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; FAILS=$((FAILS + 1)); }

[ -x "$DEBUGFS" ] || { echo "SKIP: no debugfs"; exit 77; }
command -v mkfs.ext4 >/dev/null 2>&1 || { echo "SKIP: no mkfs.ext4"; exit 77; }
# the subject is part of this change: a missing script is a FAIL, not a skip
[ -f "$REWRITE" ] || { echo "FAIL - $REWRITE not found (the rewriter is missing)"; exit 1; }
[ -f "$FETCH" ] || { echo "SKIP: $FETCH not found"; exit 77; }

# --- fixture: a real ext4 with a real-shaped manifest --------------------
mkdir -p "$WORK/fix/ncz-payload"
printf '%s\t%s\t%s\tfile\n' \
    "base.squashfs" \
    "https://pub-d7b784e01679403d9c70fcd23fff5b96.r2.dev/payload/20261108-9937de3c/base.squashfs" \
    "7c83fc8fa237689a0dfd1bf6c770147e169b543571d559769c66c5cc37392809" > "$WORK/fix/ncz-payload/ncz-fetch-payload.manifest"
printf '%s\t%s\t%s\tuntar\n' \
    "ncz-assets-amd64.tar.gz" \
    "https://pub-d7b784e01679403d9c70fcd23fff5b96.r2.dev/payload/20261108-9937de3c/ncz-assets-amd64.tar.gz" \
    "de86950a656c695ef8c80ea0b3c75b98cd08d888117d67c72c35cb6494566d26" >> "$WORK/fix/ncz-payload/ncz-fetch-payload.manifest"
printf '%s\t%s\t%s\tfile\n' \
    "ncz-pool-amd64.tar.gz" \
    "http://10.0.2.2:8765/no-path" \
    "54fc8e93425e0b953ff36d71c516dd876499359093795e6e2bd3d860e930fe56" >> "$WORK/fix/ncz-payload/ncz-fetch-payload.manifest"
cp "$WORK/fix/ncz-payload/ncz-fetch-payload.manifest" "$WORK/manifest.orig"
truncate -s 8M "$WORK/fix.raw" 2>/dev/null || dd if=/dev/zero of="$WORK/fix.raw" bs=1M count=8 2>/dev/null
mkfs.ext4 -q -F -d "$WORK/fix" "$WORK/fix.raw" 2>/dev/null \
    || { echo "SKIP: mkfs.ext4 -d failed"; exit 77; }

# --- 1. rewrite round-trips through the ext4 image ----------------------
if sh "$REWRITE" "$WORK/fix.raw" >/dev/null 2>&1; then
    "$DEBUGFS" -R "dump ncz-payload/ncz-fetch-payload.manifest $WORK/manifest.new" \
        "$WORK/fix.raw" >/dev/null 2>&1
    if [ -s "$WORK/manifest.new" ]; then
        ok "the rewrite runs and the manifest is still readable inside the image"
    else
        fail "run1: the rewritten manifest vanished from the image"
    fi
else
    fail "run1: the rewriter exited non-zero"
fi

# --- 2. every URL is dead; names, sha256s and modes are preserved --------
if [ -s "$WORK/manifest.new" ]; then
    # awk, not grep: the URL field must now name the refused endpoint only.
    _deadok=$(awk -F'\t' '$2 !~ /^http:\/\/10\.0\.2\.2:1(\/|$)/ {n++} END {print n+0}' "$WORK/manifest.new")
    if [ "$_deadok" = 0 ]; then
        ok "every pinned URL points at the refused endpoint (no live pin survives)"
    else
        fail "run2: live or wrong-base URLs survived ($_deadok rows)"; sed -n '1,5p' "$WORK/manifest.new"
    fi
    # fields 1, 3, 4 must be byte-identical to the original rows
    cut -f1,3,4 "$WORK/manifest.orig" > "$WORK/keys.orig"
    cut -f1,3,4 "$WORK/manifest.new" > "$WORK/keys.new"
    if diff "$WORK/keys.orig" "$WORK/keys.new" >/dev/null 2>&1; then
        ok "names, sha256s and modes are preserved entry-by-entry"
    else
        fail "run2: non-URL fields changed"; diff "$WORK/keys.orig" "$WORK/keys.new" | head -6
    fi
fi

# --- 3. the rewritten manifest makes the REAL fetcher fail loudly --------
# (red-first proof in the other direction: a dead pin is not a silent skip.)
if command -v wget >/dev/null 2>&1 && wget --version 2>/dev/null | grep -q "GNU Wget"; then
    mkdir -p "$WORK/dest/ncz-payload"
    # fastest possible dead endpoint: loopback port 1 (nothing listens)
    sh "$REWRITE" "$WORK/fix.raw" "http://127.0.0.1:1" >/dev/null 2>&1
    "$DEBUGFS" -R "dump ncz-payload/ncz-fetch-payload.manifest $WORK/manifest.loop" \
        "$WORK/fix.raw" >/dev/null 2>&1
    cp "$WORK/manifest.loop" "$WORK/dest/ncz-fetch-payload.manifest"
    if NCZ_PAYLOAD_DIR="$WORK/dest" NCZ_FETCH_MAX_TRIES=1 NCZ_FETCH_CONNECT_TIMEOUT=3 \
        sh "$FETCH" >"$WORK/fetch.log" 2>&1; then
        fail "run3: the fetcher SUCCEEDED against a dead pin"
    else
        grep -qE '\[FETCH\] (HARD FAIL|FATAL)' "$WORK/fetch.log" \
            && ok "a dead pin fails the run loudly ([FETCH] HARD FAIL/FATAL)" \
            || { fail "run3: dead pin failed silently"; sed -n '1,12p' "$WORK/fetch.log"; }
    fi
else
    echo "skip - dead-pin fetch case (no GNU wget on this host)"
fi

echo
if [ "$FAILS" -eq 0 ]; then
    echo "PASS: kvm-gate-dead-manifest.sh"
    exit 0
fi
echo "FAIL: $FAILS assertion(s)"
exit 1
