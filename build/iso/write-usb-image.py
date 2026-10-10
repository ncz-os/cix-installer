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
`preseed/file=/cdrom/ncz-payload/preseed.cfg` kernel-param fetch (removed
2026-10-08 -- the preseed is now loaded once from the initrd) depended on
some d-i component classifying + mounting the medium as a CD-ROM before
that fetch ran, and on a real USB-written hybrid medium that timing is
not guaranteed (confirmed on real MEDUSA hardware 2026-09-24, not a QEMU
artifact -- see patch-initrd-t2-kernel.py's preseed.cfg bake-in, which
fixed the EARLY fetch; this script removes the underlying
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
import gzip
import hashlib
import json
import os
import re
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


def _asset_kernel_ignore(base_dir: str, names: list[str]) -> list[str]:
    """Prune dev-only / aborted / stale siblings from a staged asset tree.

    The kernel staging script (``build/stage-kernel.sh``) and the shared
    kernel-staging pool on /mnt/argonas-yocto-shared regularly leave
    sibling directories or files alongside the real artifact, named:

      * ``*.native-prepare-rejected`` / ``*-rejected`` -- left behind by an
        aborted or failed ``linux_modules_prepare`` run; its OWN name
        admits it was rejected. Shipping it onto the ISO wastes
        ~600 MiB and trips dkms-abi-gate against a half-prepared
        include/config (the 2026-09-28 arm64 stage-2 incident).
      * ``*.stale-<ts>`` -- rotated aside by
        ``build/build-squashfs-layers.sh``'s base-rebuild branch so an
        operator can compare manually; also dead weight on the medium.
      * ``*.pre-*`` / ``*.bak`` / ``*.bak-*`` -- pruned from the
        staged asset tree by ``build/build-squashfs-layers.sh`` line ~941
        for exactly this reason; we follow the same precedent so an ISO
        built either way does not accidentally ship them.

    This is the asset-tree analog of build-squashfs-layers.sh's
    ``sudo find ... -delete`` block: both run on the SAME trees at
    different points in the pipeline, and a divergence between them is
    exactly the kind of subtle content-drift bug that becomes invisible
    until an installer chokes on a half-prepared headers-dir.
    """
    import fnmatch
    # Exact mirror of build-squashfs-layers.sh line ~941 plus the two known
    # aborted-staging suffixes; anchored globs, never substring matches, so a
    # legitimate file that merely contains ".bak" or ".pre-" mid-name survives.
    patterns = ("*.native-prepare-rejected", "*.stale-*", "*.stale",
                "*.pre-*", "*.bak", "*.r57-bak")
    return [n for n in names
            if any(fnmatch.fnmatchcase(n, pat) for pat in patterns)]


def _copytree_dangling_symlink_safe(src: Path, dst: Path, *,
                                    ignore=None, dirs_exist_ok: bool = True
                                    ) -> None:
    """Copy a directory tree to ``dst`` while preserving symlinks AS
    symlinks. Tolerates dangling symlinks inside ``src`` by construction
    (``symlinks=True``); refuses to swallow other errors.

    Defect (measured ULTRA arm64 make image 2026-09-28 20:12):
    ``shutil.copytree(src, dst, symlinks=False)`` -- the default --
    FOLLOWS symlinks. A staged headers tree contains
    ``scripts/kernel-doc`` whose target was removed by an upstream
    kernel-doc refactor. Following the symlink raises ``FileNotFoundError``
    inside copytree, which is then wrapped in a ``shutil.Error`` listing
    EVERY path that came before it -- making the error read like a
    wholesale copy failure even though the one real fault is the single
    dangling symlink at ``scripts/kernel-doc``.

    The fix is the same one ``write-usb-image.py`` already uses at line
    362 for the rEFInd asset (``shutil.copytree(refind_src, ..., symlinks=True)``):
    copy the symlink as a symlink, never resolve it. The rEFInd copy has
    worked for the entire pipeline history precisely because it did this
    one thing differently from the kernel channel loop below, which did
    not. We adopt the same pattern uniformly here and pass through any
    other error (including a real missing file) so the distinction
    between "benign dangling symlink" and "missing real file" survives
    in the traceback rather than getting swallowed.
    """
    shutil.copytree(str(src), str(dst), symlinks=True,
                    ignore=ignore, dirs_exist_ok=dirs_exist_ok)


SSPLUGIN_LOCK = REPO_ROOT / "post-install" / "lib" / "ncz-screensavers-plugin.lock"
SSPLUGIN_STAGED = REPO_ROOT / "build" / "ncz-screensavers-out"


def read_ssplugin_lock(lock: Path) -> dict:
    """KEY=VALUE pairs of post-install/lib/ncz-screensavers-plugin.lock."""
    out = {}
    for raw in lock.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        out[k.strip()] = v.strip().strip('"')
    return out


def stage_ssplugin_deb(assets_dst: Path, arch: str,
                       lock: Path = SSPLUGIN_LOCK,
                       staged_dir: Path = SSPLUGIN_STAGED) -> str | None:
    """Put the pinned Singularity screensaver plugin deb on the medium.

    post-install/59-ncz-screensavers-pkg.sh installs it from
    /cdrom/ncz-payload/assets/ncz-screensavers-plugin/ (late.sh also
    union-syncs it into /usr/local/lib/cix-installer/assets/). It is NOT in
    the offline apt pool: it is ABI-coupled to the Singularity payload that
    stage 1 rebuilds, so it travels with the payload, after stage 1, instead
    of with the stage-0 mirror. The pin (sha256 per arch) is the lock file;
    a missing or different staged deb is fatal, since the installed-target
    gate would fail later on every install. Returns the staged name, or None
    when the tree carries no pin (a checkout before the plugin was wired).
    """
    if not lock.is_file():
        return None
    pin = read_ssplugin_lock(lock)
    name = f"{pin['NCZ_SSPLUGIN_PKG']}_{pin['NCZ_SSPLUGIN_VERSION']}_{arch}.deb"
    want = pin.get(f"NCZ_SSPLUGIN_SHA256_{arch}", "")
    src = staged_dir / name
    if not src.is_file():
        raise RuntimeError(
            f"FATAL: {src} missing; run build/stage-screensaver-plugin.sh {arch} "
            f"on the build host (pin: {lock})")
    got = sha256_file(src)
    if not want or got != want:
        raise RuntimeError(
            f"FATAL: {src} sha256 {got} != pinned {want or '<none>'} ({lock})")
    dst = assets_dst / "ncz-screensavers-plugin"
    dst.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dst / name)
    return name


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

    # Install-time assets are deliberately outside the content-addressed
    # squashfs node: like post-install/, they can change without rebuilding a
    # multi-gigabyte base layer.  The original raw-GPT writer staged neither
    # tree.  late.sh therefore kept whatever happened to be baked into the
    # base image: on the first real AMD64/T2 installs that meant no rescue
    # rootfs at all, while 72-rescue-partition.sh and the bootloader require
    # one.  It also let 70-bootloader.sh drift from the shared rEFInd script it
    # invokes.  Stage and validate both inputs as one coherent payload.
    assets_dst = ncz_payload_dst / "assets"
    refind_src = REPO_ROOT / "assets" / "refind"
    required_refind = (
        ("refind_x64.efi", "ncz-refind-refresh-amd64.sh",
         "zz1-ncz-refind-refresh-amd64")
        if arch == "amd64"
        else ("refind_aa64.efi", "ncz-refind-refresh.sh")
    )
    missing_refind = [name for name in required_refind
                      if not (refind_src / name).is_file()]
    if missing_refind:
        raise RuntimeError(
            f"FATAL: required {arch} rEFInd assets missing from {refind_src}: "
            f"{missing_refind}"
        )
    shutil.copytree(str(refind_src), str(assets_dst / "refind"),
                    symlinks=True)

    rescue_dir = REPO_ROOT / "assets" / "rescue"
    rescue_candidates = [
        rescue_dir / f"rescue-rootfs-{arch}.tar.zst",
        rescue_dir / "rescue-rootfs.tar.zst",
    ]
    rescue_src = next((p for p in rescue_candidates if p.is_file()), None)
    if rescue_src is None:
        raise RuntimeError(
            f"FATAL: no {arch} rescue rootfs (checked: "
            f"{', '.join(str(p) for p in rescue_candidates)}). "
            f"Build it before emitting install media: sudo bash "
            f"build/build-rescue-rootfs.sh build/rescue-rootfs-{arch} "
            f"assets/rescue/rescue-rootfs-{arch}.tar.zst forky {arch}"
        )
    (assets_dst / "rescue").mkdir(parents=True, exist_ok=True)
    shutil.copy2(str(rescue_src),
                 str(assets_dst / "rescue" / "rescue-rootfs.tar.zst"))
    agents_src = rescue_dir / "AGENTS.md"
    if agents_src.is_file():
        shutil.copy2(str(agents_src), str(assets_dst / "rescue" / "AGENTS.md"))
    receipt["runtime_assets_staged"] = {
        "refind": list(required_refind),
        "rescue_rootfs": str(rescue_src),
    }
    log(f"    runtime assets staged: rEFInd ({arch}) + {rescue_src.name}")

    # Architecture payloads are content, not build mechanics.  Keep the GPT
    # writer shared and select the same committed asset families the legacy
    # arm64 assembler placed under /ncz-payload/assets/.  In particular this
    # is what carries Sky1's Image/modules/headers/config set, Mali/Panthor,
    # NPU/VPU DKMS sources and prebuilt overlays, MPAM/NPU data and firmware.
    # AMD64 uses the identical loop but naturally has the single
    # amd64-stable 7.3 kernel package directory (operator directive
    # 2026-10-05, unified; the amd64-edge channel is retired) instead of the
    # Sky1 tarball shape.
    asset_names = (
        "agent-stack", "branding", "cix-debs", "diag", "firmware",
        "kernel", "npu", "python311", "sky1-firmware", "mgmt",
        # assets/update-manager/ ships the OTA desktop update UI (7 tracked
        # files: the .manager/.policy units, the ncz-update-* helpers and the
        # .desktop entry). It was never listed here, so hook
        # 50-update-manager.sh looked for /usr/local/lib/cix-installer/assets/
        # update-manager and /cdrom/ncz-payload/assets/update-manager, found
        # neither, and failed as an optional hook on every install (KNOWN-
        # ISSUES #2). Listing it is all that is needed: the copy loop below
        # is generic and skips a name whose source directory is absent.
        "update-manager",
    )
    copied_assets = []
    for name in asset_names:
        src = REPO_ROOT / "assets" / name
        dst = assets_dst / name
        if not src.exists():
            continue
        if name == "kernel":
            # mainline is the single Sky1 kernel channel (unified 7.3 policy,
            # 2026-10-05); it replaced edge, which used to be listed here.
            channels = (("mainline", "mali", "mali-70012", "modules-overlay",
                         "npu", "panthor", "vpu") if arch == "arm64"
                        else ("amd64-stable",))
            dst.mkdir(parents=True, exist_ok=True)
            for channel in channels:
                child = src / channel
                if not child.exists():
                    continue
                if child.is_symlink():
                    # mainline (the Sky1 kernel pointer) is itself a symlink
                    # into the shared kernel-staging pool. Resolve it
                    # explicitly: copying a symlink with shutil.copytree
                    # would land the SYMLINK on the medium, which then
                    # breaks the installer's first read of KVER (a symlink
                    # whose target is a path inside the installer's
                    # chroot that doesn't exist). Following once here
                    # produces a real directory on the medium.
                    real_src = child.resolve()
                    if not real_src.is_dir():
                        log(f"    WARN: assets/kernel/{channel} symlink "
                            f"target missing: {real_src} -- skipping "
                            f"this channel (kernel not staged on this host)")
                        continue
                    child = real_src
                _copytree_dangling_symlink_safe(
                    child, dst / channel,
                    ignore=_asset_kernel_ignore,
                    dirs_exist_ok=True,
                )
                pruned = _asset_kernel_ignore(
                    str(child),
                    [p.name for p in child.iterdir()],
                )
                if pruned:
                    log(f"    pruned {channel}: {pruned}")
            copied_assets.append(name)
            continue
        if name == "cix-debs" and arch != "arm64":
            continue
        if name == "cix-debs":
            dst.mkdir(parents=True, exist_ok=True)
            excluded = ("cix-unit-test_", "cix-ltp_", "cix-gpu-test_",
                        "cix-vpu-test_", "cix-npu-onnxruntime_",
                        "cix-noe-umd_1.1.1_")
            for child in src.iterdir():
                if child.name.startswith(excluded):
                    continue
                if child.is_file():
                    shutil.copy2(child, dst / child.name)
            copied_assets.append(name)
            continue
        shutil.copytree(src, dst, symlinks=False, dirs_exist_ok=True)
        copied_assets.append(name)
    ncz_cli = REPO_ROOT / "assets" / "ncz-cli.sh"
    if ncz_cli.is_file():
        shutil.copy2(ncz_cli, assets_dst / ncz_cli.name)
    if arch == "arm64":
        # The unified 7.3 policy retired assets/kernel/edge; the one shipping
        # Sky1 kernel is assets/kernel/mainline. Its KVER is still published
        # under the historical sidecar name KVER_NEXT, which late.sh copies to
        # /etc/cix-installer and post-install/10-our-kernel.sh requires;
        # install_kernel_headers() reads headers-cixmini.tar.zst from
        # /cdrom/ncz-payload/assets/kernel/mainline.
        mainline = assets_dst / "kernel" / "mainline"
        required = ("Image-cixmini.bin", "modules-cixmini.tgz", "KVER",
                    "headers-cixmini.tar.zst")
        missing = [n for n in required if not (mainline / n).is_file()]
        if missing:
            raise RuntimeError(
                f"FATAL: arm64 Sky1 mainline kernel payload incomplete: {missing}")
        shutil.copy2(mainline / "KVER", ncz_payload_dst / "KVER_NEXT")
    ssplugin = stage_ssplugin_deb(assets_dst, arch)
    if ssplugin:
        copied_assets.append("ncz-screensavers-plugin")
        log(f"    screensaver settings plugin staged: {ssplugin}")
    receipt["architecture_assets_staged"] = copied_assets
    log(f"    architecture assets staged ({arch}): {copied_assets}")

    # Build-timestamped NCZ payload debs: record the exact identity+sha256 of the
    # bytes staged for THIS image.  The version embeds a build timestamp so the
    # deb cannot be statically sha-pinned; the provenance gate authorizes it only
    # via exact name + version regex (manifests/ncz-timestamped.tsv) + this
    # receipt entry.  A declared package that is not staged, or whose staged
    # version misses the reviewed regex, fails the build here.
    ts_tsv = REPO_ROOT / "manifests" / "ncz-timestamped.tsv"
    if ts_tsv.is_file():
        decl = {}
        for line in ts_tsv.read_text(encoding="utf-8").splitlines():
            if not line.strip() or line.startswith("#"):
                continue
            f = line.split("\t")
            if len(f) >= 6:
                decl[(f[0], f[2])] = re.compile(f[1])
        required = {k for k in decl if k[1] in (arch, "all")}
        ts_rec = []
        seen = set()
        for deb in sorted(ncz_payload_dst.rglob("*.deb")):
            r = subprocess.run(
                ["dpkg-deb", "-f", str(deb), "Package", "Version", "Architecture"],
                capture_output=True, text=True)
            if r.returncode != 0:
                continue
            d = dict(ln.split(": ", 1) for ln in r.stdout.splitlines() if ": " in ln)
            name, ver, darch = (d.get("Package", ""), d.get("Version", ""),
                                d.get("Architecture", ""))
            rx = decl.get((name, darch))
            if rx is None or not rx.match(ver):
                continue
            ts_rec.append({"filename": deb.name, "name": name, "version": ver,
                           "arch": darch, "sha256": sha256_file(deb)})
            seen.add((name, darch))
        missing = sorted(required - seen)
        if missing:
            raise RuntimeError(
                "FATAL: build-timestamped NCZ package(s) declared in "
                f"manifests/ncz-timestamped.tsv but not staged for {arch}: {missing}")
        receipt["ncz_timestamped_debs"] = ts_rec
        if ts_rec:
            log("    build-timestamped NCZ debs recorded in receipt: "
                f"{[e['filename'] for e in ts_rec]}")

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


KERNEL_ARTIFACT_NAME_RE = re.compile(
    r"^(linux-image|linux-headers|linux-modules|linux-binary|kernel-image)"
    r"|^linux-base-"
    r"|.+-modules-.+-di$|.+-binary-.+-di$")


def filter_substrate_kernel_artifacts(pool_dir: Path) -> int:
    """One-kernel policy: remove Debian kernel/module/binary udebs+debs from a
    merged /cdrom pool copy.  NCZ kernels (names containing cixmini/ncz) are
    kept.  UNPROVEN until the KVM install gate passes on a rebuilt image."""
    removed = 0
    for p in sorted(pool_dir.rglob("*")):
        if not p.is_file() or p.suffix not in (".deb", ".udeb"):
            continue
        pkg = p.name.split("_", 1)[0]
        if "cixmini" in pkg or "ncz" in pkg:
            continue
        if KERNEL_ARTIFACT_NAME_RE.search(pkg):
            p.unlink()
            removed += 1
    return removed


def stage_offline_mirror(stage_dir: Path, arch: str,
                         installer_pool: Path) -> None:
    """Copy the offline apt closure to the medium root as dists/ + pool/.

    This is what makes an install offline. post-install/20-desktop.sh gates
    on `/cdrom/dists/$NCZ_APT_SUITE` and writes
    `deb [trusted=yes] file:///cdrom $SUITE main`; without the closure at the
    root that test is false and every package install silently falls through
    to the network. build-iso-di.sh embedded it and aborted when it was
    missing; the raw-GPT writer never did.

    The closure is built by the `offline-mirror` make target (a prerequisite
    of the image target) and is a complete, verified apt repo -- 1764 packages
    on arm64 including google-chrome-stable and chromium-ncz-sky1, resolved
    from manifests/{installer-base,desktop}.pkgs over the vendor and desktop
    mirrors, with Release regenerated by apt-ftparchive.
    """
    suite = "forky"
    release_conf = REPO_ROOT / "release.conf"
    if release_conf.is_file():
        for line in release_conf.read_text().splitlines():
            if line.startswith("NCZ_BASE_CODENAME="):
                suite = line.split("=", 1)[1].strip().strip('"').strip("'") or suite
                break

    mirror = REPO_ROOT / "build" / f"{suite}-mirror"
    if not (mirror / "dists").is_dir() or not (mirror / "pool").is_dir():
        raise RuntimeError(
            f"FATAL: offline apt closure missing at {mirror} (need dists/ and "
            f"pool/). Run `make offline-mirror` first -- without it the "
            f"installed system has no local package source and every "
            f"post-install hook silently falls back to the network."
        )
    if not (mirror / "dists" / suite).is_dir():
        raise RuntimeError(
            f"FATAL: {mirror}/dists has no '{suite}' suite, so "
            f"/cdrom/dists/{suite} would not exist and 20-desktop.sh's offline "
            f"check would stay false"
        )

    for name in ("dists", "pool"):
        shutil.copytree(mirror / name, stage_dir / name, symlinks=True)

    # The medium stays a d-i installation source even without preseed/file=:
    # preseed/early_command mounts this GPT data partition at /cdrom before
    # cdrom-detect runs, so cdrom-detect exits on the already-mounted /cdrom and
    # cdrom-retriever (load-cdrom) reads the installer Packages index from here.
    # The raw-image mirror contains regular .debs only, while cdrom-retriever
    # requires the installer Packages path to exist in (and be hashed by)
    # Release even when every required udeb is already baked into the initrd.
    # Carry the substrate's matching udeb pool and index it, as the old ISO
    # builder did. An empty index lets load-cdrom return, but leaves main-menu
    # with no next component; this must be a real installer repository.
    if not installer_pool.is_dir():
        raise RuntimeError(f"FATAL: installer udeb pool missing: {installer_pool}")
    shutil.copytree(installer_pool, stage_dir / "pool", dirs_exist_ok=True,
                    symlinks=True)
    # One-kernel policy (docs/ONE-KERNEL.md).  When NCZ_ONE_KERNEL=1, drop the
    # substrate's Debian kernel/module/binary udebs from the merged /cdrom pool
    # so the image carries only OUR kernel.  UNPROVEN until
    # build/kvm-install-gate-gpt.sh reaches "finish the installation" on a
    # rebuilt image (the installer still needs its own kernel+initrd -- see
    # docs/ONE-KERNEL.md step 2); default-OFF so the unverified path is
    # unchanged.
    if os.environ.get("NCZ_ONE_KERNEL") == "1":
        removed = filter_substrate_kernel_artifacts(stage_dir / "pool")
        log(f"    one-kernel: removed {removed} Debian kernel/module artifact(s) "
            f"from the merged /cdrom pool")
    installer_index = (stage_dir / "dists" / suite / "main" /
                       "debian-installer" / f"binary-{arch}")
    installer_index.mkdir(parents=True, exist_ok=True)
    packages = installer_index / "Packages"
    with packages.open("wb") as stream:
        subprocess.run(
            ["dpkg-scanpackages", "--type", "udeb", "--multiversion",
             "pool/main", "/dev/null"],
            cwd=stage_dir, check=True, stdout=stream,
        )
    with gzip.GzipFile(filename=str(installer_index / "Packages.gz"),
                       mode="wb", mtime=0) as stream:
        stream.write(packages.read_bytes())

    release = stage_dir / "dists" / suite / "Release"
    release_cmd = [
        "apt-ftparchive",
        "-o", f"APT::FTPArchive::Release::Suite={suite}",
        "-o", f"APT::FTPArchive::Release::Codename={suite}",
        "-o", f"APT::FTPArchive::Release::Architectures={arch}",
        "-o", "APT::FTPArchive::Release::Components=main",
        "-o", "APT::FTPArchive::Release::Origin=NCZ-OS",
        "-o", "APT::FTPArchive::Release::Label=NCZ-OS offline media",
        "release", str(stage_dir / "dists" / suite),
    ]
    with release.open("wb") as stream:
        subprocess.run(release_cmd, check=True, stdout=stream)

    debs = sum(1 for _ in (stage_dir / "pool").rglob("*.deb"))
    log(f"    offline apt closure staged ({arch}, suite={suite}): "
        f"{debs} debs from {mirror}")


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
            # Copy every staged top-level entry, not just ncz-payload. The
            # docstring above and the content_bytes sizing already treat the
            # PARENT as the image root; copying one child silently dropped
            # anything else staged beside it (notably the offline apt
            # closure's dists/ and pool/).
            for _entry in sorted(ncz_payload_tree_dir.parent.iterdir()):
                run(["sudo", "cp", "-a", str(_entry), str(mnt) + "/"])
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
    ap.add_argument("--installer-pool", required=True, type=Path,
                    help="Architecture-matched substrate pool containing udebs")
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
        stage_offline_mirror(stage_dir, args.arch, args.installer_pool)
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
        if payload_receipt.get("runtime_assets_staged"):
            required_data_files.extend([
                "ncz-payload/assets/refind/" +
                ("refind_x64.efi" if args.arch == "amd64" else "refind_aa64.efi"),
                "ncz-payload/assets/rescue/rescue-rootfs.tar.zst",
            ])
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
            # Top-level convenience copy: the sha256 of every build-timestamped
            # NCZ payload deb actually staged (manifests/ncz-timestamped.tsv).
            # build/forky-provenance.py cross-checks the bytes it scans against
            # this map; a timestamped package absent here fails closed.
            "ncz_timestamped_debs": payload_receipt.get("ncz_timestamped_debs", []),
        }
        receipt_path = args.out.with_suffix(args.out.suffix + ".receipt.json")
        receipt_path.write_text(json.dumps(receipt, indent=2, sort_keys=True))
        log(f"OK: {args.out} ({args.out.stat().st_size} bytes), receipt at {receipt_path}")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
