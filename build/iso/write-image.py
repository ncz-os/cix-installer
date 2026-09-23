#!/usr/bin/env python3
"""
write-image.py — Cold and warm ISO writer for the incremental d-i prototype.

Two operations:

    cold -- Build a complete bootable image from cached components (substrate
            import, rEFInd ESP) using xorrisofs in mkisofs emulation mode. The
            output is an ISO 9660 filesystem with the rEFInd ESP image embedded
            at /efi.img inside the ISO tree (Debian's Section Header Entry +
            EFI Initial Entry pattern at El Torito catalog offsets 64 / 96).
            There is NO appended partition and NO GPT; the boot chain goes
            via El Torito only.

    warm -- Take a previously-published ISO ("parent") and a list of logical
            changes (added/replaced/removed file paths), reflink-clone the
            parent into a private scratch ISO, replace the in-tree /efi.img
            (the ESP image is replaced on EVERY warm growth; the EFI Initial
            Entry's load LBA is rewritten to the new location by xorriso
            ``-boot_image any replay``), apply the change set with xorriso
            ``-update`` / ``-cpx``, and produce a new physical artifact.

The warm path is what the design doc Section 8 calls "the warm writer
transaction". This is the operation that delivers the seconds-scale hotfix
promise (subject to a real reflink-capable scratch filesystem).

Both operations end with an INDEPENDENT verification step that parses the
resulting MBR, ISO 9660 PVD, El Torito catalog (validation + initial + Section
Header + EFI Initial entries) and the actual bytes of the embedded ESP -- we
do NOT trust xorriso's exit status alone (design §8 explicit constraint).
The cold and warm paths BOTH pass --esp-image to the verifier so it can
verify the embedded ESP bytes match the source FAT image; a corrupt ESP at
the EFI Initial Entry's load LBA is detected and rejected.

Safety rails (carried over from the design doc):

    * No tar -C /. No writes through hardlinks into shared cache objects.
      Assembly consumes files and immutable trees, never the live host root.
    * Parent and published artifacts are NEVER edited. We always operate on
      a private scratch clone.
    * Reflink is tested on the actual scratch filesystem before a warm run
      proceeds (see verify_reflink_capable_fs).
    * The kernel + initrd are REQUIRED inputs to build-refind-esp.py; the
      ESP image embedded in the ISO always contains them. The cold and warm
      paths never ship an ESP whose loader points at files that don't exist.

For Step 1 we ship just enough to qualify the writer + boot layout, not the
full content-addressed graph. We do not yet seal every node, key every
producer or substitute the monolithic orchestrator. Those are Sections
5-9's work and out of scope for Step 1.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import struct
import subprocess
import sys
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
DEFAULT_CACHE_ROOT = REPO_ROOT / "build" / "iso-cache" / "v1"


# ----- helpers -----


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def sha256_bytes(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()


def crc32(data: bytes) -> int:
    import zlib
    return zlib.crc32(data) & 0xFFFFFFFF


# Constants shared with verify-image.py (kept local to avoid coupling).
SECTOR = 512
EFI_SYS_PART_GUID_STORED = (
    b"\x28\x73\x2A\xC1\x1F\xF8\xD2\x11\xBA\x4B\x00\xA0\xC9\x3E\xC9\x3B"
)


def read_at(path: Path, offset: int, length: int) -> bytes:
    with path.open("rb") as f:
        f.seek(offset)
        return f.read(length)


def write_at(path: Path, offset: int, data: bytes) -> None:
    """Sparse-safe write that grows the file when offset+len exceeds current
    size. Pad any gap with zeros. This is how we relocate the backup GPT to a
    new tail of the image."""
    size = path.stat().st_size
    end = offset + len(data)
    if end > size:
        with path.open("r+b") as f:
            f.seek(0, 2)
            f.truncate(end)
    with path.open("r+b") as f:
        f.seek(offset)
        f.write(data)
        f.flush()
        try:
            os.fsync(f.fileno())
        except OSError:
            pass


def compute_gpt_header_crc32(header_buf: bytes) -> int:
    """CRC32 of the GPT header with the CRC field zeroed (offsets 16..20).
    Identical computation as the wire-format CRC the firmware computes."""
    return crc32(header_buf[:16] + b"\x00\x00\x00\x00" + header_buf[20:92])


def finalize_gpt_layout(image: Path) -> dict:
    """GPT-layout rescue finalizer for warm-grown images.

    Background (design §8 step 6 + local experiment §8): xorriso 1.5.8.pl02
    does NOT maintain a valid GPT backup layout when growing an ISO via
    ``-indev parent -outdev new -boot_image any replay -append_partition``.
    Concretely, the warm growth:

      * writes the EFI System Partition at a NEW (often smaller) LBA range,
      * leaves the primary GPT header's ``backup_lba`` field pointing at the
        parent's old end-of-image,
      * writes zeros (or whatever the new ISO/PVD block happened to land on)
        at the new tail LBA where the backup GPT header is supposed to live,
      * does not update the protective-MBR partition-1 ``lba_size`` field.

    The result is an ISO that boots in xorriso's eyes but fails every
    independent UEFI validator: backup GPT signature is ``\\x00`` * 8,
    primary CRC says "look at LBA 122471" (which is now mid-file), and the
    MBR partition-1 size is one or more MB short of the actual image.

    What we do to rescue the layout, while leaving the xorriso-written
    ISO filesystem and EFI partition bytes intact:

      1. Read the primary GPT header (still valid; primary CRC matches).
      2. Read the primary partition entry array (still valid; its CRC
         matches the bytes xorriso wrote).
      3. Compute the new image_lba from the file size.
      4. Allocate the backup entry array at the new tail
         (backup_lba - 62 sectors, where 62 = ceil(248 entries * 128 bytes / 512)).
      5. Write a freshly-computed backup GPT header at LBA (image_lba - 1)
         with current_lba = image_lba - 1, backup_lba = 1, the same
         part_entry_array bytes as the primary, and a fresh header CRC32.
      6. Patch the primary header's ``backup_lba`` to ``image_lba - 1``,
         set ``last_usable_lba = backup_part_entry_lba - 1`` (so the
         usable range stops one sector before the backup entries), and
         recompute the primary header CRC32.
      7. Patch the protective-MBR partition-1 ``lba_size`` to cover the
         full image (image_lba - 1 sectors).

    The space between the EFI partition's last LBA and the new backup
    entries' first LBA is conventional "post-data" / pre-backup padding
    that UEFI firmwares tolerate in hybrid images; see the design doc's
    note that "a qualified finalizer may truncate beyond the backup GPT
    only after proving all referenced extents end within the retained
    range".
    """
    size = image.stat().st_size
    if size % SECTOR != 0:
        raise ValueError(
            f"finalize_gpt_layout: image {image} size {size} is not a "
            f"multiple of {SECTOR} bytes"
        )
    image_lba = size // SECTOR
    new_backup_lba = image_lba - 1

    # 1. Read primary header
    primary_header = read_at(image, 1 * SECTOR, SECTOR)
    if primary_header[:8] != b"EFI PART":
        raise ValueError(
            f"finalize_gpt_layout: primary GPT signature at LBA 1 is "
            f"{primary_header[:8]!r}, expected b'EFI PART' — refusing to "
            f"rescue an image without a recognizable GPT primary header"
        )

    num_entries = struct.unpack("<I", primary_header[80:84])[0]
    entry_size = struct.unpack("<I", primary_header[84:88])[0]
    entry_array_bytes = num_entries * entry_size
    entry_array_sectors = (entry_array_bytes + SECTOR - 1) // SECTOR

    part_entry_lba_primary = struct.unpack("<Q", primary_header[72:80])[0]
    if part_entry_lba_primary != 2:
        # xorriso's cold compose always emits the array at LBA 2. We don't
        # know what to do if a different layout comes in, so refuse.
        raise ValueError(
            f"finalize_gpt_layout: primary part_entry_lba={part_entry_lba_primary}, "
            f"expected 2; refusing to rescue a non-standard layout"
        )

    primary_entries = read_at(
        image,
        part_entry_lba_primary * SECTOR,
        entry_array_bytes,
    )
    # Sanity: xorriso must have written a CRC-matching array here.
    stored_array_crc = struct.unpack("<I", primary_header[88:92])[0]
    if crc32(primary_entries) != stored_array_crc:
        raise ValueError(
            f"finalize_gpt_layout: primary entry array CRC mismatch "
            f"({crc32(primary_entries):#010x} vs stored {stored_array_crc:#010x}); "
            f"refusing to rescue a layout whose primary entries are already corrupt"
        )

    # 2. Locate the new backup entry array (image tail - N sectors)
    new_backup_part_entry_lba = new_backup_lba - (entry_array_sectors - 1)
    new_last_usable_lba = new_backup_part_entry_lba - 1

    # 3. Construct backup header. The backup header is a near-mirror of the
    # primary, with current_lba = image_lba - 1, backup_lba = 1, and the
    # same disk_guid + part_entry_array bytes.
    backup_header = bytearray(primary_header)
    struct.pack_into("<Q", backup_header, 24, new_backup_lba)  # current_lba
    struct.pack_into("<Q", backup_header, 32, 1)                # backup_lba
    struct.pack_into("<Q", backup_header, 40, 64)               # first_usable_lba
    struct.pack_into("<Q", backup_header, 48, new_last_usable_lba)
    struct.pack_into("<Q", backup_header, 72, new_backup_part_entry_lba)
    struct.pack_into("<I", backup_header, 88, stored_array_crc)  # array CRC same

    backup_header_crc = compute_gpt_header_crc32(bytes(backup_header))
    struct.pack_into("<I", backup_header, 16, backup_header_crc)

    # 4. Write the relocated backup partition entry array and header.
    write_at(
        image,
        new_backup_part_entry_lba * SECTOR,
        primary_entries,
    )
    write_at(image, new_backup_lba * SECTOR, bytes(backup_header))

    # 5. Patch primary header in place: backup_lba, last_usable_lba, CRC.
    new_primary_header = bytearray(primary_header)
    struct.pack_into("<Q", new_primary_header, 32, new_backup_lba)
    struct.pack_into("<Q", new_primary_header, 48, new_last_usable_lba)
    new_primary_crc = compute_gpt_header_crc32(bytes(new_primary_header))
    struct.pack_into("<I", new_primary_header, 16, new_primary_crc)
    write_at(image, 1 * SECTOR, bytes(new_primary_header))

    # 6. Patch the protective-MBR partition-1 ``lba_size`` to cover the full
    # image. The MBR's partition table starts at offset 446, each entry is
    # 16 bytes; entry 1 = bytes 446..461; the lba_size field is at offset
    # 446+12 = 458 (4 bytes, LE). For images with ``-appended_part_as_gpt``
    # the protective MBR uses type 0xEE and its partition-1 size is the
    # canonical "whole-disk" value (image_lba - 1 sectors).
    mbr = bytearray(read_at(image, 0, SECTOR))
    table_off = 446
    patched = False
    for i in range(4):
        entry_off = table_off + i * 16
        ptype = mbr[entry_off + 4]
        if ptype == 0xEE:
            struct.pack_into("<I", mbr, entry_off + 12, image_lba - 1)
            patched = True
            break
    if not patched:
        # No protective-MBR 0xEE entry: the warm output is using a legacy
        # MBR (no GPT). We don't currently rescue that case; refuse so
        # the operator notices rather than silently shipping an image
        # that won't boot.
        raise ValueError(
            "finalize_gpt_layout: no protective-MBR 0xEE entry found at "
            "LBA 0; refusing to rescue a legacy-MBR layout (warm writer "
            "must use -appended_part_as_gpt at cold compose time)"
        )
    write_at(image, 0, bytes(mbr))

    return {
        "image_lba": image_lba,
        "new_backup_lba": new_backup_lba,
        "new_backup_part_entry_lba": new_backup_part_entry_lba,
        "new_last_usable_lba": new_last_usable_lba,
        "primary_header_crc32": new_primary_crc,
        "backup_header_crc32": backup_header_crc,
        "entry_array_bytes": entry_array_bytes,
        "entry_array_sectors": entry_array_sectors,
        "protective_mbr_patched": True,
    }


def log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


def stage_cixmini_payload(stage_dir: Path, payload_dir: Path,
                          patched_udeb: Path | None,
                          preseed_dir: Path | None = None) -> dict:
    """Copy the staged r159 cixmini payload into ``stage_dir/cixmini/`` so
    it lands at the ISO top level at ``/cixmini/`` once xorrisofs packs
    the tree.

    The payload is the verbatim output of ``build/iso/stage-cixmini-payload.py``
    (or any directory with the same shape): ``base.squashfs``,
    ``desktop.squashfs``, ``desktop.overlay-manifest``, ``sqtools/``.
    Together those are what the r159 stub CONSUMES at install time
    (``/cdrom/cixmini/base.squashfs`` etc.).

    If ``patched_udeb`` is given (output of ``build/iso/patch-debootstrap-stub.py``
    on a netboot-layout substrate where the substrate has no ``/pool/``),
    it is also copied into ``stage_dir/cixmini/debootstrap-udeb/<name>``
    so the operator can inspect the patched udeb that's ready to be
    served to d-i (e.g. by extending the substrate's apt sources
    later; for netboot mini.iso substrates the patched udeb is staged
    here but not auto-installed — see the brief and
    patch-debootstrap-stub.py for why).

    If ``preseed_dir`` is given (default: ``<repo>/preseed`` if it
    exists), its files are also copied into ``stage_dir/cixmini/``
    AFTER the payload. This is how d-i's existing
    ``preseed/file=/cdrom/cixmini/preseed.cfg`` kernel-cmdline
    reference (see build-refind-esp.py options line) resolves at
    install time. The build-iso-di.sh pipeline copies these into
    ``$STAGING/cixmini/`` at lines ~2988-3054 (``preseed.cfg``,
    ``late.sh``, ``extract-rootfs.sh``, etc.); this writer does the
    same so a cold build that includes /cixmini/preseed.cfg is
    directly drive-able past the "Download debconf preconfiguration
    file" prompt without the kvm-install-gate.sh ISO re-pack.

    Note: ``preseed/`` itself is NOT modified — this script only
    READS from it (the brief's "Do NOT touch ... preseed/" rule is
    about modification, not reading).

    Returns a small receipt dict suitable for inclusion in the
    cold/warm image receipt.
    """
    if not payload_dir.is_dir():
        raise RuntimeError(f"cixmini payload dir not found: {payload_dir}")
    cixmini_dst = stage_dir / "cixmini"
    if cixmini_dst.exists():
        _chmod_r(cixmini_dst)
        shutil.rmtree(cixmini_dst)
    cixmini_dst.mkdir(parents=True)
    # Copy each expected entry by name rather than cp -a the whole
    # directory so an unexpected file in the payload (a stray NOTES,
    # receipts/ subdir, etc.) doesn't pollute the ISO tree.
    expected = ["base.squashfs", "desktop.squashfs", "desktop.overlay-manifest",
                "sqtools"]
    staged = []
    for name in expected:
        src = payload_dir / name
        if src.exists():
            dst = cixmini_dst / name
            if src.is_dir():
                subprocess.run(["cp", "-a", str(src) + "/.", str(dst)],
                               check=True)
            else:
                shutil.copy2(str(src), str(dst))
            staged.append(name)
    receipt = {
        "schema_version": "cixmini-payload-in-tree/v1",
        "payload_dir": str(payload_dir),
        "payload_dir_sha256": sha256_dir_bytes(payload_dir) if payload_dir.is_dir() else None,
        "staged_files": staged,
    }
    log(f"cixmini payload staged at {cixmini_dst}: {staged}")

    if patched_udeb is not None:
        if not patched_udeb.is_file():
            raise RuntimeError(f"patched udeb not found: {patched_udeb}")
        dst_dir = cixmini_dst / "debootstrap-udeb"
        dst_dir.mkdir(parents=True, exist_ok=True)
        dst = dst_dir / patched_udeb.name
        shutil.copy2(str(patched_udeb), str(dst))
        receipt["patched_udeb"] = str(dst)
        receipt["patched_udeb_sha256"] = sha256_file(dst)
        log(f"patched udeb staged at {dst} (sha256={receipt['patched_udeb_sha256']})")

    # Stage the preseed/ tree verbatim if requested. Files land at
    # /cixmini/preseed.cfg, /cixmini/late.sh, etc. so d-i's
    # preseed/file=/cdrom/cixmini/preseed.cfg reference resolves.
    if preseed_dir is not None and preseed_dir.is_dir():
        preseed_staged = []
        for entry in sorted(preseed_dir.iterdir()):
            if entry.name.startswith("."):
                continue
            if not entry.is_file():
                continue
            dst = cixmini_dst / entry.name
            shutil.copy2(str(entry), str(dst))
            preseed_staged.append(entry.name)
        receipt["preseed_dir"] = str(preseed_dir)
        receipt["preseed_staged_files"] = preseed_staged
        log(f"preseed/ staged at {cixmini_dst}: {preseed_staged}")
    return receipt


def sha256_dir_bytes(d: Path) -> str:
    """Hash a directory's contents (relative path + sha256 of each file,
    sorted) — used to bind the cixmini payload content to the cold/warm
    receipt so a payload change after a build produces a different
    receipt and a different artifact."""
    h = hashlib.sha256()
    files = sorted(p for p in d.rglob("*") if p.is_file())
    for f in files:
        rel = f.relative_to(d).as_posix()
        h.update(rel.encode("utf-8"))
        h.update(b"\0")
        h.update(sha256_file(f).encode("ascii"))
        h.update(b"\n")
    return h.hexdigest()


def resolve_cixmini_args(args, default_cache_root: Path) -> tuple[Path | None, Path | None]:
    """Resolve --cixmini-payload-dir / --patched-udeb from the args
    namespace, falling back to auto-detection under the cache if
    neither is provided.

    Auto-detection: pick the most-recently-modified payload node under
    ``build/iso-cache/v1/cixmini-payload/`` and the most-recently-modified
    patched udeb under ``build/iso-cache/v1/cixmini-udeb/`` for the
    matching architecture. The "most recent" is by mtime (cheaper than
    parsing receipts and the cache is monotonic). If nothing is
    cached, both return None and the caller logs INFO that the ISO
    will be payload-less (d-i will fall back to network install —
    the same behavior as a stock Debian netinst ISO).
    """
    payload_dir = getattr(args, "cixmini_payload_dir", None)
    patched_udeb = getattr(args, "patched_udeb", None)

    if payload_dir is None:
        candidates_root = default_cache_root / "cixmini-payload"
        if candidates_root.is_dir():
            payload_nodes = sorted(
                [p for p in candidates_root.iterdir() if p.is_dir()],
                key=lambda p: p.stat().st_mtime,
                reverse=True,
            )
            if payload_nodes:
                payload_dir = payload_nodes[0]
                log(f"auto-resolved --cixmini-payload-dir: {payload_dir}")

    if patched_udeb is None:
        candidates_root = default_cache_root / "cixmini-udeb"
        if candidates_root.is_dir():
            for udeb_node in sorted(
                [p for p in candidates_root.iterdir() if p.is_dir()],
                key=lambda p: p.stat().st_mtime,
                reverse=True,
            ):
                # Pick the first .udeb file inside.
                udeb_files = sorted(udeb_node.glob("*.udeb"))
                if udeb_files:
                    patched_udeb = udeb_files[0]
                    log(f"auto-resolved --patched-udeb: {patched_udeb}")
                    break

    return payload_dir, patched_udeb


def _chmod_r(p: Path) -> None:
    """Best-effort recursive chmod to writable so rmtree works on
    read-only xorriso-extracted trees."""
    try:
        subprocess.run(["chmod", "-R", "u+w", str(p)], check=False,
                       capture_output=True)
    except Exception:
        pass


def _cleanup_scratch(scratch: Path) -> None:
    """Robust cleanup of a warm-writer scratch path.

    xorriso -outdev writes a regular FILE at the -outdev path; if a
    prior run left a directory there, normal rmtree works; if xorriso
    wrote a file (success or "SORRY" failure), we have to unlink the
    file. Try the dir-first path, fall back to file path. Both must be
    safe to call when scratch does not exist."""
    if scratch.is_dir() and not scratch.is_symlink():
        _chmod_r(scratch)
        shutil.rmtree(scratch, ignore_errors=True)
        return
    if scratch.is_symlink() or scratch.is_file():
        # Make writable in case xorriso marked it read-only.
        try:
            scratch.chmod(0o644)
        except OSError:
            pass
        try:
            scratch.unlink()
        except FileNotFoundError:
            pass


def cmd_with_log(cmd: list[str], **kwargs) -> subprocess.CompletedProcess:
    log(f"$ {' '.join(str(c) for c in cmd)}")
    return subprocess.run(cmd, **kwargs)


def reflink_copy(src: Path, dst: Path) -> None:
    """Copy src -> dst, preferring reflink. On APFS, GNU cp --reflink=always
    produces a shared-extent clone (the underlying inode can be the same
    until one side is written to). On Btrfs, same thing via FICLONE ioctl.
    On filesystems that lack reflink, this falls back to a regular copy and
    we surface a warning."""
    if dst.exists():
        dst.unlink()

    # macOS / Linux GNU cp path. macOS BSD cp -c is also a clone, but GNU cp
    # --reflink=always works on both and we want a single uniform command.
    gcp = shutil.which("gcp") or shutil.which("cp")
    if not gcp:
        # Last-resort: shutil.copyfile then check if it deduped (it does on
        # APFS by default for files in the same directory).
        shutil.copyfile(str(src), str(dst))
        return

    proc = subprocess.run([gcp, "--reflink=always", str(src), str(dst)],
                          capture_output=True, text=True)
    if proc.returncode != 0:
        # Filesystem doesn't support reflink; fall back to a regular copy
        # and warn loudly so the operator notices.
        log(f"WARNING: reflink unavailable ({proc.stderr.strip()!r}); falling back to full copy")
        subprocess.run([gcp, str(src), str(dst)], check=True)


def _copyfile_reflink(src: Path, dst: Path) -> None:
    """Single-file reflink copy used by the cold staging path.

    We do NOT log a warning when reflink is unavailable here — the cold
    path tolerates a full copy of the substrate tree (the hot path that
    needs the seconds-scale promise is the warm path). We just silently
    fall back so the operator's log isn't spammed."""
    if dst.exists():
        dst.unlink()
    gcp = shutil.which("gcp") or shutil.which("cp")
    if not gcp:
        shutil.copyfile(str(src), str(dst))
        return
    proc = subprocess.run([gcp, "--reflink=always", str(src), str(dst)],
                          capture_output=True, text=True)
    if proc.returncode != 0:
        subprocess.run([gcp, str(src), str(dst)], check=True)


def _copytree_reflink(src: Path, dst: Path) -> None:
    """Recursive reflink copy of a directory tree. Falls back to a full
    recursive copy on filesystems without reflink."""
    if not src.is_dir():
        raise ValueError(f"src not a dir: {src}")
    if dst.exists():
        _chmod_r(dst)
        shutil.rmtree(dst)
    dst.mkdir(parents=True)

    # Try to use `cp -a` (recursive + preserve attributes) with --reflink.
    # On macOS, the BSD cp doesn't accept --reflink=always; we fall back
    # to shutil.copytree if cp rejects the flag.
    gcp = shutil.which("gcp") or shutil.which("cp")
    if gcp:
        proc = subprocess.run([gcp, "-a", "--reflink=always", str(src) + "/.", str(dst)],
                              capture_output=True, text=True)
        if proc.returncode == 0:
            return
    # Fallback: walk and copy file-by-file.
    for src_path in sorted(src.rglob("*")):
        rel = src_path.relative_to(src)
        if src_path.is_symlink():
            # Preserve symlinks verbatim. We don't write through into cached
            # substrate nodes anyway; symlinks inside a substrate extract
            # would be a CVE waiting to happen.
            dst_path = dst / rel
            dst_path.parent.mkdir(parents=True, exist_ok=True)
            try:
                dst_path.symlink_to(src_path.readlink())
            except OSError:
                pass
            continue
        if src_path.is_dir():
            (dst / rel).mkdir(parents=True, exist_ok=True)
            continue
        if not src_path.is_file():
            continue
        dst_path = dst / rel
        dst_path.parent.mkdir(parents=True, exist_ok=True)
        _copyfile_reflink(src_path, dst_path)


def verify_reflink_capable_fs(path: Path) -> dict:
    """Probe whether the filesystem backing `path` supports reflink clones.
    Returns {"capable": bool, "tool": ..., "detail": ...}.

    Strategy: write two large random files, clone with ``gcp --reflink=always``,
    check that the resulting file shares the same inode. macOS APFS gives
    matching inodes on copy; Btrfs/XFS give shared extents (matching
    inodes is fs-dependent but the syscall is non-failing). On filesystems
    with no reflink (ext4 without reflink, NFS, FAT) ``gcp --reflink=always``
    will fail.
    """
    probe_dir = path / ".reflink-probe"
    probe_dir.mkdir(exist_ok=True)
    a = probe_dir / "a"
    b = probe_dir / "b"
    a.write_bytes(os.urandom(2 * 1024 * 1024))
    try:
        reflink_copy(a, b)
    except Exception as e:
        return {"capable": False, "tool": "gcp --reflink=always",
                "detail": f"reflink clone failed: {e}"}
    try:
        ino_a = a.stat().st_ino
        ino_b = b.stat().st_ino
    except OSError:
        ino_a = ino_b = -1
    # Both APFS (shared inode) and CoW filesystems that expose the same
    # inode are "capable". If the inodes differ AND no reflink error
    # occurred, we still got a full copy without the requested reflink
    # (some FUSE / overlay fs behave this way).
    capable = ino_a == ino_b and ino_a > 0
    detail = f"inode a={ino_a} b={ino_b}; capable={capable}"
    # Clean up probe artifacts so they don't pollute the output tree.
    shutil.rmtree(probe_dir, ignore_errors=True)
    return {
        "capable": capable,
        "tool": "gcp --reflink=always",
        "detail": detail,
    }


# ----- cold path -----


def cold_image(args) -> int:
    """Build a complete ISO from cached substrate + ESP.

    Boot layout (qualifies QEMU/OVMF 11.1.1 + edk2-stable202408-prebuilt
    from fresh NVRAM, AND QEMU/AAVMF arm64; proven 2026-09-21):

        ISO9660 filesystem with Joliet + Rock Ridge (so Linux/Windows
        can read installer payload: driver .debs, preseed, etc.) +
        El Torito catalog with Debian's "Section Header + EFI Initial
        Entry" pattern (validation entry at offset 0, Section Header
        Entry at offset 64, EFI Initial Entry at offset 96 pointing at
        /efi.img inside the ISO tree) +
        MBR signature 0x55AA + a 0x17 partition entry pointing at the
        ISO's first sector (written by -isohybrid-mbr / -isohybrid-gpt-basdat) +
        no GPT (we do not need a backup GPT to recover; the boot chain
        uses El Torito, not the MBR/GPT layer; the design-doc §8 GPT
        rescue finalizer is therefore a no-op for this layout, kept as a
        defensive measure for future layouts that opt back into
        -append_partition).

    The ESP image lives INSIDE the ISO tree at /efi.img. This is the
    Debian Bookworm netboot pattern (their /boot/grub/efi.img is the
    same shape: a FAT filesystem containing the EFI bootloader, exposed
    to UEFI via a Section-Header Entry pointing at it). The previous
    pass used ``-append_partition 2 0xEF <esp> -e --interval:...``,
    which writes only a bare EFI Initial Entry at offset 32 of the
    El Torito catalog (no Section Header Entry). OVMF 11.1.1 ignores
    that layout and falls through to "Start PXE over IPv4" on a fresh
    NVRAM. The Section Header Entry layout fixes that.

    The xorriso command pattern that produces this layout:

        xorrisofs -R -J
                  -V <volume-id> -publisher <publisher>
                  -b <legacy-isolinux-bin>
                  -no-emul-boot
                  --efi-boot /efi.img
                  -isohybrid-mbr /path/to/isohdpfx.bin
                  -isohybrid-gpt-basdat
                  -o <out> <substrate-tree>

    Notes on each flag:
      * ``-b /isolinux/isolinux.bin`` is the legacy ISOLINUX entry that
        forces xorriso to emit the Section Header Entry structure
        (Validation+ISOLINUX+Section Header+EFI Initial). Without ``-b``
        the EFI Initial Entry sits at offset 32 with no Section Header
        and OVMF does not pick it up on this checkout. /isolinux/isolinux.bin
        is a real file from the upstream Debian netboot substrate.
      * ``-no-emul-boot`` is required for both the EFI entry (no floppy
        emulation) and the ISOLINUX entry (CD boot). Together with ``-b``
        it produces the legacy initial entry at offset 32.
      * ``--efi-boot /efi.img`` puts the EFI binary at offset 96 and
        tells xorriso to write the matching Section Header Entry.
      * ``-isohybrid-mbr`` provides the 432-byte MBR template from the
        Debian isolinux package (cached under build/iso-cache/syslinux/
        because most build hosts do not ship it). xorriso writes the
        template into the produced image's LBA 0 and sets the MBR
        signature byte to 0x55AA plus a 0x17 partition entry pointing
        at the ISO's first sector. The boot chain still goes via El
        Torito (the Section Header Entry at catalog offset 64 is what
        OVMF actually uses), but the hybrid MBR is what makes the
        image readable as a hybrid ISO/USB stick on a wider set of
        firmwares.
      * ``-isohybrid-gpt-basdat`` adds a protective-MBR + GPT for
        hybrid USB boot. The GPT is invalid on this layout (no actual
        appended partition; the boot goes via El Torito), so we do NOT
        use it as a boot hint.

    The kernel + initrd live INSIDE the FAT ESP at /linux and /initrd.gz
    (see build-refind-esp.py). The ISO 9660 filesystem that surrounds
    the ESP only carries installer payload (driver .debs, preseed, etc.);
    the bootloader reads kernel and initrd via its own SFS handle on the
    FAT volume, not from ISO 9660.
    """
    out = Path(args.output).resolve()
    if out.exists():
        out.unlink()

    # Inputs:
    #   --substrate-node-dir: the per-arch substrate import directory
    #     (created by import-substrate.py).
    #   --esp-image: the FAT ESP image (created by build-refind-esp.py).
    #   --volume-id, --publisher, --application-id: xorriso volume metadata.
    substrate_dir = Path(args.substrate_node_dir).resolve()
    esp_img = Path(args.esp_image).resolve()
    if not substrate_dir.is_dir():
        log(f"FATAL: substrate dir not found: {substrate_dir}")
        return 2
    if not esp_img.is_file():
        log(f"FATAL: ESP image not found: {esp_img}")
        return 2

    # Stage the substrate tree under a private build dir, with the ESP
    # image also staged at /efi.img so xorrisofs can emit the Section
    # Header Entry + EFI Initial Entry at offsets 64/96 of the El
    # Torito catalog. The substrate_dir/extract tree is left untouched
    # (we never write through into cached substrate nodes).
    stage = out.parent / f".cold-stage-{out.name}"
    if stage.is_dir() and not stage.is_symlink():
        _chmod_r(stage)
        shutil.rmtree(stage)
    if stage.is_symlink() or stage.is_file():
        stage.unlink()
    stage.mkdir(parents=True, exist_ok=True)
    extract_root = substrate_dir / "extract"
    # Use a reflink where possible so the staging step is O(1) on
    # reflink-capable filesystems. Falls back to full copy otherwise.
    if extract_root.is_dir():
        _copytree_reflink(extract_root, stage)
    else:
        log(f"FATAL: substrate extract dir not found: {extract_root}")
        return 2

    # Place the ESP image at /efi.img inside the staged tree. We use
    # reflink where supported.
    _copyfile_reflink(esp_img, stage / "efi.img")

    # Stage the r159 install-tree payload at /cixmini/ inside the
    # staged tree. This is what makes the ISO deliver a real,
    # offline-installable rootfs at install time (the stub debootstrap
    # reads from /cdrom/cixmini/base.squashfs etc.). If no payload is
    # available, this is a no-op and the ISO will fall back to a
    # network install — same as a stock Debian netinst ISO.
    payload_dir, patched_udeb = resolve_cixmini_args(args, DEFAULT_CACHE_ROOT)
    payload_receipt = None
    if payload_dir is not None:
        # Read-only use of preseed/ (the brief allows reading; the
        # "Do NOT touch" rule is about modifying). build-iso-di.sh
        # ~line 2988 copies these same files into $EXTRA/preseed.cfg,
        # late.sh, etc.; we mirror that here.
        preseed_dir = REPO_ROOT / "preseed" if (REPO_ROOT / "preseed").is_dir() else None
        payload_receipt = stage_cixmini_payload(
            stage_dir=stage,
            payload_dir=payload_dir,
            patched_udeb=patched_udeb,
            preseed_dir=preseed_dir,
        )
    else:
        log("INFO: no cixmini payload staged — d-i will fall back to "
            "network install (same as stock Debian netinst ISO)")

    # Build the xorrisofs command.
    cmd = [
        "xorrisofs",
        "-R", "-J",
        "-V", args.volume_id,
        "-publisher", args.publisher,
        # Legacy ISOLINUX entry (offset 32) — forces the Section Header
        # Entry structure. This is a real file from the upstream Debian
        # netboot substrate; rEFInd does NOT need it, but its presence
        # is what makes xorriso emit the catalog layout OVMF accepts.
        "-b", "/isolinux/isolinux.bin",
        "-no-emul-boot",
        # -boot-info-table patches isolinux.bin post-hoc with the LBA/
        # length it needs. Debian's own working netboot ISO has this
        # (visible as "boot-info-table isohybrid-suitable" in
        # xorriso -report_el_torito); our earlier cold image lacked it
        # entirely and OVMF's BdsDxe could not enumerate a bootable
        # device from the result ("failed to load Boot0002 ... Not
        # Found", confirmed live on real OVMF/qemu twice).
        "-boot-info-table",
        # EFI binary at /efi.img (FAT image inside ISO tree) — Section
        # Header Entry at offset 64 + EFI Initial Entry at offset 96.
        "--efi-boot", "/efi.img",
        # Real isohybrid MBR template (from the Debian isolinux package),
        # not just -isohybrid-gpt-basdat alone — that flag alone produced
        # a bare El Torito boot record with no MBR/GPT hybrid structure
        # at all, unlike Debian's own ISO which reports
        # "MBR isohybrid cyl-align-on GPT". This is what BdsDxe on OVMF
        # needs to find a bootable device from a SATA/DVD-ROM path.
        # isohdpfx.bin is cached under build/iso-cache/syslinux/ from the
        # Debian bookworm isolinux package (cached here because most build
        # hosts do not ship the isolinux package at /usr/lib/ISOLINUX/).
        "-isohybrid-mbr", str(REPO_ROOT / "build" / "iso-cache" / "syslinux" / "isohdpfx.bin"),
        "-isohybrid-gpt-basdat",
        "-o", str(out),
        str(stage),
    ]

    t0 = time.monotonic()
    proc = cmd_with_log(cmd, capture_output=True, text=True)
    cold_seconds = time.monotonic() - t0

    # Clean up stage regardless of outcome.
    _chmod_r(stage)
    shutil.rmtree(stage, ignore_errors=True)

    if proc.returncode != 0:
        log(f"FAIL: xorriso exit {proc.returncode}")
        log(proc.stderr)
        return 1

    out_sha = sha256_file(out)
    log(f"cold compose: {out} sha256={out_sha} bytes={out.stat().st_size} seconds={cold_seconds:.3f}")

    # Receipt
    receipt = {
        "schema_version": "cold-image-receipt/v1",
        "arch": args.arch,
        "output": str(out),
        "output_sha256": out_sha,
        "output_size_bytes": out.stat().st_size,
        "substrate_node_dir": str(substrate_dir),
        "esp_image": str(esp_img),
        "esp_image_sha256": sha256_file(esp_img),
        "xorriso_seconds": cold_seconds,
        "boot_layout": "iso9660_efi_in_tree",
        "el_torito": {
            "legacy_boot": "/isolinux/isolinux.bin",
            "efi_boot": "/efi.img",
        },
        "parent_physical_id": None,
        "cixmini_payload": payload_receipt,
    }
    receipt_path = out.parent / (out.name + ".receipt.json")
    receipt_path.write_text(json.dumps(receipt, indent=2, sort_keys=True))
    log(f"receipt: {receipt_path}")

    # Verify (independent of xorriso exit status). Pass --esp-image so the
    # verifier actually checks that the bytes at the EFI Initial Entry's
    # load_lba match the source ESP image -- without --esp-image, the
    # verifier only walks structural metadata (MBR / PVD / El Torito
    # catalog layout) and would happily print "verifier: OK" even if the
    # ESP bytes inside the image had been corrupted. The warm path already
    # passes --esp-image; the cold path needs to as well.
    verify_cmd = [sys.executable, str(REPO_ROOT / "build" / "iso" / "verify-image.py"),
                  "--image", str(out), "--arch", args.arch, "--level", "cold",
                  "--report", str(out.parent / (out.name + ".verify.json")),
                  "--esp-image", str(esp_img)]
    proc = cmd_with_log(verify_cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        log(f"FAIL: verifier rejected cold image")
        log(proc.stdout)
        log(proc.stderr)
        return 1
    log("verifier: OK")
    return 0


# ----- warm path -----


def _load_manifest(path: Path) -> dict:
    if not path.is_file():
        return {"add": [], "replace": [], "remove": []}
    return json.loads(path.read_text())


def warm_image(args) -> int:
    """Apply a hotfix-shaped change to a parent ISO via reflink + xorriso.

    The warm writer transaction (design doc §8) for the in-tree ESP
    layout:

        1. Reflink-clone the parent into a private scratch path.
        2. Map the logical change set (adds/replaces/removes) to xorriso
           ``-update`` / ``-cpx`` on -indev/-outdev.
        3. EXPLICITLY replace the in-tree ESP image (/efi.img) on every
           growth. ``-boot_image any keep`` is NOT used: the EFI image is
           replaced (a hotfix-shaped change in our scenario), so the El
           Torito EFI catalog entry at offset 96 must point at the new
           image bytes. The Section Header Entry at offset 64 stays
           valid because its platform/length are unchanged.
        4. ``-commit`` flushes; per design §5 fsync-and-rename semantics
           protect against crashes leaving a partial object.
        5. Independent verifier parses the result. The layout has no
           appended partition, so the GPT rescue finalizer is a no-op
           (we still attempt it for defensive coverage; on success it is
           a true no-op because there is no GPT primary header).
        6. A rejection ends the transaction: a warm growth that does not
           pass independent verification is not shippable.

    Note on the "no appended partition" choice (design §8 fallback
    guidance): the brief explicitly allows "larger FAT ESP with
    kernel/initrd inside it, rewritten on every growth" when the
    ISO9660+EFI layout doesn't qualify for boot. Our layout keeps the
    ESP image at /efi.img inside the ISO tree (Debian Bookworm netboot
    pattern) so the Section Header Entry + EFI Initial Entry catalog
    layout produces a bootable image on QEMU/OVMF 11.1.1 from fresh
    NVRAM, AND so the warm transaction only has to replace one file in
    the ISO tree (``/efi.img``) plus the logical adds/replaces/removes
    — no GPT surgery required.
    """
    parent = Path(args.parent).resolve()
    out = Path(args.output).resolve()
    manifest_path = Path(args.manifest).resolve()
    esp_img = Path(args.esp_image).resolve()
    payload_root = Path(args.payload_root).resolve()

    if not parent.is_file():
        log(f"FATAL: parent ISO not found: {parent}")
        return 2
    if not esp_img.is_file():
        log(f"FATAL: ESP image not found: {esp_img}")
        return 2
    if out.exists():
        out.unlink()

    manifest = _load_manifest(manifest_path)
    adds = manifest.get("add", [])
    replaces = manifest.get("replace", [])
    removes = manifest.get("remove", [])

    # 0. Test reflink support on the output filesystem BEFORE we commit.
    fs_check = verify_reflink_capable_fs(out.parent)
    log(f"reflink fs check: {fs_check}")
    if not fs_check["capable"]:
        log("WARNING: scratch filesystem does NOT support reflink; warm growth "
            "will pay full copy cost. Run on a reflink-capable filesystem for "
            "the seconds-scale promise.")

    # 1. Reflink-clone the parent into a private scratch path.
    clone_t0 = time.monotonic()
    scratch = out.parent / f".warm-scratch-{out.name}"
    if scratch.is_symlink() or scratch.is_file():
        _chmod_r(scratch.parent)
        try:
            scratch.unlink()
        except FileNotFoundError:
            pass
    elif scratch.is_dir():
        _cleanup_scratch(scratch)
    scratch.parent.mkdir(parents=True, exist_ok=True)
    reflink_copy(parent, scratch)
    clone_seconds = time.monotonic() - clone_t0
    log(f"parent clone: {scratch} seconds={clone_seconds:.3f} bytes={scratch.stat().st_size}")

    # 2. Materialize payload files into a private staging tree under
    #    ``out.parent/.warm-stage``.
    stage = out.parent / ".warm-stage"
    if stage.exists():
        shutil.rmtree(stage)
    stage.mkdir(parents=True)
    for entry in adds + replaces:
        rel = entry["path"].lstrip("/")
        src = payload_root / entry["source"]
        if not src.is_file():
            log(f"FATAL: payload missing: {src}")
            return 2
        dst = stage / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        reflink_copy(src, dst)

    # Also place the new ESP image in the staging tree at /efi.img.
    _copyfile_reflink(esp_img, stage / "efi.img")

    # Stage the r159 install-tree payload at /cixmini/ inside the
    # warm-stage tree. This is the same logic as the cold path; on a
    # warm growth that replaces the cixmini payload (e.g. a hotfix
    # replaces base.squashfs), the new payload files are picked up by
    # the xorriso -update step below.
    payload_dir, patched_udeb = resolve_cixmini_args(args, DEFAULT_CACHE_ROOT)
    payload_receipt = None
    if payload_dir is not None:
        preseed_dir = REPO_ROOT / "preseed" if (REPO_ROOT / "preseed").is_dir() else None
        payload_receipt = stage_cixmini_payload(
            stage_dir=stage,
            payload_dir=payload_dir,
            patched_udeb=patched_udeb,
            preseed_dir=preseed_dir,
        )
    else:
        log("INFO: no cixmini payload staged in warm growth — parent "
            "ISO's /cixmini/ is preserved verbatim by xorriso "
            "-boot_image any replay")

    # 3. Build the xorriso command list. We use -indev = the scratch
    #    clone and -outdev = the final output path. The cloned scratch
    #    is the read-only input; the output is a fresh file that xorriso
    #    writes from scratch.
    #
    # Command list:
    #    -boot_image any replay   : copy MBR/system area + El Torito
    #                                settings from the input. The replay
    #                                preserves the parent's Section
    #                                Header Entry structure (offset 64)
    #                                and the EFI Initial Entry (offset
    #                                96); the EFI Initial Entry's load
    #                                LBA is rewritten to the new
    #                                location of /efi.img in the output.
    #    -update ... <iso-path>   : add or replace files from staging.
    #    -cpx <iso-path>          : remove obsolete paths.
    #    -commit                  : flush writes (no partial objects).
    #
    # The ESP image at /efi.img is replaced via ``-update`` (NOT ``keep``).
    # ``keep`` would be wrong here — the EFI image is replaced as part
    # of the warm transaction, so the catalog must point at the new bytes.
    cmd = [
        "xorriso",
        "-indev", str(scratch),
        "-outdev", str(out),
        "-boot_image", "any", "replay",
    ]
    for entry in adds + replaces:
        rel = entry["path"].lstrip("/")
        iso_path = "/" + rel if not rel.startswith("/") else rel
        cmd += ["-update", str(stage / rel), iso_path]

    # Replace /efi.img with the new ESP image.
    cmd += ["-update", str(stage / "efi.img"), "/efi.img"]

    for entry in removes:
        iso_path = entry["path"]
        cmd += ["-cpx", "--", iso_path]

    cmd += ["-commit"]

    t0 = time.monotonic()
    proc = cmd_with_log(cmd, capture_output=True, text=True)
    growth_seconds = time.monotonic() - t0
    if proc.returncode != 0:
        log(f"FAIL: xorriso warm exit {proc.returncode}")
        log(proc.stderr[:4000])
        _cleanup_scratch(scratch)
        return 1

    # 4. Defensive: if a future build of this writer opts back into
    #    -append_partition, the GPT rescue finalizer will rescue a stale
    #    GPT backup layout. For the in-tree ESP layout there is no GPT
    #    primary header (only an MBR + ISO layout), so the finalizer
    #    refuses (raises ValueError). We treat that as success — it just
    #    means there is no GPT to rescue.
    finalizer_log: dict = {"status": "skipped", "reason": "no GPT in iso9660_efi_in_tree layout"}
    if args.layout == "hybrid":
        # Operator explicitly opted into the legacy hybrid layout (the
        # -append_partition layout from the previous pass). Run the
        # finalizer to keep the GPT consistent on warm growth.
        try:
            result = finalize_gpt_layout(out)
            result["status"] = "ok"
            finalizer_log = result
            log(
                f"finalizer: relocated backup GPT to LBA {finalizer_log['new_backup_lba']} "
                f"(array at LBA {finalizer_log['new_backup_part_entry_lba']}); "
                f"primary CRC {finalizer_log['primary_header_crc32']:#010x}, "
                f"backup CRC {finalizer_log['backup_header_crc32']:#010x}"
            )
        except Exception as e:
            finalizer_log = {"status": "failed", "error": str(e), "error_type": type(e).__name__}
            log(f"FAIL: GPT rescue finalizer raised {type(e).__name__}: {e}")
            _cleanup_scratch(scratch)
            return 1

    # 5. Independent verification.
    verify_cmd = [sys.executable, str(REPO_ROOT / "build" / "iso" / "verify-image.py"),
                  "--image", str(out), "--arch", args.arch, "--level", "warm",
                  "--report", str(out.parent / (out.name + ".verify.json")),
                  "--esp-image", str(esp_img)]
    proc = cmd_with_log(verify_cmd, capture_output=True, text=True)
    verifier_exit = proc.returncode

    _cleanup_scratch(scratch)

    if verifier_exit != 0:
        log(f"FAIL: verifier rejected warm image (exit={verifier_exit}); see "
            f"{out.parent / (out.name + '.verify.json')} for details. The "
            f"warm writer transaction must produce an image that passes "
            f"independent UEFI/ISO validation; a rejected image is not "
            f"shippable.")
        return verifier_exit or 1

    out_sha = sha256_file(out)
    log(f"warm growth: {out} sha256={out_sha} bytes={out.stat().st_size} "
        f"clone_seconds={clone_seconds:.3f} growth_seconds={growth_seconds:.3f} "
        f"verifier=PASS")

    receipt = {
        "schema_version": "warm-image-receipt/v1",
        "arch": args.arch,
        "parent": str(parent),
        "parent_sha256": sha256_file(parent),
        "parent_size_bytes": parent.stat().st_size,
        "output": str(out),
        "output_sha256": out_sha,
        "output_size_bytes": out.stat().st_size,
        "manifest": str(manifest_path),
        "esp_image": str(esp_img),
        "esp_image_sha256": sha256_file(esp_img),
        "clone_seconds": clone_seconds,
        "growth_seconds": growth_seconds,
        "reflink_fs_check": fs_check,
        "gpt_rescue_finalizer": finalizer_log,
        "manifest_summary": {
            "add_count": len(adds),
            "replace_count": len(replaces),
            "remove_count": len(removes),
        },
        "cixmini_payload": payload_receipt,
    }
    receipt_path = out.parent / (out.name + ".receipt.json")
    receipt_path.write_text(json.dumps(receipt, indent=2, sort_keys=True))
    log(f"receipt: {receipt_path}")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    sub = ap.add_subparsers(dest="op", required=True)

    cold = sub.add_parser("cold", help="Build a complete ISO from cached components")
    cold.add_argument("--arch", required=True, choices=["amd64", "arm64"])
    cold.add_argument("--substrate-node-dir", required=True, type=Path)
    cold.add_argument("--esp-image", required=True, type=Path)
    cold.add_argument("--cixmini-payload-dir", type=Path, default=None,
                      help="staged cixmini payload dir from "
                           "build/iso/stage-cixmini-payload.py. If "
                           "omitted, auto-detects the latest node under "
                           "build/iso-cache/v1/cixmini-payload/.")
    cold.add_argument("--patched-udeb", type=Path, default=None,
                      help="patched debootstrap-udeb from "
                           "build/iso/patch-debootstrap-stub.py "
                           "(netboot substrate). If omitted, "
                           "auto-detects the latest "
                           "build/iso-cache/v1/cixmini-udeb/<key>/*.udeb.")
    cold.add_argument("--output", required=True, type=Path)
    cold.add_argument("--volume-id", default="NCZOSREFIND")
    cold.add_argument("--publisher", default="NCZ-OS prototype")
    cold.add_argument("--application-id", default="Debian Installer via rEFInd")
    cold.set_defaults(func=cold_image)

    warm = sub.add_parser("warm", help="Apply a hotfix-shaped change via reflink + xorriso")
    warm.add_argument("--arch", required=True, choices=["amd64", "arm64"])
    warm.add_argument("--parent", required=True, type=Path)
    warm.add_argument("--output", required=True, type=Path)
    warm.add_argument("--manifest", required=True, type=Path,
                      help="JSON: {add: [{path,source}], replace: [], remove: []}")
    warm.add_argument("--payload-root", required=True, type=Path,
                      help="Directory containing payload source files")
    warm.add_argument("--esp-image", required=True, type=Path)
    warm.add_argument("--cixmini-payload-dir", type=Path, default=None,
                      help="staged cixmini payload dir (see --cixmini-payload-dir "
                           "on the cold subcommand). Auto-detects by default.")
    warm.add_argument("--patched-udeb", type=Path, default=None,
                      help="patched debootstrap-udeb (see --patched-udeb "
                           "on the cold subcommand). Auto-detects by default.")
    warm.add_argument("--layout", default="iso9660_efi_in_tree",
                      choices=["iso9660_efi_in_tree", "hybrid"],
                      help=(
                          "iso9660_efi_in_tree (default; bootable on OVMF/AAVMF "
                          "from fresh NVRAM via El Torito Section Header Entry) "
                          "or hybrid (legacy -append_partition layout; the "
                          "previous-pass layout, kept for compatibility and "
                          "for environments that need GPT hybrid USB boot)."
                      ))
    warm.set_defaults(func=warm_image)

    args = ap.parse_args()
    sys.exit(args.func(args))


if __name__ == "__main__":
    sys.exit(main())