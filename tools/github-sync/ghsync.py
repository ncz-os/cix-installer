#!/usr/bin/env python3
"""ghsync.py -- keep the GitHub copies of GitLab projects in step with GitLab.

GitLab is the canonical forge. Each GitHub repository receives a deterministic
filtered copy of the GitLab branches and tags:

  * blobs over the GitHub file limit (and any blob id listed in the strip list)
    are left out of the copy;
  * literals from a text-replacement list (a site file kept outside every
    repository) are replaced in file contents and commit messages;
  * author/committer/tagger identities are normalised with a mailmap (also a
    site file);
  * only refs/heads/* and refs/tags/* are copied (no merge-request refs).

The filter is git-filter-repo with --prune-empty never, so a commit that the
filter does not change keeps its sha, and a commit whose content and ancestry
are unchanged gets the same filtered sha on every run. Each sync is therefore
an incremental push; a forced update is only needed for refs whose filtered
history really changed, and it is always pinned with --force-with-lease.

A repository whose history needs no filtering runs in "identity" mode: GitLab
refs are pushed as they are (same shas on both forges) after a guard scan of
every object not seen in an earlier verified run.

Subcommands:
  sync   fetch GitLab, build the copy, plan ref changes against GitHub,
         and (with --apply) back up the GitHub refs and push.
  check  compare every GitLab branch/tag tree (with the same exclusions
         applied) to the tree of the GitHub ref; exit 1 on any drift.

Settings (environment, or first line of ~/.config/ncz/<file>):
  NCZ_GHSYNC_WORKDIR        ghsync-workdir        persistent cache/work dir
  NCZ_GHSYNC_REPLACE_FILE   ghsync-replace-file   filter-repo --replace-text file
  NCZ_GHSYNC_MAILMAP        ghsync-mailmap        mailmap file
  NCZ_GHSYNC_BACKUP_DIR     ghsync-backup-dir     where GitHub ref bundles go
  NCZ_GHSYNC_GITLAB_BASE    ghsync-gitlab-base    default https://gitlab.com
  NCZ_GHSYNC_GITHUB_BASE    ghsync-github-base    default https://github.com
  NCZ_GHSYNC_GITHUB_API     ghsync-github-api     default https://api.github.com
                                                  ("none" disables release lookups)
  GIT_ASKPASS               credential helper; also asked for the GitHub API token

Exit codes: 0 ok / in sync, 1 drift or refused change, 2 usage or setup error.
"""

import argparse
import fnmatch
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
GITHUB_FILE_LIMIT = 100 * 1024 * 1024
WARN_LIMIT = 50 * 1024 * 1024
PUSH_PACK_BUDGET = 1536 * 1024 * 1024  # stay well under the 2 GiB push cap
COPY_REF_PREFIXES = ("refs/heads/", "refs/tags/")
MAP_REF = "refs/heads/history/gitlab-commit-map"
MAP_DATE = "1791849600 +0000"  # fixed date: the map commit is reproducible


class Fatal(Exception):
    pass


def log(msg):
    print(msg, file=sys.stderr, flush=True)


def site(var, name, default=""):
    v = os.environ.get(var, "")
    if not v:
        f = os.path.join(
            os.environ.get("XDG_CONFIG_HOME")
            or os.path.join(os.path.expanduser("~"), ".config"),
            "ncz",
            name,
        )
        try:
            with open(f) as fh:
                v = fh.readline().rstrip("\n")
        except OSError:
            v = ""
    return v or default


def git(gitdir, *args, input=None, check=True, env=None, text=True):
    cmd = ["git"]
    if gitdir:
        cmd += ["--git-dir", gitdir]
    cmd += ["-c", "credential.helper=", "-c", "gc.auto=0"] + list(args)
    e = dict(os.environ)
    e.setdefault("GIT_TERMINAL_PROMPT", "0")
    if env:
        e.update(env)
    r = subprocess.run(
        cmd, input=input, capture_output=True, text=text, env=e, check=False
    )
    if check and r.returncode != 0:
        err = r.stderr if text else r.stderr.decode("utf-8", "replace")
        raise Fatal("git {} failed: {}".format(" ".join(args[:2]), err.strip()[-800:]))
    return r


# ---------------------------------------------------------------- config


def load_repos(path):
    repos = []
    with open(path) as fh:
        for line in fh:
            line = line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            f = line.split("\t")
            if len(f) < 4:
                raise Fatal(f"{path}: bad line: {line!r}")
            opts = {}
            for kv in f[4:]:
                if "=" in kv:
                    k, v = kv.split("=", 1)
                    opts[k] = v
            repos.append(
                {
                    "name": f[0],
                    "gitlab": f[1],
                    "github": f[2],
                    "mode": f[3],
                    "opts": opts,
                }
            )
    return repos


def load_strip_ids(path):
    ids = set()
    if path and os.path.exists(path):
        with open(path) as fh:
            for line in fh:
                line = line.split("#", 1)[0].strip()
                if line:
                    ids.add(line.split()[0])
    return ids


def load_literals(path):
    """filter-repo replace-text format: 'literal==>replacement' or bare literal.
    regex:/glob: lines are not supported here (the checker must model them).
    Returns a list of (bytes, bytes) pairs: the file is read in binary mode."""
    lits = []
    if not path:
        return lits
    if not os.path.exists(path):
        raise Fatal("replace file not found (setting NCZ_GHSYNC_REPLACE_FILE)")
    with open(path, "rb") as fh:
        for line in fh:
            line = line.rstrip(b"\n")
            if not line:
                continue
            if line.startswith((b"regex:", b"glob:")):
                raise Fatal("replace file: only literal entries are supported")
            line = line.removeprefix(b"literal:")
            if b"==>" in line:
                a, b = line.rsplit(b"==>", 1)
            else:
                a, b = line, b"***REMOVED***"
            lits.append((a, b))
    return lits


def mailmap_old_emails(path):
    """Emails the mailmap replaces: the commit email of every line that names
    both a proper and a commit email (a one-email line only fixes the name)."""
    out = set()
    if not path:
        return out
    with open(path) as fh:
        for line in fh:
            emails = re.findall(r"<([^<>]*)>", line.split("#", 1)[0])
            if (
                len(emails) >= 2
                and emails[-1].strip().lower() != emails[0].strip().lower()
            ):
                out.add(emails[-1].strip().lower())
    return out


class Ctx:
    def __init__(self, a):
        self.workdir = a.workdir or site("NCZ_GHSYNC_WORKDIR", "ghsync-workdir")
        if not self.workdir:
            raise Fatal("no work dir: set NCZ_GHSYNC_WORKDIR or --workdir")
        self.workdir = os.path.abspath(self.workdir)
        self.replace_file = a.replace_file or site(
            "NCZ_GHSYNC_REPLACE_FILE", "ghsync-replace-file"
        )
        self.mailmap = a.mailmap or site("NCZ_GHSYNC_MAILMAP", "ghsync-mailmap")
        self.backup_dir = getattr(a, "backup_dir", None) or site(
            "NCZ_GHSYNC_BACKUP_DIR", "ghsync-backup-dir"
        )
        self.gl_base = site(
            "NCZ_GHSYNC_GITLAB_BASE", "ghsync-gitlab-base", "https://gitlab.com"
        ).rstrip("/")
        self.gh_base = site(
            "NCZ_GHSYNC_GITHUB_BASE", "ghsync-github-base", "https://github.com"
        ).rstrip("/")
        self.gh_api = site(
            "NCZ_GHSYNC_GITHUB_API", "ghsync-github-api", "https://api.github.com"
        ).rstrip("/")
        self.strip_ids = load_strip_ids(a.strip_list)
        self.literals = load_literals(self.replace_file)
        self.limit = a.limit
        self.old_emails = mailmap_old_emails(self.mailmap) if self.mailmap else set()
        for d in ("cache", "work", "check", "state", "maps", "backup"):
            os.makedirs(os.path.join(self.workdir, d), exist_ok=True)
        self._token = None

    def gl_url(self, r):
        return "{}/{}.git".format(self.gl_base, r["gitlab"])

    def gh_url(self, r):
        return "{}/{}.git".format(self.gh_base, r["github"])

    def token(self):
        if self._token is None:
            ap = os.environ.get("GIT_ASKPASS")
            self._token = ""
            if ap:
                r = subprocess.run(
                    [ap, "Password for 'https://x-access-token@github.com': "],
                    capture_output=True,
                    text=True,
                    check=False,
                )
                self._token = r.stdout.strip() if r.returncode == 0 else ""
        return self._token

    def gh_api_get(self, path):
        if self.gh_api == "none":
            return None
        if self.gh_api.startswith("file://"):
            # test fixtures: <dir>/<path without query>.json
            f = self.gh_api[len("file://") :] + path.split("?")[0] + ".json"
            if not os.path.exists(f):
                return None
            with open(f) as fh:
                return json.load(fh)
        out, url = [], self.gh_api + path
        while url:
            req = urllib.request.Request(
                url, headers={"Accept": "application/vnd.github+json"}
            )
            if self.token():
                req.add_header("Authorization", "token " + self.token())
            try:
                with urllib.request.urlopen(req, timeout=60) as resp:
                    data = json.load(resp)
                    link = resp.headers.get("Link") or ""
            except urllib.error.HTTPError as e:
                if e.code == 404:
                    return None
                raise Fatal(f"GitHub API {path}: HTTP {e.code}")
            if isinstance(data, list):
                out.extend(data)
            else:
                return data
            url = None
            for part in link.split(","):
                if 'rel="next"' in part:
                    url = part.split(";")[0].strip().strip("<>")
        return out


# ---------------------------------------------------------------- scanning


def is_binary(data):
    return b"\0" in data[:8192]


def apply_literals(data, lits):
    for a, b in lits:
        data = data.replace(a, b)
    return data


class BlobCache:
    """Per-repo verdict cache: blob sha -> 'c' clean | 'r' replaced:<newsha> | 'b' binary hit.
    lits is the load_literals() list: (bytes, bytes) pairs."""

    def __init__(self, path, lits):
        self.path = path
        self.key = hashlib.sha256(
            b"\n".join(a for a, _ in lits) + b"\0" + b"\n".join(b for _, b in lits)
        ).hexdigest()[:16]
        self.d = {}
        try:
            with open(path) as fh:
                head = fh.readline().strip()
                if head == "key " + self.key:
                    for line in fh:
                        k, sep, v = line.rstrip("\n").partition("\t")
                        if sep:
                            self.d[k] = v
        except OSError:
            pass
        self.dirty = False

    def save(self):
        if not self.dirty:
            return
        tmp = self.path + ".tmp"
        with open(tmp, "w") as fh:
            fh.write(f"key {self.key}\n")
            fh.writelines(f"{k}\t{v}\n" for k, v in self.d.items())
        os.replace(tmp, self.path)


def scan_blobs(gitdir, shas, lits, cache):
    """Classify blobs; returns dict sha -> verdict. A replaced blob is written
    to gitdir (the check repository) so its tree can be rebuilt."""
    todo = [s for s in shas if s not in cache.d]
    if todo and lits:
        for s, data in iter_objects(gitdir, todo):
            if not any(a in data for a, _ in lits):
                cache.d[s] = "c"
            elif is_binary(data):
                cache.d[s] = "b"
            else:
                new = apply_literals(data, lits)
                r = subprocess.run(
                    ["git", "--git-dir", gitdir, "hash-object", "-w", "--stdin"],
                    input=new,
                    capture_output=True,
                    check=True,
                )
                cache.d[s] = "r:" + r.stdout.decode().strip()
            cache.dirty = True
    elif todo:
        for s in todo:
            cache.d[s] = "c"
        cache.dirty = True
    return {s: cache.d[s] for s in shas}


def expected_tree(gitdir, commit, ctx, cache, problems):
    """Tree of `commit` after the copy's exclusions. Returns tree sha."""
    out = git(
        gitdir, "ls-tree", "-r", "-z", "-l", "--full-tree", commit, text=False
    ).stdout
    entries = []
    for rec in out.split(b"\0"):
        if not rec:
            continue
        meta, path = rec.split(b"\t", 1)
        mode, typ, sha, size = meta.split()
        entries.append((mode, typ, sha.decode(), size, path))
    blobs = [e[2] for e in entries if e[1] == b"blob"]
    verdict = scan_blobs(gitdir, sorted(set(blobs)), ctx.literals, cache)
    changed = False
    keep = []
    for mode, typ, sha, size, path in entries:
        if typ == b"blob":
            if sha in ctx.strip_ids or int(size) > ctx.limit:
                changed = True
                continue
            v = verdict.get(sha, "c")
            if v == "b":
                problems.append(
                    "binary file carries a replaced literal: {} {}".format(
                        path.decode("utf-8", "replace"), sha[:12]
                    )
                )
            elif v.startswith("r:"):
                sha = v[2:]
                changed = True
        keep.append((mode, typ, sha, path))
    tree = git(gitdir, "rev-parse", commit + "^{tree}").stdout.strip()
    if not changed:
        return tree
    with tempfile.TemporaryDirectory(dir=os.environ.get("TMPDIR")) as td:
        idx = os.path.join(td, "index")
        env = {"GIT_INDEX_FILE": idx}
        git(gitdir, "read-tree", "--empty", env=env)
        data = b"".join(b"%s %s\t%s\0" % (m, s.encode(), p) for m, t, s, p in keep)
        git(
            gitdir,
            "update-index",
            "-z",
            "--index-info",
            input=data,
            env=env,
            text=False,
        )
        return git(gitdir, "write-tree", "--missing-ok", env=env).stdout.strip()


# ---------------------------------------------------------------- refs


def ls_remote(url):
    r = git(None, "ls-remote", url, check=False)
    if r.returncode != 0:
        raise Fatal(f"ls-remote {url}: {r.stderr.strip()[-300:]}")
    refs = {}
    for line in r.stdout.splitlines():
        sha, ref = line.split("\t")
        if ref.endswith("^{}"):
            continue
        if ref.startswith(COPY_REF_PREFIXES):
            refs[ref] = sha
    return refs


def local_refs(gitdir, prefix=""):
    out = git(gitdir, "for-each-ref", "--format=%(objectname) %(refname)").stdout
    refs = {}
    for line in out.splitlines():
        sha, ref = line.split(" ", 1)
        if ref.startswith(prefix):
            refs[ref] = sha
    return refs


def fetch_gitlab(ctx, r):
    cache = os.path.join(ctx.workdir, "cache", r["name"] + ".git")
    if not os.path.isdir(cache):
        git(None, "init", "-q", "--bare", cache)
    git(
        cache,
        "fetch",
        "-q",
        "--prune",
        "--no-tags",
        ctx.gl_url(r),
        "+refs/heads/*:refs/heads/*",
        "+refs/tags/*:refs/tags/*",
    )
    return cache


def default_branch(url):
    r = git(None, "ls-remote", "--symref", url, "HEAD", check=False)
    for line in r.stdout.splitlines():
        if line.startswith("ref: "):
            return line.split()[1][len("refs/heads/") :]
    return ""


def has_object(gitdir, sha):
    return git(gitdir, "cat-file", "-e", sha, check=False).returncode == 0


def is_ancestor(gitdir, a, b):
    return git(gitdir, "merge-base", "--is-ancestor", a, b, check=False).returncode == 0


# ---------------------------------------------------------------- copy


def build_copy(ctx, r, cache, mode):
    """Returns (gitdir, refs, commit_map[old]=new)."""
    work = os.path.join(ctx.workdir, "work", r["name"] + ".git")
    if mode == "identity":
        refs = local_refs(cache)
        return cache, refs, {}
    if mode != "filter":
        raise Fatal("{}: unknown mode {!r} (filter|identity)".format(r["name"], mode))
    if os.path.isdir(work):
        shutil.rmtree(work)
    git(None, "clone", "-q", "--mirror", cache, work)
    git(work, "remote", "remove", "origin", check=False)
    args = [
        "git-filter-repo",
        "--force",
        "--quiet",
        "--prune-empty",
        "never",
        "--prune-degenerate",
        "never",
        "--preserve-commit-encoding",
        "--no-gc",
        "--strip-blobs-bigger-than",
        str(ctx.limit + 1),
    ]
    ids = sorted(ctx.strip_ids)
    if ids:
        idf = os.path.join(work, "ghsync-strip-ids")
        with open(idf, "w") as fh:
            fh.write("\n".join(ids) + "\n")
        args += ["--strip-blobs-with-ids", idf]
    if ctx.literals:
        args += [
            "--replace-text",
            ctx.replace_file,
            "--replace-message",
            ctx.replace_file,
        ]
    if ctx.mailmap:
        args += ["--mailmap", ctx.mailmap]
    p = subprocess.run(args, cwd=work, capture_output=True, text=True, check=False)
    if p.returncode != 0:
        raise Fatal(
            "filter-repo failed for {}: {}".format(r["name"], p.stderr.strip()[-600:])
        )
    # filter-repo's replace refs are not part of the copy
    for ref in local_refs(work, "refs/replace/"):
        git(work, "update-ref", "-d", ref)
    cmap = {}
    mp = os.path.join(work, "filter-repo", "commit-map")
    if os.path.exists(mp):
        with open(mp) as fh:
            next(fh, None)
            for line in fh:
                old, new = line.split()
                if old != new:
                    cmap[old] = new
    refs = {
        k: v for k, v in local_refs(work).items() if k.startswith(COPY_REF_PREFIXES)
    }
    return work, refs, cmap


def guard_scan(ctx, r, gitdir, refs, mode):
    """Errors for anything the copy must never carry (all modes). In identity
    mode only objects not reachable from the last verified refs are read."""
    errs, warns = [], []
    st = load_state(ctx, r)
    base = [
        s
        for s in st.get("verified", {}).values()
        if st.get("mode") == mode and has_object(gitdir, s)
    ]
    # trusted_base=<sha>[,<sha>]: history the project imports unchanged from an
    # upstream (e.g. a mainline kernel release) is not re-read on the first run
    base += [
        s
        for s in (x.strip() for x in r["opts"].get("trusted_base", "").split(","))
        if s and has_object(gitdir, s)
    ]
    revs = list(set(refs.values()))
    if not revs:
        return errs, warns
    rl = git(
        gitdir,
        "rev-list",
        "--objects",
        "--no-object-names",
        *revs,
        *["^" + b for b in base],
    ).stdout.split()
    if not rl:
        return errs, warns
    chk = git(
        gitdir,
        "cat-file",
        "--batch-check=%(objectname) %(objecttype) %(objectsize)",
        input="\n".join(rl) + "\n",
    ).stdout.splitlines()
    blobs = []
    commits_tags = []
    for line in chk:
        sha, typ, size = line.split()
        if typ == "blob":
            sz = int(size)
            if sz > ctx.limit:
                errs.append(f"blob {sha} is {sz} bytes (over the GitHub file limit)")
            elif sz > WARN_LIMIT:
                warns.append(f"blob {sha} is {sz / 1048576:.1f} MiB (over 50 MiB)")
            blobs.append(sha)
        elif typ in ("commit", "tag"):
            commits_tags.append(sha)
    if ctx.literals:
        found = scan_raw(gitdir, blobs + commits_tags, ctx.literals)
        for sha in found:
            errs.append(f"object {sha[:12]} carries a listed literal")
    if ctx.old_emails and commits_tags:
        found = scan_identities(gitdir, commits_tags, ctx.old_emails)
        for sha in found:
            (errs if mode != "identity" else warns).append(
                f"object {sha[:12]} carries a mailmapped identity"
            )
    return errs, warns


def scan_raw(gitdir, shas, lits):
    return [
        s for s, data in iter_objects(gitdir, shas) if any(a in data for a, _ in lits)
    ]


def iter_objects(gitdir, shas):
    """Stream (sha, data) for shas through one cat-file --batch process."""
    p = subprocess.Popen(
        ["git", "--git-dir", gitdir, "cat-file", "--batch"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
    )
    import threading

    def feed():
        for s in shas:
            p.stdin.write(s.encode() + b"\n")
        p.stdin.close()

    t = threading.Thread(target=feed, daemon=True)
    t.start()
    try:
        for s in shas:
            hdr = p.stdout.readline().split()
            if len(hdr) < 3:
                raise Fatal(f"cat-file: object {s} unreadable")
            data = p.stdout.read(int(hdr[2]))
            p.stdout.read(1)
            yield s, data
    finally:
        t.join()
        p.wait()


def scan_identities(gitdir, shas, emails):
    hits = []
    pats = [(f"<{e}>").encode() for e in emails]
    for s, body in iter_objects(gitdir, shas):
        hdr = body.split(b"\n\n", 1)[0].lower()
        if any(x in hdr for x in pats):
            hits.append(s)
    return hits


# ---------------------------------------------------------------- state


def state_path(ctx, r):
    return os.path.join(ctx.workdir, "state", r["name"] + ".json")


def load_state(ctx, r):
    try:
        with open(state_path(ctx, r)) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return {}


def save_state(ctx, r, st):
    tmp = state_path(ctx, r) + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(st, fh, indent=1, sort_keys=True)
    os.replace(tmp, state_path(ctx, r))


# ---------------------------------------------------------------- plan


def release_tags(ctx, r):
    rel = ctx.gh_api_get("/repos/{}/releases?per_page=100".format(r["github"]))
    if rel is None:
        return {}
    return {
        "refs/tags/" + x["tag_name"]: ("draft" if x.get("draft") else "published")
        for x in rel
    }


def plan_repo(ctx, r, gitdir, want, gh, rels, allow_gh_only):
    """One row per ref: (ref, github sha, target sha, action).

    create        ref missing on GitHub
    fast-forward  GitHub branch is an ancestor of the target
    rewind        non-fast-forward, but GitHub still holds exactly what the last
                  verified sync pushed: GitLab itself moved the ref
    remove        GitLab deleted a ref the last verified sync had pushed
    force         non-fast-forward and GitHub holds something this tool did not
                  push (GitHub-side commits, an older snapshot history)
    delete        a ref that exists only on GitHub
    *-BLOCKED(release:...)  any of the moving actions on a ref with a GitHub release
    """
    last = load_state(ctx, r).get("verified", {})
    prune_ok = [p for p in r["opts"].get("prune_github_only", "").split(",") if p]
    rows = []
    for ref in sorted(set(want) | set(gh)):
        new, old = want.get(ref), gh.get(ref)
        if new is None and (
            ref == MAP_REF or any(fnmatch.fnmatch(ref, p) for p in allow_gh_only)
        ):
            rows.append((ref, old, old, "keep"))
            continue
        if new == old:
            act = "same"
        elif old is None:
            act = "create"
        elif new is None:
            if last.get(ref) == old:
                act = "remove"
            elif any(fnmatch.fnmatch(ref, p) for p in prune_ok):
                act = "delete-listed"
            else:
                act = "delete"
        elif (
            ref.startswith("refs/heads/")
            and has_object(gitdir, old)
            and is_ancestor(gitdir, old, new)
        ):
            act = "fast-forward"
        elif last.get(ref) == old:
            act = "rewind"
        else:
            act = "force"
        if act.split("-")[0] in ("force", "delete", "rewind", "remove") and ref in rels:
            act += f"-BLOCKED(release:{rels[ref]})"
        rows.append((ref, old, new, act))
    return rows


# ---------------------------------------------------------------- push


def backup_github(ctx, r, stamp, rows, bundle):
    """Keep every GitHub ref about to be moved or deleted. The GitHub refs are
    fetched into a persistent backup repository and the old values are pinned
    under refs/backup/<stamp>/...; with bundle=True a bundle of all GitHub refs
    is also written to the backup directory. Returns the backup location."""
    bdir = os.path.join(ctx.workdir, "backup", r["name"] + ".git")
    if not os.path.isdir(bdir):
        git(None, "init", "-q", "--bare", bdir)
    git(
        bdir,
        "fetch",
        "-q",
        "--no-tags",
        ctx.gh_url(r),
        "+refs/heads/*:refs/gh/heads/*",
        "+refs/tags/*:refs/gh/tags/*",
    )
    for ref, old, new, act in rows:
        if old and act.split("-")[0] in ("force", "delete", "rewind", "remove"):
            git(
                bdir,
                "update-ref",
                "refs/backup/{}/{}".format(stamp, ref[len("refs/") :]),
                old,
            )
    if not bundle:
        return bdir
    out = os.path.join(
        ctx.backup_dir or os.path.join(ctx.workdir, "backup"),
        "{}-github-{}.bundle".format(r["name"], stamp),
    )
    os.makedirs(os.path.dirname(out), exist_ok=True)
    git(bdir, "bundle", "create", out, "--glob=refs/gh/*")
    git(bdir, "bundle", "verify", out)
    return out


def disk_usage(gitdir, tip, nots):
    r = git(
        gitdir, "rev-list", "--objects", "--disk-usage", tip, *["^" + n for n in nots]
    )
    return int(r.stdout.strip() or 0)


def chunk_steps(gitdir, ref, new, known, budget):
    """First-parent ancestors of new to push in order so that each push stays
    under budget bytes of new objects."""
    if disk_usage(gitdir, new, known) <= budget:
        return [new]
    fp = git(
        gitdir,
        "rev-list",
        "--first-parent",
        "--reverse",
        new,
        *["^" + k for k in known],
    ).stdout.split()
    steps, have, lo = [], list(known), 0
    while lo < len(fp):
        # largest index i with usage(fp[i] ^have) <= budget (binary search)
        a, b, best = lo, len(fp) - 1, lo
        while a <= b:
            m = (a + b) // 2
            if disk_usage(gitdir, fp[m], have) <= budget:
                best, a = m, m + 1
            else:
                b = m - 1
        if best == lo and disk_usage(gitdir, fp[best], have) > budget:
            # one first-parent step (a merge with its side history) cannot be
            # split further; it is pushed as is and may hit the remote limit
            log(f"  warn: {ref} step {fp[best][:12]} alone exceeds the push budget")
        steps.append(fp[best])
        have = have + [fp[best]]
        lo = best + 1
    return steps


def push(ctx, gitdir, url, specs):
    if not specs:
        return
    r = git(gitdir, "push", "--porcelain", url, *specs, check=False)
    if r.returncode != 0:
        raise Fatal(
            "push failed: %s"
            % (r.stderr.strip()[-600:] or r.stdout.strip()[-600:] or "<no output>")
        )


def apply_repo(ctx, r, gitdir, rows, a):
    url = ctx.gh_url(r)
    blocked = [x for x in rows if "BLOCKED" in x[3]]
    known = [x[1] for x in rows if x[1] and has_object(gitdir, x[1])]
    default = r["opts"].get("default", "")
    order = sorted(
        rows,
        key=lambda x: (
            x[0] != "refs/heads/" + default,
            not x[0].startswith("refs/heads/"),
            x[0],
        ),
    )
    # creates / fast-forwards / forces, one ref at a time when chunking is needed
    for ref, old, new, act in order:
        if act not in ("create", "fast-forward", "rewind", "force"):
            continue
        if act == "force" and not a.allow_force:
            continue
        if any(fnmatch.fnmatch(ref, p) for p in a.skip_ref):
            continue
        peeled = (
            git(gitdir, "rev-parse", new + "^{commit}", check=False).stdout.strip()
            or new
        )
        steps = chunk_steps(gitdir, ref, peeled, known, a.push_budget)
        if ref.startswith("refs/tags/") and len(steps) > 1:
            # carry the history on a staging branch, then point the tag
            tmp = "refs/heads/ghsync-staging"
            tcur = None
            for s in steps[:-1]:
                push(
                    ctx,
                    gitdir,
                    url,
                    ["--force-with-lease={}:{}".format(tmp, tcur or ""), f"+{s}:{tmp}"],
                )
                tcur = s
                known.append(s)
            push(ctx, gitdir, url, [f"--force-with-lease={tmp}:{tcur}", ":" + tmp])
            steps = [new]
        elif ref.startswith("refs/tags/"):
            steps = [new]
        cur = old
        for i, s in enumerate(steps):
            spec = []
            if cur and (
                ref.startswith("refs/tags/")
                or not (has_object(gitdir, cur) and is_ancestor(gitdir, cur, s))
            ):
                spec.append(f"--force-with-lease={ref}:{cur}")
                spec.append(f"+{s}:{ref}")
            elif cur is None:
                spec.append(f"--force-with-lease={ref}:")
                spec.append(f"{s}:{ref}")
            else:
                spec.append(f"{s}:{ref}")
            if len(steps) > 1:
                log(f"  {ref} step {i + 1}/{len(steps)} {s[:12]}")
            push(ctx, gitdir, url, spec)
            cur = s
            known.append(s)
    for ref, old, new, act in rows:
        if any(fnmatch.fnmatch(ref, p) for p in a.skip_ref):
            continue
        if (
            (act == "remove" and a.prune)
            or (act == "delete-listed" and a.prune)
            or (act == "delete" and a.prune_github_only)
        ):
            push(ctx, gitdir, url, [f"--force-with-lease={ref}:{old}", ":" + ref])
    return blocked


def publish_map(ctx, r, gitdir, cmap, gh, a):
    """GitHub-only branch history/gitlab-commit-map: one TSV, reproducible commit."""
    if not cmap:
        return None
    body = "".join(f"{k}\t{cmap[k]}\n" for k in sorted(cmap))
    head = (
        "# GitLab commit -> GitHub commit for {}.\n"
        "# Listed only where the shas differ; all other commits are identical.\n"
        "# gitlab_sha\tgithub_sha\n".format(r["gitlab"])
    )
    with open(os.path.join(ctx.workdir, "maps", r["name"] + ".tsv"), "w") as fh:
        fh.write(head + body)
    blob = git(gitdir, "hash-object", "-w", "--stdin", input=head + body).stdout.strip()
    readme = (
        "Commit map between gitlab.com/{} (canonical) and this repository.\n".format(
            r["gitlab"]
        )
    )
    rb = git(gitdir, "hash-object", "-w", "--stdin", input=readme).stdout.strip()
    tree = git(
        gitdir,
        "mktree",
        input=f"100644 blob {rb}\tREADME\n100644 blob {blob}\tcommit-map.tsv\n",
    ).stdout.strip()
    env = {
        "GIT_AUTHOR_NAME": "Jason Perlow",
        "GIT_AUTHOR_EMAIL": "jperlow@gmail.com",
        "GIT_COMMITTER_NAME": "Jason Perlow",
        "GIT_COMMITTER_EMAIL": "jperlow@gmail.com",
        "GIT_AUTHOR_DATE": MAP_DATE,
        "GIT_COMMITTER_DATE": MAP_DATE,
    }
    c = git(gitdir, "commit-tree", tree, "-m", "Commit map", env=env).stdout.strip()
    if a.apply and gh.get(MAP_REF) != c:
        lease = gh.get(MAP_REF) or ""
        push(
            ctx,
            gitdir,
            ctx.gh_url(r),
            [f"--force-with-lease={MAP_REF}:{lease}", f"+{c}:{MAP_REF}"],
        )
    return c


# ---------------------------------------------------------------- commands


def select(repos, names):
    if not names:
        return repos
    by = {r["name"]: r for r in repos}
    miss = [n for n in names if n not in by]
    if miss:
        raise Fatal("unknown repo(s): {}".format(", ".join(miss)))
    return [by[n] for n in names]


def cmd_sync(a):
    ctx = Ctx(a)
    repos = select(load_repos(a.repos), a.repo)
    stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    report = {"stamp": stamp, "apply": a.apply, "repos": []}
    rc = 0
    for r in repos:
        rep = {"name": r["name"], "mode": r["mode"]}
        report["repos"].append(rep)
        try:
            log("== {} ({})".format(r["name"], r["mode"]))
            cache = fetch_gitlab(ctx, r)
            mode = r["mode"]
            gitdir, want, cmap = build_copy(ctx, r, cache, mode)
            errs, warns = guard_scan(ctx, r, gitdir, want, mode)
            rep.update(errors=errs, warnings=warns, changed_commits=len(cmap))
            for w in warns:
                log("  warn: " + w)
            if errs:
                for e in errs[:20]:
                    log("  ERROR: " + e)
                rep["result"] = "refused (guard)"
                rc = 1
                continue
            gh = ls_remote(ctx.gh_url(r))
            rep["gitlab_default"] = default_branch(ctx.gl_url(r))
            rep["github_default"] = default_branch(ctx.gh_url(r))
            if rep["gitlab_default"] != rep["github_default"]:
                log(
                    "  note: default branch GitLab {}, GitHub {} (not changed by this tool)".format(
                        rep["gitlab_default"], rep["github_default"]
                    )
                )
            r["opts"].setdefault("default", rep["gitlab_default"])
            rels = release_tags(ctx, r)
            rep["release_tags"] = rels
            allow = r["opts"].get("gh_only", "")
            rows = plan_repo(
                ctx, r, gitdir, want, gh, rels, [p for p in allow.split(",") if p]
            )
            rep["plan"] = [
                {"ref": x[0], "github": x[1], "target": x[2], "action": x[3]}
                for x in rows
            ]
            for ref, old, new, act in rows:
                if act not in ("same", "keep"):
                    log(
                        f"  {act:<28} {ref:<60} {(old or '-')[:12]} -> {(new or '-')[:12]}"
                    )
            if not a.apply:
                rep["result"] = "dry-run"
                if cmap:
                    publish_map(ctx, r, gitdir, cmap, gh, a)
                continue
            needs_backup = any(
                x[3].split("-")[0] in ("force", "delete", "rewind", "remove")
                for x in rows
            )
            if needs_backup or a.backup_bundle:
                b = backup_github(ctx, r, stamp, rows, a.backup_bundle)
                rep["backup"] = b
                log("  backup " + str(b))
            blocked = apply_repo(ctx, r, gitdir, rows, a)
            publish_map(ctx, r, gitdir, cmap, gh, a)
            after = ls_remote(ctx.gh_url(r))
            rep["after"] = after
            bad = [
                ref
                for ref, old, new, act in rows
                if act in ("create", "fast-forward") and after.get(ref) != new
            ]
            bad += [
                ref
                for ref, old, new, act in rows
                if (act == "rewind" or (act == "force" and a.allow_force))
                and not any(fnmatch.fnmatch(ref, p) for p in a.skip_ref)
                and after.get(ref) != new
            ]
            if bad:
                rc = 1
            rep["result"] = (
                "applied"
                + (f" (blocked: {len(blocked)})" if blocked else "")
                + (" (mismatch: {})".format(",".join(bad)) if bad else "")
            )
            if not bad:
                # remember what GitHub really holds of the copy (blocked or
                # skipped refs are not recorded as pushed)
                last = load_state(ctx, r).get("verified", {})
                pushed = {
                    k: v for k, v in after.items() if v in (want.get(k), last.get(k))
                }
                st = {"mode": mode, "verified": pushed, "stamp": stamp}
                save_state(ctx, r, st)
        except Fatal as e:
            log(f"  FATAL: {e}")
            rep["result"] = f"error: {e}"
            rc = 1
    if a.report:
        with open(a.report, "w") as fh:
            json.dump(report, fh, indent=1)
    return rc


def cmd_check(a):
    ctx = Ctx(a)
    repos = select(load_repos(a.repos), a.repo)
    rc = 0
    out_rows = []
    for r in repos:
        name = r["name"]
        try:
            cg = os.path.join(ctx.workdir, "check", name + ".git")
            if not os.path.isdir(cg):
                git(None, "init", "-q", "--bare", cg)
                # borrow objects from the sync cache when there is one (refs stay separate)
                cache_objs = os.path.join(
                    ctx.workdir, "cache", name + ".git", "objects"
                )
                if os.path.isdir(cache_objs):
                    os.makedirs(os.path.join(cg, "objects", "info"), exist_ok=True)
                    with open(
                        os.path.join(cg, "objects", "info", "alternates"), "w"
                    ) as fh:
                        fh.write(cache_objs + "\n")
            rels = release_tags(ctx, r)
            if not a.no_fetch:
                git(
                    cg,
                    "fetch",
                    "-q",
                    "--prune",
                    "--no-tags",
                    ctx.gl_url(r),
                    "+refs/heads/*:refs/gl/heads/*",
                    "+refs/tags/*:refs/gl/tags/*",
                )
                git(
                    cg,
                    "fetch",
                    "-q",
                    "--prune",
                    "--no-tags",
                    ctx.gh_url(r),
                    "+refs/heads/*:refs/gh/heads/*",
                    "+refs/tags/*:refs/gh/tags/*",
                )
            gl = {k[len("refs/gl") :]: v for k, v in local_refs(cg, "refs/gl/").items()}
            gh = {k[len("refs/gh") :]: v for k, v in local_refs(cg, "refs/gh/").items()}
            gl = {"refs" + k: v for k, v in gl.items()}
            gh = {"refs" + k: v for k, v in gh.items()}
            cache = BlobCache(
                os.path.join(ctx.workdir, "state", name + ".treecache"), ctx.literals
            )
            allow = [p for p in r["opts"].get("gh_only", "").split(",") if p] + [
                MAP_REF
            ]
            drift = held = 0
            for ref in sorted(set(gl) | set(gh)):
                problems = []
                if ref not in gh:
                    st, detail = "MISSING", "not on GitHub"
                elif ref not in gl:
                    if any(fnmatch.fnmatch(ref, p) for p in allow):
                        st, detail = "ok", "GitHub-only (allowed)"
                    else:
                        st, detail = "EXTRA", "only on GitHub"
                else:
                    exp = expected_tree(cg, gl[ref] + "^{commit}", ctx, cache, problems)
                    got = git(cg, "rev-parse", gh[ref] + "^{tree}").stdout.strip()
                    if exp == got and not problems:
                        st = "ok"
                        detail = "same sha" if gl[ref] == gh[ref] else "tree equal"
                    elif exp == got:
                        st, detail = "FLAG", "; ".join(problems)
                    else:
                        st, detail = "DIFF", f"tree {got[:12]} != expected {exp[:12]}"
                if st in ("DIFF", "EXTRA") and ref in rels and not a.strict_releases:
                    # a GitHub release is attached: the sync never moves it, so it
                    # is reported apart from drift (release pages are managed separately)
                    st, detail = (
                        "RELEASE",
                        detail + f" (GitHub {rels[ref]} release attached)",
                    )
                    held += 1
                elif st != "ok":
                    drift += 1
                out_rows.append((name, ref, st, detail))
                if st != "ok" or a.verbose:
                    print(f"{name:<30} {ref:<60} {st:<7} {detail}")
            cache.save()
            print(
                f"{name:<30} {'(summary)':<60} {'DRIFT' if drift else 'OK':<7} "
                f"{len(set(gl) | set(gh))} refs, {drift} drift, {held} release-held"
            )
            if drift:
                rc = 1
        except Fatal as e:
            print(f"{name:<30} {'(error)':<60} {'ERROR':<7} {e}")
            rc = 1
    if a.report:
        with open(a.report, "w") as fh:
            fh.write("repo\tref\tstatus\tdetail\n")
            fh.writelines("\t".join(x) + "\n" for x in out_rows)
    return rc


def main(argv):
    ap = argparse.ArgumentParser(prog="ghsync", description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    for n in ("sync", "check"):
        p = sub.add_parser(n)
        p.add_argument("--repos", default=os.path.join(HERE, "repos.tsv"))
        p.add_argument("--repo", action="append", default=[])
        p.add_argument("--workdir")
        p.add_argument("--replace-file")
        p.add_argument("--mailmap")
        p.add_argument("--strip-list", default=os.path.join(HERE, "strip-blobs.txt"))
        p.add_argument("--limit", type=int, default=GITHUB_FILE_LIMIT)
        p.add_argument("--report")
        if n == "sync":
            p.add_argument("--apply", action="store_true")
            p.add_argument(
                "--allow-force",
                action="store_true",
                help="also apply non-fast-forward updates (lease-pinned)",
            )
            p.add_argument(
                "--prune-github-only",
                action="store_true",
                help="also delete refs that exist only on GitHub (after backup)",
            )
            p.add_argument(
                "--skip-ref",
                action="append",
                default=[],
                help="leave this GitHub ref (glob) untouched",
            )
            p.add_argument(
                "--prune",
                action="store_true",
                help="delete GitHub branches/tags that GitLab does not have",
            )
            p.add_argument("--backup-dir")
            p.add_argument(
                "--backup-bundle",
                action="store_true",
                help="also write a bundle of every GitHub ref before pushing",
            )
            p.add_argument("--push-budget", type=int, default=PUSH_PACK_BUDGET)
        else:
            p.add_argument("--no-fetch", action="store_true")
            p.add_argument(
                "--strict-releases",
                action="store_true",
                help="count refs that differ but carry a GitHub release as drift",
            )
            p.add_argument("--verbose", "-v", action="store_true")
    a = ap.parse_args(argv)
    try:
        return cmd_sync(a) if a.cmd == "sync" else cmd_check(a)
    except Fatal as e:
        log(f"ghsync: {e}")
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
