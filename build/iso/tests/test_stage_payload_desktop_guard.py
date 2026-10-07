"""stage-ncz-payload.py refuses a desktop-hotfix layer without its desktop layer.

ncz-os-amd64-20261006-25c30d6d was assembled with desktop-hotfix.squashfs
(rebuilt by `make image`) but without desktop.squashfs (a stage-1 artifact
`make image` never builds). Real tiny squashfs files are built with
mksquashfs; the test skips when squashfs-tools is absent.
"""

import importlib.util
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
SCRIPT = REPO / "build" / "iso" / "stage-ncz-payload.py"
SPEC = importlib.util.spec_from_file_location("stage_ncz_payload", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)

HAVE_SQUASHFS = (
    shutil.which("mksquashfs") is not None and shutil.which("unsquashfs") is not None
)


def make_squashfs(src_root: Path, out: Path) -> None:
    tree = src_root / (out.name + ".tree")
    (tree / "etc").mkdir(parents=True)
    (tree / "etc" / "marker").write_text(out.name + "\n")
    os.chmod(tree, 0o755)
    subprocess.run(
        ["mksquashfs", str(tree), str(out), "-noappend", "-quiet", "-all-root"],
        check=True,
        capture_output=True,
    )


@unittest.skipUnless(HAVE_SQUASHFS, "squashfs-tools not installed")
class HotfixNeedsDesktop(unittest.TestCase):
    def setUp(self):
        self._td = tempfile.TemporaryDirectory(
            prefix="stage-payload-", dir=os.environ.get("TMPDIR")
        )
        self.t = Path(self._td.name)
        self.sq = self.t / "squashfs"
        self.sq.mkdir()
        make_squashfs(self.t, self.sq / "base.squashfs")

    def tearDown(self):
        self._td.cleanup()

    def stage(self):
        return MODULE.stage_payload("amd64", self.sq, self.t / "cache", force=True)

    def test_hotfix_without_desktop_is_fatal(self):
        make_squashfs(self.t, self.sq / "desktop-hotfix.squashfs")
        with self.assertRaises(RuntimeError) as cm:
            self.stage()
        msg = str(cm.exception)
        self.assertIn("desktop-hotfix.squashfs is staged", msg)
        self.assertIn("build-squashfs-layers.sh desktop", msg)

    def test_base_only_without_hotfix_passes_this_guard(self):
        try:
            self.stage()
        except RuntimeError as exc:  # later, unrelated staging steps may refuse
            self.assertNotIn("desktop-hotfix.squashfs is staged", str(exc))


if __name__ == "__main__":
    unittest.main()
