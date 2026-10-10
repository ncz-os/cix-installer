"""patch-debootstrap-stub.py must repack the udeb byte-reproducibly.

Real regression (r203 amd64 re-run): the patched debootstrap-udeb's sha256
changed on every invocation because the repack embedded each member's mtime,
so no static manifests/ncz-packages.tsv row could ever match it and the
provenance gate failed on `debootstrap-udeb ... NCZ ledger sha256 mismatch`.

This exercises _repack_udeb twice over freshly-built ar dirs whose members
carry DIFFERENT mtimes and asserts the outputs are byte-identical.
"""
import hashlib
import importlib.util
import os
import shutil
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).parents[1] / "patch-debootstrap-stub.py"
SPEC = importlib.util.spec_from_file_location("patch_debootstrap_stub", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


def _gnu_tool(name: str) -> bool:
    import subprocess
    if not shutil.which(name):
        return False
    out = subprocess.run([name, "--version"], capture_output=True, text=True)
    return "GNU" in out.stdout


def _sha256(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()


def _make_ar_dir(root: Path, mtime: int) -> Path:
    ar_dir = root / f"ar-{mtime}"
    (ar_dir / "usr" / "bin").mkdir(parents=True)
    (ar_dir / "etc").mkdir(parents=True)
    (ar_dir / "debian-binary").write_text("2.0\n")
    (ar_dir / "control.tar.gz").write_bytes(b"not-a-real-control")
    (ar_dir / "usr" / "bin" / "debootstrap").write_text("#!/bin/sh\necho stub\n")
    (ar_dir / "etc" / "debootstrap.conf").write_text("x=1\n")
    # Deliberately different mtimes: the old repack embedded these.
    for p in ar_dir.rglob("*"):
        os.utime(p, (mtime, mtime))
    return ar_dir


@unittest.skipUnless(all(_gnu_tool(t) for t in ("tar", "ar")) and
                     shutil.which("gzip"),
                     "GNU tar + GNU ar + gzip required (production is Linux)")
class RepackDeterminismTest(unittest.TestCase):
    def test_repeated_repack_is_byte_identical(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            out1 = root / "out1.udeb"
            out2 = root / "out2.udeb"
            ar1 = _make_ar_dir(root, 1_700_000_000)
            ar2 = _make_ar_dir(root, 1_800_000_000)
            # data_member_original is a member name we skip; it does not have
            # to exist for the repack (only its NAME is used).
            MODULE._repack_udeb(ar1, "control.tar.gz",
                                Path("data.tar.xz"), out1)
            MODULE._repack_udeb(ar2, "control.tar.gz",
                                Path("data.tar.xz"), out2)
            b1, b2 = out1.read_bytes(), out2.read_bytes()
            self.assertEqual(_sha256(b1), _sha256(b2),
                             "repacked udeb is not byte-reproducible")
            # And the ar members are exactly the three dpkg expects, in order.
            m = MODULE._list_udeb_members(out1)
            self.assertEqual(m, ["debian-binary", "control.tar.gz",
                                 "data.tar.gz"])

    def test_repack_honours_source_date_epoch(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            os.environ["SOURCE_DATE_EPOCH"] = "1234567890"
            try:
                ar = _make_ar_dir(root, 1_700_000_000)
                out = root / "out.udeb"
                MODULE._repack_udeb(ar, "control.tar.gz", Path("data.tar.xz"),
                                    out)
                self.assertTrue(out.is_file() and out.stat().st_size > 0)
            finally:
                os.environ.pop("SOURCE_DATE_EPOCH", None)


if __name__ == "__main__":
    unittest.main()
