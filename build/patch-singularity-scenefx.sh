#!/bin/bash
# patch-singularity-scenefx.sh -- make labwc's bundled SceneFX GLSL lint clean
# for the CIX/ARM libmali GLES compiler before the payload build compiles it.
#
# WHY THIS IS NOT IN /ncz-patches
#   labwc declares SceneFX as a meson [wrap-git] subproject
#   (subprojects/labwc/subprojects/scenefx.wrap), NOT as a singularity-desktop
#   submodule.  singularity-pins.sh and the build's /ncz-patches loop both key
#   on superproject submodule paths, so neither can reach it.  This helper
#   resolves the wrap, checks it out at the revision labwc names, and applies
#   assets/singularity/scenefx-patches/ to it.
#
# WHY IT IS NEEDED
#   SceneFX 0.5's quad.frag and tex.frag guard their runtime-format preamble
#   with `#error "Missing shader preamble"`.  The CIX/ARM libmali GLES
#   front-end (Valhall r53p0-p0-00eac0, Mali-G720-Immortalis) rejects the
#   double quote inside the directive -- "L0001: Unknown character '"'(34)" --
#   EVEN WHEN THE DIRECTIVE IS INSIDE A DISABLED PREPROCESSOR BRANCH (the guard
#   macro IS defined).  glCompileShader therefore fails, SceneFX cannot create
#   its fx renderer, labwc exits, greetd crash-loops and the Sky1 Mali boot is
#   a black screen.  Mesa/Panthor and PANTHOR boots discard the inactive block
#   correctly, so they were unaffected.  The fix de-quotes the two directives;
#   it changes no shader behaviour (the preamble is always substituted).
#
#   Pre-downloading the wrap is safe: meson reuses an existing
#   subprojects/<name> checkout and does not reset local modifications
#   (verified with meson 1.12).
#
# usage: patch-singularity-scenefx.sh <labwc-source-dir>
#   env: NCZ_SCENEFX_PATCHES (default /ncz-scenefx-patches)
set -euo pipefail

LABWC="${1:?usage: $0 <labwc-source-dir>}"
PATCHES="${NCZ_SCENEFX_PATCHES:-/ncz-scenefx-patches}"
WRAP="$LABWC/subprojects/scenefx.wrap"
DEST="$LABWC/subprojects/scenefx"

if [ ! -f "$WRAP" ]; then
	echo "scenefx: no wrap at $WRAP -- nothing to patch (labwc without SceneFX)"
	exit 0
fi

# Only need to do anything if there are patches to apply.
shopt -s nullglob
patch_files=("$PATCHES"/*.patch)
if [ "${#patch_files[@]}" = 0 ]; then
	echo "scenefx: no patches in $PATCHES -- nothing to do"
	exit 0
fi

ini_field() {  # ini_field <file> <key>  (first match, whitespace tolerant)
	awk -F'=' -v k="$2" '
		{ key=$1; gsub(/^[ \t]+|[ \t]+$/, "", key) }
		key == k { v=$2; gsub(/^[ \t]+|[ \t]+$/, "", v); print v; exit }' "$1"
}

url="$(ini_field "$WRAP" url)"
rev="$(ini_field "$WRAP" revision)"
[ -n "$url" ] || { echo "scenefx: no url in $WRAP" >&2; exit 1; }
[ -n "$rev" ] || { echo "scenefx: no revision in $WRAP" >&2; exit 1; }
echo "scenefx: wrap $url @ $rev"

if [ ! -d "$DEST/.git" ]; then
	rm -rf "$DEST"
	git init -q "$DEST"
	git -C "$DEST" remote add origin "$url"
	# revision may be a branch, a tag or a raw sha; try the direct ref, then a tag.
	if ! git -C "$DEST" fetch -q --depth 1 origin "$rev" 2>/dev/null; then
		git -C "$DEST" fetch -q --depth 1 origin "refs/tags/$rev" 2>/dev/null || {
			echo "scenefx: cannot fetch $url $rev" >&2; exit 1; }
	fi
	git -C "$DEST" checkout -q --detach FETCH_HEAD
fi
echo "scenefx: checked out $(git -C "$DEST" rev-parse --short HEAD)"

for p in "${patch_files[@]}"; do
	base="$(basename "$p")"
	if git -C "$DEST" apply --check "$p" 2>/dev/null; then
		git -C "$DEST" apply "$p"
		echo "    scenefx patch applied: $base"
	elif git -C "$DEST" apply --reverse --check "$p" 2>/dev/null; then
		echo "    scenefx patch already present: $base"
	else
		echo "ERROR: scenefx patch does not apply: $base" >&2
		exit 1
	fi
done

# Hard guard: the whole point is that no quoted #error survives into the build.
if grep -Rn '#error "' "$DEST/render" >/dev/null 2>&1; then
	echo "ERROR: quoted #error still present under $DEST/render after patching" >&2
	grep -Rn '#error "' "$DEST/render" >&2
	exit 1
fi
echo "scenefx: OK -- no quoted #error remains in the shader sources"
