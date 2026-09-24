#!/usr/bin/env python3
"""
patch-initrd-t2-kernel.py -- swap the d-i installer's OWN boot kernel for
our real T2 kernel, and append a modules overlay for it onto the d-i
initrd. Real, proven mechanism ported from build/build-iso-di.sh's
arm64/Sky1 kernel-swap (Step 2+3, ~line 2544) -- that script explicitly
skips this for amd64 ("stock d-i kernel/initrd already boot correctly on
generic PC hardware") because that's true for GENERIC amd64 PCs. It is
NOT true for T2 Macs: Debian's stock d-i kernel lacks the exact
Thunderbolt/USB module set and hardware quirks our own kernel already
carries (confirmed 2026-09-24: a Thunderbolt-hub-connected keyboard did
not work at d-i boot with the stock kernel; our T2 kernel ships
thunderbolt.ko).

Architecture (same as the arm64 precedent, adapted):
  1. Swap the d-i kernel binary (/linux in the ESP) for our real T2
     vmlinuz.
  2. Do NOT rebuild the base d-i initrd's userspace at all -- APPEND a
     separate modules cpio onto the end of initrd.gz (gzip and cpio both
     support concatenated streams; the kernel's initramfs unpacker
     extracts each archive in sequence, later entries winning on
     conflict). This keeps the real, working d-i environment (debconf,
     preseed, busybox, etc.) completely untouched.
  3. Real gotchas ported verbatim from the arm64 precedent:
     - d-i's own kmod udeb cannot decompress .ko.xz despite claiming to
       (zero lzma code linked in) -- decompress every .ko.xz in the
       overlay to plain .ko first, or modules silently fail to load
       ("Invalid module format").
     - NEVER emit a bare top-level "lib" directory entry in the overlay
       cpio. A usr-merged base (lib -> usr/lib symlink) has that symlink
       DELETED by the kernel's initramfs clean_path() if a later archive
       tries to create a directory at the same path -- taking libc and
       the dynamic loader with it, and initramfs will hard fail to find
       ANY working init. `find lib -mindepth 1` avoids ever emitting the
       top-level entry.
     - depmod -a -b <overlay-root> <kver> regenerates modules.dep etc
       WITHIN the overlay's own module tree before packing -- this does
       not touch the base initrd's own (now-unused, different-kver)
       module index at all.

  Deliberately does NOT prune wireless/bluetooth/mac80211 the way the
  arm64 precedent does -- T2 Macs need real WiFi (brcmfmac) support in
  d-i itself (see patch-initrd-firmware.py), so those categories stay.
  Only prunes sound (no audio need in a text-mode d-i bootstrap) to keep
  the overlay reasonably sized.

Usage:
    patch-initrd-t2-kernel.py --base-initrd PATH --kernel-deb PATH
        --arch {amd64,arm64} [--cache-root DIR] [--force]

Output: <cache-root>/cixmini-initrd-t2kernel/<node_key>/{linux,initrd.gz}
        + receipt.json
"""
from __future__ import annotations

import argparse
import gzip
import hashlib
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
DEFAULT_CACHE_ROOT = REPO_ROOT / "build" / "iso-cache" / "v1"

# Categories with no real use in a text-mode d-i bootstrap. Kept
# deliberately short -- when in doubt, keep the module; the overlay is
# appended, not baked into a firmware-size-limited image the way Sky1's
# is, so there is no real size pressure forcing aggressive pruning here.
PRUNE_MOD_DIRS = ["sound"]


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


def patch_t2_kernel(
    base_initrd: Path,
    kernel_deb: Path,
    arch: str,
    cache_root: Path,
    force: bool = False,
    preseed_cfg: Path | None = None,
) -> tuple[Path, Path]:
    if not base_initrd.is_file():
        raise RuntimeError(f"FATAL: no base initrd at {base_initrd}")
    if not kernel_deb.is_file():
        raise RuntimeError(f"FATAL: kernel .deb missing: {kernel_deb}")
    if preseed_cfg is not None and not preseed_cfg.is_file():
        raise RuntimeError(f"FATAL: preseed.cfg not found: {preseed_cfg}")

    canonical = canonical_encode({
        "schema_version": "cixmini-initrd-t2kernel/v2",
        "arch": arch,
        "base_initrd": _stat(base_initrd),
        "kernel_deb": _stat(kernel_deb),
        "prune_mod_dirs": PRUNE_MOD_DIRS,
        "preseed_cfg": _stat(preseed_cfg) if preseed_cfg is not None else {"present": False},
    })
    node_key = sha256_bytes(canonical)
    node_dir = cache_root / "cixmini-initrd-t2kernel" / node_key
    if node_dir.exists() and not force:
        log(f"node exists: {node_dir}")
        return node_dir / "linux", node_dir / "initrd.gz"
    if node_dir.exists():
        shutil.rmtree(node_dir)
    node_dir.mkdir(parents=True)

    with tempfile.TemporaryDirectory(prefix="patch-t2kernel-") as tmp:
        tmp = Path(tmp)
        deb_extract = tmp / "deb"
        deb_extract.mkdir()
        log(f"    extracting {kernel_deb} -> {deb_extract}")
        subprocess.run(["dpkg-deb", "-x", str(kernel_deb), str(deb_extract)], check=True)

        modules_dirs = sorted((deb_extract / "lib" / "modules").glob("*"))
        if len(modules_dirs) != 1:
            raise RuntimeError(
                f"FATAL: expected exactly one lib/modules/<kver> dir in "
                f"{kernel_deb}, found {len(modules_dirs)}: {modules_dirs}"
            )
        kver = modules_dirs[0].name
        log(f"    real kernel version: {kver}")

        vmlinuz_candidates = sorted((deb_extract / "boot").glob(f"vmlinuz-{kver}"))
        if not vmlinuz_candidates:
            raise RuntimeError(f"FATAL: no boot/vmlinuz-{kver} in {kernel_deb}")
        vmlinuz_src = vmlinuz_candidates[0]

        # --- build the modules overlay -------------------------------
        overlay_root = tmp / "overlay"
        overlay_root.mkdir()
        overlay_modules = overlay_root / "lib" / "modules" / kver
        overlay_modules.parent.mkdir(parents=True)
        shutil.copytree(modules_dirs[0], overlay_modules, symlinks=True)

        for d in PRUNE_MOD_DIRS:
            p = overlay_modules / "kernel" / d
            if p.is_dir():
                shutil.rmtree(p)
                log(f"    pruned kernel/{d}")

        # d-i's kmod udeb cannot decompress .ko.xz -- real, confirmed gotcha.
        xz_mods = list(overlay_modules.rglob("*.ko.xz"))
        if xz_mods:
            subprocess.run(["xz", "-d"] + [str(p) for p in xz_mods], check=True)
            log(f"    decompressed {len(xz_mods)} .ko.xz modules -> plain .ko "
                f"(d-i kmod cannot read xz)")

        subprocess.run(
            ["sudo", "/sbin/depmod", "-a", "-b", str(overlay_root), kver],
            check=True,
        )
        if not (overlay_modules / "modules.dep").is_file():
            raise RuntimeError("FATAL: depmod did not produce modules.dep")
        import os
        subprocess.run(
            ["sudo", "chown", "-R", f"{os.getuid()}:{os.getgid()}", str(overlay_root)],
            check=True,
        )

        # --- bake preseed.cfg into the initrd ROOT -----------------------
        # Real root cause (confirmed on metal 2026-09-24, not a QEMU
        # artifact): our boot path never does a genuine El-Torito CD-ROM
        # boot (kernel+initrd load straight off the ESP via rEFInd/UEFI),
        # so `preseed/file=/cdrom/cixmini/preseed.cfg` depends on
        # cdrom-detect classifying + mounting the medium before that
        # fetch runs -- timing/classification that a real USB-written
        # hybrid medium doesn't guarantee the way QEMU's clean ATAPI
        # CD-ROM emulation did. d-i's OWN initrd-preseed hook
        # (lib/debian-installer-startup.d/S30initrd-preseed) already
        # auto-loads file:///preseed.cfg straight off the initrd
        # filesystem with ZERO device/mount dependency if the file is
        # simply present at the initrd root -- so bake it there instead
        # of fetching it from /cdrom at all.
        if preseed_cfg is not None:
            shutil.copy2(preseed_cfg, overlay_root / "preseed.cfg")
            log(f"    baked {preseed_cfg} -> initrd root /preseed.cfg "
                f"({preseed_cfg.stat().st_size} bytes)")

        # Real usr-merge gotcha (verbatim from build-iso-di.sh): NEVER
        # emit a bare top-level "lib" dir entry, or a later archive's
        # directory-creation deletes the base initrd's lib->usr/lib
        # symlink (and libc/the dynamic loader with it). preseed.cfg is
        # a plain root-level FILE (no directory-creation collision), so
        # it's safe to list explicitly alongside the lib/ walk.
        overlay_cpio_gz = tmp / "overlay.cpio.gz"
        filelist = tmp / "overlay.filelist"
        find_lib = subprocess.run(
            ["find", "lib", "-mindepth", "1", "-print"],
            cwd=overlay_root, check=True, capture_output=True, text=True,
        ).stdout
        with filelist.open("w") as fl:
            fl.write(find_lib)
            if preseed_cfg is not None:
                fl.write("preseed.cfg\n")
        with filelist.open("rb") as fl_in:
            cpio_proc = subprocess.Popen(
                ["cpio", "-o", "-H", "newc", "--quiet"],
                cwd=overlay_root, stdin=fl_in, stdout=subprocess.PIPE,
            )
            with overlay_cpio_gz.open("wb") as out_f:
                with gzip.GzipFile(fileobj=out_f, mode="wb", compresslevel=9) as gz_out:
                    shutil.copyfileobj(cpio_proc.stdout, gz_out)
            cpio_proc.wait()
        if cpio_proc.returncode != 0:
            raise RuntimeError("FATAL: overlay cpio pack failed")
        log(f"    overlay cpio: {overlay_cpio_gz.stat().st_size} bytes")

        # --- concatenate onto the (already firmware-patched) base initrd
        out_initrd = node_dir / "initrd.gz"
        with out_initrd.open("wb") as out_f:
            with base_initrd.open("rb") as base_f:
                shutil.copyfileobj(base_f, out_f)
            with overlay_cpio_gz.open("rb") as ov_f:
                shutil.copyfileobj(ov_f, out_f)

        out_linux = node_dir / "linux"
        shutil.copy2(vmlinuz_src, out_linux)

    receipt = {
        "schema_version": "cixmini-initrd-t2kernel-receipt/v1",
        "node_key": node_key,
        "node_kind": "cixmini-initrd-t2kernel",
        "arch": arch,
        "kver": kver,
        "inputs": {
            "base_initrd": str(base_initrd),
            "base_initrd_sha256": sha256_file(base_initrd),
            "kernel_deb": str(kernel_deb),
            "kernel_deb_sha256": sha256_file(kernel_deb),
            "prune_mod_dirs": PRUNE_MOD_DIRS,
        },
        "outputs": {
            "linux": str(out_linux),
            "linux_sha256": sha256_file(out_linux),
            "linux_size": out_linux.stat().st_size,
            "initrd_gz": str(out_initrd),
            "initrd_gz_sha256": sha256_file(out_initrd),
            "initrd_gz_size": out_initrd.stat().st_size,
        },
    }
    (node_dir / "receipt.json").write_text(json.dumps(receipt, indent=2, sort_keys=True))
    log(f"OK: T2-kernel-patched linux+initrd at {node_dir}")
    return out_linux, out_initrd


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--base-initrd", required=True, type=Path)
    ap.add_argument("--kernel-deb", required=True, type=Path)
    ap.add_argument("--arch", required=True, choices=["amd64", "arm64"])
    ap.add_argument("--cache-root", type=Path, default=DEFAULT_CACHE_ROOT)
    ap.add_argument("--force", action="store_true")
    ap.add_argument("--preseed-cfg", type=Path,
                     default=REPO_ROOT / "preseed" / "preseed.cfg",
                     help="Baked into the initrd root as /preseed.cfg (d-i's "
                          "S30initrd-preseed auto-loads it with zero "
                          "device/mount dependency). Pass --preseed-cfg= "
                          "(empty) to skip.")
    args = ap.parse_args()
    preseed_cfg = args.preseed_cfg if str(args.preseed_cfg) else None
    if preseed_cfg is not None and not preseed_cfg.is_file():
        preseed_cfg = None
        log(f"WARNING: no preseed.cfg at {args.preseed_cfg} -- initrd will "
            f"NOT carry a baked-in preseed")

    try:
        linux_out, initrd_out = patch_t2_kernel(
            args.base_initrd, args.kernel_deb, args.arch,
            args.cache_root, args.force, preseed_cfg,
        )
    except RuntimeError as e:
        log(str(e))
        return 1
    print(f"{linux_out}\n{initrd_out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
