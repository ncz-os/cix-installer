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

# Resolve the wrap revision to the exact commit we will build. A raw sha in
# NCZ_SCENEFX_SHA (set by the compositor-pins resolver) wins; otherwise resolve
# the branch/tag the wrap names. Fail closed if neither yields a commit -- never
# build "whatever is checked out".
want="${NCZ_SCENEFX_SHA:-}"
# A wrap may name the exact commit (labwc 2f17786c: revision = 37ccd723...);
# ls-remote only resolves refs, so a full sha is taken as is.
if [ -z "$want" ] && printf '%s' "$rev" | grep -Eqx '[0-9a-f]{40}'; then
	want="$rev"
fi
if [ -z "$want" ]; then
	want="$(git ls-remote "$url" "$rev" 2>/dev/null | awk '{print $1}' | head -1)"
	[ -n "$want" ] || want="$(git ls-remote "$url" "refs/tags/$rev" 2>/dev/null | awk '{print $1}' | head -1)"
fi
case "$want" in
	[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) ;;
	*) echo "ERROR: scenefx: cannot resolve $url $rev to a commit (set NCZ_SCENEFX_SHA)" >&2; exit 1 ;;
esac
echo "scenefx: expected commit $want"

if [ ! -d "$DEST/.git" ]; then
	rm -rf "$DEST"
	git init -q "$DEST"
	git -C "$DEST" remote add origin "$url"
fi

# Make exactly $want present, then check it out -- whether $DEST is a fresh
# clone or a pre-seeded checkout from a previous step. This is the immutable
# check: we never trust the working tree's current HEAD.
if ! git -C "$DEST" cat-file -e "$want^{commit}" 2>/dev/null; then
	# Prefer the named ref (branch/tag: what the wrap actually points at), then
	# the exact sha (works when the mirror allows an advertised-commit fetch).
	git -C "$DEST" fetch -q origin "$rev" 2>/dev/null \
		|| git -C "$DEST" fetch -q --tags origin 2>/dev/null || true
	if ! git -C "$DEST" cat-file -e "$want^{commit}" 2>/dev/null; then
		git -C "$DEST" fetch -q origin "$want" 2>/dev/null || true
	fi
fi
git -C "$DEST" cat-file -e "$want^{commit}" 2>/dev/null \
	|| { echo "ERROR: scenefx: commit $want is not present in $DEST" >&2; exit 1; }
git -C "$DEST" checkout -q --detach "$want"
head_sha="$(git -C "$DEST" rev-parse HEAD)"
[ "$head_sha" = "$want" ] \
	|| { echo "ERROR: scenefx: HEAD $head_sha != expected $want" >&2; exit 1; }
echo "scenefx: checked out $(git -C "$DEST" rev-parse --short HEAD)"

# The wrap's own diff_files (labwc subprojects/packagefiles/, e.g.
# scenefx-liquid.patch). meson applies them only when IT downloads the
# subproject; because this helper pre-seeds the checkout, meson skips the
# download and would build SceneFX without them. Apply them here, in the order
# the wrap lists them, before the NCZ queue.
diff_files="$(ini_field "$WRAP" diff_files)"
if [ -n "$diff_files" ]; then
	IFS=',' read -r -a _dfs <<< "$diff_files"
	for df in "${_dfs[@]}"; do
		df="$(printf '%s' "$df" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
		[ -n "$df" ] || continue
		dp="$(cd "$LABWC" && pwd)/subprojects/packagefiles/$df"   # absolute: git -C changes the cwd
		[ -f "$dp" ] || { echo "ERROR: scenefx: wrap diff_files $df not found at $dp" >&2; exit 1; }
		if git -C "$DEST" apply --check "$dp" 2>/dev/null; then
			git -C "$DEST" apply "$dp"
			echo "    scenefx wrap diff applied: $df"
		elif git -C "$DEST" apply --reverse --check "$dp" 2>/dev/null; then
			echo "    scenefx wrap diff already present: $df"
		else
			echo "ERROR: scenefx: wrap diff_files $df does not apply" >&2
			exit 1
		fi
	done
fi

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
