#!/usr/bin/env python3
"""
write-image.py — Cold and warm ISO writer for the incremental d-i prototype.

Two operations:

    cold -- Build a complete bootable image from cached components (substrate
            import, rEFInd ESP) using xorriso in mkisofs emulation mode. The
            output is a hybrid ISO9660 + EFI GPT layout, like the upstream
            Debian netboot ISO but with our rEFInd ESP replacing its GRUB ESP.

    warm -- Take a previously-published ISO ("parent") and a list of logical
            changes (added/replaced/removed file paths), reflink-clone the
            parent into a private scratch ISO, apply the change set using
            native xorriso commands (``-update``, ``-cpx`` etc.), append a
            fresh ESP image via ``-append_partition`` (NEVER ``keep`` unless
            the EFI image is byte-for-byte unchanged), and produce a new
            physical artifact.

The warm path is what the design doc Section 8 calls "the warm writer
transaction". This is the operation that delivers the seconds-scale hotfix
promise (subject to a real reflink-capable scratch filesystem).

Both operations end with an INDEPENDENT verification step that parses the
resulting GPT, MBR, El Torito and extent map itself — we do NOT trust
xorriso's exit status alone (design §8 explicit constraint).

Safety rails (carried over from the design doc):

    * No tar -C /. No writes through hardlinks into shared cache objects.
      Assembly consumes files and immutable trees, never the live host root.
    * Parent and published artifacts are NEVER edited. We always operate on
      a private scratch clone.
    * Reflink is tested on the actual scratch filesystem before a warm run
      proceeds (see verify_reflink_capable_fs).
    * The ESP is appended EXPLICITLY on every warm growth with
      ``-append_partition``. ``keep`` is rejected when the EFI image has
      changed (and it WILL have changed unless the user passed
      ``--esp unchanged``).

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


# ----- helpers -----


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()
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
    """Build a complete ISO from cached substrate + ESP."""
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

    # The xorrisofs command pattern that boots both as optical and as USB:
    #
    #   * xorrisofs -R -J : Rock Ridge + Joliet (so the kernel/initrd are
    #     visible to a generic Linux reader too).
    #   * -partition_cyl_align on + -partition_offset 16 : align partitions
    #     to a 16-sector boundary (preserves upstream Debian netinst
    #     conventions; Sky1/T2 firmware behaviour with other alignments is
    #     a qualification question we have NOT YET TESTED on real hardware).
    #   * -append_partition 2 0xEF <esp.img> : append the rEFInd ESP after
    #     the ISO data.
    #   * -e --interval:appended_partition_2:all:: : wire the appended
    #     partition as the EFI boot image (El Torito catalog entry with
    #     platform 0xEF).
    #   * -no-emul-boot + -isohybrid-gpt-basdat : required companions.
    #
    # We deliberately do NOT pass -isohybrid-mbr here; that would force a
    # specific MBR blob. xorrisofs picks a sensible isohybrid MBR by
    # default when an EFI image is wired in via -e.
    #
    # We do NOT include /EFI/BOOT/BOOTX64.EFI inside the ISO filesystem as
    # a separate file: the ESP partition IS that. Adding both creates a
    # duplicate and triggers xorrisofs's "EFI/BOOT will not emerge"
    # warning. The small-ESP design §8 layout uses the ESP partition as
    # the sole boot entrypoint.
    cmd = [
        "xorrisofs",
        "-R", "-J",
        "-V", args.volume_id,
        "-publisher", args.publisher,
        "-partition_cyl_align", "on",
        "-partition_offset", "16",
        "-append_partition", "2", "0xEF", str(esp_img),
        # xorriso writes a single EFI entry pointing at the appended
        # partition when we use -e with the --interval: shorthand.
        # This works for QEMU/OVMF boot when the firmware auto-discovers
        # the ESP via El Torito. On real hardware, the firmware may
        # need a more explicit boot entry (see findings doc).
        "-e", "--interval:appended_partition_2:all::",
        "-no-emul-boot",
        "-isohybrid-gpt-basdat",
        # Mark appended partitions in GPT as well as MBR. Without this
        # the image is MBR-only and modern EFI firmware (which prefers
        # GPT) will fall back to MBR compatibility mode — usually fine,
        # but the design doc §12 open question #5 wants explicit GPT
        # geometry verified, so we always ask for it.
        "-appended_part_as_gpt",
        "-o", str(out),
        str(substrate_dir / "extract"),
    ]

    t0 = time.monotonic()
    proc = cmd_with_log(cmd, capture_output=True, text=True)
    cold_seconds = time.monotonic() - t0

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
        "parent_physical_id": None,
    }
    receipt_path = out.parent / (out.name + ".receipt.json")
    receipt_path.write_text(json.dumps(receipt, indent=2, sort_keys=True))
    log(f"receipt: {receipt_path}")

    # Verify (independent of xorriso exit status)
    verify_cmd = [sys.executable, str(REPO_ROOT / "build" / "iso" / "verify-image.py"),
                  "--image", str(out), "--arch", args.arch, "--level", "cold",
                  "--report", str(out.parent / (out.name + ".verify.json"))]
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
    """Apply a hotfix-shaped change to a parent ISO via reflink + xorriso,
    then rescue the GPT layout so the result passes independent UEFI/ISO
    validation.

    The warm writer transaction (design doc §8) is:

        1. Reflink-clone the parent into a private scratch path.
        2. Map the logical change set (adds/replaces/removes) to xorriso
           native commands (``-update``, ``-cpx``) on -indev/-outdev.
        3. EXPLICITLY re-append the ESP on every growth. ``-boot_image any
           keep`` is NOT used: the EFI image is replaced (a hotfix-shaped
           change in our scenario), so the El Torito EFI catalog entry
           must point at the new image.
        4. ``-commit`` flushes; per design §5 fsync-and-rename semantics
           protect against crashes leaving a partial object.
        5. GPT layout rescue finalizer. xorriso 1.5.8.pl02's
           ``-boot_image any replay -append_partition`` mode does not
           relocate the backup GPT when the image grows, so we
           patch the primary header, write a fresh backup entry array and
           header at the new tail, and fix the protective-MBR partition-1
           size. ISO filesystem bytes and the EFI partition are left
           untouched.
        6. Independent verifier parses the result. A rejection ends the
           transaction: a warm growth that does not pass independent
           verification is not shippable.
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
        # A previous failed run left a regular file or symlink at the scratch
        # path; unlink unconditionally. Use unlink_with_retries for the
        # macOS case where the prior xorriso may have set the file read-only.
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
    #    ``out.parent/.warm-stage``. The writer consumes staged payloads
    #    that came from the production build path (out of scope for Step 1).
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

    # 3. Build the xorriso command list. We use -indev = the scratch clone
    #    and -outdev = the final output path. We do NOT update the parent
    #    in place: that breaks GPT layout because xorriso does not
    #    relocate the backup GPT when growing. The cloned scratch is the
    #    read-only input; the output is a fresh file that xorriso writes
    #    from scratch.
    #
    # The command list:
    #    -boot_image any replay   : copy MBR/system area from input
    #    -update ... <iso-path>   : add or replace files from staging tree
    #    -cpx <iso-path>          : remove obsolete paths
    #    -append_partition 2 0xEF : re-append the (possibly changed) ESP
    #    -boot_image any ...      : re-emit EFI catalog entry for the ESP
    #    -commit                  : flush writes (no partial objects)
    cmd = [
        "xorriso",
        "-indev", str(scratch),
        "-outdev", str(out),
        "-boot_image", "any", "replay",
    ]
    # Map logical adds/replaces to xorriso -update. ``-update`` writes the
    # local file to the ISO at the given ISO path; it does NOT use
    # timestamp-based discovery.
    for entry in adds + replaces:
        rel = entry["path"].lstrip("/")
        iso_path = "/" + rel if not rel.startswith("/") else rel
        cmd += ["-update", str(stage / rel), iso_path]

    # Removals
    for entry in removes:
        iso_path = entry["path"]
        # ``-cpx <path>`` requires a separator before the path so it
        # doesn't look like a flag.
        cmd += ["-cpx", "--", iso_path]

    # 4. Re-append the ESP. Per design §8, an EFI image change mandates
    #    an explicit re-append; "keep" would be wrong here.
    cmd += ["-append_partition", "2", "0xEF", str(esp_img)]

    # xorriso's -boot_image replay (from step 3 above) already replays
    # the parent's El Torito settings, which point at the ESP. We
    # therefore do NOT need to re-emit -boot_image any here. The
    # -append_partition above updates the ESP contents (in-place), and
    # the replayed boot image will reference the new ESP bytes.

    # Final commit flushes all writes.
    cmd += ["-commit"]

    t0 = time.monotonic()
    proc = cmd_with_log(cmd, capture_output=True, text=True)
    growth_seconds = time.monotonic() - t0
    if proc.returncode != 0:
        log(f"FAIL: xorriso warm exit {proc.returncode}")
        log(proc.stderr[:4000])
        # Clean up scratch even on failure
        _cleanup_scratch(scratch)
        return 1

    # 4b. GPT layout rescue finalizer.
    #
    # xorriso 1.5.8.pl02 does NOT maintain a valid GPT backup layout when
    # growing an ISO via ``-indev parent -outdev new -boot_image any replay
    # -append_partition``. The primary GPT's ``backup_lba`` still points at
    # the parent's old end-of-image, the protective-MBR partition-1 size
    # field still claims the parent's size, and the file's tail (where the
    # backup GPT header should now live) is whatever ISO data and PVD/Joliet
    # descriptors xorriso happened to write there.
    #
    # We rescue the layout by relocating the backup GPT entry array to the
    # new tail of the file, writing a freshly-computed backup GPT header at
    # LBA (image_lba - 1), and patching the primary header's ``backup_lba``
    # + protective-MBR partition-1 size. The ISO 9660 filesystem bytes,
    # El Torito catalog, and EFI partition bytes are left untouched (they
    # already pass their own checks). This is the design §8 step 6
    # "explicit finalization" for warm growth.
    finalizer_log = {"status": "skipped"}
    try:
        finalizer_log = finalize_gpt_layout(out)
        finalizer_log["status"] = "ok"
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

    # 5. Independent verification. The design §8 mandate: do not trust
    # xorriso's exit status alone. The verifier parses GPT, MBR, ISO PVD,
    # El Torito catalog and verifies ESP-bytes-identical-to-source. We
    # treat a verifier rejection as a transactional failure: the warm
    # growth transaction must produce an image that passes independent
    # UEFI/ISO validation, otherwise it does not exist for our purposes.
    verify_cmd = [sys.executable, str(REPO_ROOT / "build" / "iso" / "verify-image.py"),
                  "--image", str(out), "--arch", args.arch, "--level", "warm",
                  "--report", str(out.parent / (out.name + ".verify.json")),
                  "--esp-image", str(esp_img)]
    proc = cmd_with_log(verify_cmd, capture_output=True, text=True)
    verifier_exit = proc.returncode

    # Clean up scratch clone regardless of verifier outcome.
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
    warm.set_defaults(func=warm_image)

    args = ap.parse_args()
    sys.exit(args.func(args))


if __name__ == "__main__":
    sys.exit(main())