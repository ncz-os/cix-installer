"""Deterministic NCZ derivative debootstrap-udeb provenance tests.

The old producer repacked Debian's ``debootstrap-udeb`` keeping the upstream
``Package``/``Version`` (Debian identity) while replacing the code, so the
scanner saw a byte mismatch and the artifact had nondeterministic metadata.
These tests pin the new contract:

  * two builds of the same inputs are byte-identical (deterministic tar/gzip/ar);
  * the control carries the derivative version (base + ``+ncz1``), the
    authenticated base sha256 and the stub recipe sha256;
  * ``Package`` is preserved for d-i, ``Architecture`` stays ``all`` (no
    architecture-specific bytes in a common stub);
  * a non-``all`` base is refused.
"""

import gzip
import hashlib
import importlib.util
import os
import shutil
import subprocess
import tarfile
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
SCRIPT = REPO / "build" / "iso" / "patch-debootstrap-stub.py"
SPEC = importlib.util.spec_from_file_location("patch_debootstrap_stub", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)

HAVE_AR = shutil.which("ar") is not None
STUB = "#!/bin/sh\necho ncz-derivative-stub\n"


def _tar_gz(path, entries):
    with gzip.GzipFile(fileobj=open(path, "wb"), mode="wb", mtime=0) as gz:
        with tarfile.open(fileobj=gz, mode="w") as tf:
            for name, data in entries:
                ti = tarfile.TarInfo(name)
                ti.size = len(data)
                ti.mode = 0o644
                ti.mtime = 0
                tf.addfile(ti, __import__("io").BytesIO(data))


def _make_base_udeb(root, arch="all"):
    root.mkdir(parents=True, exist_ok=True)
    (root / "debian-binary").write_text("2.0\n")
    _tar_gz(root / "control.tar.gz", [(
        "control",
        (f"Package: debootstrap-udeb\nVersion: 1.0.145\nArchitecture: {arch}\n"
         "Maintainer: Debian Install System Team <debian-boot@lists.debian.org>\n"
         "Depends: libc6-udeb\n").encode())])
    _tar_gz(root / "data.tar.gz", [(
        "usr/sbin/debootstrap", b"#!/bin/sh\necho upstream-original\n")])
    base = root / "debootstrap-udeb_1.0.145_all.udeb"
    subprocess.run(["ar", "rc", str(base), "debian-binary",
                    "control.tar.gz", "data.tar.gz"],
                   cwd=root, check=True, capture_output=True)
    return base


@unittest.skipUnless(HAVE_AR, "ar (binutils) not installed")
class DerivativeUdebTest(unittest.TestCase):
    def setUp(self):
        self.td = tempfile.mkdtemp(prefix="udeb-derivative-")
        self.addCleanup(shutil.rmtree, self.td, ignore_errors=True)
        self.root = Path(self.td)
        self.base = _make_base_udeb(self.root)

    def _patch(self, out_name, stub=STUB):
        out = self.root / out_name
        return MODULE.patch_udeb(self.base, out, stub, force=True), out

    def test_reproducible_bytes(self):
        _, a = self._patch("a.udeb")
        _, b = self._patch("b.udeb")
        self.assertEqual(hashlib.sha256(a.read_bytes()).digest(),
                         hashlib.sha256(b.read_bytes()).digest())

    def test_control_derivative_identity(self):
        receipt, out = self._patch("c.udeb")
        ex = self.root / "ex"
        ex.mkdir()
        subprocess.run(["ar", "x", str(out)], cwd=ex, check=True)
        with tarfile.open(ex / "control.tar.gz", "r:gz") as tf:
            control = tf.extractfile("control").read().decode()
        self.assertIn("Package: debootstrap-udeb", control)
        self.assertIn("Version: 1.0.145+ncz1", control)
        self.assertIn("Architecture: all", control)
        base_sha = hashlib.sha256(self.base.read_bytes()).hexdigest()
        self.assertIn(f"NCZ-Base-SHA256: {base_sha}", control)
        self.assertIn("NCZ-Derivative-Of: debootstrap-udeb 1.0.145", control)
        recipe = hashlib.sha256(STUB.encode()).hexdigest()
        self.assertIn(f"NCZ-Recipe-SHA256: {recipe}", control)
        self.assertNotIn("Debian Install System Team", control)
        self.assertEqual(receipt["derivative_version"], "1.0.145+ncz1")
        self.assertEqual(receipt["base_sha256"], base_sha)
        self.assertEqual(receipt["recipe_sha256"], recipe)
        self.assertEqual(receipt["architecture"], "all")

    def test_stub_replaces_upstream_code(self):
        _, out = self._patch("d.udeb")
        ex = self.root / "exd"
        ex.mkdir()
        subprocess.run(["ar", "x", str(out)], cwd=ex, check=True)
        with tarfile.open(ex / "data.tar.gz", "r:gz") as tf:
            self.assertEqual(tf.extractfile("usr/sbin/debootstrap").read().decode(),
                             STUB)

    def test_non_all_architecture_refused(self):
        amd = _make_base_udeb(self.root / "amd", arch="amd64")
        out = self.root / "amd-out.udeb"
        with self.assertRaises(RuntimeError):
            MODULE.patch_udeb(amd, out, STUB, force=True)


if __name__ == "__main__":
    unittest.main()
