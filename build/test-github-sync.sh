#!/bin/bash
# test-github-sync.sh -- fixture tests for tools/sync-github-mirror.sh and
# tools/check-github-sync.sh.
#
# Builds throw-away "GitLab" and "GitHub" bare repositories on local disk and
# proves, in both directions where it matters:
#   - a blob over the size limit never reaches the copy (and the tree check
#     models the same exclusion);
#   - a listed literal is replaced in files and commit messages;
#   - a mailmapped identity is rewritten in authors, committers and taggers;
#   - merge-request refs are not copied;
#   - two independent runs give identical shas (determinism) and a later run
#     is a plain fast-forward;
#   - commits added on the GitHub side are detected as drift, kept without
#     --allow-force, replaced with it after a backup bundle;
#   - refs only on GitHub are reported and removed only with --prune;
#   - a tag that carries a release is never moved;
#   - a binary blob carrying a listed literal stops the sync;
#   - identity mode keeps GitLab shas;
#   - a small push budget splits a push into several fast-forward steps.
#
# Needs git and git-filter-repo. Exit 0 = all PASS, 1 = FAIL, 2 = harness error.
set -uo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
SYNC="$REPO/tools/sync-github-mirror.sh"
CHECK="$REPO/tools/check-github-sync.sh"

command -v git-filter-repo >/dev/null 2>&1 || { echo "SKIP: git-filter-repo not installed"; exit 0; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  PASS  $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL  $1"; }
expect() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got '$1', want '$2')"; fi; }

T="$(mktemp -d "${TMPDIR:-$REPO/.tmp}/ghsync-test.XXXXXX" 2>/dev/null)" || {
    mkdir -p "$REPO/.tmp"; T="$(mktemp -d "$REPO/.tmp/ghsync-test.XXXXXX")"; }
trap 'rm -rf "$T"' EXIT

export GIT_CONFIG_NOSYSTEM=1 HOME="$T/home" GIT_TERMINAL_PROMPT=0
mkdir -p "$HOME" "$T/gl/grp" "$T/gh/org" "$T/api/repos/org" "$T/site" "$T/bk"
git config --global user.name "Dev One"
git config --global user.email "dev@corp.example"
git config --global init.defaultBranch main
git config --global protocol.file.allow always

LIT='FAKE-Pa55-w0rd!'
printf '%s==>changeme\n' "$LIT" > "$T/site/replace.txt"
printf 'Dev One <dev@example.org> <dev@corp.example>\n' > "$T/site/mailmap"
: > "$T/site/strip.txt"

export NCZ_GHSYNC_GITLAB_BASE="file://$T/gl" NCZ_GHSYNC_GITHUB_BASE="file://$T/gh"
export NCZ_GHSYNC_GITHUB_API="file://$T/api" NCZ_GHSYNC_GITLAB_API="file://$T/glapi"
export NCZ_GHSYNC_REPLACE_FILE="$T/site/replace.txt" NCZ_GHSYNC_MAILMAP="$T/site/mailmap"
export NCZ_GHSYNC_BACKUP_DIR="$T/bk"
LIMIT=1048576
COMMON=(--repos "$T/repos.tsv" --strip-list "$T/site/strip.txt" --limit "$LIMIT")

cat > "$T/repos.tsv" <<EOF
fx	grp/fx	org/fx	filter
id	grp/id	org/id	identity
bin	grp/bin	org/bin	filter
ar	grp/ar	org/ar	filter
EOF

mkrepo() { git init -q --bare "$T/gl/grp/$1.git"; git init -q --bare "$T/gh/org/$1.git"; }
mkrepo fx; mkrepo id; mkrepo bin; mkrepo ar

# ---- fixture history for fx
W="$T/w"; git clone -q "$T/gl/grp/fx.git" "$W" 2>/dev/null
(
  cd "$W"
  export GIT_AUTHOR_DATE="2026-01-01T00:00:00Z" GIT_COMMITTER_DATE="2026-01-01T00:00:00Z"
  echo hello > a.txt; git add a.txt; git commit -qm "Add a"
  head -c 1500000 /dev/urandom > big.bin; git add big.bin; git commit -qm "Add large file"
  printf 'user=ncz\npass=%s\n' "$LIT" > conf.ini; git add conf.ini; git commit -qm "Add conf ($LIT)"
  git rm -q big.bin; echo two >> a.txt; git commit -qam "Drop large file"
  git tag -a v1 -m "v1"
  git checkout -qb feature; echo f > f.txt; git add f.txt; git commit -qm "Feature"
  git push -q origin main feature v1
  git push -q origin feature:refs/merge-requests/1/head
)
GLMAIN="$(git --git-dir="$T/gl/grp/fx.git" rev-parse main)"

echo "== dry-run"
"$SYNC" "${COMMON[@]}" --workdir "$T/wd1" --repo fx --report "$T/plan1.json" >/dev/null 2>"$T/log1"; rc=$?
expect "$rc" 0 "dry-run exits 0"
expect "$(git --git-dir="$T/gh/org/fx.git" for-each-ref | wc -l)" 0 "dry-run pushes nothing"
expect "$(python3 -c "import json;d=json.load(open('$T/plan1.json'));print(sorted({x['action'] for x in d['repos'][0]['plan']}))")" "['create']" "plan creates every ref"
expect "$(python3 -c "import json;d=json.load(open('$T/plan1.json'));print(sorted(x['ref'] for x in d['repos'][0]['plan']))")" \
       "['refs/heads/feature', 'refs/heads/main', 'refs/tags/v1']" "merge-request refs are not planned"

echo "== check before apply"
"$CHECK" "${COMMON[@]}" --workdir "$T/wd1" --repo fx >"$T/chk0" 2>&1; rc=$?
expect "$rc" 1 "check reports drift while GitHub is empty"
grep -q "MISSING" "$T/chk0" && ok "check lists missing refs" || bad "check lists missing refs"

echo "== apply"
"$SYNC" "${COMMON[@]}" --workdir "$T/wd1" --repo fx --apply >/dev/null 2>"$T/log2"; rc=$?
expect "$rc" 0 "apply exits 0"
GH="$T/gh/org/fx.git"
expect "$(git --git-dir="$GH" for-each-ref --format='%(refname)' refs/heads refs/tags | sort | tr '\n' ' ')" \
       "refs/heads/feature refs/heads/history/gitlab-commit-map refs/heads/main refs/tags/v1 " "GitHub has branches, tag and commit map"
expect "$(git --git-dir="$GH" rev-list --objects --no-object-names --all | git --git-dir="$GH" cat-file --batch-check='%(objectsize)' | awk -v l=$LIMIT '$1>l' | wc -l)" 0 "no blob over the limit on GitHub"
expect "$(git --git-dir="$GH" log --all --format=%B | grep -c -F "$LIT")" 0 "literal gone from messages"
git --git-dir="$GH" grep -q -F "$LIT" $(git --git-dir="$GH" rev-list --all); rc=$?
expect "$rc" 1 "literal gone from every file version (git grep finds no match)"
expect "$(git --git-dir="$GH" show main:conf.ini | grep -c changeme)" 1 "literal replaced by placeholder"
expect "$(git --git-dir="$GH" log --all --format='%ae %ce' | grep -c corp.example)" 0 "mailmapped identity gone from commits"
expect "$(git --git-dir="$GH" for-each-ref --format='%(taggeremail)' refs/tags | grep -c corp.example)" 0 "mailmapped identity gone from tags"
expect "$(git --git-dir="$GH" for-each-ref refs/merge-requests | wc -l)" 0 "no merge-request refs on GitHub"
expect "$(git --git-dir="$GH" rev-parse main:a.txt)" "$(git --git-dir="$T/gl/grp/fx.git" rev-parse main:a.txt)" "unchanged file keeps its blob"
expect "$(git --git-dir="$GH" rev-list --count main)" "$(git --git-dir="$T/gl/grp/fx.git" rev-list --count main)" "no commit pruned"
expect "$(git --git-dir="$GH" show history/gitlab-commit-map:commit-map.tsv | grep -c "^$GLMAIN	")" 1 "commit map lists the GitLab main sha"

"$CHECK" "${COMMON[@]}" --workdir "$T/wd1" --repo fx >"$T/chk1" 2>&1; rc=$?
expect "$rc" 0 "check: in sync after apply"

echo "== determinism"
"$SYNC" "${COMMON[@]}" --workdir "$T/wd2" --repo fx --report "$T/plan2.json" >/dev/null 2>&1
expect "$(python3 -c "import json;d=json.load(open('$T/plan2.json'));print(sorted({x['action'] for x in d['repos'][0]['plan']}))")" "['keep', 'same']" "independent second run: identical shas"
M1="$(sha256sum < "$T/wd1/maps/fx.tsv")"
M2="$(sha256sum < "$T/wd2/maps/fx.tsv")"
expect "$M1" "$M2" "commit map identical between runs"

echo "== ref-set independence"
( cd "$W" && git checkout -q main && git checkout -q -b tmpx && printf 'k=%s\n' "$LIT" > x.ini && git add x.ini && git commit -qm "x" &&
  X="$(git rev-parse --short HEAD)" && git checkout -q main && git checkout -q -b refy && echo y > y.txt && git add y.txt &&
  git commit -qm "Follow-up to $X" && git push -q origin tmpx refy && git checkout -q main )
"$SYNC" "${COMMON[@]}" --workdir "$T/wd3" --repo fx --report "$T/plan-r1.json" >/dev/null 2>&1
( cd "$W" && git push -q origin :tmpx )
"$SYNC" "${COMMON[@]}" --workdir "$T/wd3" --repo fx --report "$T/plan-r2.json" >/dev/null 2>&1
Y1="$(python3 -c "import json;d=json.load(open('$T/plan-r1.json'));print([x['target'] for x in d['repos'][0]['plan'] if x['ref']=='refs/heads/refy'][0])")"
Y2="$(python3 -c "import json;d=json.load(open('$T/plan-r2.json'));print([x['target'] for x in d['repos'][0]['plan'] if x['ref']=='refs/heads/refy'][0])")"
expect "$Y2" "$Y1" "a commit whose message cites a rewritten commit keeps its sha when that ref is deleted"
( cd "$W" && git push -q origin :refy )

echo "== incremental fast-forward"
OLDMAIN="$(git --git-dir="$GH" rev-parse main)"
( cd "$W" && git checkout -q main && echo three >> a.txt && git commit -qam "Three" && git push -q origin main )
"$SYNC" "${COMMON[@]}" --workdir "$T/wd1" --repo fx --report "$T/plan3.json" >/dev/null 2>&1
expect "$(python3 -c "import json;d=json.load(open('$T/plan3.json'));print([x['action'] for x in d['repos'][0]['plan'] if x['ref']=='refs/heads/main'][0])")" "fast-forward" "new GitLab commit plans as fast-forward"
"$SYNC" "${COMMON[@]}" --workdir "$T/wd1" --repo fx --apply >/dev/null 2>&1
expect "$(git --git-dir="$GH" rev-parse main~1)" "$OLDMAIN" "earlier GitHub sha unchanged under the new commit"

echo "== GitHub-side commit (drift)"
G2="$T/g2"; git clone -q "$GH" "$G2" 2>/dev/null
( cd "$G2" && echo mirror > MIRROR.md && git add MIRROR.md && git commit -qm "mirror: sync" && git push -q origin main && git push -q origin main:refs/heads/gh-only )
"$CHECK" "${COMMON[@]}" --workdir "$T/wd1" --repo fx >"$T/chk2" 2>&1; rc=$?
expect "$rc" 1 "check detects GitHub-side commit"
grep -q "refs/heads/main .*DIFF" "$T/chk2" && ok "drift is on main" || bad "drift is on main"
grep -q "refs/heads/gh-only .*EXTRA" "$T/chk2" && ok "GitHub-only branch reported" || bad "GitHub-only branch reported"
GHMAIN="$(git --git-dir="$GH" rev-parse main)"
"$SYNC" "${COMMON[@]}" --workdir "$T/wd1" --repo fx --apply >/dev/null 2>&1
expect "$(git --git-dir="$GH" rev-parse main)" "$GHMAIN" "without --allow-force the diverged branch is left alone"
"$SYNC" "${COMMON[@]}" --workdir "$T/wd1" --repo fx --apply --allow-force --backup-bundle >/dev/null 2>&1
NEWMAIN="$(git --git-dir="$GH" rev-parse main)"
[ "$NEWMAIN" != "$GHMAIN" ] && ok "--allow-force replaces the diverged branch" || bad "--allow-force replaces the diverged branch"
expect "$(git --git-dir="$GH" rev-parse main~1)" "$OLDMAIN" "replaced branch is the filtered GitLab history"
B="$(ls "$T/bk"/fx-github-*.bundle 2>/dev/null | head -1)"
[ -n "$B" ] && git bundle list-heads "$B" | grep >/dev/null "$GHMAIN" && ok "backup bundle holds the replaced GitHub commit" || bad "backup bundle holds the replaced GitHub commit"
expect "$(git --git-dir="$T/wd1/backup/fx.git" for-each-ref --format='%(objectname)' 'refs/backup/*/heads/main' | sort -u)" "$GHMAIN" "backup repository pins the replaced GitHub sha"
expect "$(git --git-dir="$GH" rev-parse -q --verify refs/heads/gh-only >/dev/null && echo yes)" "yes" "GitHub-only branch kept without --prune"
"$SYNC" "${COMMON[@]}" --workdir "$T/wd1" --repo fx --apply --prune >/dev/null 2>&1
expect "$(git --git-dir="$GH" rev-parse -q --verify refs/heads/gh-only >/dev/null && echo yes)" "yes" "--prune alone keeps a GitHub-only branch"
"$SYNC" "${COMMON[@]}" --workdir "$T/wd1" --repo fx --apply --prune --prune-github-only >/dev/null 2>&1
expect "$(git --git-dir="$GH" rev-parse -q --verify refs/heads/gh-only >/dev/null && echo yes || echo no)" "no" "--prune-github-only removes the GitHub-only branch"
"$CHECK" "${COMMON[@]}" --workdir "$T/wd1" --repo fx >/dev/null 2>&1; expect "$?" 0 "check: in sync again"

echo "== GitLab-driven rewrite and deletion"
( cd "$W" && git checkout -q feature && git commit -q --amend -m "Feature (reworded)" && git push -q -f origin feature )
"$SYNC" "${COMMON[@]}" --workdir "$T/wd1" --repo fx --report "$T/plan5.json" >/dev/null 2>&1
expect "$(python3 -c "import json;d=json.load(open('$T/plan5.json'));print([x['action'] for x in d['repos'][0]['plan'] if x['ref']=='refs/heads/feature'][0])")" "rewind" "GitLab force-push plans as rewind"
"$SYNC" "${COMMON[@]}" --workdir "$T/wd1" --repo fx --apply >/dev/null 2>&1
expect "$(git --git-dir="$GH" log -1 --format=%s feature)" "Feature (reworded)" "rewind applies without --allow-force"
"$SYNC" "${COMMON[@]}" --workdir "$T/wd1" --repo fx --apply --skip-ref 'refs/heads/*' >/dev/null 2>&1
( cd "$W" && git push -q origin :feature )
"$SYNC" "${COMMON[@]}" --workdir "$T/wd1" --repo fx --apply >/dev/null 2>&1
expect "$(git --git-dir="$GH" rev-parse -q --verify refs/heads/feature >/dev/null && echo yes)" "yes" "GitLab deletion kept without --prune"
"$SYNC" "${COMMON[@]}" --workdir "$T/wd1" --repo fx --apply --prune >/dev/null 2>&1
expect "$(git --git-dir="$GH" rev-parse -q --verify refs/heads/feature >/dev/null && echo yes || echo no)" "no" "--prune follows a GitLab deletion"
( cd "$W" && git checkout -q main && git push -q origin main:refs/heads/side && echo s > s.txt && git add s.txt && git commit -qm side-1 && git push -q origin HEAD:side && git reset -q --hard HEAD~1 )
"$SYNC" "${COMMON[@]}" --workdir "$T/wd1" --repo fx --apply >/dev/null 2>&1
G3="$T/g3"; git clone -q "$GH" "$G3" 2>/dev/null
( cd "$G3" && git checkout -q side && echo gh > gh.txt && git add gh.txt && git commit -qm "direct GitHub work" && git push -q origin side )
SIDE="$(git --git-dir="$GH" rev-parse side)"
"$SYNC" "${COMMON[@]}" --workdir "$T/wd1" --repo fx --apply --allow-force --skip-ref refs/heads/side >/dev/null 2>&1
expect "$(git --git-dir="$GH" rev-parse side)" "$SIDE" "--skip-ref leaves a ref untouched"
"$SYNC" "${COMMON[@]}" --workdir "$T/wd1" --repo fx --apply --allow-force >/dev/null 2>&1
expect "$(git --git-dir="$GH" log -1 --format=%s side)" "side-1" "--allow-force restores the GitLab branch"

echo "== release-attached tag"
mkdir -p "$T/api/repos/org/fx"; printf '[{"tag_name":"v1","draft":false}]' > "$T/api/repos/org/fx/releases.json"
TAGV1="$(git --git-dir="$GH" rev-parse v1)"
( cd "$W" && git tag -f -a v1 -m "v1 moved" main >/dev/null && git push -q -f origin v1 )
"$SYNC" "${COMMON[@]}" --workdir "$T/wd1" --repo fx --apply --allow-force --report "$T/plan4.json" >/dev/null 2>&1; rc=$?
expect "$rc" 0 "a release-held tag is reported, not an error"
expect "$(python3 -c "import json;d=json.load(open('$T/plan4.json'));print([x['action'] for x in d['repos'][0]['plan'] if x['ref']=='refs/tags/v1'][0])")" "rewind-BLOCKED(release:published)" "tag with a release is BLOCKED"
expect "$(git --git-dir="$GH" rev-parse v1)" "$TAGV1" "tag with a release is not moved"
"$CHECK" "${COMMON[@]}" --workdir "$T/wd1" --repo fx >"$T/chk4" 2>&1; rc=$?
[ "$rc" = 0 ] || cat "$T/chk4"
expect "$rc" 0 "check: a release-held tag is reported apart from drift"
grep -q "refs/tags/v1 .*RELEASE" "$T/chk4" && ok "check marks the release-held tag" || bad "check marks the release-held tag"
"$CHECK" "${COMMON[@]}" --workdir "$T/wd1" --repo fx --strict-releases >/dev/null 2>&1
expect "$?" 1 "check --strict-releases counts it as drift"

echo "== binary blob carrying a listed literal"
( W3="$T/w3"; git clone -q "$T/gl/grp/bin.git" "$W3" 2>/dev/null; cd "$W3"
  printf 'x\0y%s\n' "$LIT" > blob.dat; git add blob.dat; git commit -qm "binary"; git push -q origin main )
"$SYNC" "${COMMON[@]}" --workdir "$T/wd1" --repo bin --apply >/dev/null 2>"$T/log5"; rc=$?
expect "$rc" 1 "binary literal stops the sync"
expect "$(git --git-dir="$T/gh/org/bin.git" for-each-ref | wc -l)" 0 "nothing pushed for the refused repo"

echo "== identity mode"
( W4="$T/w4"; git clone -q "$T/gl/grp/id.git" "$W4" 2>/dev/null; cd "$W4"
  git config user.email dev@example.org
  for i in 1 2 3 4 5 6; do head -c 3000 /dev/urandom | base64 > "f$i"; git add "f$i"; git commit -qm "c$i"; done
  git push -q origin main )
"$SYNC" "${COMMON[@]}" --workdir "$T/wd1" --repo id --apply --push-budget 6000 >/dev/null 2>"$T/log6"; rc=$?
expect "$rc" 0 "identity apply exits 0"
expect "$(git --git-dir="$T/gh/org/id.git" rev-parse main)" "$(git --git-dir="$T/gl/grp/id.git" rev-parse main)" "identity mode keeps the GitLab sha"
n="$(grep -c "step " "$T/log6")"
[ "$n" -ge 2 ] && ok "small push budget splits the push ($n steps)" || bad "small push budget splits the push ($n steps)"
"$CHECK" "${COMMON[@]}" --workdir "$T/wd1" --repo id >/dev/null 2>&1; expect "$?" 0 "check: identity repo in sync"

echo "== identity guard"
( cd "$T/w4" && head -c 1200000 /dev/urandom > large.bin && echo g > g.txt && git add large.bin g.txt && git commit -qm "large" && git push -q origin main )
"$SYNC" "${COMMON[@]}" --workdir "$T/wd1" --repo id --apply >/dev/null 2>&1; rc=$?
expect "$rc" 1 "identity mode refuses a blob over the limit"
"$CHECK" "${COMMON[@]}" --workdir "$T/wd1" --repo id >/dev/null 2>&1; expect "$?" 1 "check flags the unsynced identity repo"

echo "== archived GitHub copy"
# the fixture "GitHub" refuses pushes while its API object says archived
ARJ="$T/api/repos/org/ar.json"; GLJ="$T/glapi/projects/grp/ar.json"; ARGH="$T/gh/org/ar.git"
mkdir -p "$(dirname "$GLJ")"
cat > "$ARGH/hooks/pre-receive" <<EOF
#!/bin/sh
python3 -c 'import json,sys; sys.exit(1 if json.load(open("$ARJ")).get("archived") else 0)' && exit 0
echo "This repository was archived so it is read-only." >&2; exit 1
EOF
chmod +x "$ARGH/hooks/pre-receive"
arj() { printf '{"archived": %s, "permissions": {"admin": %s}}' "$1" "${2:-true}" > "$ARJ"; }
glj() { printf '{"archived": %s}' "$1" > "$GLJ"; }
archived() { python3 -c "import json;print(json.load(open('$ARJ'))['archived'])"; }
arcommit() { ( cd "$T/w5" && echo "$1" >> r.txt && git add r.txt && git commit -qm "$1" && git push -q origin main ); }
git clone -q "$T/gl/grp/ar.git" "$T/w5" 2>/dev/null
arcommit one; arj false; glj false
"$SYNC" "${COMMON[@]}" --workdir "$T/wd1" --repo ar --apply >/dev/null 2>&1; expect "$?" 0 "unarchived copy: plain apply"
AR1="$(git --git-dir="$ARGH" rev-parse main)"
arj true
"$SYNC" "${COMMON[@]}" --workdir "$T/wd1" --repo ar --apply --prune >/dev/null 2>"$T/log7"; rc=$?
expect "$rc" 0 "archived copy with nothing to push: apply exits 0"
expect "$(archived)" "True" "nothing to push: the archive is not touched"
arcommit two
"$SYNC" "${COMMON[@]}" --workdir "$T/wd1" --repo ar --apply >/dev/null 2>"$T/log8"; rc=$?
expect "$rc" 1 "archived copy, GitLab project not archived: push refused"
expect "$(git --git-dir="$ARGH" rev-parse main)" "$AR1" "refused: GitHub branch unchanged"
expect "$(archived)" "True" "refused: the copy stays archived"
grep -q "GitLab project grp/ar is not archived" "$T/log8" && ok "refusal names the GitLab state" || bad "refusal names the GitLab state"
glj true; arj true false
"$SYNC" "${COMMON[@]}" --workdir "$T/wd1" --repo ar --apply >/dev/null 2>"$T/log8b"; rc=$?
expect "$rc" 1 "archived on both, token without admin: push refused"
expect "$(archived)" "True" "no admin: the copy stays archived"
arj true
"$SYNC" "${COMMON[@]}" --workdir "$T/wd1" --repo ar --report "$T/plan9.json" >/dev/null 2>"$T/log9"
grep -q "lifts the GitHub archive" "$T/log9" && ok "dry run notes the archive lift" || bad "dry run notes the archive lift"
expect "$(archived)" "True" "dry run leaves the archive alone"
"$SYNC" "${COMMON[@]}" --workdir "$T/wd1" --repo ar --apply --report "$T/plan10.json" >/dev/null 2>"$T/log10"; rc=$?
expect "$rc" 0 "archived on both forges: apply exits 0"
expect "$(archived)" "True" "copy archived again after the push"
expect "$(git --git-dir="$ARGH" log -1 --format=%s main)" "two" "the push went through while the archive was lifted"
expect "$(python3 -c "import json;d=json.load(open('$T/plan10.json'));a=d['repos'][0]['archive'];print(a['github_archived'],a['gitlab_archived'],a['lifted'],a['github_archived_after'])")" \
       "True True True True" "report records the archive state before and after"
grep -q "archived again" "$T/wd1/archive-events.log" && ok "archive events are logged" || bad "archive events are logged"
"$CHECK" "${COMMON[@]}" --workdir "$T/wd1" --repo ar >/dev/null 2>&1; expect "$?" 0 "check: archived copy in sync"
arcommit three
: > "${ARJ%.json}.fail-archived-true"
FXMAIN="$(git --git-dir="$GH" rev-parse main)"
( cd "$W" && git checkout -q main && echo four >> a.txt && git commit -qam "Four" && git push -q origin main )
NCZ_GHSYNC_WORKDIR="$T/wd1" "$REPO/tools/github-sync/run-hourly.sh" "${COMMON[@]}" --repo ar --repo fx >"$T/out11" 2>&1; rc=$?
expect "$rc" 3 "copy that cannot be archived again: run exits 3"
grep -q "ALERT: GitHub copy org/ar could not be archived again" "$T/out11" && ok "run-hourly prints the ALERT" || bad "run-hourly prints the ALERT"
expect "$(archived)" "False" "the failure is real: the copy is left unarchived"
expect "$(git --git-dir="$GH" rev-parse main)" "$FXMAIN" "the run stops after the alert (next repository untouched)"
rm -f "${ARJ%.json}.fail-archived-true"
"$SYNC" "${COMMON[@]}" --workdir "$T/wd1" --repo ar --apply >/dev/null 2>&1; expect "$?" 0 "unarchived again: plain apply"
arj true

echo "== scheduled pass keeps GitHub-side work"
( cd "$T/g3" && git fetch -q origin && git checkout -q side && git reset -q --hard origin/side && echo h > h.txt && git add h.txt && git commit -qm "more direct GitHub work" && git push -q origin side )
SIDE2="$(git --git-dir="$GH" rev-parse side)"
NCZ_GHSYNC_WORKDIR="$T/wd1" "$REPO/tools/github-sync/run-hourly.sh" "${COMMON[@]}" --repo fx >/dev/null 2>&1
expect "$(git --git-dir="$GH" rev-parse side)" "$SIDE2" "run-hourly.sh does not overwrite a GitHub-side commit"
ls "$T/wd1/logs/"*-check-after.log >/dev/null 2>&1 && ok "run-hourly.sh writes its logs" || bad "run-hourly.sh writes its logs"

echo
echo "test-github-sync: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ]
