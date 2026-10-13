#!/bin/bash
# check-release-links.sh - fail when documentation links to one specific
# release instead of the stable "latest" addresses.
#
# There is only ever one release page per forge, and older release pages are
# removed, so a link to a tag's release page, a tag's download or a package
# file stops working at the next release. Documentation links to:
#   https://github.com/<repo>/releases/latest
#   https://github.com/<repo>/releases/latest/download/<file>
#   https://gitlab.com/<project>/-/releases/permalink/latest
#   https://gitlab.com/<project>/-/releases/permalink/latest/downloads/<file>
# Source for a tag is linked as a tree (/tree/<tag>, /-/tree/<tag>), which
# keeps working because tags are kept.
#
# Flagged (for this project only):
#   <github>/<repo>/releases/tag/...  and  <github>/<repo>/releases/download/...
#   <gitlab>/<project>/-/releases/<anything but permalink/latest>
#   <gitlab api>/projects/<project>/packages/generic/<package>/...  except the
#     linux-* source packages (the kernel source offer; those are kept)
# A placeholder segment such as <tag> or <version> is not flagged.
#
# Usage:
#   tools/check-release-links.sh                 # README*.md and docs/ (*.md, *.html)
#   tools/check-release-links.sh --files F...    # just these files
# Settings: NCZ_GITHUB_REPO, NCZ_GITLAB_PROJECT (default ncz-os/cix-installer),
# NCZ_GITLAB_PROJECT_ID (default 81838641), NCZ_LINT_ROOT (repository root).
# Exit codes: 0 clean, 1 links found, 2 usage error.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${NCZ_LINT_ROOT:-$(git -C "$HERE" rev-parse --show-toplevel 2>/dev/null || (cd "$HERE/.." && pwd))}"
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
  "${FILES[@]}" <<'PY'
import os, re, sys, urllib.parse as up
root, repo, proj, pid, ghw, glw = sys.argv[1:7]
files = sys.argv[7:]
r, p = re.escape(repo), re.escape(proj)
def hosts(default, web):
    hs = {default, up.urlsplit(web).netloc or default}
    return "(?:" + "|".join(re.escape(h) for h in sorted(hs)) + ")"
GH, GL = hosts("github.com", ghw), hosts("gitlab.com", glw)
penc = re.escape(up.quote(proj, safe=""))
seg = r"(?!<)[^\s)\]>\"'`]+"
pats = [
    ("tag release page or download", re.compile(GH + "/" + r + r"/releases/(?:tag|download)/" + seg, re.I)),
    ("tag release page", re.compile(GL + "/" + p + r"/-/releases/(?!permalink/latest(?:[/\s)\]>\"'`]|$))" + seg, re.I)),
    ("package file", re.compile(r"/api/v4/projects/(?:" + re.escape(pid) + "|" + penc + r")/packages/generic/(?!linux-)" + seg, re.I)),
]
hits = 0
for f in files:
    try:
        lines = open(f, encoding="utf-8", errors="replace").read().split("\n")
    except OSError as e:
        print("check-release-links: cannot read %s: %s" % (f, e), file=sys.stderr); sys.exit(2)
    rel = os.path.relpath(f, root) if f.startswith(root + os.sep) else f
    for n, line in enumerate(lines, 1):
        for what, rx in pats:
            for m in rx.finditer(line):
                hits += 1
                print("RELEASE-LINK: %s:%d: %s: %s" % (rel, n, what, m.group(0)))
if hits:
    print("check-release-links: %d link(s) to a specific release; use the releases/latest "
          "(GitHub) or -/releases/permalink/latest (GitLab) forms, see docs/IMAGE-HOSTING.md" % hits)
    sys.exit(1)
print("check-release-links: OK (%d files)" % len(files))
PY
