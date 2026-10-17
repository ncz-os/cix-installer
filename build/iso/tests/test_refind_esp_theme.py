"""Installer ESP: the Cygnus theme is staged only when NCZ_REFIND_THEME is on.

MINOR-004 (2026-10-17): assets/refind/cygnus/ was complete -- background,
selection art, theme.conf with the `banner_scale fillscreen` design and the
refind.conf.snippet include line -- but build/iso/build-refind-esp.py never
referenced it. The installer ESP therefore booted stock, unbranded rEFInd
while the INSTALLED system got the Cygnus theme from
assets/refind/ncz-refind-refresh*.sh. This test pins the wiring:

  * NCZ_REFIND_THEME defaults to ON for this release, so a plain build gets
    the theme: themes/cygnus/ is written into BOTH SelfDir candidates
    (EFI/BOOT/ -- the El Torito fallback launch -- and EFI/REFIND/ -- the
    installed path, exactly where icons/ and refind.conf go), and
    refind.conf gains the tracked snippet's `include themes/cygnus/theme.conf`
    line after the menu so the theme's banner directives win.

  * NCZ_REFIND_THEME=0 restores today's byte output: no themes/ tree at all
    and not a single `include` line, on both arches. That is asserted against
    the pre-change tree contents rather than just "no theme files", so a
    stray blank line or comment in the off path fails here.

  * Both arches, because they share this builder and the theme is not
    arch-specific: the amd64 ESP is the reported defect, the arm64 ESP had
    the same gap on the same rEFInd loading rules.

Everything runs build_esp_dir() against a fake rEFInd binary + fake d-i
payload, so it needs no real kernel, initrd, mtools or boot.
"""

import contextlib
import importlib.util
import os
import re
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).parents[1] / "build-refind-esp.py"
SPEC = importlib.util.spec_from_file_location("build_refind_esp", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)

REPO_ROOT = SCRIPT.parents[2]
THEME_DIR = REPO_ROOT / "assets" / "refind" / "cygnus"
INCLUDE_LINE = "include themes/cygnus/theme.conf"

# What the theme directory ships today; the ESP copy must be complete, not a
# subset that would leave rEFInd pointing `banner` at a missing file.
THEME_FILES = {
    "theme.conf",
    "background-1920x1080.png",
    "selection_big.png",
    "selection_small.png",
    "os_ncz.png",
    "refind.conf.snippet",
}

ARCHES = ("amd64", "arm64")


def _fake_refind(root: Path, arch: str) -> Path:
    refind = root / "refind"
    (refind / "icons").mkdir(parents=True)
    (refind / "refind_x64.efi").write_bytes(b"x64")
    (refind / "refind_aa64.efi").write_bytes(b"aa64")
    # rEFInd forces text mode without an icons/ tree; not the subject here,
    # but a realistic binary directory should have one.
    for name in ("boot_linux.png", "os_ncz.png"):
        (refind / "icons" / name).write_bytes(b"\x89PNG" + name.encode())
    return refind


def build(arch: str, theme) -> dict:
    """Build the ESP tree for `arch` with the given theme setting.

    `theme` is passed straight to build_esp_dir(), so `None` means "decide
    from NCZ_REFIND_THEME" and is what an unmodified build does.
    """
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        refind = _fake_refind(root, arch)
        kernel = root / "linux"
        initrd = root / "initrd.gz"
        kernel.write_bytes(b"k")
        initrd.write_bytes(b"i")
        esp = root / "esp"
        info = MODULE.build_esp_dir(esp, refind, arch, kernel, initrd, "info",
                                    theme=theme)
        files = {
            str(p.relative_to(esp)): p.read_bytes()
            for p in esp.rglob("*") if p.is_file()
        }
        return {
            "files": files,
            "inventory": info["inventory"],
            "boot_conf": (esp / "EFI" / "BOOT" / "refind.conf").read_text(),
            "installed_conf": (esp / "EFI" / "REFIND" / "REFIND.CONF").read_text(),
        }


@contextlib.contextmanager
def refind_theme_env(value):
    """Set (value=None deletes) NCZ_REFIND_THEME for the block."""
    old = os.environ.get("NCZ_REFIND_THEME")
    try:
        if value is None:
            os.environ.pop("NCZ_REFIND_THEME", None)
        else:
            os.environ["NCZ_REFIND_THEME"] = value
        yield
    finally:
        if old is None:
            os.environ.pop("NCZ_REFIND_THEME", None)
        else:
            os.environ["NCZ_REFIND_THEME"] = old


class ThemeEnabledByDefault(unittest.TestCase):
    def test_default_is_on(self):
        with refind_theme_env(None):
            self.assertTrue(MODULE.theme_enabled())

    def test_off_only_for_explicit_zero(self):
        # The documented off switch is "0"; anything else stays on so a
        # typo never silently downgrades the release's branding.
        with refind_theme_env("0"):
            self.assertFalse(MODULE.theme_enabled())
        for value in ("1", "", "yes", "false", "off"):
            with refind_theme_env(value):
                self.assertTrue(MODULE.theme_enabled(), repr(value))

    def test_environment_drives_the_build(self):
        with refind_theme_env(None):
            on = build("amd64", None)
        with refind_theme_env("0"):
            off = build("amd64", None)
        self.assertIn(INCLUDE_LINE, on["boot_conf"])
        self.assertNotIn(INCLUDE_LINE, off["boot_conf"])


class ThemeStagedOnBothArches(unittest.TestCase):
    def test_theme_files_land_in_both_selfdir_candidates(self):
        for arch in ARCHES:
            with self.subTest(arch=arch):
                t = build(arch, True)
                for base in ("EFI/BOOT", "EFI/REFIND"):
                    for name in THEME_FILES:
                        rel = f"{base}/themes/cygnus/{name}"
                        self.assertIn(rel, t["files"], t["inventory"])
                        # Byte-identical to the tracked asset: the approved
                        # 1080p background blob must not be re-encoded here.
                        self.assertEqual(
                            t["files"][rel],
                            (THEME_DIR / name).read_bytes(),
                            rel,
                        )

    def test_theme_tree_is_in_the_receipt_inventory(self):
        for arch in ARCHES:
            with self.subTest(arch=arch):
                t = build(arch, True)
                for rel in t["inventory"]:
                    if "themes/cygnus/" in rel:
                        self.assertTrue(rel.endswith(tuple(THEME_FILES)), rel)

    def test_include_line_is_present_in_both_configs(self):
        for arch in ARCHES:
            with self.subTest(arch=arch):
                t = build(arch, True)
                for name, conf in (("boot", t["boot_conf"]),
                                   ("installed", t["installed_conf"])):
                    lines = [ln.strip() for ln in conf.splitlines()]
                    self.assertIn(INCLUDE_LINE, lines, f"{arch} {name}")
                    # Appended LAST: rEFInd applies the theme's banner /
                    # banner_scale over anything generated above, so an
                    # include placed before the generated directives would
                    # be silently overridden and the theme inert.
                    self.assertEqual(lines[-1], INCLUDE_LINE, f"{arch} {name}")

    def test_snippet_is_reproduced_verbatim(self):
        snippet = (THEME_DIR / "refind.conf.snippet").read_text()
        for arch in ARCHES:
            with self.subTest(arch=arch):
                conf = build(arch, True)["boot_conf"]
                self.assertTrue(conf.endswith(snippet), repr(conf[-120:]))

    def test_icons_are_still_shipped_alongside_the_theme(self):
        # The theme does not replace icons/: rEFInd forces text mode without
        # an icons/ dir AND the theme's selection art is separate from the
        # per-loader icons. Staging one must not have displaced the other.
        t = build("amd64", True)
        self.assertIn("EFI/BOOT/icons/boot_linux.png", t["files"])


class ThemeDisabledRestoresPriorOutput(unittest.TestCase):
    def test_no_theme_files_when_disabled(self):
        for arch in ARCHES:
            with self.subTest(arch=arch):
                t = build(arch, False)
                themed = [p for p in t["files"] if "themes/" in p]
                self.assertEqual(themed, [], t["inventory"])

    def test_no_include_and_no_theme_directives_when_disabled(self):
        for arch in ARCHES:
            with self.subTest(arch=arch):
                t = build(arch, False)
                for conf in (t["boot_conf"], t["installed_conf"]):
                    # Directive lines only: the templates' explanatory
                    # comment prose uses the word "include".
                    directives = [ln.strip() for ln in conf.splitlines()
                                  if ln.strip() and not ln.lstrip().startswith("#")]
                    self.assertFalse(
                        [ln for ln in directives if ln.startswith("include")],
                        conf,
                    )
                    self.assertNotIn("themes/cygnus", conf)
                    # Turning the theme off must not change video policy either:
                    # amd64 keeps the graphics config (textonly would skip GOP
                    # SetMode and reintroduce the left-third bug), arm64 keeps
                    # its deliberate textonly (its d-i runs on the UART). Both
                    # are asserted so the off path cannot drift from today.
                    found = re.findall(r"(?m)^textonly\b.*$", conf)
                    if arch == "amd64":
                        self.assertEqual(found, [], conf)
                    else:
                        self.assertEqual(found, ["textonly"], conf)

    def test_disabled_config_ends_with_the_last_menuentry(self):
        # The off path must not grow a trailing blank line or comment where
        # the include block sits; that is what makes NCZ_REFIND_THEME=0 a
        # byte-for-byte reproduction of the pre-theme ESP.
        for arch in ARCHES:
            with self.subTest(arch=arch):
                t = build(arch, False)
                self.assertTrue(
                    t["boot_conf"].endswith('    disabled\n}\n'),
                    repr(t["boot_conf"][-80:]),
                )


class ThemeDesignPreserved(unittest.TestCase):
    def test_staged_theme_keeps_fillscreen_rationale(self):
        # MINOR-004 is explicit: the banner_scale fillscreen rationale must
        # survive the move into the ESP. Assert on the STAGED copy (what
        # rEFInd will actually read), not only the repo source.
        staged = build("amd64", True)["files"][
            "EFI/BOOT/themes/cygnus/theme.conf"
        ].decode()
        self.assertIn("banner_scale fillscreen", staged)
        self.assertIn("banner themes/cygnus/background-1920x1080.png", staged)
        self.assertIn("selection_big themes/cygnus/selection_big.png", staged)
        self.assertIn("selection_small themes/cygnus/selection_small.png", staged)
        # The rationale comment: one 1920x1080 source scaled to the exact GOP
        # mode. If someone "fixes" a crop by adding noscale or a pinned
        # resolution they have undone docs/REFIND-THEME.md's whole argument.
        self.assertIn("banner_scale fillscreen", staged)
        self.assertNotIn("banner_scale noscale", staged)
        self.assertNotRegex(staged, r"(?m)^resolution\s")
        self.assertIn("1920x1080", staged)

    def test_theme_does_not_pin_a_resolution_into_refind_conf(self):
        t = build("amd64", True)
        self.assertIsNone(
            re.search(r"(?m)^resolution\s+\d+\s+\d+\s*$", t["boot_conf"]),
            t["boot_conf"],
        )
        self.assertIn("resolution max", t["boot_conf"])


class ThemeFailClosed(unittest.TestCase):
    def test_missing_theme_dir_is_fatal_not_silent(self):
        # A build with the theme requested but no assets must fail loudly,
        # never ship an unbranded ESP while claiming the theme is on.
        real = MODULE.theme_source_dir
        MODULE.theme_source_dir = lambda: Path("/nonexistent/cygnus")
        try:
            with self.assertRaises(FileNotFoundError):
                build("amd64", True)
        finally:
            MODULE.theme_source_dir = real


if __name__ == "__main__":
    unittest.main()
