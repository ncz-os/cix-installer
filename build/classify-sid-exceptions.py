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
substrate -- refresh-substrate is required); 4 = NEW exceptions require a human
review (a warning without --accept-new-exceptions; a hard error, nothing
written, with --require-accepted).

--ledger mode (build/repin.sh, docs/BUILD-STABILITY.md M2) is the reviewed
merge this script was always meant to be:
  * class A / K:           the row is GRADUATED and dropped (use forky).
  * a row that changes:    (name, version, arch, sha256) differs from the row
                           carried over -> NEW: the exception is regenerated with
                           first_seen/snapshot/review_by and owner_action, but it
                           is NOT approved: without --accept-new-exceptions it
                           is only a warning, and with --require-accepted the run
                           fails (rc 4) and nothing is written.  With the flag the
                           row is written; --review-by sets the review date
                           (default: first_seen + --review-days).
  * a row that does not:   class B / C, not graduated, still authorized by the
                           pinned sid d-i index at the same sha256.
                           - classification unchanged, same snapshot, valid
                             review_by -> carried over BYTE-IDENTICAL (the human
                             review stands);
                           - the pin moved (or the classification changed, or
                             review_by lapsed) -> carried over, re-chained to the
                             new snapshot with the remaining review window (or a
                             fresh one if it has lapsed).  The decision is
                             unchanged; when the owner action is also unchanged
                             --accept-new-exceptions is not required (repin prints
                             the decision it kept).
                           - class ? (the pin does not authorize it) -> NEW-like:
                             it is not a decision, so it takes the acceptance
                             path too.
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
    r"|(^.+-(modules|binary)-.*-di$)"
)


def die(msg: str) -> NoReturn:  # noqa: F821
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
    r = subprocess.run(
        ["xorriso", "-osirrox", "on", "-indev", iso, "-extract", member, out],
        capture_output=True,
        text=True,
    )
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


def load_snapshot_index(ts: str, suite: str, comp: str, arch: str, cache: str) -> dict:
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
            return {}
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


def initrd_identities(initrd: str, scratch: str) -> list:
    """The (name, version) identities carried in the substrate's d-i initrd.

    The netinst's installer initrd unpacks a d-i/udpkg dpkg status that lists
    udebs the ISO's own `/dists` indexes do NOT always list (the initrd is a
    superset: e.g. `cdrom-detect`, `libssl3-udeb`, `libcrypto3-udeb`,
    `libexpat1-udeb` at their sid versions).  Those records are still shipped
    into the image and must be classified, or the gate flags them as
    sid d-i packages with no reviewed row.
    """
    dest = os.path.join(scratch, "substrate_initrd_status")
    if not (os.path.isfile(dest) and os.path.getsize(dest) > 0):
        try:
            with open(dest, "wb") as o:
                p1 = subprocess.Popen(
                    ["gzip", "-dc", initrd],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.DEVNULL,
                )
                subprocess.run(
                    ["cpio", "-i", "--to-stdout", "var/lib/dpkg/status"],
                    stdin=p1.stdout,
                    stdout=o,
                    stderr=subprocess.DEVNULL,
                )
                p1.stdout.close()
                p1.wait()
        except OSError:
            return []
        if not (os.path.isfile(dest) and os.path.getsize(dest) > 0):
            return []
    with open(dest, errors="replace") as fh:
        text = fh.read()
    ids = []
    for d in parse_stanzas(text):
        if d.get("Package") and d.get("Version"):
            ids.append((d["Package"], d["Version"]))
    return ids


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
    ap.add_argument(
        "--initrd",
        default="",
        help="the substrate's d-i initrd.gz; its dpkg status adds "
        "identities the ISO's /dists indexes omit (classified "
        "against the same pinned snapshot + sid d-i index)",
    )
    ap.add_argument("--snapshot", required=True)
    ap.add_argument("--scratch", required=True)
    ap.add_argument("--ledger", default="")
    ap.add_argument("--tsv-out", default="")
    ap.add_argument("--first-seen", default=dt.date.today().isoformat())
    ap.add_argument("--review-days", type=int, default=30)
    ap.add_argument(
        "--accept-new-exceptions",
        action="store_true",
        help="write NEW exceptions (a changed identity/decision or a "
        "class-? row) into --ledger.  Without it they are "
        "reported and NOT written; never implies approval of "
        "what it writes without a review_by date",
    )
    ap.add_argument(
        "--require-accepted",
        action="store_true",
        help="with --ledger: if any NEW exception needs review, "
        "write nothing and exit 4 (build/repin.sh uses this)",
    )
    ap.add_argument(
        "--review-by",
        default="",
        help="review_by date for NEW exceptions (YYYY-MM-DD; "
        "default: --first-seen + --review-days)",
    )
    a = ap.parse_args()
    if a.accept_new_exceptions and not a.ledger:
        die("--accept-new-exceptions needs --ledger")
    if a.require_accepted and not a.ledger:
        die("--require-accepted needs --ledger")
    if a.accept_new_exceptions and a.require_accepted:
        die("--accept-new-exceptions and --require-accepted are exclusive")
    if a.review_by and not a.ledger:
        die("--review-by needs --ledger")
    if a.review_by:
        try:
            dt.date.fromisoformat(a.review_by)
        except ValueError:
            die(f"--review-by is not a YYYY-MM-DD date: {a.review_by!r}")

    if not os.path.isfile(a.iso):
        die(f"iso not found: {a.iso}")
    os.makedirs(a.scratch, exist_ok=True)

    # --- forky (the codename suite) full index set + its own d-i index ---
    forky: dict = {}
    for comp in COMPONENTS:
        for x in (a.arch, "all"):
            forky.update(load_snapshot_index(a.snapshot, "forky", comp, x, a.scratch))
    for x in (a.arch, "all"):
        forky.update(
            load_snapshot_index(a.snapshot, "forky", DI_COMPONENT, x, a.scratch)
        )
    if not forky:
        die("could not load forky indexes from the pinned snapshot")
    forky_by_name: dict = {}
    for n, v, ar in forky:
        forky_by_name.setdefault(n, set()).add(v)

    # --- sid debian-installer index (the substrate's own d-i source) ---
    siddi: dict = {}
    for x in (a.arch, "all"):
        siddi.update(
            load_snapshot_index(a.snapshot, DI_SUITE, DI_COMPONENT, x, a.scratch)
        )
    if not siddi:
        die("could not load sid debian-installer indexes from the pinned snapshot")

    sub = iso_di_identities(a.iso, a.arch, a.scratch)
    if not sub:
        die("no substrate identities extracted from the iso")

    if a.initrd:
        if not os.path.isfile(a.initrd):
            die(f"initrd not found: {a.initrd}")
        merged = 0
        for nm, vr in initrd_identities(a.initrd, a.scratch):
            for (sn, sv, sa), rec in siddi.items():
                if sn == nm and sv == vr and (sn, sv, sa) not in sub:
                    sub[(sn, sv, sa)] = {
                        "filename": rec.get("filename", ""),
                        "sha256": rec.get("sha256", ""),
                        "size": rec.get("size", ""),
                        "index": "initrd",
                    }
                    merged += 1
        print(f"initrd: merged {merged} substrate d-i identity(ies) from {a.initrd}")

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
                # The closest forky version by upstream proximity (lower-or-equal
                # preferred; fall back to the highest).
                forky_ver = sorted(vers)[-1]
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
            if forky_ver:
                pass
        gap = gap_of(ver, forky_ver) if forky_ver else "none"
        siddi_rec = siddi.get(key, {})
        rows.append(
            {
                "name": name,
                "version": ver,
                "arch": arch,
                "sha256": siddi_rec.get("sha256", ""),
                "class": cls,
                "forky_version": forky_ver,
                "gap": gap,
                "action": action,
            }
        )

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
            '# check-sid-exceptions tracker fail on it: "use forky").  Keep it small and\n'
            "# shrinking; see docs/SID-EXCEPTIONS.md and build/forky-provenance.py.\n"
            "#\n"
            "# columns (TAB): name version arch sha256 class forky_version gap reason\n"
            "#                first_seen snapshot owner_action review_by tracking_url\n"
            "# class: B = small gap, rebuild planned; C = large gap/none, wait/replace.\n"
            "# owner_action: rebuild | wait | replace (what we will do to remove it).\n"
        )
        # Merge with any existing ledger so per-arch runs accumulate (a stable
        # (name,version,arch) key; arch:all rows appear once).  The ledger is
        # never regenerated from scratch: a row this arch's substrate does not
        # carry (the OTHER arch's rows, an arch:all row) is carried over, and a
        # row for this arch that the classification no longer lists is dropped
        # as GRADUATED (it became a class-A/K identity, i.e. forky provides it).
        # What is carried over and what needs a human review is decided below;
        # nothing is approved by writing it.
        carried: list[tuple[str, list[str]]] = []
        if os.path.isfile(a.ledger):
            for ln in open(a.ledger, errors="replace"):
                if ln.startswith("#") or not ln.strip():
                    continue
                f = ln.rstrip("\n").split("\t")
                if len(f) >= 4:
                    carried.append((ln.rstrip("\n"), f))
        # The keys this substrate carries, for ANY arch -- arch:all rows included.
        # A row is GRADUATED when the pinned forky index now provides it at the
        # same identity (class A) at the same sha256, whichever arch lists it:
        # both arches ship one arch:all udeb, and either ledger row would then
        # contradict forky.  A row that is merely absent from THIS arch's
        # substrate is not graduated (the other arch still carries it).
        present = {
            (r["name"], r["version"], r["arch"]): r["sha256"] for r in ledger_rows
        }
        today = dt.date.fromisoformat(a.first_seen)
        review_by = (
            a.review_by or (today + dt.timedelta(days=a.review_days)).isoformat()
        )

        merged: dict = {}
        new: list[dict] = []  # exceptions that need a human decision
        refreshed: list[dict] = []  # carried over, re-chained, decision kept
        unchanged: list[str] = []
        graduated: list[str] = []
        for ln, f in carried:
            key = (f[0], f[1], f[2])
            name, ver, arch = key
            if arch not in (a.arch, "all"):
                merged[key] = ln  # the other arch's row
                continue
            if key not in present and (f[0], f[1]) in forky:
                graduated.append(f"{name} {ver} {arch}")
                continue
            r = next(
                (x for x in ledger_rows if (x["name"], x["version"], x["arch"]) == key),
                None,
            )
            problems = []
            if r is None:  # arch:all row this substrate does not carry
                problems.append(("", ""))
                r = {
                    "name": name,
                    "version": ver,
                    "arch": arch,
                    "sha256": f[3],
                    # A short (legacy) row has fewer than the 13 columns: read
                    # each one only if it is there.  Indexing f[4]/f[5]/f[6]
                    # unconditionally raised IndexError on a 4-6 column row for
                    # arch:all that this substrate does not carry.
                    "class": f[4] if len(f) > 4 else "",
                    "forky_version": f[5] if len(f) > 5 else "",
                    "gap": f[6] if len(f) > 6 else "",
                    "action": f[10] if len(f) > 10 else "",
                }
            if r["class"] == "?":
                problems.append(("class", "?"))
            got_sha = r["sha256"]
            if len(f) > 3 and f[3] != got_sha:
                problems.append(("sha256", f"{f[3]} -> {got_sha}"))
            if len(f) > 4 and f[4] != r["class"]:
                problems.append(("class", f"{f[4]} -> {r['class']}"))
            if len(f) > 10 and f[10] != r["action"]:
                problems.append(("owner_action", f"{f[10]} -> {r['action']}"))
            if problems:
                # The exception itself changed (version or bytes) or the
                # decision did: that is new sid content and needs a review.  The
                # reason names the column that changed -- version against version,
                # sha256 against sha256 (never one against the other).
                identity = []
                # `ver` is the LEDGER row's version (key = (f[0], f[1], f[2])),
                # so a drift is measured against the version the pinned
                # classification currently lists -- never against `ver`, which
                # would make the comparison a tautology.
                now_ver = next(
                    (
                        x["version"]
                        for x in ledger_rows
                        if x["name"] == name and x["arch"] == arch
                    ),
                    "",
                )
                if now_ver and now_ver != ver:
                    identity.append(f"version {ver} -> {now_ver}")
                if len(f) > 3 and f[3] != got_sha:
                    identity.append(f"sha256 {f[3][:12]}… -> {got_sha[:12]}…")
                decided = [
                    f"{k} {v}" for k, v in problems if k in ("class", "owner_action")
                ]
                why = list(identity)
                if decided:
                    why.append("decision changed: " + ", ".join(decided))
                # Keyed by the ledger's identity (name, arch): the version may
                # have CHANGED (that is often exactly why it is new content), so
                # matching on version below would never find this entry.
                new.append(
                    {"name": name, "arch": arch, "version": ver, "why": "; ".join(why)}
                )
                continue
            same_snap = len(f) > 9 and f[9] == a.snapshot
            by = f[11] if len(f) > 11 else ""
            try:
                by_ok = dt.date.fromisoformat(by) > today
            except ValueError:
                by_ok = False
            if same_snap and by_ok:
                merged[key] = ln
                unchanged.append(f"{name} {ver} {arch}")
                continue
            # Keep the decision (class + owner_action), re-chain it to THIS pin
            # and carry the remaining review window (a fresh one if it lapsed).
            fields = list(f) + [""] * max(0, 13 - len(f))
            fields[9] = a.snapshot
            if not by_ok:
                fields[11] = review_by
            merged[key] = "\t".join(fields[:13])
            refreshed.append(
                {
                    "name": name,
                    "version": ver,
                    "arch": arch,
                    "class": r["class"],
                    "action": r["action"],
                    "review_by": fields[11],
                }
            )
        for r in ledger_rows:
            key = (r["name"], r["version"], r["arch"])
            if key in merged:
                continue
            reason = {
                "B": (
                    "forky has the same source at a close version "
                    f"({r['forky_version'] or 'n/a'}); small gap -> rebuild"
                ),
                "C": (
                    "forky lacks the package or is markedly older "
                    f"({r['forky_version'] or 'none'}) -> track and replace"
                ),
            }.get(r["class"], "review")
            tracking = f"https://tracker.debian.org/pkg/{r['name']}"
            # A ledger row is the SAME package when (name, arch) matches; its
            # version may legitimately differ from the new row's (version drift
            # is one of the things that makes it new content), so compare the
            # identity, never the version.
            as_new = any(n["name"] == r["name"] and n["arch"] == r["arch"] for n in new)
            if as_new and not a.accept_new_exceptions:
                continue
            row = "\t".join(
                [
                    r["name"],
                    r["version"],
                    r["arch"],
                    r["sha256"],
                    r["class"],
                    r["forky_version"],
                    r["gap"],
                    reason,
                    a.first_seen,
                    a.snapshot,
                    r["action"],
                    review_by,
                    tracking,
                ]
            )
            merged[key] = row
            if as_new:
                new = [
                    n
                    for n in new
                    if not (n["name"] == r["name"] and n["arch"] == r["arch"])
                ]
                print(
                    f"NEW exception ACCEPTED (--accept-new-exceptions): "
                    f"{r['name']} {r['version']} {r['arch']} class {r['class']} "
                    f"owner_action {r['action']} review_by {review_by}"
                )
            elif not os.path.isfile(a.ledger) or not any(
                n["name"] == r["name"] and n["arch"] == r["arch"] for n in new
            ):
                # New to the ledger whether or not the file already existed: a
                # reviewed ledger never approves a row just because the file is
                # there (that path used to write a brand-new (name,version,arch)
                # straight to the merged output, unreported and unreviewed).
                new.append(
                    {
                        "name": r["name"],
                        "arch": r["arch"],
                        "version": r["version"],
                        "why": "new to the ledger",
                    }
                )

        for n in new:
            print(
                f"NEW sid exception needs a human review: {n['name']} "
                f"{n['version']} ({n['why']})",
                file=sys.stderr,
            )
        if new and a.require_accepted:
            print(
                f"ERROR: {len(new)} NEW sid exception(s) need a human review; "
                f"re-run with --accept-new-exceptions (or review and edit "
                f"{a.ledger} by hand).  Nothing was written.",
                file=sys.stderr,
            )
            return 4
        if new and not a.accept_new_exceptions:
            print(
                f"WARN: {len(new)} NEW sid exception(s) NOT written (they are not "
                f"reviewed); re-run with --accept-new-exceptions to write them "
                f"with review_by {review_by}",
                file=sys.stderr,
            )

        os.makedirs(os.path.dirname(os.path.abspath(a.ledger)), exist_ok=True)
        with open(a.ledger, "w") as o:
            o.write(hdr)
            o.writelines(
                merged[k] + "\n"
                for k in sorted(
                    merged, key=lambda k: (merged[k].split("\t")[4], k[2], k[0])
                )
            )
        grace = (
            (
                f", {len(refreshed)} re-chained to {a.snapshot} "
                f"(decision kept: "
                + ", ".join(
                    f"{r['name']} {r['class']}/{r['action']}" for r in refreshed
                )
                + ")"
            )
            if refreshed
            else ""
        )
        print(
            f"wrote {a.ledger} ({len([r for r in ledger_rows if r['arch'] in (a.arch, 'all')])} "
            f"row(s) this arch, {len(merged)} total: {len(unchanged)} carried over"
            f" byte-identical{grace}; {len(graduated)} graduated"
            + (", " + ", ".join(graduated) if graduated else "")
        )

    if a.tsv_out:
        with open(a.tsv_out, "w") as o:
            o.write(
                "package\tarch\tsubstrate_version\tforky_version\tclass\tgap\taction\tsha256\n"
            )
            for r in sorted(rows, key=lambda r: (r["arch"], r["name"])):
                o.write(
                    "\t".join(
                        [
                            r["name"],
                            r["arch"],
                            r["version"],
                            r["forky_version"],
                            r["class"],
                            r["gap"],
                            r["action"],
                            r["sha256"],
                        ]
                    )
                    + "\n"
                )
        print(f"wrote {a.tsv_out} ({len(rows)} rows)")

    n = {"A": 0, "B": 0, "C": 0, "K": 0, "?": 0}
    for r in rows:
        n[r["class"]] += 1
    print(
        f"{a.arch}: substrate identities {len(rows)}  A={n['A']} B={n['B']} "
        f"C={n['C']} K(kernel)={n['K']} unknown={n['?']}  "
        f"ledger(B+C)={n['B'] + n['C']}"
    )

    if unauth:
        print(
            f"ERROR: {len(unauth)} substrate identities are NOT authorized by the "
            f"pinned snapshot (neither forky nor sid d-i); refresh-substrate is "
            f"required:",
            file=sys.stderr,
        )
        for k in unauth:
            print("  UNAUTH", k[0], k[1], k[2], file=sys.stderr)
        return 3
    return 0


if __name__ == "__main__":
    sys.exit(main())
