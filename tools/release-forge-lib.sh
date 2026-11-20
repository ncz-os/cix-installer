# shellcheck shell=bash
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

# Associative arrays and mapfile: bash 4 or newer (macOS ships 3.2 as /bin/bash).
if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
  echo "ERROR: bash 4 or newer is required (this is bash ${BASH_VERSION:-unknown}; on macOS install a current bash, e.g. brew install bash)" >&2
  exit 2
fi

RF_GITHUB_API="${NCZ_GITHUB_API:-https://api.github.com}"
RF_GITHUB_UPLOADS="${NCZ_GITHUB_UPLOADS:-https://uploads.github.com}"
RF_GITHUB_WEB="${NCZ_GITHUB_WEB:-https://github.com}"
RF_GITHUB_RAW="${NCZ_GITHUB_RAW:-https://raw.githubusercontent.com}"
RF_GITLAB_API="${NCZ_GITLAB_API:-https://gitlab.com/api/v4}"
RF_GITLAB_WEB="${NCZ_GITLAB_WEB:-https://gitlab.com}"
RF_GITHUB_API=${RF_GITHUB_API%/}; RF_GITHUB_UPLOADS=${RF_GITHUB_UPLOADS%/}
RF_GITHUB_WEB=${RF_GITHUB_WEB%/}; RF_GITHUB_RAW=${RF_GITHUB_RAW%/}
RF_GITLAB_API=${RF_GITLAB_API%/}; RF_GITLAB_WEB=${RF_GITLAB_WEB%/}

# Architecture groups are ordered amd64, arm64. Within each group come
# desktop parts and checksums, server parts and checksums, then the combined
# architecture checksum. Legacy groups have one unflavored part set.
# The join script, combined checksums and notes follow the architecture groups.
# shellcheck disable=SC2034  # used by the scripts that source this file
RF_ARCHES=(amd64 arm64)
RF_FLAVOR_SUFFIXES=(-desktop -server)
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

# Stable aliases omit the date and build from part names.
rf_stable_name() {
  printf '%s\n' "$1" | sed -E 's/^(ncz-os-[a-z0-9_]+)-[0-9]{8}-[0-9a-f]{6,40}((-(desktop|server))?\.img\.zst\.part-[0-9]+)$/\1\2/'
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
    m = re.match(r"^ncz-os-(amd64|arm64)-[0-9]{8}-[0-9a-f]{6,40}((-(desktop|server))?\.img\.zst\.part-[0-9]+)$", name)
    if m: return "/%s/ncz-os-%s%s" % (m.group(1), m.group(1), m.group(2))
    m = re.match(r"^(?:PARTS-(amd64|arm64)(?:-desktop|-server)?\.sha256|SHA256SUMS-(amd64|arm64)(?:-desktop|-server)?)$", name)
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
    elif re.match(r"^(amd64|arm64)/(PARTS-\1(?:-desktop|-server)?\.sha256|SHA256SUMS-\1(?:-desktop|-server)?)$", p): name = p.split("/", 1)[1]
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
    ncz-os-amd64-*|PARTS-amd64.sha256|PARTS-amd64-*.sha256|SHA256SUMS-amd64|SHA256SUMS-amd64-*) echo amd64 ;;
    ncz-os-arm64-*|PARTS-arm64.sha256|PARTS-arm64-*.sha256|SHA256SUMS-arm64|SHA256SUMS-arm64-*) echo arm64 ;;
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
         if (g < 2) {
           k = (n ~ /^ncz-os-/) ? 0 : (n ~ /^PARTS-/ ? 1 : 2)
           if (n ~ /-server(\.img\.zst\.part-[0-9]+|\.sha256)?$/) k += 3
           if (n ~ /^SHA256SUMS-(amd64|arm64)$/) k = 6
         }
         else { k = (n == "ncz-join-image.sh") ? 0 : (n == "SHA256SUMS" ? 1 : (n == "NOTES.md" ? 2 : 3)) }
         printf "%d\t%d\t%s\n", g, k, n }' | LC_ALL=C sort -t$'\t' -k1,1n -k2,2n -k3,3 | cut -f3
}

# Select the parts of one architecture and flavor from names on stdin.
# An empty suffix selects legacy parts.
rf_image_parts() {
  local arch=$1 suffix=$2
  if [ -n "$suffix" ]; then
    grep -E "^ncz-os-$arch-[0-9]{8}-[0-9a-f]{6,40}$suffix\.img\.zst\.part-[0-9]+$"
  else
    grep -E "^ncz-os-$arch-.*\.img\.zst\.part-[0-9]+$" |
      grep -Ev -- '-(desktop|server)\.img\.zst\.part-'
  fi
}

# rf_layout DIR [--need-notes]  ->  "<group>\t<path relative to DIR>\t<name>"
# per file in the canonical order. Requires all four images and verifies
# every part against its PARTS
# file and the folder against the layout above; prints ERROR lines to stderr
# and returns 2 on any problem.
rf_layout() {
  local dir=$1 need_notes=${2:-} a p pf sf want name got suffix img raw zipped
  local arches=() bad=0 lines=() flavor_sums=()
  local -A seen=()
  err() { echo "ERROR: $*" >&2; bad=1; }
  for p in "$dir"/*.img.zst.part-*; do [ -e "$p" ] && err "part outside an architecture folder: ${p##*/}"; done
  for a in "${RF_ARCHES[@]}"; do
    if [ -d "$dir/$a" ]; then arches+=("$a"); fi
    seen=()
    flavor_sums=()
    for suffix in "${RF_FLAVOR_SUFFIXES[@]}"; do
      pf="PARTS-$a$suffix.sha256"; sf="SHA256SUMS-$a$suffix"
      [ -f "$dir/$a/$pf" ] || { err "$a$suffix: $a/$pf not found"; continue; }
      [ -f "$dir/$a/$sf" ] || { err "$a/$sf not found"; continue; }
      seen[$pf]=1; seen[$sf]=1
      flavor_sums+=("$dir/$a/$sf")
      img=
      while read -r want name; do
        [ -n "${name:-}" ] || continue; name=${name#\*}
        case "$name" in */*) err "$a/$pf entry is not a plain file name: $name"; continue ;; esac
        [[ $name =~ ^[A-Za-z0-9._+~-]+$ ]] || { err "file name not allowed: $name"; continue; }
        if ! rf_image_parts "$a" "$suffix" <<<"$name" >/dev/null; then
          err "$a/$pf lists $name, which is not an image part for $a$suffix"; continue
        fi
        if [ -n "$img" ] && [ "$img" != "${name%.zst.part-*}" ]; then
          err "$a/$pf lists parts of more than one image"; continue
        fi
        img=${name%.zst.part-*}
        [ -z "${seen[$name]:-}" ] || { err "$a/$pf lists $name more than once"; continue; }
        seen[$name]=1
        [ -f "$dir/$a/$name" ] || { err "part listed in $a/$pf is missing: $name"; continue; }
        got=$(rf_sha "$dir/$a/$name")
        [ "$got" = "$want" ] || { err "checksum mismatch for $a/$name"; continue; }
        lines+=("$name")
      done < "$dir/$a/$pf"
      [ -n "$img" ] || err "$a/$pf lists no parts"
      raw=0; zipped=0
      while read -r want name; do
        [ -n "${name:-}" ] || continue; name=${name#\*}
        case "$name" in
          "$img") raw=$((raw+1)) ;;
          "$img.zst") zipped=$((zipped+1)) ;;
          *) err "$a/$sf names $name but $a/$pf has no part of it" ;;
        esac
        if [[ ! $want =~ ^[0-9a-f]{64}$ ]]; then
          err "$a/$sf has an invalid sha256 for $name"
        fi
      done < "$dir/$a/$sf"
      if [ "$raw" -ne 1 ] || [ "$zipped" -ne 1 ]; then
        err "$a/$sf must list one image and one compressed image checksum"
      fi
      lines+=("$pf" "$sf")
    done
    sf="SHA256SUMS-$a"
    if [ "${#flavor_sums[@]}" -gt 0 ]; then
      [ -f "$dir/$a/$sf" ] || err "$a/$sf not found"
      cmp -s "$dir/$a/$sf" <(cat "${flavor_sums[@]}") || err "$a/$sf is not the concatenation of its flavor checksums"
      seen[$sf]=1
      lines+=("$sf")
    fi
    for p in "$dir/$a"/*; do
      [ -e "$p" ] || continue
      name=${p##*/}
      [ -n "${seen[$name]:-}" ] && continue
      err "$a/$name is not listed in the flavor layout"
    done
  done
  [ -f "$dir/ncz-join-image.sh" ] || err "ncz-join-image.sh not found"
  if [ ! -f "$dir/SHA256SUMS" ]; then err "SHA256SUMS not found"
  elif [ "${#arches[@]}" -gt 0 ]; then
    local cat_f=() x
    for x in "${arches[@]}"; do cat_f+=("$dir/$x/SHA256SUMS-$x"); done
    cmp -s "$dir/SHA256SUMS" <(cat "${cat_f[@]}") || err "SHA256SUMS is not SHA256SUMS-amd64 followed by SHA256SUMS-arm64"
  fi
  lines+=(ncz-join-image.sh SHA256SUMS)
  if [ -f "$dir/NOTES.md" ]; then lines+=(NOTES.md)
  elif [ -n "$need_notes" ]; then err "NOTES.md not found"; fi
  [ "$bad" -eq 0 ] || return 2
  while IFS= read -r name; do
    a=$(rf_file_group "$name")
    if [ "$a" = common ]; then p=$name; else p=$a/$name; fi
    printf '%s\t%s\t%s\n' "$a" "$p" "$name"
  done < <(printf '%s\n' "${lines[@]}" | rf_canonical_sort)
}

# rf_check_sections BODY ARCH=SHA256SUMS-FILE...  ->  "ok<TAB>text" / "DIFF<TAB>text" lines
# The notes need one section per architecture: a heading (## or deeper)
# naming the architecture, in the order given, whose section contains the
# raw image sha256 and join command in each flavor subsection or in the
# architecture section for legacy images.
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
    start, sec = pos[a]
    miss = []
    images = []
    try:
        for line in open(sums, encoding="utf-8"):
            f = line.split()
            if len(f) >= 2 and f[1].endswith(".img"): images.append((f[0], f[1].lstrip("*")))
    except OSError:
        miss.append("(no SHA256SUMS-%s to compare)" % a)
    for sha, image in images or [("", "")]:
        flavor = re.search(r"-(desktop|server)\.img$", image)
        command = a
        section = sec
        if flavor:
            flavor = flavor.group(1)
            command += r"[ \t]+" + flavor
            limit = start + len(sec.splitlines())
            heading = next(((i, lvl) for i, lvl, title in heads
                            if start < i < limit and re.match(flavor + r"\b", title, re.I)), None)
            if heading:
                i, lvl = heading
                end = next((j for j, lv, _ in heads if j > i and lv <= lvl), limit)
                section = "\n".join(body[i:min(end, limit)])
            else:
                miss.append(flavor.capitalize() + " subsection")
                continue
        if sha and sha not in section: miss.append("sha256 of " + image)
        pattern = r"ncz-join-image\.sh[ \t]+" + command + r"(?![\w-])"
        if not re.search(pattern, section):
            miss.append("the 'ncz-join-image.sh %s' command" % (a + (" " + flavor if flavor else "")))
    if miss: print("DIFF\tthe %s section of the notes is missing: %s" % (a, ", ".join(miss)))
    else: print("ok\tnotes: %s section with its image sha256 and join command" % a)
order = [a for a, _ in pairs if a in pos]
if [pos[a][0] for a in order] != sorted(pos[a][0] for a in order):
    print("DIFF\tthe architecture sections are not in the order %s" % " ".join(a for a, _ in pairs))
PY
}
