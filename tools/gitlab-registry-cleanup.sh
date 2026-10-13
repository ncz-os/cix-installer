#!/bin/bash
# gitlab-registry-cleanup.sh - apply retention rules to GitLab generic packages.
#
# Usage:
#   tools/gitlab-registry-cleanup.sh [--rules FILE] [--apply] [options]
#
# Reads retention rules (default tools/registry-retention.conf) and, for each
# rule, lists the generic packages of that name in that project and works out
# what the rule removes:
#   * versions whose name matches the rule's version pattern, newest first by
#     created_at; the newest KEEP versions stay, older ones are removed
#     (KEEP "all" keeps every matching version)
#   * with dedupe "yes": inside every version that stays, only the newest file
#     of each file name is kept; older copies of the same name are removed
# A version is never removed while an asset link of any release in the project
# points at it (it is reported as kept). Packages that no rule names are never
# looked at. Package types other than generic are never touched.
#
# Without --apply nothing is changed: the plan is printed and, with
# --manifest, written out. With --apply the manifest is written first, then
# every removal is made one request at a time and each result is printed.
#
# Rules file: one rule per line, whitespace separated, '#' starts a comment:
#   PROJECT  PACKAGE  VERSION-REGEX  KEEP  DEDUPE
#   ncz-os/cix-installer  ncz-os-image  .  2  yes
# VERSION-REGEX is a jq (Oniguruma) regular expression matched against the
# version; KEEP is a number >= 1 or "all"; DEDUPE is "yes" or "no". A version
# matched by an earlier rule of the same project and package is not counted
# again by a later one.
#
# Options:
#   --rules FILE      rules file (default: registry-retention.conf next to
#                     this script)
#   --apply           make the removals (default is a dry run)
#   --manifest FILE   write the planned removals as JSON (package ids, file
#                     names, sizes, sha256) before anything is removed
#   --log FILE        append one summary line per rule and run (UTC time,
#                     mode, counts, bytes) to FILE
#   --api URL         API base (default https://gitlab.com/api/v4, or
#                     $NCZ_GITLAB_API)
#   -h, --help        this text
#
# Token: never passed on a command line or printed. It is read from the
# command named by $NCZ_GITLAB_TOKEN_HELPER (run with no arguments, like
# GIT_ASKPASS; its stdout is the token), otherwise from the environment
# variable whose NAME is in $NCZ_GITLAB_TOKEN_VAR (default GITLAB_TOKEN).
# It reaches curl on stdin as a config file. Listing needs read_api, removal
# needs the api scope.
#
# Exit codes: 0 ok, 1 API failure, 2 usage or input error.
set -euo pipefail

if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
  echo "ERROR: bash >= 4 required" >&2; exit 2
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
API="${NCZ_GITLAB_API:-https://gitlab.com/api/v4}"
RULES="$HERE/registry-retention.conf"
APPLY=0; MANIFEST=""; LOGF=""

usage() { sed -n '2,50p' "$0" | sed 's/^# \{0,1\}//'; }
die() { echo "ERROR: $1" >&2; exit "${2:-1}"; }
udie() { die "$*" 2; }
log() { echo "$*"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --rules) RULES=${2:?--rules needs a file}; shift 2 ;;
    --apply) APPLY=1; shift ;;
    --dry-run) APPLY=0; shift ;;
    --manifest) MANIFEST=${2:?--manifest needs a file}; shift 2 ;;
    --log) LOGF=${2:?--log needs a file}; shift 2 ;;
    --api) API=${2:?}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) udie "unknown argument: $1 (try --help)" ;;
  esac
done
API=${API%/}
for t in jq curl; do command -v "$t" >/dev/null 2>&1 || udie "$t is required"; done
[ -r "$RULES" ] || udie "cannot read rules file: $RULES"

# ---- rules ------------------------------------------------------------------
RULE_LINES=()
n=0
while read -r proj pkg vre keep dedupe extra; do
  n=$((n+1))
  case "${proj:-}" in ''|'#'*) continue ;; esac
  [ -n "${dedupe:-}" ] && [ -z "${extra:-}" ] || udie "$RULES:$n: need exactly 5 fields"
  printf '%s' "$proj" | grep -Eq '^[A-Za-z0-9._/-]+$' || udie "$RULES:$n: bad project: $proj"
  printf '%s' "$pkg" | grep -Eq '^[A-Za-z0-9._+~-]+$' || udie "$RULES:$n: bad package name: $pkg"
  case "$keep" in all) ;; ''|*[!0-9]*) udie "$RULES:$n: KEEP must be a number or all" ;; esac
  [ "$keep" = all ] || [ "$keep" -ge 1 ] || udie "$RULES:$n: KEEP must be at least 1"
  case "$dedupe" in yes|no) ;; *) udie "$RULES:$n: DEDUPE must be yes or no" ;; esac
  jq -n --arg r "$vre" '"x" | test($r)' >/dev/null 2>&1 || udie "$RULES:$n: bad version regex: $vre"
  RULE_LINES+=("$proj $pkg $vre $keep $dedupe")
done < "$RULES"
[ "${#RULE_LINES[@]}" -gt 0 ] || udie "no rules in $RULES"

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
[ -n "$TOKEN" ] || udie "no token (set NCZ_GITLAB_TOKEN_HELPER or NCZ_GITLAB_TOKEN_VAR)"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/glclean.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
BODY="$WORK/body"
uri() { jq -rn --arg s "$1" '$s|@uri'; }

# api METHOD URL -> response in $BODY, HTTP code on stdout
api() {
  printf 'header = "PRIVATE-TOKEN: %s"\n' "$TOKEN" |
    curl -sS -K - -X "$1" -o "$BODY" -w '%{http_code}' "$2" || echo 000
}
get() { local c; c=$(api GET "$1"); [ "$c" = 200 ] || die "GET $1 returned HTTP $c: $(head -c 300 "$BODY" 2>/dev/null)"; }
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
# remove URL: 2xx or 404 (already gone) is success; retried on other codes
remove() {
  local c attempt
  for attempt in 1 2 3; do
    c=$(api DELETE "$1")
    case "$c" in 2??|404) echo "$c"; return 0 ;; esac
    sleep $((attempt * 3))
  done
  echo "$c"; return 1
}

# ---- plan -------------------------------------------------------------------
PLAN="$WORK/plan.json"
echo '[]' > "$PLAN"
declare -A PID_OF=() SEEN=()
for rule in "${RULE_LINES[@]}"; do
  read -r proj pkg vre keep dedupe <<<"$rule"
  if [ -z "${PID_OF[$proj]:-}" ]; then
    get "$API/projects/$(uri "$proj")"
    pid=$(jq -r '.id' "$BODY")
    case "$pid" in ''|null|*[!0-9]*) die "could not resolve project $proj" ;; esac
    PID_OF[$proj]=$pid
    get_all "$API/projects/$pid/releases" > "$WORK/rel-$pid.json"
    get_all "$API/projects/$pid/packages?package_type=generic" > "$WORK/pkgs-$pid.json"
  fi
  pid=${PID_OF[$proj]}
  # versions of this package matching the rule, newest first
  jq --arg n "$pkg" --arg r "$vre" \
    '[.[] | select(.package_type=="generic" and .name==$n and (.version|test($r)))] | sort_by(.created_at, .id) | reverse' \
    "$WORK/pkgs-$pid.json" > "$WORK/match.json"
  # release links that point at a version of this package
  jq -r --arg n "$pkg" '.[] | .assets.links[]?.url // empty | select(test("/packages/generic/" + $n + "/"))
      | capture("/packages/generic/[^/]+/(?<v>[^/]+)/").v' "$WORK/rel-$pid.json" | sort -u > "$WORK/linked.txt"
  idx=0; kept=0
  while read -r id ver created; do
    key="$pid/$id"
    if [ -n "${SEEN[$key]:-}" ]; then continue; fi
    SEEN[$key]=1
    idx=$((idx+1))
    get_all "$API/projects/$pid/packages/$id/package_files" > "$WORK/files.json"
    if [ "$keep" = all ] || [ "$idx" -le "$keep" ] || grep -qxF -- "$ver" "$WORK/linked.txt"; then
      if [ "$keep" != all ] && [ "$idx" -gt "$keep" ]; then
        log "  keep     $proj $pkg $ver (a release links to it)"
      fi
      kept=$((kept+1))
      [ "$dedupe" = yes ] || continue
      jq --arg p "$proj" --argjson pid "$pid" --arg n "$pkg" --arg v "$ver" --argjson id "$id" '
        group_by(.file_name) | map(sort_by(.created_at, .id) | reverse | .[1:]) | add // []
        | map({kind:"file", project:$p, project_id:$pid, package:$n, version:$v, package_id:$id,
               file_id:.id, file_name, size, sha256:.file_sha256, created_at})' \
        "$WORK/files.json" > "$WORK/add.json"
    else
      jq --arg p "$proj" --argjson pid "$pid" --arg n "$pkg" --arg v "$ver" --argjson id "$id" --arg c "$created" '
        [{kind:"package", project:$p, project_id:$pid, package:$n, version:$v, package_id:$id, created_at:$c,
          size:(map(.size)|add // 0),
          files: map({file_id:.id, file_name, size, sha256:.file_sha256})}]' \
        "$WORK/files.json" > "$WORK/add.json"
    fi
    jq -s '.[0] + .[1]' "$PLAN" "$WORK/add.json" > "$PLAN.n" && mv "$PLAN.n" "$PLAN"
  done < <(jq -r '.[] | "\(.id) \(.version) \(.created_at)"' "$WORK/match.json")
  log "rule: $proj $pkg /$vre/ keep=$keep dedupe=$dedupe: $idx matching versions, $kept kept"
done

npk=$(jq '[.[] | select(.kind=="package")] | length' "$PLAN")
nfi=$(jq '[.[] | select(.kind=="file")] | length' "$PLAN")
bytes=$(jq '[.[].size] | add // 0' "$PLAN")
jq -r '.[] | if .kind=="package"
  then "  remove   package \(.project) \(.package) \(.version) (\(.files|length) files, \(.size) bytes, created \(.created_at))"
  else "  remove   file    \(.project) \(.package) \(.version) \(.file_name) #\(.file_id) (\(.size) bytes, created \(.created_at))" end' "$PLAN"
MODE=dry-run; [ "$APPLY" -eq 1 ] && MODE=apply
log "plan: $npk versions and $nfi duplicate files, $bytes bytes ($MODE)"

if [ -n "$MANIFEST" ]; then
  jq --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg m "$MODE" '{written_at:$t, mode:$m, removals:.}' "$PLAN" > "$MANIFEST"
  log "manifest: $MANIFEST"
fi

summary() { # $1 result
  [ -n "$LOGF" ] || return 0
  printf '%s gitlab-registry-cleanup %s rules=%s versions=%s files=%s bytes=%s result=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$MODE" "${RULES##*/}" "$npk" "$nfi" "$bytes" "$1" >> "$LOGF"
}

if [ "$APPLY" -eq 0 ]; then
  summary planned
  log "Dry run: nothing was changed."
  exit 0
fi

# ---- apply ------------------------------------------------------------------
failed=0
while read -r kind pid id fid label; do
  if [ "$kind" = package ]; then url="$API/projects/$pid/packages/$id"
  else url="$API/projects/$pid/packages/$id/package_files/$fid"; fi
  if c=$(remove "$url"); then log "  removed  $label (HTTP $c)"
  else log "  FAILED   $label (HTTP $c)"; failed=$((failed+1)); fi
done < <(jq -r '.[] | "\(.kind) \(.project_id) \(.package_id) \(.file_id // 0) \(.package) \(.version) \(.file_name // "")"' "$PLAN")

if [ "$failed" -gt 0 ]; then summary "failed=$failed"; die "$failed removals failed"; fi
summary ok
log "Done: $npk versions and $nfi duplicate files removed."
