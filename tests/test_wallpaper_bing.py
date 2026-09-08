#!/usr/bin/env python3
"""Integration tests for the Bing helper embedded by post-install step 45."""

import json
import os
import re
import subprocess
import tempfile
import threading
import unittest
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
INSTALLER = ROOT / "post-install" / "45-wallpaper-rotator.sh"


def extract_helper(destination):
    source = INSTALLER.read_text()
    match = re.search(
        r"install -m 0755 /dev/stdin /usr/local/bin/ncz-wallpaper-bing <<'BING_EOF'\n"
        r"(.*?)\nBING_EOF",
        source,
        re.S,
    )
    if not match:
        raise AssertionError("embedded Bing helper not found")
    destination.write_text(match.group(1) + "\n")
    destination.chmod(0o755)


class FeedHandler(BaseHTTPRequestHandler):
    images = []
    feed_requests = 0

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path == "/HPImageArchive.aspx":
            type(self).feed_requests += 1
            payload = json.dumps({"images": type(self).images}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
        else:
            payload = b"fake-jpeg-payload"
            self.send_response(200)
            self.send_header("Content-Type", "image/jpeg")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, _format, *_args):
        pass


def item(date, image_id):
    return {
        "startdate": date,
        "enddate": date,
        "urlbase": "/th?id=" + image_id,
        "title": "Title " + image_id,
        "copyright": "Credit " + image_id,
        "copyrightlink": "https://example.test/credit",
        "hsh": "hash-" + image_id,
    }


class BingAccumulationTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        root = Path(self.temp.name)
        self.helper = root / "ncz-wallpaper-bing"
        extract_helper(self.helper)
        self.archive = root / "archive"
        self.feed_cache = root / "feed-cache"
        self.thumbs = root / "thumbs"
        FeedHandler.images = []
        FeedHandler.feed_requests = 0
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), FeedHandler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        origin = "http://127.0.0.1:" + str(self.server.server_port)
        self.env = os.environ | {
            "NCZ_BING_MARKETS": "en-US",
            "NCZ_BING_DATA_ROOT": str(self.archive),
            "NCZ_BING_FEED_CACHE_ROOT": str(self.feed_cache),
            "NCZ_BING_THUMB_ROOT": str(self.thumbs),
            "NCZ_BING_API": origin + "/HPImageArchive.aspx",
            "NCZ_BING_ORIGIN": origin,
            "NCZ_BING_QUIET": "1",
        }

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.temp.cleanup()

    def run_helper(self, *args, env=None):
        return subprocess.run(
            [str(self.helper), *args], env=env or self.env,
            check=True, text=True, capture_output=True,
        )

    def test_fetches_accumulate_and_deduplicate_by_bing_identity(self):
        FeedHandler.images = [item("20260901", "OHR.One_EN-US1"), item("20260902", "OHR.Two_EN-US2")]
        self.run_helper("fetch")
        self.assertEqual(len(list(self.archive.glob("*/*.jpg"))), 2)

        # Force a new live-feed window. One item is old, one has the same Bing
        # id under a different date, and one is genuinely new.
        for cached in self.feed_cache.glob("*.json"):
            cached.unlink()
        FeedHandler.images = [
            item("20260902", "OHR.Two_EN-US2"),
            item("20260903", "OHR.One_EN-US1"),
            item("20260904", "OHR.Three_EN-US3"),
        ]
        self.run_helper("fetch")

        images = sorted(self.archive.glob("*/*.jpg"))
        self.assertEqual([path.stem for path in images], ["20260901", "20260902", "20260904"])
        metadata = [json.loads(path.with_suffix(".json").read_text()) for path in images]
        self.assertEqual({row["image_id"] for row in metadata}, {
            "OHR.One_EN-US1", "OHR.Two_EN-US2", "OHR.Three_EN-US3",
        })
        rows = json.loads(self.run_helper("list", "en-US").stdout)
        self.assertEqual(len(rows), 3)
        self.assertEqual(rows[0]["image_id"], "OHR.Three_EN-US3")

    def test_six_hour_feed_cache_is_separate_from_archive(self):
        FeedHandler.images = [item("20260901", "OHR.One_EN-US1")]
        self.run_helper("fetch")
        first_requests = FeedHandler.feed_requests
        self.run_helper("fetch")
        self.assertEqual(FeedHandler.feed_requests, first_requests)
        self.assertEqual(len(list(self.archive.glob("*/*.jpg"))), 1)


if __name__ == "__main__":
    unittest.main()
