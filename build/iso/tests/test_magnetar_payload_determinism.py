"""The Magnetar (NCZ_VARIANT=server) payload is reproducible.

A server medium pins three artifacts by sha256 in ncz-fetch-payload.manifest:
base.squashfs, ncz-assets-<arch>.tar.gz and ncz-pool-<arch>.tar.gz. If any of
them changes between two builds of the same pins, the medium's manifest
changes, so the image changes too, and a published payload would no longer
match a rebuilt medium.

The desktop determinism work (5702cc38) made the MEDIUM's Release reproducible
by rewriting it with a Date from SOURCE_DATE_EPOCH. A server medium carries no
offline pool: the pool tarball packs build/<suite>-mirror/{dists,pool} as the
offline-mirror stage left it, and build-forky-mirror.sh stamped that Release
with the wall clock (apt-ftparchive ignores SOURCE_DATE_EPOCH) and redirected
it into the tree it was scanning. So two server builds of one commit pinned
different pool tarballs even when every .deb was identical.

These tests build the payload twice from independent fixture trees (different
mtimes, creation order and xattrs), the way two clean CI builds would, and
require byte-identical tarballs and sha256 sidecars.

Run: python3 -m pytest build/iso/tests/test_magnetar_payload_determinism.py -q
"""

from __future__ import annotations

import gzip
import hashlib
import importlib.util
import os
import shutil
import subprocess
import tarfile
import time
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[3]
WRITER = REPO_ROOT / "build" / "iso" / "write-usb-image.py"
RELEASE_LIB = REPO_ROOT / "build" / "lib" / "apt-release.sh"
FORKY_MIRROR = REPO_ROOT / "build" / "build-forky-mirror.sh"
SDE = 1791404677  # a fixed epoch (2026-10-07T20:24:37Z)


def _load(path: Path, name: str):
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec and spec.loader, f"cannot load {path}"
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


@pytest.fixture(scope="module")
def writer():
    return _load(WRITER, "write_usb_image_magnetar_det")


def _sha(p: Path) -> str:
    return hashlib.sha256(p.read_bytes()).hexdigest()


def _write(root: Path, rel: str, data: bytes, mtime: int) -> None:
    p = root / rel
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_bytes(data)
    os.utime(p, (mtime, mtime))


ASSET_FILES = {
    "assets/rescue/ncz-rescue-rootfs.tar.zst": b"rescue-rootfs-bytes" * 64,
    "assets/firmware/iwlwifi-x.ucode": b"\x00\x01firmware" * 32,
    "assets/kernel/linux-image-7.3.3_amd64.deb": b"!<arch>\nkernel" * 40,
    "assets/kernel/KVER": b"7.3.3-t2-ncz\n",
    "assets/branding/logo.png": b"\x89PNG\r\n\x1a\nbrand",
}


def _asset_tree(root: Path, mtime: int, reverse: bool, xattr: bool) -> Path:
    """One staged asset tree. Two calls with different mtime/reverse/xattr give
    the same CONTENT in a different on-disk history, like two clean builds."""
    names = sorted(ASSET_FILES, reverse=reverse)
    for rel in names:
        _write(root, rel, ASSET_FILES[rel], mtime)
        if xattr:
            try:
                os.setxattr(root / rel, "user.ncz.test", b"build-host-noise")
            except OSError:
                pass  # filesystem without user xattrs: the rest still holds
    for d in sorted({str(Path(r).parent) for r in names}) + ["assets"]:
        os.utime(root / d, (mtime, mtime))
    return root


def _mirror_tree(root: Path, mtime: int, reverse: bool) -> Path:
    files = {
        "pool/main/a/alpha_1.0_amd64.deb": b"!<arch>\nalpha" * 50,
        "pool/main/b/beta_2.0_all.deb": b"!<arch>\nbeta" * 50,
        "dists/forky/main/binary-amd64/Packages":
            b"Package: alpha\nVersion: 1.0\n\nPackage: beta\nVersion: 2.0\n",
    }
    for rel in sorted(files, reverse=reverse):
        _write(root, rel, files[rel], mtime)
    pk = root / "dists/forky/main/binary-amd64/Packages"
    # build-forky-mirror.sh compresses with gzip -9n (no name, no mtime)
    with gzip.GzipFile(filename="", mode="wb", fileobj=open(pk.with_suffix(".gz"), "wb"),
                       mtime=0, compresslevel=9) as gz:
        gz.write(pk.read_bytes())
    return root


def _release(mirror: Path, sde: int | None) -> Path:
    env = dict(os.environ, LC_ALL="C")
    env.pop("SOURCE_DATE_EPOCH", None)
    if sde is not None:
        env["SOURCE_DATE_EPOCH"] = str(sde)
    subprocess.run(
        ["bash", "-c", '. "$1" && ncz_apt_release "$2" forky amd64 NCZ-OS NCZ-OS-forky',
         "_", str(RELEASE_LIB), str(mirror)],
        check=True, env=env)
    return mirror / "dists" / "forky" / "Release"


# --- asset bundle ---------------------------------------------------------

def test_asset_bundle_and_sidecar_identical_across_two_clean_trees(writer, tmp_path):
    a = _asset_tree(tmp_path / "a", mtime=1_000_000_000, reverse=False, xattr=False)
    b = _asset_tree(tmp_path / "b", mtime=1_700_000_000, reverse=True, xattr=True)
    entries = [f"assets/{n}" for n in writer.SERVER_ONLINE_ASSET_DIRS]
    ba = tmp_path / "wa" / "ncz-assets-amd64.tar.gz"
    bb = tmp_path / "wb" / "ncz-assets-amd64.tar.gz"
    writer.make_targz(a, entries, ba)
    writer.make_targz(b, entries, bb)
    assert ba.read_bytes() == bb.read_bytes(), "asset bundle bytes depend on build history"
    # the writer exports what the medium pins, with a sha256 sidecar
    ea = writer.export_assets_bundle(ba, tmp_path / "pay-a", _sha(ba))
    eb = writer.export_assets_bundle(bb, tmp_path / "pay-b", _sha(bb))
    assert ea.read_bytes() == eb.read_bytes()
    sa = (tmp_path / "pay-a" / "ncz-assets-amd64.tar.gz.sha256").read_bytes()
    sb = (tmp_path / "pay-b" / "ncz-assets-amd64.tar.gz.sha256").read_bytes()
    assert sa == sb == f"{_sha(ba)}  ncz-assets-amd64.tar.gz\n".encode()


def test_asset_bundle_members_are_normalised(writer, tmp_path):
    a = _asset_tree(tmp_path / "a", mtime=1_234_567_890, reverse=True, xattr=True)
    out = tmp_path / "ncz-assets-amd64.tar.gz"
    writer.make_targz(a, [f"assets/{n}" for n in writer.SERVER_ONLINE_ASSET_DIRS], out)
    raw = out.read_bytes()
    assert raw[4:8] == b"\x00\x00\x00\x00", "gzip header mtime is not pinned to 0"
    assert raw[3] & 0x08 == 0, "gzip header carries a file name (FNAME set)"
    with tarfile.open(out) as t:
        members = t.getmembers()
    names = [m.name for m in members]
    assert names[0] == "assets/branding", names[:3]
    assert all(m.mtime == 0 and m.uid == 0 and m.gid == 0 and m.uname == "" and m.gname == ""
               for m in members)
    assert not any(m.pax_headers for m in members), "a member carries PAX records (xattrs/times)"


def test_asset_bundle_changes_when_content_changes(writer, tmp_path):
    """Negative control: the test above must not pass for every input."""
    a = _asset_tree(tmp_path / "a", mtime=1_000_000_000, reverse=False, xattr=False)
    b = _asset_tree(tmp_path / "b", mtime=1_000_000_000, reverse=False, xattr=False)
    (b / "assets/kernel/KVER").write_bytes(b"7.3.4-t2-ncz\n")
    entries = [f"assets/{n}" for n in writer.SERVER_ONLINE_ASSET_DIRS]
    writer.make_targz(a, entries, tmp_path / "a.tar.gz")
    writer.make_targz(b, entries, tmp_path / "b.tar.gz")
    assert _sha(tmp_path / "a.tar.gz") != _sha(tmp_path / "b.tar.gz")


# --- offline pool (option B) ----------------------------------------------

needs_ftparchive = pytest.mark.skipif(shutil.which("apt-ftparchive") is None,
                                      reason="apt-ftparchive not installed")


@needs_ftparchive
def test_mirror_release_date_comes_from_source_date_epoch(tmp_path):
    m = _mirror_tree(tmp_path / "m", mtime=1_000_000_000, reverse=False)
    rel = _release(m, SDE).read_text()
    assert "Date: Wed, 07 Oct 2026 20:24:37 +0000" in rel, rel.splitlines()[:8]


@needs_ftparchive
def test_mirror_release_does_not_list_itself(tmp_path):
    m = _mirror_tree(tmp_path / "m", mtime=1_000_000_000, reverse=False)
    (m / "dists/forky/Release").write_text("stale Release from an earlier run\n")
    rel = _release(m, SDE).read_text()
    listed = [ln.split()[-1] for ln in rel.splitlines() if ln.startswith(" ")]
    assert "Release" not in listed, listed
    assert "main/binary-amd64/Packages" in listed
    assert not list(m.glob(".Release.*")), "the helper left its temp file in the mirror"


@needs_ftparchive
def test_mirror_release_without_epoch_is_wall_clock(tmp_path):
    """Negative control: the Date really is what SOURCE_DATE_EPOCH drives."""
    m = _mirror_tree(tmp_path / "m", mtime=1_000_000_000, reverse=False)
    rel = _release(m, None).read_text()
    assert "07 Oct 2026 20:24:37" not in rel
    assert "Date: " in rel


@needs_ftparchive
def test_pool_tarball_and_sidecar_identical_across_two_clean_mirrors(writer, tmp_path):
    ma = _mirror_tree(tmp_path / "ma", mtime=1_000_000_000, reverse=False)
    _release(ma, SDE)
    time.sleep(1.1)  # a later wall clock, as for a second build
    mb = _mirror_tree(tmp_path / "mb", mtime=1_700_000_000, reverse=True)
    _release(mb, SDE)
    pa, pb = tmp_path / "wa" / "ncz-pool-amd64.tar.gz", tmp_path / "wb" / "ncz-pool-amd64.tar.gz"
    for mirror, out in ((ma, pa), (mb, pb)):
        # exactly the writer's call for option B
        writer.make_targz(mirror, ["dists", "pool"], out,
                          arc_prefix=writer.SERVER_POOL_REPO_DIR + "/", compresslevel=1)
    assert pa.read_bytes() == pb.read_bytes(), "pool tarball bytes depend on build history"
    writer.export_assets_bundle(pa, tmp_path / "pay-a", _sha(pa), what="offline apt pool")
    writer.export_assets_bundle(pb, tmp_path / "pay-b", _sha(pb), what="offline apt pool")
    for name in ("ncz-pool-amd64.tar.gz", "ncz-pool-amd64.tar.gz.sha256"):
        assert (tmp_path / "pay-a" / name).read_bytes() == (tmp_path / "pay-b" / name).read_bytes(), name


def test_forky_mirror_uses_the_reproducible_release_helper():
    """The mirror the pool tarball packs must be written by the helper above,
    not by an inline apt-ftparchive redirect into dists/<suite>/Release."""
    text = FORKY_MIRROR.read_text()
    assert "build/lib/apt-release.sh" in text
    assert "ncz_apt_release " in text
    assert 'release "dists/$SUITE" > "dists/$SUITE/Release"' not in text
