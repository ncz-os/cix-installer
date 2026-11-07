"""patch-initrd-firmware.py runs end to end on a fixture initrd.

The function-local `import os` made `os` local to patch_initrd(), so the
earlier `os.getpid()` (the .partial.<pid> build dir) raised UnboundLocalError
the first time build-installer-image.sh actually called the script (amd64
stage 2, 2026-10-06). sudo is replaced by a PATH stub that runs its
arguments unprivileged; the fixture initrd holds no device nodes.
"""

import gzip
import json
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
SCRIPT = REPO / "build" / "iso" / "patch-initrd-firmware.py"
TOOLS = all(shutil.which(t) for t in ("cpio", "zcat", "tar", "find"))


def _newc_members(data: bytes) -> dict:
    """name -> mtime for every member of a newc cpio stream."""
    out, i = {}, 0
    while i + 110 <= len(data) and data[i : i + 6] in (b"070701", b"070702"):
        f = [int(data[i + 6 + 8 * k : i + 14 + 8 * k], 16) for k in range(13)]
        nsize, fsize = f[11], f[6]
        name = data[i + 110 : i + 110 + nsize - 1].decode()
        body = (i + 110 + nsize + 3) & ~3
        i = (body + fsize + 3) & ~3
        if name == "TRAILER!!!":
            break
        out[name] = f[5]
    return out


def _fixture(t: Path) -> tuple[Path, Path, dict]:
    """A one-file d-i initrd, a one-blob firmware tarball and a sudo stub."""
    tree = t / "tree"
    (tree / "etc").mkdir(parents=True)
    (tree / "etc" / "marker").write_text("d-i\n")
    node = t / "substrate"
    (node / "extract" / "d-i").mkdir(parents=True)
    cpio = subprocess.run(
        "find . | cpio --quiet -o -H newc",
        shell=True,
        cwd=tree,
        check=True,
        capture_output=True,
    ).stdout
    (node / "extract" / "d-i" / "initrd.gz").write_bytes(
        gzip.compress(cpio, mtime=0)
    )

    fw = t / "fw"
    fw.mkdir()
    (fw / "brcmfmac4364b3-pcie.bin").write_bytes(b"blob")
    fw_tar = t / "fw.tar.xz"
    with tarfile.open(fw_tar, "w:xz") as tf:
        tf.add(fw / "brcmfmac4364b3-pcie.bin", arcname="brcmfmac4364b3-pcie.bin")

    stub = t / "bin"
    stub.mkdir()
    (stub / "sudo").write_text('#!/bin/sh\nexec "$@"\n')
    (stub / "sudo").chmod(0o755)
    env = dict(os.environ, PATH=f"{stub}:{os.environ.get('PATH', '')}")
    return node, fw_tar, env


def _run(node: Path, fw_tar: Path, cache: Path, env: dict):
    return subprocess.run(
        [
            sys.executable,
            str(SCRIPT),
            "--substrate-node-dir",
            str(node),
            "--arch",
            "amd64",
            "--firmware-tar",
            str(fw_tar),
            "--cache-root",
            str(cache),
        ],
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )


@unittest.skipUnless(TOOLS, "cpio/zcat/tar/find not available")
class PatchInitrdFirmware(unittest.TestCase):
    def test_injects_brcmfmac_blobs_into_a_fixture_initrd(self):
        with tempfile.TemporaryDirectory(
            prefix="initrd-fw-", dir=os.environ.get("TMPDIR")
        ) as td:
            t = Path(td)
            node, fw_tar, env = _fixture(t)
            r = _run(node, fw_tar, t / "cache", env)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            out = Path(r.stdout.strip())
            self.assertTrue(out.is_file(), out)
            self.assertTrue((out.parent / "receipt.json").is_file())
            listing = subprocess.run(
                ["cpio", "-t", "--quiet"],
                input=gzip.decompress(out.read_bytes()),
                capture_output=True,
                check=True,
            ).stdout.decode()
            self.assertIn("lib/firmware/brcm/brcmfmac4364b3-pcie.bin", listing)
            self.assertIn("etc/marker", listing)
            receipt = json.loads((out.parent / "receipt.json").read_text())
            self.assertEqual(receipt["inputs"]["firmware_files_injected"], 1)
            self.assertFalse(list(out.parent.parent.glob("*.partial.*")))

    def test_repack_is_byte_identical_across_runs(self):
        """Two runs of the same inputs under one SOURCE_DATE_EPOCH write the
        same initrd.gz. Measured 2026-11-07 (two amd64 builds of 342d44bc):
        the shipped installer initrd differed only in extraction-time
        directory mtimes and cpio inode numbers; the gzip header carried the
        wall clock too. The runs are a second apart so every one of those
        would show up here."""
        with tempfile.TemporaryDirectory(
            prefix="initrd-fw-", dir=os.environ.get("TMPDIR")
        ) as td:
            t = Path(td)
            node, fw_tar, env = _fixture(t)
            env["SOURCE_DATE_EPOCH"] = "1700000000"
            outs = []
            for i in range(2):
                if i:
                    time.sleep(1.2)
                r = _run(node, fw_tar, t / f"cache{i}", env)
                self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
                outs.append(Path(r.stdout.strip()).read_bytes())
            self.assertEqual(outs[0], outs[1], "repacked initrd.gz differs")
            members = _newc_members(gzip.decompress(outs[0]))
            self.assertIn("lib/firmware/brcm/brcmfmac4364b3-pcie.bin", members)
            late = {n: m for n, m in members.items() if m > 1700000000}
            self.assertEqual(late, {}, "members newer than SOURCE_DATE_EPOCH")


if __name__ == "__main__":
    unittest.main()
