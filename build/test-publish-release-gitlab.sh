#!/bin/bash
# test-publish-release-gitlab.sh -- regression tests for
# tools/publish-release-gitlab.sh against a mocked curl (no network).
#
# The mock keeps a small in-memory GitLab (project, tags, generic packages,
# releases, asset links) in a JSON state file and logs every request, so the
# tests can check exactly which calls a run makes: dry runs change nothing,
# uploads are verified against the registry's sha256, a bad part or a missing
# tag stops the run before any change, re-runs skip files already present,
# --prune-old keeps the newest N versions per package and removes stale links, and the
# token never appears in curl's argv or in the output.
#
# Run: bash build/test-publish-release-gitlab.sh
# The checks are eval'd strings, expanded when they run:
# shellcheck disable=SC2016,SC2034
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
TOOL="$ROOT/tools/publish-release-gitlab.sh"
PASS=0; FAILS=0
ok()  { PASS=$((PASS+1)); echo "ok   $1"; }
bad() { FAILS=$((FAILS+1)); echo "FAIL $1${2:+: $2}"; }
check() { if eval "$2"; then ok "$1"; else bad "$1" "$2"; fi; }

for t in jq python3; do command -v "$t" >/dev/null || { echo "SKIP: $t not installed"; exit 0; }; done
[ -x "$TOOL" ] || { echo "FATAL: $TOOL missing or not executable" >&2; exit 2; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
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
import hashlib, json, os, re, sys, urllib.parse as up
argv = sys.argv[1:]
with open(os.environ["MOCK_ARGV"], "a") as fh:
    fh.write(json.dumps(argv) + "\n")
method, out, wfmt, data, upload, url, cfg = "GET", None, "", None, None, None, None
i = 0
while i < len(argv):
    a = argv[i]
    if a in ("-X",): method = argv[i+1]; i += 2; continue
    if a == "-o": out = argv[i+1]; i += 2; continue
    if a == "-w": wfmt = argv[i+1]; i += 2; continue
    if a == "-H": i += 2; continue
    if a == "-K": cfg = argv[i+1]; i += 2; continue
    if a == "--data-binary": data = argv[i+1]; i += 2; continue
    if a == "-T": upload = argv[i+1]; i += 2; continue
    if a.startswith("-"): i += 1; continue
    url = a; i += 1
headers = sys.stdin.read() if cfg == "-" else ""
st = json.load(open(os.environ["MOCK_STATE"]))
authed = ('PRIVATE-TOKEN: %s' % os.environ.get("TEST_TOKEN", "")) in headers and os.environ.get("TEST_TOKEN")
with open(os.environ["MOCK_LOG"], "a") as fh:
    fh.write("%s %s auth=%s\n" % (method, url, "yes" if authed else "no"))
pu = up.urlsplit(url)
path = pu.path
q = dict(up.parse_qsl(pu.query))
base = "/api/v4"
assert path.startswith(base), path
parts = [up.unquote(p) for p in path[len(base):].strip("/").split("/")]
code, body = 404, {"message": "404 Not Found"}
def nid():
    st["next_id"] += 1; return st["next_id"]
def page(items):
    pp = int(q.get("per_page", 20)); pg = int(q.get("page", 1))
    return items[(pg-1)*pp: pg*pp]
proj = st["project"]
if not authed:
    code, body = 401, {"message": "401 Unauthorized"}
elif parts[0] == "projects" and len(parts) == 2 and method == "GET":
    if parts[1] in (proj["path"], str(proj["id"])): code, body = 200, proj
elif parts[0] == "projects" and parts[1] == str(proj["id"]):
    r = parts[2:]
    rel = st["releases"]
    if r[:2] == ["repository", "tags"] and method == "GET":
        if r[2] in st["tags"]: code, body = 200, {"name": r[2]}
    elif r == ["packages"] and method == "GET":
        items = [p for p in st["packages"] if p["name"] == q.get("package_name", p["name"])]
        code, body = 200, [{k: v for k, v in p.items() if k != "files"} for p in page(items)]
    elif r[0] == "packages" and len(r) == 3 and r[2] == "package_files" and method == "GET":
        p = [p for p in st["packages"] if str(p["id"]) == r[1]]
        if p: code, body = 200, page(p[0]["files"])
    elif r[0] == "packages" and len(r) == 2 and method == "DELETE":
        n = len(st["packages"]); st["packages"] = [p for p in st["packages"] if str(p["id"]) != r[1]]
        if len(st["packages"]) < n: code, body = 204, None
    elif r[0] == "packages" and len(r) == 4 and r[2] == "package_files" and method == "DELETE":
        for p in st["packages"]:
            if str(p["id"]) == r[1]:
                n = len(p["files"]); p["files"] = [f for f in p["files"] if str(f["id"]) != r[3]]
                if len(p["files"]) < n: code, body = 204, None
    elif r[:2] == ["packages", "generic"] and method == "PUT" and len(r) == 5:
        name, ver, fn = r[2], r[3], r[4]
        if fn in st.get("fail_upload", []):
            code, body = 500, {"message": "boom"}
        else:
            content = open(upload, "rb").read()
            sha = hashlib.sha256(content).hexdigest()
            if fn in st.get("corrupt_sha", []): sha = "0" * 64
            p = [p for p in st["packages"] if p["name"] == name and p["version"] == ver]
            if not p:
                p = {"id": nid(), "name": name, "version": ver, "package_type": "generic",
                     "created_at": "2026-10-13T%02d:00:00Z" % (len(st["packages"]) % 24), "files": []}
                st["packages"].append(p)
            else:
                p = p[0]
            f = {"id": nid(), "file_name": fn, "file_sha256": sha, "size": len(content)}
            p["files"].append(f)
            code, body = 201, f
    elif r == ["releases"] and method == "GET":
        code, body = 200, page([{"tag_name": t, "name": v["name"], "assets": {"links": v["links"]}} for t, v in rel.items()])
    elif r == ["releases"] and method == "POST":
        d = json.load(open(data[1:]))
        if d["tag_name"] not in st["tags"]: code, body = 422, {"message": "tag missing"}
        elif d["tag_name"] in rel: code, body = 409, {"message": "exists"}
        else:
            rel[d["tag_name"]] = {"name": d.get("name"), "description": d.get("description"), "links": []}
            code, body = 201, {"tag_name": d["tag_name"]}
    elif r[0] == "releases" and len(r) == 2 and r[1] in rel:
        if method == "GET":
            v = rel[r[1]]; code, body = 200, {"tag_name": r[1], "name": v["name"], "description": v["description"], "assets": {"links": v["links"]}}
        elif method == "PUT":
            d = json.load(open(data[1:])); rel[r[1]]["name"] = d.get("name")
            if "description" in d: rel[r[1]]["description"] = d["description"]
            code, body = 200, {"tag_name": r[1]}
    elif r[0] == "releases" and len(r) >= 4 and r[1] in rel and r[2:4] == ["assets", "links"]:
        links = rel[r[1]]["links"]
        if len(r) == 4 and method == "POST":
            d = json.load(open(data[1:]))
            if any(l["name"] == d["name"] for l in links): code, body = 400, {"message": "name taken"}
            else:
                d["id"] = nid(); links.append(d); code, body = 201, d
        elif len(r) == 5 and method in ("PUT", "DELETE"):
            m = [l for l in links if str(l["id"]) == r[4]]
            if m:
                if method == "PUT": m[0].update(json.load(open(data[1:])))
                else: links.remove(m[0])
                code, body = 200, m[0]
json.dump(st, open(os.environ["MOCK_STATE"], "w"))
if out:
    with open(out, "w") as fh:
        if body is not None: json.dump(body, fh)
if "%{http_code}" in wfmt:
    sys.stdout.write(wfmt.replace("%{http_code}", str(code)))
sys.exit(0)
PY
chmod +x "$T/bin/curl"
export PATH="$T/bin:$PATH"

# ---- fixtures -----------------------------------------------------------------
sha() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1 || shasum -a 256 "$1" | cut -d' ' -f1; }
mkparts() { # $1 dir $2 arch: (re)write PARTS-<arch>.sha256 from the parts present
  ( cd "$1/$2" && for p in ncz-os-"$2"-*.part-*; do printf '%s  %s\n' "$(sha "$p")" "$p"; done > "PARTS-$2.sha256" )
}
mkrel() { # $1 dir: amd64 (2 parts) + arm64 (1 part) + common files
  local d=$1; mkdir -p "$d/amd64" "$d/arm64"
  head -c 3000 /dev/urandom > "$d/amd64/ncz-os-amd64-20261013-abcdef12.img.zst.part-00"
  head -c 1000 /dev/urandom > "$d/amd64/ncz-os-amd64-20261013-abcdef12.img.zst.part-01"
  head -c 2000 /dev/urandom > "$d/arm64/ncz-os-arm64-20261013-abcdef12.img.zst.part-00"
  mkparts "$d" amd64; mkparts "$d" arm64
  printf '%s  %s\n' "$(printf a | sha256sum | cut -d' ' -f1)" ncz-os-amd64-20261013-abcdef12.img > "$d/amd64/SHA256SUMS-amd64"
  printf '%s  %s\n' "$(printf b | sha256sum | cut -d' ' -f1)" ncz-os-arm64-20261013-abcdef12.img > "$d/arm64/SHA256SUMS-arm64"
  cat "$d/amd64/SHA256SUMS-amd64" "$d/arm64/SHA256SUMS-arm64" > "$d/SHA256SUMS"
  cp "$ROOT/tools/ncz-join-image.sh" "$d/"
}
reset_state() {
  cat > "$MOCK_STATE" <<EOF
{"next_id": 1000, "project": {"id": 4242, "path": "ncz-os/cix-installer"},
 "tags": ["v26.10-test", "v26.09-old", "v26.08-older"],
 "packages": [{"id": 7, "name": "linux-source-cix-sky1-ncz", "version": "7.0.12", "package_type": "generic", "created_at": "2026-07-26T16:02:50Z", "files": []}],
 "releases": {}}
EOF
  : > "$MOCK_LOG"; : > "$MOCK_ARGV"
}
st() { jq -r "$1" "$MOCK_STATE"; }
mutations() { grep -cE '^(PUT|POST|DELETE) ' "$MOCK_LOG" || true; }
REL="$T/rel"; mkrel "$REL"
NLINKS=9      # 4 amd64 + 3 arm64 + ncz-join-image.sh + SHA256SUMS
NUPLOADS=11   # the links' files + a join script copy in each architecture package
PK='.packages[] | select(.name != "linux-source-cix-sky1-ncz")'
LINKS='.releases["v26.10-test"].links'

# 1. dry run: reads only, plans every upload, release and link
reset_state
out=$(bash "$TOOL" --dir "$REL" --tag v26.10-test --dry-run 2>&1); rc=$?
check "dry run exits 0" '[ "$rc" -eq 0 ]' || echo "$out"
check "dry run makes no PUT/POST/DELETE" '[ "$(mutations)" -eq 0 ]'
check "dry run plans one upload per package file" '[ "$(grep -c "\[dry-run\] upload" <<<"$out")" -eq $NUPLOADS ]'
check "dry run plans the release" 'grep -q "\[dry-run\] POST .*/releases$" <<<"$out"'
check "dry run says nothing changed" 'grep -q "Dry run: nothing was changed" <<<"$out"'

# 2. dry run without a token: no API calls at all
reset_state
out=$(TEST_TOKEN="" bash "$TOOL" --dir "$REL" --tag v26.10-test --dry-run 2>&1); rc=$?
check "token-less dry run exits 0" '[ "$rc" -eq 0 ]'
check "token-less dry run calls nothing" '[ ! -s "$MOCK_LOG" ]'

# 3. real run without a token refuses
reset_state
TEST_TOKEN="" bash "$TOOL" --dir "$REL" --tag v26.10-test >/dev/null 2>&1; rc=$?
check "real run without token exits 2" '[ "$rc" -eq 2 ]'
check "real run without token calls nothing" '[ ! -s "$MOCK_LOG" ]'

# 4. publish: one package per architecture + common, release, links in folders
reset_state
out=$(bash "$TOOL" --dir "$REL" --tag v26.10-test --name "NCZ-OS test" 2>&1); rc=$?
check "publish exits 0" '[ "$rc" -eq 0 ]' || echo "$out"
check "publish uploads every package file once" '[ "$(grep -c "^PUT .*/packages/generic/ncz-os-image-" "$MOCK_LOG")" -eq $NUPLOADS ]'
check "three packages: amd64, arm64, common" '[ "$(st "[$PK | .name] | sort | join(\",\")")" = "ncz-os-image-amd64,ncz-os-image-arm64,ncz-os-image-common" ]'
check "amd64 package holds its files and the join script" '[ "$(st "[$PK | select(.name==\"ncz-os-image-amd64\") | .files[].file_name] | sort | join(\" \")")" = "PARTS-amd64.sha256 SHA256SUMS-amd64 ncz-join-image.sh ncz-os-amd64-20261013-abcdef12.img.zst.part-00 ncz-os-amd64-20261013-abcdef12.img.zst.part-01" ]'
check "registry sha256 equals the local file" '[ "$(st "[$PK | .files[] | select(.file_name==\"PARTS-arm64.sha256\")][0].file_sha256")" = "$(sha "$REL/arm64/PARTS-arm64.sha256")" ]'
check "release created with title" '[ "$(st ".releases[\"v26.10-test\"].name")" = "NCZ-OS test" ]'
check "one link per file" '[ "$(st "$LINKS | length")" -eq $NLINKS ]'
check "links in canonical order with folder names" '[ "$(st "[$LINKS[].name] | join(\" \")")" = "amd64/ncz-os-amd64-20261013-abcdef12.img.zst.part-00 amd64/ncz-os-amd64-20261013-abcdef12.img.zst.part-01 amd64/PARTS-amd64.sha256 amd64/SHA256SUMS-amd64 arm64/ncz-os-arm64-20261013-abcdef12.img.zst.part-00 arm64/PARTS-arm64.sha256 arm64/SHA256SUMS-arm64 ncz-join-image.sh SHA256SUMS" ]'
check "part link points at the arm64 package file" '[ "$(st "$LINKS[] | select(.name==\"arm64/ncz-os-arm64-20261013-abcdef12.img.zst.part-00\") | .url")" = "$NCZ_GITLAB_API/projects/4242/packages/generic/ncz-os-image-arm64/26.10-test/ncz-os-arm64-20261013-abcdef12.img.zst.part-00" ]'
check "part link: package type, stable folder path" '[ "$(st "$LINKS[] | select(.name==\"amd64/ncz-os-amd64-20261013-abcdef12.img.zst.part-01\") | \"\(.link_type) \(.direct_asset_path)\"")" = "package /amd64/ncz-os-amd64.img.zst.part-01" ]'
check "arch checksum link: package type, folder path" '[ "$(st "$LINKS[] | select(.name==\"amd64/PARTS-amd64.sha256\") | \"\(.link_type) \(.direct_asset_path)\"")" = "package /amd64/PARTS-amd64.sha256" ]'
check "common file: other type, top-level path, common package" '[ "$(st "$LINKS[] | select(.name==\"SHA256SUMS\") | \"\(.link_type) \(.direct_asset_path) \(.url | test(\"/ncz-os-image-common/\"))\"")" = "other /SHA256SUMS true" ]'
check "token never in curl argv" '! grep -qF "$TOKEN_VALUE" "$MOCK_ARGV"'
check "token never in output" '! grep -qF "$TOKEN_VALUE" <<<"$out"'
check "every request authenticated via stdin config" '! grep -q "auth=no" "$MOCK_LOG"'

# 5. re-run is idempotent: nothing re-uploaded, no new links
: > "$MOCK_LOG"
out=$(bash "$TOOL" --dir "$REL" --tag v26.10-test --name "NCZ-OS test" 2>&1); rc=$?
check "re-run exits 0" '[ "$rc" -eq 0 ]'
check "re-run uploads nothing" '! grep -q "^PUT .*/packages/generic/" "$MOCK_LOG"'
check "re-run adds no link" '! grep -q "^POST .*/assets/links" "$MOCK_LOG"'
check "re-run updates the existing release, does not create" '! grep -qE "^POST .*/releases " "$MOCK_LOG" && grep -qE "^PUT .*/releases/v26.10-test " "$MOCK_LOG"'
check "re-run reports files present" '[ "$(grep -c "  present  " <<<"$out")" -eq $NUPLOADS ]'

# 6. a changed part is re-uploaded and the older copy removed
echo extra >> "$REL/arm64/ncz-os-arm64-20261013-abcdef12.img.zst.part-00"; mkparts "$REL" arm64
: > "$MOCK_LOG"
bash "$TOOL" --dir "$REL" --tag v26.10-test >/dev/null 2>&1; rc=$?
check "changed part run exits 0" '[ "$rc" -eq 0 ]'
check "changed part and PARTS-arm64.sha256 re-uploaded only" '[ "$(grep -c "^PUT .*/packages/generic/" "$MOCK_LOG")" -eq 2 ]'
check "one copy per file name remains in each package" '[ "$(st "[$PK | ([.files[].file_name] | (length == (unique|length)))] | all")" = true ]'
check "remaining copy is the new one" '[ "$(st "$PK | .files[] | select(.file_name==\"ncz-os-arm64-20261013-abcdef12.img.zst.part-00\") | .file_sha256")" = "$(sha "$REL/arm64/ncz-os-arm64-20261013-abcdef12.img.zst.part-00")" ]'

# 7. registry reports a different sha256: fail, no release
reset_state
jq '.corrupt_sha=["ncz-os-amd64-20261013-abcdef12.img.zst.part-01"]' "$MOCK_STATE" > "$MOCK_STATE.n" && mv "$MOCK_STATE.n" "$MOCK_STATE"
out=$(bash "$TOOL" --dir "$REL" --tag v26.10-test 2>&1); rc=$?
check "sha mismatch from registry exits non-zero" '[ "$rc" -ne 0 ]'
check "sha mismatch retried 3 times" '[ "$(grep -c "^PUT .*part-01?select" "$MOCK_LOG")" -eq 3 ]'
check "sha mismatch creates no release" '[ "$(st ".releases | length")" -eq 0 ]'

# 8. upload error: fail, no release
reset_state
jq '.fail_upload=["SHA256SUMS"]' "$MOCK_STATE" > "$MOCK_STATE.n" && mv "$MOCK_STATE.n" "$MOCK_STATE"
bash "$TOOL" --dir "$REL" --tag v26.10-test >/dev/null 2>&1; rc=$?
check "HTTP error on upload exits non-zero" '[ "$rc" -ne 0 ]'
check "HTTP error creates no release" '[ "$(st ".releases | length")" -eq 0 ]'

# 9. layout errors stop before any request
layout_case() { # name expected-message setup...
  local name=$1 msg=$2; shift 2
  local D="$T/bad-$name"; rm -rf "$D"; mkrel "$D"; ( cd "$D" && eval "$*" )
  reset_state
  out=$(bash "$TOOL" --dir "$D" --tag v26.10-test 2>&1); rc=$?
  check "layout $name exits 2 with no request" '[ "$rc" -eq 2 ] && [ ! -s "$MOCK_LOG" ]' || echo "$out"
  check "layout $name names the problem" 'grep -qF -- "$msg" <<<"$out"' || echo "$out"
}
layout_case badpart "checksum mismatch for amd64/ncz-os-amd64-20261013-abcdef12.img.zst.part-00" 'echo x >> amd64/ncz-os-amd64-20261013-abcdef12.img.zst.part-00'
layout_case unlisted "arm64/ncz-os-arm64-20261013-abcdef12.img.zst.part-01 is not listed in arm64/PARTS-arm64.sha256" 'head -c 10 /dev/urandom > arm64/ncz-os-arm64-20261013-abcdef12.img.zst.part-01'
layout_case nojoin "ncz-join-image.sh not found" 'rm ncz-join-image.sh'
layout_case nosums "amd64/SHA256SUMS-amd64 not found" 'rm amd64/SHA256SUMS-amd64'
layout_case combined "SHA256SUMS is not SHA256SUMS-amd64 followed by SHA256SUMS-arm64" 'cat arm64/SHA256SUMS-arm64 amd64/SHA256SUMS-amd64 > SHA256SUMS'
layout_case toplevel "part outside an architecture folder" 'cp amd64/ncz-os-amd64-20261013-abcdef12.img.zst.part-00 .'
layout_case wrongarch "which is not an arm64 image part" 'mv amd64/ncz-os-amd64-20261013-abcdef12.img.zst.part-01 arm64/ && cat amd64/PARTS-amd64.sha256 >> arm64/PARTS-arm64.sha256 && sed -i "/part-01/d" amd64/PARTS-amd64.sha256'
layout_case noarch "no architecture folder" 'rm -rf amd64 arm64'

# 10. a single architecture is a valid release
ONE="$T/one"; mkrel "$ONE"; rm -rf "$ONE/arm64"; cp "$ONE/amd64/SHA256SUMS-amd64" "$ONE/SHA256SUMS"
reset_state
bash "$TOOL" --dir "$ONE" --tag v26.10-test >/dev/null 2>&1; rc=$?
check "amd64-only release exits 0" '[ "$rc" -eq 0 ]'
check "amd64-only release has no arm64 package or links" '[ "$(st "[$PK | .name] | sort | join(\",\")")" = "ncz-os-image-amd64,ncz-os-image-common" ] && ! st "$LINKS[].name" | grep >/dev/null "^arm64/"'

# 11. tag that does not exist: no upload, no release (the tool never creates tags)
reset_state
out=$(bash "$TOOL" --dir "$REL" --tag v99-none 2>&1); rc=$?
check "missing tag exits 2" '[ "$rc" -eq 2 ]'
check "missing tag makes no change" '[ "$(mutations)" -eq 0 ]'
check "missing tag message is clean" '[ "$(tail -1 <<<"$out")" = "ERROR: tag v99-none does not exist in ncz-os/cix-installer (HTTP 404); create and push the tag first" ]'

# 12. file over the size limit is refused before any request
reset_state
NCZ_GITLAB_MAX_FILE_BYTES=1500 bash "$TOOL" --dir "$REL" --tag v26.10-test >/dev/null 2>&1; rc=$?
check "oversize file exits 2" '[ "$rc" -eq 2 ]'
check "oversize file makes no request" '[ ! -s "$MOCK_LOG" ]'

# 13. token helper (GIT_ASKPASS style)
reset_state
printf '#!/bin/sh\necho "%s"\n' "$TOKEN_VALUE" > "$T/bin/tokhelper"; chmod +x "$T/bin/tokhelper"
NCZ_GITLAB_TOKEN_VAR=UNSET_VAR NCZ_GITLAB_TOKEN_HELPER="$T/bin/tokhelper" bash "$TOOL" --dir "$REL" --tag v26.10-test >/dev/null 2>&1; rc=$?
check "token helper run exits 0" '[ "$rc" -eq 0 ]'
check "token helper authenticates" '! grep -q "auth=no" "$MOCK_LOG"'

# 14. a link that is not in the staged set is removed from the release
reset_state
bash "$TOOL" --dir "$REL" --tag v26.10-test >/dev/null 2>&1
jq '.releases["v26.10-test"].links += [{"id": 1, "name": "PARTS.sha256", "url": "x", "direct_asset_path": "/PARTS.sha256", "link_type": "other"}]' "$MOCK_STATE" > "$MOCK_STATE.n" && mv "$MOCK_STATE.n" "$MOCK_STATE"
out=$(bash "$TOOL" --dir "$REL" --tag v26.10-test 2>&1); rc=$?
check "stale link run exits 0" '[ "$rc" -eq 0 ]'
check "stale link removed" '[ "$(st "$LINKS | length")" -eq $NLINKS ] && grep -q "link removed PARTS.sha256" <<<"$out"'

# 15. retention per package: keep newest N of each, drop the old single package, never touch others
reset_state
jq '.packages += [{"id": 8, "name": "ncz-os-image", "version": "26.09-single", "package_type": "generic", "created_at": "2026-09-01T00:00:00Z", "files": []}]' "$MOCK_STATE" > "$MOCK_STATE.n" && mv "$MOCK_STATE.n" "$MOCK_STATE"
O1="$T/old1"; O2="$T/old2"; mkrel "$O1"; mkrel "$O2"
bash "$TOOL" --dir "$O2" --tag v26.08-older >/dev/null 2>&1
bash "$TOOL" --dir "$O1" --tag v26.09-old >/dev/null 2>&1
check "two older releases staged as three packages each" '[ "$(st "[$PK | select(.name != \"ncz-os-image\")] | length")" -eq 6 ]'
: > "$MOCK_LOG"
out=$(bash "$TOOL" --dir "$REL" --tag v26.10-test --prune-old --dry-run 2>&1); rc=$?
check "prune dry run exits 0 and changes nothing" '[ "$rc" -eq 0 ] && [ "$(mutations)" -eq 0 ]'
out=$(bash "$TOOL" --dir "$REL" --tag v26.10-test --prune-old --keep 2 2>&1); rc=$?
check "prune keep 2 exits 0" '[ "$rc" -eq 0 ]' || echo "$out"
check "keep 2 leaves two versions of each package" '[ "$(st "[$PK | \"\(.name)=\(.version)\"] | sort | join(\",\")")" = "ncz-os-image-amd64=26.09-old,ncz-os-image-amd64=26.10-test,ncz-os-image-arm64=26.09-old,ncz-os-image-arm64=26.10-test,ncz-os-image-common=26.09-old,ncz-os-image-common=26.10-test" ]'
check "old single package removed" '[ "$(st "[.packages[] | select(.name==\"ncz-os-image\")] | length")" -eq 0 ]'
check "keep 2 removed the oldest release links" '[ "$(st ".releases[\"v26.08-older\"].links | length")" -eq 0 ]'
check "keep 2 kept the middle release links" '[ "$(st ".releases[\"v26.09-old\"].links | length")" -eq $NLINKS ]'
out=$(bash "$TOOL" --dir "$REL" --tag v26.10-test --prune-old 2>&1); rc=$?
check "prune default keep 1 exits 0" '[ "$rc" -eq 0 ]'
check "keep 1 leaves only the published version" '[ "$(st "[$PK | .version] | unique | join(\",\")")" = "26.10-test" ]'
check "keep 1 leaves current release links" '[ "$(st "$LINKS | length")" -eq $NLINKS ]'
check "kernel source package never touched" '[ "$(st "[.packages[] | select(.name==\"linux-source-cix-sky1-ncz\")] | length")" -eq 1 ]'
check "older releases themselves are kept" '[ "$(st ".releases | length")" -eq 3 ]'

# 16. usage errors
bash "$TOOL" --tag x >/dev/null 2>&1; rc=$?; check "missing --dir exits 2" '[ "$rc" -eq 2 ]'
bash "$TOOL" --dir "$REL" >/dev/null 2>&1; rc=$?; check "missing --tag exits 2" '[ "$rc" -eq 2 ]'
bash "$TOOL" --dir "$REL" --tag v26.10-test --keep 0 >/dev/null 2>&1; rc=$?; check "--keep 0 exits 2" '[ "$rc" -eq 2 ]'
bash "$TOOL" --dir "$REL" --tag 'bad tag' --version 'bad ver' --dry-run >/dev/null 2>&1; rc=$?; check "invalid version exits 2" '[ "$rc" -eq 2 ]'
bash "$TOOL" --help | grep >/dev/null -- "--prune-old"; rc=$?; check "--help documents --prune-old" '[ "$rc" -eq 0 ]'

echo "passed=$PASS failed=$FAILS"
[ "$FAILS" -eq 0 ]
