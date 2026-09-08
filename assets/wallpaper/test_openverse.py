"""Offline contract/security tests; real network checks are documented separately."""
import importlib.machinery
import json
import os
from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import patch
import urllib.error

ov = importlib.machinery.SourceFileLoader("openverse", str(Path(__file__).with_name("ncz-wallpaper-openverse"))).load_module()
ID = "c6a260ef-8a37-43df-939e-f3d662403fcc"


def image(identity=ID):
    return dict(id=identity, title="Transantarctic mountain hg", creator="Hannes Grobe, Alfred Wegener Institute",
                license="by-sa", license_version="2.5", license_url="https://creativecommons.org/licenses/by-sa/2.5/",
                attribution='"Transantarctic mountain hg" by Hannes Grobe, Alfred Wegener Institute is licensed under CC BY-SA 2.5.',
                foreign_landing_url="https://commons.wikimedia.org/w/index.php?curid=585111",
                thumbnail="https://api.openverse.org/v1/images/" + identity + "/thumb/",
                url="https://upload.wikimedia.org/wikipedia/commons/c/c1/Transantarctic_mountain_hg.jpg",
                tags=[], width=2563, height=1652, source="wikimedia")


class OpenverseTests(unittest.TestCase):
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

    def test_anonymous_no_registration(self):
        with patch.object(ov, "api", return_value={}) as api:
            ov.authenticated("images/?q=test")
            api.assert_called_once_with("images/?q=test", token=None)
        self.assertFalse(ov.credential_path().exists())

    def test_registration_immediately_persists_private_credentials(self):
        with patch.object(ov, "api", return_value={"client_id": "test-id", "client_secret": "test-secret"}) as api:
            result = ov.register("test@example.org")
            self.assertNotIn("test-secret", json.dumps(result))
            self.assertEqual(api.call_args.args[0], "auth_tokens/register/")
            self.assertEqual(api.call_args.args[1]["email"], "test@example.org")
            with self.assertRaises(ValueError):
                ov.register("test@example.org")
            self.assertEqual(api.call_count, 1)
        path = ov.credential_path()
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(path.parent.stat().st_mode & 0o777, 0o700)
        self.assertEqual(ov.read_json(path)["client_secret"], "test-secret")

    def test_token_expiry_and_reuse(self):
        ov.save_json(ov.credential_path(), {"client_id": "id", "client_secret": "secret"})
        with patch.object(ov, "api", return_value={"access_token": "first", "token_type": "Bearer", "expires_in": 36000}) as api:
            self.assertEqual(ov.token(), "first")
            self.assertEqual(ov.token(), "first")
            self.assertEqual(api.call_count, 1)
            self.assertEqual(api.call_args.args[1]["grant_type"], "client_credentials")
            ov.token(force=True)
            self.assertEqual(api.call_count, 2)
        record = ov.read_json(ov.credential_path())
        record["expires_at"] = time.time() - 1
        ov.save_json(ov.credential_path(), record)
        with patch.object(ov, "api", return_value={"access_token": "second", "token_type": "Bearer", "expires_in": 60}):
            self.assertEqual(ov.token(), "second")

    def test_401_renews_once(self):
        error = urllib.error.HTTPError(ov.BASE, 401, "Unauthorized", {}, None)
        with patch.object(ov, "token", side_effect=["expired", "new"]), patch.object(ov, "api", side_effect=[error, {}]) as api:
            ov.authenticated("images/")
            self.assertEqual(api.call_count, 2)
            self.assertEqual(api.call_args.kwargs["token"], "new")

    def test_search_cache_pagination_refresh_stale(self):
        response = dict(results=[image()], page_count=3)
        with patch.object(ov, "authenticated", return_value=response) as api:
            first = ov.search("mountains")
            self.assertFalse(first["cached"])
            self.assertIn("aspect_ratio=wide", api.call_args.args[0])
            self.assertIn("page_size=20", api.call_args.args[0])
            self.assertTrue(ov.search("mountains")["cached"])
            self.assertEqual(api.call_count, 1)
            ov.search("mountains", 2)
            ov.search("mountains", refresh=True)
            self.assertEqual(api.call_count, 3)
        with patch.object(ov, "authenticated", side_effect=OSError("offline")):
            self.assertTrue(ov.search("mountains", refresh=True)["stale"])
            with self.assertRaises(OSError):
                ov.search("uncached")

    def test_shape_and_license(self):
        result = ov.normalize(image())
        self.assertEqual(result["license"], "by-sa")
        self.assertEqual(result["license_version"], "2.5")
        self.assertEqual(result["attribution"], image()["attribution"])
        nullable = image()
        nullable.update(title=None, creator=None, tags=None, width=None, height=None)
        self.assertEqual(ov.normalize(nullable)["author"], "")
        for bad in (dict(image(), id="../escape"), dict(image(), license=123), dict(image(), width="4K")):
            with self.assertRaises(ValueError):
                ov.normalize(bad)

    def test_reject_local_media_and_redirect(self):
        for url in ("file:///etc/passwd", "http://127.0.0.1/a", "http://[::1]/a", "https://u:p@example.org/a"):
            with self.assertRaises(ValueError):
                ov.public_url(url)
        with self.assertRaises(ValueError):
            ov.NoRedirect().redirect_request(None, None, 302, "", {}, "https://example.org")

    def test_raw_bearer_scheme_and_form_request(self):
        class Response:
            def __enter__(self): return self
            def __exit__(self, *args): pass
            def read(self, size): return b'{}'
        with patch.object(ov.urllib.request, "build_opener") as build:
            build.return_value.open.return_value = Response()
            ov.api("auth_tokens/token/", {"client_secret": "test & secret"}, token="test-token")
            req = build.return_value.open.call_args.args[0]
            self.assertEqual(req.get_header("Authorization"), "Bearer test-token")
            self.assertEqual(req.get_header("Content-type"), "application/x-www-form-urlencoded")
            self.assertIn(b"test+%26+secret", req.data)

    def test_import_accumulation_original_bytes_and_no_auth_leak(self):
        payload = b"\xff\xd8\xff" + b"test-image"
        class Response:
            def __enter__(self): return self
            def __exit__(self, *args): pass
            def read(self, size): return payload
        with patch.object(ov, "authenticated", side_effect=lambda path: image(path.split('/')[1])), \
             patch.object(ov, "validate_raster"), \
             patch.object(ov, "public_url", side_effect=lambda url: url), \
             patch.object(ov.urllib.request, "build_opener") as build:
            build.return_value.open.return_value = Response()
            a = ov.import_image(ID)
            b = ov.import_image("834f0fb2-0c99-400c-8a53-0f1ea0b6ed70")
            self.assertEqual(a["collection"], b["collection"])
            self.assertIsNone(build.return_value.open.call_args.args[0].get_header("Authorization"))
        destination = Path(a["destination"])
        self.assertEqual(len(list(destination.glob("*.jpg"))), 2)
        self.assertEqual((destination / a["images"][0]["file"]).read_bytes(), payload)
        self.assertEqual(ov.read_json(destination / a["images"][0]["sidecar"])["license"], "by-sa")

    def test_invalid_raster_is_rejected(self):
        with patch.object(ov.subprocess, "run", side_effect=ov.subprocess.CalledProcessError(1, "identify")):
            with self.assertRaises(ValueError):
                ov.validate_raster(b"\xff\xd8\xffbroken", ".jpg")


if __name__ == "__main__":
    unittest.main()
