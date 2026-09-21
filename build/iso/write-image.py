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


def log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


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
    """Apply a hotfix-shaped change to a parent ISO via reflink + xorriso.

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
        5. Independent verifier parses the result independently of xorriso.
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
    reflink_copy(parent, out)
    clone_seconds = time.monotonic() - clone_t0
    log(f"parent clone: {out} seconds={clone_seconds:.3f} bytes={out.stat().st_size}")

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

    # 3. Build the xorriso command list. We open the SAME file as -indev
    #    AND -outdev so the operation is in-place (xorriso handles the
    #    seek-and-overwrite via -commit). The command list:
    #
    #    -boot_image any discard   : drop existing boot catalog entries
    #    -boot_image any cat_path : blank catalog path reset
    #    -update ... <iso-path>    : add or replace files from staging tree
    #    -cpx <iso-path>           : remove obsolete paths
    #    -append_partition 2 0xEF  : re-append the (possibly changed) ESP
    #    -boot_image any ...       : re-emit the boot catalog with EFI
    #                               entry pointing at the new ESP
    #    -commit                   : flush writes (no partial objects)
    cmd = [
        "xorriso",
        "-indev", str(out),
        "-outdev", str(out),
    ]
    # Drop existing boot catalog so we can rewrite it.
    cmd += ["-boot_image", "any", "discard"]
    cmd += ["-boot_image", "any", "cat_path="]

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

    # Re-emit the El Torito boot catalog with an EFI entry for the ESP.
    # We use the same xorrisofs syntax as the cold path so the layout
    # matches and the verifier's checks pass without changes.
    cmd += [
        "-boot_image", "any",
        "cat_path=/boot.cat,cat_hidden=on,boot_info_table=on,"
        "platform_id=0xEF,boot=yes",
    ]
    # Match cold: keep GPT/MBR geometry consistent.
    cmd += ["-boot_image", "any", "next",
            "cat_path=/efi.img,cat_hidden=on,platform_id=0xEF,boot=yes"]

    # Final commit flushes all writes.
    cmd += ["-commit"]

    t0 = time.monotonic()
    proc = cmd_with_log(cmd, capture_output=True, text=True)
    growth_seconds = time.monotonic() - t0
    if proc.returncode != 0:
        log(f"FAIL: xorriso warm exit {proc.returncode}")
        log(proc.stderr[:4000])
        return 1

    # 5. Independent verification (do not trust xorriso exit status alone).
    verify_cmd = [sys.executable, str(REPO_ROOT / "build" / "iso" / "verify-image.py"),
                  "--image", str(out), "--arch", args.arch, "--level", "warm",
                  "--report", str(out.parent / (out.name + ".verify.json")),
                  "--esp-image", str(esp_img)]
    proc = cmd_with_log(verify_cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        log("FAIL: verifier rejected warm image")
        log(proc.stdout)
        log(proc.stderr)
        return 1

    out_sha = sha256_file(out)
    log(f"warm growth: {out} sha256={out_sha} bytes={out.stat().st_size} "
        f"clone_seconds={clone_seconds:.3f} growth_seconds={growth_seconds:.3f}")

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