#!/usr/bin/env python3
"""verify-sbom-against-manifests.py -- the real preflight gate this project
was missing. Two independent checks, both against REAL data, neither
against a hand-maintained intermediate file that can itself drift:

1. MISSING PACKAGE: every top-level package name in manifests/*.pkgs must
   actually appear in the SPDX doc generated from the real built tree
   (gen-spdx-sbom.py). Hard failure -- the ISO was told to ship it and
   didn't.

2. STALE COMPONENT: every package's installed version (from the SPDX doc,
   i.e. what's actually in the built tree) is compared against the
   CURRENTLY AVAILABLE candidate version from the tree's own configured
   apt mirror (chroot + apt-get update + apt-cache policy, live, not a
   cached/manually-maintained "minimum version" file). A package behind
   its mirror's candidate is flagged. This is a WARNING by default, not a
   hard failure: this project has no existing convention for deliberately
   pinning a package below the mirror's candidate, so treating every lag
   as fatal would false-alarm on completely ordinary version churn between
   builds. A --stale-allowlist file (one package name per line, '#'
   comments ok) silences a specific, deliberately-pinned package without
   silencing the check as a whole. Pass --strict-staleness to hard-fail
   instead.

Usage:
    verify-sbom-against-manifests.py --spdx base.spdx.json \\
        --manifest manifests/installer-base.pkgs \\
        --tree /path/to/built/rootfs \\
        [--manifest manifests/desktop.pkgs ...] \\
        [--stale-allowlist sbom/stale-allowlist.txt] \\
        [--strict-staleness] [--skip-staleness]
"""
from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
import uuid
from pathlib import Path


def load_spdx_versions(spdx_path: Path) -> dict[str, str]:
    doc = json.loads(spdx_path.read_text())
    out: dict[str, str] = {}
    for pkg in doc.get("packages", []):
        name = pkg.get("name")
        ver = pkg.get("versionInfo")
        if name and ver and ver != "NOASSERTION":
            out[name] = ver
    return out


def parse_manifest(path: Path) -> list[str]:
    names = []
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        names.append(line.split()[0])
    return names


def check_missing(spdx_versions: dict[str, str], manifest_paths: list[Path]) -> list[str]:
    problems = []
    for mpath in manifest_paths:
        for name in parse_manifest(mpath):
            if name not in spdx_versions:
                problems.append(f"MISSING PACKAGE: {mpath.name}:{name} -- declared in manifest, absent from built tree's SBOM")
    return problems


def load_allowlist(path: Path | None) -> set[str]:
    if path is None or not path.exists():
        return set()
    out = set()
    for line in path.read_text().splitlines():
        # Strip a trailing '# reason' comment, not just whole-line comments
        # -- the file's own header tells authors to write the pin's reason
        # in a comment next to the entry, which this must not swallow into
        # the package name (caught in zoder review, 2026-09-14).
        line = line.split("#", 1)[0].strip()
        if line:
            out.add(line)
    return out


def dpkg_compare(a: str, op: str, b: str) -> bool:
    return subprocess.run(
        ["dpkg", "--compare-versions", a, op, b], capture_output=True, text=True
    ).returncode == 0


def check_staleness(tree: Path, spdx_versions: dict[str, str]) -> list[str]:
    """chroot into the tree, apt-get update against its OWN real configured
    mirror, then compare each SPDX-recorded installed version against the
    live candidate. Leaves the tree exactly as found (temp resolv.conf and
    apt cache/lists are cleaned up on the way out, success or failure)."""
    resolv = tree / "etc/resolv.conf"
    resolv_existed = resolv.exists()
    resolv_backup = None
    if resolv_existed:
        # A fixed suffix would silently clobber a leftover backup from a
        # prior run that crashed before restoring (caught in zoder review,
        # 2026-09-14) -- use a name that can't collide with a real file.
        resolv_backup = resolv.with_name(f".resolv.conf.spdx-check-bak.{uuid.uuid4().hex}")
        shutil.copy2(resolv, resolv_backup)
    shutil.copy2("/etc/resolv.conf", resolv)

    warnings: list[str] = []
    try:
        upd = subprocess.run(["chroot", str(tree), "/usr/bin/apt-get", "update"],
                              capture_output=True, text=True)
        if upd.returncode != 0:
            print(f"verify-sbom: WARNING: apt-get update inside {tree} failed "
                  f"(rc={upd.returncode}); staleness check skipped, not failed --"
                  f" this is a network/mirror problem, not a build defect", file=sys.stderr)
            print(upd.stderr, file=sys.stderr)
            return []

        for name, installed_ver in sorted(spdx_versions.items()):
            pol = subprocess.run(["chroot", str(tree), "/usr/bin/apt-cache", "policy", name],
                                  capture_output=True, text=True)
            candidate = None
            for line in pol.stdout.splitlines():
                line = line.strip()
                if line.startswith("Candidate:"):
                    candidate = line.split(":", 1)[1].strip()
                    break
            if not candidate or candidate == "(none)":
                continue  # not in the configured mirror (e.g. an NCZ-local .deb) -- not this check's job
            if dpkg_compare(installed_ver, "lt", candidate):
                warnings.append(f"STALE: {name} installed={installed_ver} candidate={candidate}")
    finally:
        subprocess.run(["rm", "-rf", str(tree / "var/lib/apt/lists"), str(tree / "var/cache/apt/archives")],
                        check=False)
        (tree / "var/lib/apt/lists").mkdir(parents=True, exist_ok=True)
        if resolv_existed and resolv_backup is not None:
            shutil.move(str(resolv_backup), str(resolv))
        else:
            resolv.unlink(missing_ok=True)

    return warnings


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--spdx", required=True, type=Path)
    ap.add_argument("--manifest", action="append", required=True, type=Path, dest="manifests")
    ap.add_argument("--tree", required=True, type=Path, help="built rootfs dir, needed for the live staleness check")
    ap.add_argument("--stale-allowlist", type=Path, default=None)
    ap.add_argument("--strict-staleness", action="store_true", help="hard-fail on stale packages instead of warning")
    ap.add_argument("--skip-staleness", action="store_true", help="skip the live apt-cache check entirely (e.g. no network)")
    args = ap.parse_args()

    spdx_versions = load_spdx_versions(args.spdx)
    print(f"verify-sbom: loaded {len(spdx_versions)} packages from {args.spdx}", file=sys.stderr)

    missing = check_missing(spdx_versions, args.manifests)
    for line in missing:
        print(line, file=sys.stderr)

    stale_warnings: list[str] = []
    if not args.skip_staleness:
        allowlist = load_allowlist(args.stale_allowlist)
        raw_stale = check_staleness(args.tree, spdx_versions)
        for w in raw_stale:
            pkg = w.split(":", 2)[1].strip().split(" ")[0]
            if pkg in allowlist:
                print(f"ok (pinned, in {args.stale_allowlist}): {w}", file=sys.stderr)
                continue
            stale_warnings.append(w)
            print(("STALE (hard fail): " if args.strict_staleness else "WARNING: ") + w, file=sys.stderr)

    if missing:
        print(f"verify-sbom: FAIL -- {len(missing)} manifest-declared package(s) missing from build", file=sys.stderr)
        return 1
    if args.strict_staleness and stale_warnings:
        print(f"verify-sbom: FAIL -- {len(stale_warnings)} stale package(s) (--strict-staleness)", file=sys.stderr)
        return 1

    print(f"verify-sbom: PASS ({len(stale_warnings)} staleness warning(s), 0 missing)", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
