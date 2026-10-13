#!/bin/bash
# test-release-parity.sh -- regression tests for tools/check-release-parity.sh,
# tools/sync-release-pages.sh and tools/check-release-links.sh against a
# mocked curl (no network).
#
# The mock keeps a small GitHub (releases, assets, tags, latest, uploads,
# downloads, raw files) and GitLab (project, tags, generic packages,
# releases, links, permalink/latest, release downloads, raw files) in a JSON
# state file and logs every request, so the tests can check which calls a
# run makes. Covered: a gated sync publishes both pages, retires every other
# release (tags kept) and ends at parity; a re-run uploads nothing; dry runs
# and refused runs change nothing; every kind of difference makes the parity
# check fail with a readable line; tokens never reach curl's argv or output.
#
# Run: bash build/test-release-parity.sh
# The checks are eval'd strings, expanded when they run:
# shellcheck disable=SC2016,SC2034
set -uo pipefail
# Needs bash >= 4 (associative arrays in the tools). Under an older bash
# (macOS /bin/bash 3.2) re-run with a newer one if installed, else SKIP.
if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
  for b in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    if [ -x "$b" ] && "$b" -c '[ "${BASH_VERSINFO[0]}" -ge 4 ]' 2>/dev/null; then exec "$b" "$0" "$@"; fi
  done
  echo "SKIP: bash >= 4 required (found ${BASH_VERSION:-unknown})"; exit 0
fi
# the tools are run as "bash TOOL": make that the same bash
PATH="$(dirname "$BASH"):$PATH"; export PATH
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CHECK="$ROOT/tools/check-release-parity.sh"
SYNC="$ROOT/tools/sync-release-pages.sh"
LINKS="$ROOT/tools/check-release-links.sh"
PASS=0; FAILS=0
ok()  { PASS=$((PASS+1)); echo "ok   $1"; }
bad() { FAILS=$((FAILS+1)); echo "FAIL $1${2:+: $2}"; }
check() { if eval "$2"; then ok "$1"; else bad "$1" "$2"; fi; }
# TEST_RELPARITY_KEEP=<dir> saves the tool output of each case there (evidence)
keep() { [ -z "${TEST_RELPARITY_KEEP:-}" ] || printf '%s\n' "$2" > "$TEST_RELPARITY_KEEP/$1.txt"; }

for t in jq python3; do command -v "$t" >/dev/null || { echo "SKIP: $t not installed"; exit 0; }; done
for f in "$CHECK" "$SYNC" "$LINKS" "$ROOT/tools/publish-release-gitlab.sh"; do
  [ -x "$f" ] || { echo "FATAL: $f missing or not executable" >&2; exit 2; }
done

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/blobs" "$T/rawroot"
export TMPDIR="$T"
GH_TOK="ghtok-$RANDOM-$RANDOM-not-real"; GL_TOK="gltok-$RANDOM-$RANDOM-not-real"
export TEST_GH_TOKEN="$GH_TOK" TEST_GL_TOKEN="$GL_TOK"
export NCZ_GITHUB_TOKEN_VAR=TEST_GH_TOKEN NCZ_GITLAB_TOKEN_VAR=TEST_GL_TOKEN
unset NCZ_GITHUB_TOKEN_HELPER NCZ_GITLAB_TOKEN_HELPER NCZ_RELEASE_APPROVAL_FILE NCZ_RELEASE_AUDIT_FILE
export NCZ_GITHUB_API="https://api.github.test" NCZ_GITHUB_UPLOADS="https://uploads.github.test"
export NCZ_GITHUB_WEB="https://github.test" NCZ_GITHUB_RAW="https://raw.github.test"
export NCZ_GITLAB_API="https://gitlab.test/api/v4" NCZ_GITLAB_WEB="https://gitlab.test"
export MOCK_STATE="$T/state.json" MOCK_LOG="$T/calls.log" MOCK_ARGV="$T/argv.log" MOCK_BLOBS="$T/blobs" MOCK_RAW="$T/rawroot"

# ---- mock curl ----------------------------------------------------------------
cat > "$T/bin/curl" <<'PY'
#!/usr/bin/env python3
import hashlib, json, os, re, shutil, sys, urllib.parse as up
argv = sys.argv[1:]
with open(os.environ["MOCK_ARGV"], "a") as fh:
    fh.write(json.dumps(argv) + "\n")
method, out, wfmt, data, upload, url, cfg, follow = None, None, "", None, None, None, None, False
i = 0
while i < len(argv):
    a = argv[i]
    if a == "-X": method = argv[i+1]; i += 2; continue
    if a == "-o": out = argv[i+1]; i += 2; continue
    if a == "-w": wfmt = argv[i+1]; i += 2; continue
    if a == "-H": i += 2; continue
    if a == "-K": cfg = argv[i+1]; i += 2; continue
    if a == "--data-binary": data = argv[i+1]; i += 2; continue
    if a == "-T": upload = argv[i+1]; i += 2; continue
    if a == "-L": follow = True; i += 1; continue
    if a.startswith("-"): i += 1; continue
    url = a; i += 1
method = method or ("PUT" if upload and not method else "GET")
headers = sys.stdin.read() if cfg == "-" else ""
st = json.load(open(os.environ["MOCK_STATE"]))
gh_auth = ("Authorization: Bearer %s" % os.environ.get("TEST_GH_TOKEN", "")) in headers and bool(os.environ.get("TEST_GH_TOKEN"))
gl_auth = ("PRIVATE-TOKEN: %s" % os.environ.get("TEST_GL_TOKEN", "")) in headers and bool(os.environ.get("TEST_GL_TOKEN"))
BL = os.environ["MOCK_BLOBS"]
def nid():
    st["next_id"] += 1; return st["next_id"]
def store(path):
    b = open(path, "rb").read(); s = hashlib.sha256(b).hexdigest()
    open(os.path.join(BL, s), "wb").write(b); return s, len(b)
GH, GL = st["gh"], st["gl"]
REPO, PROJ, PID = GH["repo"], GL["project"]["path"], GL["project"]["id"]

def gh_rel_view(r):
    return {k: r[k] for k in ("id", "tag_name", "name", "body", "draft", "prerelease", "created_at")} | {
        "assets": [{"id": a["id"], "name": a["name"], "size": a["size"], "digest": a.get("digest"),
                    "browser_download_url": "https://github.test/%s/releases/download/%s/%s" % (REPO, r["tag_name"], a["name"])}
                   for a in sorted(r["assets"], key=lambda a: a["id"])]}
def gh_latest():
    c = [r for r in GH["releases"] if not r["draft"] and not r["prerelease"]]
    m = [r for r in c if r["id"] == GH.get("latest_id")]
    if m: return m[0]
    return max(c, key=lambda r: r["id"]) if c else None
def gl_rel_view(t, v):
    return {"tag_name": t, "name": v["name"], "description": v.get("description"), "released_at": v["released_at"],
            "upcoming_release": v.get("upcoming", False), "assets": {"links": v["links"]}}
def gl_latest():
    c = [(v["released_at"], t) for t, v in GL["releases"].items() if not v.get("upcoming")]
    return max(c)[1] if c else None
def page(items, q):
    pp = int(q.get("per_page", 30)); pg = int(q.get("page", 1))
    return items[(pg-1)*pp: pg*pp]
def blob(sha):
    p = os.path.join(BL, sha); return p if os.path.exists(p) else None

def handle(method, url):
    """-> code, body(json|None), file-to-serve|None, location"""
    pu = up.urlsplit(url); host = pu.netloc; path = pu.path; q = dict(up.parse_qsl(pu.query))
    parts = [up.unquote(p) for p in path.strip("/").split("/")]
    log(method, url)
    # ---- GitHub API
    if host == "api.github.test":
        if method != "GET" and not gh_auth: return 401, {"message": "Requires authentication"}, None, ""
        if parts[:3] != ["repos"] + REPO.split("/"): return 404, {"message": "Not Found"}, None, ""
        r = parts[3:]
        if r == ["releases"] and method == "GET":
            rels = [gh_rel_view(x) for x in sorted(GH["releases"], key=lambda x: -x["id"]) if gh_auth or not x["draft"]]
            return 200, page(rels, q), None, ""
        if r == ["releases", "latest"] and method == "GET":
            l = gh_latest(); return (200, gh_rel_view(l), None, "") if l else (404, {"message": "Not Found"}, None, "")
        if r[:3] == ["git", "ref", "tags"] and method == "GET":
            t = "/".join(r[3:])
            return (200, {"ref": "refs/tags/" + t, "object": {"sha": "f" * 40}}, None, "") if t in GH["tags"] else (404, {"message": "Not Found"}, None, "")
        if r == ["releases"] and method == "POST":
            d = json.load(open(data[1:]))
            if d["tag_name"] not in GH["tags"]:
                GH["tags"].append(d["tag_name"]); GH.setdefault("tags_created", []).append(d["tag_name"])
            if any(x["tag_name"] == d["tag_name"] for x in GH["releases"]): return 422, {"message": "already_exists"}, None, ""
            rel = {"id": nid(), "tag_name": d["tag_name"], "name": d.get("name"), "body": d.get("body", ""),
                   "draft": d.get("draft", False), "prerelease": d.get("prerelease", False),
                   "created_at": "2026-10-14T00:00:%02dZ" % (st["next_id"] % 60), "assets": []}
            GH["releases"].append(rel)
            if d.get("make_latest") == "true": GH["latest_id"] = rel["id"]
            return 201, gh_rel_view(rel), None, ""
        if len(r) == 2 and r[0] == "releases" and r[1].isdigit():
            m = [x for x in GH["releases"] if x["id"] == int(r[1])]
            if not m: return 404, {"message": "Not Found"}, None, ""
            if method == "PATCH":
                d = json.load(open(data[1:]))
                for k in ("name", "body", "draft", "prerelease"):
                    if k in d: m[0][k] = d[k]
                if d.get("make_latest") == "true": GH["latest_id"] = m[0]["id"]
                return 200, gh_rel_view(m[0]), None, ""
            if method == "DELETE":
                GH["releases"].remove(m[0]); return 204, None, None, ""
            if method == "GET": return 200, gh_rel_view(m[0]), None, ""
        if len(r) == 3 and r[0] == "releases" and r[2] == "assets" and method == "GET":
            m = [x for x in GH["releases"] if x["id"] == int(r[1])]
            return (200, page(gh_rel_view(m[0])["assets"], q), None, "") if m else (404, {"message": "Not Found"}, None, "")
        if len(r) == 3 and r[:2] == ["releases", "assets"] and method == "DELETE":
            for x in GH["releases"]:
                for a in x["assets"]:
                    if a["id"] == int(r[2]): x["assets"].remove(a); return 204, None, None, ""
            return 404, {"message": "Not Found"}, None, ""
        return 404, {"message": "Not Found"}, None, ""
    if host == "uploads.github.test":
        if not gh_auth: return 401, {"message": "Requires authentication"}, None, ""
        r = parts[3:]
        m = [x for x in GH["releases"] if len(r) == 3 and x["id"] == int(r[1])]
        if not m or method != "POST": return 404, {"message": "Not Found"}, None, ""
        name = q["name"]
        if any(a["name"] == name for a in m[0]["assets"]): return 422, {"message": "already_exists"}, None, ""
        if name in GH.get("fail_upload", []): return 500, {"message": "boom"}, None, ""
        s, n = store(upload)
        dg = "sha256:" + ("0" * 64 if name in GH.get("corrupt_upload", []) else s)
        a = {"id": nid(), "name": name, "size": n, "digest": dg, "sha": s}
        m[0]["assets"].append(a)
        return 201, {"id": a["id"], "name": name, "size": n, "digest": dg}, None, ""
    if host == "github.test":
        r = parts[2:]
        if r[:2] == ["releases", "download"] and len(r) == 4:
            for x in GH["releases"]:
                if x["tag_name"] == r[2]:
                    for a in x["assets"]:
                        if a["name"] == r[3]:
                            return 200, None, blob(a.get("serve", a["sha"])), ""
        return 404, None, None, ""
    if host == "raw.github.test":
        if parts[:3] == REPO.split("/") + ["main"]:
            return raw("/".join(parts[3:]), "gh")
        return 404, None, None, ""
    # ---- GitLab
    if host == "gitlab.test" and path.startswith("/api/v4/"):
        if method != "GET" and not gl_auth: return 401, {"message": "401 Unauthorized"}, None, ""
        p = parts[2:]
        if p[0] == "projects" and len(p) == 2 and method == "GET":
            return (200, GL["project"], None, "") if p[1] in (PROJ, str(PID)) else (404, {"message": "404"}, None, "")
        if p[0] != "projects" or p[1] != str(PID): return 404, {"message": "404"}, None, ""
        r = p[2:]
        rel = GL["releases"]
        if r[:2] == ["repository", "tags"] and method == "GET":
            t = "/".join(r[2:])
            return (200, {"name": t, "commit": {"id": "e" * 40}}, None, "") if t in GL["tags"] else (404, {"message": "404 Tag Not Found"}, None, "")
        if r == ["packages"] and method == "GET":
            items = [x for x in GL["packages"] if x["name"] == q.get("package_name", x["name"])]
            return 200, page([{k: v for k, v in x.items() if k != "files"} for x in items], q), None, ""
        if r[0] == "packages" and len(r) == 3 and r[2] == "package_files" and method == "GET":
            m = [x for x in GL["packages"] if str(x["id"]) == r[1]]
            return (200, page([{k: v for k, v in f.items() if k != "serve"} for f in m[0]["files"]], q), None, "") if m else (404, {"message": "404"}, None, "")
        if r[0] == "packages" and len(r) == 2 and method == "DELETE":
            n = len(GL["packages"]); GL["packages"] = [x for x in GL["packages"] if str(x["id"]) != r[1]]
            return (204, None, None, "") if len(GL["packages"]) < n else (404, {"message": "404"}, None, "")
        if r[0] == "packages" and len(r) == 4 and r[2] == "package_files" and method == "DELETE":
            for x in GL["packages"]:
                if str(x["id"]) == r[1]:
                    x["files"] = [f for f in x["files"] if str(f["id"]) != r[3]]
            return 204, None, None, ""
        if r[:2] == ["packages", "generic"] and len(r) == 5:
            name, ver, fn = r[2], r[3], r[4]
            if method == "PUT":
                s, n = store(upload)
                m = [x for x in GL["packages"] if x["name"] == name and x["version"] == ver]
                if not m:
                    m = [{"id": nid(), "name": name, "version": ver, "package_type": "generic",
                          "created_at": "2026-10-14T%02d:00:00Z" % (len(GL["packages"]) % 24), "files": []}]
                    GL["packages"].append(m[0])
                f = {"id": nid(), "file_name": fn, "file_sha256": s, "size": n}
                m[0]["files"].append(f)
                return 201, f, None, ""
            if method == "GET":
                for x in GL["packages"]:
                    if x["name"] == name and x["version"] == ver:
                        fs = [f for f in x["files"] if f["file_name"] == fn]
                        if fs:
                            f = max(fs, key=lambda f: f["id"])
                            return 200, None, blob(f.get("serve", f["file_sha256"])), ""
                return 404, {"message": "404"}, None, ""
        if r == ["releases"] and method == "GET":
            items = sorted(rel.items(), key=lambda kv: kv[1]["released_at"], reverse=True)
            return 200, page([gl_rel_view(t, v) for t, v in items], q), None, ""
        if r == ["releases", "permalink", "latest"] and method == "GET":
            t = gl_latest()
            if not t: return 404, {"message": "404"}, None, ""
            return 302, None, None, "https://gitlab.test/api/v4/projects/%d/releases/%s" % (PID, up.quote(t, safe=""))
        if r == ["releases"] and method == "POST":
            d = json.load(open(data[1:]))
            if d["tag_name"] not in GL["tags"]: return 422, {"message": "tag missing"}, None, ""
            if d["tag_name"] in rel: return 409, {"message": "exists"}, None, ""
            rel[d["tag_name"]] = {"name": d.get("name"), "description": d.get("description"),
                                  "released_at": "2026-10-14T00:00:%02dZ" % (st["next_id"] % 60), "links": []}
            nid()
            return 201, {"tag_name": d["tag_name"]}, None, ""
        if r[0] == "releases" and len(r) == 2:
            if r[1] not in rel: return 404, {"message": "404"}, None, ""
            if method == "GET": return 200, gl_rel_view(r[1], rel[r[1]]), None, ""
            if method == "PUT":
                d = json.load(open(data[1:])); rel[r[1]]["name"] = d.get("name")
                if "description" in d: rel[r[1]]["description"] = d["description"]
                return 200, {"tag_name": r[1]}, None, ""
            if method == "DELETE":
                v = rel.pop(r[1]); return 200, gl_rel_view(r[1], v), None, ""
        if r[0] == "releases" and len(r) >= 4 and r[1] in rel and r[2:4] == ["assets", "links"]:
            links = rel[r[1]]["links"]
            if len(r) == 4 and method == "POST":
                d = json.load(open(data[1:]))
                if any(l["name"] == d["name"] for l in links): return 400, {"message": "name taken"}, None, ""
                d["id"] = nid(); links.append(d); return 201, d, None, ""
            if len(r) == 5:
                m = [l for l in links if str(l["id"]) == r[4]]
                if m and method == "PUT": m[0].update(json.load(open(data[1:]))); return 200, m[0], None, ""
                if m and method == "DELETE": links.remove(m[0]); return 200, m[0], None, ""
        return 404, {"message": "404"}, None, ""
    if host == "gitlab.test":
        pp = PROJ.split("/")
        if parts[:len(pp)] != pp: return 404, None, None, ""
        r = parts[len(pp):]
        if r[:3] == ["-", "raw", "main"]:
            return raw("/".join(r[3:]), "gl")
        if r[:2] == ["-", "releases"] and len(r) >= 5 and r[3] == "downloads":
            t = r[2]; dp = "/" + "/".join(r[4:])
            if t in GL["releases"]:
                for l in GL["releases"][t]["links"]:
                    if l.get("direct_asset_path") == dp: return 302, None, None, l["url"]
        return 404, None, None, ""
    return 404, None, None, ""

def raw(rel, forge):
    ov = st.get("raw_override", {}).get(forge + ":" + rel)
    if ov == "404": return 404, None, None, ""
    p = os.path.join(os.environ["MOCK_RAW"], rel)
    if ov == "corrupt":
        c = os.path.join(BL, "corrupt.bin"); open(c, "wb").write(b"not the file"); return 200, None, c, ""
    return (200, None, p, "") if os.path.isfile(p) else (404, None, None, "")

def log(m, u):
    a = "gh" if gh_auth else ("gl" if gl_auth else "anon")
    with open(os.environ["MOCK_LOG"], "a") as fh: fh.write("%s %s auth=%s\n" % (m, u, a))

code, body, serve, loc = handle(method, url)
hops = 0
while follow and code in (301, 302) and loc and hops < 5:
    gh_auth = gl_auth = False
    code, body, serve, loc = handle("GET", loc); hops += 1
json.dump(st, open(os.environ["MOCK_STATE"], "w"))
if out:
    if serve: shutil.copyfile(serve, out)
    else:
        with open(out, "w") as fh:
            if body is not None: json.dump(body, fh)
w = wfmt.replace("%{http_code}", str(code)).replace("%{redirect_url}", loc if code in (301, 302) else "")
sys.stdout.write(w)
sys.exit(0)
PY
chmod +x "$T/bin/curl"
export PATH="$T/bin:$PATH"

# ---- fixtures -------------------------------------------------------------------
if command -v sha256sum >/dev/null 2>&1; then sha() { sha256sum "$1" | cut -d' ' -f1; }; sha_str() { printf '%s' "$1" | sha256sum | cut -d' ' -f1; }
else sha() { shasum -a 256 "$1" | cut -d' ' -f1; }; sha_str() { printf '%s' "$1" | shasum -a 256 | cut -d' ' -f1; }; fi
sedi() { sed "$1" "$2" > "$2.sedi" && mv "$2.sedi" "$2"; }   # in-place sed on GNU and BSD
REPOROOT="$T/rawroot"   # what main holds on both forges, and the --repo-root
mkdir -p "$REPOROOT/docs/screenshots/26.10"
head -c 700 /dev/urandom > "$REPOROOT/docs/screenshots/26.10/01-desktop.png"
head -c 500 /dev/urandom > "$REPOROOT/docs/screenshots/26.10/02-lock.png"
TAG=v26.10-preview2
AMD=ncz-os-amd64-20261014-abcdef12; ARM=ncz-os-arm64-20261014-abcdef12
mkparts() { ( cd "$1/$2" && for p in ncz-os-"$2"-*.part-*; do printf '%s  %s\n' "$(sha "$p")" "$p"; done > "PARTS-$2.sha256" ); }
mkrel() { # $1 dir: amd64 (1 part) + arm64 (2 parts) + common files
  local d=$1; mkdir -p "$d/amd64" "$d/arm64"
  head -c 2000 /dev/urandom > "$d/amd64/$AMD.img.zst.part-00"
  head -c 3000 /dev/urandom > "$d/arm64/$ARM.img.zst.part-00"
  head -c 1000 /dev/urandom > "$d/arm64/$ARM.img.zst.part-01"
  mkparts "$d" amd64; mkparts "$d" arm64
  local ha hb; ha=$(sha_str b); hb=$(sha_str a)
  printf '%s  %s\n' "$ha" "$AMD.img" > "$d/amd64/SHA256SUMS-amd64"
  printf '%s  %s\n' "$hb" "$ARM.img" > "$d/arm64/SHA256SUMS-arm64"
  cat "$d/amd64/SHA256SUMS-amd64" "$d/arm64/SHA256SUMS-arm64" > "$d/SHA256SUMS"
  cp "$ROOT/tools/ncz-join-image.sh" "$d/"
  printf 'NCZ-OS 26.10 Cygnus — Preview 2\n' > "$d/TITLE"
  echo yes > "$d/PRERELEASE"   # a preview tag is a GitHub pre-release
  cat > "$d/NOTES.md" <<EOF
# NCZ-OS 26.10 "Cygnus" — Preview 2

**Status: preview.**

## Screenshots

![Desktop](https://gitlab.test/ncz-os/cix-installer/-/raw/main/docs/screenshots/26.10/01-desktop.png)
<img src="https://gitlab.test/ncz-os/cix-installer/-/raw/main/docs/screenshots/26.10/02-lock.png" alt="Lock" width="600">

## amd64: Intel/AMD PCs and Apple T2 Macs

| Image | sha256 of the .img |
|---|---|
| \`$AMD\` | \`$ha\` |

Download the amd64 files and run \`sh ncz-join-image.sh amd64\`.

## arm64: CIX Sky1

| Image | sha256 of the .img |
|---|---|
| \`$ARM\` | \`$hb\` |

Download the arm64 files and run \`sh ncz-join-image.sh arm64\`; the first part is
[arm64/ncz-os-arm64.img.zst.part-00](https://gitlab.test/ncz-os/cix-installer/-/releases/permalink/latest/downloads/arm64/ncz-os-arm64.img.zst.part-00),
its list [PARTS-arm64.sha256](https://gitlab.test/ncz-os/cix-installer/-/releases/permalink/latest/downloads/arm64/PARTS-arm64.sha256).

## Source

Download: [latest release](https://gitlab.test/ncz-os/cix-installer/-/releases/permalink/latest),
[SHA256SUMS](https://gitlab.test/ncz-os/cix-installer/-/releases/permalink/latest/downloads/SHA256SUMS).
Source: [$TAG](https://gitlab.test/ncz-os/cix-installer/-/tree/$TAG), see
[SOURCE-RELEASES.md](https://gitlab.test/ncz-os/cix-installer/-/blob/main/docs/SOURCE-RELEASES.md).
EOF
}
REL="$T/rel"; mkrel "$REL"
NFILES=10      # GitHub assets = GitLab links
NGLUPLOADS=12  # GitLab package files: the links' files + a join script copy per architecture package
CANON="$AMD.img.zst.part-00 PARTS-amd64.sha256 SHA256SUMS-amd64 $ARM.img.zst.part-00 $ARM.img.zst.part-01 PARTS-arm64.sha256 SHA256SUMS-arm64 ncz-join-image.sh SHA256SUMS NOTES.md"
reset_state() { # the situation before the cutover: Preview 1 on GitHub, old releases on both
  local pv1="$T/pv1"; mkdir -p "$pv1"; printf 'old sums\n' > "$pv1/SHA256SUMS"
  local s; s=$(sha "$pv1/SHA256SUMS"); cp "$pv1/SHA256SUMS" "$MOCK_BLOBS/$s"
  cat > "$MOCK_STATE" <<EOF
{"next_id": 5000,
 "gh": {"repo": "ncz-os/cix-installer", "tags": ["$TAG", "v26.10-preview1", "v2026.08.27-v14", "gitlab-canonical"],
        "releases": [
          {"id": 11, "tag_name": "gitlab-canonical", "name": "Releases are on GitLab", "body": "see GitLab", "draft": false, "prerelease": false, "created_at": "2026-07-23T05:11:55Z", "assets": []},
          {"id": 12, "tag_name": "v2026.08.27-v14", "name": "NCZ-OS 26.7", "body": "old", "draft": false, "prerelease": false, "created_at": "2026-08-27T23:18:14Z", "assets": []},
          {"id": 13, "tag_name": "v26.10-preview1", "name": "NCZ-OS 26.10 Cygnus — Preview 1", "body": "pv1", "draft": false, "prerelease": true, "created_at": "2026-08-27T23:40:38Z",
           "assets": [{"id": 131, "name": "SHA256SUMS", "size": 9, "digest": "sha256:$s", "sha": "$s"}]}]},
 "gl": {"project": {"id": 4242, "path": "ncz-os/cix-installer"}, "tags": ["$TAG", "v26.10-preview1", "v2026.08.27-v14", "v2026.08.18-v12"],
        "packages": [{"id": 77, "name": "linux-source-cix-sky1-ncz", "version": "7.0.12", "package_type": "generic", "created_at": "2026-07-26T16:02:50Z", "files": []}],
        "releases": {"v2026.08.27-v14": {"name": "NCZ-OS 26.7 v14", "description": "old", "released_at": "2026-08-27T23:16:31Z", "links": []},
                     "v2026.08.18-v12": {"name": "NCZ-OS 26.7 v12", "description": "older", "released_at": "2026-08-18T04:37:42Z", "links": []}}}}
EOF
  : > "$MOCK_LOG"; : > "$MOCK_ARGV"
}
st() { jq -r "$1" "$MOCK_STATE"; }
mutations() { grep -cE '^(PUT|POST|PATCH|DELETE) ' "$MOCK_LOG" || true; }
APPROVE="$T/approve"; printf 'approve %s\n' "$TAG" > "$APPROVE"
AUDIT="$T/audit"; awk '{print "PASS", $1, $2}' "$REL/SHA256SUMS" > "$AUDIT"
CK=(--repo-root "$REPOROOT")
gated=(--operator-approved "$APPROVE" --audit-ok "$AUDIT" --repo-root "$REPOROOT")

# Every forge in this file is the mock above: no request reaches a real forge
# (checked at the end), so no check depends on what GitHub or GitLab hold now.
# 1. parity check on a mocked pre-cutover state (Preview 1 on GitHub only,
#    older releases on both): fails and lists the extra releases
reset_state
out=$(bash "$CHECK" --tag v26.10-preview1 "${CK[@]}" 2>&1); rc=$?; keep check-today "$out"
check "today: parity fails" '[ "$rc" -eq 1 ]'
check "today: GitHub extras listed" 'grep -q "DIFF  github has another release: gitlab-canonical" <<<"$out" && grep -q "github has another release: v2026.08.27-v14" <<<"$out"'
check "today: GitLab extras listed" 'grep -q "DIFF  gitlab has another release: v2026.08.18-v12" <<<"$out"'
check "today: GitLab has no Preview 1" 'grep -q "DIFF  gitlab has no release for v26.10-preview1" <<<"$out"'
check "check makes no change" '[ "$(mutations)" -eq 0 ]'

# 2. sync dry run: changes nothing, plans every step and every retirement
reset_state
out=$(bash "$SYNC" --dir "$REL" --tag "$TAG" --repo-root "$REPOROOT" 2>&1); rc=$?; keep sync-dry-run "$out"
check "dry run exits 0" '[ "$rc" -eq 0 ]' || echo "$out"
check "dry run makes no PUT/POST/PATCH/DELETE" '[ "$(mutations)" -eq 0 ]'
check "dry run reports missing gates" 'grep -q "gate  operator approval: missing" <<<"$out" && grep -q "gate  image audit: missing" <<<"$out"'
check "dry run plans GitHub release" 'grep -q "create release $TAG" <<<"$out"'
check "dry run plans GitHub uploads" '[ "$(grep -c "\[dry-run\] upload .* bytes)$" <<<"$out")" -eq $NFILES ]'
check "dry run plans GitLab uploads" '[ "$(grep -c "\[dry-run\] upload .* -> " <<<"$out")" -eq $NGLUPLOADS ]'
check "dry run lists every release it would retire" 'grep -q "github: delete release gitlab-canonical" <<<"$out" && grep -q "github: delete release v26.10-preview1 .* 1 asset" <<<"$out" && grep -q "github: delete release v2026.08.27-v14" <<<"$out" && grep -q "gitlab: delete release v2026.08.18-v12" <<<"$out" && grep -q "gitlab: delete release v2026.08.27-v14" <<<"$out"'
check "dry run says nothing changed" 'grep -q "Dry run: nothing was changed" <<<"$out"'

# 3. apply without gates / with wrong gates: refused before any request that changes anything
reset_state
bash "$SYNC" --dir "$REL" --tag "$TAG" --apply --repo-root "$REPOROOT" >/dev/null 2>&1; rc=$?
check "apply without gates exits 2" '[ "$rc" -eq 2 ]'
check "apply without gates makes no request" '[ ! -s "$MOCK_LOG" ]'
printf 'approve v26.10-preview3\n' > "$T/wrong"
bash "$SYNC" --dir "$REL" --tag "$TAG" --apply --operator-approved "$T/wrong" --audit-ok "$AUDIT" --repo-root "$REPOROOT" >/dev/null 2>&1; rc=$?
check "approval for another tag is refused" '[ "$rc" -eq 2 ] && [ ! -s "$MOCK_LOG" ]'
head -1 "$AUDIT" > "$T/audit-half"
bash "$SYNC" --dir "$REL" --tag "$TAG" --apply --operator-approved "$APPROVE" --audit-ok "$T/audit-half" --repo-root "$REPOROOT" >/dev/null 2>&1; rc=$?
check "audit missing an image is refused" '[ "$rc" -eq 2 ] && [ ! -s "$MOCK_LOG" ]'
{ cat "$AUDIT"; echo "FAIL deadbeef something"; } > "$T/audit-fail"
bash "$SYNC" --dir "$REL" --tag "$TAG" --apply --operator-approved "$APPROVE" --audit-ok "$T/audit-fail" --repo-root "$REPOROOT" >/dev/null 2>&1; rc=$?
check "audit with a FAIL line is refused" '[ "$rc" -eq 2 ] && [ ! -s "$MOCK_LOG" ]'

# 4. input refusals: missing screenshot, release-specific link, relative image, prerelease, missing tag
for case in shot link relimg pre sections layout badpart; do
  D="$T/bad-$case"; rm -rf "$D"; cp -r "$REL" "$D"
  case $case in
    shot) sedi 's#01-desktop.png#09-missing.png#' "$D/NOTES.md" ;;
    link) echo "[old](https://github.test/ncz-os/cix-installer/releases/download/v26.10-preview1/SHA256SUMS)" >> "$D/NOTES.md" ;;
    relimg) echo "![x](../screenshots/26.10/01-desktop.png)" >> "$D/NOTES.md" ;;
    pre) echo no > "$D/PRERELEASE" ;;
    sections) sedi 's/^## arm64: CIX Sky1$/## Sky1/' "$D/NOTES.md" ;;
    layout) mv "$D/amd64/$AMD.img.zst.part-00" "$D/" ;;
    badpart) echo "[p](https://gitlab.test/ncz-os/cix-installer/-/releases/permalink/latest/downloads/arm64/ncz-os-arm64.img.zst.part-07)" >> "$D/NOTES.md" ;;
  esac
  reset_state
  out=$(bash "$SYNC" --dir "$D" --tag "$TAG" --apply "${gated[@]}" 2>&1); rc=$?
  if [ "$case" = badpart ]; then
    check "refused input ($case) exits 2 with no change" '[ "$rc" -eq 2 ] && [ "$(mutations)" -eq 0 ] && grep -q "ncz-os-arm64.img.zst.part-07" <<<"$out"' || echo "$out"
  else
    check "refused input ($case) exits 2 with no request" '[ "$rc" -eq 2 ] && [ ! -s "$MOCK_LOG" ]' || echo "$out"
  fi
done
# a tag that is not a preview tag needs --allow-prerelease to be a pre-release
reset_state
out=$(bash "$SYNC" --dir "$REL" --tag v26.10.0 --apply "${gated[@]}" 2>&1); rc=$?
check "pre-release of a non-preview tag refused without --allow-prerelease" '[ "$rc" -eq 2 ] && [ ! -s "$MOCK_LOG" ] && grep -q "not a preview tag" <<<"$out"'
D="$T/bad-pre-absent"; rm -rf "$D"; cp -r "$REL" "$D"; rm "$D/PRERELEASE"
out=$(bash "$SYNC" --dir "$D" --tag "$TAG" --repo-root "$REPOROOT" 2>&1); rc=$?
check "preview tag without a PRERELEASE file is a pre-release" '[ "$rc" -eq 0 ] && grep -q "prerelease=yes (preview tag)" <<<"$out"'
reset_state
jq '.gh.tags -= ["'"$TAG"'"]' "$MOCK_STATE" > "$MOCK_STATE.n" && mv "$MOCK_STATE.n" "$MOCK_STATE"
out=$(bash "$SYNC" --dir "$REL" --tag "$TAG" --apply "${gated[@]}" 2>&1); rc=$?
check "missing GitHub tag exits 2" '[ "$rc" -eq 2 ]'
check "missing GitHub tag: no change, no tag created" '[ "$(mutations)" -eq 0 ] && [ "$(st ".gh.tags_created // [] | length")" -eq 0 ]'
check "missing tag message names the rule" 'grep -q "this tool never creates tags" <<<"$out"'

# 5. gated apply: publish both, parity, retire all others, final parity
reset_state
out=$(bash "$SYNC" --dir "$REL" --tag "$TAG" --apply "${gated[@]}" 2>&1); rc=$?; keep sync-apply "$out"
check "gated apply exits 0" '[ "$rc" -eq 0 ]' || echo "$out"
check "one GitHub release left: $TAG" '[ "$(st "[.gh.releases[].tag_name] | join(\",\")")" = "$TAG" ]'
check "one GitLab release left: $TAG" '[ "$(st ".gl.releases | keys | join(\",\")")" = "$TAG" ]'
check "tags kept on both forges" '[ "$(st ".gh.tags | length")" -eq 4 ] && [ "$(st ".gl.tags | length")" -eq 4 ]'
check "no tag created" '[ "$(st ".gh.tags_created // [] | length")" -eq 0 ]'
check "GitHub assets in canonical order (amd64, arm64, common)" '[ "$(st "[.gh.releases[0].assets | sort_by(.id)[].name] | join(\" \")")" = "$CANON" ]'
check "GitLab links in the same order, in arch folders" '[ "$(st "[.gl.releases[\"$TAG\"].links[].name] | join(\" \")")" = "amd64/$AMD.img.zst.part-00 amd64/PARTS-amd64.sha256 amd64/SHA256SUMS-amd64 arm64/$ARM.img.zst.part-00 arm64/$ARM.img.zst.part-01 arm64/PARTS-arm64.sha256 arm64/SHA256SUMS-arm64 ncz-join-image.sh SHA256SUMS NOTES.md" ]'
check "GitLab part link has stable folder path" '[ "$(st ".gl.releases[\"$TAG\"].links[] | select(.name==\"arm64/$ARM.img.zst.part-01\") | .direct_asset_path")" = /arm64/ncz-os-arm64.img.zst.part-01 ]'
check "GitLab packages per architecture + common" '[ "$(st "[.gl.packages[] | select(.name | startswith(\"ncz-os-image\")) | .name] | sort | join(\",\")")" = "ncz-os-image-amd64,ncz-os-image-arm64,ncz-os-image-common" ]'
check "GitHub body uses GitHub link forms" '[ "$(st ".gh.releases[0].body" | grep -c "https://raw.github.test/ncz-os/cix-installer/main/docs/screenshots")" -eq 2 ] && st ".gh.releases[0].body" | grep >/dev/null "https://github.test/ncz-os/cix-installer/releases/download/$TAG/SHA256SUMS" && st ".gh.releases[0].body" | grep >/dev/null "https://github.test/ncz-os/cix-installer/releases)" && st ".gh.releases[0].body" | grep >/dev/null "releases/download/$TAG/$ARM.img.zst.part-00)" && st ".gh.releases[0].body" | grep >/dev/null "releases/download/$TAG/PARTS-arm64.sha256)" && ! st ".gh.releases[0].body" | grep >/dev/null "releases/latest"'
check "GitLab body is NOTES.md as staged" '[ "$(st ".gl.releases[\"$TAG\"].description")" = "$(cat "$REL/NOTES.md")" ]'
check "GitHub release is a pre-release" '[ "$(st ".gh.releases[0].prerelease")" = true ]'
check "release lists read back after retiring" 'grep -q "GitHub lists 1 release(s) ($TAG, prerelease=yes); GitLab release $TAG exists and is not upcoming" <<<"$out"'
check "parity used the releases list, not /releases/latest" 'grep -q "GitHub releases page lists only $TAG (prerelease=yes)" <<<"$out" && ! grep -q "/releases/latest" "$MOCK_LOG"'
check "kernel source package untouched" '[ "$(st "[.gl.packages[] | select(.name==\"linux-source-cix-sky1-ncz\")] | length")" -eq 1 ]'
check "final parity reported" 'grep -q "Result: PARITY ($TAG)" <<<"$out" && grep -q "Done: $TAG is the one release page" <<<"$out"'
check "no GitHub tokens in curl argv" '! grep -qF "$GH_TOK" "$MOCK_ARGV" && ! grep -qF "$GL_TOK" "$MOCK_ARGV"'
check "no tokens in output" '! grep -qF "$GH_TOK" <<<"$out" && ! grep -qF "$GL_TOK" <<<"$out"'
check "downloads are anonymous" '! grep -E "^GET https://(github.test|gitlab.test/ncz-os|raw.github.test)" "$MOCK_LOG" | grep >/dev/null -v "auth=anon"'
cp "$MOCK_STATE" "$T/good.json"

# 6. parity on the good state, anonymous and quick
: > "$MOCK_LOG"
out=$(TEST_GH_TOKEN="" TEST_GL_TOKEN="" bash "$CHECK" --tag "$TAG" "${CK[@]}" --release-dir "$REL" --expect-prerelease yes 2>&1); rc=$?
check "anonymous full parity passes" '[ "$rc" -eq 0 ]' || echo "$out"
check "parity read-only" '[ "$(mutations)" -eq 0 ]'
out=$(bash "$CHECK" "${CK[@]}" 2>&1); rc=$?
check "parity without --tag uses the single release" '[ "$rc" -eq 0 ] && grep -q "no --tag: checking $TAG" <<<"$out"'
out=$(bash "$CHECK" --tag "$TAG" --quick "${CK[@]}" 2>&1); rc=$?
check "quick parity passes" '[ "$rc" -eq 0 ]'

# 7. re-run of the sync is idempotent
: > "$MOCK_LOG"
out=$(bash "$SYNC" --dir "$REL" --tag "$TAG" --apply "${gated[@]}" 2>&1); rc=$?
check "re-run exits 0" '[ "$rc" -eq 0 ]' || echo "$out"
check "re-run uploads nothing to either forge" '! grep -qE "^(POST https://uploads|PUT .*/packages/generic/)" "$MOCK_LOG"'
check "re-run retires nothing" '! grep -qE "^DELETE .*/releases/" "$MOCK_LOG"'

# 8. every kind of difference fails the parity check
mism() { # name jq-filter expected-grep [extra args]
  local name=$1 f=$2 want=$3; shift 3
  jq "$f" "$T/good.json" > "$MOCK_STATE"
  out=$(bash "$CHECK" --tag "$TAG" "${CK[@]}" "$@" 2>&1); rc=$?; keep "mismatch-$name" "$out"
  check "mismatch $name: exit 1" '[ "$rc" -eq 1 ]' || echo "$out"
  check "mismatch $name: reported" 'grep -q -- "$want" <<<"$out"' || echo "$out"
}
GHR='.gh.releases[0]'
mism title "$GHR.name = \"other\"" "DIFF  title: GitHub 'other'"
mism body "$GHR.body += \"\nextra line\n\"" "notes body differs"
mism body-diff-line "$GHR.body += \"\nextra line\n\"" "+extra line\|-extra line"
mism asset-missing "$GHR.assets |= map(select(.name != \"SHA256SUMS\"))" "asset names differ"
mism size "$GHR.assets |= map(if .name == \"ncz-os-amd64-20261014-abcdef12.img.zst.part-00\" then .size = 1 else . end)" "size of ncz-os-amd64-20261014-abcdef12.img.zst.part-00"
mism sha "$GHR.assets |= map(if .name == \"ncz-os-arm64-20261014-abcdef12.img.zst.part-00\" then .digest = \"sha256:$(printf '1%.0s' {1..64})\" else . end)" "sha256 of ncz-os-arm64-20261014-abcdef12.img.zst.part-00"
mism extra-gh-list ".gh.releases += [{\"id\": 98, \"tag_name\": \"v2026.08.27-v14\", \"name\": \"old\", \"body\": \"\", \"draft\": false, \"prerelease\": false, \"created_at\": \"2026-08-27T23:18:14Z\", \"assets\": []}]" "GitHub releases page lists 2 releases; it must list only $TAG"
mism extra-gh-release ".gh.releases += [{\"id\": 99, \"tag_name\": \"v26.10-preview1\", \"name\": \"P1\", \"body\": \"\", \"draft\": false, \"prerelease\": true, \"created_at\": \"2026-08-27T23:40:38Z\", \"assets\": []}]" "github has another release: v26.10-preview1"
mism extra-gl-release ".gl.releases[\"v2026.08.18-v12\"] = {\"name\": \"old\", \"description\": \"\", \"released_at\": \"2026-08-18T04:37:42Z\", \"links\": []}" "gitlab has another release: v2026.08.18-v12"
mism gl-missing ".gl.releases = {}" "gitlab has no release for $TAG"
mism prerelease "$GHR.prerelease = false" "pre-release flag is no, expected yes" --expect-prerelease yes
mism expect-pre "." "pre-release flag is yes, expected no" --expect-prerelease no
mism other-tag-link "$GHR.body += \"\n[old](https://github.test/ncz-os/cix-installer/releases/download/v26.10-preview1/SHA256SUMS)\n\"" "github notes link to another release"
mism gh-latest-link "$GHR.body += \"\n[latest](https://github.test/ncz-os/cix-installer/releases/latest)\n\"" "GitHub /releases/latest never reaches a pre-release"
mism draft "$GHR.draft = true" "GitHub release is a draft"
mism gl-latest ".gl.releases[\"$TAG\"].upcoming = true" "GitLab releases/permalink/latest -> 'none'"
mism direct-path ".gl.releases[\"$TAG\"].links |= map(if .name == \"arm64/$ARM.img.zst.part-00\" then .direct_asset_path = \"/$ARM.img.zst.part-00\" else . end)" "expected stable alias '/arm64/ncz-os-arm64.img.zst.part-00'"
mism gh-order "$GHR.assets |= map(if (.name | startswith(\"ncz-os-amd64\")) then .id += 100000 else . end)" "github files are not in the canonical order"
mism gl-noprefix ".gl.releases[\"$TAG\"].links |= map(if .name == \"arm64/PARTS-arm64.sha256\" then .name = \"PARTS-arm64.sha256\" else . end)" "expected the name 'arm64/PARTS-arm64.sha256'"
mism gl-linktype ".gl.releases[\"$TAG\"].links |= map(if .name == \"amd64/SHA256SUMS-amd64\" then .link_type = \"other\" else . end)" "link type 'other', expected package"
mism gl-package ".gl.releases[\"$TAG\"].links |= map(if .name == \"amd64/$AMD.img.zst.part-00\" then .url |= sub(\"ncz-os-image-amd64\"; \"ncz-os-image-common\") else . end)" "points into package 'ncz-os-image-common', expected ncz-os-image-amd64"
mism unexpected "$GHR.assets += [{\"id\": 999999, \"name\": \"PARTS.sha256\", \"size\": 1, \"digest\": null, \"sha\": \"0\"}]" "unexpected file on a release page: PARTS.sha256"
mism section-missing "$GHR.body |= sub(\"## arm64: CIX Sky1\"; \"## Sky1\")" "the notes have no section heading naming arm64"
mism join-missing "$GHR.body |= sub(\"sh ncz-join-image.sh amd64\"; \"sh join amd64\")" "the amd64 section of the notes is missing: the 'ncz-join-image.sh amd64' command"
mism foreign-link ".gl.releases[\"$TAG\"].links |= map(if .name == \"ncz-join-image.sh\" then .url = \"https://elsewhere.test/x\" else . end)" "does not point at this project's generic package registry"
# small file served with other bytes on GitHub than its digest claims: the byte check catches it
printf 'tampered\n' > "$T/tampered"; badblob=$(sha "$T/tampered"); cp "$T/tampered" "$MOCK_BLOBS/$badblob"
mism small-file "$GHR.assets |= map(if .name == \"SHA256SUMS\" then .serve = \"$badblob\" else . end)" "SHA256SUMS content differs"
both_serve() { # file -> jq filter serving the tampered blob for it on both forges
  printf '%s' "$GHR.assets |= map(if .name == \"$1\" then .serve = \"$badblob\" else . end) | .gl.packages |= map(.files |= map(if .file_name == \"$1\" then .serve = \"$badblob\" else . end))"
}
mism sums-concat "$(both_serve SHA256SUMS)" "SHA256SUMS is not SHA256SUMS-amd64 SHA256SUMS-arm64 in that order"
mism parts-list "$(both_serve PARTS-arm64.sha256)" "PARTS-arm64.sha256 does not list exactly the arm64 parts on the page"
jq '.raw_override = {"gl:docs/screenshots/26.10/02-lock.png": "404"}' "$T/good.json" > "$T/g2.json"
mism shot-404 '.raw_override = {"gl:docs/screenshots/26.10/02-lock.png": "404"}' "02-lock.png answers HTTP 404"
mism shot-corrupt '.raw_override = {"gh:docs/screenshots/26.10/01-desktop.png": "corrupt"}' "does not match docs/screenshots/26.10/01-desktop.png"
mism shot-set "$GHR.body |= sub(\"!\\\\[Desktop\\\\]\\\\([^)]*\\\\)\"; \"\")" "screenshot sets differ"
mism shot-relative "$GHR.body += \"\n![r](docs/screenshots/26.10/01-desktop.png)\n\"" "is a relative link"
jq '.' "$T/good.json" > "$MOCK_STATE"
out=$(bash "$CHECK" --tag v26.10-preview1 "${CK[@]}" 2>&1); rc=$?
check "tag that is not the single release fails" '[ "$rc" -eq 1 ] && grep -q "github has no release for v26.10-preview1" <<<"$out" && grep -q "github has another release: $TAG" <<<"$out"'
# quick mode: size still compared, sha not
jq "$GHR.assets |= map(if .name == \"ncz-os-arm64-20261014-abcdef12.img.zst.part-00\" then .digest = \"sha256:$(printf '2%.0s' {1..64})\" else . end)" "$T/good.json" > "$MOCK_STATE"
bash "$CHECK" --tag "$TAG" --quick "${CK[@]}" >/dev/null 2>&1; rc=$?
check "quick mode ignores sha256" '[ "$rc" -eq 0 ]'
# staged folder differs from pages
D="$T/rel-changed"; rm -rf "$D"; cp -r "$REL" "$D"; echo "changed" >> "$D/NOTES.md"
jq '.' "$T/good.json" > "$MOCK_STATE"
out=$(bash "$CHECK" --tag "$TAG" "${CK[@]}" --release-dir "$D" 2>&1); rc=$?
check "staged folder difference fails" '[ "$rc" -eq 1 ] && grep -q "staged NOTES.md size" <<<"$out"'
D="$T/rel-badlayout"; rm -rf "$D"; cp -r "$REL" "$D"; echo "changed" >> "$D/SHA256SUMS"
out=$(bash "$CHECK" --tag "$TAG" "${CK[@]}" --release-dir "$D" 2>&1); rc=$?
check "staged folder not in the layout fails" '[ "$rc" -eq 1 ] && grep -q "does not match the release layout" <<<"$out"'

# 9. sync replaces a changed file and keeps canonical order
cp "$T/good.json" "$MOCK_STATE"; : > "$MOCK_LOG"
D="$T/rel2"; rm -rf "$D"; cp -r "$REL" "$D"
head -c 1200 /dev/urandom > "$D/arm64/$ARM.img.zst.part-01"; mkparts "$D" arm64
out=$(bash "$SYNC" --dir "$D" --tag "$TAG" --apply "${gated[@]}" 2>&1); rc=$?
check "changed-file sync exits 0" '[ "$rc" -eq 0 ]' || echo "$out"
check "unchanged leading file not re-uploaded" '! grep -q "^POST https://uploads.*name=ncz-os-arm64-20261014-abcdef12.img.zst.part-00 " "$MOCK_LOG"'
check "changed file and later files re-uploaded" 'grep -q "^POST https://uploads.*name=ncz-os-arm64-20261014-abcdef12.img.zst.part-01 " "$MOCK_LOG" && grep -q "^POST https://uploads.*name=NOTES.md " "$MOCK_LOG"'
check "amd64 group not re-uploaded" '! grep -qE "^POST https://uploads.*name=(ncz-os-amd64|PARTS-amd64|SHA256SUMS-amd64)" "$MOCK_LOG"'
check "order still canonical" '[ "$(st "[.gh.releases[0].assets | sort_by(.id)[].name] | join(\" \")")" = "$CANON" ]'

# 10. GitHub upload whose digest does not verify: fails, nothing retired
reset_state
jq '.gh.corrupt_upload = ["SHA256SUMS"]' "$MOCK_STATE" > "$MOCK_STATE.n" && mv "$MOCK_STATE.n" "$MOCK_STATE"
out=$(bash "$SYNC" --dir "$REL" --tag "$TAG" --apply "${gated[@]}" 2>&1); rc=$?
check "bad GitHub digest exits 1" '[ "$rc" -eq 1 ]'
check "bad GitHub digest retried 3 times" '[ "$(grep -c "^POST https://uploads.*name=SHA256SUMS " "$MOCK_LOG")" -eq 3 ]'
check "bad GitHub digest retires nothing" '[ "$(st ".gh.releases | length")" -eq 4 ] && [ "$(st ".gl.releases | length")" -eq 3 ]'

# 11. check-release-links and refresh-release-links
REFRESH="$ROOT/tools/refresh-release-links.sh"
L="$T/links"; mkdir -p "$L/docs/releases"
cat > "$L/README.md" <<'EOF'
[ok](https://github.com/ncz-os/cix-installer/releases)
[ok](https://github.com/ncz-os/cix-installer/releases/tag/v26.10-preview2)
[ok](https://github.com/ncz-os/cix-installer/releases/download/v26.10-preview2/SHA256SUMS)
[ok](https://github.com/ncz-os/cix-installer/releases/download/v26.10-preview2/PARTS-arm64.sha256)
[ok](https://gitlab.com/ncz-os/cix-installer/-/releases/permalink/latest)
[ok](https://gitlab.com/ncz-os/cix-installer/-/releases/permalink/latest/downloads/SHA256SUMS)
[ok](https://gitlab.com/ncz-os/cix-installer/-/releases/permalink/latest/downloads/amd64/ncz-os-amd64.img.zst.part-00)
[ok](https://gitlab.com/ncz-os/cix-installer/-/releases/permalink/latest/downloads/arm64/SHA256SUMS-arm64)
[ok](https://gitlab.com/ncz-os/cix-installer/-/tree/v26.10-preview1)
[ok](https://gitlab.com/ncz-os/cix-installer/-/releases)
[ok](https://gitlab.com/api/v4/projects/81838641/packages/generic/linux-source-cix-sky1-ncz/7.0.12/x.tar.gz)
placeholder https://gitlab.com/ncz-os/cix-installer/-/releases/<tag>/downloads/<file>
placeholder https://github.com/ncz-os/cix-installer/releases/download/<tag>/<file>
[ok](https://github.com/ncz-os/zoder/releases/download/nightly/zoder.tar.gz)
EOF
out=$(NCZ_LINT_ROOT="$L" bash "$LINKS" --current-tag v26.10-preview2 2>&1); rc=$?
check "links: clean files pass with the current tag" '[ "$rc" -eq 0 ]' || echo "$out"
echo v26.10-preview2 > "$L/docs/releases/current-tag"
out=$(NCZ_LINT_ROOT="$L" bash "$LINKS" 2>&1); rc=$?
check "links: current tag read from docs/releases/current-tag" '[ "$rc" -eq 0 ] && grep -q "current tag v26.10-preview2" <<<"$out"' || echo "$out"
rm "$L/docs/releases/current-tag"
out=$(NCZ_LINT_ROOT="$L" bash "$LINKS" 2>&1); rc=$?
check "links: without a current tag every tag link fails" '[ "$rc" -eq 1 ] && [ "$(grep -c "^RELEASE-LINK: README.md:" <<<"$out")" -eq 3 ]' || echo "$out"
cat > "$L/docs/bad.md" <<'EOF'
[x](https://github.com/ncz-os/cix-installer/releases/latest)
[x](https://github.com/ncz-os/cix-installer/releases/latest/download/SHA256SUMS)
<https://github.com/ncz-os/cix-installer/releases/tag/v26.10-preview1>
[x](https://github.com/ncz-os/cix-installer/releases/download/v26.10-preview1/SHA256SUMS)
[x](https://github.com/ncz-os/cix-installer/releases/download/v26.10-preview2/PARTS.sha256)
[x](https://github.com/ncz-os/cix-installer/releases/download/v26.10-preview2/ncz-os-arm64-20261014-abcdef12.img.zst.part-00)
[x](https://gitlab.com/ncz-os/cix-installer/-/releases/v2026.08.18-v12)
[x](https://gitlab.com/api/v4/projects/81838641/packages/generic/ncz-iso/2026.08.27-v14/a.iso)
[x](https://gitlab.com/ncz-os/cix-installer/-/releases/permalink/latest/downloads/amd64/ncz-os-amd64-20261014-abcdef12.img.zst.part-00)
EOF
out=$(NCZ_LINT_ROOT="$L" bash "$LINKS" --current-tag v26.10-preview2 2>&1); rc=$?
check "links: other tags, /releases/latest and changing names fail" '[ "$rc" -eq 1 ] && [ "$(grep -c "^RELEASE-LINK: docs/bad.md:" <<<"$out")" -eq 9 ]' || echo "$out"
out=$(bash "$LINKS" --current-tag v26.10-preview2 --allow-part-names --files "$L/docs/bad.md" 2>&1); rc=$?
check "links: --allow-part-names accepts a part of the current tag only" '[ "$(grep -c "^RELEASE-LINK" <<<"$out")" -eq 8 ]' || echo "$out"
out=$(bash "$LINKS" --current-tag v26.10-preview2 --files "$L/README.md" 2>&1); rc=$?
check "links: --files mode" '[ "$rc" -eq 0 ]'
# refresh: dry run shows the change, --apply moves every GitHub tag link to the new tag
R="$T/refresh"; mkdir -p "$R/docs/releases"
cat > "$R/README.md" <<'EOF'
[page](https://github.com/ncz-os/cix-installer/releases)
[tag](https://github.com/ncz-os/cix-installer/releases/tag/v26.10-preview1).
[sums](https://github.com/ncz-os/cix-installer/releases/download/v26.10-preview1/SHA256SUMS)
placeholder https://github.com/ncz-os/cix-installer/releases/download/<tag>/<file>
[gl](https://gitlab.com/ncz-os/cix-installer/-/releases/permalink/latest)
[src](https://gitlab.com/ncz-os/cix-installer/-/tree/v26.10-preview1)
EOF
echo v26.10-preview1 > "$R/docs/releases/current-tag"
cp "$R/README.md" "$R/README.before"
out=$(NCZ_LINT_ROOT="$R" bash "$REFRESH" --tag v26.10-preview2 2>&1); rc=$?
check "refresh dry run exits 0 and changes nothing" '[ "$rc" -eq 0 ] && cmp -s "$R/README.md" "$R/README.before" && grep -q "1 file(s) would change" <<<"$out" && grep -q "^+.*releases/download/v26.10-preview2/SHA256SUMS" <<<"$out"' || echo "$out"
out=$(NCZ_LINT_ROOT="$R" bash "$REFRESH" --tag v26.10-preview2 --apply 2>&1); rc=$?
check "refresh --apply rewrites GitHub tag links only" '[ "$rc" -eq 0 ] && [ "$(grep -c "v26.10-preview2" "$R/README.md")" -eq 2 ] && grep -q "releases/tag/v26.10-preview2)\." "$R/README.md" && grep -q -- "-/tree/v26.10-preview1" "$R/README.md" && grep -q "download/<tag>/<file>" "$R/README.md"' || { echo "$out"; cat "$R/README.md"; }
check "refresh --apply records the current tag" '[ "$(cat "$R/docs/releases/current-tag")" = v26.10-preview2 ]'
rm "$R/README.before"
out=$(NCZ_LINT_ROOT="$R" bash "$LINKS" 2>&1); rc=$?
check "links pass after the refresh" '[ "$rc" -eq 0 ]' || echo "$out"

# 12. ncz-join-image.sh with per-architecture files (and the older combined files)
if command -v zstd >/dev/null && [ "$(df -Pk "$T" | awk 'NR==2{print $4}')" -ge 8500000 ]; then
  J="$T/join"; mkdir -p "$J"
  head -c 300000 /dev/urandom > "$J/img.raw"
  zstd -q -c "$J/img.raw" > "$J/img.zst"
  python3 -I -c 'import sys; d = open(sys.argv[1], "rb").read()
for i, o in enumerate(range(0, len(d), 100000)): open("%s%02d" % (sys.argv[2], i), "wb").write(d[o:o + 100000])' "$J/img.zst" "$J/ncz-os-amd64-20261014-abcdef12.img.zst.part-"
  rm "$J/img.zst"
  ( cd "$J" && for p in ncz-os-amd64-*.part-*; do printf '%s  %s\n' "$(sha "$p")" "$p"; done > PARTS-amd64.sha256
    printf '%s  %s\n' "$(sha img.raw)" ncz-os-amd64-20261014-abcdef12.img > SHA256SUMS-amd64 )
  rm "$J/img.raw"
  out=$(sh "$ROOT/tools/ncz-join-image.sh" -d "$J" amd64 2>&1); rc=$?
  check "join script verifies per-architecture files" '[ "$rc" -eq 0 ] && grep -q "^OK: ncz-os-amd64-20261014-abcdef12.img verified" <<<"$out"' || echo "$out"
  rm "$J/ncz-os-amd64-20261014-abcdef12.img"; mv "$J/PARTS-amd64.sha256" "$J/PARTS.sha256"; mv "$J/SHA256SUMS-amd64" "$J/SHA256SUMS"
  out=$(sh "$ROOT/tools/ncz-join-image.sh" -d "$J" 2>&1); rc=$?
  check "join script still reads the combined files of older releases" '[ "$rc" -eq 0 ] && grep -q "^OK: " <<<"$out"' || echo "$out"
  echo x >> "$J/ncz-os-amd64-20261014-abcdef12.img.zst.part-01"
  sh "$ROOT/tools/ncz-join-image.sh" -d "$J" -f >/dev/null 2>&1; rc=$?
  check "join script refuses a bad part" '[ "$rc" -ne 0 ]'
else
  echo "SKIP join-script checks: $(command -v zstd >/dev/null || echo 'zstd not installed')$(command -v zstd >/dev/null && echo 'under 8.5 GB free')"
fi

# 13. hermetic: every request went to the mocked forges
check "no request reached a real forge" '! grep -E "^[A-Z]+ https?://([a-z.]*\.)?(github\.com|githubusercontent\.com|gitlab\.com)/" "$MOCK_LOG"'

# 14. usage
bash "$SYNC" --dir "$REL" >/dev/null 2>&1; rc=$?; check "sync without --tag exits 2" '[ "$rc" -eq 2 ]'
bash "$CHECK" --expect-prerelease maybe >/dev/null 2>&1; rc=$?; check "bad --expect-prerelease exits 2" '[ "$rc" -eq 2 ]'
bash "$SYNC" --help | grep >/dev/null -- "--operator-approved"; rc=$?; check "sync --help documents the gate" '[ "$rc" -eq 0 ]'
bash "$CHECK" --help | grep >/dev/null -- "--quick"; rc=$?; check "check --help documents --quick" '[ "$rc" -eq 0 ]'

echo "passed=$PASS failed=$FAILS"
[ "$FAILS" -eq 0 ]
