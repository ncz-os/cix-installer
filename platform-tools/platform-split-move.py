#!/usr/bin/env python3
"""platform-split-move.py -- physically split the tree per docs/platform-inventory.tsv.

For every tracked file under the build roots (see platform-assemble.py ROOTS) that
is not already under common/ or platforms/<p>/, `git mv` it to

    class common | mixed  ->  common/<path>
    class sky1            ->  platforms/sky1-arm64/<path>
    class amd64           ->  platforms/amd64/<path>

It is idempotent and re-runnable: after a rebase brings in new files at the old flat
paths, run it again and only those files move. A file with no inventory row is an
error (classify it first; see docs/PLATFORM-SPLIT.md). Directory history is kept
(`git log --follow`). Nothing is rewritten inside file contents: the historical flat
paths keep working through the generated view (platform-assemble.py), which is
what the compatibility layer of this split is.

  --dry-run   print the plan, change nothing
  --root DIR  repository root (default: parent of this script)
"""
import argparse
import os
import subprocess
import sys

ROOTS = ["post-install", "manifests", "assets", "build", "preseed", "tests", "tools",
         "scripts", "packaging", "packages", "sbom", "docker", "kernel-source"]
DEST = {"common": "common", "mixed": "common",
        "sky1": "platforms/sky1-arm64", "amd64": "platforms/amd64"}


def load_inventory(path):
    rows = {}
    for line in open(path):
        if line.startswith("#") or not line.strip():
            continue
        p, cls = line.rstrip("\n").split("\t")[:2]
        rows[p] = cls
    return rows


def classify(rows, path):
    if path in rows and not path.endswith("/"):
        return rows[path]
    best = None
    for p in rows:
        if p.endswith("/") and path.startswith(p) and (best is None or len(p) > len(best)):
            best = p
    return rows[best] if best else None


BEGIN = "# BEGIN platform-split generated (platform-tools/platform-split-move.py; do not edit)"
END = "# END platform-split generated"


def rewrite_gitignore(root):
    """Ignore the generated flat view and mirror every build-root ignore rule onto the
    source locations (common/<r>/..., platforms/*/<r>/...), so blobs staged in either
    place stay untracked exactly as they were in the flat tree."""
    path = os.path.join(root, ".gitignore")
    lines = open(path).read().split("\n")
    if BEGIN in lines:
        a, b = lines.index(BEGIN), lines.index(END)
        lines = lines[:a] + lines[b + 1:]
    while lines and lines[-1] == "":
        lines.pop()
    gen = [BEGIN,
           "# The flat build view is generated from common/ and platforms/<platform>/.",
           ] + ["/%s/" % r for r in ROOTS] + ["/.platform-assembled"]
    for l in lines:
        neg = l.startswith("!")
        body = l[1:] if neg else l
        first = body.split("/", 1)[0]
        if first in ROOTS and "/" in body:
            gen.append(("!" if neg else "") + "common/" + body)
            gen.append(("!" if neg else "") + "platforms/*/" + body)
    gen.append(END)
    open(path, "w").write("\n".join(lines + [""] + gen) + "\n")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--root", default=os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()
    root = a.root
    rows = load_inventory(os.path.join(root, "docs", "platform-inventory.tsv"))
    out = subprocess.run(["git", "-C", root, "ls-files", "-z"], check=True, capture_output=True).stdout
    files = [f for f in out.decode().split("\0") if f]
    plan, bad = [], []
    for f in files:
        top = f.split("/", 1)[0]
        if top not in ROOTS:
            continue
        cls = classify(rows, f)
        if cls is None:
            bad.append(f)
            continue
        plan.append((f, os.path.join(DEST[cls], f)))
    if bad:
        print("platform-split-move: %d tracked file(s) have no inventory row:" % len(bad), file=sys.stderr)
        for f in bad[:50]:
            print("  " + f, file=sys.stderr)
        return 2
    print("platform-split-move: %d file(s) to move (%d already in place)"
          % (len(plan), sum(1 for f in files if f.split("/", 1)[0] in ("common", "platforms"))))
    if not a.dry_run:
        rewrite_gitignore(root)
    if a.dry_run:
        for s, d in plan[:20]:
            print("  %s -> %s" % (s, d))
        return 0
    # batch git mv per destination directory keeps the command line short
    for i, (s, d) in enumerate(plan):
        os.makedirs(os.path.join(root, os.path.dirname(d)), exist_ok=True)
    B = 400
    for i in range(0, len(plan), B):
        chunk = plan[i:i + B]
        # `git mv` takes one destination per call for a file, so feed pairs through update-index-free rename
        for s, d in chunk:
            subprocess.run(["git", "-C", root, "mv", "-k", s, d], check=True)
    # remove now-empty flat directories (the view recreates them)
    for r in ROOTS:
        base = os.path.join(root, r)
        if os.path.isdir(base):
            for dp, dns, fns in os.walk(base, topdown=False):
                if not os.listdir(dp) and dp != base:
                    os.rmdir(dp)
    print("platform-split-move: done; run platform-tools/platform-assemble.py to build the flat view")
    return 0


if __name__ == "__main__":
    sys.exit(main())
