#!/usr/bin/env python3
"""resolve-kernel-from-registry.py -- the kernel this image build uses, from the kernel-ci registry.

The kernel-ci promotion registry (fleet-ops gitops/fleet/kernel-ci, registry.json on ARGONAS) is the
single source of truth: its `current` pointer per arch is the kernel the next image is built
with, and a promotion changes the next build without a commit here. The committed pins
(assets/kernel/amd64-stable/KVER + PKGVERSION, assets/kernel/mainline.release) are the reviewed
record of a promotion, written to a branch by kernel-promote --write-pins. They are read only with
--allow-committed-manifests (build-image.sh --kernel-from-manifests), and even then a pin the
registry lists as retired is refused.

usage: build/resolve-kernel-from-registry.py --arch amd64|arm64 [--registry PATH]
           [--allow-committed-manifests] [--root DIR] [--format env|json]

Registry path: --registry, else $NCZ_KERNEL_REGISTRY, else
/mnt/argonas/datapool/projects/kernel-ci/registry.json.
Output (env): NCZ_KERNEL_SOURCE=registry|committed-manifests, NCZ_KERNEL_KVER, NCZ_KERNEL_REV,
NCZ_KERNEL_PKGVERSION (amd64), NCZ_KERNEL_RELEASE (arm64), NCZ_KERNEL_STAGED_DIR, NCZ_KERNEL_BUILD,
NCZ_KERNEL_RETIRED, NCZ_KERNEL_PIN_DRIFT (1 when the committed pins name a different build).
Exit: 0 resolved, 3 refused (no/retired/unverifiable kernel), 2 usage.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import re
import sys

DEFAULT = "/mnt/argonas/datapool/projects/kernel-ci/registry.json"
ARCH_TREE = {"amd64": "t2-amd64", "arm64": "sky1-arm64"}


class Refused(Exception):
    pass


def canonical(obj) -> bytes:
    return json.dumps(obj, sort_keys=True, separators=(",", ":")).encode()


def load(path: pathlib.Path) -> dict:
    """Read and verify the registry exactly as kernel-ci writes it (checksum + hash chain)."""
    try:
        doc = json.loads(path.read_text())
    except FileNotFoundError as e:
        raise Refused(f"registry {path} not found") from e
    except (OSError, json.JSONDecodeError) as e:
        raise Refused(f"registry {path} unreadable: {e}") from e
    body = {k: v for k, v in doc.items() if k != "checksum"}
    if (
        doc.get("schema") != 1
        or doc.get("checksum") != hashlib.sha256(canonical(body)).hexdigest()
    ):
        raise Refused(f"registry {path} checksum/schema does not verify")
    prev = ""
    for rec in doc.get("history", []):
        h = hashlib.sha256(
            canonical({k: v for k, v in rec.items() if k != "hash"})
        ).hexdigest()
        if rec.get("prev") != prev or rec.get("hash") != h:
            raise Refused(f"registry {path} history broken at seq {rec.get('seq')}")
        prev = h
    return doc


def retired_of(tree: dict) -> list[str]:
    return sorted({f"{r['kver']}+{r['rev']}" for r in tree.get("retired", [])})


def is_retired(tree: dict, kver: str, rev: str | None) -> bool:
    return any(
        r["kver"] == kver and (r["rev"] == "*" or rev is None or r["rev"] == rev)
        for r in tree.get("retired", [])
    )


def pkgversion(kver: str, rev: str) -> str:
    m = re.match(r"^(\d+\.\d+\.\d+(?:-rc\d+)?)", kver)
    return f"{m.group(1)}-{rev}" if m else rev


def committed(root: pathlib.Path, arch: str) -> dict:
    def rd(rel):
        p = root / rel
        return re.sub(r"#.*", "", p.read_text()).strip() if p.exists() else ""

    if arch == "amd64":
        kver, pv = (
            rd("assets/kernel/amd64-stable/KVER"),
            rd("assets/kernel/amd64-stable/PKGVERSION"),
        )
        rev = (
            pv[len(kver.split("-t2")[0]) + 1 :]
            if pv.startswith(kver.split("-t2")[0] + "-")
            else pv
        )
        return {
            "kver": kver,
            "rev": rev,
            "pkgversion": pv,
            "release": "",
            "staged_dir": "",
        }
    rel, rev = (
        rd("assets/kernel/mainline.release"),
        rd("assets/kernel/mainline.deb-revision"),
    )
    m = re.match(r"^(r\d+)-(.+)$", rel)
    kver = re.sub(r"-\d{8}$", "", m.group(2)) if m else ""
    return {
        "kver": kver,
        "rev": rev or (m.group(1) if m else ""),
        "pkgversion": "",
        "release": rel,
        "staged_dir": "",
    }


def resolve(
    arch: str, registry: pathlib.Path, root: pathlib.Path, allow_committed: bool
) -> dict:
    pins = committed(root, arch)
    try:
        doc = load(registry)
    except Refused as e:
        if not allow_committed:
            raise Refused(
                f"{e}; pass --kernel-from-manifests to build from the committed pins"
            ) from e
        if not pins["kver"]:
            raise Refused(f"{e}; and no committed pin for {arch}") from e
        return {
            "source": "committed-manifests",
            "warning": str(e),
            **pins,
            "build": f"{pins['kver']}+{pins['rev']}",
            "retired": [],
            "pin_drift": 0,
        }
    tree = doc.get("trees", {}).get(ARCH_TREE[arch])
    if not tree:
        raise Refused(f"registry has no tree {ARCH_TREE[arch]} for {arch}")
    if allow_committed:
        if pins["kver"] and is_retired(tree, pins["kver"], pins["rev"] or None):
            raise Refused(
                f"committed pin {pins['kver']}+{pins['rev']} is RETIRED in the registry"
            )
        return {
            "source": "committed-manifests",
            **pins,
            "build": f"{pins['kver']}+{pins['rev']}",
            "retired": retired_of(tree),
            "pin_drift": int(f"{pins['kver']}+{pins['rev']}" != tree.get("current")),
        }
    cur = tree.get("current")
    b = tree.get("builds", {}).get(cur or "")
    if not cur or not b:
        raise Refused(f"registry has no current kernel for {arch}")
    if b.get("state") != "current" or is_retired(tree, b["kver"], b["rev"]):
        raise Refused(f"registry current {cur} is retired or not current")
    out = {
        "source": "registry",
        "build": cur,
        "kver": b["kver"],
        "rev": b["rev"],
        "staged_dir": b.get("staged_dir") or "",
        "release": (b.get("source") or {}).get("release") or "",
        "retired": retired_of(tree),
        "pkgversion": pkgversion(b["kver"], b["rev"]) if arch == "amd64" else "",
    }
    if arch == "arm64" and not out["release"]:
        raise Refused(f"registry current {cur} has no Sky1 staging release name")
    out["pin_drift"] = int((pins["kver"], pins["rev"]) != (out["kver"], out["rev"]))
    return out


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    ap.add_argument("--arch", required=True, choices=sorted(ARCH_TREE))
    ap.add_argument(
        "--registry", default=os.environ.get("NCZ_KERNEL_REGISTRY") or DEFAULT
    )
    ap.add_argument("--allow-committed-manifests", action="store_true")
    ap.add_argument(
        "--root", default=str(pathlib.Path(__file__).resolve().parent.parent)
    )
    ap.add_argument("--format", choices=["env", "json"], default="env")
    a = ap.parse_args(argv)
    try:
        res = resolve(
            a.arch,
            pathlib.Path(a.registry),
            pathlib.Path(a.root),
            a.allow_committed_manifests,
        )
    except Refused as e:
        print(f"resolve-kernel-from-registry: REFUSED ({a.arch}): {e}", file=sys.stderr)
        return 3
    if res.get("warning"):
        print(
            f"resolve-kernel-from-registry: WARNING: {res['warning']}; using committed pins",
            file=sys.stderr,
        )
    if res.get("pin_drift"):
        print(
            f"resolve-kernel-from-registry: note: committed pins differ from the resolved {res['build']} "
            "(the registry wins; review the kernel-pin branch)",
            file=sys.stderr,
        )
    if a.format == "json":
        print(json.dumps(res, indent=1, sort_keys=True))
    else:
        for k in (
            "source",
            "build",
            "kver",
            "rev",
            "pkgversion",
            "release",
            "staged_dir",
        ):
            print(f"NCZ_KERNEL_{k.upper()}={res.get(k) or ''}")
        print(f"NCZ_KERNEL_RETIRED={','.join(res['retired'])}")
        print(f"NCZ_KERNEL_PIN_DRIFT={res['pin_drift']}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
