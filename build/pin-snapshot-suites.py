#!/usr/bin/env python3
"""pin-snapshot-suites.py -- record/verify the signed InRelease digests for every
suite of the pinned Debian snapshot.

The provenance gate verifies the codename suite's InRelease (forky/testing) AND,
when the trust metadata declares ``di_suite`` (sid/unstable), that suite's
debian-installer InRelease -- the netinst substrate's d-i udebs are built from
sid.  Both digests must agree with the SAME pinned snapshot timestamp.

When the pin moves, ALL suite digests must move with it, or a build fails closed.
This fetches each declared suite's InRelease from snapshot.debian.org at the
pinned timestamp, verifies it against the committed keyring (gpgv), and either
rewrites the trust file's digest/size lines (default) or just checks them
(--check).  It never changes the snapshot timestamp itself unless --snapshot is
given (refresh-substrate.sh owns the pin decision).

Usage:
  build/pin-snapshot-suites.py [--check] [--snapshot TS]
Exit: 0 ok; 1 mismatch (--check) / verification failure; 2 usage/IO error.
"""
from __future__ import annotations

import argparse
import hashlib
import os
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SNAP = "https://snapshot.debian.org/archive/debian"
PIN_RE = re.compile(r"^[0-9]{8}T[0-9]{6}Z$")
TOOL_PATH = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"


def die(msg):
    print(f"pin-snapshot-suites: ERROR: {msg}", file=sys.stderr)
    sys.exit(2)


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def load_trust(path):
    kv = {}
    order = []
    for line in open(path, encoding="utf-8").read().splitlines():
        if not line.strip() or line.startswith("#"):
            continue
        if "\t" not in line:
            die(f"malformed trust line (need key<TAB>value): {line!r}")
        k, v = line.split("\t", 1)
        kv[k.strip()] = v.strip()
        order.append(k.strip())
    return kv, order


def suite_map(trust):
    """[(suite, path_key, sha_key, size_key)] for the codename + di_suite."""
    out = [(trust["codename"], "inrelease_path", "inrelease_sha256", "inrelease_size")]
    ds = trust.get("di_suite", "")
    if ds and ds != trust["codename"]:
        out.append((ds, "di_inrelease_path", "di_inrelease_sha256", "di_inrelease_size"))
    return out


def fetch_verify(snap, relpath, keyring, tmp):
    url = f"{SNAP}/{snap}/{relpath}"
    dest = os.path.join(tmp, os.path.basename(relpath) + "." + hashlib.sha1(url.encode()).hexdigest()[:8])
    try:
        with urllib.request.urlopen(url, timeout=180) as r, open(dest, "wb") as o:
            shutil.copyfileobj(r, o)
    except Exception as e:  # noqa: BLE001
        die(f"could not fetch {url}: {e}")
    gpgv = shutil.which("gpgv") or shutil.which("gpgv", path=TOOL_PATH)
    if not gpgv:
        die("gpgv not found (needed to verify the InRelease signature)")
    r = subprocess.run([gpgv, "--keyring", keyring, dest], capture_output=True, text=True,
                       env={"PATH": TOOL_PATH, "LC_ALL": "C", "LANG": "C"})
    if r.returncode != 0:
        die(f"InRelease signature verification FAILED for {url}")
    return sha256(dest), os.path.getsize(dest)


def rewrite(path, updates):
    """Replace each key<TAB>old value with key<TAB>new value; keep order."""
    out = []
    seen = set()
    for line in open(path, encoding="utf-8").read().splitlines(keepends=True):
        m = re.match(r"^([A-Za-z0-9_]+)\t", line)
        if m and m.group(1) in updates:
            k = m.group(1)
            out.append(f"{k}\t{updates[k]}\n")
            seen.add(k)
        else:
            out.append(line)
    missing = set(updates) - seen
    if missing:
        die(f"trust file {path} lacks key(s) to update: {sorted(missing)}")
    fd, tmp = tempfile.mkstemp(prefix=".ncz-trust-", dir=os.path.dirname(path))
    os.close(fd)
    try:
        with open(tmp, "w", encoding="utf-8") as o:
            o.writelines(out)
        os.replace(tmp, path)
        tmp = None
    finally:
        if tmp and os.path.exists(tmp):
            os.remove(tmp)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--snapshot", default="")
    ap.add_argument("--trust-file", default=os.path.join(ROOT, "manifests", "forky-snapshot.tsv"))
    a = ap.parse_args()

    trust, _ = load_trust(a.trust_file)
    snap = a.snapshot or trust.get("snapshot", "")
    if not PIN_RE.match(snap):
        die(f"snapshot is not a valid timestamp: {snap!r}")
    keyring = trust.get("keyring", "")
    if not os.path.isabs(keyring):
        keyring = os.path.join(ROOT, keyring)
    if not os.path.isfile(keyring):
        die(f"trust keyring missing: {keyring}")

    updates = {}
    if a.snapshot and a.snapshot != trust.get("snapshot"):
        updates["snapshot"] = snap
    rc = 0
    tmp = tempfile.mkdtemp(prefix=".ncz-suites-")
    try:
        for suite, _pk, shak, sizek in suite_map(trust):
            relpath = trust[_pk]
            got_sha, got_size = fetch_verify(snap, relpath, keyring, tmp)
            if a.check:
                if trust.get(shak) != got_sha or str(trust.get(sizek)) != str(got_size):
                    print(f"pin-snapshot-suites: MISMATCH {suite} {relpath}: "
                          f"trusted {trust.get(shak)}/{trust.get(sizek)} != "
                          f"archive {got_sha}/{got_size}", file=sys.stderr)
                    rc = 1
                else:
                    print(f"pin-snapshot-suites: OK {suite} {relpath} {got_sha[:16]}..")
            else:
                if trust.get(shak) != got_sha or str(trust.get(sizek)) != str(got_size):
                    print(f"pin-snapshot-suites: update {suite} {relpath} "
                          f"{trust.get(shak, '')[:16]}.. -> {got_sha[:16]}..")
                updates[shak] = got_sha
                updates[sizek] = str(got_size)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    if not a.check and updates:
        rewrite(a.trust_file, updates)
        print(f"pin-snapshot-suites: wrote {len(updates)} field(s) to {a.trust_file}")
    return rc


if __name__ == "__main__":
    sys.exit(main())
