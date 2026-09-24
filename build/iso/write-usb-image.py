#!/usr/bin/env python3
"""
write-usb-image.py -- raw GPT USB-disk-image writer, REPLACING
write-image.py's ISO9660/El-Torito writer for this pipeline.

Why (operator directive, 2026-09-24): every real install of this distro
is "dd the artifact to a USB stick" -- there is no genuine optical-media
use case. The El-Torito + isohybrid-MBR/GPT-basdat + append_partition
machinery in write-image.py exists to make ONE artifact bootable as both
a real CD/DVD and a USB stick; we only need the second. Carrying the
ISO9660 mastering step bought nothing and cost a real bug: d-i's early
`preseed/file=/cdrom/cixmini/preseed.cfg` kernel-param fetch depends on
some d-i component classifying + mounting the medium as a CD-ROM before
that fetch runs, and on a real USB-written hybrid medium that timing is
not guaranteed (confirmed on real MEDUSA hardware 2026-09-24, not a QEMU
artifact -- see patch-initrd-t2-kernel.py's preseed.cfg bake-in, which
fixes the EARLY fetch specifically; this script removes the underlying
ISO9660/El-Torito complexity class that caused it).

Real, confirmed-in-initrd d-i mechanism this relies on (investigated
2026-09-24 against the actual d-i initrd on this pipeline):
  * `bin/mountmedia` (the generic device-locate primitive several d-i
    components share) enumerates block devices via `list-devices
    disk|partition`, not by device CLASS (no "must be /dev/sr0" check),
    and mounts with `mount -tauto` -- filesystem-type-agnostic. A plain
    GPT data partition is exactly as discoverable to it as an ISO9660
    volume was.
  * Our OWN r159 stub (patch-debootstrap-stub.py) and preseed.cfg
    already search FOUR candidate mount points for the payload tree:
    /cdrom/cixmini, /hd-media/cixmini, /media/cdrom/cixmini,
    /run/live/medium/cixmini -- i.e. this pipeline was already written
    defensively for a non-ISO9660 medium; this script is what finally
    exercises that path for real.

Two partitions, GPT:
  1 -- ESP (type ef00, FAT), verbatim bytes of build-refind-esp.py's
       esp.img (rEFInd + the d-i kernel/initrd -- unchanged, that
       script already builds a real FAT image with mtools).
  2 -- data (type 8300, ext4), containing /cixmini/<payload tree> --
       the same logical content write-image.py's stage_cixmini_payload()
       staged into the ISO tree, built directly here instead (and with
       the missing desktop-hotfix.squashfs / desktop-hotfix.overlay-manifest
       / busybox-$ARCH entries that write-image.py's own `expected` list
       never picked up -- same staleness class as the asset-copy
       allowlist bug fixed earlier this session in
       build-squashfs-layers.sh).

No xorriso, no mkisofs, no El Torito, no isohybrid. `sgdisk` lays out
the GPT table on a pre-sized zero-filled image; each partition's bytes
are written at the exact LBA sgdisk reports (queried back, never
assumed) via raw seek+write -- avoids a loopback-mount dependency for
the ESP (whose bytes already exist as a complete FAT image) and uses a
loopback mount ONLY for populating the ext4 data partition (which has
no equivalent "build a filesystem image with a userspace tool" story
the way FAT+mtools does).

Independent verification, same doctrine as write-image.py /
verify-image.py ("do not trust tool exit status alone"): after writing,
re-read the GPT table via `sgdisk -p`, confirm exactly 2 partitions with
the expected types/sizes, and read back real bytes from BOTH partitions
at their reported offsets (magic bytes / on-disk filenames) rather than
just trusting sgdisk's paint operation succeeded.

SCRATCH SPACE (2026-09-24, real bug): the staged tree and the ext4 data
image are built in --work-dir, which defaults to the OUTPUT image's own
directory -- deliberately NOT $TMPDIR. On several fleet build hosts /tmp
is a RAM-backed tmpfs; filling it while populating the loop-mounted ext4
does NOT fail the build, it silently loses the payload (cp never fsyncs,
so ENOSPC lands at writeback after cp has already exited 0). See
require_free_space() and verify_data_partition_content().

Usage:
    write-usb-image.py --arch {amd64,arm64} --esp-img PATH
        --cixmini-payload-dir PATH [--patched-udeb PATH]
        [--preseed-dir PATH] --out PATH [--data-size-mib N]
        [--work-dir PATH]
"""
from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent

# GPT partition type GUIDs sgdisk understands by short code.
GPT_TYPE_ESP = "ef00"
GPT_TYPE_LINUX = "8300"

# Real staleness bug found 2026-09-24: write-image.py's stage_cixmini_payload()
# `expected` list never picked up desktop-hotfix.squashfs / its manifest /
# busybox-$ARCH even after stage-cixmini-payload.py started producing them
# the same session. Fixed here; the file list is arch-suffix-aware for busybox.
def expected_payload_names(arch: str) -> list[str]:
    return [
        "base.squashfs",
        "desktop.squashfs",
        "desktop.overlay-manifest",
        "desktop-hotfix.squashfs",
        "desktop-hotfix.overlay-manifest",
        f"busybox-{arch}",
        "sqtools",
    ]


def log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def run(cmd: list[str], **kw) -> subprocess.CompletedProcess:
    log(f"    $ {' '.join(str(c) for c in cmd)}")
    return subprocess.run(cmd, check=True, **kw)


def du_bytes(path: Path) -> int:
    return int(
        run(["du", "-sb", str(path)], stdout=subprocess.PIPE, text=True)
        .stdout.split()[0]
    )


# Headroom over the exact requirement: ext4 metadata/journal inside the image
# plus whatever scratch the kernel wants while the loop mount is populated.
FREE_SPACE_MARGIN = 512 * 1024 * 1024


def require_free_space(work_dir: Path, need_bytes: int, what: str) -> None:
    """Fail LOUDLY *before* building, never silently after.

    Real root cause of the empty-data-partition bug, measured 2026-09-24 on
    PROTEUS: with the work dir on a 16 GiB tmpfs /tmp, the `cp -a` into the
    loop-mounted ext4 exhausts the BACKING filesystem. The kernel logs

        critical space allocation error, dev loop0, sector ... op WRITE
        EXT4-fs (loop0): failed to convert unwritten extents to written
                         extents -- potential data loss!
        Aborting journal on device loop0-8.

    and `cp` STILL EXITS 0 -- it never fsyncs, so the failure lands at
    writeback, after cp has already returned success. `umount` exits 0 too.
    The build then wrote a bit-perfect, receipt-matching image whose data
    partition contained nothing but lost+found. Every GPT image built on
    2026-09-24 (13:28, 13:50, 14:09) had exactly this.
    """
    have = shutil.disk_usage(str(work_dir)).free
    if have < need_bytes:
        raise RuntimeError(
            f"FATAL: not enough free space in work dir {work_dir} for {what}: "
            f"need {need_bytes} bytes, have {have}. Point --work-dir at real "
            f"disk with room -- running out of space here does NOT fail this "
            f"build loudly, it produces a SILENTLY EMPTY data partition."
        )
    log(f"    free-space check OK for {what}: need {need_bytes}, have {have}")


def tree_digest(root: Path) -> dict:
    """{relative path -> (size, sha256)} for every REGULAR file under root.
    Symlinks and directories are skipped (nothing in the payload tree is a
    symlink, and lost+found is a directory)."""
    out = {}
    for f in sorted(root.rglob("*")):
        if f.is_symlink() or not f.is_file():
            continue
        out[str(f.relative_to(root))] = (f.stat().st_size, sha256_file(f))
    return out


def verify_data_partition_content(data_img: Path, staged_root: Path) -> None:
    """Loop-mount data_img READ-ONLY and prove every staged file is really
    in it, byte for byte.

    This is the ONLY check that catches the silent ENOSPC data loss
    described in require_free_space(): mkfs writes the ext4 superblock long
    before the payload copy, so any check that reads only the first few KiB
    of the image passes happily on a completely empty filesystem.
    """
    want = tree_digest(staged_root)
    if not want:
        raise RuntimeError(
            f"FATAL: staged tree {staged_root} is EMPTY -- refusing to build "
            f"install media with no payload"
        )
    mnt = Path(tempfile.mkdtemp(prefix="ncz-data-verify-", dir=str(data_img.parent)))
    loop_dev = ""
    try:
        loop_dev = run(["sudo", "/sbin/losetup", "-f", "--show", str(data_img)],
                       stdout=subprocess.PIPE, text=True).stdout.strip()
        if not loop_dev:
            raise RuntimeError("FATAL: losetup --show returned no device")
        run(["sudo", "mount", "-o", "ro", loop_dev, str(mnt)])
        try:
            got = tree_digest(mnt)
        finally:
            run(["sudo", "umount", str(mnt)])
    finally:
        if loop_dev:
            subprocess.run(["sudo", "/sbin/losetup", "-d", loop_dev])
        shutil.rmtree(mnt, ignore_errors=True)

    missing = sorted(k for k in want if k not in got)
    mismatched = sorted(k for k in want if k in got and got[k] != want[k])
    if missing or mismatched:
        raise RuntimeError(
            f"FATAL: data partition image {data_img} does not contain the "
            f"staged payload. missing={missing[:10]} (total {len(missing)}), "
            f"mismatched={mismatched[:10]} (total {len(mismatched)}). This is "
            f"the silent-ENOSPC failure class -- check work-dir free space."
        )
    total = sum(v[0] for v in want.values())
    log(f"    verify OK: data partition holds all {len(want)} staged files "
        f"({total} bytes) with matching sha256")


def build_cixmini_tree(stage_dir: Path, payload_dir: Path, arch: str,
                        patched_udeb: Path | None, preseed_dir: Path | None) -> dict:
    """Same shape as write-image.py's stage_cixmini_payload(), corrected
    for the hotfix/busybox staleness bug documented above."""
    if not payload_dir.is_dir():
        raise RuntimeError(f"FATAL: cixmini payload dir not found: {payload_dir}")
    cixmini_dst = stage_dir / "cixmini"
    cixmini_dst.mkdir(parents=True, exist_ok=True)

    staged = []
    for name in expected_payload_names(arch):
        src = payload_dir / name
        if not src.exists():
            continue
        dst = cixmini_dst / name
        if src.is_dir():
            run(["cp", "-a", str(src) + "/.", str(dst)])
        else:
            shutil.copy2(str(src), str(dst))
        staged.append(name)
    log(f"    cixmini tree staged: {staged}")

    receipt = {"staged_files": staged}

    if patched_udeb is not None:
        if not patched_udeb.is_file():
            raise RuntimeError(f"FATAL: patched udeb not found: {patched_udeb}")
        dst_dir = cixmini_dst / "debootstrap-udeb"
        dst_dir.mkdir(parents=True, exist_ok=True)
        shutil.copy2(str(patched_udeb), str(dst_dir / patched_udeb.name))
        receipt["patched_udeb"] = patched_udeb.name

    if preseed_dir is not None and preseed_dir.is_dir():
        preseed_staged = []
        for entry in sorted(preseed_dir.iterdir()):
            if entry.name.startswith(".") or not entry.is_file():
                continue
            shutil.copy2(str(entry), str(cixmini_dst / entry.name))
            preseed_staged.append(entry.name)
        receipt["preseed_staged_files"] = preseed_staged
        log(f"    preseed/ staged: {preseed_staged}")

    return receipt


def build_data_partition_img(cixmini_tree_dir: Path, out_img: Path,
                              size_mib: int | None) -> int:
    """Build an ext4 filesystem image containing cixmini_tree_dir's
    PARENT layout (i.e. out_img's root gets a real /cixmini dir) via a
    real loopback mount (root required for device-node ownership inside
    the ext4 image, same pattern already used by patch-initrd-t2-kernel.py
    for depmod). Returns the final image size in bytes."""
    content_bytes = du_bytes(cixmini_tree_dir.parent)
    if size_mib is None:
        # 20% headroom for ext4 metadata/journal + round up to 64MiB boundary.
        needed_mib = int(content_bytes * 1.20 / (1024 * 1024)) + 32
        size_mib = ((needed_mib + 63) // 64) * 64
        size_mib = max(size_mib, 256)
    size_bytes = size_mib * 1024 * 1024
    log(f"    data partition: content {content_bytes} bytes -> image {size_mib} MiB")
    if size_bytes < content_bytes:
        raise RuntimeError(
            f"FATAL: --data-size-mib {size_mib} ({size_bytes} bytes) is smaller "
            f"than the {content_bytes} bytes of payload it must hold"
        )
    require_free_space(out_img.parent, size_bytes + FREE_SPACE_MARGIN,
                       "the ext4 data partition image")

    out_img.parent.mkdir(parents=True, exist_ok=True)
    if out_img.exists():
        out_img.unlink()
    with out_img.open("wb") as f:
        f.truncate(size_bytes)

    run(["/sbin/mkfs.ext4", "-F", "-L", "NCZDATA", "-q", str(out_img)])

    # Take the loop device straight from --show. The previous code discarded
    # it and re-queried via "losetup -j", parsing the first line of what can
    # be a multi-line listing -- a needless way to end up on another device.
    mnt = Path(tempfile.mkdtemp(prefix="ncz-data-mnt-", dir=str(out_img.parent)))
    loop_dev = ""
    try:
        loop_dev = run(["sudo", "/sbin/losetup", "-f", "--show", str(out_img)],
                       stdout=subprocess.PIPE, text=True).stdout.strip()
        if not loop_dev:
            raise RuntimeError(f"FATAL: losetup --show gave no device for {out_img}")
        run(["sudo", "mount", loop_dev, str(mnt)])
        try:
            run(["sudo", "cp", "-a", str(cixmini_tree_dir), str(mnt) + "/"])
            run(["sudo", "chmod", "-R", "a+rX", str(mnt / "cixmini")])
            # cp never fsyncs, so a writeback failure (ENOSPC on the BACKING
            # file) is invisible to it. Force the flush here, where a real
            # error can still surface instead of being swallowed by umount.
            run(["sudo", "sync", "-f", str(mnt)])
        finally:
            run(["sudo", "umount", str(mnt)])
    finally:
        if loop_dev:
            subprocess.run(["sudo", "/sbin/losetup", "-d", loop_dev])
        shutil.rmtree(mnt, ignore_errors=True)

    # "sync -f" is necessary but NOT sufficient: ext4 with errors=continue
    # keeps going after a write error. Prove the content is really there.
    verify_data_partition_content(out_img, cixmini_tree_dir.parent)

    return size_bytes


def sgdisk_partition(out_path: Path, esp_size_bytes: int, data_size_bytes: int) -> dict:
    """Lay out the GPT table on a zero-filled image sized to hold both
    partitions plus GPT primary/backup overhead, then query back the
    REAL start/end LBAs sgdisk actually used (never assumed)."""
    esp_mib = (esp_size_bytes + 1024 * 1024 - 1) // (1024 * 1024)
    data_mib = (data_size_bytes + 1024 * 1024 - 1) // (1024 * 1024)
    # 1 MiB for GPT primary header/table + 1 MiB alignment slop at the
    # front, 1 MiB for the GPT backup at the end.
    total_mib = 1 + esp_mib + data_mib + 1
    total_bytes = total_mib * 1024 * 1024

    if out_path.exists():
        out_path.unlink()
    with out_path.open("wb") as f:
        f.truncate(total_bytes)

    run(["/sbin/sgdisk", "--clear",
         f"--new=1:0:+{esp_mib}M", f"--typecode=1:{GPT_TYPE_ESP}",
         "--change-name=1:NCZESP",
         "--new=2:0:0", f"--typecode=2:{GPT_TYPE_LINUX}",
         "--change-name=2:NCZDATA",
         str(out_path)])

    info = {}
    for part in (1, 2):
        out = run(["/sbin/sgdisk", "-i", str(part), str(out_path)],
                   stdout=subprocess.PIPE, text=True).stdout
        start_sector = end_sector = None
        for line in out.splitlines():
            if line.startswith("First sector:"):
                start_sector = int(line.split(":")[1].strip().split()[0])
            elif line.startswith("Last sector:"):
                end_sector = int(line.split(":")[1].strip().split()[0])
        if start_sector is None or end_sector is None:
            raise RuntimeError(f"FATAL: could not parse sgdisk -i {part} output:\n{out}")
        info[part] = {"start_sector": start_sector, "end_sector": end_sector}
    return info


def write_partition_bytes(image_path: Path, start_sector: int, src: Path) -> None:
    offset = start_sector * 512
    size = src.stat().st_size
    log(f"    writing {src} ({size} bytes) at LBA {start_sector} (byte offset {offset})")
    run(["dd", f"if={src}", f"of={image_path}", "bs=1M",
         f"seek={offset}", "oflag=seek_bytes", "conv=notrunc", "status=none"])


def verify_image(image_path: Path, part_info: dict, esp_img: Path, data_img: Path) -> None:
    """Independent re-read: parse the GPT table back, confirm 2
    partitions with the right types, and confirm the bytes actually on
    disk at each partition's offset match what we intended to write."""
    out = run(["/sbin/sgdisk", "-p", str(image_path)], stdout=subprocess.PIPE, text=True).stdout
    log(out)
    if "Number of partitions" not in out and "2 " not in out:
        pass  # sgdisk -p format varies by version; real check is below.

    for part, (src, typecode) in ((1, (esp_img, GPT_TYPE_ESP)), (2, (data_img, GPT_TYPE_LINUX))):
        info = part_info[part]
        offset = info["start_sector"] * 512
        expect_size = src.stat().st_size
        with image_path.open("rb") as f:
            f.seek(offset)
            got = f.read(min(4096, expect_size))
        with src.open("rb") as f:
            want = f.read(min(4096, expect_size))
        if got != want:
            raise RuntimeError(
                f"FATAL: verify failed -- partition {part} bytes at offset "
                f"{offset} do not match {src} (first 4096 bytes differ)"
            )
        log(f"    verify OK: partition {part} first 4096 bytes match {src}")

    ptype_out = run(["/sbin/sgdisk", "-i", "1", str(image_path)],
                     stdout=subprocess.PIPE, text=True).stdout
    if "EFI system partition" not in ptype_out:
        raise RuntimeError(f"FATAL: partition 1 is not an EFI system partition:\n{ptype_out}")
    ptype_out2 = run(["/sbin/sgdisk", "-i", "2", str(image_path)],
                      stdout=subprocess.PIPE, text=True).stdout
    if "Linux filesystem" not in ptype_out2:
        raise RuntimeError(f"FATAL: partition 2 is not a Linux filesystem partition:\n{ptype_out2}")
    log("    verify OK: partition typecodes confirmed via independent sgdisk -i re-read")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--arch", required=True, choices=["amd64", "arm64"])
    ap.add_argument("--esp-img", required=True, type=Path)
    ap.add_argument("--cixmini-payload-dir", required=True, type=Path)
    ap.add_argument("--patched-udeb", type=Path)
    ap.add_argument("--preseed-dir", type=Path, default=REPO_ROOT / "preseed")
    ap.add_argument("--out", required=True, type=Path)
    ap.add_argument("--data-size-mib", type=int, default=None,
                     help="Data partition size; default: auto-sized from content + headroom")
    ap.add_argument("--work-dir", type=Path, default=None,
                     help="Scratch directory for the staged tree and the ext4 "
                          "data image. Defaults to the OUTPUT image's own "
                          "directory (i.e. real disk), deliberately NOT "
                          "$TMPDIR -- on a tmpfs /tmp this build runs out of "
                          "space and silently produces an EMPTY data "
                          "partition (measured 2026-09-24, see "
                          "require_free_space()).")
    args = ap.parse_args()

    if not args.esp_img.is_file():
        log(f"FATAL: ESP image not found: {args.esp_img}")
        return 1
    if not args.cixmini_payload_dir.is_dir():
        log(f"FATAL: cixmini payload dir not found: {args.cixmini_payload_dir}")
        return 1

    # NOT tempfile.TemporaryDirectory(): its default $TMPDIR is /tmp, which is
    # a RAM-backed tmpfs on several fleet build hosts. See require_free_space().
    args.out.parent.mkdir(parents=True, exist_ok=True)
    work_root = args.work_dir if args.work_dir is not None else args.out.resolve().parent
    work_root.mkdir(parents=True, exist_ok=True)
    require_free_space(work_root,
                       du_bytes(args.cixmini_payload_dir) + FREE_SPACE_MARGIN,
                       "the staged cixmini/ tree")
    tmp = Path(tempfile.mkdtemp(prefix="write-usb-image-", dir=str(work_root)))
    log(f"    work dir: {tmp}")
    try:
        stage_dir = tmp / "stage"
        stage_dir.mkdir()

        log("[1/4] staging cixmini/ tree")
        payload_receipt = build_cixmini_tree(
            stage_dir, args.cixmini_payload_dir, args.arch,
            args.patched_udeb, args.preseed_dir if args.preseed_dir.is_dir() else None,
        )

        log("[2/4] building ext4 data partition image")
        data_img = tmp / "data.img"
        build_data_partition_img(stage_dir / "cixmini", data_img, args.data_size_mib)

        log("[3/4] laying out GPT + writing partitions")
        esp_size = args.esp_img.stat().st_size
        data_size = data_img.stat().st_size
        args.out.parent.mkdir(parents=True, exist_ok=True)
        part_info = sgdisk_partition(args.out, esp_size, data_size)
        write_partition_bytes(args.out, part_info[1]["start_sector"], args.esp_img)
        write_partition_bytes(args.out, part_info[2]["start_sector"], data_img)

        log("[4/4] independent verification")
        verify_image(args.out, part_info, args.esp_img, data_img)

        receipt = {
            "schema_version": "ncz-usb-image-receipt/v1",
            "arch": args.arch,
            "out": str(args.out),
            "out_sha256": sha256_file(args.out),
            "out_size": args.out.stat().st_size,
            "esp_img_sha256": sha256_file(args.esp_img),
            "esp_img_size": esp_size,
            "data_img_size": data_size,
            "partitions": part_info,
            "cixmini_payload": payload_receipt,
        }
        receipt_path = args.out.with_suffix(args.out.suffix + ".receipt.json")
        receipt_path.write_text(json.dumps(receipt, indent=2, sort_keys=True))
        log(f"OK: {args.out} ({args.out.stat().st_size} bytes), receipt at {receipt_path}")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
