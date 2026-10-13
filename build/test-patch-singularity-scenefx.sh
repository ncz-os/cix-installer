#!/bin/bash
# test-patch-singularity-scenefx.sh -- build/patch-singularity-scenefx.sh against a
# local fixture SceneFX repository (no network).
#
# Why (2026-10-13): labwc 2f17786c changed its scenefx.wrap from `revision = 0.5`
# to a raw commit plus `diff_files = scenefx-liquid.patch`. The helper resolved
# only refs with ls-remote ("cannot resolve ... to a commit"), and because it
# pre-seeds the checkout, meson would also have skipped the wrap's diff_files.
#
#   1. wrap with a tag revision: checked out at the tag, NCZ patch applied
#   2. wrap with a raw 40-hex revision: checked out at that commit
#   3. diff_files are applied from subprojects/packagefiles/ BEFORE the NCZ queue
#      (the NCZ patch here only applies on top of the wrap diff)
#   4. a diff_files entry that is missing fails closed
#   5. a quoted #error left in render/ fails closed
# Usage: build/test-patch-singularity-scenefx.sh
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
H="$HERE/patch-singularity-scenefx.sh"
command -v git >/dev/null 2>&1 || { echo "SKIP: git not available"; exit 77; }
T="$(mktemp -d "${TMPDIR:-/tmp}/test-scenefx.XXXXXX")"; trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS  $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL  $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'; }
g() { git -c user.name=t -c user.email=t@example.invalid -c init.defaultBranch=main "$@"; }

# upstream fixture: v1 has the quoted #error; tag 0.5
U="$T/scenefx"; mkdir -p "$U/render"
g init -q "$U"
printf '#ifndef PREAMBLE\n#error "Missing shader preamble"\n#endif\nvoid main() {}\n' > "$U/render/quad.frag"
g -C "$U" add -A; g -C "$U" commit -qm v1; g -C "$U" tag 0.5
SHA="$(git -C "$U" rev-parse HEAD)"
# a later commit, so a checkout at the tag/sha is distinguishable from the branch head
echo later > "$U/LATER"; g -C "$U" add -A; g -C "$U" commit -qm later

# wrap diff (like scenefx-liquid.patch): appends a line to quad.frag
W="$T/wdiff"; g clone -q "$U" "$W"; git -C "$W" checkout -q "$SHA"
printf '// liquid\n' >> "$W/render/quad.frag"; git -C "$W" diff > "$T/liquid.patch"
# NCZ patch: de-quotes the directive AND touches the liquid line, so it only applies after the wrap diff
g -C "$W" commit -qam liquid
sed -i 's/#error "Missing shader preamble"/#error Missing shader preamble/; s#// liquid#// liquid (mali)#' "$W/render/quad.frag"
mkdir -p "$T/ncz"; git -C "$W" diff > "$T/ncz/0001-dequote.patch"

mklabwc() {  # dir revision [diff_files]
    mkdir -p "$1/subprojects/packagefiles"
    { echo '[wrap-git]'; echo "url = $U"; echo "revision = $2"; [ -n "${3:-}" ] && echo "diff_files = $3"; } > "$1/subprojects/scenefx.wrap"
    cp "$T/liquid.patch" "$1/subprojects/packagefiles/scenefx-liquid.patch"
}
run() { NCZ_SCENEFX_PATCHES="$2" bash "$H" "$1" > "$T/run.log" 2>&1; }

# 1. tag revision, no diff_files, plain de-quote patch
mkdir -p "$T/ncz-plain"; g clone -q "$U" "$T/p"; git -C "$T/p" checkout -q "$SHA"
sed -i 's/#error "Missing shader preamble"/#error Missing shader preamble/' "$T/p/render/quad.frag"; git -C "$T/p" diff > "$T/ncz-plain/0001.patch"
mklabwc "$T/l1" 0.5
run "$T/l1" "$T/ncz-plain" && ok "tag revision: helper succeeds" || bad "tag revision failed" "$(cat "$T/run.log")"
[ "$(git -C "$T/l1/subprojects/scenefx" rev-parse HEAD)" = "$SHA" ] && ok "tag revision: checked out the tagged commit" || bad "tag revision: wrong HEAD"

# 2+3. raw sha + diff_files
mklabwc "$T/l2" "$SHA" scenefx-liquid.patch
run "$T/l2" "$T/ncz" && ok "raw sha + diff_files: helper succeeds" || bad "raw sha + diff_files failed" "$(cat "$T/run.log")"
[ "$(git -C "$T/l2/subprojects/scenefx" rev-parse HEAD 2>/dev/null)" = "$SHA" ] && ok "raw sha: checked out exactly $SHA" || bad "raw sha: wrong HEAD"
grep -q 'liquid (mali)' "$T/l2/subprojects/scenefx/render/quad.frag" && ok "wrap diff applied before the NCZ patch (NCZ patch builds on it)" || bad "wrap diff / NCZ order wrong" "$(cat "$T/run.log")"
grep -q 'scenefx wrap diff applied: scenefx-liquid.patch' "$T/run.log" && ok "log names the wrap diff" || bad "log lacks the wrap diff line" "$(cat "$T/run.log")"

# the build passes a RELATIVE labwc dir (subprojects/labwc); the diff path must still resolve
mklabwc "$T/rel/subprojects/labwc" "$SHA" scenefx-liquid.patch
( cd "$T/rel" && NCZ_SCENEFX_PATCHES="$T/ncz" bash "$H" subprojects/labwc ) > "$T/run.log" 2>&1 \
    && ok "relative labwc dir: wrap diff and NCZ patch applied" || bad "relative labwc dir failed" "$(cat "$T/run.log")"

# negative control: the same wrap without diff_files -> the NCZ patch cannot apply
mklabwc "$T/l3" "$SHA"
run "$T/l3" "$T/ncz" && bad "without the wrap diff the dependent NCZ patch applied" || ok "negative control: without diff_files the dependent NCZ patch fails"

# 4. missing diff file
mklabwc "$T/l4" "$SHA" missing.patch
run "$T/l4" "$T/ncz" && bad "missing diff_files entry accepted" || ok "missing diff_files entry fails closed"
grep -q 'missing.patch not found' "$T/run.log" && ok "  message names the missing diff" || bad "  message" "$(cat "$T/run.log")"

# 5. a patch queue that leaves the quoted #error fails the guard
mkdir -p "$T/ncz-noop"; g clone -q "$U" "$T/q"; git -C "$T/q" checkout -q "$SHA"; echo x >> "$T/q/LATER2"; git -C "$T/q" add -N LATER2; git -C "$T/q" diff > "$T/ncz-noop/0001.patch"
mklabwc "$T/l5" 0.5
run "$T/l5" "$T/ncz-noop" && bad "quoted #error survived and was accepted" || ok "a surviving quoted #error fails the guard"

echo "test-patch-singularity-scenefx: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
