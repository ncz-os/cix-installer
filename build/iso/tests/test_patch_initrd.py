import gzip
import importlib.util
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).parents[1] / "patch-initrd-t2-kernel.py"
SPEC = importlib.util.spec_from_file_location("patch_initrd_t2_kernel", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


class SingleMemberInitrdTest(unittest.TestCase):
    def test_combines_payloads_without_a_second_gzip_member(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            base = root / "base.gz"
            overlay = root / "overlay.gz"
            output = root / "initrd.gz"
            with gzip.open(base, "wb") as stream:
                stream.write(b"base-cpio")
            with gzip.open(overlay, "wb") as stream:
                stream.write(b"overlay-cpio")

            MODULE.write_single_member_initrd(base, overlay, output)

            self.assertEqual(gzip.decompress(output.read_bytes()),
                             b"base-cpiooverlay-cpio")
            # zlib's unused_data exposes another gzip header if a second
            # member was appended; the production regression was that layout.
            import zlib
            inflater = zlib.decompressobj(16 + zlib.MAX_WBITS)
            inflater.decompress(output.read_bytes())
            self.assertEqual(inflater.unused_data, b"")


class MissingFirmwarePatchTest(unittest.TestCase):
    def test_removes_timestamp_truncation_but_keeps_following_logic(self):
        source = """get_fresh_dmesg() {
\tdmesg > $dmesg_file
\t# Truncate if needed:
\tif [ -f $dmesg_ts ]; then
\t\tsed -i "1,$ln d" $dmesg_file
\telse
\t\tlog first
\tfi

\tif [ -s $dmesg_file ]; then
\t\tlog save
\tfi
}
"""
        patched = MODULE.patch_check_missing_firmware(source)
        self.assertNotIn('sed -i "1,$ln d"', patched)
        self.assertIn("looking at complete dmesg (NCZ firmware audit)", patched)
        self.assertIn("if [ -s $dmesg_file ]; then", patched)

    def test_fails_closed_if_upstream_shape_changes(self):
        with self.assertRaisesRegex(RuntimeError, "changed upstream"):
            MODULE.patch_check_missing_firmware("get_fresh_dmesg() { dmesg; }")


class NicFirmwareTest(unittest.TestCase):
    def test_stages_under_lib_firmware_rtl_nic(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            src = root / "rtl_nic"
            src.mkdir()
            (src / "rtl8125b-2.fw").write_bytes(b"fw-b2")
            (src / "rtl8127a-1.fw").write_bytes(b"fw-a1")
            (src / "README").write_text("not firmware")
            overlay = root / "overlay"
            overlay.mkdir()

            names = MODULE.stage_nic_firmware(src, overlay)

            self.assertEqual(names, ["rtl8125b-2.fw", "rtl8127a-1.fw"])
            dest = overlay / "lib" / "firmware" / "rtl_nic"
            self.assertEqual((dest / "rtl8125b-2.fw").read_bytes(), b"fw-b2")
            self.assertFalse((dest / "README").exists())
            # never a bare top-level lib entry beyond the firmware subtree
            self.assertEqual(sorted(p.name for p in (overlay / "lib").iterdir()),
                             ["firmware"])

    def test_fails_closed_on_empty_source(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            (root / "rtl_nic").mkdir()
            with self.assertRaisesRegex(RuntimeError, "no \\*.fw files"):
                MODULE.stage_nic_firmware(root / "rtl_nic", root / "overlay")

    def test_repo_ships_the_o6n_firmware(self):
        repo_fw = Path(__file__).parents[3] / "assets" / "firmware" / "rtl_nic"
        self.assertTrue((repo_fw / "rtl8125b-2.fw").is_file(),
                        "assets/firmware/rtl_nic/rtl8125b-2.fw is what the O6N RTL8125B requests")


if __name__ == "__main__":
    unittest.main()
