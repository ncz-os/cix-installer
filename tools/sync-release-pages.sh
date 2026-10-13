#!/bin/bash
# sync-release-pages.sh - publish one staged release to the GitHub and GitLab
# release pages so both show the same release, then retire every other
# release page, so each forge has exactly one release page.
#
# Usage:
#   tools/sync-release-pages.sh --dir DIR --tag TAG                 # dry run (default)
#   tools/sync-release-pages.sh --dir DIR --tag TAG --apply \
#       --operator-approved APPROVAL --audit-ok AUDIT
#
# DIR is the single source of truth for the release:
#   NOTES.md        release notes (Markdown) in the GitLab link form; the
#                   GitHub body is the same text with the GitLab links of
#                   main / latest release replaced by their GitHub forms
#                   (tools/release-forge-lib.sh). Also attached as a file.
#   TITLE           one line: the release title on both forges
#   PRERELEASE      "yes" or "no": the GitHub pre-release flag (GitLab has
#                   no such flag; say "preview" in TITLE and NOTES.md)
#   amd64/          ncz-os-amd64-<date>-<build>.img.zst.part-NN, PARTS-amd64.sha256,
#                   SHA256SUMS-amd64
#   arm64/          the same for arm64 (one or both architectures)
#   ncz-join-image.sh, SHA256SUMS (= SHA256SUMS-amd64 followed by SHA256SUMS-arm64)
# (the release layout, docs/IMAGE-HOSTING.md). NOTES.md has one section per
# architecture, amd64 first, each with its images' sha256 and the
# "ncz-join-image.sh <arch>" command.
#
# TAG is required and must already exist on both forges: this tool never
# creates, moves or deletes git tags.
#
# Order of work (each step only runs when the previous one succeeded):
#   1. local checks: the release layout (parts against their PARTS files),
#      file names and size limits, TITLE/PRERELEASE, the architecture
#      sections of NOTES.md, NOTES.md has no links to a specific release
#      (tools/check-release-links.sh) and every screenshot it references is
#      an absolute raw URL on main of the GitLab project whose file exists
#      in --repo-root
#   2. gates (--apply only): the approval file names TAG, the audit file
#      passes every image in SHA256SUMS
#   3. GitLab: tools/publish-release-gitlab.sh --prune-old (one package per
#      architecture plus a common package, release, links in amd64/ and
#      arm64/ folders with stable direct paths; older versions removed per
#      package)
#   4. GitHub: release created or its title/body/flag updated; assets
#      uploaded in the canonical order (all amd64 files, all arm64 files,
#      then ncz-join-image.sh, SHA256SUMS, NOTES.md), each verified by size
#      and sha256; files not in DIR removed from this release
#   5. tools/check-release-parity.sh --ignore-other-releases must pass
#   6. retire: every other release object on both forges is deleted (their
#      git tags are kept); a release already gone is a no-op
#   7. tools/check-release-parity.sh (full: one release page per forge)
# A dry run performs the local checks, reads both forges and prints every
# change steps 3-6 would make, including each release that would be retired.
#
# Options:
#   --dir DIR                 staged release folder (required)
#   --tag TAG                 existing tag of the new release (required), e.g. v26.10-preview2
#   --apply                   make the changes (default: dry run)
#   --operator-approved FILE  approval file; a line must be TAG (or "tag=TAG"
#                             or "approve TAG"). Also $NCZ_RELEASE_APPROVAL_FILE.
#   --audit-ok FILE           image audit result; every image sha256 in SHA256SUMS
#                             needs a line "PASS <sha256> [name]" and no line
#                             may start with FAIL. Also $NCZ_RELEASE_AUDIT_FILE.
#   --no-retire               stop after step 5 (other releases stay; the
#                             final full parity check then reports them)
#   --allow-prerelease        allow PRERELEASE=yes; GitHub never treats a
#                             pre-release as "latest", so the stable
#                             releases/latest links will not reach it and the
#                             latest check is skipped
#   --github-repo OWNER/NAME  default ncz-os/cix-installer ($NCZ_GITHUB_REPO)
#   --gitlab-project PATH     default ncz-os/cix-installer ($NCZ_GITLAB_PROJECT)
#   --repo-root DIR           checkout holding the screenshots (default: this repository)
#   -h, --help                this text
#
# Tokens: see tools/release-forge-lib.sh. --apply needs both; a dry run reads
# anonymously when a token is missing. Tokens are never printed.
#
# Exit codes: 0 ok, 1 API, verification or parity failure, 2 usage, input or gate error.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tools/release-forge-lib.sh
. "$HERE/release-forge-lib.sh"

GH_REPO="${NCZ_GITHUB_REPO:-ncz-os/cix-installer}"
GL_PROJECT="${NCZ_GITLAB_PROJECT:-ncz-os/cix-installer}"
DIR=""; TAG=""; APPLY=0; RETIRE=1; ALLOW_PRE=0; REPO_ROOT=""
APPROVAL="${NCZ_RELEASE_APPROVAL_FILE:-}"; AUDIT="${NCZ_RELEASE_AUDIT_FILE:-}"
GH_MAX_BYTES="${NCZ_GITHUB_MAX_FILE_BYTES:-2147483648}"

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; }
udie() { rf_die "$*" 2; }
die() { rf_die "$*" 1; }
log() { echo "$*"; }
while [ $# -gt 0 ]; do
  case "$1" in
    --dir) DIR=${2:?--dir needs a folder}; shift 2 ;;
    --tag) TAG=${2:?--tag needs a tag}; shift 2 ;;
    --apply) APPLY=1; shift ;;
    --operator-approved) APPROVAL=${2:?}; shift 2 ;;
    --audit-ok) AUDIT=${2:?}; shift 2 ;;
    --no-retire) RETIRE=0; shift ;;
    --allow-prerelease) ALLOW_PRE=1; shift ;;
    --github-repo) GH_REPO=${2:?}; shift 2 ;;
    --gitlab-project) GL_PROJECT=${2:?}; shift 2 ;;
    --repo-root) REPO_ROOT=${2:?}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) udie "unknown argument: $1 (try --help)" ;;
  esac
done
[ -n "$DIR" ] || udie "--dir is required"
[ -n "$TAG" ] || udie "--tag is required (the operator names the release tag)"
[ -d "$DIR" ] || udie "not a folder: $DIR"
DIR=$(cd "$DIR" && pwd)
printf '%s' "$TAG" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]*$' || udie "invalid tag: $TAG"
printf '%s' "$GH_REPO" | grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' || udie "invalid --github-repo: $GH_REPO"
for t in jq curl python3; do command -v "$t" >/dev/null 2>&1 || udie "$t is required"; done
[ -n "$REPO_ROOT" ] || REPO_ROOT=$(git -C "$HERE" rev-parse --show-toplevel 2>/dev/null || (cd "$HERE/.." && pwd))
MODE="dry run"; [ "$APPLY" -eq 1 ] && MODE="apply"
log "== sync-release-pages ($MODE): $TAG from $DIR"
log "   GitHub $GH_REPO   GitLab $GL_PROJECT"

# ---- 1. local checks ------------------------------------------------------------
for f in NOTES.md TITLE PRERELEASE; do
  [ -f "$DIR/$f" ] || udie "$f not found in $DIR"
done
TITLE=$(cat "$DIR/TITLE"); PRE=$(tr -d ' \r\n' < "$DIR/PRERELEASE")
[ -n "$TITLE" ] && [ "$(grep -c '' "$DIR/TITLE")" -eq 1 ] || udie "TITLE must be exactly one non-empty line"
case "$PRE" in yes|no) ;; *) udie "PRERELEASE must be yes or no" ;; esac
if [ "$PRE" = yes ] && [ "$ALLOW_PRE" -eq 0 ]; then
  udie "PRERELEASE=yes: GitHub never makes a pre-release 'latest', so releases/latest links would not reach $TAG; set PRERELEASE=no (say 'preview' in TITLE/NOTES.md) or pass --allow-prerelease"
fi
[ -s "$DIR/NOTES.md" ] || udie "NOTES.md is empty"
[ "$(wc -c < "$DIR/NOTES.md")" -le 120000 ] || udie "NOTES.md is over the 120000 byte release body limit"

W0=$(mktemp -d "${TMPDIR:-/tmp}/relsync0.XXXXXX"); trap 'rm -rf "$W0"' EXIT
rf_layout "$DIR" --need-notes > "$W0/layout.tsv" || udie "the staged folder does not match the release layout (see above)"
FILES=(); ARCHES=()
declare -A LSHA=() LSIZE=() FPATH=()
while IFS=$'\t' read -r g rel f; do
  FILES+=("$f"); FPATH[$f]="$DIR/$rel"
  if [ "$g" != common ] && ! printf '%s\n' "${ARCHES[@]}" | grep -qxF "$g"; then ARCHES+=("$g"); fi
  LSIZE[$f]=$(rf_size "$DIR/$rel")
  [ "${LSIZE[$f]}" -lt "$GH_MAX_BYTES" ] || udie "$f is ${LSIZE[$f]} bytes; GitHub release files must be under $GH_MAX_BYTES"
  LSHA[$f]=$(rf_sha "$DIR/$rel")
done < "$W0/layout.tsv"
log "ok    staged folder: ${#FILES[@]} files (${ARCHES[*]} + common), parts verified against their PARTS files"
sargs=(); for a in "${ARCHES[@]}"; do sargs+=("$a=$DIR/$a/SHA256SUMS-$a"); done
sec_bad=0
while IFS=$'\t' read -r st msg; do
  [ -n "$st" ] || continue
  if [ "$st" = ok ]; then log "ok    $msg"; else echo "ERROR: $msg" >&2; sec_bad=1; fi
done < <(rf_check_sections "$DIR/NOTES.md" "${sargs[@]}")
[ "$sec_bad" -eq 0 ] || udie "NOTES.md needs one section per architecture (amd64 first) with its image sha256 and join command"

if ! links_out=$(bash "$HERE/check-release-links.sh" --files "$DIR/NOTES.md" 2>&1); then
  echo "$links_out" >&2; udie "NOTES.md links to a specific release; use the permalink forms (docs/IMAGE-HOSTING.md)"
fi
raw_prefix="$RF_GITLAB_WEB/$GL_PROJECT/-/raw/main/"
nimg=0
while IFS= read -r u; do
  [ -n "$u" ] || continue
  case "$u" in
    "$raw_prefix"*) rel=${u#"$raw_prefix"} ;;
    *) udie "NOTES.md image '$u' must be an absolute raw URL on main: $raw_prefix<path>" ;;
  esac
  [ -f "$REPO_ROOT/$rel" ] || udie "NOTES.md references a screenshot that is not in the repository: $rel"
  nimg=$((nimg+1))
done < <(rf_image_refs "$DIR/NOTES.md")
log "ok    NOTES.md: no release-specific links, $nimg screenshot(s) present in $REPO_ROOT"

# ---- 2. gates ---------------------------------------------------------------------
gate_ok=1
if [ -z "$APPROVAL" ] || [ ! -r "$APPROVAL" ]; then
  gate_ok=0; log "gate  operator approval: missing (--operator-approved FILE)"
elif awk -v t="$TAG" '{ gsub(/\r/, ""); sub(/^[ \t]+/, ""); sub(/[ \t]+$/, "") }
       $0 == t || $0 == "tag=" t || $0 == "approve " t { f = 1 } END { exit !f }' "$APPROVAL"; then
  log "gate  operator approval: $APPROVAL names $TAG"
else
  gate_ok=0; log "gate  operator approval: $APPROVAL does not name $TAG"
fi
if [ -z "$AUDIT" ] || [ ! -r "$AUDIT" ]; then
  gate_ok=0; log "gate  image audit: missing (--audit-ok FILE)"
elif grep -qiE '^[[:space:]]*FAIL' "$AUDIT"; then
  gate_ok=0; log "gate  image audit: $AUDIT has a FAIL line"
else
  miss=""
  while read -r s img; do
    [ -n "${img:-}" ] || continue
    grep -qE "^[[:space:]]*PASS[[:space:]]+$s([[:space:]]|\$)" "$AUDIT" || miss="$miss ${img#\*}"
  done < "$DIR/SHA256SUMS"
  if [ -n "$miss" ]; then gate_ok=0; log "gate  image audit: no PASS for$miss"
  else log "gate  image audit: every image in SHA256SUMS passed"; fi
fi
if [ "$APPLY" -eq 1 ] && [ "$gate_ok" -eq 0 ]; then
  udie "refusing to publish: the operator approval and audit gates must both pass (nothing was changed)"
fi

# ---- remote state ---------------------------------------------------------------------
rf_load_token github; rf_load_token gitlab
if [ "$APPLY" -eq 1 ]; then
  [ -n "${RF_TOKEN_GITHUB:-}" ] || udie "--apply needs a GitHub token"
  [ -n "${RF_TOKEN_GITLAB:-}" ] || udie "--apply needs a GitLab token"
fi
W=$(mktemp -d "${TMPDIR:-/tmp}/relsync.XXXXXX"); trap 'rm -rf "$W" "$W0"' EXIT
GL_PID=$(rf_project_id "$GL_PROJECT" "$W") || die "cannot resolve GitLab project $GL_PROJECT"
c=$(rf_api github GET "$RF_GITHUB_API/repos/$GH_REPO/git/ref/tags/$(rf_uri "$TAG")" "$W/t1")
[ "$c" = 200 ] || udie "tag $TAG does not exist on GitHub $GH_REPO (HTTP $c); this tool never creates tags"
c=$(rf_api gitlab GET "$RF_GITLAB_API/projects/$GL_PID/repository/tags/$(rf_uri "$TAG")" "$W/t2")
[ "$c" = 200 ] || udie "tag $TAG does not exist on GitLab $GL_PROJECT (HTTP $c); this tool never creates tags"
log "ok    tag $TAG exists on both forges"
rf_get_all github "$RF_GITHUB_API/repos/$GH_REPO/releases" "$W/gh-rels.json" || die "cannot list GitHub releases"
rf_get_all gitlab "$RF_GITLAB_API/projects/$GL_PID/releases" "$W/gl-rels.json" || die "cannot list GitLab releases"
rf_render_github "$DIR/NOTES.md" "$GH_REPO" "$GL_PROJECT" > "$W/gh-body.md"

# ---- 3. GitLab ------------------------------------------------------------------------
log "== GitLab: tools/publish-release-gitlab.sh"
glargs=(--dir "$DIR" --tag "$TAG" --project "$GL_PROJECT" --name "$TITLE" --notes "$DIR/NOTES.md" --prune-old)
[ "$APPLY" -eq 1 ] || glargs+=(--dry-run)
NCZ_GITLAB_TOKEN_HELPER="" NCZ_GITLAB_TOKEN_VAR=RF_TOKEN_GITLAB RF_TOKEN_GITLAB="${RF_TOKEN_GITLAB:-}" \
  bash "$HERE/publish-release-gitlab.sh" "${glargs[@]}" 2>&1 | sed 's/^/   /'
rc=${PIPESTATUS[0]}
[ "$rc" -eq 0 ] || die "GitLab publish failed (exit $rc)"

# ---- 4. GitHub ------------------------------------------------------------------------------
log "== GitHub: release $TAG"
GH_ID=$(jq -r --arg t "$TAG" '[.[] | select(.tag_name==$t)][0].id // empty' "$W/gh-rels.json")
jq -n --arg t "$TAG" --arg n "$TITLE" --rawfile b "$W/gh-body.md" --arg p "$PRE" \
  '{tag_name:$t, name:$n, body:$b, draft:false, prerelease:($p=="yes"), make_latest:(if $p=="yes" then "false" else "true" end)}' > "$W/rel.json"
gh_mut() { # METHOD URL [args] : obeys dry run, dies on non-2xx
  local m=$1 u=$2 c; shift 2
  if [ "$APPLY" -eq 0 ]; then log "   [dry-run] $m $u"; return 0; fi
  c=$(rf_api github "$m" "$u" "$W/resp.json" "$@")
  case "$c" in 2??) return 0 ;; esac
  die "GitHub $m $u returned HTTP $c: $(head -c 300 "$W/resp.json")"
}
if [ -z "$GH_ID" ]; then
  log "   create release $TAG ($TITLE, prerelease=$PRE)"
  gh_mut POST "$RF_GITHUB_API/repos/$GH_REPO/releases" "$W/rel.json"
  [ "$APPLY" -eq 0 ] || GH_ID=$(jq -r '.id' "$W/resp.json")
  echo '[]' > "$W/gh-assets.json"
else
  jq --arg t "$TAG" '[.[] | select(.tag_name==$t)][0]' "$W/gh-rels.json" > "$W/gh.json"
  if jq -e --arg n "$TITLE" --rawfile b "$W/gh-body.md" --arg p "$PRE" \
       '.name == $n and (.body // "") == $b and .prerelease == ($p == "yes") and .draft == false' "$W/gh.json" >/dev/null; then
    log "   release $TAG: title, body and flags already current"
  else
    log "   update release $TAG (title/body/flags)"
    jq 'del(.tag_name)' "$W/rel.json" > "$W/relu.json"
    gh_mut PATCH "$RF_GITHUB_API/repos/$GH_REPO/releases/$GH_ID" "$W/relu.json"
  fi
  jq '.assets | sort_by(.id)' "$W/gh.json" > "$W/gh-assets.json"
fi

# Assets in canonical order. From the first file that is missing or differs,
# every later file is re-uploaded too, so the order on the page stays canonical.
first_bad=-1; i=0
mapfile -t HAVE < <(jq -r '.[].name' "$W/gh-assets.json")
for f in "${FILES[@]}"; do
  row=$(jq -r --arg n "$f" '[.[] | select(.name==$n)][0] // empty | "\(.size) \((.digest // "") | sub("^sha256:";""))"' "$W/gh-assets.json")
  if [ "$first_bad" -lt 0 ] && { [ "${HAVE[$i]:-}" != "$f" ] || [ "$row" != "${LSIZE[$f]} ${LSHA[$f]}" ]; }; then first_bad=$i; fi
  i=$((i+1))
done
for n in "${HAVE[@]}"; do
  keep=0; i=0
  for f in "${FILES[@]}"; do
    if [ "$f" = "$n" ] && { [ "$first_bad" -lt 0 ] || [ "$i" -lt "$first_bad" ]; }; then keep=1; fi
    i=$((i+1))
  done
  [ "$keep" -eq 1 ] && continue
  aid=$(jq -r --arg n "$n" '[.[] | select(.name==$n)][0].id' "$W/gh-assets.json")
  log "   remove asset $n (id $aid)"
  gh_mut DELETE "$RF_GITHUB_API/repos/$GH_REPO/releases/assets/$aid"
done
i=0
for f in "${FILES[@]}"; do
  if [ "$first_bad" -lt 0 ] || [ "$i" -lt "$first_bad" ]; then log "   present  $f"; i=$((i+1)); continue; fi
  i=$((i+1))
  if [ "$APPLY" -eq 0 ]; then log "   [dry-run] upload $f (${LSIZE[$f]} bytes)"; continue; fi
  ok=0
  for attempt in 1 2 3; do
    c=$(rf_api github POST "$RF_GITHUB_UPLOADS/repos/$GH_REPO/releases/$GH_ID/assets?name=$(rf_uri "$f")" "$W/up.json" --upload "${FPATH[$f]}" application/octet-stream)
    if [ "$c" = 201 ]; then
      gsz=$(jq -r '.size' "$W/up.json"); gdg=$(jq -r '(.digest // "") | sub("^sha256:";"")' "$W/up.json")
      if [ "$gsz" = "${LSIZE[$f]}" ] && [ "$gdg" = "${LSHA[$f]}" ]; then ok=1; break; fi
      echo "   $f: GitHub reports size $gsz sha256 '${gdg:-none}', expected ${LSIZE[$f]} ${LSHA[$f]} (attempt $attempt)" >&2
    else
      echo "   upload of $f returned HTTP $c (attempt $attempt): $(head -c 200 "$W/up.json")" >&2
    fi
    # drop whatever the failed attempt left under this name before retrying
    rf_get_all github "$RF_GITHUB_API/repos/$GH_REPO/releases/$GH_ID/assets" "$W/cur.json" || true
    for aid in $(jq -r --arg n "$f" '.[] | select(.name==$n) | .id' "$W/cur.json" 2>/dev/null); do
      rf_api github DELETE "$RF_GITHUB_API/repos/$GH_REPO/releases/assets/$aid" "$W/del.json" >/dev/null
    done
  done
  [ "$ok" -eq 1 ] || die "upload of $f to GitHub failed verification"
  log "   uploaded $f (${LSHA[$f]})"
done

# ---- 5. parity -----------------------------------------------------------------------------
pargs=(--tag "$TAG" --github-repo "$GH_REPO" --gitlab-project "$GL_PROJECT" --release-dir "$DIR" --repo-root "$REPO_ROOT" --expect-prerelease "$PRE")
[ "$PRE" = no ] || pargs+=(--no-latest-check)
if [ "$APPLY" -eq 1 ]; then
  log "== parity (other releases ignored)"
  bash "$HERE/check-release-parity.sh" "${pargs[@]}" --ignore-other-releases 2>&1 | sed 's/^/   /'
  [ "${PIPESTATUS[0]}" -eq 0 ] || die "parity check failed after publishing; nothing was retired"
else
  log "== parity: runs here after publishing (dry run: not run)"
fi

# ---- 6. retire every other release ----------------------------------------------------------------
jq -r --arg t "$TAG" '.[] | select(.tag_name != $t) | "\(.id)\t\(.tag_name)\t\(.assets|length)\t\(.name)"' "$W/gh-rels.json" > "$W/gh-retire.tsv"
jq -r --arg t "$TAG" '.[] | select(.tag_name != $t) | "\(.tag_name)\t\(.assets.links|length)\t\(.name)"' "$W/gl-rels.json" > "$W/gl-retire.tsv"
if [ ! -s "$W/gh-retire.tsv" ] && [ ! -s "$W/gl-retire.tsv" ]; then
  log "== retire: no other release on either forge"
elif [ "$RETIRE" -eq 0 ]; then
  log "== retire: skipped (--no-retire); other releases:"
  sed 's/^/   github /' "$W/gh-retire.tsv"; sed 's/^/   gitlab /' "$W/gl-retire.tsv"
else
  log "== retire: every other release object (git tags are kept)"
  while IFS=$'\t' read -r id tg na nm; do
    log "   github: delete release $tg \"$nm\" with its $na asset(s) (id $id)"
    if [ "$APPLY" -eq 1 ]; then
      c=$(rf_api github DELETE "$RF_GITHUB_API/repos/$GH_REPO/releases/$id" "$W/del.json")
      case "$c" in 204|404) ;; *) die "GitHub delete of release $tg returned HTTP $c" ;; esac
    else log "   [dry-run] DELETE $RF_GITHUB_API/repos/$GH_REPO/releases/$id"; fi
  done < "$W/gh-retire.tsv"
  while IFS=$'\t' read -r tg nl nm; do
    log "   gitlab: delete release $tg \"$nm\" with its $nl link(s)"
    if [ "$APPLY" -eq 1 ]; then
      c=$(rf_api gitlab DELETE "$RF_GITLAB_API/projects/$GL_PID/releases/$(rf_uri "$tg")" "$W/del.json")
      case "$c" in 200|204|404) ;; *) die "GitLab delete of release $tg returned HTTP $c" ;; esac
    else log "   [dry-run] DELETE $RF_GITLAB_API/projects/$GL_PID/releases/$(rf_uri "$tg")"; fi
  done < "$W/gl-retire.tsv"
fi

# ---- 7. final parity --------------------------------------------------------------------------------
if [ "$APPLY" -eq 0 ]; then
  log "Dry run: nothing was changed."
  exit 0
fi
log "== final parity"
bash "$HERE/check-release-parity.sh" "${pargs[@]}" 2>&1 | sed 's/^/   /'
rc=${PIPESTATUS[0]}
[ "$rc" -eq 0 ] || die "final parity check failed (exit $rc)"
log "Done: $TAG is the one release page on both forges."
