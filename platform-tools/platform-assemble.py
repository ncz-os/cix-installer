#!/usr/bin/env python3
"""platform-assemble.py -- build the flat build view from common/ + platforms/<p>/.

Sources of truth live in
    common/<root>/...                      shared files
    platforms/<platform>/<root>/...        platform-unique files
for the build roots listed in ROOTS. Every builder, hook and gate in this
repository still reads the historical flat paths (post-install/, assets/,
build/, ...). This tool materializes exactly that layout, as HARD LINKS to the
source files (no copy of the 1.1 GB asset tree; a plain copy is the fallback
across filesystems), so a builder sees the same bytes at the same path it always
did. The flat directories are generated and git-ignored; edit the sources.

  --scope all            common + every platform (identical to the pre-split tree)
  --scope sky1-arm64     common + that platform only
  --scope amd64          common + that platform only
  --check                change nothing; exit 1 if the view is missing, stale or diverged
  --root DIR             repository root (default: parent of this script)

Untracked files already sitting in the flat directories (staged blobs such as
assets/cix-debs/*.deb, assets/sky1-firmware/, build outputs) are never removed:
only paths this tool created earlier (recorded in .platform-assembled) are ever
deleted. Blobs may also be staged under the source tree, where they are linked
into the view like any other file.

Exit status: 0 ok, 1 --check found a difference, 2 error (e.g. a path present in
both common/ and a platform).
"""
import argparse
import fcntl
import filecmp
import os
import shutil
import sys

ROOTS = ["post-install", "manifests", "assets", "build", "preseed", "tests", "tools",
         "scripts", "packaging", "packages", "sbom", "docker", "kernel-source"]
PLATFORMS = ["sky1-arm64", "amd64"]
STATE = ".platform-assembled"


def source_dirs(root, scope):
    plats = PLATFORMS if scope == "all" else [scope]
    out = []
    for r in ROOTS:
        out.append(("common", os.path.join(root, "common", r), r))
        for p in plats:
            out.append((p, os.path.join(root, "platforms", p, r), r))
    return out


def desired(root, scope):
    """rel path -> (owner, source path). Raises on a duplicate."""
    want = {}
    for owner, base, r in source_dirs(root, scope):
        if not os.path.isdir(base):
            continue
        for dp, dns, fns in os.walk(base):
            dns.sort()
            for fn in sorted(fns) + [d for d in dns if os.path.islink(os.path.join(dp, d))]:
                src = os.path.join(dp, fn)
                rel = os.path.join(r, os.path.relpath(src, base))
                if rel in want:
                    try:
                        if os.path.samestat(os.lstat(src), os.lstat(want[rel][1])):
                            continue
                    except OSError:
                        pass
                    raise SystemExit("platform-assemble: %s exists in both %s and %s" % (rel, want[rel][0], owner))
                want[rel] = (owner, src)
    return want


def same(a, b):
    try:
        if os.path.islink(a) or os.path.islink(b):
            return os.path.islink(a) and os.path.islink(b) and os.readlink(a) == os.readlink(b)
        sa, sb = os.stat(a), os.stat(b)
        if (sa.st_dev, sa.st_ino) == (sb.st_dev, sb.st_ino):
            return True
        return sa.st_size == sb.st_size and filecmp.cmp(a, b, shallow=False)
    except OSError:
        return False


def linked(a, b):
    try:
        if os.path.islink(a) or os.path.islink(b):
            return same(a, b)
        sa, sb = os.stat(a), os.stat(b)
        return (sa.st_dev, sa.st_ino) == (sb.st_dev, sb.st_ino)
    except OSError:
        return False


def read_state(root):
    p = os.path.join(root, STATE)
    if not os.path.exists(p):
        return []
    return [l.rstrip("\n") for l in open(p) if l.strip() and not l.startswith("#")]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--scope", default=os.environ.get("NCZ_ASSEMBLE_SCOPE", "all"),
                    choices=["all"] + PLATFORMS)
    ap.add_argument("--root", default=os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--quiet", action="store_true")
    a = ap.parse_args()
    root = os.path.abspath(a.root)
    lockf = open(os.path.join(root, STATE + ".lock"), "w")
    fcntl.flock(lockf, fcntl.LOCK_EX)
    want = desired(root, a.scope)
    old = read_state(root)
    stale = [p for p in old if p not in want]
    problems = 0
    made = kept = overwritten = 0

    for rel in sorted(want):
        owner, src = want[rel]
        dst = os.path.join(root, rel)
        if os.path.lexists(dst) and linked(src, dst):
            kept += 1
            continue
        if a.check:
            print("platform-assemble: view differs at %s" % rel, file=sys.stderr)
            problems += 1
            continue
        if os.path.lexists(dst):
            if os.path.isdir(dst) and not os.path.islink(dst):
                raise SystemExit("platform-assemble: %s is a directory in the view but a file in the source; remove it by hand" % rel)
            if not same(src, dst):
                overwritten += 1
                if not a.quiet:
                    print("platform-assemble: WARN replacing %s with its source (content differed)" % rel, file=sys.stderr)
            os.unlink(dst)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        if os.path.islink(src):
            os.symlink(os.readlink(src), dst)
        else:
            try:
                os.link(src, dst)
            except OSError:
                shutil.copy2(src, dst)
                print("platform-assemble: WARN %s was COPIED (hard link failed); source edits will not show until the next assemble" % rel, file=sys.stderr)
        made += 1

    for rel in stale:
        dst = os.path.join(root, rel)
        if a.check:
            if os.path.lexists(dst):
                print("platform-assemble: stale view file %s" % rel, file=sys.stderr)
                problems += 1
            continue
        if os.path.lexists(dst):
            os.unlink(dst)
        d = os.path.dirname(dst)
        while os.path.abspath(d) != root and os.path.isdir(d) and not os.listdir(d) \
                and os.path.relpath(d, root) not in ROOTS:
            os.rmdir(d)
            d = os.path.dirname(d)

    if a.check:
        if problems:
            print("platform-assemble: %d difference(s); run platform-tools/platform-assemble.py --scope %s" % (problems, a.scope), file=sys.stderr)
            return 1
        if not a.quiet:
            print("platform-assemble: view OK (scope %s, %d files)" % (a.scope, len(want)))
        return 0

    tmp = os.path.join(root, STATE + ".tmp.%d" % os.getpid())
    with open(tmp, "w") as f:
        f.write("# generated by platform-tools/platform-assemble.py; scope=%s\n" % a.scope)
        for rel in sorted(want):
            f.write(rel + "\n")
    os.replace(tmp, os.path.join(root, STATE))
    if not a.quiet:
        print("platform-assemble: scope %s: %d linked, %d already current, %d replaced, %d stale removed"
              % (a.scope, made, kept, overwritten, len(stale)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
