#!/usr/bin/python3
"""Tests for the apt output parser using a fake apt executable."""

import json
import os
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
CHECKER = ROOT / "assets/update-manager/ncz-update-check"


class UpdateCheckTest(unittest.TestCase):
    def test_parses_and_prioritizes_desktop(self):
        with tempfile.TemporaryDirectory(dir=os.path.expanduser("~/build-tmp")) as temp:
            fake = pathlib.Path(temp) / "apt"
            fake.write_text("""#!/bin/sh
cat <<'EOF'
Listing...
linux-image/forky 6.1 arm64 [upgradable from: 6.0]
ncz-singularity-desktop/any 2.0 arm64 [upgradable from: 1.9]
EOF
""")
            fake.chmod(0o755)
            # The production checker pins PATH. Substitute its apt executable
            # in-memory so this test never touches or mutates system APT state.
            # apt-cache policy (origin lookup, 3da1f0c3) gets a silent stub.
            fake_cache = pathlib.Path(temp) / "apt-cache"
            fake_cache.write_text("#!/bin/sh\nexit 0\n")
            fake_cache.chmod(0o755)
            source = CHECKER.read_text()
            for old, new in (
                ('run_apt("apt", "list"', f'run_apt("{fake}", "list"'),
                ('run_apt("apt-cache"', f'run_apt("{fake_cache}"'),
            ):
                self.assertIn(old, source)
                source = source.replace(old, new)
            result = subprocess.run(
                ["python3", "-c", source], text=True, capture_output=True, check=True
            )
        payload = json.loads(result.stdout)
        self.assertEqual(payload["count"], 2)
        self.assertTrue(payload["desktop_update"])
        self.assertEqual(payload["updates"][0]["package"], "ncz-singularity-desktop")


if __name__ == "__main__":
    pathlib.Path(os.path.expanduser("~/build-tmp")).mkdir(parents=True, exist_ok=True)
    unittest.main()
