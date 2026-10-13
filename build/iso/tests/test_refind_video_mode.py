"""Installer rEFInd video mode: amd64 programs the firmware's largest GOP mode, arm64 untouched.

2026-10-11: the HP OmniDesk test desktop (Arrow Lake i915, ViewSonic VP2488-4K, HDMI) d-i
video defect reappeared at the FIRMWARE/rEFInd level -- rEFInd and d-i both
painted only the left third of the panel. Root cause: the installer ESP used
`textonly`, so rEFInd never called GOP SetMode and the kernel's efifb inherited
whatever mode the firmware happened to leave programmed (a value that varies
boot to boot). Fix: the amd64 installer ESP drops `textonly`, ships icons/ (or
rEFInd silently forces text mode anyway -- "Icons directory doesn't exist;
setting textonly = TRUE!"), and programs a GOP mode before the kernel.

2026-10-12: that first fix pinned `resolution 1920 1080`, which on a single-mode
T2 Mac GOP (one mode: 3584x2240) makes rEFInd print
"Error setting graphics mode 1920 x 1080; using default mode!" and call
`PauseForKey()` -- a mandatory key press that breaks unattended installs.
`PauseForKey()` is unconditional in `libeg/screen.c egSetScreenSize()`, so the
fix is to stop asking for a mode that may not exist: `resolution max` makes
rEFInd QueryMode() the firmware GOP and SetMode() the largest mode it reports,
which is guaranteed to exist and can never hit the error/pause branch. It still
programs a real GOP mode, so the d-i framebuffer stays stride-consistent (the
HP OmniDesk left-third fix). The old second "safe video mode" config is gone: any
`resolution W H` pair reintroduces the defect.

This builds the real ESP tree with build_esp_dir() for both arches (fake rEFInd
binary, fake d-i payload) and reads what it writes. It does NOT need the real
kernel/initrd, mtools, or a boot.
"""

import importlib.util
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

# A fixed "resolution <width> <height>" pair: rEFInd reads it as a specific
# mode and, if the firmware GOP does not offer exactly that mode, prints the
# error screen and pauses. The installer config must never contain one.
FIXED_RESOLUTION_PAIR = re.compile(r"(?m)^resolution\s+\d+\s+\d+\s*$")


def _fake_refind(root: Path) -> Path:
    """A refind_src with the two EFI binaries and an icons/ tree."""
    refind = root / "refind"
    (refind / "icons").mkdir(parents=True)
    (refind / "refind_x64.efi").write_bytes(b"x64")
    (refind / "refind_aa64.efi").write_bytes(b"aa64")
    for name in ("boot_linux.png", "os_ncz.png", "transparent.png"):
        (refind / "icons" / name).write_bytes(b"\x89PNG" + name.encode())
    return refind


def build_tree(arch: str) -> dict:
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        refind = _fake_refind(root)
        kernel = root / "linux"
        initrd = root / "initrd.gz"
        kernel.write_bytes(b"k")
        initrd.write_bytes(b"i")
        esp = root / "esp"
        info = MODULE.build_esp_dir(esp, refind, arch, kernel, initrd, "info")
        return {
            "boot_conf": (esp / "EFI" / "BOOT" / "refind.conf").read_text(),
            "installed_conf": (esp / "EFI" / "REFIND" / "REFIND.CONF").read_text(),
            "icons_boot": sorted(p.name for p in (esp / "EFI" / "BOOT" / "icons").glob("*.png"))
            if (esp / "EFI" / "BOOT" / "icons").is_dir() else [],
            "icons_refind": sorted(p.name for p in (esp / "EFI" / "REFIND" / "icons").glob("*.png"))
            if (esp / "EFI" / "REFIND" / "icons").is_dir() else [],
            "inventory": info["inventory"],
        }


def direct_lines(conf: str, token: str) -> list:
    return re.findall(rf"(?m)^{re.escape(token)}\b.*$", conf)


def menuentries(conf: str) -> dict:
    out = {}
    for m in re.finditer(r'menuentry "([^"]+)" \{(.*?)\n\}', conf, re.DOTALL):
        out[m.group(1)] = m.group(2)
    return out


def options_of(body: str) -> str:
    opt = re.search(r'options "([^"]*)"', body)
    return opt.group(1) if opt else ""


class Amd64GraphicsMode(unittest.TestCase):
    def setUp(self):
        self.t = build_tree("amd64")
        self.conf = self.t["boot_conf"]

    def test_no_textonly_directive(self):
        # textonly would skip GOP SetMode; the fix depends on programming a mode.
        # (The word also appears in the explanatory comment, so assert on the
        # directive line, not the raw string.)
        self.assertEqual(direct_lines(self.conf, "textonly"), [])

    def test_resolution_is_max_never_a_fixed_pair(self):
        # `resolution max` picks a mode that is guaranteed to exist, so rEFInd's
        # egSetScreenSize() can never print the error screen and PauseForKey().
        self.assertEqual(direct_lines(self.conf, "resolution"), ["resolution max"])
        # A fixed "W H" pair is rejected by a single-mode GOP (T2 Mac) and pauses.
        self.assertIsNone(FIXED_RESOLUTION_PAIR.search(self.conf), self.conf)

    def test_no_generated_config_pins_a_fixed_resolution_pair(self):
        # Invariant across every generated config (both SelfDir copies): nothing
        # may contain `resolution <int> <int>`, which a single-mode GOP rejects.
        for name, conf in (
            ("boot", self.t["boot_conf"]),
            ("installed", self.t["installed_conf"]),
        ):
            self.assertIsNone(FIXED_RESOLUTION_PAIR.search(conf), f"{name}:\n{conf}")
            # The x-form is parsed by rEFInd as ONE option and silently ignored.
            self.assertNotRegex(conf, r"(?m)^resolution\s+\d+x\d+")

    def test_use_graphics_for_keeps_the_gop_mode_at_handoff(self):
        self.assertIn("use_graphics_for linux,grub", direct_lines(self.conf, "use_graphics_for"))

    def test_timeout_and_scanfor_kept(self):
        self.assertEqual(direct_lines(self.conf, "timeout"), ["timeout 3"])
        self.assertIn("scanfor manual", direct_lines(self.conf, "scanfor"))

    def test_install_entries_keep_nomodeset(self):
        # Policy (fix/di-lcd-display-20261010): Install/Expert run with
        # nomodeset; Rescue deliberately keeps full modeset for diagnosis.
        entries = menuentries(self.conf)
        for title in ("NCZ-OS Installer -- Install",
                      "NCZ-OS Installer -- Install (expert)"):
            self.assertIn(title, entries, entries.keys())
            opts = options_of(entries[title]).split()
            self.assertEqual(opts.count("nomodeset"), 1, f"{title}: {opts}")
        rescue = options_of(entries["NCZ-OS Installer -- Rescue mode"]).split()
        self.assertEqual(rescue.count("nomodeset"), 0, rescue)

    def test_no_safe_conf_and_no_refind_relaunch_entry(self):
        # The old `resolution 800 600` safe config was itself a fixed pair that a
        # single-mode GOP rejects, so it is gone: there is one robust installer
        # config and no rEFInd re-launch entry.
        inv = "\n".join(self.t["inventory"])
        self.assertNotIn("refind-safe.conf", inv)
        self.assertNotIn("REFIND-SAFE.CONF", inv)
        entries = menuentries(self.conf)
        for title, body in entries.items():
            self.assertNotIn("-c refind-safe.conf", options_of(body), title)
            self.assertNotIn("safe video", title)

    def test_icons_ship_next_to_both_binaries(self):
        self.assertIn("boot_linux.png", self.t["icons_boot"], self.t["icons_boot"])
        self.assertEqual(self.t["icons_boot"], self.t["icons_refind"])
        inv = "\n".join(self.t["inventory"])
        self.assertIn("EFI/BOOT/icons/boot_linux.png", inv)
        self.assertIn("EFI/REFIND/icons/boot_linux.png", inv)

    def test_two_conf_copies_identical(self):
        self.assertEqual(self.t["boot_conf"], self.t["installed_conf"])


class Arm64Unchanged(unittest.TestCase):
    def setUp(self):
        self.t = build_tree("arm64")
        self.conf = self.t["boot_conf"]

    def test_arm64_output_is_byte_identical_to_the_shared_text_template(self):
        expected = MODULE.REFIND_CONF_TEXT_TEMPLATE.format(
            info_line="info",
            install_options=MODULE.ARM64_INSTALL_OPTIONS,
            expert_options=MODULE.ARM64_EXPERT_OPTIONS,
            rescue_options=MODULE.ARM64_RESCUE_OPTIONS,
        )
        self.assertEqual(self.conf, expected)
        # and the arm64 template is still the shared alias
        self.assertIs(MODULE.REFIND_CONF_TEXT_ARM64_TEMPLATE, MODULE.REFIND_CONF_TEXT_TEMPLATE)

    def test_arm64_keeps_textonly_and_no_graphics_directives(self):
        self.assertIn("textonly", direct_lines(self.conf, "textonly"))
        self.assertEqual(direct_lines(self.conf, "resolution"), [])
        self.assertEqual(direct_lines(self.conf, "use_graphics_for"), [])

    def test_arm64_ships_no_icons_and_no_safe_conf(self):
        self.assertEqual(self.t["icons_boot"], [])
        self.assertEqual(self.t["icons_refind"], [])
        self.assertNotIn("icons/", "\n".join(self.t["inventory"]))
        self.assertNotIn("refind-safe.conf", "\n".join(self.t["inventory"]))


class RealAssetGuard(unittest.TestCase):
    def test_tracked_icons_tree_exists_for_real_builds(self):
        # build_esp_dir falls back to this tree when the .deb extract is absent;
        # without it the amd64 graphics config could never ship icons.
        self.assertTrue((REPO_ROOT / "assets" / "refind" / "icons" / "boot_linux.png").is_file())


if __name__ == "__main__":
    unittest.main()
