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


if __name__ == "__main__":
    unittest.main()
