# release-forge-lib.sh - shared helpers for the release page tools
# (tools/check-release-parity.sh, tools/sync-release-pages.sh).
# Source it; it defines functions only and changes no shell options.
#
# Forges: "github" (REST API v3) and "gitlab" (REST API v4).
#
# Tokens are never passed on a command line or printed. For each forge the
# token is read from the command named by NCZ_<FORGE>_TOKEN_HELPER (run with
# no arguments, its stdout is the token), otherwise from the environment
# variable whose NAME is in NCZ_<FORGE>_TOKEN_VAR (defaults GITHUB_TOKEN and
# GITLAB_TOKEN). The token reaches curl on stdin as a config file. Without a
# token, API reads are anonymous (public projects only, lower rate limits).
# File downloads are always anonymous, so a token is never sent to a CDN or
# a redirect target.

RF_GITHUB_API="${NCZ_GITHUB_API:-https://api.github.com}"
RF_GITHUB_UPLOADS="${NCZ_GITHUB_UPLOADS:-https://uploads.github.com}"
RF_GITHUB_WEB="${NCZ_GITHUB_WEB:-https://github.com}"
RF_GITHUB_RAW="${NCZ_GITHUB_RAW:-https://raw.githubusercontent.com}"
RF_GITLAB_API="${NCZ_GITLAB_API:-https://gitlab.com/api/v4}"
RF_GITLAB_WEB="${NCZ_GITLAB_WEB:-https://gitlab.com}"
RF_GITHUB_API=${RF_GITHUB_API%/}; RF_GITHUB_UPLOADS=${RF_GITHUB_UPLOADS%/}
RF_GITHUB_WEB=${RF_GITHUB_WEB%/}; RF_GITHUB_RAW=${RF_GITHUB_RAW%/}
RF_GITLAB_API=${RF_GITLAB_API%/}; RF_GITLAB_WEB=${RF_GITLAB_WEB%/}

# The small files every release carries under the same name.
# shellcheck disable=SC2034  # used by the scripts that source this file
RF_FIXED_FILES=(PARTS.sha256 SHA256SUMS ncz-join-image.sh NOTES.md)

rf_die() { echo "ERROR: $1" >&2; exit "${2:-1}"; }

rf_sha() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}
rf_size() { wc -c < "$1" | tr -d ' '; }
rf_uri() { jq -rn --arg s "$1" '$s|@uri'; }

# rf_load_token FORGE  ->  sets RF_TOKEN_<FORGE>
rf_load_token() {
  local forge=$1 up helper var tok=""
  up=$(printf '%s' "$forge" | tr '[:lower:]' '[:upper:]')
  helper="NCZ_${up}_TOKEN_HELPER"; var="NCZ_${up}_TOKEN_VAR"
  if [ -n "${!helper:-}" ]; then
    tok=$("${!helper}") || rf_die "$forge token helper failed"
  else
    local name=${!var:-${up}_TOKEN}
    printf '%s' "$name" | grep -Eq '^[A-Za-z_][A-Za-z0-9_]*$' || rf_die "$var is not a variable name" 2
    tok=${!name:-}
  fi
  tok=$(printf '%s' "$tok" | tr -d '\r\n')
  case "$tok" in *'"'*|*\\*) rf_die "$forge token contains characters that cannot be passed safely" ;; esac
  printf -v "RF_TOKEN_$up" '%s' "$tok"
}

# rf_api FORGE METHOD URL OUT [json-file | --upload FILE CONTENT-TYPE]
#   -> HTTP code on stdout, response body in OUT, redirect target in OUT.loc
rf_api() {
  local forge=$1 m=$2 url=$3 out=$4; shift 4
  local extra=() cfg="" tok
  case "$forge" in
    github)
      tok=${RF_TOKEN_GITHUB:-}
      extra+=(-H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28')
      [ -z "$tok" ] || cfg=$(printf 'header = "Authorization: Bearer %s"' "$tok") ;;
    gitlab)
      tok=${RF_TOKEN_GITLAB:-}
      [ -z "$tok" ] || cfg=$(printf 'header = "PRIVATE-TOKEN: %s"' "$tok") ;;
    *) rf_die "unknown forge $forge" 2 ;;
  esac
  if [ $# -gt 0 ]; then
    # -T streams the file (a 2 GiB part is never read into memory)
    if [ "$1" = --upload ]; then extra+=(-H "Content-Type: $3" -T "$2")
    else extra+=(-H 'Content-Type: application/json' --data-binary "@$1"); fi
  fi
  printf '%s\n' "$cfg" |
    curl -sS -K - -X "$m" -o "$out" -w '%{http_code} %{redirect_url}' "${extra[@]}" "$url" > "$out.w" 2>"$out.err" || echo "000" > "$out.w"
  cut -d' ' -f2- "$out.w" | sed 's/^ *//' > "$out.loc"
  cut -d' ' -f1 "$out.w"
}

# rf_get_all FORGE URL OUT  ->  all pages of a list endpoint as one JSON array
rf_get_all() {
  local forge=$1 url=$2 out=$3 page=1 sep c
  echo '[]' > "$out"
  case "$url" in *\?*) sep='&' ;; *) sep='?' ;; esac
  while :; do
    c=$(rf_api "$forge" GET "${url}${sep}per_page=100&page=$page" "$out.page")
    [ "$c" = 200 ] || { echo "GET $url (page $page) returned HTTP $c: $(head -c 200 "$out.page" 2>/dev/null)" >&2; return 1; }
    jq -s '.[0] + .[1]' "$out" "$out.page" > "$out.n" && mv "$out.n" "$out"
    [ "$(jq 'length' "$out.page")" -ge 100 ] || break
    page=$((page+1))
  done
  rm -f "$out.page" "$out.page.w" "$out.page.loc" "$out.page.err"
}

# rf_download URL OUT  ->  anonymous download following redirects; HTTP code on stdout
rf_download() {
  curl -sS -L -o "$2" -w '%{http_code}' "$1" 2>/dev/null || echo 000
}

# rf_project_id PROJECT WORKDIR  ->  numeric GitLab project id
rf_project_id() {
  local c
  case "$1" in *[!0-9]*) ;; *) echo "$1"; return 0 ;; esac
  c=$(rf_api gitlab GET "$RF_GITLAB_API/projects/$(rf_uri "$1")" "$2/proj.json") || true
  [ "$c" = 200 ] || return 1
  jq -r '.id' "$2/proj.json"
}

# Stable alias of a split image part: ncz-os-<arch>-<date>-<sha>.img.zst.part-NN
# -> ncz-os-<arch>.img.zst.part-NN. Other names are their own alias.
rf_stable_name() {
  printf '%s\n' "$1" | sed -E 's/^(ncz-os-[a-z0-9_]+)-[0-9]{8}-[0-9a-f]{6,40}(\.img\.zst\.part-[0-9]+)$/\1\2/'
}

# rf_normalise_body FILE GITHUB_REPO GITLAB_PROJECT  ->  stdout
# Line endings and trailing blank lines are normalised, and the forge-specific
# forms of the same link are replaced by one neutral form:
#   release page:   <github>/<repo>/releases/latest          | <gitlab>/<p>/-/releases/permalink/latest
#   latest file:    .../releases/latest/download/<f>          | .../-/releases/permalink/latest/downloads/<f>
#   raw file:       <raw>/<repo>/main/<path>                  | <gitlab>/<p>/-/raw/main/<path>
#   file view:      <github>/<repo>/blob/main/<path>          | <gitlab>/<p>/-/blob/main/<path>
#   tree view:      <github>/<repo>/tree/<ref>                | <gitlab>/<p>/-/tree/<ref>
# Nothing else is changed.
rf_normalise_body() {
  python3 -I - "$1" "$2" "$3" "$RF_GITHUB_WEB" "$RF_GITHUB_RAW" "$RF_GITLAB_WEB" <<'PY'
import re, sys
path, repo, proj, ghw, ghr, glw = sys.argv[1:7]
t = open(path, encoding="utf-8", errors="replace").read().replace("\r\n", "\n").replace("\r", "\n")
t = "\n".join(l.rstrip() for l in t.split("\n")).strip("\n") + "\n"
gh = re.escape(ghw + "/" + repo); gl = re.escape(glw + "/" + proj); raw = re.escape(ghr + "/" + repo)
subs = [
    (gh + r"/releases/latest/download/", "<release-file>/"),
    (gl + r"/-/releases/permalink/latest/downloads/", "<release-file>/"),
    (gh + r"/releases/latest(?![\w/-])", "<release-page>"),
    (gl + r"/-/releases/permalink/latest(?![\w/-])", "<release-page>"),
    (raw + r"/main/", "<raw-main>/"),
    (gl + r"/-/raw/main/", "<raw-main>/"),
    (gh + r"/blob/main/", "<blob-main>/"),
    (gl + r"/-/blob/main/", "<blob-main>/"),
    (gh + r"/tree/", "<tree>/"),
    (gl + r"/-/tree/", "<tree>/"),
]
for pat, rep in subs:
    t = re.sub(pat, rep, t)
sys.stdout.write(t)
PY
}

# rf_render_github NOTES GITHUB_REPO GITLAB_PROJECT  ->  stdout
# The GitHub form of the canonical (GitLab-form) notes: the same text with the
# GitLab links of the table above replaced by their GitHub equivalents.
rf_render_github() {
  python3 -I - "$1" "$2" "$3" "$RF_GITHUB_WEB" "$RF_GITHUB_RAW" "$RF_GITLAB_WEB" <<'PY'
import re, sys
path, repo, proj, ghw, ghr, glw = sys.argv[1:7]
t = open(path, encoding="utf-8").read()
gl = re.escape(glw + "/" + proj); gh = ghw + "/" + repo; raw = ghr + "/" + repo
subs = [
    (gl + r"/-/releases/permalink/latest/downloads/", gh + "/releases/latest/download/"),
    (gl + r"/-/releases/permalink/latest(?![\w/-])", gh + "/releases/latest"),
    (gl + r"/-/raw/main/", raw + "/main/"),
    (gl + r"/-/blob/main/", gh + "/blob/main/"),
    (gl + r"/-/tree/", gh + "/tree/"),
]
for pat, rep in subs:
    t = re.sub(pat, lambda m, r=rep: r, t)
sys.stdout.write(t)
PY
}

# rf_image_refs FILE  ->  one image URL per line (Markdown ![..](url) and <img src="url">)
rf_image_refs() {
  python3 -I - "$1" <<'PY'
import re, sys
t = open(sys.argv[1], encoding="utf-8", errors="replace").read()
seen = []
for m in re.finditer(r'!\[[^\]]*\]\(\s*<?([^)\s>]+)>?(?:\s+"[^"]*")?\s*\)', t):
    seen.append(m.group(1))
for m in re.finditer(r'<img\b[^>]*\bsrc\s*=\s*["\']([^"\']+)["\']', t, re.I):
    seen.append(m.group(1))
out = []
for u in seen:
    if u not in out: out.append(u)
print("\n".join(out))
PY
}
