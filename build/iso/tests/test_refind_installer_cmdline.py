"""Installer cmdline: every entry carries the build id, no entry names brltty.

  1. No installer entry may carry a cmdline token containing "brltty".
     brltty-udeb's d-i startup hook S37brltty runs `grep -q brltty
     /proc/cmdline` and STARTS brltty when it matches. The earlier
     ncz_no_brltty=1 token (meant for the udev helper, which treats the same
     substring as "do not start") therefore started brltty on every boot of
     the Install/Expert entries: 80-column console clamp and no framebuffer
     frontend, with no braille or USB-serial device attached (MacBookPro16,1,
     2026-10-14). The installer now carries no brltty at all
     (patch-initrd-t2-kernel.py); this test keeps the token from coming back.

  2. The boot banner showed "==== NCZ-OS INSTALLER unknown ====" because the
     installer cmdline never carried ncz_rev=. Fix: build-refind-esp.py gains
     --build-id (build/build-installer-image.sh passes its BUILD_VERSION, e.g.
     2026.10.12-07c0644) and stamps `ncz_rev=<id>` into every entry's options.

This builds the real ESP tree with build_esp_dir() for both arches (fake rEFInd
binary and d-i payload) and reads the refind.conf it writes; it needs no real
kernel, initrd, mtools or boot.
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

BUILD_ID = "2026.10.12-07c0644"


def _fake_refind(root: Path) -> Path:
    refind = root / "refind"
    (refind / "icons").mkdir(parents=True)
    (refind / "refind_x64.efi").write_bytes(b"x64")
    (refind / "refind_aa64.efi").write_bytes(b"aa64")
    # amd64 build_esp_dir copies icons/ and needs boot_linux.png.
    (refind / "icons" / "boot_linux.png").write_bytes(b"\x89PNG")
    return refind


def build_conf(arch: str, build_id: str = BUILD_ID) -> str:
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        refind = _fake_refind(root)
        kernel = root / "linux"
        initrd = root / "initrd.gz"
        kernel.write_bytes(b"k")
        initrd.write_bytes(b"i")
        esp = root / "esp"
        MODULE.build_esp_dir(esp, refind, arch, kernel, initrd, "info",
                             build_id=build_id)
        boot = (esp / "EFI" / "BOOT" / "refind.conf").read_text()
        installed = (esp / "EFI" / "REFIND" / "REFIND.CONF").read_text()
        assert boot == installed, "EFI/BOOT and EFI/REFIND copies differ"
        return boot


def entries(conf: str) -> dict:
    """menuentry title -> options string, for entries that load /linux."""
    out = {}
    for m in re.finditer(r'menuentry "([^"]+)" \{(.*?)\n\}', conf, re.DOTALL):
        body = m.group(2)
        if "loader /linux" not in body:
            continue
        opt = re.search(r'options "([^"]*)"', body)
        if opt:
            out[m.group(1)] = opt.group(1)
    return out


class BuildIdOnEveryEntry(unittest.TestCase):
    def _check_arch(self, arch: str):
        opts = entries(build_conf(arch))
        self.assertGreaterEqual(len(opts), 3, opts)
        for title, o in opts.items():
            toks = o.split()
            self.assertEqual(toks.count(f"ncz_rev={BUILD_ID}"), 1,
                             f"{arch} {title}: expected exactly one ncz_rev=, got {toks}")
            # never the literal "unknown" (the "unknown" banner defect)
            self.assertNotIn("ncz_rev=unknown", toks, f"{arch} {title}: {toks}")

    def test_amd64_entries_carry_the_build_id(self):
        self._check_arch("amd64")

    def test_arm64_entries_carry_the_build_id(self):
        self._check_arch("arm64")

    def test_no_ncz_rev_token_when_no_build_id_is_given(self):
        # A hand-run with no --build-id (and no git) must not ship "ncz_rev=",
        # which would be the misleading "unknown" again.
        conf = build_conf("amd64", build_id="")
        self.assertNotIn("ncz_rev=", conf)

    def test_whitespace_and_quotes_are_stripped_from_the_build_id(self):
        self.assertEqual(MODULE.sanitize_build_id(' 2026.10.12-07c "0644 '),
                         "2026.10.12-07c-0644")
        conf = build_conf("amd64", build_id='2026.10.12 x"y')
        for o in entries(conf).values():
            self.assertEqual(o.split().count("ncz_rev=2026.10.12-xy"), 1, o)


class NoBrlttyOnTheCmdline(unittest.TestCase):
    def test_no_entry_names_brltty(self):
        for arch in ("amd64", "arm64"):
            opts = entries(build_conf(arch))
            self.assertGreaterEqual(len(opts), 3, opts)
            for title, o in opts.items():
                self.assertNotIn("brltty", o.lower(), f"{arch} {title}: {o}")

    def test_no_module_option_string_names_brltty(self):
        for name in dir(MODULE):
            if name.endswith("_OPTIONS"):
                value = getattr(MODULE, name)
                if isinstance(value, str):
                    self.assertNotIn("brltty", value.lower(), name)

    def test_builder_refuses_a_brltty_token(self):
        bad = 'menuentry "x" {\n    options "auto=true ncz_no_brltty=1"\n}\n'
        with self.assertRaises(ValueError):
            MODULE.assert_no_brltty_options(bad)
        # Comments and other lines are not boot options.
        MODULE.assert_no_brltty_options("# brltty is not shipped\n")


if __name__ == "__main__":
    unittest.main()
