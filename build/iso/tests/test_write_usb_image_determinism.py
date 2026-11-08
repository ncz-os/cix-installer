"""The raw-GPT writer's data partition and media metadata are reproducible.

Measured 2026-11-07 on two amd64 builds of 342d44bc from the same pins: the
squashfs layers aside, the NCZDATA ext4 partition differed in every inode's
ctime/atime/crtime, in mtimes inherited from the checkout, in the superblock
mount/write times and in block placement (it was populated through a kernel
loop mount + cp -a), and /ncz-payload/BUILD_DATE carried the wall clock.

Run: python3 -m pytest build/iso/tests/test_write_usb_image_determinism.py -q
"""

from __future__ import annotations

import importlib.util
import os
import re
import shutil
import subprocess
import time
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[3]
WRITER = REPO_ROOT / "build" / "iso" / "write-usb-image.py"
MKFS = "/sbin/mkfs.ext4"


def _load(path: Path, name: str):
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec and spec.loader, f"cannot load {path}"
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


@pytest.fixture(scope="module")
def writer():
    return _load(WRITER, "write_usb_image")


def test_build_date_follows_source_date_epoch(writer, monkeypatch):
    monkeypatch.setenv("SOURCE_DATE_EPOCH", "1700000000")
    assert writer.media_build_date() == "2023-11-14T22:13:20Z"


@pytest.mark.parametrize("bad", ["", "abc", "\u00b2", "99999999999999999999"])
def test_invalid_epoch_is_ignored(writer, monkeypatch, bad):
    monkeypatch.setenv("SOURCE_DATE_EPOCH", bad)
    assert writer.source_date_epoch() is None
    assert writer.media_build_date()  # the clock, no crash


def test_build_date_without_epoch_is_the_clock(writer, monkeypatch):
    monkeypatch.delenv("SOURCE_DATE_EPOCH", raising=False)
    before = time.strftime("%Y-", time.gmtime())
    got = writer.media_build_date()
    after = time.strftime("%Y-", time.gmtime())
    assert got.startswith(before) or got.startswith(after), got


def _stage(root: Path) -> Path:
    src = root / "stage"
    (src / "ncz-payload" / "post-install").mkdir(parents=True)
    (src / "ncz-payload" / "post-install" / "late.sh").write_text("#!/bin/sh\n")
    (src / "ncz-payload" / "base.squashfs").write_bytes(b"x" * 300000)
    (src / "pool").mkdir()
    (src / "pool" / "a.deb").write_bytes(b"deb")
    return src


@pytest.mark.skipif(not os.path.exists(MKFS), reason="mkfs.ext4 not available")
def test_data_partition_is_byte_identical_across_stagings(
    writer, tmp_path, monkeypatch
):
    monkeypatch.setenv("SOURCE_DATE_EPOCH", "1700000000")
    monkeypatch.setenv(
        "NCZ_REPRO_UUID_EXT4_DATA", "13ace74c-e1f0-5444-bd73-8df753aa7297"
    )
    monkeypatch.setenv(
        "NCZ_REPRO_UUID_EXT4_HASHSEED", "cb2f666d-2f17-5d93-a7d8-7ae1c5c3b98a"
    )
    imgs = []
    for i in range(2):
        run = tmp_path / f"run{i}"
        run.mkdir()
        if i:
            time.sleep(1.2)  # every staged file gets a later mtime/ctime
        src = _stage(run)
        img = run / "data.img"
        with img.open("wb") as f:
            f.truncate(64 * 1024 * 1024)
        argv = writer.data_mkfs_argv(src, img)
        assert "-d" in argv and str(src) in argv
        subprocess.run(argv, check=True)
        imgs.append(img.read_bytes())
    assert imgs[0] == imgs[1], "NCZDATA ext4 differs between two stagings"


@pytest.mark.skipif(not shutil.which("debugfs"), reason="debugfs not available")
@pytest.mark.skipif(not os.path.exists(MKFS), reason="mkfs.ext4 not available")
def test_data_partition_root_is_root_owned_0755(writer, tmp_path, monkeypatch):
    monkeypatch.setenv("SOURCE_DATE_EPOCH", "1700000000")
    src = _stage(tmp_path)
    src.chmod(0o700)  # the writer's mkdtemp staging root
    img = tmp_path / "data.img"
    with img.open("wb") as f:
        f.truncate(64 * 1024 * 1024)
    subprocess.run(writer.data_mkfs_argv(src, img), check=True)
    out = subprocess.run(
        ["debugfs", "-R", "stat /", str(img)],
        capture_output=True,
        text=True,
        check=True,
    ).stdout
    assert re.search(r"User:\s+0\s+Group:\s+0\b", out), out
    assert re.search(r"Mode:\s+0755\b", out), out


def _dists(root: Path) -> Path:
    suite_dir = root / "dists" / "forky"
    idx = suite_dir / "main" / "binary-amd64"
    idx.mkdir(parents=True)
    (idx / "Packages").write_text("Package: x\n")
    return suite_dir


@pytest.mark.skipif(not shutil.which("apt-ftparchive"), reason="apt-ftparchive not available")
def test_medium_release_is_byte_identical_and_dated_by_epoch(writer, tmp_path, monkeypatch):
    """Measured 2026-11-07: with every layer identical, two builds of one
    commit (amd64 and arm64) still differed in /dists/<suite>/Release on
    NCZDATA: apt-ftparchive stamps the wall clock as Date (it ignores
    SOURCE_DATE_EPOCH), and because its output was redirected INTO the tree
    it scans, the file listed a checksum of its own half-written header."""
    monkeypatch.setenv("SOURCE_DATE_EPOCH", "1700000000")
    outs = []
    for i in range(2):
        root = tmp_path / f"run{i}"
        if i:
            time.sleep(1.2)
        suite_dir = _dists(root)
        writer.write_medium_release(root, "forky", "amd64")
        outs.append((suite_dir / "Release").read_bytes())
        assert sorted(p.name for p in root.iterdir()) == ["dists"], "temp file left on the medium"
    assert outs[0] == outs[1], "Release differs between two runs"
    text = outs[0].decode()
    assert "Date: Tue, 14 Nov 2023 22:13:20 +0000" in text, text
    listed = [line.split()[-1] for line in text.splitlines() if line.startswith(" ")]
    assert "main/binary-amd64/Packages" in listed
    assert "Release" not in listed, "Release lists a checksum of itself"


def test_release_date_is_rfc2822_c_locale(writer, monkeypatch):
    monkeypatch.setenv("SOURCE_DATE_EPOCH", "1793607971")
    assert writer.release_date() == "Mon, 02 Nov 2026 08:26:11 +0000"
    monkeypatch.delenv("SOURCE_DATE_EPOCH")
    assert writer.release_date() is None
