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
#     line endings and the forge-specific forms of the same link (release
#     page, release file of TAG, raw/blob/tree links on main); see
#     tools/release-forge-lib.sh. Neither body may link to another release
#     (tools/check-release-links.sh with TAG as the current tag).
#   * status: the GitHub release is not a draft, its pre-release flag equals
#     --expect-prerelease when given, the GitLab release is not "upcoming";
#     and the stable addresses reach TAG: on GitHub the releases page
#     (github.com/<repo>/releases) lists TAG only (a pre-release is never
#     "latest" on GitHub, so /releases/latest is not used), on GitLab
#     gitlab.com/<p>/-/releases/permalink/latest resolves to TAG.
#   * assets (release layout, docs/IMAGE-HOSTING.md): the same files in the
#     same canonical order on both pages: every amd64 file (parts,
#     PARTS-amd64.sha256, SHA256SUMS-amd64), every arm64 file, then
#     ncz-join-image.sh, SHA256SUMS, NOTES.md; nothing else. Equal sizes and
#     sha256: GitHub sizes and digests come from the API (a file without an
#     API digest is downloaded and hashed); GitLab assets must be links into
#     the project's generic packages <package>-amd64, -arm64 and -common,
#     named <arch>/<file> for architecture files (link type package) and
#     <file> for common files (link type other), with the stable direct path
#     (/<arch>/ncz-os-<arch>.img.zst.part-NN, /<arch>/<file>, /<file>);
#     sizes and sha256 come from the registry.
#   * every file but the parts is downloaded anonymously from both pages and
#     must be byte-equal; SHA256SUMS must be SHA256SUMS-amd64 followed by
#     SHA256SUMS-arm64; each PARTS-<arch>.sha256 must list exactly the parts
#     of that architecture on the page, with their sha256.
#   * notes: one section heading (## or deeper) per architecture, amd64
#     first, each containing the sha256 of its images and the
#     "ncz-join-image.sh <arch>" command.
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
#   --package NAME              GitLab package prefix (default ncz-os-image, $NCZ_GITLAB_PACKAGE)
#   --release-dir DIR           also compare against a staged release folder
#   --repo-root DIR             checkout holding the screenshots (default: this repository)
#   --expect-prerelease yes|no  required state of the GitHub pre-release flag
#   --ignore-other-releases     report other releases but do not fail on them
#                               (used between publishing and retiring)
#   --no-latest-check           skip the stable address check
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
PACKAGE="${NCZ_GITLAB_PACKAGE:-ncz-os-image}"
TAG=""; QUICK=0; RDIR=""; REPO_ROOT=""; EXPECT_PRE=""; IGNORE_OTHERS=0; LATEST=1

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; }
udie() { rf_die "$*" 2; }
while [ $# -gt 0 ]; do
  case "$1" in
    --tag) TAG=${2:?--tag needs a tag}; shift 2 ;;
    --github-repo) GH_REPO=${2:?}; shift 2 ;;
    --gitlab-project) GL_PROJECT=${2:?}; shift 2 ;;
    --quick) QUICK=1; shift ;;
    --package) PACKAGE=${2:?}; shift 2 ;;
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
printf '%s' "$GH_REPO" | grep >/dev/null -E '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' || udie "invalid --github-repo: $GH_REPO"
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
rf_normalise_body "$W/gh-body.md" "$GH_REPO" "$GL_PROJECT" "$TAG" > "$W/gh-body.n"
rf_normalise_body "$W/gl-body.md" "$GH_REPO" "$GL_PROJECT" "$TAG" > "$W/gl-body.n"
# links to a release other than this one, in either body
for forge in gh gl; do
  if ! lk=$(bash "$HERE/check-release-links.sh" --current-tag "$TAG" --allow-part-names --files "$W/$forge-body.md" 2>&1); then
    fn=github; [ "$forge" = gl ] && fn=gitlab
    diff_ "$fn notes link to another release or use a link form that changes:"
    printf '%s\n' "$lk" | grep '^RELEASE-LINK' | sed 's/^RELEASE-LINK: [^:]*:/      line /'
  fi
done
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
  # GitHub: a pre-release is never "latest", so the stable GitHub address is the
  # releases page itself, which must list this release only.
  nrel=$(jq length "$W/gh-rels.json")
  if [ "$nrel" -eq 1 ]; then ok "GitHub releases page lists only $TAG (prerelease=$gh_pre)"
  elif [ "$IGNORE_OTHERS" -eq 1 ]; then info "GitHub releases page lists $nrel releases (the others are retired next)"
  else diff_ "GitHub releases page lists $nrel releases; it must list only $TAG"; fi
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
while IFS=$'\t' read -r lname url dpath ltype; do
  [ -n "$lname" ] || continue
  name=${lname#amd64/}; name=${name#arm64/}
  grp=$(rf_file_group "$name")
  if [ "$(rf_gl_link_name "$name")" != "$lname" ]; then diff_ "GitLab link '$lname': expected the name '$(rf_gl_link_name "$name")' (architecture files sit under <arch>/)"; fi
  want_path=$(rf_gl_path "$name")
  if [ "$dpath" != "$want_path" ]; then diff_ "GitLab link $lname: direct path '$dpath', expected stable alias '$want_path'"; fi
  if [ "$grp" = common ]; then want_lt=other; else want_lt=package; fi
  if [ "$ltype" != "$want_lt" ]; then diff_ "GitLab link $lname: link type '$ltype', expected $want_lt"; fi
  case "$url" in
    "$pkg_prefix"*) ;;
    *) diff_ "GitLab link $lname does not point at this project's generic package registry: $url"
       printf '%s\t-\t-\t%s\n' "$name" "$url" >> "$W/gl-assets.tsv"; continue ;;
  esac
  rest=${url#"$pkg_prefix"}; pkg=${rest%%/*}; rest=${rest#*/}; ver=${rest%%/*}; file=${rest#*/}
  if [ "$pkg" != "$PACKAGE-$grp" ]; then diff_ "GitLab link $lname points into package '$pkg', expected $PACKAGE-$grp"; fi
  if [ "$file" != "$name" ]; then diff_ "GitLab link $lname points at the package file '$file'"; fi
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
  if [ -z "$row" ]; then diff_ "GitLab link $lname: package file $pkg $ver $file not found"; row=$'-\t-'; fi
  printf '%s\t%s\t%s\n' "$name" "$row" "$url" >> "$W/gl-assets.tsv"
done < "$W/gl-links.tsv"

cut -f1 "$W/gh-assets.tsv" > "$W/gh-names"; cut -f1 "$W/gl-assets.tsv" > "$W/gl-names"
if cmp -s "$W/gh-names" "$W/gl-names"; then ok "asset names and order ($(wc -l < "$W/gh-names" | tr -d ' ') files)"
elif cmp -s <(sort "$W/gh-names") <(sort "$W/gl-names"); then diff_ "asset order differs (same names)"
else
  diff_ "asset names differ (- GitHub only, + GitLab only):"
  diff <(sort "$W/gh-names") <(sort "$W/gl-names") | grep -E '^[<>]' | sed 's/^</      -/; s/^>/      +/'
fi

# canonical order and file set: amd64 files, arm64 files, common files
for forge in gh gl; do
  fn=github; [ "$forge" = gl ] && fn=gitlab
  if [ -s "$W/$forge-names" ] && ! cmp -s "$W/$forge-names" <(rf_canonical_sort < "$W/$forge-names"); then
    diff_ "$fn files are not in the canonical order (amd64 files, arm64 files, then ncz-join-image.sh SHA256SUMS NOTES.md); expected:"
    rf_canonical_sort < "$W/$forge-names" | sed 's/^/      /'
  fi
done
ARCHES_ON=()
for a in "${RF_ARCHES[@]}"; do
  if grep -q "^ncz-os-$a-.*\.img\.zst\.part-" "$W/gh-names"; then
    ARCHES_ON+=("$a")
    for f in "PARTS-$a.sha256" "SHA256SUMS-$a"; do grep -qxF "$f" "$W/gh-names" || diff_ "$f is missing ($a parts are on the page)"; done
  else
    for f in "PARTS-$a.sha256" "SHA256SUMS-$a"; do grep -qxF "$f" "$W/gh-names" && diff_ "$f is on the page but there are no $a parts"; done
  fi
done
[ "${#ARCHES_ON[@]}" -gt 0 ] || diff_ "no image parts on the GitHub page"
for f in "${RF_COMMON_FILES[@]}"; do grep -qxF "$f" "$W/gh-names" || grep >/dev/null -xF "$f" "$W/gl-names" || diff_ "$f is on neither release page"; done
while IFS= read -r n; do
  case "$n" in ncz-os-amd64-*.img.zst.part-*|ncz-os-arm64-*.img.zst.part-*|PARTS-amd64.sha256|PARTS-arm64.sha256|SHA256SUMS-amd64|SHA256SUMS-arm64|ncz-join-image.sh|SHA256SUMS|NOTES.md) ;;
    *) diff_ "unexpected file on a release page: $n (not part of the release layout)" ;;
  esac
done < <(sort -u "$W/gh-names" "$W/gl-names")
[ "${#ARCHES_ON[@]}" -eq 0 ] || ok "file set: ${ARCHES_ON[*]} with their PARTS and SHA256SUMS files, plus the common files"

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
while IFS= read -r f; do
  case "$f" in *.img.zst.part-*) continue ;; esac
  [ -n "${GHZ[$f]:-}" ] && [ -n "${GLZ[$f]:-}" ] || continue   # already reported as a name difference
  c1=$(rf_download "${GHU[$f]}" "$W/gh-$f")
  c2=$(rf_download "$RF_GITLAB_WEB/$GL_PROJECT/-/releases/$(rf_uri "$TAG")/downloads$(rf_gl_path "$f")" "$W/gl-$f")
  if [ "$c1" != 200 ] || [ "$c2" != 200 ]; then diff_ "$f download: GitHub HTTP $c1, GitLab HTTP $c2 (GitLab path $(rf_gl_path "$f"))"; rm -f "$W/gh-$f"; continue; fi
  if cmp -s "$W/gh-$f" "$W/gl-$f"; then ok "$f byte-equal ($(rf_size "$W/gh-$f") bytes)"
  else
    diff_ "$f content differs (- GitHub, + GitLab):"
    diff -u --label github --label gitlab "$W/gh-$f" "$W/gl-$f" | sed 's/^/      /' | head -40
  fi
done < "$W/gh-names"
# the checksum files agree with each other and with the parts on the page
if [ -f "$W/gh-SHA256SUMS" ] && [ "${#ARCHES_ON[@]}" -gt 0 ]; then
  cat_f=(); for a in "${ARCHES_ON[@]}"; do [ -f "$W/gh-SHA256SUMS-$a" ] && cat_f+=("$W/gh-SHA256SUMS-$a"); done
  if [ "${#cat_f[@]}" -eq "${#ARCHES_ON[@]}" ] && cmp -s "$W/gh-SHA256SUMS" <(cat "${cat_f[@]}"); then ok "SHA256SUMS = $(printf 'SHA256SUMS-%s ' "${ARCHES_ON[@]}")"
  else diff_ "SHA256SUMS is not $(printf 'SHA256SUMS-%s ' "${ARCHES_ON[@]}")in that order"; fi
fi
for a in "${ARCHES_ON[@]}"; do
  pf="$W/gh-PARTS-$a.sha256"; [ -f "$pf" ] || continue
  listed=$(awk '{ n = $2; sub(/^\*/, "", n); print n }' "$pf")
  onpage=$(grep "^ncz-os-$a-.*\.img\.zst\.part-" "$W/gh-names")
  if [ "$listed" != "$onpage" ]; then diff_ "PARTS-$a.sha256 does not list exactly the $a parts on the page, in order"; continue; fi
  bad=0
  if [ "$QUICK" -eq 0 ]; then
    while read -r want n; do n=${n#\*}; [ "${GHS[$n]:-}" = "$want" ] || { diff_ "PARTS-$a.sha256 has $want for $n, the page has ${GHS[$n]:-none}"; bad=1; }; done < "$pf"
  fi
  [ "$bad" -eq 1 ] || ok "PARTS-$a.sha256 lists the $a parts on the page"
done

# ---- notes: one section per architecture ------------------------------------------------------------
sargs=(); for a in "${ARCHES_ON[@]}"; do sargs+=("$a=$W/gh-SHA256SUMS-$a"); done
if [ "${#sargs[@]}" -gt 0 ]; then
  while IFS=$'\t' read -r st msg; do
    [ -n "$st" ] || continue
    if [ "$st" = ok ]; then ok "$msg"; else diff_ "$msg"; fi
  done < <(rf_check_sections "$W/gh-body.n" "${sargs[@]}")
fi

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
    abs=$(rf_normalise_body "$W/u.txt" "$GH_REPO" "$GL_PROJECT" "$TAG")
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
  if ! rf_layout "$RDIR" > "$W/local-layout.tsv"; then diff_ "the staged folder $RDIR does not match the release layout"
  else
    : > "$W/local-names"
    while IFS=$'\t' read -r _ rel n; do
      echo "$n" >> "$W/local-names"
      if [ -z "${GHZ[$n]:-}" ]; then diff_ "staged $n is not on the GitHub page"; continue; fi
      if [ "$(rf_size "$RDIR/$rel")" != "${GHZ[$n]}" ]; then diff_ "staged $n size $(rf_size "$RDIR/$rel") vs pages ${GHZ[$n]}"; continue; fi
      if [ "$QUICK" -eq 0 ] && [ "${GHS[$n]:-}" != "$(rf_sha "$RDIR/$rel")" ]; then diff_ "staged $n sha256 differs from the GitHub page"; fi
    done < "$W/local-layout.tsv"
    cmp -s "$W/local-names" "$W/gh-names" || [ "$DIFFS" -gt "$d0" ] || diff_ "the page order differs from the staged canonical order"
    unstaged=$(LC_ALL=C sort "$W/local-names" | LC_ALL=C comm -13 - <(LC_ALL=C sort "$W/gh-names"))
    [ -z "$unstaged" ] || diff_ "on the pages but not staged: $(echo "$unstaged" | tr '\n' ' ')"
  fi
  [ "$DIFFS" -gt "$d0" ] || ok "pages equal the staged folder $RDIR"
fi

if [ "$DIFFS" -eq 0 ]; then echo "Result: PARITY ($TAG)"; exit 0; fi
echo "Result: $DIFFS difference(s) for $TAG"
exit 1
