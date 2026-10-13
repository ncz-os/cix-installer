#!/bin/bash
# check-release-parity.sh - check that the GitHub and GitLab release pages
# show the same release. Read-only: it never changes anything on either forge.
#
# Usage:
#   tools/check-release-parity.sh [--tag TAG] [options]
#
# Checks, each reported as "ok" or "DIFF":
#   * one release page per forge: each forge has exactly one release object
#     (drafts and pre-releases count); with --tag it must be TAG. Without
#     --tag the single GitHub release names the tag.
#   * the tag exists on both forges (the commits may differ: the GitHub
#     repository is a mirror snapshot; both are printed).
#   * title and notes body are equal. The body is compared after normalising
#     line endings and the forge-specific forms of the same link (latest
#     release page, latest release file, raw/blob/tree links on main); see
#     tools/release-forge-lib.sh.
#   * status: the GitHub release is not a draft, its pre-release flag equals
#     --expect-prerelease when given, the GitLab release is not "upcoming";
#     and both stable "latest" addresses resolve to TAG
#     (github.com/<repo>/releases/latest, gitlab.com/<p>/-/releases/permalink/latest).
#     A GitHub pre-release is never "latest", so it fails this check.
#   * assets: the same names in the same order, with equal sizes and sha256.
#     GitHub sizes and digests come from the API (a file without an API
#     digest is downloaded and hashed). GitLab assets must be links to files
#     of this project's generic package registry; sizes and sha256 come from
#     the registry. Each GitLab link's direct path is the stable alias of its
#     file (parts: ncz-os-<arch>.img.zst.part-NN; other files: their name).
#   * PARTS.sha256, SHA256SUMS, ncz-join-image.sh and NOTES.md are downloaded
#     anonymously from both release pages and must be byte-equal.
#   * screenshots: both bodies reference the same images; every image is an
#     absolute raw URL on main of the forge's own repository, answers HTTP 200
#     and has the sha256 of the same file in --repo-root.
#   * with --release-dir: the assets also equal the staged folder.
#
# Options:
#   --tag TAG                   the release to check (default: the single GitHub release)
#   --github-repo OWNER/NAME    default ncz-os/cix-installer ($NCZ_GITHUB_REPO)
#   --gitlab-project PATH       default ncz-os/cix-installer ($NCZ_GITLAB_PROJECT)
#   --quick                     compare asset names and sizes only (no sha256,
#                               no downloads of large files)
#   --release-dir DIR           also compare against a staged release folder
#   --repo-root DIR             checkout holding the screenshots (default: this repository)
#   --expect-prerelease yes|no  required state of the GitHub pre-release flag
#   --ignore-other-releases     report other releases but do not fail on them
#                               (used between publishing and retiring)
#   --no-latest-check           skip the "latest" address check
#   -h, --help                  this text
#
# Tokens (optional; reads are anonymous without them): see
# tools/release-forge-lib.sh (NCZ_GITHUB_TOKEN_HELPER / NCZ_GITHUB_TOKEN_VAR,
# NCZ_GITLAB_TOKEN_HELPER / NCZ_GITLAB_TOKEN_VAR). Tokens are never printed.
#
# Exit codes: 0 parity, 1 a difference was found, 2 usage error, 3 API error.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tools/release-forge-lib.sh
. "$HERE/release-forge-lib.sh"

GH_REPO="${NCZ_GITHUB_REPO:-ncz-os/cix-installer}"
GL_PROJECT="${NCZ_GITLAB_PROJECT:-ncz-os/cix-installer}"
TAG=""; QUICK=0; RDIR=""; REPO_ROOT=""; EXPECT_PRE=""; IGNORE_OTHERS=0; LATEST=1

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; }
udie() { rf_die "$*" 2; }
while [ $# -gt 0 ]; do
  case "$1" in
    --tag) TAG=${2:?--tag needs a tag}; shift 2 ;;
    --github-repo) GH_REPO=${2:?}; shift 2 ;;
    --gitlab-project) GL_PROJECT=${2:?}; shift 2 ;;
    --quick) QUICK=1; shift ;;
    --release-dir) RDIR=${2:?}; shift 2 ;;
    --repo-root) REPO_ROOT=${2:?}; shift 2 ;;
    --expect-prerelease) EXPECT_PRE=${2:?}; shift 2 ;;
    --ignore-other-releases) IGNORE_OTHERS=1; shift ;;
    --no-latest-check) LATEST=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) udie "unknown argument: $1 (try --help)" ;;
  esac
done
case "$EXPECT_PRE" in ''|yes|no) ;; *) udie "--expect-prerelease takes yes or no" ;; esac
printf '%s' "$GH_REPO" | grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' || udie "invalid --github-repo: $GH_REPO"
[ -z "$RDIR" ] || [ -d "$RDIR" ] || udie "not a folder: $RDIR"
for t in jq curl python3; do command -v "$t" >/dev/null 2>&1 || udie "$t is required"; done
[ -n "$REPO_ROOT" ] || REPO_ROOT=$(git -C "$HERE" rev-parse --show-toplevel 2>/dev/null || (cd "$HERE/.." && pwd))

rf_load_token github; rf_load_token gitlab
W=$(mktemp -d "${TMPDIR:-/tmp}/relparity.XXXXXX"); trap 'rm -rf "$W"' EXIT

DIFFS=0
ok()   { echo "ok    $*"; }
diff_() { echo "DIFF  $*"; DIFFS=$((DIFFS+1)); }
info() { echo "info  $*"; }
apierr() { echo "ERROR: $*" >&2; exit 3; }

# ---- release lists: one release page per forge ---------------------------------
GL_PID=$(rf_project_id "$GL_PROJECT" "$W") || apierr "cannot resolve GitLab project $GL_PROJECT"
rf_get_all github "$RF_GITHUB_API/repos/$GH_REPO/releases" "$W/gh-rels.json" || apierr "cannot list GitHub releases"
rf_get_all gitlab "$RF_GITLAB_API/projects/$GL_PID/releases" "$W/gl-rels.json" || apierr "cannot list GitLab releases"

if [ -z "$TAG" ]; then
  [ "$(jq length "$W/gh-rels.json")" -ge 1 ] || { diff_ "GitHub has no release and no --tag was given"; exit 1; }
  TAG=$(jq -r 'sort_by(.created_at) | last | .tag_name' "$W/gh-rels.json")
  info "no --tag: checking $TAG (newest GitHub release)"
fi
echo "Release $TAG   GitHub $GH_REPO   GitLab $GL_PROJECT (id $GL_PID)"

for forge in github gitlab; do
  if [ "$forge" = github ]; then f="$W/gh-rels.json"; q='.[] | "\(.tag_name)\t\(.name)\t\(.assets|length) assets\(if .draft then " draft" else "" end)\(if .prerelease then " prerelease" else "" end)"'
  else f="$W/gl-rels.json"; q='.[] | "\(.tag_name)\t\(.name)\t\(.assets.links|length) links\(if .upcoming_release then " upcoming" else "" end)"'; fi
  n=$(jq length "$f")
  others=$(jq -r --arg t "$TAG" "[.[] | select(.tag_name != \$t)] | $q" "$f")
  if [ -n "$others" ]; then
    while IFS= read -r l; do
      if [ "$IGNORE_OTHERS" -eq 1 ]; then info "$forge other release: $l"; else diff_ "$forge has another release: $l"; fi
    done <<<"$others"
  fi
  if jq -e --arg t "$TAG" 'any(.[]; .tag_name == $t)' "$f" >/dev/null; then
    [ -n "$others" ] || ok "$forge has exactly one release page ($TAG)"
  else
    diff_ "$forge has no release for $TAG ($n release(s) in total)"
  fi
done

GH_HAVE=0; GL_HAVE=0
jq --arg t "$TAG" '[.[] | select(.tag_name == $t)][0] // empty' "$W/gh-rels.json" > "$W/gh.json"
jq --arg t "$TAG" '[.[] | select(.tag_name == $t)][0] // empty' "$W/gl-rels.json" > "$W/gl.json"
[ -s "$W/gh.json" ] && GH_HAVE=1
[ -s "$W/gl.json" ] && GL_HAVE=1
if [ "$GH_HAVE" -eq 0 ] || [ "$GL_HAVE" -eq 0 ]; then
  echo "Result: $DIFFS difference(s); the release is missing on one forge."
  exit 1
fi

# ---- tag ------------------------------------------------------------------------
c=$(rf_api github GET "$RF_GITHUB_API/repos/$GH_REPO/git/ref/tags/$(rf_uri "$TAG")" "$W/ghtag.json")
if [ "$c" = 200 ]; then info "GitHub tag $TAG -> $(jq -r '.object.sha[0:12]' "$W/ghtag.json") (mirror snapshot)"
else diff_ "GitHub tag $TAG not found (HTTP $c)"; fi
c=$(rf_api gitlab GET "$RF_GITLAB_API/projects/$GL_PID/repository/tags/$(rf_uri "$TAG")" "$W/gltag.json")
if [ "$c" = 200 ]; then info "GitLab tag $TAG -> $(jq -r '.commit.id[0:12]' "$W/gltag.json")"
else diff_ "GitLab tag $TAG not found (HTTP $c)"; fi

# ---- title and body ---------------------------------------------------------------
ght=$(jq -r '.name // ""' "$W/gh.json"); glt=$(jq -r '.name // ""' "$W/gl.json")
if [ "$ght" = "$glt" ]; then ok "title: $ght"; else diff_ "title: GitHub '$ght' vs GitLab '$glt'"; fi
jq -r '.body // ""' "$W/gh.json" > "$W/gh-body.md"
jq -r '.description // ""' "$W/gl.json" > "$W/gl-body.md"
rf_normalise_body "$W/gh-body.md" "$GH_REPO" "$GL_PROJECT" > "$W/gh-body.n"
rf_normalise_body "$W/gl-body.md" "$GH_REPO" "$GL_PROJECT" > "$W/gl-body.n"
if cmp -s "$W/gh-body.n" "$W/gl-body.n"; then ok "notes body ($(wc -l < "$W/gh-body.n" | tr -d ' ') lines, links normalised)"
else
  diff_ "notes body differs (normalised; - GitHub, + GitLab):"
  diff -u --label github --label gitlab "$W/gh-body.n" "$W/gl-body.n" | sed 's/^/      /' | head -80
fi

# ---- status ---------------------------------------------------------------------------
gh_pre=$(jq -r 'if .prerelease then "yes" else "no" end' "$W/gh.json")
if [ "$(jq -r '.draft' "$W/gh.json")" = true ]; then diff_ "GitHub release is a draft"; fi
if [ -n "$EXPECT_PRE" ] && [ "$gh_pre" != "$EXPECT_PRE" ]; then diff_ "GitHub pre-release flag is $gh_pre, expected $EXPECT_PRE"
else info "GitHub pre-release flag: $gh_pre"; fi
if [ "$(jq -r '.upcoming_release // false' "$W/gl.json")" = true ]; then diff_ "GitLab release is an upcoming release (released_at in the future)"; fi
if [ "$LATEST" -eq 1 ]; then
  c=$(rf_api github GET "$RF_GITHUB_API/repos/$GH_REPO/releases/latest" "$W/ghlatest.json")
  lt=""; [ "$c" = 200 ] && lt=$(jq -r '.tag_name' "$W/ghlatest.json")
  if [ "$lt" = "$TAG" ]; then ok "GitHub releases/latest -> $TAG"
  elif [ "$gh_pre" = yes ]; then diff_ "GitHub releases/latest -> '${lt:-none}' (HTTP $c): a pre-release is never 'latest' on GitHub, so the stable latest links do not reach $TAG"
  else diff_ "GitHub releases/latest -> '${lt:-none}' (HTTP $c), expected $TAG"; fi
  c=$(rf_api gitlab GET "$RF_GITLAB_API/projects/$GL_PID/releases/permalink/latest" "$W/gllatest.json")
  loc=$(cat "$W/gllatest.json.loc"); lt=""
  if [ "$c" = 302 ] || [ "$c" = 301 ]; then lt=$(python3 -I -c 'import sys,urllib.parse as u;print(u.unquote(sys.argv[1].rstrip("/").rsplit("/",1)[-1]))' "$loc"); fi
  if [ "$lt" = "$TAG" ]; then ok "GitLab releases/permalink/latest -> $TAG"
  else diff_ "GitLab releases/permalink/latest -> '${lt:-none}' (HTTP $c), expected $TAG"; fi
fi

# ---- assets ----------------------------------------------------------------------------
# GitHub: name size sha(or -) url
jq -r '.assets[] | [.name, (.size|tostring), ((.digest // "") | sub("^sha256:";"") | if .=="" then "-" else . end), .browser_download_url] | @tsv' "$W/gh.json" > "$W/gh-assets.tsv"
# GitLab: links -> package files of this project
jq -r '.assets.links[] | [.name, .url, (.direct_asset_path // ""), (.link_type // "")] | @tsv' "$W/gl.json" > "$W/gl-links.tsv"
: > "$W/gl-assets.tsv"
declare -A PKGFILES=()
pkg_prefix="$RF_GITLAB_API/projects/$GL_PID/packages/generic/"
while IFS=$'\t' read -r name url dpath _; do
  [ -n "$name" ] || continue
  want_path="/$(rf_stable_name "$name")"
  if [ "$dpath" != "$want_path" ]; then diff_ "GitLab link $name: direct path '$dpath', expected stable alias '$want_path'"; fi
  case "$url" in
    "$pkg_prefix"*) ;;
    *) diff_ "GitLab link $name does not point at this project's generic package registry: $url"
       printf '%s\t-\t-\t%s\n' "$name" "$url" >> "$W/gl-assets.tsv"; continue ;;
  esac
  rest=${url#"$pkg_prefix"}; pkg=${rest%%/*}; rest=${rest#*/}; ver=${rest%%/*}; file=${rest#*/}
  key="$pkg/$ver"
  if [ -z "${PKGFILES[$key]:-}" ]; then
    rf_get_all gitlab "$RF_GITLAB_API/projects/$GL_PID/packages?package_type=generic&package_name=$(rf_uri "$pkg")" "$W/pk.json" || apierr "cannot list GitLab packages"
    pid=$(jq -r --arg n "$pkg" --arg v "$ver" '[.[] | select(.name==$n and .version==$v)][0].id // empty' "$W/pk.json")
    out="$W/pf-$(printf '%s' "$key" | tr '/' '_').json"
    if [ -n "$pid" ]; then rf_get_all gitlab "$RF_GITLAB_API/projects/$GL_PID/packages/$pid/package_files" "$out" || apierr "cannot list package files"
    else echo '[]' > "$out"; fi
    PKGFILES[$key]=$out
  fi
  row=$(jq -r --arg f "$file" '[.[] | select(.file_name==$f)] | max_by(.id) // empty | "\(.size)\t\(.file_sha256)"' "${PKGFILES[$key]}")
  if [ -z "$row" ]; then diff_ "GitLab link $name: package file $pkg $ver $file not found"; row=$'-\t-'; fi
  printf '%s\t%s\t%s\n' "$name" "$row" "$url" >> "$W/gl-assets.tsv"
done < "$W/gl-links.tsv"

cut -f1 "$W/gh-assets.tsv" > "$W/gh-names"; cut -f1 "$W/gl-assets.tsv" > "$W/gl-names"
if cmp -s "$W/gh-names" "$W/gl-names"; then ok "asset names and order ($(wc -l < "$W/gh-names" | tr -d ' ') files)"
elif cmp -s <(sort "$W/gh-names") <(sort "$W/gl-names"); then diff_ "asset order differs (same names)"
else
  diff_ "asset names differ (- GitHub only, + GitLab only):"
  diff <(sort "$W/gh-names") <(sort "$W/gl-names") | grep -E '^[<>]' | sed 's/^</      -/; s/^>/      +/'
fi

# sha of a GitHub asset with no API digest: download unless --quick
gh_sha() { # name size sha url
  if [ "$3" != "-" ]; then echo "$3"; return; fi
  [ "$QUICK" -eq 1 ] && { echo "-"; return; }
  local c; c=$(rf_download "$4" "$W/dl.bin")
  if [ "$c" = 200 ]; then rf_sha "$W/dl.bin"; else echo "download-failed-$c"; fi
  rm -f "$W/dl.bin"
}
declare -A GHS=() GHZ=() GLS=() GLZ=() GHU=()
while IFS=$'\t' read -r n z s u; do [ -n "$n" ] || continue; GHZ[$n]=$z; GHU[$n]=$u; GHS[$n]=$(gh_sha "$n" "$z" "$s" "$u"); done < "$W/gh-assets.tsv"
while IFS=$'\t' read -r n z s u; do [ -n "$n" ] || continue; GLZ[$n]=$z; GLS[$n]=$s; done < "$W/gl-assets.tsv"
while IFS= read -r n; do
  [ -n "${GHZ[$n]:-}" ] && [ -n "${GLZ[$n]:-}" ] || continue
  if [ "${GHZ[$n]}" != "${GLZ[$n]}" ]; then diff_ "size of $n: GitHub ${GHZ[$n]} vs GitLab ${GLZ[$n]}"; continue; fi
  if [ "$QUICK" -eq 1 ]; then ok "$n size ${GHZ[$n]}"; continue; fi
  if [ "${GHS[$n]}" = "${GLS[$n]}" ] && [ "${GHS[$n]}" != "-" ]; then ok "$n size ${GHZ[$n]} sha256 ${GHS[$n]:0:16}"
  else diff_ "sha256 of $n: GitHub ${GHS[$n]} vs GitLab ${GLS[$n]}"; fi
done < <(sort -u "$W/gh-names" "$W/gl-names")

# ---- small files: byte-equal from both release pages ---------------------------------------
for f in "${RF_FIXED_FILES[@]}"; do
  in_gh=0; in_gl=0
  [ -n "${GHZ[$f]:-}" ] && in_gh=1; [ -n "${GLZ[$f]:-}" ] && in_gl=1
  if [ "$in_gh" -eq 0 ] && [ "$in_gl" -eq 0 ]; then diff_ "$f is on neither release page"; continue; fi
  [ "$in_gh" -eq 1 ] && [ "$in_gl" -eq 1 ] || continue   # already reported as a name difference
  c1=$(rf_download "${GHU[$f]}" "$W/gh-$f")
  c2=$(rf_download "$RF_GITLAB_WEB/$GL_PROJECT/-/releases/$(rf_uri "$TAG")/downloads/$(rf_stable_name "$f")" "$W/gl-$f")
  if [ "$c1" != 200 ] || [ "$c2" != 200 ]; then diff_ "$f download: GitHub HTTP $c1, GitLab HTTP $c2"; continue; fi
  if cmp -s "$W/gh-$f" "$W/gl-$f"; then ok "$f byte-equal ($(rf_size "$W/gh-$f") bytes)"
  else
    diff_ "$f content differs (- GitHub, + GitLab):"
    diff -u --label github --label gitlab "$W/gh-$f" "$W/gl-$f" | sed 's/^/      /' | head -40
  fi
done

# ---- screenshots -------------------------------------------------------------------------------
check_images() { # forge body-file
  local forge=$1 body=$2 u rel abs
  : > "$W/img-$forge.n"
  while IFS= read -r u; do
    [ -n "$u" ] || continue
    case "$u" in
      http://*|https://*) ;;
      *) diff_ "$forge body image '$u' is a relative link (it does not render on a release page)"; continue ;;
    esac
    printf '%s\n' "$u" > "$W/u.txt"
    abs=$(rf_normalise_body "$W/u.txt" "$GH_REPO" "$GL_PROJECT")
    printf '%s\n' "$abs" >> "$W/img-$forge.n"
    case "$abs" in
      "<raw-main>/"*) rel=${abs#"<raw-main>/"} ;;
      *) diff_ "$forge body image $u is not a raw file on main of the $forge repository"; continue ;;
    esac
    if [ ! -f "$REPO_ROOT/$rel" ]; then diff_ "$forge body image $rel is not in $REPO_ROOT"; continue; fi
    c=$(rf_download "$u" "$W/img.bin")
    if [ "$c" != 200 ]; then diff_ "$forge body image $u answers HTTP $c"; continue; fi
    if [ "$(rf_sha "$W/img.bin")" = "$(rf_sha "$REPO_ROOT/$rel")" ]; then ok "$forge image $rel (HTTP 200, sha256 = repository file)"
    else diff_ "$forge body image $u does not match $rel in the repository"; fi
  done < <(rf_image_refs "$body")
}
check_images github "$W/gh-body.md"
check_images gitlab "$W/gl-body.md"
if cmp -s <(sort -u "$W/img-github.n") <(sort -u "$W/img-gitlab.n"); then ok "same screenshot set on both pages ($(sort -u "$W/img-github.n" | grep -c . || true) images)"
else
  diff_ "screenshot sets differ (- GitHub only, + GitLab only):"
  diff <(sort -u "$W/img-github.n") <(sort -u "$W/img-gitlab.n") | grep -E '^[<>]' | sed 's/^</      -/; s/^>/      +/'
fi

# ---- staged folder --------------------------------------------------------------------------------
if [ -n "$RDIR" ]; then
  d0=$DIFFS
  : > "$W/local.tsv"
  while read -r s n; do n=${n#\*}; [ -n "$n" ] || continue; printf '%s\t%s\n' "$n" "$s" >> "$W/local.tsv"; done < "$RDIR/PARTS.sha256"
  for f in "${RF_FIXED_FILES[@]}"; do [ -f "$RDIR/$f" ] && printf '%s\t%s\n' "$f" "$(rf_sha "$RDIR/$f")" >> "$W/local.tsv"; done
  while IFS=$'\t' read -r n s; do
    if [ -z "${GHZ[$n]:-}" ]; then diff_ "staged $n is not on the GitHub page"; continue; fi
    if [ -f "$RDIR/$n" ] && [ "$(rf_size "$RDIR/$n")" != "${GHZ[$n]}" ]; then diff_ "staged $n size $(rf_size "$RDIR/$n") vs pages ${GHZ[$n]}"; continue; fi
    if [ "$QUICK" -eq 0 ] && [ "${GHS[$n]:-}" != "$s" ]; then diff_ "staged $n sha256 $s vs GitHub ${GHS[$n]:-none}"; fi
  done < "$W/local.tsv"
  unstaged=$(cut -f1 "$W/local.tsv" | LC_ALL=C sort | LC_ALL=C comm -13 - <(LC_ALL=C sort "$W/gh-names"))
  [ -z "$unstaged" ] || diff_ "on the pages but not staged: $(echo "$unstaged" | tr '\n' ' ')"
  [ "$DIFFS" -gt "$d0" ] || ok "pages equal the staged folder $RDIR"
fi

if [ "$DIFFS" -eq 0 ]; then echo "Result: PARITY ($TAG)"; exit 0; fi
echo "Result: $DIFFS difference(s) for $TAG"
exit 1
