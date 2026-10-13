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

# Release layout. A staged release folder is
#   <dir>/amd64/  ncz-os-amd64-<date>-<build>.img.zst.part-NN  PARTS-amd64.sha256  SHA256SUMS-amd64
#   <dir>/arm64/  ncz-os-arm64-<date>-<build>.img.zst.part-NN  PARTS-arm64.sha256  SHA256SUMS-arm64
#   <dir>/        ncz-join-image.sh  SHA256SUMS  NOTES.md  (TITLE  PRERELEASE)
# (one or both architectures). SHA256SUMS is SHA256SUMS-amd64 followed by
# SHA256SUMS-arm64. The canonical file order, used on both release pages, is
# every amd64 file (parts, PARTS-amd64.sha256, SHA256SUMS-amd64), then every
# arm64 file, then the common files (ncz-join-image.sh, SHA256SUMS, NOTES.md).
# shellcheck disable=SC2034  # used by the scripts that source this file
RF_ARCHES=(amd64 arm64)
# shellcheck disable=SC2034
RF_COMMON_FILES=(ncz-join-image.sh SHA256SUMS NOTES.md)

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
    printf '%s' "$name" | grep >/dev/null -E '^[A-Za-z_][A-Za-z0-9_]*$' || rf_die "$var is not a variable name" 2
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

# rf_normalise_body FILE GITHUB_REPO GITLAB_PROJECT [TAG]  ->  stdout
# Line endings and trailing blank lines are normalised, and the forge-specific
# forms of the same link are replaced by one neutral form:
#   release page:   <github>/<repo>/releases                  | <gitlab>/<p>/-/releases/permalink/latest
#   release file:   .../releases/download/<TAG>/<name>        | .../-/releases/permalink/latest/downloads/<path>
#                   (GitHub has no folders and the part names carry the build;
#                   <name> is compared through its GitLab path, see rf_gl_path)
#   raw file:       <raw>/<repo>/main/<path>                  | <gitlab>/<p>/-/raw/main/<path>
#   file view:      <github>/<repo>/blob/main/<path>          | <gitlab>/<p>/-/blob/main/<path>
#   tree view:      <github>/<repo>/tree/<ref>                | <gitlab>/<p>/-/tree/<ref>
# A GitHub download link for any other tag is left as it is (so it differs).
rf_normalise_body() {
  python3 -I - "$1" "$2" "$3" "${4:-}" "$RF_GITHUB_WEB" "$RF_GITHUB_RAW" "$RF_GITLAB_WEB" <<'PY'
import re, sys
path, repo, proj, tag, ghw, ghr, glw = sys.argv[1:8]
t = open(path, encoding="utf-8", errors="replace").read().replace("\r\n", "\n").replace("\r", "\n")
t = "\n".join(l.rstrip() for l in t.split("\n")).strip("\n") + "\n"
gh = re.escape(ghw + "/" + repo); gl = re.escape(glw + "/" + proj); raw = re.escape(ghr + "/" + repo)
END = r"""[^\s)\]>"'`]+"""
def gl_path(name):
    m = re.match(r"^ncz-os-(amd64|arm64)-[0-9]{8}-[0-9a-f]{6,40}(\.img\.zst\.part-[0-9]+)$", name)
    if m: return "/%s/ncz-os-%s%s" % (m.group(1), m.group(1), m.group(2))
    m = re.match(r"^(?:PARTS-(amd64|arm64)\.sha256|SHA256SUMS-(amd64|arm64))$", name)
    if m: return "/%s/%s" % (m.group(1) or m.group(2), name)
    return "/" + name
if tag:
    t = re.sub(gh + r"/releases/download/" + re.escape(tag) + "/(" + END + ")",
               lambda m: "<release-file>" + gl_path(m.group(1)), t)
t = re.sub(gl + r"/-/releases/permalink/latest/downloads/(" + END + ")", lambda m: "<release-file>/" + m.group(1), t)
subs = [
    (gh + r"/releases(?![\w/-])", "<release-page>"),
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

# rf_render_github NOTES GITHUB_REPO GITLAB_PROJECT TAG [MAP]  ->  stdout
# The GitHub form of the canonical (GitLab-form) notes: the same text with the
# GitLab links of the table above replaced by their GitHub equivalents. The
# GitHub release is reached as <github>/<repo>/releases (the one release page;
# a pre-release is never "latest" on GitHub), its files by the tag:
# <github>/<repo>/releases/download/<TAG>/<name>. MAP ("<gitlab path>\t<name>"
# lines, e.g. "amd64/ncz-os-amd64.img.zst.part-00\tncz-os-amd64-...part-00")
# resolves the stable part aliases; a link that cannot be resolved fails (2).
rf_render_github() {
  python3 -I - "$1" "$2" "$3" "$4" "${5:-}" "$RF_GITHUB_WEB" "$RF_GITHUB_RAW" "$RF_GITLAB_WEB" <<'PY'
import os, re, sys
path, repo, proj, tag, mapf, ghw, ghr, glw = sys.argv[1:9]
t = open(path, encoding="utf-8").read()
gl = re.escape(glw + "/" + proj); gh = ghw + "/" + repo; raw = ghr + "/" + repo
END = r"""[^\s)\]>"'`]+"""
amap = {}
if mapf and os.path.exists(mapf):
    for line in open(mapf, encoding="utf-8"):
        k, _, v = line.rstrip("\n").partition("\t")
        if k: amap[k] = v
bad = []
def dl(m):
    p = m.group(1)
    if p in amap: name = amap[p]
    elif re.match(r"^(amd64|arm64)/(PARTS-\1\.sha256|SHA256SUMS-\1)$", p): name = p.split("/", 1)[1]
    elif "/" not in p and not re.search(r"\.part-[0-9]+$", p): name = p
    else:
        bad.append(p); name = p
    return gh + "/releases/download/" + tag + "/" + name
t = re.sub(gl + r"/-/releases/permalink/latest/downloads/(" + END + ")", dl, t)
subs = [
    (gl + r"/-/releases/permalink/latest(?![\w/-])", gh + "/releases"),
    (gl + r"/-/raw/main/", raw + "/main/"),
    (gl + r"/-/blob/main/", gh + "/blob/main/"),
    (gl + r"/-/tree/", gh + "/tree/"),
]
for pat, rep in subs:
    t = re.sub(pat, lambda m, r=rep: r, t)
if bad:
    sys.stderr.write("ERROR: no GitHub file for the release link(s): %s\n" % " ".join(sorted(set(bad))))
    sys.exit(2)
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

# rf_file_group NAME  ->  amd64 | arm64 | common (by file name)
rf_file_group() {
  case "$1" in
    ncz-os-amd64-*|PARTS-amd64.sha256|SHA256SUMS-amd64) echo amd64 ;;
    ncz-os-arm64-*|PARTS-arm64.sha256|SHA256SUMS-arm64) echo arm64 ;;
    *) echo common ;;
  esac
}
# GitLab link name and direct path of a file: architecture files sit under
# "<arch>/" so the release page reads as one folder per architecture.
rf_gl_link_name() { local g; g=$(rf_file_group "$1"); if [ "$g" = common ]; then echo "$1"; else echo "$g/$1"; fi; }
rf_gl_path() { local g; g=$(rf_file_group "$1"); if [ "$g" = common ]; then echo "/$1"; else echo "/$g/$(rf_stable_name "$1")"; fi; }
# rf_canonical_sort  <names on stdin>  ->  names in the canonical order
rf_canonical_sort() {
  awk '{ n = $0; g = 2; k = 9
         if (n ~ /^ncz-os-amd64-|^(PARTS|SHA256SUMS)-amd64/) g = 0
         else if (n ~ /^ncz-os-arm64-|^(PARTS|SHA256SUMS)-arm64/) g = 1
         if (g < 2) { k = (n ~ /^ncz-os-/) ? 0 : (n ~ /^PARTS-/ ? 1 : 2) }
         else { k = (n == "ncz-join-image.sh") ? 0 : (n == "SHA256SUMS" ? 1 : (n == "NOTES.md" ? 2 : 3)) }
         printf "%d\t%d\t%s\n", g, k, n }' | LC_ALL=C sort -t$'\t' -k1,1n -k2,2n -k3,3 | cut -f3
}

# rf_layout DIR [--need-notes]  ->  "<group>\t<path relative to DIR>\t<name>"
# per file in the canonical order. Verifies every part against its PARTS
# file and the folder against the layout above; prints ERROR lines to stderr
# and returns 2 on any problem.
rf_layout() {
  local dir=$1 need_notes=${2:-} a pf sf want name n got arches=() bad=0 lines=()
  err() { echo "ERROR: $*" >&2; bad=1; }
  for p in "$dir"/*.img.zst.part-*; do [ -e "$p" ] && err "part outside an architecture folder: ${p##*/}"; done
  for a in "${RF_ARCHES[@]}"; do
    [ -d "$dir/$a" ] || continue
    arches+=("$a"); pf="$dir/$a/PARTS-$a.sha256"; sf="$dir/$a/SHA256SUMS-$a"
    [ -f "$pf" ] || { err "$a/PARTS-$a.sha256 not found"; continue; }
    [ -f "$sf" ] || { err "$a/SHA256SUMS-$a not found"; continue; }
    n=0
    while read -r want name; do
      [ -n "${name:-}" ] || continue; name=${name#\*}
      case "$name" in */*) err "$a/PARTS-$a.sha256 entry is not a plain file name: $name"; continue ;; esac
      printf '%s' "$name" | grep >/dev/null -E '^[A-Za-z0-9._+~-]+$' || { err "file name not allowed: $name"; continue; }
      case "$name" in "ncz-os-$a-"*.img.zst.part-*) ;; *) err "$a/PARTS-$a.sha256 lists $name, which is not an $a image part"; continue ;; esac
      [ -f "$dir/$a/$name" ] || { err "part listed in $a/PARTS-$a.sha256 is missing: $name"; continue; }
      got=$(rf_sha "$dir/$a/$name")
      [ "$got" = "$want" ] || { err "checksum mismatch for $a/$name"; continue; }
      lines+=("$a"$'\t'"$a/$name"$'\t'"$name"); n=$((n+1))
    done < "$pf"
    [ "$n" -gt 0 ] || err "$a/PARTS-$a.sha256 lists no parts"
    for p in "$dir/$a"/*; do
      name=${p##*/}
      case "$name" in "PARTS-$a.sha256"|"SHA256SUMS-$a") continue ;; esac
      grep -qE "[[:space:]]\*?$(printf '%s' "$name" | sed 's/[.[\*^$+]/\\&/g')\$" "$pf" || err "$a/$name is not listed in $a/PARTS-$a.sha256"
    done
    while read -r want name; do
      [ -n "${name:-}" ] || continue; name=${name#\*}
      case "$name" in "ncz-os-$a-"*.img) ;; *) err "$a/SHA256SUMS-$a names $name, which is not an $a image"; continue ;; esac
      grep -q "[[:space:]]\*\?$(printf '%s' "$name" | sed 's/[.[\*^$+]/\\&/g')\.zst\.part-" "$pf" || err "$a/SHA256SUMS-$a names $name but $a/PARTS-$a.sha256 has no part of it"
    done < "$sf"
    lines+=("$a"$'\t'"$a/PARTS-$a.sha256"$'\t'"PARTS-$a.sha256" "$a"$'\t'"$a/SHA256SUMS-$a"$'\t'"SHA256SUMS-$a")
  done
  [ "${#arches[@]}" -gt 0 ] || err "no architecture folder (amd64/ or arm64/) in $dir"
  [ -f "$dir/ncz-join-image.sh" ] || err "ncz-join-image.sh not found"
  if [ ! -f "$dir/SHA256SUMS" ]; then err "SHA256SUMS not found"
  elif [ "${#arches[@]}" -gt 0 ]; then
    local cat_f=() x
    for x in "${arches[@]}"; do cat_f+=("$dir/$x/SHA256SUMS-$x"); done
    cmp -s "$dir/SHA256SUMS" <(cat "${cat_f[@]}") || err "SHA256SUMS is not SHA256SUMS-amd64 followed by SHA256SUMS-arm64"
  fi
  lines+=("common"$'\t'"ncz-join-image.sh"$'\t'"ncz-join-image.sh" "common"$'\t'"SHA256SUMS"$'\t'"SHA256SUMS")
  if [ -f "$dir/NOTES.md" ]; then lines+=("common"$'\t'"NOTES.md"$'\t'"NOTES.md")
  elif [ -n "$need_notes" ]; then err "NOTES.md not found"; fi
  [ "$bad" -eq 0 ] || return 2
  printf '%s\n' "${lines[@]}"
}

# rf_check_sections BODY ARCH=SHA256SUMS-FILE...  ->  "ok<TAB>text" / "DIFF<TAB>text" lines
# The notes need one section per architecture: a heading (## or deeper)
# naming the architecture, in the order given, whose section contains the
# sha256 of each image in that architecture's SHA256SUMS file and the
# "ncz-join-image.sh <arch>" command.
rf_check_sections() {
  python3 -I - "$@" <<'PY'
import re, sys
body = open(sys.argv[1], encoding="utf-8", errors="replace").read().split("\n")
pairs = [a.split("=", 1) for a in sys.argv[2:]]
heads = []
for i, l in enumerate(body):
    m = re.match(r"^(#{2,6})\s+(.*)$", l)
    if m: heads.append((i, len(m.group(1)), m.group(2)))
pos = {}
for a, sums in pairs:
    for i, lvl, t in heads:
        if re.search(r"(?<![\w-])" + re.escape(a) + r"(?![\w-])", t):
            end = next((j for j, lv, _ in heads if j > i and lv <= lvl), len(body))
            pos[a] = (i, "\n".join(body[i:end])); break
    if a not in pos:
        print("DIFF\tthe notes have no section heading naming %s" % a); continue
    sec = pos[a][1]; miss = []
    try:
        for line in open(sums, encoding="utf-8"):
            f = line.split()
            if len(f) >= 2 and f[0] not in sec: miss.append("sha256 of " + f[1].lstrip("*"))
    except OSError:
        miss.append("(no SHA256SUMS-%s to compare)" % a)
    if not re.search(r"ncz-join-image\.sh\b[^\n]*?(?<![\w-])" + re.escape(a) + r"(?![\w-])", sec):
        miss.append("the 'ncz-join-image.sh %s' command" % a)
    if miss: print("DIFF\tthe %s section of the notes is missing: %s" % (a, ", ".join(miss)))
    else: print("ok\tnotes: %s section with its image sha256 and join command" % a)
order = [a for a, _ in pairs if a in pos]
if [pos[a][0] for a in order] != sorted(pos[a][0] for a in order):
    print("DIFF\tthe architecture sections are not in the order %s" % " ".join(a for a, _ in pairs))
PY
}
