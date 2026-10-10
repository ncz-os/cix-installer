#!/usr/bin/env python3
"""derive-base-pin.py -- derive the snapshot.debian.org pin for a netinst
substrate, by measurement.

The netinst's own signed `dists/<codename>/*/Packages` indexes name every
package identity (name, version, arch) the substrate ships.  This tool reads
them from the ISO (xorriso), then tries candidate snapshot.debian.org timestamps
around the substrate's own Release date, fetches the same component indexes from
each -- the codename's full set PLUS the same snapshot's development suite's
debian-installer indexes (the netinst's d-i udebs are built from sid) -- and
picks the snapshot that authorizes the LARGEST number of the netinst's
identities.

The result is written to manifests/base.pin (substrate sha256 + date + the
chosen snapshot + measured coverage).  Exit 0 only when the best coverage meets
--min-coverage (default 99); otherwise exit 3 and print the unauthorized
identities -- the substrate is then stale (a newer weekly is needed), NOT a
reason to add a fourth origin.
"""
from __future__ import annotations

import argparse
import datetime as dt
import glob
import gzip
import hashlib
import lzma
import os
import subprocess
import sys
import urllib.request

COMPONENTS = ("main", "contrib", "non-free-firmware")
# The pinned snapshot's development suite: the netinst substrate's d-i udebs are
# built from it, so its debian-installer indexes take part in the measurement
# (its runtime packages do not).  Mirrors manifests/forky-snapshot.tsv di_suite.
DI_SUITE = "sid"
SNAP = "https://snapshot.debian.org/archive/debian"
KERNEL_RE = None  # set in main


def sha256(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def xorriso_extract(iso: str, member: str, out: str) -> bool:
    r = subprocess.run(["xorriso", "-osirrox", "on", "-indev", iso,
                        "-extract", member, out],
                       capture_output=True, text=True)
    return r.returncode == 0 and os.path.isfile(out)


def parse_stanzas(text: str) -> list[dict]:
    out = []
    for st in text.split("\n\n"):
        d = {}
        for line in st.split("\n"):
            if ": " in line:
                k, v = line.split(": ", 1)
                d[k] = v.strip()
        if d:
            out.append(d)
    return out


def read_maybe(path: str) -> str:
    if path.endswith(".xz"):
        return lzma.open(path, "rt", errors="replace").read()
    if path.endswith(".gz"):
        return gzip.open(path, "rt", errors="replace").read()
    return open(path, errors="replace").read()


def netinst_identities(iso: str, arch: str, scratch: str) -> tuple[set, str]:
    """(identities, substrate_date) read straight from the ISO."""
    os.makedirs(scratch, exist_ok=True)
    rel = os.path.join(scratch, "Release")
    subprocess.run(["xorriso", "-osirrox", "on", "-indev", iso,
                    "-extract", "/dists/forky/Release", rel],
                   capture_output=True, text=True)
    sub_date = ""
    for line in open(rel, errors="replace").read().splitlines():
        if line.startswith("Date:"):
            sub_date = line.split(":", 1)[1].strip()
    ident = set()
    for comp in COMPONENTS:
        for x in (arch, "all"):
            for path in (f"{comp}/binary-{x}", f"main/debian-installer/binary-{x}"
                         if comp == "main" else None):
                if not path:
                    continue
                for ext in ("Packages.gz", "Packages"):
                    out = os.path.join(scratch, path.replace("/", "_") + "." + ext)
                    if xorriso_extract(iso, f"/dists/forky/{path}/{ext}", out):
                        for d in parse_stanzas(read_maybe(out)):
                            if d.get("Package") and d.get("Version") and d.get("Architecture"):
                                ident.add((d["Package"], d["Version"], d["Architecture"]))
                        break
    return ident, sub_date


def snapshot_identities(ts: str, arch: str, cache: str) -> set:
    os.makedirs(cache, exist_ok=True)
    ident = set()

    def load(suite: str, relpath: str) -> None:
        f = os.path.join(cache, f"{ts}_{suite}_" + relpath.replace("/", "_"))
        if not os.path.isfile(f) or os.path.getsize(f) == 0:
            url = f"{SNAP}/{ts}/dists/{suite}/{relpath}"
            try:
                with urllib.request.urlopen(url, timeout=120) as r, open(f, "wb") as o:
                    o.write(r.read())
            except Exception:  # noqa: BLE001 - a missing component index is fine
                open(f, "wb").close()
                return
        try:
            text = read_maybe(f)
        except Exception:  # noqa: BLE001
            return
        for d in parse_stanzas(text):
            if d.get("Package") and d.get("Version") and d.get("Architecture"):
                ident.add((d["Package"], d["Version"], d["Architecture"]))

    # The codename's (testing/forky) full index set -- the image base closure.
    for comp in COMPONENTS:
        for x in (arch, "all"):
            load("forky", f"{comp}/binary-{x}/Packages.xz")
    for x in (arch, "all"):
        load("forky", f"main/debian-installer/binary-{x}/Packages.xz")
        # The SAME snapshot's development suite (sid) debian-installer indexes
        # only: the netinst substrate's d-i udebs are built from sid.  Its
        # runtime (binary-*) packages are deliberately NOT loaded.
        load(DI_SUITE, f"main/debian-installer/binary-{x}/Packages.xz")
    return ident


def candidate_timestamps(sub_date: str) -> list[str]:
    try:
        d = dt.datetime.strptime(sub_date.split()[1] + " " + sub_date.split()[2] + " "
                                 + sub_date.split()[3], "%d %b %Y")
    except Exception:  # noqa: BLE001
        d = dt.datetime.utcnow()
    out = []
    for delta in (-2, -1, 0, 1):
        day = d + dt.timedelta(days=delta)
        for hh in ("000000", "120000", "235959"):
            out.append(day.strftime("%Y%m%dT") + hh + "Z")
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--arch", required=True, choices=["amd64", "arm64"])
    ap.add_argument("--iso", required=True)
    ap.add_argument("--pin-out", default=os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
        "manifests", "base.pin"))
    ap.add_argument("--scratch", required=True)
    ap.add_argument("--min-coverage", type=float, default=99.0)
    a = ap.parse_args()

    iso_sha = sha256(a.iso)
    sub, sub_date = netinst_identities(a.iso, a.arch, a.scratch)
    if not sub:
        print(f"ERROR: no netinst identities extracted from {a.iso}", file=sys.stderr)
        return 2
    best = None
    for ts in candidate_timestamps(sub_date):
        snap = snapshot_identities(ts, a.arch, a.scratch)
        if not snap:
            continue
        cov = 100.0 * len(sub & snap) / len(sub)
        print(f"  candidate snapshot {ts}: {len(sub & snap)}/{len(sub)} = {cov:.1f}%")
        if best is None or cov > best[1]:
            best = (ts, cov, sub - snap)
    if best is None:
        print("ERROR: no candidate snapshot index could be fetched", file=sys.stderr)
        return 2
    ts, cov, missing = best

    hdr = ("# manifests/base.pin -- the single BUILD+provenance base pin.\n"
           "# Substrate (Debian testing netinst) sha256 + its archive date, and the\n"
           "# snapshot.debian.org timestamp DERIVED from it (the snapshot that\n"
           "# authorizes the most of the netinst's own package identities).  Written\n"
           "# by build/refresh-substrate.sh; the provenance gate fails if the pinned\n"
           "# snapshot does not authorize the substrate, or if the substrate is\n"
           "# older than NCZ_SUBSTRATE_MAX_AGE_DAYS at build time.\n"
           "# arch\tsubstrate_sha256\tsubstrate_date\tsnapshot\tcoverage_pct\tsource_url\n")
    line = (f"{a.arch}\t{iso_sha}\t{sub_date}\t{ts}\t{cov:.1f}\t"
            f"https://cdimage.debian.org/cdimage/weekly-builds/{a.arch}/iso-cd/"
            f"debian-testing-{a.arch}-netinst.iso\n")
    # merge: keep other arches' rows
    rows = {}
    if os.path.isfile(a.pin_out):
        for ln in open(a.pin_out, errors="replace"):
            if ln.startswith("#") or not ln.strip():
                continue
            f = ln.rstrip("\n").split("\t")
            if len(f) >= 6:
                rows[f[0]] = ln
    rows[a.arch] = line
    os.makedirs(os.path.dirname(a.pin_out), exist_ok=True)
    with open(a.pin_out, "w") as o:
        o.write(hdr)
        for arch in sorted(rows):
            o.write(rows[arch])
    print(f"wrote {a.pin_out}: {a.arch} substrate {iso_sha[:8]} ({sub_date}) "
          f"-> snapshot {ts} coverage {cov:.1f}%")
    if cov < a.min_coverage:
        print(f"ERROR: coverage {cov:.1f}% < required {a.min_coverage:.1f}%; the "
              f"pinned netinst is STALE relative to testing.  Unauthorized "
              f"identities ({len(missing)}):", file=sys.stderr)
        for m in sorted(missing):
            print("  MISS", m[0], m[1], m[2], file=sys.stderr)
        return 3
    return 0


if __name__ == "__main__":
    sys.exit(main())
