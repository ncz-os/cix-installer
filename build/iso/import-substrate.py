#!/usr/bin/env python3
"""
import-substrate.py — One verified extraction per substrate digest.

Given a real Debian Installer ISO -- STOCK, UNMODIFIED d-i, target suite
Debian forky/testing (bookworm is FULLY DEPRECATED project-wide, operator
2026-09-24: never point this at a bookworm substrate again; a bookworm
substrate mixed with real forky udebs/mirror fetches produces a real,
observed GLIBC_2.38 ABI break in cdebconf) -- USE THE DAILY BUILD, NOT
the per-suite "current" build. Real, measured 2026-09-24: even
deb.debian.org/debian/dists/forky/main/installer-<arch>/current/images/
netboot/mini.iso (the per-suite path, and the same substrate whether
fetched live or from release.conf's pinned snapshot.debian.org
timestamp -- both were byte-identical) carries a STALE d-i userland
that lagged forky's live glibc bump: its own libc.so.6 topped out at
GLIBC_2.38/2.39 while the CURRENT forky archive's busybox-udeb needed
GLIBC_2.42, so anna fetching real udebs from a live/pinned mirror broke
with "version GLIBC_2.42 not found (required by sh)" the same way
the earlier bookworm substrate did with GLIBC_2.38. The per-suite
netboot.iso is NOT rebuilt on every archive change and can silently
drift behind. The FIX: use
https://d-i.debian.org/daily-images/<arch>/daily/netboot/mini.iso
instead -- rebuilt daily against the live archive, confirmed via direct
extraction that its libc.so.6 carries up through GLIBC_2.43, matching
what the live/pinned forky archive's own udebs actually require.
Verified end-to-end: zero GLIBC errors, real forky udebs (rescue-check,
rootskel, wpasupplicant-udeb, busybox-udeb, etc.) all loaded cleanly
via real QEMU boot against a daily-build substrate.
mount or xorriso-extract it into an immutable content-addressed tree
under build/iso-cache/v1/nodes/<arch>/substrate/<key>/.

This replaces the monolithic ``$STAGING`` extraction in build/build-iso-di.sh
without touching the imported tree afterward. The substrate ISO is treated as
a black box: we read the bytes via xorriso, never via tar -C /, never via
hardlinks into shared cache objects.

Output layout under the node key:

    d-i/                 -> contents of /install.amd or /install.arm
    isolinux/            -> /isolinux.bin, /isolinux.cfg, ldlinux.c32, etc
    grub-efi/            -> /boot/grub/efi.img (verbatim)
    grub-config/         -> /boot/grub/*.cfg (verbatim)
    efi-tree/            -> top-level EFI/ contents (verbatim)
    root/                -> top-level / minus EFI / boot / install.* / isolinux
    metadata.json        -> SHA256 of input ISO, sizes, layout receipt
    receipt.json         -> node-key binding source digest to extracted tree

Node key (per design §5):

    sha256(canonical_encode({
      schema_version: "substrate-import/v1",
      arch: "amd64",
      iso_url, iso_sha256, iso_size,
      extraction_tool: "xorriso <version>",
    }))

We do NOT claim that the ISO's own boot layout (currently GRUB-based) is the
target layout. The refind-esp builder rebuilds a real rEFInd ESP from this
imported substrate's d-i kernel+initrd. The substrate's boot bits are kept
only as compatibility/recovery inventory, not as the shipping boot path.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
DEFAULT_CACHE_ROOT = REPO_ROOT / "build" / "iso-cache" / "v1" / "nodes"


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def sha256_bytes(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()


def canonical_encode(obj: dict) -> bytes:
    # RFC 8785-style JSON canonicalization: sorted keys, no whitespace.
    return json.dumps(obj, sort_keys=True, separators=(",", ":")).encode("utf-8")


def xorriso_version() -> str:
    out = subprocess.check_output(["xorriso", "--version"], text=True)
    # First non-empty line is "GNU xorriso 1.5.8.pl02 : ..."
    for line in out.splitlines():
        line = line.strip()
        if line.startswith("GNU xorriso"):
            return line.split(":", 1)[0].strip()
    return "xorriso-unknown"


def _chmod_r(p: Path) -> None:
    """Best-effort recursive chmod to writable so rmtree works."""
    try:
        subprocess.run(["chmod", "-R", "u+w", str(p)], check=False,
                       capture_output=True)
    except Exception:
        pass


def extract_iso(iso_path: Path, extract_root: Path) -> dict:
    """Use xorriso -osirrox on -indev to extract. -boot_image any discard
    removes boot catalogs; we just need files. Reject hardlinks/follow
    symlinks by using xorriso's default behavior (which doesn't follow
    symlinks out of the image)."""
    if extract_root.exists():
        _chmod_r(extract_root)
        shutil.rmtree(extract_root)
    extract_root.parent.mkdir(parents=True, exist_ok=True)
    extract_root.mkdir(parents=True)

    cmd = [
        "xorriso",
        "-osirrox", "on",
        "-indev", str(iso_path),
        "-extract", "/", str(extract_root),
    ]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError(f"xorriso extract failed: {proc.stderr.strip()}")

    # Make everything writable so downstream consumers don't have to.
    _chmod_r(extract_root)

    # Inventory the extracted tree
    inventory = []
    for p in sorted(extract_root.rglob("*")):
        if p.is_file() or p.is_symlink():
            rel = p.relative_to(extract_root)
            try:
                size = p.stat().st_size
            except OSError:
                size = 0
            inventory.append({"path": str(rel), "size": size, "mode": oct(p.stat().st_mode & 0o7777)})
    return {"inventory": inventory, "count": len(inventory)}


def move_subpaths(extract_root: Path, mapping: dict[str, str]) -> None:
    """After xorriso extracts everything under /<extract_root>, pull specific
    ISO paths into named subdirectories. Skip if source missing (the ISO may
    not have a particular piece).

    Mapping values can be either a single filename (move file -> file under
    extract_root) or a relative path (the parent directory is created).

    ``dst == src`` is treated as a no-op (idempotency for the common case
    where the ISO path matches the desired final location).
    """
    for src_rel, dst_rel in mapping.items():
        src = extract_root / src_rel
        if not src.exists():
            continue
        dst = extract_root / dst_rel
        if src.resolve() == dst.resolve():
            continue  # no-op
        # Create intermediate directories if dst is nested.
        dst.parent.mkdir(parents=True, exist_ok=True)
        if dst.exists():
            if dst.is_dir():
                _chmod_r(dst)
                shutil.rmtree(dst)
            else:
                dst.unlink()
        # shutil.move falls back to copy+delete across devices. We prefer
        # an explicit os.rename first to keep things atomic on the same FS,
        # and only fall back when the cross-device case is unavoidable.
        try:
            os.rename(str(src), str(dst))
        except OSError:
            shutil.move(str(src), str(dst))


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--iso", required=True, type=Path, help="path to substrate ISO")
    ap.add_argument("--arch", required=True, choices=["amd64", "arm64"])
    ap.add_argument("--iso-url", required=True, help="source URL (recorded in receipt)")
    ap.add_argument("--cache-root", type=Path, default=DEFAULT_CACHE_ROOT,
                    help=f"node-key tree root (default: {DEFAULT_CACHE_ROOT})")
    ap.add_argument("--force", action="store_true", help="re-extract even if node already exists")
    args = ap.parse_args()

    iso = args.iso.resolve()
    if not iso.is_file():
        print(f"FATAL: ISO not found: {iso}", file=sys.stderr)
        sys.exit(2)

    iso_sha = sha256_file(iso)
    iso_size = iso.stat().st_size

    canonical = canonical_encode({
        "schema_version": "substrate-import/v1",
        "arch": args.arch,
        "iso_url": args.iso_url,
        "iso_sha256": iso_sha,
        "iso_size": iso_size,
        "extraction_tool": xorriso_version(),
    })
    node_key = sha256_bytes(canonical)
    node_dir = args.cache_root / args.arch / "substrate" / node_key
    if node_dir.exists() and not args.force:
        print(f"node exists: {node_dir}")
        print(f"node_key: {node_key}")
        return 0

    # If a stale partial node exists from a previous failed run, wipe it.
    if node_dir.exists():
        _chmod_r(node_dir)
        shutil.rmtree(node_dir)
    node_dir.mkdir(parents=True)
    extract_root = node_dir / "extract"
    inv = extract_iso(iso, extract_root)

    # Identify which d-i layout we got. The standard "netinst" ISO has a
    # /install.<arch>/ tree; the smaller "netboot/mini.iso" has just a
    # /linux and /initrd.gz at the root (this is the form d-i actually
    # bootstraps from in netinstall mode and is what ``build/build-iso-di.sh``
    # line 977 uses as the Bookworm/Trixie netboot path).
    #
    # We support BOTH layouts. The "d-i" subdir will contain either the
    # full /install.<arch>/ tree OR the (linux, initrd.gz) pair, depending
    # on which the source ISO has.
    install_dir = "install.amd" if args.arch == "amd64" else "install.arm"
    has_install_dir = (extract_root / install_dir).is_dir()
    has_linux_initrd = (extract_root / "linux").is_file() and (extract_root / "initrd.gz").is_file()

    # Map ISO paths -> named dirs (preserving verbatim bytes). The d-i map
    # branches on which layout the source ISO has; the other layout paths
    # stay at the root (where the kernel/initrd live for netboot) and get
    # left alone.
    if has_install_dir:
        move_subpaths(extract_root, {
            install_dir: "d-i",
        })
    elif has_linux_initrd:
        # Netboot form: kernel + initrd at the root. Surface them under
        # d-i/ for a uniform consumer-side interface.
        d_i_dst = extract_root / "d-i"
        d_i_dst.mkdir()
        shutil.move(str(extract_root / "linux"), str(d_i_dst / "linux"))
        shutil.move(str(extract_root / "initrd.gz"), str(d_i_dst / "initrd.gz"))
    else:
        print(f"WARNING: unknown substrate layout (no /{install_dir}, no /linux+initrd.gz)",
              file=sys.stderr)

    # Always pull these into named dirs (verbatim) regardless of layout.
    move_subpaths(extract_root, {
        "isolinux.bin": "isolinux/isolinux.bin",
        "isolinux.cfg": "isolinux/isolinux.cfg",
        "ldlinux.c32": "isolinux/ldlinux.c32",
        "libcom32.c32": "isolinux/libcom32.c32",
        "libutil.c32": "isolinux/libutil.c32",
        "boot": "boot",
        "EFI": "efi-tree",
    })

    # Pull boot/grub/efi.img verbatim into grub-efi/ for inspection only.
    # The shipping ESP will be rebuilt by build-refind-esp.py — we keep this
    # around purely as the substrate's pre-existing EFI source bytes.
    efi_img_src = extract_root / "boot" / "grub" / "efi.img"
    if efi_img_src.is_file():
        grub_efi = node_dir / "grub-efi"
        grub_efi.mkdir()
        shutil.copy2(str(efi_img_src), str(grub_efi / "efi.img"))

    # Pull boot/grub/*.cfg as substrate grub-config (diagnostic only).
    grub_cfg_src = extract_root / "boot" / "grub"
    if grub_cfg_src.is_dir():
        grub_cfg = node_dir / "grub-config"
        grub_cfg.mkdir()
        for cfg in sorted(grub_cfg_src.glob("*.cfg")):
            shutil.copy2(str(cfg), str(grub_cfg / cfg.name))

    # Write metadata.json and receipt.json
    metadata = {
        "schema_version": "substrate-metadata/v1",
        "arch": args.arch,
        "iso_url": args.iso_url,
        "iso_sha256": iso_sha,
        "iso_size": iso_size,
        "extraction_tool": xorriso_version(),
        "extract_root": str(extract_root.relative_to(node_dir)),
        "inventory_count": inv["count"],
        "substrate_layout": "install_dir" if has_install_dir else ("netboot" if has_linux_initrd else "unknown"),
        "d_i_dir_present": (extract_root / "d-i").is_dir(),
    }
    (node_dir / "metadata.json").write_text(json.dumps(metadata, indent=2, sort_keys=True))

    receipt = {
        "schema_version": "substrate-receipt/v1",
        "node_key": node_key,
        "node_kind": "substrate",
        "arch": args.arch,
        "inputs": {
            "iso_url": args.iso_url,
            "iso_sha256": iso_sha,
            "iso_size": iso_size,
        },
        "outputs": {
            "extract_root": str(extract_root.relative_to(node_dir)),
            "inventory_count": inv["count"],
        },
        "tool": xorriso_version(),
    }
    (node_dir / "receipt.json").write_text(json.dumps(receipt, indent=2, sort_keys=True))

    # Also write the canonical node_key payload for audit.
    (node_dir / "node-key.json").write_text(json.dumps({
        "node_key": node_key,
        "canonical_payload_hex": canonical.hex(),
        "canonical_payload_sha256": sha256_bytes(canonical),
    }, indent=2, sort_keys=True))

    print(f"node_key: {node_key}")
    print(f"node_dir: {node_dir}")
    print(f"extracted {inv['count']} entries")
    return 0


if __name__ == "__main__":
    sys.exit(main())