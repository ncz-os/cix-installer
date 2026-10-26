#!/bin/bash
# test-shipped-secret-scan-payload.sh -- scan-shipped-secrets.py --payload scans the
# artifacts a Magnetar (NCZ_VARIANT=server) medium does NOT carry: base.squashfs and
# the asset bundle (a gzip tar) that the installer fetches over the network.
#
# Proves, on real squashfs and tar files built here:
#   - a fake secret planted in a squashfs, in a tar.gz, in a rescue-rootfs tar.zst
#     nested inside a tar.gz, and in a plain/zstd tar is caught (hashed match);
#   - a token shape nobody listed is caught in a tar.gz;
#   - the same artifacts without the secret pass, and the receipt names them;
#   - FAIL CLOSED: random bytes, gzip of a non-tar, an empty file, a directory and a
#     truncated tar.gz all fail; --image and --payload together (or neither) is a
#     usage error.
#
# Usage: bash build/test-shipped-secret-scan-payload.sh    Exit: 0 pass, 1 fail.
# Needs mksquashfs, unsquashfs, tar, gzip, zstd, python3 (all on the build hosts).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FAILS=0
pass() { echo "  ok: $*"; }
fail() { echo "  FAIL: $*" >&2; FAILS=$((FAILS + 1)); }

for t in mksquashfs unsquashfs tar gzip zstd python3; do
    command -v "$t" >/dev/null 2>&1 || { echo "test-shipped-secret-scan-payload: SKIP (missing $t)"; exit 0; }
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ncz-payload-scan-test.XXXXXX")"
cleanup() { chmod -R u+rwX "$WORK" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT
export TMPDIR="$WORK"
export NCZ_SECRET_HASHES_KEY="$WORK/hash.key"
SCAN="$ROOT/build/scan-shipped-secrets.py"
MAKEHASH="$ROOT/build/make-secret-hashes.py"
PY=python3

# assembled at run time so this file carries no literal credential
FAKE="$(printf '%s-%s-%s' 'fake' 'payload' 'credential20261026')"
SHAPE_TOKEN="glpat-$(printf 'B%.0s' {1..24})"

cat > "$WORK/keymaster.json" <<JSON
{"secrets": [{"value": "$FAKE", "label": "fixture-fake-credential"}]}
JSON
$PY "$MAKEHASH" --master "$WORK/keymaster.json" --out "$WORK/hashes.json" --quiet || {
    echo "test-shipped-secret-scan-payload: cannot make the hash list" >&2; exit 1; }

mk_tree() {   # <dir> <clean|leaky|shape>
    local d="$1" mode="$2"
    mkdir -p "$d/etc" "$d/usr/share/doc/x" "$d/assets/rescue"
    printf 'name=ncz\nlevel=3\n' > "$d/etc/app.conf"
    printf 'documentation\n' > "$d/usr/share/doc/x/README"
    ln -s ../etc/app.conf "$d/usr/share/doc/x/link"
    case "$mode" in
        leaky) printf 'token=xy%s;\n' "$FAKE" >> "$d/etc/app.conf" ;;
        shape) printf 'push_token=%s\n' "$SHAPE_TOKEN" >> "$d/etc/app.conf" ;;
    esac
}
mk_rescue() {   # <out.tar.zst> <clean|leaky>
    local r="$WORK/rescue-$2"
    mkdir -p "$r/root"
    printf 'rescue\n' > "$r/root/notes"
    [ "$2" = leaky ] && printf 'pw=%s\n' "$FAKE" >> "$r/root/notes"
    tar -C "$r" -cf - . | zstd -q -o "$1"
}

for mode in clean leaky shape; do
    mk_tree "$WORK/t-$mode" "$mode"
    mksquashfs "$WORK/t-$mode" "$WORK/$mode.squashfs" -noappend -no-progress -quiet >/dev/null 2>&1 \
        || { echo "fixture: mksquashfs failed" >&2; exit 1; }
    tar -C "$WORK/t-$mode" -czf "$WORK/$mode.tar.gz" .
    tar -C "$WORK/t-$mode" -cf "$WORK/$mode.tar" .
    tar -C "$WORK/t-$mode" -cf - . | zstd -q -o "$WORK/$mode.tar.zst"
done
# the bundle shape: assets/rescue/rescue-rootfs.tar.zst inside a tar.gz
mk_tree "$WORK/b-clean" clean; mk_rescue "$WORK/b-clean/assets/rescue/rescue-rootfs.tar.zst" clean
mk_tree "$WORK/b-leaky" clean; mk_rescue "$WORK/b-leaky/assets/rescue/rescue-rootfs.tar.zst" leaky
tar -C "$WORK/b-clean" -czf "$WORK/ncz-assets-clean.tar.gz" .
tar -C "$WORK/b-leaky" -czf "$WORK/ncz-assets-leaky.tar.gz" .

scan() { $PY "$SCAN" --hash-file "$WORK/hashes.json" --jobs 2 "$@" 2>&1; }

echo "== shipped-artifact credential gate: --payload =="
# 1. clean payloads pass, and the receipt names them
out="$(scan --payload "$WORK/clean.squashfs" --payload "$WORK/ncz-assets-clean.tar.gz" \
       --receipt "$WORK/clean.receipt.json")"; rc=$?
if [ "$rc" = 0 ] && grep -q 'SHIPPED-SCAN: PASS' <<<"$out"; then
    pass "clean squashfs + clean asset bundle pass"
else
    fail "clean payloads did not pass (rc=$rc): $out"
fi
if $PY - "$WORK/clean.receipt.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
names = [p["name"] for p in r["payloads"]]
fmts = sorted(l["format"] for l in r["layers"])
ok = (r["result"] == "PASS" and names == ["clean.squashfs", "ncz-assets-clean.tar.gz"]
      and fmts == ["squashfs", "tar"] and "image" not in r
      and all(l["files_scanned"] > 0 for l in r["layers"]))
sys.exit(0 if ok else 1)
PY
then pass "the receipt lists both payloads, their formats and scanned files"; else fail "payload receipt is wrong: $(cat "$WORK/clean.receipt.json")"; fi

# 2. a planted secret is caught in every container shape
for f in leaky.squashfs leaky.tar.gz leaky.tar leaky.tar.zst ncz-assets-leaky.tar.gz; do
    out="$(scan --payload "$WORK/$f")"; rc=$?
    if [ "$rc" = 1 ] && grep -q 'SHIPPED-SCAN: FAIL' <<<"$out" && grep -q 'known-secret' <<<"$out"; then
        pass "secret planted in $f is caught"
    else
        fail "secret in $f NOT caught (rc=$rc): $out"
    fi
    grep -qF "$FAKE" <<<"$out" && fail "the report for $f prints the secret value"
done
out="$(scan --payload "$WORK/ncz-assets-leaky.tar.gz")"
grep -q 'rescue-rootfs.tar.zst' <<<"$out" && pass "the nested rescue-rootfs.tar.zst is named in the finding" \
    || fail "nested finding does not name the rescue rootfs: $out"
# a clean tar in the same run cannot mask a leaky one
out="$(scan --payload "$WORK/clean.tar.gz" --payload "$WORK/leaky.squashfs")"; rc=$?
[ "$rc" = 1 ] && pass "one leaky payload fails the whole run" || fail "a leaky payload next to a clean one passed (rc=$rc)"

# 3. unlisted token shape
out="$(scan --payload "$WORK/shape.tar.gz")"; rc=$?
[ "$rc" = 1 ] && grep -q 'token-shape \[gitlab-pat\]' <<<"$out" && pass "an unlisted glpat- token shape is caught" \
    || fail "token shape not caught (rc=$rc): $out"

# 4. fail closed
head -c 65536 /dev/urandom > "$WORK/random.bin"
printf 'just some text, not an archive\n' | gzip -c > "$WORK/notar.gz"
: > "$WORK/empty.squashfs"
mkdir -p "$WORK/adir"
# a bundle large enough to stream in several reads, cut in half
head -c 3000000 /dev/urandom > "$WORK/t-clean/usr/share/doc/x/blob.bin"
tar -C "$WORK/t-clean" -czf "$WORK/big.tar.gz" .
head -c "$(( $(wc -c < "$WORK/big.tar.gz") / 2 ))" "$WORK/big.tar.gz" > "$WORK/trunc.tar.gz"
for f in random.bin notar.gz empty.squashfs adir trunc.tar.gz; do
    out="$(scan --payload "$WORK/$f")"; rc=$?
    if [ "$rc" = 1 ] && grep -q 'SHIPPED-SCAN: FAIL' <<<"$out"; then
        pass "fail closed: $f ($(grep -m1 -oE 'neither a squashfs|not a readable tar|is empty|not a regular file|truncated|no file to scan|zstd could not' <<<"$out" || echo FAIL))"
    else
        fail "$f did not fail closed (rc=$rc): $out"
    fi
done
out="$(scan --payload "$WORK/random.bin")"
grep -q 'neither a squashfs image nor a tar archive' <<<"$out" && pass "an unknown type says why it failed" \
    || fail "unknown-type message missing: $out"

# 5. exactly one mode
out="$(scan --image "$WORK/x.img" --payload "$WORK/clean.tar.gz")"; rc=$?
[ "$rc" = 2 ] && pass "--image with --payload is a usage error" || fail "--image + --payload rc=$rc"
out="$(scan)"; rc=$?
[ "$rc" = 2 ] && pass "neither --image nor --payload is a usage error" || fail "no mode rc=$rc"

# 6. the hashed half is still mandatory in payload mode
out="$($PY "$SCAN" --hash-file "$WORK/absent.json" --payload "$WORK/clean.tar.gz" 2>&1)"; rc=$?
[ "$rc" = 1 ] && pass "payload mode without a hash list fails" || fail "payload mode without hashes rc=$rc"

if [ "$FAILS" = 0 ]; then
    echo "test-shipped-secret-scan-payload: PASS"
    exit 0
fi
echo "test-shipped-secret-scan-payload: FAIL ($FAILS)" >&2
exit 1
