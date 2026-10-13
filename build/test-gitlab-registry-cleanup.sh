#!/bin/bash
# test-gitlab-registry-cleanup.sh -- regression tests for
# tools/gitlab-registry-cleanup.sh against a mocked curl (no network).
#
# The mock keeps a small GitLab (projects, releases with asset links, generic
# and non-generic packages with files) in a JSON state file and logs every
# request. The tests check that a dry run changes nothing, that KEEP keeps the
# newest versions by created_at across paginated listings, that duplicate file
# names are reduced to the newest copy, that versions linked from a release
# and packages no rule names are never removed, that the manifest is written
# before any removal, that a second run is a no-op, and that the token never
# appears in curl's argv or in the output.
#
# Run: bash build/test-gitlab-registry-cleanup.sh
# The checks are eval'd strings, expanded when they run:
# shellcheck disable=SC2016,SC2034
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
TOOL="$ROOT/tools/gitlab-registry-cleanup.sh"
PASS=0; FAILS=0
ok()  { PASS=$((PASS+1)); echo "ok   $1"; }
bad() { FAILS=$((FAILS+1)); echo "FAIL $1${2:+: $2}"; }
check() { if eval "$2"; then ok "$1"; else bad "$1" "$2"; fi; }

for t in jq python3; do command -v "$t" >/dev/null || { echo "SKIP: $t not installed"; exit 0; }; done
[ -x "$TOOL" ] || { echo "FATAL: $TOOL missing or not executable" >&2; exit 2; }
BASH4=$BASH
if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
  for b in /opt/homebrew/bin/bash /usr/local/bin/bash; do [ -x "$b" ] && BASH4=$b && break; done
fi

T="$(mktemp -d "${TMPDIR:-/tmp}/test-glclean.XXXXXX")"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
TOKEN_VALUE="tok-$RANDOM-$RANDOM-not-a-real-token"
export TEST_TOKEN="$TOKEN_VALUE"
export NCZ_GITLAB_TOKEN_VAR=TEST_TOKEN
unset NCZ_GITLAB_TOKEN_HELPER
export NCZ_GITLAB_API="https://gitlab.example/api/v4"
export MOCK_STATE="$T/state.json" MOCK_LOG="$T/calls.log" MOCK_ARGV="$T/argv.log"

# ---- mock curl ----------------------------------------------------------------
cat > "$T/bin/curl" <<'PY'
#!/usr/bin/env python3
import json, os, sys, urllib.parse as up
argv = sys.argv[1:]
with open(os.environ["MOCK_ARGV"], "a") as fh:
    fh.write(json.dumps(argv) + "\n")
method, out, wfmt, url, cfg = "GET", None, "", None, None
i = 0
while i < len(argv):
    a = argv[i]
    if a == "-X": method = argv[i+1]; i += 2; continue
    if a == "-o": out = argv[i+1]; i += 2; continue
    if a == "-w": wfmt = argv[i+1]; i += 2; continue
    if a in ("-H", "-K"):
        if a == "-K": cfg = argv[i+1]
        i += 2; continue
    if a.startswith("-"): i += 1; continue
    url = a; i += 1
headers = sys.stdin.read() if cfg == "-" else ""
st = json.load(open(os.environ["MOCK_STATE"]))
tok = os.environ.get("TEST_TOKEN", "")
authed = bool(tok) and ('PRIVATE-TOKEN: %s' % tok) in headers
with open(os.environ["MOCK_LOG"], "a") as fh:
    fh.write("%s %s auth=%s\n" % (method, url, "yes" if authed else "no"))
pu = up.urlsplit(url)
q = dict(up.parse_qsl(pu.query))
parts = [up.unquote(p) for p in pu.path[len("/api/v4"):].strip("/").split("/")]
code, body = 404, {"message": "404 Not Found"}
def page(items):
    pp = int(q.get("per_page", 20)); pg = int(q.get("page", 1))
    return items[(pg-1)*pp: pg*pp]
projs = {str(p["id"]): p for p in st["projects"]}
byname = {p["path"]: p for p in st["projects"]}
if not authed:
    code, body = 401, {"message": "401 Unauthorized"}
elif parts[0] == "projects" and len(parts) == 2 and method == "GET":
    p = projs.get(parts[1]) or byname.get(parts[1])
    if p: code, body = 200, {"id": p["id"], "path_with_namespace": p["path"]}
elif parts[0] == "projects" and parts[1] in projs:
    p = projs[parts[1]]; r = parts[2:]
    if r == ["releases"] and method == "GET":
        code, body = 200, page(p["releases"])
    elif r == ["packages"] and method == "GET":
        items = [k for k in p["packages"] if k["package_type"] == q.get("package_type", k["package_type"])]
        items.sort(key=lambda k: k["id"])
        code, body = 200, [{x: v for x, v in k.items() if x != "files"} for k in page(items)]
    elif r[0] == "packages" and len(r) == 3 and r[2] == "package_files" and method == "GET":
        k = [k for k in p["packages"] if str(k["id"]) == r[1]]
        if k: code, body = 200, page(k[0]["files"])
    elif method == "DELETE" and len(r) >= 2 and r[1] in st.get("fail_delete", []):
        code, body = 500, {"message": "boom"}
    elif r[0] == "packages" and len(r) == 2 and method == "DELETE":
        n = len(p["packages"]); p["packages"] = [k for k in p["packages"] if str(k["id"]) != r[1]]
        if len(p["packages"]) < n: code, body = 204, None
    elif r[0] == "packages" and len(r) == 4 and r[2] == "package_files" and method == "DELETE":
        for k in p["packages"]:
            if str(k["id"]) == r[1]:
                n = len(k["files"]); k["files"] = [f for f in k["files"] if str(f["id"]) != r[3]]
                if len(k["files"]) < n: code, body = 204, None
json.dump(st, open(os.environ["MOCK_STATE"], "w"))
if out:
    with open(out, "w") as fh:
        if body is not None: json.dump(body, fh)
if "%{http_code}" in wfmt:
    sys.stdout.write(wfmt.replace("%{http_code}", str(code)))
PY
chmod +x "$T/bin/curl"
export PATH="$T/bin:$PATH"

# ---- fixtures -----------------------------------------------------------------
# Project 10 "ncz-os/zoder": master (3 copies of each of 2 files), 105 dated
# nightly versions (created out of id order so sorting must use created_at),
# one non-generic package and one unrelated generic package.
# Project 20 "ncz-os/cix-installer": 4 image versions, the oldest linked from a
# release; two kernel source packages no rule names.
reset_state() {
  python3 - "$MOCK_STATE" <<'PY'
import json, sys
nid = [1000]
def fid():
    nid[0] += 1; return nid[0]
def f(name, day, h=0):
    return {"id": fid(), "file_name": name, "size": 100 + h, "file_sha256": "%064x" % nid[0],
            "created_at": "2026-%s T%02d:00:00Z".replace(" ", "") % (day, h)}
zp = []
master = {"id": 1, "name": "zoder-nightly", "version": "master", "package_type": "generic",
          "created_at": "2026-07-03T00:00:00Z",
          "files": [f(n, "07-03", h) for h in range(3) for n in ("zoder-x86_64", "zoder-x86_64.sha256")]}
zp.append(master)
import datetime
d0 = datetime.date(2026, 6, 1)
order = list(range(105)); order = order[1::2] + order[0::2]   # ids not in date order
for k, i in enumerate(order):
    d = d0 + datetime.timedelta(days=i)
    ds = d.isoformat()
    files = [f("zoder-x86_64", ds[5:]), f("zoder-x86_64.sha256", ds[5:])]
    if i == 104: files += [f("zoder-x86_64", ds[5:], 5)]           # duplicate in the newest
    zp.append({"id": 100 + k, "name": "zoder-nightly", "version": ds, "package_type": "generic",
               "created_at": ds + "T10:00:00Z", "files": files})
zp.append({"id": 500, "name": "zoder-nightly", "version": "2026-01-01", "package_type": "npm",
           "created_at": "2026-01-01T00:00:00Z", "files": [f("x", "01-01")]})
zp.append({"id": 501, "name": "zoder", "version": "0.2.0", "package_type": "generic",
           "created_at": "2026-06-29T00:00:00Z", "files": [f("zoder", "06-29"), f("zoder", "06-29", 1)]})
cp = []
for k, v in enumerate(["26.07-a", "26.08-b", "26.09-c", "26.10-d"]):
    cp.append({"id": 600 + k, "name": "ncz-os-image", "version": v, "package_type": "generic",
               "created_at": "2026-%02d-01T00:00:00Z" % (7 + k),
               "files": [f("ncz.img.zst.part-00", "%02d-01" % (7 + k))]})
cp.append({"id": 700, "name": "linux-source-cix-sky1-ncz", "version": "7.0.12", "package_type": "generic",
           "created_at": "2026-07-26T00:00:00Z", "files": [f("linux-src.tar.gz", "07-26")]})
cp.append({"id": 701, "name": "linux-pristine-base-cix-sky1-ncz", "version": "7.2-075b7484",
           "package_type": "generic", "created_at": "2026-08-03T00:00:00Z", "files": [f("base.tar.gz", "08-03")]})
rel = [{"tag_name": "v26.07-a", "assets": {"links": [
    {"id": 1, "name": "part", "url": "https://gitlab.example/api/v4/projects/20/packages/generic/ncz-os-image/26.07-a/ncz.img.zst.part-00"}]}}]
oldest = [k for k in zp if k.get("version") == "2026-06-01"][0]
zrel = [{"tag_name": "pinned", "assets": {"links": [
    {"id": 2, "name": "old master copy", "url": "https://gitlab.example/ncz-os/zoder/-/package_files/%d/download" % master["files"][0]["id"]},
    {"id": 3, "name": "pinned day", "url": "https://gitlab.example/ncz-os/zoder/-/package_files/%d/download" % oldest["files"][0]["id"]}]}}]
json.dump({"projects": [{"id": 10, "path": "ncz-os/zoder", "packages": zp, "releases": zrel},
                        {"id": 20, "path": "ncz-os/cix-installer", "packages": cp, "releases": rel}]},
          open(sys.argv[1], "w"))
PY
  : > "$MOCK_LOG"; : > "$MOCK_ARGV"
}
RULES="$T/rules.conf"
cat > "$RULES" <<'EOF'
# test rules
ncz-os/cix-installer  ncz-os-image   .                             2    yes
ncz-os/zoder          zoder-nightly  ^master$                      all  yes
ncz-os/zoder          zoder-nightly  ^[0-9]{4}-[0-9]{2}-[0-9]{2}$  14   yes
EOF
st() { jq -r "$1" "$MOCK_STATE"; }
deletes() { grep -c '^DELETE ' "$MOCK_LOG" || true; }
run() { "$BASH4" "$TOOL" --rules "$RULES" "$@" 2>&1; }

# 1. dry run: plans, changes nothing
reset_state
out=$(run --manifest "$T/plan.json"); rc=$?
check "dry run exits 0" '[ "$rc" -eq 0 ]' || echo "$out"
check "dry run sends no DELETE" '[ "$(deletes)" -eq 0 ]'
check "dry run plans 90 old dated versions + 1 image version" 'grep -q "plan: 91 versions and" <<<"$out"'
check "dry run plans 3 master + 1 dated duplicate files" 'grep -q "and 4 duplicate files" <<<"$out"'
check "dry run says nothing changed" 'grep -q "Dry run: nothing was changed" <<<"$out"'
check "dry-run manifest has the planned removals" '[ "$(jq ".removals | length" "$T/plan.json")" -eq 95 ] && [ "$(jq -r .mode "$T/plan.json")" = dry-run ]'
check "manifest records sha256 of package files" '[ "$(jq "[.removals[] | select(.kind==\"package\") | .files[].sha256 | select(length==64)] | length" "$T/plan.json")" -ge 91 ]'
check "linked image version reported as kept" 'grep -q "keep     ncz-os/cix-installer ncz-os-image 26.07-a (a release links to it)" <<<"$out"'
check "listing pages past 100 packages" 'grep -q "packages?package_type=generic&per_page=100&page=2" "$MOCK_LOG"'

# 2. apply
reset_state
out=$(run --apply --manifest "$T/applied.json" --log "$T/run.log"); rc=$?
check "apply exits 0" '[ "$rc" -eq 0 ]' || echo "$out"
check "apply removes 91 versions and 4 files" '[ "$(deletes)" -eq 95 ]'
check "newest 14 dated versions and the release-linked day remain" '[ "$(st "[.projects[0].packages[] | select(.package_type==\"generic\" and .name==\"zoder-nightly\" and .version!=\"master\") | .version] | sort | join(\",\")")" = "$(python3 -c "import datetime as d;print(\",\".join((d.date(2026,6,1)+d.timedelta(days=i)).isoformat() for i in [0]+list(range(91,105))))")" ]'
check "master keeps one file per name plus the release-linked copy" '[ "$(st "[.projects[0].packages[] | select(.version==\"master\") | .files[].file_name] | sort | join(\",\")")" = "zoder-x86_64,zoder-x86_64,zoder-x86_64.sha256" ]'
check "master keeps the newest copy and the linked old one" '[ "$(st "[.projects[0].packages[] | select(.version==\"master\") | .files[] | select(.file_name==\"zoder-x86_64\") | .created_at] | sort | join(\",\")")" = "2026-07-03T00:00:00Z,2026-07-03T02:00:00Z" ]'
check "duplicate inside newest dated version removed" '[ "$(st "[.projects[0].packages[] | select(.version==\"2026-09-13\") | .files[]] | length")" -eq 2 ]'
check "non-generic package untouched" '[ "$(st "[.projects[0].packages[] | select(.id==500)] | length")" -eq 1 ]'
check "package no rule names untouched (even with duplicates)" '[ "$(st "[.projects[0].packages[] | select(.id==501) | .files[]] | length")" -eq 2 ]'
check "image: newest 2 + release-linked remain" '[ "$(st "[.projects[1].packages[] | select(.name==\"ncz-os-image\") | .version] | sort | join(\",\")")" = "26.07-a,26.09-c,26.10-d" ]'
check "kernel source packages untouched" '[ "$(st "[.projects[1].packages[] | select(.name|startswith(\"linux-\"))] | length")" -eq 2 ]'
check "apply manifest written in apply mode" '[ "$(jq -r .mode "$T/applied.json")" = apply ] && [ "$(jq ".removals | length" "$T/applied.json")" -eq 95 ]'
check "log line appended" 'grep -q "gitlab-registry-cleanup apply rules=rules.conf versions=91 files=4 bytes=[0-9]* result=ok" "$T/run.log"'
check "token never in curl argv" '! grep -qF "$TOKEN_VALUE" "$MOCK_ARGV"'
check "token never in output" '! grep -qF "$TOKEN_VALUE" <<<"$out"'
check "every request authenticated via stdin config" '! grep -q "auth=no" "$MOCK_LOG"'

# 3. second run is a no-op
: > "$MOCK_LOG"
out=$(run --apply); rc=$?
check "second apply exits 0" '[ "$rc" -eq 0 ]'
check "second apply removes nothing" '[ "$(deletes)" -eq 0 ] && grep -q "plan: 0 versions and 0 duplicate files" <<<"$out"'

# 4. a failing removal: manifest already written, exit 1, others still removed
reset_state
python3 - "$MOCK_STATE" <<'PY'
import json, sys
s = json.load(open(sys.argv[1])); s["fail_delete"] = ["601"]; json.dump(s, open(sys.argv[1], "w"))
PY
out=$(run --apply --manifest "$T/fail.json"); rc=$?
check "failed removal exits 1" '[ "$rc" -eq 1 ]'
check "failed removal reported" 'grep -q "FAILED   ncz-os-image 26.08-b" <<<"$out"'
check "manifest exists despite the failure" '[ "$(jq ".removals | length" "$T/fail.json")" -eq 95 ]'
check "other removals still made" '[ "$(st "[.projects[0].packages[] | select(.name==\"zoder-nightly\" and .package_type==\"generic\")] | length")" -eq 16 ]'

# 5. token and rules errors make no request
reset_state
TEST_TOKEN="" "$BASH4" "$TOOL" --rules "$RULES" >/dev/null 2>&1; rc=$?
check "no token exits 2" '[ "$rc" -eq 2 ] && [ ! -s "$MOCK_LOG" ]'
for bad_rule in "ncz-os/zoder zoder-nightly . 0 yes" "ncz-os/zoder zoder-nightly . 2" \
                "ncz-os/zoder zoder-nightly ( 2 yes" "ncz-os/zoder zoder-nightly . 2 maybe"; do
  echo "$bad_rule" > "$T/bad.conf"
  "$BASH4" "$TOOL" --rules "$T/bad.conf" >/dev/null 2>&1; rc=$?
  check "bad rule '$bad_rule' exits 2" '[ "$rc" -eq 2 ] && [ ! -s "$MOCK_LOG" ]'
done
"$BASH4" "$TOOL" --rules "$T/none.conf" >/dev/null 2>&1; rc=$?
check "missing rules file exits 2" '[ "$rc" -eq 2 ]'
"$BASH4" "$TOOL" --bogus >/dev/null 2>&1; rc=$?
check "unknown option exits 2" '[ "$rc" -eq 2 ]'

# 6. token helper (GIT_ASKPASS style)
reset_state
printf '#!/bin/sh\necho "%s"\n' "$TOKEN_VALUE" > "$T/bin/tokhelper"; chmod +x "$T/bin/tokhelper"
NCZ_GITLAB_TOKEN_VAR=UNSET_VAR NCZ_GITLAB_TOKEN_HELPER="$T/bin/tokhelper" "$BASH4" "$TOOL" --rules "$RULES" >/dev/null 2>&1; rc=$?
check "token helper run exits 0" '[ "$rc" -eq 0 ] && ! grep -q "auth=no" "$MOCK_LOG"'

# 7. the shipped rules file parses and never names kernel source packages
check "shipped rules name no linux-* package" '! grep -Ev "^[[:space:]]*(#|$)" "$ROOT/tools/registry-retention.conf" | grep >/dev/null " linux-"'
"$BASH4" "$TOOL" --help | grep >/dev/null -- "--apply"; rc=$?
check "--help documents --apply" '[ "$rc" -eq 0 ]'

echo "passed=$PASS failed=$FAILS"
[ "$FAILS" -eq 0 ]
