#!/bin/bash
# verify-split.sh -- prove the physical split changed nothing a builder can see.
#
#   platform-tools/verify-split.sh [--base REV]
#
# REV is the last commit BEFORE the physical move (default: the parent of the newest
# commit whose subject starts "platform-split: physical move"; pass --base after a
# rebase). Checks, all of which must pass:
#   1. scope=all view: every file the base tree tracked under the build roots is present
#      at the same flat path with the same git blob id and executable bit (symlinks: same
#      target), and the view holds no extra managed file. This is the sorted
#      `path sha256`-list equality in blob-id form: identical builder inputs.
#   2. per-platform views: scope=<p> equals the base tree restricted to inventory classes
#      common, mixed and <p>; nothing of the other platform leaks in.
#   3. `make -n ARCH=arm64 image` and `make -n ARCH=amd64 image` output is identical to the
#      base tree's (paths normalized), i.e. no recipe or prerequisite changed except the
#      quiet parse-time view assembly.
#   4. build/lint-platform.sh and build/test-platform-lint.sh pass on the scope=all view.
# The view is left assembled with scope=all on exit.
set -uo pipefail
REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
cd "$REPO"
BASE=""
[ "${1:-}" = "--base" ] && BASE="${2:?rev}"
if [ -z "$BASE" ]; then
    m=$(git log --format=%H --grep='^platform-split: physical move' -1)
    [ -n "$m" ] || { echo "verify-split: cannot find the physical-move commit; pass --base REV" >&2; exit 2; }
    BASE=$(git rev-parse "$m^")
fi
# Files deliberately edited AFTER the pure-rename commit (tooling that had to learn the new
# layout) are reported, then excluded from the byte comparison. Everything else must match.
MOVE=$(git log --format=%H --grep='^platform-split: physical move' -1)
EDITED=""
if [ -n "$MOVE" ]; then
    EDITED=$(git diff --name-only --diff-filter=AMR "$MOVE" HEAD | sed -E 's#^common/##; s#^platforms/[^/]+/##' | LC_ALL=C sort -u)
fi
ROOTS="post-install manifests assets build preseed tests tools scripts packaging packages sbom docker kernel-source"
FAIL=0
bad() { echo "VERIFY FAIL: $*" >&2; FAIL=1; }
echo "verify-split: base $(git rev-parse --short "$BASE"), head $(git rev-parse --short HEAD)"

expected() {  # mode blob path (NUL-safe enough: paths here have no tabs/newlines)
    git ls-tree -r "$BASE" -- $ROOTS | awk -F'\t' '{split($1,a," "); print a[1] "\t" a[3] "\t" $2}'
}
viewsum() {   # same format from the assembled view; $1 = file with newline-separated paths
    while IFS= read -r p; do
        if [ -L "$p" ]; then m=120000; b=$(printf '%s' "$(readlink "$p")" | git hash-object --stdin)
        else [ -x "$p" ] && m=100755 || m=100644; b=$(git hash-object -- "$p"); fi
        printf '%s\t%s\t%s\n' "$m" "$b" "$p"
    done < "$1"
}
inv_class() {  # path -> class via longest prefix (uses the same rule as the lint)
    awk -F'\t' -v P="$1" '!/^#/ && NF>=4 { if ($1==P) {exact=$2} else if (substr($1,length($1))=="/" && index(P,$1)==1 && length($1)>bl) {bl=length($1); pc=$2} } END{print (exact!=""?exact:pc)}' docs/platform-inventory.tsv
}

T=$(mktemp -d); trap 'rm -rf "$T"; git worktree prune >/dev/null 2>&1; python3 "$REPO/platform-tools/platform-assemble.py" --scope all --quiet' EXIT
expected | LC_ALL=C sort -t$'\t' -k3 > "$T/expected.all"
printf '%s\n' "$EDITED" > "$T/edited"
[ -s "$T/edited" ] && echo "verify-split: $(grep -c . "$T/edited") file(s) edited after the pure-rename commit are excluded from the byte comparison (listed in docs/PLATFORM-SPLIT.md)"
dropedited() { awk -F'\t' 'NR==FNR{e[$0]=1; next} !($3 in e)' "$T/edited" -; }

check_scope() {  # scope
    local scope="$1"
    python3 platform-tools/platform-assemble.py --scope "$scope" --quiet || { bad "assemble --scope $scope failed"; return; }
    grep -v '^#' .platform-assembled | LC_ALL=C sort > "$T/managed.$scope"
    viewsum "$T/managed.$scope" | LC_ALL=C sort -t$'\t' -k3 | dropedited > "$T/view.$scope"
    if [ "$scope" = all ]; then dropedited < "$T/expected.all" > "$T/want.$scope"
    else
        own=$([ "$scope" = sky1-arm64 ] && echo sky1 || echo amd64)
        : > "$T/want.$scope"
        while IFS=$'\t' read -r m b p; do
            c=$(inv_class "$p")
            case "$c" in common|mixed|"$own") printf '%s\t%s\t%s\n' "$m" "$b" "$p" >> "$T/want.$scope" ;; esac
        done < <(dropedited < "$T/expected.all")
    fi
    if diff -u "$T/want.$scope" "$T/view.$scope" > "$T/diff.$scope"; then
        echo "verify-split: scope $scope OK ($(wc -l < "$T/view.$scope") files identical to the base tree$([ "$scope" != all ] && echo ' minus the other platform'))"
    else
        bad "scope $scope differs from the base tree:"; head -20 "$T/diff.$scope" >&2
    fi
}
check_scope all
check_scope sky1-arm64
check_scope amd64
python3 platform-tools/platform-assemble.py --scope all --quiet

# 3. make -n identity against the base tree
git worktree add -q --detach "$T/base" "$BASE" || { bad "cannot check out base"; exit 1; }
for a in arm64 amd64; do
    # the image name embeds the short git sha of the tree being built: normalize it
    bsha=$(git -C "$T/base" rev-parse --short=8 HEAD); hsha=$(git rev-parse --short=8 HEAD)
    (cd "$T/base" && make -n ARCH=$a image 2>&1 | sed "s#$T/base#ROOT#g; s#$bsha#BUILDSHA#g") > "$T/make.base.$a"
    make -n ARCH=$a image 2>&1 | sed "s#$REPO#ROOT#g; s#$hsha#BUILDSHA#g" > "$T/make.head.$a"
    if diff -u "$T/make.base.$a" "$T/make.head.$a" > "$T/make.diff.$a"; then echo "verify-split: make -n ARCH=$a image identical ($(wc -l < "$T/make.head.$a") lines)"
    else bad "make -n ARCH=$a image differs:"; head -20 "$T/make.diff.$a" >&2; fi
done
git worktree remove --force "$T/base" >/dev/null 2>&1

# 4. lints and unit tests on the scope=all view
bash build/lint-platform.sh || bad "lint-platform"
bash build/test-platform-lint.sh >/dev/null 2>&1 && echo "verify-split: build/test-platform-lint.sh passed" || bad "test-platform-lint"
[ "$FAIL" = 0 ] && { echo "verify-split: OK -- the split is invisible to the builders"; exit 0; }
exit 1
