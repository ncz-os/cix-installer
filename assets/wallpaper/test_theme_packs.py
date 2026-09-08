"""Exercise provider accumulation without network or ImageMagick."""
import importlib.machinery
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ocs = importlib.machinery.SourceFileLoader(
    "ocs", str(Path(__file__).with_name("ncz-wallpaper-ocs"))).load_module()


class ThemePacks(unittest.TestCase):
    def test_catalog_cache_and_forced_refresh(self):
        with tempfile.TemporaryDirectory() as tmp, patch.dict(os.environ, {"XDG_CACHE_HOME": tmp, "NCZ_WALLPAPER_REFRESH": "0"}):
            with patch.object(ocs, "fetch_items", return_value=[{"id": "101"}]) as fetch:
                self.assertEqual(ocs.get_items("pling", "300"), [{"id": "101"}])
                ocs.get_items("pling", "300")
                self.assertEqual(fetch.call_count, 1)
                with patch.dict(os.environ, {"NCZ_WALLPAPER_REFRESH": "1"}):
                    ocs.get_items("pling", "300")
                self.assertEqual(fetch.call_count, 2)
            with patch.dict(os.environ, {"NCZ_WALLPAPER_REFRESH": "1"}), patch.object(ocs, "fetch_items", side_effect=SystemExit(1)):
                self.assertEqual(ocs.get_items("pling", "300"), [{"id": "101"}])
                self.assertTrue(ocs.STALE_CACHE)

    def test_accumulate_retry_and_isolate(self):
        def item(provider, identity):
            return dict(name="Same title", author="Uploader", tags=[],
                        detailpage="https://example.org", download=dict(
                            name="image.png", extension=".png", url="https://example.org/image",
                            size_kib=1))

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            with patch.dict(os.environ, {"XDG_DATA_HOME": str(root / "data")}), \
                 patch.object(ocs, "get_item", side_effect=item), \
                 patch.object(ocs, "fetch_bytes", return_value=(b"image", "https://example.org/image")), \
                 patch.object(ocs, "sniff_mime", return_value="image/png"), \
                 patch.object(ocs, "image_geometry", return_value=(3840, 2160)), \
                 patch.object(ocs, "normalize_image", side_effect=lambda src, dst, w, h: dst.write_bytes(b"jpeg")):
                a = ocs.import_item("pling", "101", 3840, 2160, root / "backgrounds")
                b = ocs.import_item("pling", "102", 3840, 2160, root / "backgrounds")
                retry = ocs.import_item("pling", "101", 3840, 2160, root / "backgrounds")
                c = ocs.import_item("kde-look", "101", 3840, 2160, root / "backgrounds")
            self.assertEqual(a["destination"], b["destination"])
            self.assertEqual(a, retry)
            self.assertEqual(a["destination"], c["destination"])
            self.assertEqual(len(list(Path(a["destination"]).glob("*.jpg"))), 3)
            self.assertEqual(len(list(Path(a["destination"]).glob("*.json"))), 3)
            self.assertEqual(len(list((root / "data/ncz-wallpapers/collections").glob("*.collection"))), 1)
            self.assertIn("PackKind=theme", Path(a["collection"]).read_text())


if __name__ == "__main__":
    unittest.main()
