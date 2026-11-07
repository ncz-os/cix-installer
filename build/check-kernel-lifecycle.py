#!/usr/bin/env python3
"""check-kernel-lifecycle.py -- refuse a retired, too-old or unpromoted kernel pin.

Reads assets/kernel/KERNEL-LIFECYCLE (KEY=value, written by the kernel-ci
promotion registry; see docs/RC-DEFINITION.md) and compares it with every
committed kernel pin for the requested architecture:

  amd64  assets/kernel/amd64-stable/KVER, assets/kernel/amd64-stable/PKGVERSION,
         assets/kernel/amd64-stable-manifest.json (kver, package_revision)
  arm64  assets/kernel-manifest.json (variants.mainline.kver and the
         linux-image-cixmini deb version), assets/kernel/sky1-manifest.json (kver)
  both   manifests/ncz-packages.tsv kernel rows for that arch

A pin fails when its KVER is in RETIRED, its upstream version sorts below
MIN_VERSION (an -rcN sorts below its final release), it differs from the
promoted CURRENT_KVER_<arch> / CURRENT_PKG_<arch>, the pin sources disagree
with each other, or no kernel is promoted for the arch.  A missing or
malformed lifecycle file fails closed.

Why (2026-11-07): rc3 (ba74b7c7) shipped 7.3.0 kernels after 7.3.0 had been
retired for 7.3.1.  The old policy only checked the 7.3 series.

Usage: check-kernel-lifecycle.py [--root <repo>] --arch amd64|arm64|all
Exit: 0 pins agree with the lifecycle, 1 violation, 2 misuse.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

LIFECYCLE_REL = "assets/kernel/KERNEL-LIFECYCLE"
SCHEMA = "1"
ARCHES = ("amd64", "arm64")
# 7.3.1, 7.3.0-rc7, 7.4-rc1, 7.3.1-t2-ncz, 7.2.9-2-t2-ncz: release, optional rc.
VERSION_RE = re.compile(r"^(\d+)\.(\d+)(?:\.(\d+))?(?:-rc(\d+))?(?=$|[-+])")


def parse_version(text: str) -> tuple[int, int, int, int] | None:
    """Return a sortable key; a final release sorts above all of its -rcN."""
    m = VERSION_RE.match(text)
    if not m:
        return None
    major, minor, patch, rc = m.groups()
    rc_key = int(rc) if rc is not None else 1 << 30
    return (int(major), int(minor), int(patch or 0), rc_key)


def read_lifecycle(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        key, sep, value = line.partition("=")
        if not sep:
            raise ValueError(f"line without '=': {raw!r}")
        values[key.strip()] = value.split("#", 1)[0].strip()
    return values


def load_json(path: Path) -> dict:
    with path.open(encoding="utf-8") as fh:
        return json.load(fh)


def ledger_kernel_rows(root: Path, arch: str) -> list[tuple[str, str, str]]:
    """(name, version, kver) of every kernel image/headers row for arch."""
    rows = []
    ledger = root / "manifests/ncz-packages.tsv"
    if not ledger.is_file():
        return rows
    for raw in ledger.read_text(encoding="utf-8").splitlines():
        if not raw or raw.startswith("#"):
            continue
        cols = raw.split("\t")
        if len(cols) < 3 or cols[2] != arch:
            continue
        name, version = cols[0], cols[1]
        if name in ("linux-image-cixmini", "linux-headers-cixmini"):
            rows.append((name, version, version.split("+", 1)[0]))
        elif name.startswith(("linux-image-", "linux-headers-")) and not name.endswith(
            "-dbg"
        ):
            kver = name.split("-", 2)[2]
            if parse_version(kver):
                rows.append((name, version, kver))
    return rows


def pins_amd64(root: Path, errors: list[str]) -> tuple[dict[str, str], dict[str, str]]:
    kvers: dict[str, str] = {}
    pkgs: dict[str, str] = {}
    side = root / "assets/kernel/amd64-stable"
    for name, target in (("KVER", kvers), ("PKGVERSION", pkgs)):
        f = side / name
        if f.is_file() and f.read_text(encoding="utf-8").strip():
            target[f"assets/kernel/amd64-stable/{name}"] = f.read_text(
                encoding="utf-8"
            ).strip()
    man = root / "assets/kernel/amd64-stable-manifest.json"
    if man.is_file():
        try:
            d = load_json(man)
        except (OSError, ValueError) as exc:
            errors.append(f"amd64: {man.relative_to(root)} is not valid JSON ({exc})")
        else:
            if d.get("kver"):
                kvers["assets/kernel/amd64-stable-manifest.json kver"] = str(d["kver"])
            if d.get("package_revision"):
                pkgs["assets/kernel/amd64-stable-manifest.json package_revision"] = str(
                    d["package_revision"]
                )
    return kvers, pkgs


def pins_arm64(root: Path, errors: list[str]) -> tuple[dict[str, str], dict[str, str]]:
    kvers: dict[str, str] = {}
    pkgs: dict[str, str] = {}
    man = root / "assets/kernel-manifest.json"
    if man.is_file():
        try:
            d = load_json(man)
        except (OSError, ValueError) as exc:
            errors.append(
                f"arm64: assets/kernel-manifest.json is not valid JSON ({exc})"
            )
        else:
            kver = ((d.get("variants") or {}).get("mainline") or {}).get("kver")
            if kver:
                kvers["assets/kernel-manifest.json variants.mainline.kver"] = str(kver)
            for deb in d.get("kernel_debs") or []:
                base = Path(str(deb.get("file", ""))).name
                m = re.match(r"^linux-image-cixmini_([^_]+)_arm64\.deb$", base)
                if m:
                    pkgs["assets/kernel-manifest.json linux-image-cixmini"] = m.group(1)
    sky = root / "assets/kernel/sky1-manifest.json"
    if sky.is_file():
        try:
            d = load_json(sky)
        except (OSError, ValueError) as exc:
            errors.append(
                f"arm64: assets/kernel/sky1-manifest.json is not valid JSON ({exc})"
            )
        else:
            if d.get("kver"):
                kvers["assets/kernel/sky1-manifest.json kver"] = str(d["kver"])
    return kvers, pkgs


def check_arch(root: Path, arch: str, lc: dict[str, str]) -> list[str]:
    errors: list[str] = []
    min_text = lc.get("MIN_VERSION", "")
    min_key = parse_version(min_text)
    retired = {k.strip() for k in lc.get("RETIRED", "").split(",") if k.strip()}
    current = lc.get(f"CURRENT_KVER_{arch}", "")
    current_pkg = lc.get(f"CURRENT_PKG_{arch}", "")

    def judge(kver: str, where: str) -> None:
        key = parse_version(kver)
        if key is None:
            errors.append(
                f"{arch}: cannot parse a kernel version from '{kver}' ({where})"
            )
            return
        if kver in retired:
            errors.append(
                f"{arch}: '{kver}' ({where}) is retired (RETIRED in {LIFECYCLE_REL})"
            )
        if min_key is not None and key < min_key:
            errors.append(f"{arch}: '{kver}' ({where}) is below MIN_VERSION {min_text}")

    if not current:
        errors.append(
            f"{arch}: no promoted kernel (CURRENT_KVER_{arch} is empty in {LIFECYCLE_REL}); "
            "promote a boot-tested build before building this arch"
        )
    else:
        judge(current, f"CURRENT_KVER_{arch}")

    kvers, pkgs = (pins_amd64 if arch == "amd64" else pins_arm64)(root, errors)
    if not kvers:
        errors.append(f"{arch}: no committed kernel pin found")
    for where, kver in kvers.items():
        judge(kver, where)
    if len(set(kvers.values())) > 1:
        detail = ", ".join(f"{w}={v}" for w, v in kvers.items())
        errors.append(f"{arch}: kernel pin sources disagree: {detail}")
    if len(set(pkgs.values())) > 1:
        detail = ", ".join(f"{w}={v}" for w, v in pkgs.items())
        errors.append(f"{arch}: package revision pins disagree: {detail}")
    if current:
        for where, kver in kvers.items():
            if kver != current:
                errors.append(
                    f"{arch}: '{kver}' ({where}) is not the promoted CURRENT_KVER_{arch} '{current}'"
                )
        if current_pkg:
            for where, pkg in pkgs.items():
                if pkg != current_pkg:
                    errors.append(
                        f"{arch}: '{pkg}' ({where}) is not the promoted CURRENT_PKG_{arch} '{current_pkg}'"
                    )
    for name, version, kver in ledger_kernel_rows(root, arch):
        if kver in retired:
            errors.append(
                f"{arch}: manifests/ncz-packages.tsv row {name} {version} is a retired kernel ({kver})"
            )
    return errors


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--root", default=str(Path(__file__).resolve().parent.parent))
    ap.add_argument("--arch", required=True)
    args = ap.parse_args(argv)
    arch = {"aarch64": "arm64", "x86_64": "amd64"}.get(args.arch, args.arch)
    if arch not in (*ARCHES, "all"):
        print(
            f"[kernel-lifecycle] ERROR: unsupported --arch '{args.arch}'",
            file=sys.stderr,
        )
        return 2
    root = Path(args.root)
    if not root.is_dir():
        print(
            f"[kernel-lifecycle] ERROR: --root '{root}' is not a directory",
            file=sys.stderr,
        )
        return 2

    path = root / LIFECYCLE_REL
    errors: list[str] = []
    lc: dict[str, str] = {}
    if not path.is_file():
        errors.append(
            f"{LIFECYCLE_REL} is missing (kernel lifecycle unknown; fail closed)"
        )
    else:
        try:
            lc = read_lifecycle(path)
        except (OSError, ValueError) as exc:
            errors.append(f"{LIFECYCLE_REL} is malformed: {exc}")
    if lc:
        if lc.get("LIFECYCLE_SCHEMA") != SCHEMA:
            errors.append(
                f"{LIFECYCLE_REL}: LIFECYCLE_SCHEMA '{lc.get('LIFECYCLE_SCHEMA', '')}' is not {SCHEMA}"
            )
        if parse_version(lc.get("MIN_VERSION", "")) is None:
            errors.append(f"{LIFECYCLE_REL}: MIN_VERSION missing or unparseable")
        if not errors:
            for a in ARCHES if arch == "all" else (arch,):
                errors.extend(check_arch(root, a, lc))

    for e in errors:
        print(f"[kernel-lifecycle] FAIL: {e}", file=sys.stderr)
    if errors:
        return 1
    print(
        f"[kernel-lifecycle] OK -- arch={arch} pins equal the promoted kernel "
        f"(MIN_VERSION {lc['MIN_VERSION']}, retired: {lc.get('RETIRED', '') or '<none>'})"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
