"""Installer rEFInd video mode: amd64 programs an explicit GOP mode, arm64 untouched.

2026-10-11: the PROTEUS (HP Arrow Lake i915, ViewSonic VP2488-4K, HDMI) d-i
video defect reappeared at the FIRMWARE/rEFInd level -- rEFInd and d-i both
painted only the left third of the panel. Root cause: the installer ESP used
`textonly`, so rEFInd never called GOP SetMode and the kernel's efifb inherited
whatever mode the firmware happened to leave programmed (a value that varies
boot to boot). Fix: the amd64 installer ESP drops `textonly`, ships icons/ (or
rEFInd silently forces text mode anyway -- "Icons directory doesn't exist;
setting textonly = TRUE!"), and programs an explicit lower-common-denominator
GOP mode with `resolution 1920 1080` + `use_graphics_for linux,grub`. A second
"safe video mode" entry re-launches rEFInd with refind-safe.conf (800x600),
because rEFInd has no per-menuentry resolution on UEFI PCs.

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
SAFE_TITLE = "NCZ-OS Installer -- Install - safe video mode (800x600)"
SAFE_OPTS = "-c refind-safe.conf"


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
            "safe": (esp / "EFI" / "BOOT" / "refind-safe.conf").read_text()
            if (esp / "EFI" / "BOOT" / "refind-safe.conf").is_file() else None,
            "safe_installed": (esp / "EFI" / "REFIND" / "REFIND-SAFE.CONF").read_text()
            if (esp / "EFI" / "REFIND" / "REFIND-SAFE.CONF").is_file() else None,
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

    def test_explicit_resolution_is_space_separated_1080p(self):
        lines = direct_lines(self.conf, "resolution")
        self.assertEqual(lines, ["resolution 1920 1080"], lines)
        # The x-form is parsed by rEFInd as ONE option and silently ignored.
        self.assertNotRegex(self.conf, r"(?m)^resolution\s+\d+x\d+")

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

    def test_safe_video_entry_relaunches_refind(self):
        entries = menuentries(self.conf)
        self.assertIn(SAFE_TITLE, entries)
        body = entries[SAFE_TITLE]
        self.assertIn("loader /EFI/BOOT/BOOTX64.EFI", body)
        self.assertEqual(options_of(body), SAFE_OPTS)

    def test_icons_ship_next_to_both_binaries(self):
        self.assertIn("boot_linux.png", self.t["icons_boot"], self.t["icons_boot"])
        self.assertEqual(self.t["icons_boot"], self.t["icons_refind"])
        inv = "\n".join(self.t["inventory"])
        self.assertIn("EFI/BOOT/icons/boot_linux.png", inv)
        self.assertIn("EFI/REFIND/icons/boot_linux.png", inv)

    def test_two_conf_copies_identical(self):
        self.assertEqual(self.t["boot_conf"], self.t["installed_conf"])

    def test_safe_conf_is_800x600_graphics_without_recursion(self):
        self.assertIsNotNone(self.t["safe"])
        self.assertEqual(self.t["safe"], self.t["safe_installed"])
        safe = self.t["safe"]
        self.assertEqual(direct_lines(safe, "textonly"), [])
        self.assertEqual(direct_lines(safe, "resolution"), ["resolution 800 600"])
        self.assertIn("use_graphics_for linux,grub", direct_lines(safe, "use_graphics_for"))
        # No safe entry in the safe config: that would recurse.
        self.assertNotIn(SAFE_TITLE, safe)
        entries = menuentries(safe)
        self.assertIn("NCZ-OS Installer -- Install", entries)
        self.assertEqual(options_of(entries["NCZ-OS Installer -- Install"]).split().count("nomodeset"), 1)


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
        self.assertIsNone(self.t["safe"])
        self.assertIsNone(self.t["safe_installed"])
        self.assertNotIn("icons/", "\n".join(self.t["inventory"]))
        self.assertNotIn("refind-safe.conf", "\n".join(self.t["inventory"]))


class RealAssetGuard(unittest.TestCase):
    def test_tracked_icons_tree_exists_for_real_builds(self):
        # build_esp_dir falls back to this tree when the .deb extract is absent;
        # without it the amd64 graphics config could never ship icons.
        self.assertTrue((REPO_ROOT / "assets" / "refind" / "icons" / "boot_linux.png").is_file())


if __name__ == "__main__":
    unittest.main()
