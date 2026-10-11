"""Installer rEFInd entries: nouveau.runpm=0 on every amd64 entry, never on arm64.

PEGASUS (ASUS GU502LV, RTX 2060 Mobile 10de:1f15), 2026-10-06: the installer
kernel's nouveau oopsed in nvkm_gsp_gcx_ready() during runtime suspend and the
install hung in post-install/54-gpu-accel.sh. The installer entries must keep
nouveau's runtime PM off on amd64; the Sky1 entries must not change.

This builds the real ESP tree with build_esp_dir() for both arches (fake rEFInd
binary and d-i payload) and reads the refind.conf it writes.
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

TOKEN = "nouveau.runpm=0"


def build_conf(arch: str) -> str:
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        refind = root / "refind"
        refind.mkdir()
        (refind / "refind_x64.efi").write_bytes(b"x64")
        (refind / "refind_aa64.efi").write_bytes(b"aa64")
        kernel = root / "linux"
        initrd = root / "initrd.gz"
        kernel.write_bytes(b"k")
        initrd.write_bytes(b"i")
        esp = root / "esp"
        MODULE.build_esp_dir(esp, refind, arch, kernel, initrd, "info")
        boot = (esp / "EFI" / "BOOT" / "refind.conf").read_text()
        installed = (esp / "EFI" / "REFIND" / "REFIND.CONF").read_text()
        assert boot == installed, "EFI/BOOT and EFI/REFIND copies differ"
        return boot


def entry_options(conf: str) -> dict:
    """menuentry title -> options string, for entries that have options."""
    out = {}
    for m in re.finditer(r'menuentry "([^"]+)" \{(.*?)\n\}', conf, re.DOTALL):
        opt = re.search(r'options "([^"]*)"', m.group(2))
        if opt:
            out[m.group(1)] = opt.group(1)
    return out


class NouveauRunpmEntries(unittest.TestCase):
    def test_every_amd64_entry_carries_the_token_once(self):
        entries = entry_options(build_conf("amd64"))
        self.assertGreaterEqual(len(entries), 3, entries)
        for title, opts in entries.items():
            self.assertEqual(opts.split().count(TOKEN), 1, f"{title}: {opts}")

    def test_no_arm64_entry_carries_the_token(self):
        conf = build_conf("arm64")
        entries = entry_options(conf)
        self.assertGreaterEqual(len(entries), 3, entries)
        for title, opts in entries.items():
            self.assertNotIn("nouveau", opts, f"{title}: {opts}")
        self.assertNotIn("nouveau", conf)

    def test_arm64_strings_are_unchanged_by_the_amd64_suffix(self):
        for name in (
            "ARM64_INSTALL_OPTIONS",
            "ARM64_EXPERT_OPTIONS",
            "ARM64_RESCUE_OPTIONS",
        ):
            self.assertNotIn("nouveau", getattr(MODULE, name), name)
        # the amd64 strings are the shared strings plus the suffix, nothing else
        self.assertEqual(
            MODULE.AMD64_INSTALL_OPTIONS,
            MODULE._PC_INSTALL_OPTIONS + " " + TOKEN + " nomodeset",
        )
        self.assertEqual(
            MODULE.AMD64_EXPERT_OPTIONS,
            MODULE._PC_EXPERT_OPTIONS + " " + TOKEN + " nomodeset",
        )
        self.assertEqual(
            MODULE.AMD64_RESCUE_OPTIONS, MODULE._PC_RESCUE_OPTIONS + " " + TOKEN
        )


if __name__ == "__main__":
    unittest.main()
