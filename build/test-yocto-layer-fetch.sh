#!/usr/bin/env bash
# test-yocto-layer-fetch.sh -- the Yocto layer fetch, against fixture repos.
#
# M9's cache half says the FIRST clone should come from the store rather than the
# public URL, and the pin must still decide. These cases run the real function
# (build/lib/yocto-layers.sh) with local bare repositories as "upstream" and
# "store", so the policy is proven without a mounted Yocto export or a network.
set -uo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
LIB="$REPO/build/lib/yocto-layers.sh"
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  PASS  $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL  $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'; }

[ -s "$LIB" ] || { echo "missing $LIB"; exit 1; }
command -v git >/dev/null || { echo "SKIP: no git"; exit 0; }

T="$(mktemp -d "${TMPDIR:-/var/tmp}/ncz-yocto-fetch.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid

# upstream: two commits. A fixture that silently made one commit would let the
# "stale store" case pass for the wrong reason, so the shape is asserted.
work="$T/work"; git init -q "$work"
printf 'one\n' > "$work/f"; git -C "$work" add f; git -C "$work" commit -qm one
printf 'two\n' > "$work/f"; git -C "$work" add f; git -C "$work" commit -qm two
OLD="$(git -C "$work" rev-parse HEAD~1 2>/dev/null)"
NEW="$(git -C "$work" rev-parse HEAD 2>/dev/null)"
case "$OLD$NEW" in
    *[!0-9a-f]*|"") echo "SETUP FAILED: expected two commits (old='$OLD' new='$NEW')" >&2; exit 1 ;;
esac
[ "${#OLD}" = 40 ] && [ "${#NEW}" = 40 ] || { echo "SETUP FAILED: short shas" >&2; exit 1; }

UP="$T/upstream.git"; git clone -q --bare "$work" "$UP"
STORE="$T/store/layer.git"; mkdir -p "$(dirname "$STORE")"; git clone -q --bare "$work" "$STORE"
STALE="$T/stale/layer.git"; mkdir -p "$(dirname "$STALE")"; git clone -q --bare "$work" "$STALE"
git -C "$STALE" update-ref refs/heads/main "$OLD"
[ "$(git -C "$STALE" rev-parse refs/heads/main 2>/dev/null)" = "$OLD" ] \
    || { echo "SETUP FAILED: stale store does not point at the old commit" >&2; exit 1; }

run() {  # run <layers-root> <url> <fallback> <revision>  -> RC/OUT
    local lr="$1" url="$2" fb="$3" rev="$4"
    OUT="$( . "$LIB"; ncz_yocto_fetch_layer layer "$url" "$fb" "$rev" "$lr" 2>&1 )"; RC=$?
}

# 1. with a store configured, the FIRST clone comes from the store
lr="$T/l1"; mkdir -p "$lr"; run "$lr" "$UP" "$STORE" "$NEW"
if [ "$RC" = 0 ] && [ "$(git -C "$lr/layer" rev-parse HEAD 2>/dev/null)" = "$NEW" ]; then
    ok "a fresh clone with a store configured lands on the pinned revision"
else
    bad "a fresh clone with a store configured lands on the pinned revision" "$OUT"
fi
origin="$(git -C "$lr/layer" config --get remote.origin.url 2>/dev/null)"
case "$origin" in
    *store*) ok "the first clone came from the store, not the public URL" ;;
    *) bad "the first clone came from the store" "origin=$origin" ;;
esac
grep -q 'from the store' <<< "$OUT" \
    && ok "it says which source it used" \
    || bad "it does not say which source it used"

# 2. without a store, it clones upstream
lr2="$T/l2"; mkdir -p "$lr2"; run "$lr2" "$UP" "" "$NEW"
if [ "$RC" = 0 ] && [ "$(git -C "$lr2/layer" rev-parse HEAD 2>/dev/null)" = "$NEW" ]; then
    ok "with no store configured it clones upstream and pins"
else
    bad "with no store configured it clones upstream and pins" "$OUT"
fi

# 3. a store missing the pinned commit must not win: upstream supplies it
lr3="$T/l3"; mkdir -p "$lr3"; run "$lr3" "$UP" "$STALE" "$NEW"
if [ "$RC" = 0 ] && [ "$(git -C "$lr3/layer" rev-parse HEAD 2>/dev/null)" = "$NEW" ]; then
    ok "a stale store is completed from upstream, ending at the pin"
else
    bad "a stale store is completed from upstream, ending at the pin" "$OUT"
fi

# 4. nobody has the revision: hard error, never a silent checkout
lr4="$T/l4"; mkdir -p "$lr4"; run "$lr4" "$UP" "$STALE" "0123456789012345678901234567890123456789"
[ "$RC" != 0 ] && ok "an unreachable revision fails loudly" || bad "an unreachable revision fails loudly"
grep -q 'pinned revision .* not found' <<< "$OUT" \
    && ok "the failure names the missing revision" \
    || bad "the failure names the missing revision" "$OUT"

# 4b. a store that genuinely LACKS the object (not just a moved ref) must be
#     completed from upstream: a store clone's origin is the store, so this is
#     the case that a naive implementation fails.
STORESHALLOW="$T/shallow/layer.git"; mkdir -p "$(dirname "$STORESHALLOW")"
git init -q --bare "$STORESHALLOW"
# push ONLY the old commit: a bare clone of the work tree would carry the new
# object too and the case would pass for the wrong reason
git -C "$work" push -q "$STORESHALLOW" "$OLD:refs/heads/main"
git -C "$STORESHALLOW" cat-file -e "$NEW^{commit}" 2>/dev/null \
    && { echo "SETUP FAILED: the shallow store still has the new object" >&2; exit 1; }
lr6="$T/l6"; mkdir -p "$lr6"; run "$lr6" "$UP" "$STORESHALLOW" "$NEW"
if [ "$RC" = 0 ] && [ "$(git -C "$lr6/layer" rev-parse HEAD 2>/dev/null)" = "$NEW" ]; then
    ok "a store missing the object is completed from upstream"
else
    bad "a store missing the object is completed from upstream" "$OUT"
fi

# 4c. STORE_BASE supplies the fallback when the manifest row leaves it empty
lr7="$T/l7"; mkdir -p "$lr7"
OUT="$( . "$LIB"; STORE_BASE="$T/store" ncz_yocto_fetch_layer layer "$UP" "" "$NEW" "$lr7" 2>&1 )"; RC=$?
if [ "$RC" = 0 ] && case "$(git -C "$lr7/layer" config --get remote.origin.url 2>/dev/null)" in *store*) true;; *) false;; esac; then
    ok "STORE_BASE stands in for an empty manifest fallback"
else
    bad "STORE_BASE stands in for an empty manifest fallback" "$OUT"
fi

# 5. a store path that does not exist falls back to upstream
lr5="$T/l5"; mkdir -p "$lr5"; run "$lr5" "$UP" "$T/nope/layer.git" "$NEW"
[ "$RC" = 0 ] && ok "a missing store falls back to upstream" || bad "a missing store falls back to upstream" "$OUT"

echo "test-yocto-layer-fetch: $pass passed, $fail failed"
[ "$fail" = 0 ]
