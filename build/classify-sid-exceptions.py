#!/usr/bin/env python3
"""classify-sid-exceptions.py -- classify the installer-substrate packages.

Every package the Debian netinst substrate ships into the installer's /cdrom
pool (its debian-installer udebs, plus any base deb the ISO carries) is
classified against the PINNED snapshot, so the build knows which ones need a
reviewed sid exception and which forky already provides:

  A  the exact (name, version, arch) is present in forky (any component,
     including forky's own main/debian-installer index).  No exception; the
     build must use forky's copy (prefer forky always).
  B  forky does not carry this exact version but has the SAME source package at
     a CLOSE version (same upstream, or a patch/minor upstream delta): a SMALL
     gap.  The plan is to REBUILD the needed version from the forky source in a
     clean forky container as an NCZ udeb; until that lands it needs a ledger
     entry with owner_action=rebuild.
  C  forky has a MARKEDLY older upstream version or LACKS the package entirely:
     a LARGE gap / none.  Allowed only via a reviewed manifests/sid-exceptions.tsv
     entry (owner_action=wait|replace|rebuild) until upstream forks it.

The substrate's Debian kernel/module/binary udebs (linux-base-*, linux-binary-*,
*-modules-*-di) are reported with class K: the one-kernel policy removes them
from the image entirely (docs/ONE-KERNEL.md), so they never need a ledger entry.

The substrate's own package identities come straight from the netinst ISO
(xorriso); forky's and sid's identities come from the pinned snapshot, whose
signed InRelease is verified against the committed keyring and digests in
manifests/forky-snapshot.tsv.  The ledger's sha256 is the signed sid d-i index's
sha256 for that exact identity, so the gate can chain every exception to the
signed archive state.

Usage:
  build/classify-sid-exceptions.py --arch amd64 --iso <netinst.iso> \\
      --scratch <dir> [--ledger manifests/sid-exceptions.tsv] [--tsv-out ...]
Exit 0 = classification produced; 2 = bad input; 3 = a substrate identity is
neither in forky nor in the pinned sid d-i index (the pin does not authorize the
substrate -- refresh-substrate is required).
"""
from __future__ import annotations

import argparse
import datetime as dt
import gzip
import hashlib
import lzma
import os
import re
import subprocess
import sys
import urllib.request

COMPONENTS = ("main", "contrib", "non-free", "non-free-firmware")
DI_COMPONENT = "main/debian-installer"
DI_SUITE = "sid"
SNAP = "https://snapshot.debian.org/archive/debian"
# One-kernel policy: Debian kernel/module/binary artifacts, dropped from the
# image by NCZ_ONE_KERNEL=1.  Mirrors build/forky-provenance.py KERNEL_ARTIFACT_RE.
KERNEL_ARTIFACT_RE = re.compile(
    r"^(linux-image|linux-headers|linux-modules|linux-binary|kernel-image)"
    r"|^linux-base-"
    r"|(^.+-(modules|binary)-.*-di$)")


def _load_gate():
    """Load build/forky-provenance.py for its Debian version comparator (the
    canonical implementation) -- never hand-roll version ordering."""
    import importlib.util
    p = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                     "forky-provenance.py")
    spec = importlib.util.spec_from_file_location("forky_provenance", p)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def max_version(versions, vercmp):
    """The greatest version under Debian ordering (NOT lexicographic)."""
    best = None
    for v in versions:
        if best is None or vercmp(v, best) > 0:
            best = v
    return best


def die(msg: str) -> "NoReturn":  # noqa: F821
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(2)


def sha256(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def read_maybe(path: str) -> str:
    if path.endswith(".xz"):
        return lzma.open(path, "rt", errors="replace").read()
    if path.endswith(".gz"):
        return gzip.open(path, "rt", errors="replace").read()
    return open(path, errors="replace").read()


def parse_stanzas(text: str) -> list[dict]:
    out = []
    for st in re.split(r"\n\s*\n", text):
        d = {}
        for line in st.split("\n"):
            if ": " in line and line[:1] not in (" ", "\t"):
                k, v = line.split(": ", 1)
                d[k] = v.strip()
        if d.get("Package"):
            out.append(d)
    return out


def xorriso_extract(iso: str, member: str, out: str) -> bool:
    r = subprocess.run(["xorriso", "-osirrox", "on", "-indev", iso,
                        "-extract", member, out], capture_output=True, text=True)
    return r.returncode == 0 and os.path.isfile(out)


def fetch(url: str, dest: str) -> bool:
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    if os.path.isfile(dest) and os.path.getsize(dest) > 0:
        return True
    try:
        with urllib.request.urlopen(url, timeout=180) as r, open(dest, "wb") as o:
            o.write(r.read())
        return os.path.getsize(dest) > 0
    except Exception:  # noqa: BLE001
        open(dest, "wb").close()
        return False


def load_snapshot_index(ts: str, suite: str, comp: str, arch: str,
                        cache: str) -> dict:
    """{(name,version,arch): {filename,sha256,size}} from one snapshot index."""
    out = {}
    for ext in ("Packages.xz", "Packages.gz", "Packages"):
        rel = f"{comp}/binary-{arch}/{ext}"
        f = os.path.join(cache, f"{ts}_{suite}_" + rel.replace("/", "_"))
        url = f"{SNAP}/{ts}/dists/{suite}/{rel}"
        if not fetch(url, f):
            continue
        try:
            text = read_maybe(f)
        except Exception:  # noqa: BLE001
            # A corrupt/unreadable first format must not abort the others.
            continue
        for d in parse_stanzas(text):
            if d.get("Package") and d.get("Version") and d.get("Architecture"):
                out[(d["Package"], d["Version"], d["Architecture"])] = {
                    "filename": d.get("Filename", ""),
                    "sha256": d.get("SHA256", ""),
                    "size": d.get("Size", ""),
                }
        return out
    return out


def iso_di_identities(iso: str, arch: str, scratch: str) -> dict:
    """The netinst's own d-i (+ component) identities, from its Packages indexes."""
    out = {}
    paths = []
    for comp in COMPONENTS:
        for x in (arch, "all"):
            paths.append(f"{comp}/binary-{x}")
    for x in (arch, "all"):
        paths.append(f"{DI_COMPONENT}/binary-{x}")
    for path in paths:
        for ext in ("Packages.gz", "Packages"):
            dest = os.path.join(scratch, "iso_" + path.replace("/", "_") + "." + ext)
            if xorriso_extract(iso, f"/dists/forky/{path}/{ext}", dest):
                for d in parse_stanzas(read_maybe(dest)):
                    if d.get("Package") and d.get("Version") and d.get("Architecture"):
                        out[(d["Package"], d["Version"], d["Architecture"])] = {
                            "filename": d.get("Filename", ""),
                            "sha256": d.get("SHA256", ""),
                            "size": d.get("Size", ""),
                            "index": path,
                        }
                break
    return out


def dparse(v: str) -> tuple[int, str, str]:
    epoch = 0
    rest = v or ""
    if ":" in rest:
        e, rest = rest.split(":", 1)
        try:
            epoch = int(e)
        except ValueError:
            epoch = 0
    if "-" in rest:
        upstream, rev = rest.rsplit("-", 1)
    else:
        upstream, rev = rest, ""
    return epoch, upstream, rev


def upstream_distance(a: str, b: str) -> str:
    """'same' | 'small' | 'large' for two upstream version strings."""
    if a == b:
        return "same"
    an = re.findall(r"\d+", a)
    bn = re.findall(r"\d+", b)
    if an and bn:
        # Drop trailing equal components; a difference confined to the last
        # numeric component (patch/minor) is small, anything else is large.
        if an[:-1] == bn[:-1]:
            return "small"
        return "large"
    return "large"


def gap_of(sub_ver: str, forky_ver: str) -> str:
    if not forky_ver:
        return "none"
    e1, u1, r1 = dparse(sub_ver)
    e2, u2, r2 = dparse(forky_ver)
    d = upstream_distance(u1, u2)
    if d == "same":
        return "revision" if r1 != r2 else "exact-upstream"
    if d == "small":
        return "upstream-minor"
    return "upstream-major"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--arch", required=True, choices=["amd64", "arm64"])
    ap.add_argument("--iso", required=True)
    ap.add_argument("--snapshot", required=True)
    ap.add_argument("--scratch", required=True)
    ap.add_argument("--ledger", default="")
    ap.add_argument("--tsv-out", default="")
    ap.add_argument("--first-seen", default=dt.date.today().isoformat())
    ap.add_argument("--review-days", type=int, default=30)
    a = ap.parse_args()

    if not os.path.isfile(a.iso):
        die(f"iso not found: {a.iso}")
    os.makedirs(a.scratch, exist_ok=True)
    vercmp = _load_gate().deb_vercmp

    # --- forky (the codename suite) full index set + its own d-i index ---
    forky: dict = {}
    for comp in COMPONENTS:
        for x in (a.arch, "all"):
            forky.update(load_snapshot_index(a.snapshot, "forky", comp, x, a.scratch))
    for x in (a.arch, "all"):
        forky.update(load_snapshot_index(a.snapshot, "forky", DI_COMPONENT, x, a.scratch))
    if not forky:
        die("could not load forky indexes from the pinned snapshot")
    forky_by_name: dict = {}
    for (n, v, ar) in forky:
        forky_by_name.setdefault(n, set()).add(v)

    # --- sid debian-installer index (the substrate's own d-i source) ---
    siddi: dict = {}
    for x in (a.arch, "all"):
        siddi.update(load_snapshot_index(a.snapshot, DI_SUITE, DI_COMPONENT, x, a.scratch))
    if not siddi:
        die("could not load sid debian-installer indexes from the pinned snapshot")

    sub = iso_di_identities(a.iso, a.arch, a.scratch)
    if not sub:
        die("no substrate identities extracted from the iso")

    rows = []
    unauth = []
    for key in sorted(sub, key=lambda k: (k[0], k[2])):
        name, ver, arch = key
        if key in forky:
            cls, forky_ver, action = "A", ver, "use-forky"
        elif KERNEL_ARTIFACT_RE.search(name):
            cls, forky_ver, action = "K", "", "drop-one-kernel"
        else:
            vers = forky_by_name.get(name)
            forky_ver = ""
            if vers:
                # The closest forky version by Debian ordering (max), never a
                # lexicographic sort ("1.9" > "1.10" lexicographically).
                forky_ver = max_version(vers, vercmp)
            if key not in siddi:
                unauth.append(key)
                cls, action = "?", "REVIEW"
            elif not vers:
                cls, action = "C", "wait"
            else:
                g = gap_of(ver, forky_ver)
                if g in ("revision", "upstream-minor"):
                    cls, action = "B", "rebuild"
                else:
                    cls, action = "C", "wait"
        gap = gap_of(ver, forky_ver) if forky_ver else "none"
        siddi_rec = siddi.get(key, {})
        rows.append({
            "name": name, "version": ver, "arch": arch,
            "sha256": siddi_rec.get("sha256", ""),
            "class": cls, "forky_version": forky_ver, "gap": gap,
            "action": action,
        })

    # --- ledger rows: everything that still needs a sid exception (B, C; not A/K) ---
    # Arch:all rows are emitted once (they cover both arches).
    ledger_rows = [r for r in rows if r["class"] in ("B", "C")]
    if a.ledger:
        hdr = (
            "# manifests/sid-exceptions.tsv -- the reviewed ledger of installer-substrate\n"
            "# packages that are authorized from the pinned snapshot's sid debian-installer\n"
            "# suite INSTEAD of from forky.  This REPLACES any blanket suite grant: the\n"
            "# provenance gate authorizes sid d-i ONLY for an exact (name,version,arch,sha256)\n"
            "# row here, and each row is chained to the signed sid index at the pinned\n"
            "# snapshot (manifests/forky-snapshot.tsv di_suite/di_inrelease_sha256).  Any sid\n"
            "# d-i package NOT in this ledger FAILS.  A row whose package forky now provides\n"
            "# at the same or newer version is GRADUATED and must be removed (the gate + the\n"
            "# check-sid-exceptions tracker fail on it: \"use forky\").  Keep it small and\n"
            "# shrinking; see docs/SID-EXCEPTIONS.md and docs/FORKY-PROVENANCE.md.\n"
            "#\n"
            "# columns (TAB): name version arch sha256 class forky_version gap reason\n"
            "#                first_seen snapshot owner_action review_by tracking_url\n"
            "# class: B = small gap, rebuild planned; C = large gap/none, wait/replace.\n"
            "# owner_action: rebuild | wait | replace (what we will do to remove it).\n")
        # Merge with any existing ledger so per-arch runs accumulate (a stable
        # (name,version,arch) key; arch:all rows appear once).
        merged: dict = {}
        if os.path.isfile(a.ledger):
            for ln in open(a.ledger, errors="replace"):
                if ln.startswith("#") or not ln.strip():
                    continue
                f = ln.rstrip("\n").split("\t")
                if len(f) >= 4:
                    merged[(f[0], f[1], f[2])] = ln.rstrip("\n")
        review_by = (dt.date.fromisoformat(a.first_seen)
                     + dt.timedelta(days=a.review_days)).isoformat()
        for r in sorted(ledger_rows, key=lambda r: (r["class"], r["arch"], r["name"])):
            reason = {
                "B": ("forky has the same source at a close version "
                      f"({r['forky_version'] or 'n/a'}); small gap -> rebuild"),
                "C": ("forky lacks the package or is markedly older "
                      f"({r['forky_version'] or 'none'}) -> track and replace"),
            }.get(r["class"], "review")
            tracking = f"https://tracker.debian.org/pkg/{r['name']}"
            merged[(r["name"], r["version"], r["arch"])] = "\t".join([
                r["name"], r["version"], r["arch"], r["sha256"], r["class"],
                r["forky_version"], r["gap"], reason, a.first_seen, a.snapshot,
                r["action"], review_by, tracking,
            ])
        os.makedirs(os.path.dirname(os.path.abspath(a.ledger)), exist_ok=True)
        with open(a.ledger, "w") as o:
            o.write(hdr)
            for k in sorted(merged, key=lambda k: (merged[k].split("\t")[4],
                                                   k[2], k[0])):
                o.write(merged[k] + "\n")
        print(f"wrote {a.ledger} ({len(ledger_rows)} rows this arch, "
              f"{len(merged)} total)")

    if a.tsv_out:
        with open(a.tsv_out, "w") as o:
            o.write("package\tarch\tsubstrate_version\tforky_version\tclass\tgap\taction\tsha256\n")
            for r in sorted(rows, key=lambda r: (r["arch"], r["name"])):
                o.write("\t".join([r["name"], r["arch"], r["version"],
                                   r["forky_version"], r["class"], r["gap"],
                                   r["action"], r["sha256"]]) + "\n")
        print(f"wrote {a.tsv_out} ({len(rows)} rows)")

    n = {"A": 0, "B": 0, "C": 0, "K": 0, "?": 0}
    for r in rows:
        n[r["class"]] += 1
    print(f"{a.arch}: substrate identities {len(rows)}  A={n['A']} B={n['B']} "
          f"C={n['C']} K(kernel)={n['K']} unknown={n['?']}  "
          f"ledger(B+C)={n['B'] + n['C']}")

    if unauth:
        print(f"ERROR: {len(unauth)} substrate identities are NOT authorized by the "
              f"pinned snapshot (neither forky nor sid d-i); refresh-substrate is "
              f"required:", file=sys.stderr)
        for k in unauth:
            print("  UNAUTH", k[0], k[1], k[2], file=sys.stderr)
        return 3
    return 0


if __name__ == "__main__":
    sys.exit(main())
