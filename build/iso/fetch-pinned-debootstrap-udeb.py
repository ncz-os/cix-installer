#!/usr/bin/env python3
"""fetch-pinned-debootstrap-udeb.py -- fetch and cryptographically authenticate
the debootstrap-udeb base that ``patch-debootstrap-stub.py`` derives.

The consumer (``build/build-installer-image.sh``) must never resolve this from a
live ``deb.debian.org`` forky index: that would let the base bytes drift out
from under the committed pin.  This helper resolves the udeb through the SAME
trust root the provenance scanner uses:

  1. verify the signed ``InRelease`` for the pinned snapshot
     (``manifests/forky-snapshot.tsv``: InRelease sha256+size, committed keyring,
     pinned signer fingerprints) and the ``main/debian-installer/binary-<arch>``
     ``Packages.xz`` digest from it;
  2. read the authenticated ``debootstrap-udeb`` Filename/SHA256/Size from that
     verified index;
  3. download the udeb from ``snapshot.debian.org`` at the pinned timestamp and
     verify its sha256+size against the signed index.

Nothing here can authorize a byte that is not in the pinned signed index.
Prints a JSON receipt on success; exits non-zero on any failure (fail closed).
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import shutil
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parent.parent
VERIFIER = REPO_ROOT / "build" / "forky-provenance.py"


def _load_verifier():
    spec = importlib.util.spec_from_file_location("forky_provenance", VERIFIER)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load verifier {VERIFIER}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def resolve(fp, arch: str, work_dir: Path, out_dir: Path) -> dict:
    trust = fp.load_trust()
    pin = trust["snapshot"]
    codename = trust["codename"]
    index_dir = work_dir / "index"
    index_dir.mkdir(parents=True, exist_ok=True)

    got = fp.verify_index(index_dir, trust,
                          [("main/debian-installer", arch)], fetch=True)
    if got is None or fp.FAILS:
        raise RuntimeError("signed snapshot index did not verify")

    packages = (index_dir / "dists" / codename / "main" / "debian-installer"
                / f"binary-{arch}" / "Packages.xz")
    if not packages.is_file():
        raise RuntimeError(f"verified Packages.xz missing: {packages}")

    fields = None
    for stanza in fp.parse_stanzas(fp.read_maybe_compressed(str(packages))):
        if stanza.get("Package") == "debootstrap-udeb":
            if fields is not None:
                raise RuntimeError("debootstrap-udeb appears more than once in the index")
            fields = stanza
    if not fields:
        raise RuntimeError("debootstrap-udeb not present in the pinned installer index")
    if fields.get("Architecture") != "all":
        raise RuntimeError(
            f"debootstrap-udeb Architecture={fields.get('Architecture')!r}, expected 'all' "
            "(the stub is architecture-independent)")
    filename = fields.get("Filename")
    sha = fields.get("SHA256")
    size = fields.get("Size")
    if not filename or not fp.SHA256_RE.match(sha or "") or not str(size or "").isdigit():
        raise RuntimeError(f"incomplete debootstrap-udeb index record: {fields}")

    dest = out_dir / Path(filename).name
    url = f"https://snapshot.debian.org/archive/debian/{pin}/{filename}"
    fp.atomic_fetch(url, str(dest), sha, int(size))
    if fp.sha256_file(str(dest)) != sha or dest.stat().st_size != int(size):
        raise RuntimeError("downloaded udeb did not match the signed index")
    return {
        "udeb_path": str(dest),
        "filename": Path(filename).name,
        "sha256": sha,
        "size": int(size),
        "snapshot": pin,
        "codename": codename,
        "arch": arch,
        "source": url,
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--arch", required=True, choices=["amd64", "arm64"])
    ap.add_argument("--out-dir", required=True, type=Path,
                    help="directory to write the authenticated udeb into")
    args = ap.parse_args()

    args.out_dir.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix="ncz-pinned-udeb-",
                                 dir=str(args.out_dir))).resolve()
    try:
        fp = _load_verifier()
        receipt = resolve(fp, args.arch, work, args.out_dir)
    except Exception as e:  # noqa: BLE001 - fail closed, no traceback noise
        print(f"FATAL: pinned debootstrap-udeb fetch failed: {e}", file=sys.stderr)
        return 1
    finally:
        shutil.rmtree(work, ignore_errors=True)

    print(json.dumps(receipt, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
