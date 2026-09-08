"""Offline contract/security tests; real network checks are documented separately."""
import importlib.machinery
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

us = importlib.machinery.SourceFileLoader("unsplash", str(Path(__file__).with_name("ncz-wallpaper-unsplash"))).load_module()
ID = "photo-abc_123"


def photo(identity=ID):
    return {"id": identity, "description": None, "alt_description": "snowy mountain", "width": 6000, "height": 4000,
            "user": {"name": "Ada Photographer", "links": {"html": "https://unsplash.com/@ada"}},
            "urls": {"raw": "https://images.unsplash.com/photo-1?ixid=test", "small": "https://images.unsplash.com/photo-1?w=400"},
            "links": {"html": "https://unsplash.com/photos/" + identity,
                      "download_location": "https://api.unsplash.com/photos/" + identity + "/download"},
            "tags": [{"title": "mountain"}]}


class UnsplashTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.env = patch.dict(os.environ, {"XDG_CONFIG_HOME": str(self.root / "config"),
                                          "XDG_DATA_HOME": str(self.root / "data"),
                                          "XDG_CACHE_HOME": str(self.root / "cache")})
        self.env.start()

    def tearDown(self):
        self.env.stop()
        self.tmp.cleanup()

    def test_configure_private_single_key_and_status_safe(self):
        result = us.configure("test-access-key\n")
        self.assertNotIn("test-access-key", json.dumps(result))
        path = us.credential_path()
        self.assertEqual(us.read_json(path), {"access_key": "test-access-key"})
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(path.parent.stat().st_mode & 0o777, 0o700)
        self.assertEqual(us.access_key(), "test-access-key")
        for bad in ("", "white space", "x" * 201):
            with self.assertRaises(ValueError): us.configure(bad)

    def test_client_id_header_and_no_redirect(self):
        us.configure("test-key")
        class Response:
            def __enter__(self): return self
            def __exit__(self, *args): pass
            def read(self, size): return b'{}'
        with patch.object(us.urllib.request, "build_opener") as build:
            build.return_value.open.return_value = Response()
            us.api("photos")
            req = build.return_value.open.call_args.args[0]
            self.assertEqual(req.get_header("Authorization"), "Client-ID test-key")
        with self.assertRaises(ValueError):
            us.NoRedirect().redirect_request(None, None, 302, "", {}, "https://example.org")

    def test_search_cache_pagination_refresh_stale(self):
        response = {"results": [photo()], "total_pages": 3}
        with patch.object(us, "api", return_value=response) as api:
            first = us.search("mountains")
            self.assertFalse(first["cached"])
            self.assertIn("orientation=landscape", api.call_args.args[0])
            self.assertIn("per_page=20", api.call_args.args[0])
            self.assertTrue(us.search("mountains")["cached"])
            self.assertEqual(api.call_count, 1)
            us.search("mountains", 2)
            us.search("mountains", refresh=True)
            self.assertEqual(api.call_count, 3)
        with patch.object(us, "api", side_effect=OSError("offline")):
            self.assertTrue(us.search("mountains", refresh=True)["stale"])
            with self.assertRaises(OSError): us.search("uncached")

    def test_normalized_attribution_resize_and_validation(self):
        item = us.normalize(photo())
        self.assertEqual(item["provider"], "unsplash")
        self.assertEqual(item["attribution"], "Photo by Ada Photographer on Unsplash")
        self.assertEqual(item["license"], "Unsplash License")
        self.assertIn("w=3840", item["url"])
        self.assertIn("h=2160", item["url"])
        self.assertIn("utm_source=singularity_wallpaper_browser", item["page_url"])
        self.assertIn("utm_medium=referral", item["creator_url"])
        self.assertIn("4K", item["tags"])
        for bad in (dict(photo(), id="../escape"), dict(photo(), width="6000"), dict(photo(), user={})):
            with self.assertRaises(ValueError): us.normalize(bad)

    def test_reject_local_media(self):
        for url in ("file:///etc/passwd", "http://127.0.0.1/a", "http://[::1]/a", "https://u:p@example.org/a"):
            with self.assertRaises(ValueError): us.public_url(url)

    def test_import_tracks_before_fetch_and_accumulates(self):
        payload = b"\xff\xd8\xfftest-image"
        calls = []
        def api(path):
            calls.append(path)
            return {"url": "https://images.unsplash.com/tracked"} if path.endswith("/download") else photo(path.split("/")[1])
        class Response:
            def __enter__(self): return self
            def __exit__(self, *args): pass
            def read(self, size): return payload
        with patch.object(us, "api", side_effect=api), patch.object(us, "validate_raster"), \
             patch.object(us, "public_url", side_effect=lambda url: url), patch.object(us.urllib.request, "build_opener") as build:
            build.return_value.open.return_value = Response()
            a = us.import_image(ID)
            b = us.import_image("second-photo")
        self.assertEqual(calls, ["photos/" + ID, "photos/" + ID + "/download", "photos/second-photo", "photos/second-photo/download"])
        self.assertEqual(a["collection"], b["collection"])
        destination = Path(a["destination"])
        self.assertEqual(len(list(destination.glob("*.jpg"))), 2)
        sidecar = us.read_json(destination / a["images"][0]["sidecar"])
        self.assertEqual(sidecar["provider"], "unsplash")
        self.assertEqual(sidecar["attribution"], "Photo by Ada Photographer on Unsplash")
        self.assertIsNone(build.return_value.open.call_args.args[0].get_header("Authorization"))

    def test_invalid_raster_is_rejected(self):
        with patch.object(us.subprocess, "run", side_effect=us.subprocess.CalledProcessError(1, "identify")):
            with self.assertRaises(ValueError): us.validate_raster(b"\xff\xd8\xffbroken", ".jpg")


if __name__ == "__main__":
    unittest.main()
