#!/usr/bin/env python3
"""Exercise the installed rotator without touching the host desktop."""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class WallpaperOwnerTest(unittest.TestCase):
    def run_rotator(self, desktop):
        source = (ROOT / "post-install/45-wallpaper-rotator.sh").read_text()
        script = source.split("<<'ROT'\n", 1)[1].split("\nROT\n", 1)[0]
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            bindir = root / "bin"
            bindir.mkdir()
            image = root / "selected wallpaper.jpg"
            image.touch()
            log = root / "calls"
            for command in ("gsettings", "swaybg", "pkill"):
                stub = bindir / command
                stub.write_text(
                    '#!/bin/sh\nprintf "%s" "${0##*/}" >> "$TEST_LOG"\nfor arg do printf "|%s" "$arg" >> "$TEST_LOG"; done\nprintf "\\n" >> "$TEST_LOG"\n'
                )
                stub.chmod(0o755)
            (bindir / "systemctl").write_text("#!/bin/sh\nexit 0\n")
            (bindir / "systemctl").chmod(0o755)
            picker = bindir / "collections"
            picker.write_text('#!/bin/sh\nprintf "%s\\n" "$TEST_IMAGE"\n')
            picker.chmod(0o755)
            script = script.replace(
                "WP_DIR=/usr/share/backgrounds/ncz", 'WP_DIR="' + str(root) + '"'
            )
            script = script.replace(
                "/usr/local/bin/ncz-wallpaper-collections", str(picker)
            )
            script = script.replace(
                "SSD=/opt/singularity/share/glib-2.0/schemas", 'SSD="' + str(root) + '"'
            )
            env = dict(
                os.environ,
                PATH=str(bindir) + ":/usr/bin:/bin",
                HOME=str(root),
                XDG_CONFIG_HOME=str(root / "config"),
                XDG_RUNTIME_DIR=str(root),
                XDG_CURRENT_DESKTOP=desktop,
                DESKTOP_SESSION=desktop,
                WAYLAND_DISPLAY="wayland-test",
                TEST_LOG=str(log),
                TEST_IMAGE=str(image),
            )
            subprocess.run(
                ["/bin/sh", "-eu"],
                input=script + "\nwait\n",
                text=True,
                env=env,
                check=True,
                capture_output=True,
                timeout=10,
            )
            return log.read_text().splitlines(), "file://" + str(image)

    def test_singularity_uses_only_native_wallpaper(self):
        calls, uri = self.run_rotator("Singularity")
        self.assertEqual(
            calls, ["gsettings|set|dev.sinty.desktop|background-picture-uri|" + uri]
        )

    def test_gnome_settings_are_unchanged(self):
        calls, uri = self.run_rotator("GNOME")
        self.assertEqual(
            calls,
            [
                "gsettings|set|org.gnome.desktop.background|picture-uri|" + uri,
                "gsettings|set|org.gnome.desktop.background|picture-uri-dark|" + uri,
                "gsettings|set|org.gnome.desktop.background|picture-options|zoom",
            ],
        )


if __name__ == "__main__":
    unittest.main()
