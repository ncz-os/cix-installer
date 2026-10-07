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
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
SCRIPT = REPO / "build" / "iso" / "patch-initrd-firmware.py"
TOOLS = all(shutil.which(t) for t in ("cpio", "zcat", "tar", "find"))


@unittest.skipUnless(TOOLS, "cpio/zcat/tar/find not available")
class PatchInitrdFirmware(unittest.TestCase):
    def test_injects_brcmfmac_blobs_into_a_fixture_initrd(self):
        with tempfile.TemporaryDirectory(
            prefix="initrd-fw-", dir=os.environ.get("TMPDIR")
        ) as td:
            t = Path(td)
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
            (node / "extract" / "d-i" / "initrd.gz").write_bytes(gzip.compress(cpio))

            fw = t / "fw"
            fw.mkdir()
            (fw / "brcmfmac4364b3-pcie.bin").write_bytes(b"blob")
            fw_tar = t / "fw.tar.xz"
            with tarfile.open(fw_tar, "w:xz") as tf:
                tf.add(
                    fw / "brcmfmac4364b3-pcie.bin", arcname="brcmfmac4364b3-pcie.bin"
                )

            stub = t / "bin"
            stub.mkdir()
            (stub / "sudo").write_text('#!/bin/sh\nexec "$@"\n')
            (stub / "sudo").chmod(0o755)
            env = dict(os.environ, PATH=f"{stub}:{os.environ.get('PATH', '')}")

            r = subprocess.run(
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
                    str(t / "cache"),
                ],
                env=env,
                capture_output=True,
                text=True,
                check=False,
            )
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


if __name__ == "__main__":
    unittest.main()
