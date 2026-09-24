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
`preseed/file=/cdrom/ncz-payload/preseed.cfg` kernel-param fetch depends on
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
    /cdrom/ncz-payload, /hd-media/ncz-payload, /media/cdrom/ncz-payload,
    /run/live/medium/ncz-payload -- i.e. this pipeline was already written
    defensively for a non-ISO9660 medium; this script is what finally
    exercises that path for real.

Two partitions, GPT:
  1 -- ESP (type ef00, FAT), verbatim bytes of build-refind-esp.py's
       esp.img (rEFInd + the d-i kernel/initrd -- unchanged, that
       script already builds a real FAT image with mtools).
  2 -- data (type 8300, ext4), containing /ncz-payload/<payload tree> --
       the same logical content write-image.py's stage_ncz_payload()
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
verify-image.py ("do not trust tool exit status alone") -- rewritten
2026-09-24 because the first cut did not live up to that doctrine. It
compared the first 4096 BYTES per partition, had a literal `pass` where
the partition-count check belonged, and so passed cleanly on an image
whose data partition was completely empty. verify_image() now parses both
GPT headers itself (struct/zlib, no sgdisk), checks every CRC32 primary
and backup, checks geometry/type-GUID/name against what was intended,
hashes the FULL byte content of both partitions against their sources,
and loop-mounts the finished data partition to confirm the payload files
an install actually needs are really in it.

SCRATCH SPACE (2026-09-24, real bug): the staged tree and the ext4 data
image are built in --work-dir, which defaults to the OUTPUT image's own
directory -- deliberately NOT $TMPDIR. On several fleet build hosts /tmp
is a RAM-backed tmpfs; filling it while populating the loop-mounted ext4
does NOT fail the build, it silently loses the payload (cp never fsyncs,
so ENOSPC lands at writeback after cp has already exited 0). See
require_free_space() and verify_data_partition_content().

Usage:
    write-usb-image.py --arch {amd64,arm64} --esp-img PATH
        --ncz-payload-dir PATH [--patched-udeb PATH]
        [--preseed-dir PATH] --out PATH [--data-size-mib N]
        [--work-dir PATH]
"""
from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import time
import zlib
from datetime import datetime, timezone
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent

SECTOR_SIZE = 512

# GPT partition type GUIDs sgdisk understands by short code.
GPT_TYPE_ESP = "ef00"
GPT_TYPE_LINUX = "8300"

# The same two types as they really appear on disk: 16-byte mixed-endian
# GUIDs. verify_image() compares these directly out of the partition array
# rather than grepping sgdisk's English prose for "EFI system partition".
GPT_TYPE_GUID_ESP = bytes.fromhex("28732ac11ff8d211ba4b00a0c93ec93b")
GPT_TYPE_GUID_LINUX = bytes.fromhex("af3dc60f838472478e793d69d8477de4")

# Real staleness bug found 2026-09-24: write-image.py's stage_ncz_payload()
# `expected` list never picked up desktop-hotfix.squashfs / its manifest /
# busybox-$ARCH even after stage-ncz-payload.py started producing them
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


def build_ncz_payload_tree(stage_dir: Path, payload_dir: Path, arch: str,
                           patched_udeb: Path | None, preseed_dir: Path | None,
                           allow_missing_stub: bool = False,
                           post_install_dir: Path | None = None,
                           build_version: str | None = None) -> dict:
    """Same shape as write-image.py's stage_ncz_payload(), corrected
    for the hotfix/busybox staleness bug documented above."""
    if not payload_dir.is_dir():
        raise RuntimeError(f"FATAL: ncz-payload dir not found: {payload_dir}")
    ncz_payload_dst = stage_dir / "ncz-payload"
    ncz_payload_dst.mkdir(parents=True, exist_ok=True)

    staged = []
    for name in expected_payload_names(arch):
        src = payload_dir / name
        if not src.exists():
            continue
        dst = ncz_payload_dst / name
        if src.is_dir():
            run(["cp", "-a", str(src) + "/.", str(dst)])
        else:
            shutil.copy2(str(src), str(dst))
        staged.append(name)
    log(f"    cixmini tree staged: {staged}")

    # The staging loop skips anything absent, so without this it accepts an
    # EMPTY payload directory without complaint and happily builds install
    # media that cannot install anything (found 2026-09-24 alongside the
    # empty-data-partition bug). base.squashfs is the root filesystem and
    # sqtools/ is the arch-matched unsquashfs that extracts it: with either
    # one missing there is no install, so refuse here rather than at the
    # d-i prompt on the operator's hardware.
    for required in ("base.squashfs", "sqtools"):
        if required not in staged:
            raise RuntimeError(
                f"FATAL: payload dir {payload_dir} has no {required} -- "
                f"refusing to build install media that cannot install. "
                f"Staged: {staged}"
            )

    receipt = {"staged_files": staged}

    # The patched debootstrap udeb is NOT optional decoration. It carries the
    # r159 stub that replaces /usr/sbin/debootstrap, and that stub is the one
    # and only live path that extracts base.squashfs into /target: there is
    # no partman/late_command hook in d-i (verified against partman-base 241),
    # so extract-rootfs.sh never runs. Without this udeb on the medium,
    # bootstrap-base network-debootstraps a bare Debian and the install
    # silently produces the wrong system. preseed.cfg's partman/early_command
    # installs it and refuses to continue if it is missing; refuse here too,
    # at build time, where it is cheap to notice.
    if patched_udeb is not None:
        if not patched_udeb.is_file():
            raise RuntimeError(f"FATAL: patched udeb not found: {patched_udeb}")
        dst_dir = ncz_payload_dst / "debootstrap-udeb"
        dst_dir.mkdir(parents=True, exist_ok=True)
        shutil.copy2(str(patched_udeb), str(dst_dir / patched_udeb.name))
        receipt["patched_udeb"] = patched_udeb.name
        log(f"    staged patched debootstrap udeb: {patched_udeb.name}")
    elif allow_missing_stub:
        log("    WARNING: --allow-missing-debootstrap-stub -- this medium will "
            "NOT install NCZ-OS. partman/early_command will abort the install.")
    else:
        raise RuntimeError(
            "FATAL: no --patched-udeb. The r159 debootstrap stub is the only "
            "live path that extracts base.squashfs into /target (there is no "
            "partman/late_command hook in d-i), so a medium without it cannot "
            "install this distro -- it would network-debootstrap a bare "
            "Debian instead. Build one with build/iso/patch-debootstrap-stub.py "
            "and pass it here, or pass --allow-missing-debootstrap-stub if you "
            "are deliberately building a non-installing test medium."
        )

    # post-install/ -- the ~80 hooks run-all.sh executes inside /target.
    # build-iso-di.sh:3124 staged this onto every ISO ("cp -a $ROOT/post-install
    # $EXTRA/post-install"); the raw-GPT writer dropped it in the migration, and
    # late.sh's baked-mode refresh (which deletes the target's tree BEFORE
    # copying) then died under set -e with the scripts already gone. Staged
    # here from the repo rather than through stage-ncz-payload.py's
    # content-addressed cache on purpose: these are source files that change
    # constantly, and folding them into the payload node key would re-stage
    # 3.3 GiB of squashfs every time a hook comment is edited.
    if post_install_dir is not None:
        if not (post_install_dir / "run-all.sh").is_file():
            raise RuntimeError(
                f"FATAL: {post_install_dir} has no run-all.sh -- refusing to "
                f"stage a post-install tree that cannot run"
            )
        run(["cp", "-a", str(post_install_dir), str(ncz_payload_dst / "post-install")])
        names = sorted(p.name for p in (ncz_payload_dst / "post-install").iterdir())
        receipt["post_install_staged"] = len(names)
        log(f"    post-install/ staged: {len(names)} entries")

    # Media identity/metadata. late.sh copies BUILD_VERSION / BUILD_DATE /
    # BUILD_HOST / BUILD_ARCH / RELEASE off the medium into
    # /target/{etc,usr/local/lib}/cix-installer, where 50-brand.sh reads the
    # build serial and 23-base-apt-sources.sh reads the release profile.
    # build-iso-di.sh staged these; the raw-GPT writer did not, so every hook
    # that reads them silently fell back to whatever the squashfs happened to
    # bake in months earlier. RELEASE is release.conf verbatim -- the same
    # file 23-base-apt-sources.sh sources for the pinned mirror.
    release_conf = REPO_ROOT / "release.conf"
    if release_conf.is_file():
        shutil.copy2(str(release_conf), str(ncz_payload_dst / "RELEASE"))
        receipt["release_conf_sha256"] = sha256_file(release_conf)
    meta = {
        "BUILD_VERSION": build_version or "",
        "BUILD_DATE": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "BUILD_HOST": socket.gethostname(),
        "BUILD_ARCH": arch,
    }
    for name, value in meta.items():
        if value:
            (ncz_payload_dst / name).write_text(value + "\n")
    receipt["media_metadata"] = {k: v for k, v in meta.items() if v}
    log(f"    media metadata staged: {sorted(receipt['media_metadata'])}"
        f"{' + RELEASE' if release_conf.is_file() else ''}")

    if preseed_dir is not None and preseed_dir.is_dir():
        preseed_staged = []
        for entry in sorted(preseed_dir.iterdir()):
            if entry.name.startswith(".") or not entry.is_file():
                continue
            shutil.copy2(str(entry), str(ncz_payload_dst / entry.name))
            preseed_staged.append(entry.name)
        receipt["preseed_staged_files"] = preseed_staged
        log(f"    preseed/ staged: {preseed_staged}")

    return receipt


def build_data_partition_img(ncz_payload_tree_dir: Path, out_img: Path,
                             size_mib: int | None) -> int:
    """Build an ext4 filesystem image containing ncz_payload_tree_dir's
    PARENT layout (i.e. out_img's root gets a real /ncz-payload dir) via a
    real loopback mount (root required for device-node ownership inside
    the ext4 image, same pattern already used by patch-initrd-t2-kernel.py
    for depmod). Returns the final image size in bytes."""
    content_bytes = du_bytes(ncz_payload_tree_dir.parent)
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
            run(["sudo", "cp", "-a", str(ncz_payload_tree_dir), str(mnt) + "/"])
            run(["sudo", "chmod", "-R", "a+rX", str(mnt / "ncz-payload")])
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
    verify_data_partition_content(out_img, ncz_payload_tree_dir.parent)

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


def parse_gpt(image_path: Path) -> dict:
    """Parse BOTH GPT headers out of the finished image and check each
    one's CRC32s for real -- the header's own CRC and the partition-entry
    array CRC, primary and backup. Pure struct/zlib: no sgdisk, so the
    check is genuinely independent of the tool that wrote the table."""
    img_size = image_path.stat().st_size
    if img_size % SECTOR_SIZE:
        raise RuntimeError(
            f"FATAL: image size {img_size} is not a whole number of "
            f"{SECTOR_SIZE}-byte sectors"
        )
    last_lba = img_size // SECTOR_SIZE - 1
    result = {}
    with image_path.open("rb") as f:
        for which, hdr_lba in (("primary", 1), ("backup", last_lba)):
            f.seek(hdr_lba * SECTOR_SIZE)
            hdr = f.read(SECTOR_SIZE)
            if hdr[0:8] != b"EFI PART":
                raise RuntimeError(
                    f"FATAL: no GPT signature in the {which} header at LBA "
                    f"{hdr_lba} of {image_path}"
                )
            hdr_size = struct.unpack_from("<I", hdr, 12)[0]
            if not 92 <= hdr_size <= SECTOR_SIZE:
                raise RuntimeError(f"FATAL: absurd {which} GPT header size {hdr_size}")
            stored_hdr_crc = struct.unpack_from("<I", hdr, 16)[0]
            calc_hdr_crc = zlib.crc32(
                hdr[:16] + b"\x00\x00\x00\x00" + hdr[20:hdr_size]
            ) & 0xFFFFFFFF
            if stored_hdr_crc != calc_hdr_crc:
                raise RuntimeError(
                    f"FATAL: {which} GPT header CRC32 mismatch in {image_path}: "
                    f"stored {stored_hdr_crc:#010x}, computed {calc_hdr_crc:#010x}"
                )
            cur_lba, bak_lba = struct.unpack_from("<QQ", hdr, 24)
            first_usable, last_usable = struct.unpack_from("<QQ", hdr, 40)
            entries_lba = struct.unpack_from("<Q", hdr, 72)[0]
            n_entries, entry_size = struct.unpack_from("<II", hdr, 80)
            stored_arr_crc = struct.unpack_from("<I", hdr, 88)[0]
            if cur_lba != hdr_lba:
                raise RuntimeError(
                    f"FATAL: {which} GPT header self-pointer is LBA {cur_lba}, "
                    f"but it was read from LBA {hdr_lba}"
                )
            f.seek(entries_lba * SECTOR_SIZE)
            arr = f.read(n_entries * entry_size)
            calc_arr_crc = zlib.crc32(arr) & 0xFFFFFFFF
            if stored_arr_crc != calc_arr_crc:
                raise RuntimeError(
                    f"FATAL: {which} GPT partition-array CRC32 mismatch in "
                    f"{image_path}: stored {stored_arr_crc:#010x}, computed "
                    f"{calc_arr_crc:#010x}"
                )
            parts = {}
            for idx in range(n_entries):
                ent = arr[idx * entry_size:(idx + 1) * entry_size]
                type_guid = ent[0:16]
                if type_guid == b"\x00" * 16:
                    continue
                first, last = struct.unpack_from("<QQ", ent, 32)
                name = ent[56:128].decode("utf-16-le", "replace").rstrip("\x00")
                parts[idx + 1] = {
                    "type_guid": type_guid,
                    "start_sector": first,
                    "end_sector": last,
                    "name": name,
                }
            result[which] = {
                "current_lba": cur_lba,
                "backup_lba": bak_lba,
                "first_usable": first_usable,
                "last_usable": last_usable,
                "partitions": parts,
            }
    return result


def hash_image_range(image_path: Path, offset: int, length: int) -> str:
    h = hashlib.sha256()
    with image_path.open("rb") as f:
        f.seek(offset)
        remaining = length
        while remaining:
            chunk = f.read(min(1024 * 1024, remaining))
            if not chunk:
                raise RuntimeError(
                    f"FATAL: {image_path} ended {remaining} bytes early while "
                    f"hashing the range at offset {offset}"
                )
            h.update(chunk)
            remaining -= len(chunk)
    return h.hexdigest()


def verify_image_data_files(image_path: Path, part_num: int, required: list[str],
                            work_dir: Path) -> None:
    """Loop-mount the FINISHED image's data partition read-only and confirm
    the files an install actually needs are present and non-empty."""
    mnt = Path(tempfile.mkdtemp(prefix="ncz-img-verify-", dir=str(work_dir)))
    loop_dev = ""
    try:
        loop_dev = run(["sudo", "/sbin/losetup", "-fP", "--show", str(image_path)],
                       stdout=subprocess.PIPE, text=True).stdout.strip()
        if not loop_dev:
            raise RuntimeError("FATAL: losetup --show returned no device")
        part_dev = Path(f"{loop_dev}p{part_num}")
        # udev populates the partition nodes asynchronously after losetup -P.
        # `udevadm settle` is not usable here -- it exits 1 on this host even
        # when the nodes do appear -- so poll for the real thing instead.
        for _ in range(100):
            if part_dev.exists():
                break
            time.sleep(0.1)
        if not part_dev.exists():
            raise RuntimeError(
                f"FATAL: the kernel did not expose {part_dev} within 10s -- "
                f"the GPT in {image_path} is not readable as a real partition "
                f"table"
            )
        run(["sudo", "mount", "-o", "ro", part_dev, str(mnt)])
        try:
            missing = [r for r in required
                       if not (mnt / r).is_file() or (mnt / r).stat().st_size == 0]
            if missing:
                listing = sorted(p.name for p in (mnt / "ncz-payload").iterdir()) \
                    if (mnt / "ncz-payload").is_dir() else ["<no ncz-payload/ directory>"]
                raise RuntimeError(
                    f"FATAL: the finished image's data partition is missing "
                    f"required payload: {missing}. What is actually there: "
                    f"{listing}"
                )
        finally:
            run(["sudo", "umount", str(mnt)])
    finally:
        if loop_dev:
            subprocess.run(["sudo", "/sbin/losetup", "-d", loop_dev])
        shutil.rmtree(mnt, ignore_errors=True)
    log(f"    verify OK: finished image's partition {part_num} holds "
        f"{len(required)} required payload files")


def verify_image(image_path: Path, part_info: dict, esp_img: Path, data_img: Path,
                 required_data_files: list[str], work_dir: Path) -> None:
    """Independent re-read of the finished image.

    Rewritten 2026-09-24 after the empty-data-partition incident. The
    previous version compared the first 4096 BYTES of each partition and
    had a literal no-op (`pass`) where the partition-count check was
    supposed to be, so a corruption at offset 8192 -- or an entirely empty
    data filesystem -- passed verification cleanly. Every check here reads
    the whole thing.
    """
    gpt = parse_gpt(image_path)
    log("    verify OK: primary and backup GPT header + partition-array "
        "CRC32s are self-consistent")

    prim, bak = gpt["primary"], gpt["backup"]
    if prim["partitions"] != bak["partitions"]:
        raise RuntimeError(
            f"FATAL: primary and backup GPT disagree about the partitions:\n"
            f"  primary: {prim['partitions']}\n  backup:  {bak['partitions']}"
        )
    if prim["backup_lba"] != bak["current_lba"]:
        raise RuntimeError(
            f"FATAL: primary GPT points at backup LBA {prim['backup_lba']} but "
            f"the backup header lives at LBA {bak['current_lba']}"
        )

    parts = prim["partitions"]
    if sorted(parts) != [1, 2]:
        raise RuntimeError(
            f"FATAL: expected exactly partitions 1 and 2, found {sorted(parts)}"
        )

    expect = (
        (1, esp_img, GPT_TYPE_GUID_ESP, "NCZESP"),
        (2, data_img, GPT_TYPE_GUID_LINUX, "NCZDATA"),
    )
    for num, src, want_guid, want_name in expect:
        p = parts[num]
        if p["type_guid"] != want_guid:
            raise RuntimeError(
                f"FATAL: partition {num} type GUID is "
                f"{p['type_guid'].hex()}, expected {want_guid.hex()} "
                f"({want_name})"
            )
        if p["name"] != want_name:
            raise RuntimeError(
                f"FATAL: partition {num} is named {p['name']!r}, expected "
                f"{want_name!r}"
            )
        if (p["start_sector"] != part_info[num]["start_sector"]
                or p["end_sector"] != part_info[num]["end_sector"]):
            raise RuntimeError(
                f"FATAL: partition {num} on disk spans sectors "
                f"{p['start_sector']}..{p['end_sector']}, but the layout step "
                f"reported {part_info[num]['start_sector']}.."
                f"{part_info[num]['end_sector']}"
            )
        part_bytes = (p["end_sector"] - p["start_sector"] + 1) * SECTOR_SIZE
        src_bytes = src.stat().st_size
        if part_bytes < src_bytes:
            raise RuntimeError(
                f"FATAL: partition {num} is {part_bytes} bytes but {src} is "
                f"{src_bytes} bytes -- the source does not fit"
            )
        offset = p["start_sector"] * SECTOR_SIZE
        got = hash_image_range(image_path, offset, src_bytes)
        want = sha256_file(src)
        if got != want:
            raise RuntimeError(
                f"FATAL: partition {num} content mismatch. All {src_bytes} "
                f"bytes at offset {offset} hash to {got}, but {src} hashes to "
                f"{want}"
            )
        log(f"    verify OK: partition {num} ({want_name}) -- geometry, type "
            f"GUID and all {src_bytes} bytes match {src} (sha256 {got[:16]}...)")

    verify_image_data_files(image_path, 2, required_data_files, work_dir)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--arch", required=True, choices=["amd64", "arm64"])
    ap.add_argument("--esp-img", required=True, type=Path)
    ap.add_argument("--ncz-payload-dir", required=True, type=Path)
    ap.add_argument("--patched-udeb", type=Path,
                     help="Patched debootstrap-udeb carrying the r159 stub, "
                          "from build/iso/patch-debootstrap-stub.py. REQUIRED "
                          "for a medium that can actually install.")
    ap.add_argument("--allow-missing-debootstrap-stub", action="store_true",
                     help="Build without the r159 stub. The result CANNOT "
                          "install NCZ-OS; only for deliberate test media.")
    ap.add_argument("--preseed-dir", type=Path, default=REPO_ROOT / "preseed")
    ap.add_argument("--build-version", default=None,
                     help="Build serial staged as ncz-payload/BUILD_VERSION and "
                          "read by post-install/50-brand.sh.")
    ap.add_argument("--post-install-dir", type=Path,
                     default=REPO_ROOT / "post-install",
                     help="post-install hook tree staged at ncz-payload/post-install; "
                          "late.sh refreshes the installed copy from it.")
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
    if not args.ncz_payload_dir.is_dir():
        log(f"FATAL: ncz-payload dir not found: {args.ncz_payload_dir}")
        return 1

    # NOT tempfile.TemporaryDirectory(): its default $TMPDIR is /tmp, which is
    # a RAM-backed tmpfs on several fleet build hosts. See require_free_space().
    args.out.parent.mkdir(parents=True, exist_ok=True)
    work_root = args.work_dir if args.work_dir is not None else args.out.resolve().parent
    work_root.mkdir(parents=True, exist_ok=True)
    require_free_space(work_root,
                       du_bytes(args.ncz_payload_dir) + FREE_SPACE_MARGIN,
                       "the staged ncz-payload/ tree")
    tmp = Path(tempfile.mkdtemp(prefix="write-usb-image-", dir=str(work_root)))
    log(f"    work dir: {tmp}")
    try:
        stage_dir = tmp / "stage"
        stage_dir.mkdir()

        log("[1/4] staging ncz-payload/ tree")
        payload_receipt = build_ncz_payload_tree(
            stage_dir, args.ncz_payload_dir, args.arch,
            args.patched_udeb, args.preseed_dir if args.preseed_dir.is_dir() else None,
            args.allow_missing_debootstrap_stub,
            args.post_install_dir if args.post_install_dir.is_dir() else None,
            args.build_version,
        )

        log("[2/4] building ext4 data partition image")
        data_img = tmp / "data.img"
        build_data_partition_img(stage_dir / "ncz-payload", data_img, args.data_size_mib)

        log("[3/4] laying out GPT + writing partitions")
        esp_size = args.esp_img.stat().st_size
        data_size = data_img.stat().st_size
        args.out.parent.mkdir(parents=True, exist_ok=True)
        part_info = sgdisk_partition(args.out, esp_size, data_size)
        write_partition_bytes(args.out, part_info[1]["start_sector"], args.esp_img)
        write_partition_bytes(args.out, part_info[2]["start_sector"], data_img)

        log("[4/4] independent verification")
        required_data_files = [
            f"ncz-payload/{n}" for n in payload_receipt["staged_files"]
            if n != "sqtools"
        ] + ["ncz-payload/sqtools/unsquashfs"]
        if payload_receipt.get("post_install_staged"):
            required_data_files.append("ncz-payload/post-install/run-all.sh")
        if "patched_udeb" in payload_receipt:
            required_data_files.append(
                f"ncz-payload/debootstrap-udeb/{payload_receipt['patched_udeb']}")
        if "preseed.cfg" in payload_receipt.get("preseed_staged_files", []):
            required_data_files.append("ncz-payload/preseed.cfg")
        verify_image(args.out, part_info, args.esp_img, data_img,
                     required_data_files, tmp)

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
            "ncz_payload": payload_receipt,
        }
        receipt_path = args.out.with_suffix(args.out.suffix + ".receipt.json")
        receipt_path.write_text(json.dumps(receipt, indent=2, sort_keys=True))
        log(f"OK: {args.out} ({args.out.stat().st_size} bytes), receipt at {receipt_path}")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
