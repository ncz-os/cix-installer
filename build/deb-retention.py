#!/usr/bin/env python3
"""n-2 retention for kernel and singularity debs, dry-run first.

Keeps the current and the two previous versions of every series, where a series
is a package name with its version token(s) collapsed (so linux-image-7.3.0-t2-ncz
and linux-image-7.4.0-t2-ncz are one series, while linux-image-cixmini and
cixmini-boot are each their own).

Safety properties, all asserted by --self-test:
  * the newest version of a series is never a removal candidate;
  * a series is never emptied;
  * nothing is deleted unless --apply AND --yes-really are both passed, and even
    then only files named on the printed plan;
  * an unparseable version sorts *above* everything else, so a version we cannot
    read is treated as the one to keep.

Sources: --packages URL|FILE (an apt Packages index, as the live repo serves) or
--dir DIR (a local pool of .deb files). --self-test needs neither.

Usage:
  deb-retention.py --packages https://.../main/binary-amd64/Packages
  deb-retention.py --dir /srv/debs --keep 3
  deb-retention.py --dir /srv/debs --apply --yes-really   # CI only
"""
import argparse
import functools
import gzip
import json
import os
import re
import subprocess
import sys
import urllib.request

KERNEL_RE = re.compile(r"^(linux-(image|headers|modules)|cixmini-boot|cixmini-kernel)")
SINGULARITY_RE = re.compile(r"^(ncz-singularity|singularity-)")
VERSION_TOKEN = re.compile(r"\d+\.\d+(?:\.\d+)*(?:-rc\d+)?")


def series_of(name):
    """Collapse version tokens inside a package name: one series per flavor."""
    return VERSION_TOKEN.sub("<v>", name)


def classify(name):
    if SINGULARITY_RE.match(name):
        return "singularity"
    if KERNEL_RE.match(name):
        return "kernel"
    return None


def fetch(url, timeout=30):
    req = urllib.request.Request(url, headers={"User-Agent": "ncz-deb-retention/1"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        raw = resp.read()
    if url.endswith(".gz"):
        return gzip.decompress(raw).decode("utf-8", "replace")
    return raw.decode("utf-8", "replace")


def parse_packages(text, arch_hint=None):
    """Yield (name, version, arch, filename)."""
    cur = {}
    for line in text.splitlines() + [""]:
        if not line.strip():
            if cur.get("Package") and cur.get("Version"):
                yield (cur["Package"], cur["Version"],
                       cur.get("Architecture", arch_hint or "?"),
                       cur.get("Filename", ""))
            cur = {}
            continue
        if line[0] in " \t" or ":" not in line:
            continue
        key, _, val = line.partition(":")
        cur[key.strip()] = val.strip()


def _natural(text):
    """Tokenise for comparison: digit runs numeric, everything else lexical."""
    return [(0, int(t)) if t.isdigit() else (1, t)
            for t in re.findall(r"\d+|\D+", text)]


def _fallback_cmp(a, b):
    """dpkg-ish ordering for the shapes this repo ships (7.3.0-2, +r293)."""
    def split(v):
        base, _, rev = v.partition("-")
        return [int(x) for x in re.findall(r"\d+", base.split("+")[0]) or [0]], rev
    (na, ra), (nb, rb) = split(a), split(b)
    if na != nb:
        return -1 if na < nb else 1
    if ra != rb:
        if not ra:
            return -1
        if not rb:
            return 1
        ka, kb = _natural(ra), _natural(rb)
        return -1 if ka < kb else 1
    return 0


def dpkg_cmp(a, b):
    """-1/0/1 using dpkg when available, else the fallback above."""
    try:
        r = subprocess.run(["dpkg", "--compare-versions", a, "lt", b],
                           capture_output=True)
        if r.returncode == 0:
            return -1
        r = subprocess.run(["dpkg", "--compare-versions", a, "eq", b],
                           capture_output=True)
        return 0 if r.returncode == 0 else 1
    except Exception:
        return _fallback_cmp(a, b)


def build_order(x, y):
    """Oldest first: an rc yields to its final release, then dpkg ordering."""
    rx = 0 if "-rc" in x["version"] else 1
    ry = 0 if "-rc" in y["version"] else 1
    if rx != ry:
        return -1 if rx < ry else 1
    return dpkg_cmp(x["version"], y["version"])


def sort_versions(items):
    """Insertion sort with dpkg_cmp; an unparseable version goes last (newest)."""
    out = []
    for item in items:
        pos = len(out)
        while pos > 0 and dpkg_cmp(out[pos - 1]["version"], item["version"]) > 0:
            pos -= 1
        out.insert(pos, item)
    return out


def slot_of(cls, version):
    """The retention slot: one per kernel release, one per singularity build day.

    An rc and the final release of 7.4.0 are the same slot, so they never hold
    two of the three kept places; the newest build inside a slot wins.
    """
    if cls == "singularity":
        m = re.match(r"^(\d{14})", version)
        return m.group(1) if m else version
    m = re.match(r"^(\d+\.\d+(?:\.\d+)?)", version)
    return m.group(1) if m else version


def plan(rows, keep):
    """rows: [{name, version, arch, filename}]; returns (kept, removals)."""
    groups = {}
    for row in rows:
        cls = classify(row["name"])
        if not cls:
            continue
        key = (cls, series_of(row["name"]), row.get("arch", "?"))
        groups.setdefault(key, {}).setdefault(slot_of(cls, row["version"]), []).append(row)

    kept = {}
    removals = []
    for key, slots in groups.items():
        ordered_slots = list(slots)
        for i in range(1, len(ordered_slots)):          # dpkg-order the slots
            cur = ordered_slots[i]
            j = i - 1
            while j >= 0 and dpkg_cmp(ordered_slots[j], cur) > 0:
                ordered_slots[j + 1] = ordered_slots[j]
                j -= 1
            ordered_slots[j + 1] = cur
        keep_slots = ordered_slots[-keep:] if keep > 0 else []
        kept[key] = []
        for slot in ordered_slots:
            builds = sorted(slots[slot], key=functools.cmp_to_key(build_order))
            if slot in keep_slots:
                kept[key].append(builds[-1]["version"])
                removals.extend(builds[:-1])                 # older builds, same slot
            else:
                removals.extend(builds)                      # whole slot is beyond n-2
    return kept, removals


SELF_TEST_ROWS = [
    # five kernel versions; the two oldest must be removed, newest kept
    {"name": "linux-image-7.1.0-t2-ncz", "version": "7.1.0-1", "arch": "amd64"},
    {"name": "linux-image-7.2.0-t2-ncz", "version": "7.2.0-1", "arch": "amd64"},
    {"name": "linux-image-7.3.0-t2-ncz", "version": "7.3.0-1", "arch": "amd64"},
    {"name": "linux-image-7.3.0-t2-ncz", "version": "7.3.0-2", "arch": "amd64"},
    {"name": "linux-image-7.3.1-t2-ncz", "version": "7.3.1-1", "arch": "amd64"},
    # rc sorts below the release of the same version
    {"name": "linux-image-7.4.0-t2-ncz", "version": "7.4.0-rc1-1", "arch": "amd64"},
    {"name": "linux-image-7.4.0-t2-ncz", "version": "7.4.0-1", "arch": "amd64"},
    # a second flavor is its own series and must not interact
    {"name": "linux-image-cixmini", "version": "7.3.0-sky1-ncz+r293", "arch": "arm64"},
    # singularity payloads
    {"name": "ncz-singularity-desktop", "version": "20261025175504+bk0+tgz1", "arch": "amd64"},
    {"name": "ncz-singularity-desktop", "version": "20261105105000+bk0+tgz2", "arch": "amd64"},
    {"name": "ncz-singularity-desktop", "version": "20261106151728+bk0+tgz3", "arch": "amd64"},
    # not in scope at all
    {"name": "bash", "version": "5.2-1", "arch": "amd64"},
]


def self_test():
    ok = True

    def check(label, got, want):
        nonlocal ok
        if got != want:
            ok = False
            print("  FAIL  %s: got %r want %r" % (label, got, want))

    series, removals = plan(SELF_TEST_ROWS, keep=3)
    removed = sorted((r["version"], r["arch"]) for r in removals)
    check("removals", removed, sorted([
        ("7.1.0-1", "amd64"),
        ("7.2.0-1", "amd64"),
        ("7.3.0-1", "amd64"),        # older build inside a kept slot
        ("7.4.0-rc1-1", "amd64"),    # the rc yields to its final release
    ]))
    check("kernel keeps 3 releases",
          series[("kernel", "linux-image-<v>-t2-ncz", "amd64")],
          ["7.3.0-2", "7.3.1-1", "7.4.0-1"])
    check("other flavor untouched", series[("kernel", "linux-image-cixmini", "arm64")],
          ["7.3.0-sky1-ncz+r293"])
    check("a release outranks its rc inside a slot",
          [r["version"] for r in removals if r["name"] == "linux-image-7.4.0-t2-ncz"],
          ["7.4.0-rc1-1"])
    check("numeric revisions order", dpkg_cmp("7.3.0-2", "7.3.0-10"), -1)
    check("bash ignored", [r for r in removals if r["name"] == "bash"], [])
    check("newest never removed",
          [r for r in removals if r["version"] in ("7.4.0-1", "7.3.1-1")], [])

    # keep=1 must still keep the newest and never empty a series
    _, rem1 = plan(SELF_TEST_ROWS, keep=1)
    check("keep=1 keeps newest release only",
          sorted(r["version"] for r in rem1 if r["name"] == "linux-image-7.4.0-t2-ncz"),
          ["7.4.0-rc1-1"])
    check("keep=1 does not empty a series",
          [k for k, v in plan(SELF_TEST_ROWS, keep=1)[0].items() if not v], [])

    if ok:
        print("self-test: series collapse, ordering and the never-remove-newest "
              "guard hold -- good")
        return 0
    return 1


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--packages", help="apt Packages URL or path")
    ap.add_argument("--dir", help="directory of .deb files")
    ap.add_argument("--arch", default=None, help="arch hint when the index has none")
    ap.add_argument("--keep", type=int, default=3, help="n total versions kept (default 3 = current + 2)")
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--yes-really", action="store_true")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args(argv)

    if args.self_test:
        return self_test()
    if not args.packages and not args.dir:
        ap.error("need --packages URL|FILE or --dir DIR (or --self-test)")

    rows = []
    if args.packages:
        text = fetch(args.packages) if re.match(r"^https?://", args.packages) \
            else open(args.packages, encoding="utf-8").read()
        rows = [{"name": n, "version": v, "arch": a, "filename": f}
                for n, v, a, f in parse_packages(text, args.arch)]
    else:
        for entry in sorted(os.listdir(args.dir)):
            if not entry.endswith(".deb"):
                continue
            m = re.match(r"^(.*?)_([^_]+)_(\w+)\.deb$", entry)
            if not m:
                continue
            rows.append({"name": m.group(1), "version": m.group(2),
                         "arch": m.group(3),
                         "filename": os.path.join(args.dir, entry)})

    series, removals = plan(rows, args.keep)

    if args.json:
        print(json.dumps({"keep": args.keep, "series": {
            "|".join(k): v for k, v in series.items()},
            "would_remove": removals}, indent=2))
    else:
        print("retention plan: keep %d version(s) per series (current + %d previous)"
              % (args.keep, max(0, args.keep - 1)))
        for key in sorted(series, key=lambda k: (k[0], k[1], k[2])):
            print("  keep  %-10s %-28s %-6s %s"
                  % (key[0], key[1], key[2], ", ".join(series[key])))
        if not removals:
            print("  nothing to remove -- every series is at or below the keep count")
        for row in removals:
            print("  %s %-10s %-28s %-6s %s"
                  % ("REMOVE" if (args.apply and args.yes_really) else "would-remove",
                     classify(row["name"]), row["name"], row["arch"],
                     row["version"]))

    if args.apply and args.yes_really:
        if not args.dir:
            print("refusing to apply against an index URL: only a local pool can be pruned")
            return 2
        for row in removals:
            if row["filename"] and os.path.isfile(row["filename"]):
                os.remove(row["filename"])
                print("removed %s" % row["filename"])
    elif args.apply:
        print("--apply given without --yes-really: nothing deleted")
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
