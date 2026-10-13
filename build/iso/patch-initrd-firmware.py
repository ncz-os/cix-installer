#!/usr/bin/env python3
"""
patch-initrd-firmware.py -- inject real device firmware into a Debian
Installer initrd, content-addressed and cached the same way
patch-debootstrap-stub.py and stage-ncz-payload.py already are.

Why this exists (2026-09-24): T2 MacBooks need the real Apple/
Broadcom WiFi firmware (brcmfmac4355c1/4364b2/4364b3/4377b3 board
variants) to bring up wireless AT ALL -- the driver modules
(brcmfmac.ko/brcmsmac.ko/brcmutil.ko) and wpa_supplicant + netcfg's own
wireless-config prompt are ALL already present in Debian's stock d-i
initrd, but the proprietary firmware blob is not (Debian's default
netboot mini.iso deliberately ships no non-free firmware). Without it,
the brcmfmac driver loads but the radio never associates, so d-i's
native (interactive, attended-install) wireless prompt has nothing to
work with.

We already have the real firmware, extracted once from a genuine macOS
Sonoma 14 Recovery Image and vendored at
assets/firmware/apple-t2/apple-t2-firmware-sonoma14.tar.xz (see
post-install/55-t2-firmware.sh, which stages the SAME tarball onto the
INSTALLED system after the fact -- this script closes the equivalent gap
for the d-i RUNTIME environment itself, so wireless is available during
install, not just after it).

Two different artifacts, two different production pipelines, same
reasoning as patch-debootstrap-stub.py's own header: the payload
(firmware) and the environment it's injected into (the d-i initrd) are
independently diagnosable, so this stays its own script.

What this does NOT do:
  * It does not touch Bluetooth firmware (brcmbt*) -- out of scope for
    "WiFi during install"; add a --include-bluetooth flag here if that's
    ever wanted.
  * It does not modify the substrate's own extracted tree in place
    (import-substrate.py's black-box contract) -- it reads the
    substrate's d-i/initrd.gz as an immutable input and writes a new,
    separately content-addressed artifact.
  * It does not change the d-i kernel (linux) -- only the initrd.

Usage:
    patch-initrd-firmware.py --substrate-node-dir DIR --arch {amd64,arm64}
        [--firmware-tar PATH] [--cache-root DIR] [--force]

Output: <cache-root>/ncz-initrd/<node_key>/initrd.gz + receipt.json
"""
from __future__ import annotations

import argparse
import gzip
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
DEFAULT_CACHE_ROOT = REPO_ROOT / "build" / "iso-cache" / "v1"
DEFAULT_FIRMWARE_TAR = (
    REPO_ROOT / "assets" / "firmware" / "apple-t2" / "apple-t2-firmware-sonoma14.tar.xz"
)


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def sha256_bytes(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()


def canonical_encode(obj: dict) -> bytes:
    return json.dumps(obj, sort_keys=True, separators=(",", ":")).encode("utf-8")


def log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


def _stat(path: Path) -> dict:
    if not path.exists():
        return {"present": False}
    s = path.stat()
    return {"present": True, "sha256": sha256_file(path), "size": s.st_size}


def patch_initrd(
    substrate_node_dir: Path,
    arch: str,
    firmware_tar: Path,
    cache_root: Path,
    force: bool = False,
) -> Path:
    src_initrd = substrate_node_dir / "extract" / "d-i" / "initrd.gz"
    if not src_initrd.is_file():
        raise RuntimeError(f"FATAL: no d-i initrd at {src_initrd}")
    if not firmware_tar.is_file():
        raise RuntimeError(f"FATAL: firmware tarball missing: {firmware_tar}")

    canonical = canonical_encode({
        "schema_version": "ncz-initrd-patch/v1",
        "arch": arch,
        "src_initrd": _stat(src_initrd),
        "firmware_tar": _stat(firmware_tar),
    })
    node_key = sha256_bytes(canonical)
# Content-addressed cache nodes are created EMPTY and filled afterwards, and
# every reader treats "the directory exists" as "the build succeeded". An
# interrupted or crashed run therefore leaves a partial node that later runs
# serve as a cache HIT -- silently shipping half a build. Fix: build into a
# sibling .partial.<pid> directory and os.replace() it into its final name only
# after the receipt has been written, so a node is either absent or complete.
# A node that somehow exists without its receipt is treated as incomplete and
# rebuilt rather than trusted.
    node_dir = cache_root / "ncz-initrd" / node_key
    if node_dir.exists() and not force:
        if (node_dir / "receipt.json").is_file():
            log(f"node exists: {node_dir}")
            return node_dir / "initrd.gz"
        log(f"WARNING: incomplete cache node (no receipt.json): {node_dir} -- rebuilding")
    if node_dir.exists():
        shutil.rmtree(node_dir)
    build_dir = node_dir.parent / f"{node_key}.partial.{os.getpid()}"
    shutil.rmtree(build_dir, ignore_errors=True)
    build_dir.mkdir(parents=True)

    with tempfile.TemporaryDirectory(prefix="patch-initrd-") as tmp:
        tmp = Path(tmp)
        extract_dir = tmp / "extract"
        extract_dir.mkdir()

        # Real d-i initrds contain device nodes (dev/console, dev/null)
        # that cpio can only mknod(2) as root -- extract via sudo, then
        # hand ownership back so the repack + tempdir cleanup below can
        # run as the normal user.
        log(f"    extracting {src_initrd} -> {extract_dir} (sudo, real device nodes)")
        with src_initrd.open("rb") as gz_in:
            zcat_out = subprocess.run(["zcat"], stdin=gz_in, stdout=subprocess.PIPE, check=True).stdout
        subprocess.run(
            ["sudo", "cpio", "-idm", "--quiet"],
            input=zcat_out,
            cwd=extract_dir,
            check=True,
        )
        subprocess.run(
            ["sudo", "chown", "-R", f"{os.getuid()}:{os.getgid()}", str(extract_dir)],
            check=True,
        )

        fw_extract = tmp / "fw"
        fw_extract.mkdir()
        log(f"    extracting {firmware_tar} -> {fw_extract}")
        subprocess.run(["tar", "-xJf", str(firmware_tar), "-C", str(fw_extract)], check=True)

        brcm_files = sorted(fw_extract.glob("brcmfmac*"))
        if not brcm_files:
            raise RuntimeError(
                f"FATAL: no brcmfmac* firmware files found in {firmware_tar} "
                f"-- tarball layout changed?"
            )
        dest_fw = extract_dir / "lib" / "firmware" / "brcm"
        dest_fw.mkdir(parents=True, exist_ok=True)
        for f in brcm_files:
            shutil.copy2(f, dest_fw / f.name)
            (dest_fw / f.name).chmod(0o644)
        log(f"    injected {len(brcm_files)} brcmfmac firmware files into lib/firmware/brcm/")

        out_initrd = build_dir / "initrd.gz"
        log(f"    repacking cpio+gzip -> {out_initrd}")
        find_proc = subprocess.Popen(
            ["find", "."], cwd=extract_dir, stdout=subprocess.PIPE,
        )
        cpio_proc = subprocess.Popen(
            ["cpio", "--quiet", "-o", "-H", "newc"],
            cwd=extract_dir,
            stdin=find_proc.stdout,
            stdout=subprocess.PIPE,
        )
        find_proc.stdout.close()
        with out_initrd.open("wb") as out_f:
            with gzip.GzipFile(fileobj=out_f, mode="wb", compresslevel=9) as gz_out:
                shutil.copyfileobj(cpio_proc.stdout, gz_out)
        cpio_proc.wait()
        find_proc.wait()
        if cpio_proc.returncode != 0 or find_proc.returncode != 0:
            raise RuntimeError("FATAL: cpio/find repack failed")

    receipt = {
        "schema_version": "ncz-initrd-patch-receipt/v1",
        "node_key": node_key,
        "node_kind": "ncz-initrd",
        "arch": arch,
        "inputs": {
            "src_initrd": str(src_initrd),
            "src_initrd_sha256": sha256_file(src_initrd),
            "firmware_tar": str(firmware_tar),
            "firmware_tar_sha256": sha256_file(firmware_tar),
            "firmware_files_injected": len(brcm_files),
        },
        "outputs": {
            "initrd_gz": str(out_initrd),
            "initrd_gz_sha256": sha256_file(out_initrd),
            "initrd_gz_size": out_initrd.stat().st_size,
        },
    }
    (build_dir / "receipt.json").write_text(json.dumps(receipt, indent=2, sort_keys=True))
    # Atomic publish: until this rename, no other run can see a partial node.
    os.replace(build_dir, node_dir)
    log(f"OK: patched initrd at {node_dir / 'initrd.gz'}")
    return node_dir / "initrd.gz"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--substrate-node-dir", required=True, type=Path)
    ap.add_argument("--arch", required=True, choices=["amd64", "arm64"])
    ap.add_argument("--firmware-tar", type=Path, default=DEFAULT_FIRMWARE_TAR)
    ap.add_argument("--cache-root", type=Path, default=DEFAULT_CACHE_ROOT)
    ap.add_argument("--force", action="store_true")
    args = ap.parse_args()

    try:
        out = patch_initrd(
            args.substrate_node_dir, args.arch, args.firmware_tar,
            args.cache_root, args.force,
        )
    except RuntimeError as e:
        log(str(e))
        return 1
    print(str(out))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
