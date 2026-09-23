"""Exercise the ISO gate at the mirror/staging boundary."""
import hashlib
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

GATE = Path(__file__).resolve().parents[1] / 'verify-iso-offline-pool.py'


class OfflinePoolTest(unittest.TestCase):
    def test_retained_missing_and_corrupt_archive(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = root / 'pool/main/repair.deb'
            archive.parent.mkdir(parents=True)
            data = b'package archive fixture'
            archive.write_bytes(data)
            entry = ('Package: repair\nVersion: 1\nArchitecture: arm64\n'
                     'Filename: pool/main/repair.deb\n'
                     f'Size: {len(data)}\nSHA256: {hashlib.sha256(data).hexdigest()}\n\n')
            source = root / 'source'
            staged = root / 'Packages'
            source.write_text(entry)
            staged.write_text(entry)
            command = [sys.executable, str(GATE), '--source-index', str(source),
                       '--staging', str(root), '--index', 'Packages']
            def run():
                return subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(run().returncode, 0)
            source.write_text(entry + entry.replace('Package: repair', 'Package: lost'))
            result = run()
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('ISO lost 1 resolved packages', result.stderr)
            source.write_text(entry)
            archive.write_bytes(b'corrupt archive')
            result = run()
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('does not match index', result.stderr)


if __name__ == '__main__':
    unittest.main()
