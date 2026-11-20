"""SOURCE_DATE_EPOCH resolution for the installer-initrd packer.

The overlay pack clamps member mtimes to SOURCE_DATE_EPOCH. When the variable
is missing the clamp used to silently no-op, and two builds of one commit
shipped /preseed.cfg and /ncz/RELEASE with build-wall-clock mtimes (measured
2026-11-09 on the arm64 desktop A/B compare: the only bytes differing between
the images were those two members' cpio mtime fields, plus the ESP file-size
field that follows from the gzip delta).

Contract now: the environment wins; otherwise the determinism contract's own
derivation resolves it (build/lib/reproducible.py sde: git commit time, else
the pin's snapshot_epoch); only when that is gone too does the caller see
None -- and the packer refuses to pack without it.
"""

import importlib.util
import os
import subprocess
import unittest
from pathlib import Path
from unittest import mock

SCRIPT = Path(__file__).parents[1] / "patch-initrd-t2-kernel.py"
SPEC = importlib.util.spec_from_file_location("patch_initrd_t2_kernel", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)

REPO = Path(__file__).resolve().parents[3]


def _contract_sde() -> int:
    out = subprocess.run(
        ["python3", "-I", str(REPO / "build/lib/reproducible.py"), "sde",
         "--pin", str(REPO / "manifests/base.pin"), "--repo", str(REPO)],
        capture_output=True, text=True, check=True)
    return int(out.stdout.strip())


class TestSourceDateEpoch(unittest.TestCase):
    def test_env_wins(self):
        with mock.patch.dict(os.environ, {"SOURCE_DATE_EPOCH": "1794190634"}):
            self.assertEqual(MODULE.source_date_epoch(), 1794190634)

    def test_env_missing_resolves_from_the_pin(self):
        env = {k: v for k, v in os.environ.items() if k != "SOURCE_DATE_EPOCH"}
        with mock.patch.dict(os.environ, env, clear=True):
            got = MODULE.source_date_epoch()
        self.assertIsNotNone(
            got, "unset SOURCE_DATE_EPOCH must resolve from the determinism "
                 "contract, not silently skip the mtime clamp")
        self.assertEqual(got, _contract_sde())

    def test_env_garbage_resolves_from_the_pin(self):
        with mock.patch.dict(os.environ, {"SOURCE_DATE_EPOCH": "not-a-number"}):
            self.assertIsNotNone(MODULE.source_date_epoch())

    def test_pack_refuses_without_any_epoch(self):
        # fail closed: a pack with no resolvable epoch must never write bytes
        import gzip
        import tempfile
        with tempfile.TemporaryDirectory() as td:
            tdp = Path(td)
            root = tdp / "ov"
            root.mkdir()
            (root / "f").write_text("x")
            fl = tdp / "filelist"
            fl.write_text("f\n")
            with mock.patch.object(MODULE, "source_date_epoch", lambda: None):
                with self.assertRaises(Exception):
                    MODULE.pack_overlay_cpio_gz(root, fl, tdp / "out.gz", None)
            self.assertFalse((tdp / "out.gz").exists())


if __name__ == "__main__":
    unittest.main()
