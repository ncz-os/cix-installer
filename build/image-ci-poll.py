#!/usr/bin/env python3
"""Image CI poller: what would a rebuild, and what was the last value seen.

Five triggers, each with a poll source, a value remembered in a state file, and
a named rebuild. The matrix printed by --matrix comes from the same table the
poller uses, so the document cannot drift from the code.

TRIGGERS
  forky-pin      snapshot.debian.org's newest archive stamp   -> image, both arches
  kernel-stable  kernel.org releases.json, stable 7.x tag      -> kernel debs, then images
  kernel-rc      kernel.org releases.json, mainline (rc) tag   -> kernel debs (preview)
  singularity    singularityos-lab HEAD + newest tag           -> singularity debs, then images
  ncz-debs       NCZ apt index sha256 (per arch)               -> image assemble only

The NCZ suite is whatever the image actually consumes, which today is the R2
mirror named in release.conf (NCZ_R2_BASE). Point --apt-base elsewhere to poll
the publisher's reprepro instead; the state key changes with it so values from
two different repos are never confused.

Dry run is the default: nothing is written unless --update-state is passed, and
that flag exists for the CI job, not for a headless cycle.

Usage:
  image-ci-poll.py                 # dry run, human readable
  image-ci-poll.py --matrix        # the trigger matrix
  image-ci-poll.py --json          # dry run, machine readable
  image-ci-poll.py --update-state  # record what a real run saw
  image-ci-poll.py --self-test     # parse fixtures, no network
"""
import argparse
import gzip
import json
import os
import re
import subprocess
import sys
import urllib.request

SNAPSHOT_LIST = "https://snapshot.debian.org/archive/debian/"
KERNEL_RELEASES = "https://www.kernel.org/releases.json"
SINGULARITY_GIT = "https://github.com/singularityos-lab/singularity-desktop.git"
DEFAULT_APT_BASE = ("https://pub-d7b784e01679403d9c70fcd23fff5b96.r2.dev"
                    "/dists/any")
STATE_DEFAULT = os.path.expanduser("~/.cache/ncz-image-ci/state.json")
TIMEOUT = 25

# name, poll source description, state key, rebuilds
MATRIX = [
    ("forky-pin", "daily pin resolve output (snapshot.debian.org listing is JS)", "forky.stamp",
     "image, amd64 + arm64 (base pins change)"),
    ("kernel-stable", "kernel.org releases.json, newest stable 7.x",
     "kernel.stable", "kernel debs (both arches), then the images"),
    ("kernel-rc", "kernel.org releases.json, mainline (rc) tag",
     "kernel.rc", "kernel debs for the rc (preview), no image promotion"),
    ("singularity", "singularityos-lab HEAD + newest tag",
     "singularity.head", "singularity debs, then the images"),
    ("ncz-debs", "NCZ apt index sha256 per arch",
     "ncz.index.<arch>.<repo>", "image assemble only (no source rebuild)"),
]


def fetch(url, timeout=TIMEOUT):
    req = urllib.request.Request(url, headers={"User-Agent": "ncz-image-ci-poll/1"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        raw = resp.read()
    if url.endswith(".gz"):
        return gzip.decompress(raw).decode("utf-8", "replace")
    return raw.decode("utf-8", "replace")


def parse_snapshot_stamp(html):
    """Newest stamp on snapshot.debian.org's archive listing."""
    stamps = re.findall(r"(?<!\d)(\d{8}T\d{6}Z)(?!\d)", html)
    return max(stamps) if stamps else None


def parse_kernel_releases(doc):
    """Return (newest stable 7.x version, mainline rc version) from releases.json."""
    try:
        data = json.loads(doc)
    except Exception:
        return None, None
    stable = None
    rc = None
    for rel in data.get("releases", []):
        moniker = (rel.get("moniker") or "").strip()
        ver = (rel.get("version") or "").strip()
        if not ver:
            continue
        if moniker == "stable" and re.match(r"^7\.", ver):
            if stable is None or numeric_key(ver) > numeric_key(stable):
                stable = ver
        elif moniker == "mainline":
            rc = ver
    return stable, rc


def numeric_key(text):
    """All digit runs of a version or tag, as integers: 0.10 > 0.9, 1.0.1 > 1.0."""
    nums = re.findall(r"\d+", text)
    return tuple(int(n) for n in nums) if nums else (0,)


def version_key(v):
    """Numeric key for a kernel version like 7.3.1 or 7.4.0-rc2.

    A release outranks any rc of the same version: 7.4.0 > 7.4.0-rc9.
    """
    m = re.match(r"^(\d+)\.(\d+)(?:\.(\d+))?(?:-rc(\d+))?", v)
    if not m:
        return (0, 0, 0, 0, 0)
    a, b, c, rc = m.groups()
    # a release outranks any rc of the same version: 7.4.0 > 7.4.0-rc9
    return (int(a), int(b), int(c) if c else 0, 0 if rc else 1, int(rc) if rc else 0)


def parse_apt_release(doc):
    """Return {arch: sha256-of-Packages} from a Release file's SHA256 block."""
    out = {}
    in_sha = False
    for line in doc.splitlines():
        if line.strip() == "SHA256:":
            in_sha = True
            continue
        if in_sha:
            if not line.startswith(" "):
                if line.strip():
                    break
                continue
            m = re.match(r"\s*([0-9a-f]{64})\s+\d+\s+main/binary-(\w+)/Packages$",
                         line)
            if m:
                out[m.group(2)] = m.group(1)
    return out


def singularity_state():
    """HEAD sha of the pinned git, newest tag, via git ls-remote (no API limit)."""

    def ls(*args):
        try:
            out = subprocess.run(["git", "ls-remote", SINGULARITY_GIT] + list(args),
                                 capture_output=True, text=True, timeout=60)
            return out.stdout
        except Exception as exc:
            return "ERROR %s" % exc

    head_txt = ls("HEAD")
    head = head_txt.split()[0][:12] if head_txt.strip() and "ERROR" not in head_txt else None
    tags_txt = ls("--tags")
    tags = []
    for line in tags_txt.splitlines():
        parts = line.split()
        if len(parts) < 2:
            continue
        ref = parts[1]
        if ref.endswith("^{}"):
            continue
        tags.append((numeric_key(ref.rsplit("/", 1)[-1]), ref))
    newest = max(tags)[1] if tags else None
    return head, newest


def apt_tag(apt_base):
    """Short, stable tag for a repo URL, so two repos never share state keys."""
    import hashlib
    return hashlib.sha256(apt_base.rstrip("/").encode()).hexdigest()[:8]


def probe(apt_base):
    """Poll every source. Returns {state_key: (value, detail)}; value None on error."""
    seen = {}

    # snapshot.debian.org's archive listing is rendered client-side, so the
    # newest stamp is not scrapeable. The poll source is our own resolver: the
    # daily job records the stamp it would pin, and this compares it.
    try:
        with open(os.environ.get("NCZ_IMAGE_CI_FORKY_STATE",
                                 os.path.expanduser("~/.cache/ncz-image-ci/forky-resolve.json")),
                  encoding="utf-8") as fh:
            doc = json.load(fh)
        seen["forky.stamp"] = (doc.get("newest_stamp"), "daily resolve output")
    except Exception as exc:
        seen["forky.stamp"] = (None, "needs the daily resolve: %s" % exc)

    try:
        stable, rc = parse_kernel_releases(fetch(KERNEL_RELEASES))
        seen["kernel.stable"] = (stable, "releases.json stable")
        seen["kernel.rc"] = (rc, "releases.json mainline")
    except Exception as exc:
        seen["kernel.stable"] = (None, "error: %s" % exc)
        seen["kernel.rc"] = (None, "error: %s" % exc)

    try:
        head, tag = singularity_state()
        seen["singularity.head"] = (head, "ls-remote HEAD")
        seen["singularity.head.tag"] = (tag, "ls-remote newest tag")
    except Exception as exc:
        seen["singularity.head"] = (None, "error: %s" % exc)

    try:
        tag = apt_tag(apt_base)
        shas = parse_apt_release(fetch(apt_base.rstrip("/") + "/Release"))
        for arch in ("amd64", "arm64"):
            seen["ncz.index.%s.%s" % (arch, tag)] = (
                shas.get(arch), "%s main/binary-%s/Packages" % (apt_base, arch))
    except Exception as exc:
        for arch in ("amd64", "arm64"):
            seen["ncz.index.%s.%s" % (arch, tag)] = (None, "error: %s" % exc)

    return seen


def decide(matrix, prev, seen, apt_base=""):
    """Map the matrix rows to verdicts. A trigger fires when its value moved."""
    rows = []
    for name, source, key, rebuilds in matrix:
        if name == "singularity":
            now, how = seen.get("singularity.head", (None, "not polled"))
            tag, _ = seen.get("singularity.head.tag", (None, ""))
            was = prev.get("singularity.head")
            if now is None:
                verdict = "unknown (poll failed)"
            elif was is None:
                verdict = "first run (no state)"
            elif now != was:
                verdict = "WOULD TRIGGER"
            else:
                verdict = "no change"
            rows.append((name, source, "%s%s" % (now, (" tag=" + tag) if tag else ""),
                         verdict, rebuilds))
            continue
        if name == "ncz-debs":
            tag = apt_tag(apt_base) if apt_base else ""
            keys = ["ncz.index.%s.%s" % (a, tag) for a in ("amd64", "arm64")]
            now_parts = [seen.get(k, (None, ""))[0] for k in keys]
            was_parts = [prev.get(k) for k in keys]
            now = "+".join((p or "?")[:12] for p in now_parts)
            if any(p is None for p in now_parts):
                verdict = "unknown (poll failed)"
            elif any(w is None for w in was_parts):
                verdict = "first run (no state)"
            elif now_parts != was_parts:
                verdict = "WOULD TRIGGER"
            else:
                verdict = "no change"
            rows.append((name, source, now, verdict, rebuilds))
            continue
        now, how = seen.get(key, (None, "not polled"))
        was = prev.get(key)
        if now is None:
            verdict = "unknown (poll failed)"
        elif was is None:
            verdict = "first run (no state)"
        elif now != was:
            verdict = "WOULD TRIGGER"
        else:
            verdict = "no change"
        rows.append((name, source, now, verdict, rebuilds))
    return rows


def matrix_table():
    rows = [("trigger", "poll source", "state key", "what it rebuilds")]
    rows += [(n, s, k, r) for n, s, k, r in MATRIX]
    widths = [max(len(str(r[i])) for r in rows) for i in range(4)]
    out = []
    for idx, row in enumerate(rows):
        out.append("| " + " | ".join(str(row[i]).ljust(widths[i])
                                    for i in range(4)) + " |")
        if idx == 0:
            out.append("|" + "|".join("-" * (w + 2) for w in widths) + "|")
    return "\n".join(out)


def self_test():
    """Fixtures for every parser; no network."""
    ok = True

    def check(label, got, want):
        nonlocal ok
        if got != want:
            ok = False
            print("  FAIL  %s: got %r want %r" % (label, got, want))

    html = ('<a href="?20261105T120000Z">x</a> <a href="?20261102T082611Z">y</a> '
            '<a href="?20261104T000000Z">z</a>')
    check("newest snapshot stamp", parse_snapshot_stamp(html), "20261105T120000Z")
    check("no stamp", parse_snapshot_stamp("nothing here"), None)

    doc = json.dumps({"releases": [
        {"moniker": "stable", "version": "7.3.4"},
        {"moniker": "stable", "version": "7.2.9"},
        {"moniker": "stable", "version": "6.19.2"},
        {"moniker": "mainline", "version": "7.4.0-rc2"},
        {"moniker": "longterm", "version": "7.1.11"},
    ]})
    stable, rc = parse_kernel_releases(doc)
    check("newest stable 7.x", stable, "7.3.4")
    check("mainline rc", rc, "7.4.0-rc2")

    release = (
        "Origin: NCZ-OS\nSHA256:\n"
        " 1ecc2db7ea43ae06de92f56a1c1ad2dd0c163b11748116919eec52a0392e75b8 55522 main/binary-arm64/Packages\n"
        " 9b4fc34d7f7382051f3b48dfc36b6ea2" + "0"*32 + " 34182 main/binary-amd64/Packages\n"
        "SHA1:\n"
    )
    check("apt index shas",
          parse_apt_release(release),
          {"arm64": "1ecc2db7ea43ae06de92f56a1c1ad2dd0c163b11748116919eec52a0392e75b8",
           "amd64": "9b4fc34d7f7382051f3b48dfc36b6ea2" + "0"*32})

    check("version key ordering", version_key("7.10.1") > version_key("7.9.9"), True)
    check("tag ordering 0.10 > 0.9", numeric_key("v0.10.0") > numeric_key("v0.9.0"), True)
    check("different repos never share a state key",
          apt_tag("https://a/dists/any") != apt_tag("https://b/dists/any"), True)

    prev = {"forky.stamp": "20261102T082611Z", "kernel.stable": "7.3.4"}
    seen = {"forky.stamp": ("20261105T120000Z", ""),
            "kernel.stable": ("7.3.4", ""),
            "kernel.rc": (None, ""),
            "singularity.head": (None, ""),
            "ncz.index.amd64": (None, ""), "ncz.index.arm64": (None, "")}
    rows = decide(MATRIX, prev, seen, "https://example.invalid/dists/any")
    verdicts = {r[0]: r[3] for r in rows}
    check("forky moved", verdicts["forky-pin"], "WOULD TRIGGER")
    check("kernel stable same", verdicts["kernel-stable"], "no change")
    check("unknown reported", verdicts["kernel-rc"], "unknown (poll failed)")

    if ok:
        print("self-test: parsers and decisions agree with the fixtures -- good")
        return 0
    return 1


def load_state(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except Exception:
        return {}


def save_state(path, state):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(state, fh, indent=2, sort_keys=True)
        fh.write("\n")
    os.replace(tmp, path)


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--state", default=STATE_DEFAULT)
    ap.add_argument("--apt-base", default=os.environ.get("NCZ_R2_BASE", DEFAULT_APT_BASE))
    ap.add_argument("--update-state", action="store_true")
    ap.add_argument("--matrix", action="store_true")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args(argv)

    if args.self_test:
        return self_test()
    if args.matrix:
        print(matrix_table())
        return 0

    prev = load_state(args.state)
    seen = probe(args.apt_base)
    rows = decide(MATRIX, prev, seen, args.apt_base)

    if args.json:
        print(json.dumps({"apt_base": args.apt_base,
                          "state_file": args.state,
                          "dry_run": not args.update_state,
                          "rows": [{"trigger": r[0], "source": r[1],
                                    "value": r[2], "verdict": r[3],
                                    "rebuilds": r[4]} for r in rows]}, indent=2))
    else:
        print("image-ci poll (dry run: %s)" % ("no, --update-state" if args.update_state else "yes, state untouched"))
        print("state: %s" % args.state)
        print("apt:   %s" % args.apt_base)
        print()
        for name, source, value, verdict, rebuilds in rows:
            print("%-14s %-46s %s" % (name, value if value else "-", verdict))
            if verdict.startswith("unknown"):
                detail = ""
                if name == "forky-pin":
                    detail = seen.get("forky.stamp", ("", ""))[1]
                elif name == "singularity":
                    detail = seen.get("singularity.head", ("", ""))[1]
                elif name == "ncz-debs":
                    detail = seen.get("ncz.index.amd64." + apt_tag(args.apt_base),
                                      ("", ""))[1]
                if detail:
                    print("%-14s   (%s)" % ("", detail))
            if "TRIGGER" in verdict:
                print("%-14s   -> rebuilds %s" % ("", rebuilds))

    if args.update_state:
        new_state = dict(prev)
        for key, (value, _detail) in seen.items():
            if value is not None:
                new_state[key] = value
        if seen.get("singularity.head.tag", (None,))[0]:
            new_state["singularity.head.tag"] = seen["singularity.head.tag"][0]
        save_state(args.state, new_state)
        print("\nstate written: %s" % args.state)
    return 0


if __name__ == "__main__":
    sys.exit(main())
