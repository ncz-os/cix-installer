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


def test_build_date_without_epoch_is_the_clock(writer, monkeypatch):
    monkeypatch.delenv("SOURCE_DATE_EPOCH", raising=False)
    assert writer.media_build_date().startswith(time.strftime("%Y-", time.gmtime()))


def _stage(root: Path) -> Path:
    src = root / "stage"
    (src / "ncz-payload" / "post-install").mkdir(parents=True)
    (src / "ncz-payload" / "post-install" / "late.sh").write_text("#!/bin/sh\n")
    (src / "ncz-payload" / "base.squashfs").write_bytes(b"x" * 300000)
    (src / "pool").mkdir()
    (src / "pool" / "a.deb").write_bytes(b"deb")
    return src


@pytest.mark.skipif(not os.path.exists(MKFS), reason="mkfs.ext4 not available")
def test_data_partition_is_byte_identical_across_stagings(writer, tmp_path, monkeypatch):
    monkeypatch.setenv("SOURCE_DATE_EPOCH", "1700000000")
    monkeypatch.setenv("NCZ_REPRO_UUID_EXT4_DATA", "13ace74c-e1f0-5444-bd73-8df753aa7297")
    monkeypatch.setenv("NCZ_REPRO_UUID_EXT4_HASHSEED", "cb2f666d-2f17-5d93-a7d8-7ae1c5c3b98a")
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
    out = subprocess.run(["debugfs", "-R", "stat /", str(img)],
                         capture_output=True, text=True, check=True).stdout
    assert "User:     0   Group:     0" in out, out
    assert "Mode:  0755" in out, out
