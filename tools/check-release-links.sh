#!/bin/bash
# check-release-links.sh - fail when documentation links to a release other
# than the current one, or uses a release link form that stops working.
#
# There is only ever one release page per forge; older release pages are
# removed when a new release is published. Documentation links to:
#   https://github.com/<repo>/releases
#       the GitHub releases page, which lists the one release. GitHub never
#       treats a pre-release as "latest", so /releases/latest and
#       /releases/latest/download/... are not used.
#   https://github.com/<repo>/releases/tag/<current tag>
#   https://github.com/<repo>/releases/download/<current tag>/<stable file>
#       written for the current tag; tools/refresh-release-links.sh moves
#       them to the next tag at release time.
#   https://gitlab.com/<project>/-/releases/permalink/latest
#   https://gitlab.com/<project>/-/releases/permalink/latest/downloads/<stable path>
# Source for a tag is linked as a tree (/tree/<tag>, /-/tree/<tag>), which
# keeps working because tags are kept.
#
# The current tag is --current-tag TAG, else $NCZ_RELEASE_TAG, else the first
# line of docs/releases/current-tag in the repository (none: no tag link is
# allowed).
#
# Flagged (for this project only):
#   <github>/<repo>/releases/latest[/download/...]
#   <github>/<repo>/releases/tag/<tag> and .../releases/download/<tag>/...
#     for any tag but the current one
#   <gitlab>/<project>/-/releases/<tag> for any tag but the current one
#   <gitlab api>/projects/<project>/packages/generic/<package>/...  except the
#     linux-* source packages (the kernel source offer; those are kept)
#   a release file whose name changes between releases: stable on GitHub are
#     SHA256SUMS, ncz-join-image.sh, NOTES.md, PARTS-<arch>.sha256 and
#     SHA256SUMS-<arch>; on GitLab also <arch>/PARTS-<arch>.sha256,
#     <arch>/SHA256SUMS-<arch> and <arch>/ncz-os-<arch>.img.zst.part-NN
# A placeholder such as <tag>, <file> or PARTS-<arch>.sha256 is not flagged.
#
# Usage:
#   tools/check-release-links.sh [--current-tag TAG]                # README*.md and docs/ (*.md, *.html)
#   tools/check-release-links.sh [--current-tag TAG] --files F...   # just these files
#   --allow-part-names   accept image part names in GitHub download links of
#                        the current tag (a published release body, which is
#                        rewritten for every release, not documentation)
# Settings: NCZ_GITHUB_REPO, NCZ_GITLAB_PROJECT (default ncz-os/cix-installer),
# NCZ_GITLAB_PROJECT_ID (default 81838641), NCZ_LINT_ROOT (repository root).
# Exit codes: 0 clean, 1 links found, 2 usage error.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${NCZ_LINT_ROOT:-$(git -C "$HERE" rev-parse --show-toplevel 2>/dev/null || (cd "$HERE/.." && pwd))}"
CUR="${NCZ_RELEASE_TAG:-}"; PARTS_OK=0
while :; do
  case "${1:-}" in
    --current-tag) CUR=${2:?--current-tag needs a tag}; shift 2 ;;
    --allow-part-names) PARTS_OK=1; shift ;;
    *) break ;;
  esac
done
if [ -z "$CUR" ] && [ -f "$ROOT/docs/releases/current-tag" ]; then CUR=$(head -1 "$ROOT/docs/releases/current-tag" | tr -d ' \r\n'); fi
FILES=()
if [ "${1:-}" = --files ]; then
  shift; [ $# -gt 0 ] || { echo "check-release-links: --files needs at least one file" >&2; exit 2; }
  FILES=("$@")
elif [ $# -gt 0 ]; then
  case "$1" in -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;; esac
  echo "check-release-links: unknown argument $1" >&2; exit 2
else
  while IFS= read -r f; do FILES+=("$ROOT/$f"); done < <(
    if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      git -C "$ROOT" ls-files --cached --others --exclude-standard -- 'README*.md' 'docs/*.md' 'docs/*.html'
    else
      (cd "$ROOT" && find . -path ./.git -prune -o -type f \( -name 'README*.md' -o -path './docs/*.md' -o -path './docs/*.html' \) -print | sed 's#^\./##')
    fi | LC_ALL=C sort)
fi

python3 -I - "$ROOT" "${NCZ_GITHUB_REPO:-ncz-os/cix-installer}" "${NCZ_GITLAB_PROJECT:-ncz-os/cix-installer}" \
  "${NCZ_GITLAB_PROJECT_ID:-81838641}" "${NCZ_GITHUB_WEB:-https://github.com}" "${NCZ_GITLAB_WEB:-https://gitlab.com}" \
  "$CUR" "$PARTS_OK" "${FILES[@]}" <<'PY'
import os, re, sys, urllib.parse as up
root, repo, proj, pid, ghw, glw, cur, parts_ok = sys.argv[1:9]
files = sys.argv[9:]
GH_PART = re.compile(r"^ncz-os-(amd64|arm64)-[0-9]{8}-[0-9a-f]{6,40}\.img\.zst\.part-[0-9]+$")
r, p = re.escape(repo), re.escape(proj)
def hosts(default, web):
    hs = {default, up.urlsplit(web).netloc or default}
    return "(?:" + "|".join(re.escape(h) for h in sorted(hs)) + ")"
GH, GL = hosts("github.com", ghw), hosts("gitlab.com", glw)
penc = re.escape(up.quote(proj, safe=""))
seg = r"[^\s)\]>\"'`]+"
GH_STABLE = {"SHA256SUMS", "ncz-join-image.sh", "NOTES.md"} | {
    "SHA256SUMS-%s" % a for a in ("amd64", "arm64")} | {"PARTS-%s.sha256" % a for a in ("amd64", "arm64")}
GL_STABLE = {"SHA256SUMS", "ncz-join-image.sh", "NOTES.md"} | {
    "%s/%s" % (a, n) for a in ("amd64", "arm64") for n in ("PARTS-%s.sha256" % a, "SHA256SUMS-%s" % a)}
GL_PART = re.compile(r"^(amd64|arm64)/ncz-os-\1\.img\.zst\.part-[0-9]+$")
gh_latest = re.compile(GH + "/" + r + r"/releases/latest(?:/download/" + seg + r")?", re.I)
gh_tag = re.compile(GH + "/" + r + r"/releases/tag/(" + seg + ")", re.I)
gh_dl = re.compile(GH + "/" + r + r"/releases/download/([^/\s)\]>\"'`]+)/(" + seg + ")", re.I)
gl_rel = re.compile(GL + "/" + p + r"/-/releases/(?!permalink/latest(?:[/\s)\]>\"'`]|$))([^/\s)\]>\"'`]+)", re.I)
gl_latest_dl = re.compile(GL + "/" + p + r"/-/releases/permalink/latest/downloads/(" + seg + ")", re.I)
pkg = re.compile(r"/api/v4/projects/(?:" + re.escape(pid) + "|" + penc + r")/packages/generic/(?!linux-)(?!<)" + seg, re.I)
def ph(s): return "<" in s
def clean(s): return s.rstrip(".,;:")
hits = 0
def hit(rel, n, what, text):
    global hits
    hits += 1
    print("RELEASE-LINK: %s:%d: %s: %s" % (rel, n, what, text))
for f in files:
    try:
        lines = open(f, encoding="utf-8", errors="replace").read().split("\n")
    except OSError as e:
        print("check-release-links: cannot read %s: %s" % (f, e), file=sys.stderr); sys.exit(2)
    rel = os.path.relpath(f, root) if f.startswith(root + os.sep) else f
    for n, line in enumerate(lines, 1):
        for m in gh_latest.finditer(line):
            hit(rel, n, "GitHub /releases/latest never reaches a pre-release; link to /releases", m.group(0))
        for m in gh_tag.finditer(line):
            t = clean(m.group(1))
            if ph(t) or (cur and t == cur): continue
            hit(rel, n, "release page of a tag that is not the current release%s" % (" (%s)" % cur if cur else ""), m.group(0))
        for m in gh_dl.finditer(line):
            t, name = m.group(1), clean(m.group(2))
            if t == "latest": continue   # reported above
            if ph(t) and ph(name): continue
            if not ph(t) and not (cur and t == cur):
                hit(rel, n, "download from a tag that is not the current release%s" % (" (%s)" % cur if cur else ""), m.group(0)); continue
            if not ph(name) and name not in GH_STABLE and not (parts_ok == "1" and GH_PART.match(name)):
                hit(rel, n, "release file without a stable name", m.group(0))
        for m in gl_rel.finditer(line):
            t = clean(m.group(1))
            if ph(t) or (cur and t == cur): continue
            hit(rel, n, "release page of a tag that is not the current release%s" % (" (%s)" % cur if cur else ""), m.group(0))
        for m in gl_latest_dl.finditer(line):
            name = clean(m.group(1))
            if ph(name) or name in GL_STABLE or GL_PART.match(name): continue
            hit(rel, n, "latest-release file without a stable name", m.group(0))
        for m in pkg.finditer(line):
            hit(rel, n, "package file", m.group(0))
if hits:
    print("check-release-links: %d link(s) to another release or with a changing name; GitHub: /releases or the current tag, "
          "GitLab: -/releases/permalink/latest (docs/IMAGE-HOSTING.md)" % hits)
    sys.exit(1)
print("check-release-links: OK (%d files%s)" % (len(files), ", current tag %s" % cur if cur else ""))
PY
