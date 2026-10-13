#!/bin/bash
# refresh-release-links.sh - point the documentation's GitHub release links at
# a new release tag (the release-time refresh step).
#
# GitHub never treats a pre-release as "latest", so links to a release file
# on GitHub name the tag: https://github.com/<repo>/releases/download/<tag>/<file>
# (and /releases/tag/<tag>). At release time this tool rewrites every such
# link in README*.md and docs/ (*.md, *.html) to the new tag and records it in
# docs/releases/current-tag, which tools/check-release-links.sh reads. Links to
# /releases, GitLab permalinks, tree links and placeholders are left as they
# are.
#
# Usage:
#   tools/refresh-release-links.sh --tag TAG            # dry run: show the changes
#   tools/refresh-release-links.sh --tag TAG --apply    # write them
# The tool never creates tags; commit the result with the release.
# Exit codes: 0 ok, 2 usage error.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${NCZ_LINT_ROOT:-$(git -C "$HERE" rev-parse --show-toplevel 2>/dev/null || (cd "$HERE/.." && pwd))}"
TAG=""; APPLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --tag) TAG=${2:?--tag needs a tag}; shift 2 ;;
    --apply) APPLY=1; shift ;;
    -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
    *) echo "refresh-release-links: unknown argument $1 (try --help)" >&2; exit 2 ;;
  esac
done
[ -n "$TAG" ] || { echo "refresh-release-links: --tag is required" >&2; exit 2; }
printf '%s' "$TAG" | grep >/dev/null -E '^[A-Za-z0-9][A-Za-z0-9._-]*$' || { echo "refresh-release-links: invalid tag: $TAG" >&2; exit 2; }

FILES=()
while IFS= read -r f; do FILES+=("$ROOT/$f"); done < <(
  if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$ROOT" ls-files --cached --others --exclude-standard -- 'README*.md' 'docs/*.md' 'docs/*.html'
  else
    (cd "$ROOT" && find . -path ./.git -prune -o -type f \( -name 'README*.md' -o -path './docs/*.md' -o -path './docs/*.html' \) -print | sed 's#^\./##')
  fi | LC_ALL=C sort)

python3 -I - "$ROOT" "${NCZ_GITHUB_REPO:-ncz-os/cix-installer}" "${NCZ_GITHUB_WEB:-https://github.com}" "$TAG" "$APPLY" "${FILES[@]}" <<'PY'
import difflib, os, re, sys, urllib.parse as up
root, repo, ghw, tag, apply_ = sys.argv[1:6]
files = sys.argv[6:]
hosts = {"github.com", up.urlsplit(ghw).netloc or "github.com"}
H = "(?:" + "|".join(re.escape(h) for h in sorted(hosts)) + ")"
rx = re.compile("(" + H + "/" + re.escape(repo) + r"/releases/(?:tag|download)/)(?!<)(?!latest/)([^/\s)\]>\"'`]+)")
changed = 0
for f in files:
    old = open(f, encoding="utf-8").read()
    new = rx.sub(lambda m: m.group(1) + tag if m.group(2).rstrip(".,;:") == m.group(2) else m.group(1) + tag + m.group(2)[len(m.group(2).rstrip(".,;:")):], old)
    if new == old: continue
    changed += 1
    rel = os.path.relpath(f, root)
    sys.stdout.writelines(difflib.unified_diff(old.splitlines(True), new.splitlines(True), "a/" + rel, "b/" + rel))
    if apply_ == "1":
        open(f, "w", encoding="utf-8").write(new)
cur = os.path.join(root, "docs", "releases", "current-tag")
prev = open(cur).read().strip() if os.path.exists(cur) else ""
if prev != tag:
    print("docs/releases/current-tag: %s -> %s" % (prev or "(none)", tag))
    if apply_ == "1":
        open(cur, "w").write(tag + "\n")
print("refresh-release-links: %d file(s) %s; current tag %s%s" % (
    changed, "updated" if apply_ == "1" else "would change", tag, "" if apply_ == "1" else " (dry run)"))
PY
