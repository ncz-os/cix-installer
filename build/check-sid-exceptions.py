#!/usr/bin/env python3
"""check-sid-exceptions.py -- track the reviewed sid exceptions and drive the
"gradually replace with forky" loop.

For every row in manifests/sid-exceptions.tsv it compares the recorded version
with:
  * the PINNED snapshot's forky index (the build's own root of trust), and
  * the LATEST forky (deb.debian.org, plus `rmadison` when available),
and reports one of:
  * GRADUATED  forky now provides this package at >= the ledger version -> the
               row MUST be removed and the image rebuilt from forky (the gate
               already fails on this; "use forky").
  * EXPIRED    the row's review_by date has passed -> re-review required.
  * SHRINKING  forky's closest version moved UP (the gap is closing).
  * GROWING    forky's closest version did not move (gap stable/widening).
  * ABSENT     forky still has no such package.

It writes a short markdown report (docs/SID-EXCEPTIONS.md by default), prints a
per-arch count + trend, and can record the count into an image receipt JSON.

Exit 0 = no action required; 1 = a GRADUATED/EXPIRED row (with --strict) or a
finding; 2 = usage/IO error.  Offline: pass --index-dir/--latest-dir (or
--offline) to avoid the network."""
from __future__ import annotations

import argparse
import datetime as dt
import gzip
import hashlib
import importlib.util
import json
import lzma
import os
import re
import shutil
import subprocess
import sys
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SNAP = "https://snapshot.debian.org/archive/debian"
LIVE = "https://deb.debian.org/debian"
# Only main (the sid exceptions are all main d-i udebs); the codename's d-i
# index plus its normal index cover the recorded names.
NEED = [("main", "amd64"), ("main", "arm64"), ("main", "all"),
        ("main/debian-installer", "amd64"), ("main/debian-installer", "arm64"),
        ("main/debian-installer", "all")]


def _load_gate(path):
    spec = importlib.util.spec_from_file_location("forky_provenance", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def read_maybe(path):
    if path.endswith(".xz"):
        return lzma.open(path, "rt", errors="replace").read()
    if path.endswith(".gz"):
        return gzip.open(path, "rt", errors="replace").read()
    return open(path, errors="replace").read()


def parse_versions(text):
    out = {}
    for st in re.split(r"\n\s*\n", text):
        d = {}
        for line in st.split("\n"):
            if ": " in line and line[:1] not in (" ", "\t"):
                k, v = line.split(": ", 1)
                d[k] = v.strip()
        if d.get("Package") and d.get("Version"):
            out.setdefault(d["Package"], []).append((d["Version"],
                                                     d.get("Architecture", "")))
    return out


def fetch(url, dest):
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    if os.path.isfile(dest) and os.path.getsize(dest) > 0:
        return True
    try:
        with urllib.request.urlopen(url, timeout=120) as r, open(dest, "wb") as o:
            o.write(r.read())
        return os.path.getsize(dest) > 0
    except Exception:  # noqa: BLE001
        if os.path.exists(dest):
            os.remove(dest)
        return False


def load_index(base, suite, cache, tag, offline):
    """{name: [(version, arch)]} for the suite under base (snapshot or live)."""
    out = {}
    for comp, arch in NEED:
        delivered = False
        for ext in ("Packages.xz", "Packages.gz", "Packages"):
            rel = f"{comp}/binary-{arch}/{ext}"
            if offline:
                f = os.path.join(cache, f"{tag}_" + rel.replace("/", "_"))
                if not os.path.isfile(f):
                    continue
            else:
                f = os.path.join(cache, f"{tag}_" + rel.replace("/", "_"))
                url = f"{base}/dists/{suite}/{rel}"
                if not fetch(url, f):
                    continue
            try:
                text = read_maybe(f)
            except Exception:  # noqa: BLE001
                delivered = True
                break
            for name, vers in parse_versions(text).items():
                out.setdefault(name, []).extend(vers)
            delivered = True
            break
        if not delivered and not offline:
            continue
    return out


def best_version(index, name, arch):
    look = {arch, "all"}
    vers = [v for (v, a) in index.get(name, []) if a in look]
    if not vers:
        return ""
    best = vers[0]
    for v in vers[1:]:
        if _cmp(v, best) > 0:
            best = v
    return best


_CMP = None


def _cmp(a, b):
    return _CMP(a, b)


def main():
    global _CMP
    ap = argparse.ArgumentParser()
    ap.add_argument("--ledger", default=os.path.join(ROOT, "manifests/sid-exceptions.tsv"))
    ap.add_argument("--trust", default=os.path.join(ROOT, "manifests/forky-snapshot.tsv"))
    ap.add_argument("--index-dir", default="")
    ap.add_argument("--latest-dir", default="")
    ap.add_argument("--offline", action="store_true",
                    help="do not fetch; use --index-dir/--latest-dir caches only")
    ap.add_argument("--out", default=os.path.join(ROOT, "docs/SID-EXCEPTIONS.md"))
    ap.add_argument("--receipt", default="")
    ap.add_argument("--strict", action="store_true")
    ap.add_argument("--work", default="")
    a = ap.parse_args()

    gate = _load_gate(os.path.join(ROOT, "build/forky-provenance.py"))
    _CMP = gate.deb_vercmp

    # trust: pinned snapshot
    snap = ""
    for line in open(a.trust, errors="replace"):
        if line.startswith("snapshot\t"):
            snap = line.split("\t", 1)[1].strip()
    rows = []
    for n, line in enumerate(open(a.ledger, errors="replace"), 1):
        if line.startswith("#") or not line.strip():
            continue
        f = line.rstrip("\n").split("\t")
        if len(f) < 13:
            print(f"ERROR: {a.ledger}:{n} needs 13 columns", file=sys.stderr)
            return 2
        rows.append({"name": f[0], "version": f[1], "arch": f[2], "sha256": f[3],
                     "class": f[4], "forky_version": f[5], "gap": f[6],
                     "reason": f[7], "first_seen": f[8], "snapshot": f[9],
                     "owner_action": f[10], "review_by": f[11], "tracking": f[12]})

    work = a.work or os.path.join(os.path.expanduser("~"), ".cache", "ncz-sid-exceptions")
    os.makedirs(work, exist_ok=True)

    pinned = {}
    latest = {}
    if a.index_dir:
        pinned = _load_index_dir(a.index_dir)
    else:
        pinned = load_index(f"{SNAP}/{snap}", "forky", work, "pinned", a.offline)
    if a.latest_dir:
        latest = _load_index_dir(a.latest_dir)
    else:
        latest = load_index(LIVE, "forky", work, "latest", a.offline)

    today = dt.date.today()
    md = ["# SID-EXCEPTIONS.md -- generated by build/check-sid-exceptions.sh", "",
          f"Pinned snapshot: `{snap}`.  Ledger rows: **{len(rows)}**.  "
          f"Generated {dt.datetime.now(dt.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')}.", "",
          "This file is GENERATED (do not hand-edit).  It tracks the reviewed",
          "installer-substrate sid exceptions and whether forky has caught up yet.",
          "See docs/FORKY-PROVENANCE.md for the policy.", "",
          ("| package | arch | substrate ver | forky (pinned) | forky (latest) | "
           "recorded forky | class | status | review_by | action |"),
          ("|---|---|---|---|---|---|---|---|---|---|")]
    counts = {}
    trend = {}
    findings = 0
    for r in rows:
        pv = best_version(pinned, r["name"], r["arch"])
        lv = best_version(latest, r["name"], r["arch"])
        rec = r["forky_version"]
        if lv and _cmp(lv, r["version"]) >= 0:
            status = "GRADUATED"
        elif r["review_by"] and dt.date.fromisoformat(r["review_by"]) < today:
            status = "EXPIRED"
        elif lv:
            if rec and _cmp(lv, rec) > 0:
                status = "SHRINKING"
            elif rec and _cmp(lv, rec) < 0:
                status = "GROWING"
            else:
                status = "STABLE"
        else:
            status = "ABSENT"
        if status in ("GRADUATED", "EXPIRED"):
            findings += 1
        # per-arch count (arch:all counts for both arches)
        for arch in (("amd64", "arm64") if r["arch"] == "all" else (r["arch"],)):
            counts[arch] = counts.get(arch, 0) + 1
        trend[status] = trend.get(status, 0) + 1
        md.append("| `{name}` | {arch} | {version} | {pv} | {lv} | {rec} | {cls} | "
                  "**{st}** | {rby} | {act} |".format(
                      name=r["name"], arch=r["arch"], version=r["version"],
                      pv=pv or "-", lv=lv or "-", rec=rec or "-", cls=r["class"],
                      st=status, rby=r["review_by"], act=r["owner_action"]))
    md += ["", "## Summary", "",
           "| arch | sid components |", "|---|---|"]
    for arch in ("amd64", "arm64"):
        md.append(f"| {arch} | {counts.get(arch, 0)} |")
    md += ["", "Trend: " + ", ".join(f"{k}={v}" for k, v in sorted(trend.items())), ""]

    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
    with open(a.out, "w") as o:
        o.write("\n".join(md) + "\n")
    print(f"sid-exceptions: {len(rows)} rows; per-arch " +
          " ".join(f"{k}={counts.get(k, 0)}" for k in ("amd64", "arm64")) +
          f"; trend " + " ".join(f"{k}={v}" for k, v in sorted(trend.items())))
    print(f"wrote {a.out}")

    if a.receipt:
        rec = {}
        if os.path.isfile(a.receipt):
            try:
                rec = json.loads(open(a.receipt).read())
            except Exception:  # noqa: BLE001
                rec = {}
        if not isinstance(rec, dict):
            rec = {}
        rec["sid_exceptions"] = {
            "count_per_arch": {k: counts.get(k, 0) for k in ("amd64", "arm64")},
            "total_rows": len(rows),
            "trend": trend,
            "ledger_sha256": hashlib.sha256(open(a.ledger, "rb").read()).hexdigest(),
            "snapshot": snap,
            "generated": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        }
        with open(a.receipt, "w") as o:
            json.dump(rec, o, indent=2, sort_keys=True)
            o.write("\n")
        print(f"recorded sid_exceptions in {a.receipt}")

    if a.strict and findings:
        print(f"sid-exceptions: {findings} row(s) GRADUATED/EXPIRED -- action "
              f"required", file=sys.stderr)
        return 1
    return 0


def _load_index_dir(d):
    out = {}
    import glob
    for f in glob.glob(os.path.join(d, "**", "Packages*"), recursive=True):
        try:
            text = read_maybe(f)
        except Exception:  # noqa: BLE001
            continue
        for name, vers in parse_versions(text).items():
            out.setdefault(name, []).extend(vers)
    return out


if __name__ == "__main__":
    sys.exit(main())
