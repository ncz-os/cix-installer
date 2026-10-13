#!/bin/bash
# publish-release-gitlab.sh - host a staged release on the GitLab generic
# package registry and attach the files to the GitLab release of a tag.
#
# Usage:
#   tools/publish-release-gitlab.sh --dir DIR --tag TAG [options]
#
# DIR is a staged release folder with one folder per architecture
# (docs/IMAGE-HOSTING.md, "Release layout"):
#   DIR/amd64/  ncz-os-amd64-<date>-<build>.img.zst.part-NN, PARTS-amd64.sha256, SHA256SUMS-amd64
#   DIR/arm64/  the same for arm64
#   DIR/        ncz-join-image.sh, SHA256SUMS (= SHA256SUMS-amd64 + SHA256SUMS-arm64),
#               optionally NOTES.md (attached as a file too)
# Every part is checked against its PARTS file before anything is sent.
# Each architecture is one generic package, <package>-<arch> (its parts, its
# PARTS and SHA256SUMS files and a copy of ncz-join-image.sh, so the package
# alone is a complete download); the common files are the package
# <package>-common. Files go to
#   <api>/projects/<id>/packages/generic/<package>-<group>/<version>/<file>
# and the sha256 the registry reports must equal the local one. A file that
# is already in that package version with the same sha256 is not sent again.
# The GitLab release for TAG is then created (or its name/notes updated) and
# gets one asset link per file, in the canonical order: the amd64 files as
# "amd64/<file>", the arm64 files as "arm64/<file>" (both link type package,
# so the page reads as one folder per architecture), then the common files
# (link type other). Links of the release that are not in this set are
# removed. Each link's direct path is a stable alias that does not change
# between releases (/<arch>/ncz-os-<arch>.img.zst.part-NN,
# /<arch>/PARTS-<arch>.sha256, /<arch>/SHA256SUMS-<arch>, /<common file>), so
#   https://gitlab.com/<project>/-/releases/permalink/latest/downloads/<alias>
# always reaches the latest release's file.
# The tag must already exist: this tool never creates tags.
#
# Options:
#   --dir DIR         staged release folder (required)
#   --tag TAG         existing git tag the release belongs to (required)
#   --project PATH    project path or numeric id (default ncz-os/cix-installer,
#                     or $NCZ_GITLAB_PROJECT)
#   --package NAME    generic package name prefix (default ncz-os-image:
#                     packages ncz-os-image-amd64, -arm64 and -common)
#   --version VER     package version (default: TAG without a leading "v")
#   --name TEXT       release title (default: TAG)
#   --notes FILE      Markdown file used as the release description
#   --api URL         API base (default https://gitlab.com/api/v4, or
#                     $NCZ_GITLAB_API)
#   --prune-old       after publishing, delete older versions of each of the
#                     three packages, keeping the newest --keep versions of
#                     each (the one just published always counts as kept),
#                     delete every version of the older single package
#                     <package> (no suffix), and remove the asset links of
#                     other releases that point at a deleted version. Other
#                     packages (e.g. the kernel source packages) are never
#                     touched.
#   --keep N          versions kept by --prune-old (default 1)
#   --dry-run         read-only: check the folder, query the API when a token
#                     is available, print every change that would be made
#   -h, --help        this text
#
# Token: never passed on a command line or printed. It is read from the
# command named by $NCZ_GITLAB_TOKEN_HELPER (run with no arguments, like
# GIT_ASKPASS; its stdout is the token), otherwise from the environment
# variable whose NAME is in $NCZ_GITLAB_TOKEN_VAR (default GITLAB_TOKEN).
# It reaches curl on stdin as a config file. The token needs the api scope.
#
# Limits: $NCZ_GITLAB_MAX_FILE_BYTES (default 5 GiB, the GitLab.com generic
# package file limit) is checked per file before upload.
#
# Exit codes: 0 ok, 1 API or verification failure, 2 usage or input error.
set -euo pipefail

API="${NCZ_GITLAB_API:-https://gitlab.com/api/v4}"
PROJECT="${NCZ_GITLAB_PROJECT:-ncz-os/cix-installer}"
PACKAGE="ncz-os-image"
DIR=""; TAG=""; VERSION=""; NAME=""; NOTES=""
PRUNE=0; KEEP=1; DRY=0
MAX_BYTES="${NCZ_GITLAB_MAX_FILE_BYTES:-5368709120}"

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; }
die() { echo "ERROR: $1" >&2; exit "${2:-1}"; }
udie() { die "$*" 2; }
log() { echo "$*"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --dir) DIR=${2:?--dir needs a folder}; shift 2 ;;
    --tag) TAG=${2:?--tag needs a tag}; shift 2 ;;
    --project) PROJECT=${2:?}; shift 2 ;;
    --package) PACKAGE=${2:?}; shift 2 ;;
    --version) VERSION=${2:?}; shift 2 ;;
    --name) NAME=${2:?}; shift 2 ;;
    --notes) NOTES=${2:?}; shift 2 ;;
    --api) API=${2:?}; shift 2 ;;
    --prune-old) PRUNE=1; shift ;;
    --keep) KEEP=${2:?}; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) udie "unknown argument: $1 (try --help)" ;;
  esac
done

[ -n "$DIR" ] || udie "--dir is required"
[ -n "$TAG" ] || udie "--tag is required"
[ -d "$DIR" ] || udie "not a folder: $DIR"
[ -z "$NOTES" ] || [ -r "$NOTES" ] || udie "cannot read notes file: $NOTES"
case "$KEEP" in ''|*[!0-9]*) udie "--keep needs a number" ;; esac
[ "$KEEP" -ge 1 ] || udie "--keep must be at least 1"
case "$MAX_BYTES" in ''|*[!0-9]*) udie "NCZ_GITLAB_MAX_FILE_BYTES must be a number" ;; esac
[ -n "$VERSION" ] || VERSION=${TAG#v}
[ -n "$NAME" ] || NAME=$TAG
# Registry naming rules (generic packages): name and file [A-Za-z0-9._+~-],
# version made of word characters, '.', '+' and '-'.
printf '%s' "$PACKAGE" | grep -Eq '^[A-Za-z0-9._+~-]+$' || udie "invalid package name: $PACKAGE"
printf '%s' "$VERSION" | grep -Eq '^[A-Za-z0-9_.+-]+$' || udie "invalid package version: $VERSION"
API=${API%/}
for t in jq curl; do command -v "$t" >/dev/null 2>&1 || udie "$t is required"; done
if command -v sha256sum >/dev/null 2>&1; then sha() { sha256sum "$1" | cut -d' ' -f1; }
elif command -v shasum >/dev/null 2>&1; then sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
else udie "need sha256sum or shasum"; fi
fsize() { wc -c < "$1" | tr -d ' '; }
uri() { jq -rn --arg s "$1" '$s|@uri'; }
WORK0=$(mktemp -d "${TMPDIR:-/tmp}/glpub0.XXXXXX")
trap 'rm -rf "$WORK0"' EXIT

# ---- the staged folder ------------------------------------------------------
# shellcheck source=tools/release-forge-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/release-forge-lib.sh"
rf_layout "$DIR" > "$WORK0/layout.tsv" || udie "the staged folder does not match the release layout (see above)"

FILES=(); declare -A FPATH=() FGROUP=() LSHA=()
while IFS=$'\t' read -r g rel f; do
  FILES+=("$f"); FPATH[$f]="$DIR/$rel"; FGROUP[$f]=$g
  s=$(fsize "$DIR/$rel")
  [ "$s" -le "$MAX_BYTES" ] || udie "$f is $s bytes, over the $MAX_BYTES byte file limit"
  LSHA[$f]=$(sha "$DIR/$rel")
done < "$WORK0/layout.tsv"
declare -A ALIAS=()
for f in "${FILES[@]}"; do
  a=$(rf_gl_path "$f")
  [ -z "${ALIAS[$a]:-}" ] || udie "$f and ${ALIAS[$a]} share the stable path $a (one image per architecture per release)"
  ALIAS[$a]=$f
done
GROUPS_USED=$(printf '%s\n' "${FGROUP[@]}" | sort -u | tr '\n' ' ')
# what goes into which package: the architecture files, plus a copy of the
# join script in each architecture package; the common files
UPLOADS=()   # "<package>\t<file>"
for f in "${FILES[@]}"; do UPLOADS+=("$PACKAGE-${FGROUP[$f]}"$'\t'"$f"); done
for g in $GROUPS_USED; do [ "$g" = common ] || UPLOADS+=("$PACKAGE-$g"$'\t'"ncz-join-image.sh"); done
log "Release folder: $DIR (${#FILES[@]} files: ${GROUPS_USED% }; parts verified against their PARTS files)"
log "Packages: $(for g in $GROUPS_USED; do printf '%s ' "$PACKAGE-$g"; done)version $VERSION   Tag: $TAG   Project: $PROJECT"

# ---- token and API helpers --------------------------------------------------
TOKEN=""
if [ -n "${NCZ_GITLAB_TOKEN_HELPER:-}" ]; then
  TOKEN=$("$NCZ_GITLAB_TOKEN_HELPER") || die "token helper failed"
else
  tv=${NCZ_GITLAB_TOKEN_VAR:-GITLAB_TOKEN}
  printf '%s' "$tv" | grep -Eq '^[A-Za-z_][A-Za-z0-9_]*$' || udie "NCZ_GITLAB_TOKEN_VAR is not a variable name"
  TOKEN=${!tv:-}
fi
TOKEN=$(printf '%s' "$TOKEN" | tr -d '\r\n')
case "$TOKEN" in *'"'*|*\\*) die "token contains characters that cannot be passed safely" ;; esac
if [ -z "$TOKEN" ]; then
  [ "$DRY" -eq 1 ] || die "no token (set NCZ_GITLAB_TOKEN_HELPER or NCZ_GITLAB_TOKEN_VAR)" 2
  log "No token: dry run without API lookups."
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/glpub.XXXXXX")
trap 'rm -rf "$WORK" "$WORK0"' EXIT
BODY="$WORK/body"

# api METHOD URL [json-body-file | --upload FILE]  ->  response in $BODY, code on stdout
api() {
  local m=$1 url=$2; shift 2
  local extra=()
  if [ $# -gt 0 ]; then
    if [ "$1" = --upload ]; then extra=(-T "$2"); else extra=(-H 'Content-Type: application/json' --data-binary "@$1"); fi
  fi
  printf 'header = "PRIVATE-TOKEN: %s"\n' "$TOKEN" |
    curl -sS -K - -X "$m" -o "$BODY" -w '%{http_code}' "${extra[@]}" "$url" || echo 000
}
# get URL  ->  fails unless 200
get() { local c; c=$(api GET "$1"); [ "$c" = 200 ] || die "GET $1 returned HTTP $c: $(head -c 300 "$BODY")"; }
# mutate METHOD URL [body]: obeys --dry-run
mutate() {
  local m=$1 url=$2 c; shift 2
  if [ "$DRY" -eq 1 ]; then log "  [dry-run] $m $url"; return 0; fi
  c=$(api "$m" "$url" "$@")
  case "$c" in 2??) return 0 ;; esac
  die "$m $url returned HTTP $c: $(head -c 300 "$BODY")"
}
# all pages of a list endpoint as one JSON array
get_all() {
  local url=$1 page=1 sep acc="$WORK/acc.json"
  echo '[]' > "$acc"
  case "$url" in *\?*) sep='&' ;; *) sep='?' ;; esac
  while :; do
    get "${url}${sep}per_page=100&page=$page"
    jq -s '.[0] + .[1]' "$acc" "$BODY" > "$acc.n" && mv "$acc.n" "$acc"
    [ "$(jq 'length' "$BODY")" -ge 100 ] || break
    page=$((page+1))
  done
  cat "$acc"
}

ONLINE=0; [ -n "$TOKEN" ] && ONLINE=1
PENC=$(uri "$PROJECT")
PID=$PENC
if [ "$ONLINE" -eq 1 ]; then
  get "$API/projects/$PENC"
  PID=$(jq -r '.id' "$BODY")
  case "$PID" in ''|null|*[!0-9]*) die "could not resolve project $PROJECT" ;; esac
  c=$(api GET "$API/projects/$PID/repository/tags/$(uri "$TAG")")
  [ "$c" = 200 ] || die "tag $TAG does not exist in $PROJECT (HTTP $c); create and push the tag first" 2
fi
pkgbase() { echo "$API/projects/$PID/packages/generic/$1/$VERSION"; }

# ---- uploads ----------------------------------------------------------------
# package_id PACKAGE -> id of its version $VERSION (empty if none)
package_id() {
  get_all "$API/projects/$PID/packages?package_type=generic&package_name=$(uri "$1")" > "$WORK/pkgs.json"
  jq -r --arg n "$1" --arg v "$VERSION" '[.[] | select(.name==$n and .version==$v)][0].id // empty' "$WORK/pkgs.json"
}
# existing files: "<package>/<file>" -> sha256 (newest wins)
declare -A RSHA=()
if [ "$ONLINE" -eq 1 ]; then
  for g in $GROUPS_USED; do
    pk="$PACKAGE-$g"; id=$(package_id "$pk")
    [ -n "$id" ] || continue
    get_all "$API/projects/$PID/packages/$id/package_files" > "$WORK/files.json"
    while read -r n s; do RSHA[$pk/$n]=$s; done < <(jq -r 'sort_by(.id)[] | "\(.file_name) \(.file_sha256)"' "$WORK/files.json")
  done
fi

for u in "${UPLOADS[@]}"; do
  pk=${u%%$'\t'*}; f=${u#*$'\t'}
  want=${LSHA[$f]}; src=${FPATH[$f]}; base=$(pkgbase "$pk")
  if [ "${RSHA[$pk/$f]:-}" = "$want" ]; then log "  present  $pk/$f"; continue; fi
  if [ "$DRY" -eq 1 ]; then log "  [dry-run] upload $pk/$f ($(fsize "$src") bytes) -> $base/$f"; continue; fi
  ok=0
  for attempt in 1 2 3; do
    c=$(api PUT "$base/$(uri "$f")?select=package_file" --upload "$src")
    if [ "$c" = 200 ] || [ "$c" = 201 ]; then
      got=$(jq -r '.file_sha256 // empty' "$BODY")
      if [ "$got" = "$want" ]; then ok=1; break; fi
      echo "  sha256 from the registry for $pk/$f is '$got', expected $want (attempt $attempt)" >&2
    else
      echo "  upload of $pk/$f returned HTTP $c (attempt $attempt): $(head -c 200 "$BODY")" >&2
    fi
  done
  [ "$ok" -eq 1 ] || die "upload of $pk/$f failed verification"
  log "  uploaded $pk/$f ($want)"
done

# Keep exactly one file per name in each package version: drop older
# duplicates so a download can only ever return the verified file.
if [ "$DRY" -eq 0 ]; then
  for g in $GROUPS_USED; do
    pk="$PACKAGE-$g"; id=$(package_id "$pk")
    [ -n "$id" ] || die "package $pk $VERSION not found after upload"
    get_all "$API/projects/$PID/packages/$id/package_files" > "$WORK/files.json"
    for u in "${UPLOADS[@]}"; do
      [ "${u%%$'\t'*}" = "$pk" ] || continue
      f=${u#*$'\t'}
      newest=$(jq -r --arg n "$f" --arg s "${LSHA[$f]}" '[.[] | select(.file_name==$n and .file_sha256==$s)] | max_by(.id) | .id // empty' "$WORK/files.json")
      [ -n "$newest" ] || die "$f with sha256 ${LSHA[$f]} is not in $pk $VERSION"
      for old in $(jq -r --arg n "$f" --argjson k "$newest" '.[] | select(.file_name==$n and .id!=$k) | .id' "$WORK/files.json"); do
        mutate DELETE "$API/projects/$PID/packages/$id/package_files/$old"
        log "  removed older copy of $pk/$f (file id $old)"
      done
    done
  done
fi

# ---- release and links ------------------------------------------------------
TENC=$(uri "$TAG")
jq -n --arg t "$TAG" --arg n "$NAME" --rawfile d "${NOTES:-/dev/null}" \
  '{tag_name:$t, name:$n} + (if $d == "" then {} else {description:$d} end)' > "$WORK/rel.json"
HAVE_REL=0
if [ "$ONLINE" -eq 1 ]; then
  c=$(api GET "$API/projects/$PID/releases/$TENC")
  case "$c" in
    200) HAVE_REL=1; jq '.assets.links' "$BODY" > "$WORK/links.json" ;;
    404) echo '[]' > "$WORK/links.json" ;;
    *) die "GET release $TAG returned HTTP $c" ;;
  esac
else
  echo '[]' > "$WORK/links.json"
fi
if [ "$HAVE_REL" -eq 1 ]; then
  log "Release $TAG exists: updating title${NOTES:+ and notes}"
  mutate PUT "$API/projects/$PID/releases/$TENC" "$WORK/rel.json"
else
  log "Creating release $TAG"
  mutate POST "$API/projects/$PID/releases" "$WORK/rel.json"
fi

WANT_LINKS=()
for f in "${FILES[@]}"; do
  url="$(pkgbase "$PACKAGE-${FGROUP[$f]}")/$f"
  ln=$(rf_gl_link_name "$f"); dp=$(rf_gl_path "$f")
  WANT_LINKS+=("$ln")
  if [ "${FGROUP[$f]}" = common ]; then lt=other; else lt=package; fi
  jq -n --arg n "$ln" --arg u "$url" --arg p "$dp" --arg l "$lt" \
    '{name:$n, url:$u, direct_asset_path:$p, link_type:$l}' > "$WORK/link.json"
  lid=$(jq -r --arg n "$ln" '[.[] | select(.name==$n)][0].id // empty' "$WORK/links.json")
  if [ -z "$lid" ]; then
    mutate POST "$API/projects/$PID/releases/$TENC/assets/links" "$WORK/link.json"
    log "  link added   $ln"
  elif [ "$(jq -r --arg n "$ln" '[.[] | select(.name==$n)][0] | "\(.url) \(.direct_asset_path // "") \(.link_type // "")"' "$WORK/links.json")" != "$url $dp $lt" ]; then
    mutate PUT "$API/projects/$PID/releases/$TENC/assets/links/$lid" "$WORK/link.json"
    log "  link updated $ln"
  else
    log "  link ok      $ln"
  fi
done
# links of this release that are not part of the staged set
while IFS=$'\t' read -r lid ln; do
  [ -n "$lid" ] || continue
  printf '%s\n' "${WANT_LINKS[@]}" | grep -qxF -- "$ln" && continue
  mutate DELETE "$API/projects/$PID/releases/$TENC/assets/links/$lid"
  log "  link removed $ln (not in the staged release)"
done < <(jq -r '.[] | "\(.id)\t\(.name)"' "$WORK/links.json")

# ---- retention ----------------------------------------------------------------
if [ "$PRUNE" -eq 1 ]; then
  if [ "$ONLINE" -eq 0 ]; then
    log "Prune: skipped (no token)"
  else
    get_all "$API/projects/$PID/releases" > "$WORK/rels.json"
    # "<package> <keep>": the per-group packages keep the newest --keep
    # versions; the older single package keeps none
    for pk_keep in "$PACKAGE-amd64 $KEEP" "$PACKAGE-arm64 $KEEP" "$PACKAGE-common $KEEP" "$PACKAGE 0"; do
      pk=${pk_keep% *}; k=${pk_keep#* }
      get_all "$API/projects/$PID/packages?package_type=generic&package_name=$(uri "$pk")" > "$WORK/pkgs.json"
      # newest first by creation; the version just published is always kept
      jq -r --arg n "$pk" --arg v "$VERSION" --argjson k "$k" '
        [.[] | select(.name==$n)] | sort_by(.created_at) | reverse as $all
        | ([$all[] | select(.version==$v)] + [$all[] | select(.version!=$v)])
        | .[$k:][] | "\(.id) \(.version)"' "$WORK/pkgs.json" > "$WORK/prune.txt"
      if [ ! -s "$WORK/prune.txt" ]; then
        log "Prune: nothing to remove from $pk"
        continue
      fi
      while read -r id ver; do
        prefix="/packages/generic/$pk/$ver/"
        jq -r --arg p "$prefix" --arg t "$TAG" '.[] | select(.tag_name != $t) | .tag_name as $tg
          | .assets.links[] | select(.url | contains($p)) | "\($tg)\t\(.id)\t\(.name)"' "$WORK/rels.json" |
        while IFS=$'\t' read -r tg lid lname; do
          mutate DELETE "$API/projects/$PID/releases/$(uri "$tg")/assets/links/$lid"
          log "  link removed from $tg: $lname"
        done
        mutate DELETE "$API/projects/$PID/packages/$id"
        log "  package version removed: $pk $ver (id $id)"
      done < "$WORK/prune.txt"
    done
  fi
fi

if [ "$DRY" -eq 1 ]; then log "Dry run: nothing was changed."
else log "Done: $VERSION published for release $TAG ($(for g in $GROUPS_USED; do printf '%s ' "$PACKAGE-$g"; done | sed 's/ $//'))."; fi
