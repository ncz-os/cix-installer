"""Installer cmdline: every entry carries the build id, unattended entries stop brltty.

HP OmniDesk test desktop, 2026-10-12, unattended amd64 install:

  1. A Prolific PL2303 USB-serial adapter (067b:2303) was plugged in. BRLTTY's
     d-i udev rules start brltty for GENERIC USB-serial ids (FTDI 0403:6001,
     0403:6010, CP210x 10c4:ea60/ea80, CH341 1a86:55d3/7523; QEMU's emulated
     usb-serial is 0403:6001) and set /var/run/brltty-generic, so the
     brltty-udeb postinst asked the CRITICAL question "Is the USB serial
     device indeed a braille device?" and the install stopped dead.
     Fix (this test): every unattended Install/Expert entry carries a cmdline
     token that makes brltty-udeb's /lib/udev/brltty.sh exit before it starts
     brltty (`grep -q brltty /proc/cmdline && exit 0`). The d-i-level answer
     lives in preseed/preseed.cfg (`brltty-udeb/generic boolean false`).
     Rescue is deliberately left alone (it is the interactive path, and the
     preseed answer covers it anyway).

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
# Any cmdline token containing the substring "brltty" satisfies the upstream
# /lib/udev/brltty.sh guard; we just require that SOME token does.
BRLTTY_TOKEN = MODULE.NCZ_NO_BRLTTY


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


class BrlttyAutodetectDisabled(unittest.TestCase):
    def _check_arch(self, arch: str):
        opts = entries(build_conf(arch))
        for title in ("NCZ-OS Installer -- Install",
                      "NCZ-OS Installer -- Install (expert)"):
            self.assertIn(title, opts, opts.keys())
            tokens = opts[title].split()
            # Exactly one token, and it satisfies the upstream substring guard.
            hits = [t for t in tokens if "brltty" in t]
            self.assertEqual(hits, [BRLTTY_TOKEN], f"{arch} {title}: {tokens}")

    def test_amd64_install_and_expert_disable_brltty(self):
        self._check_arch("amd64")

    def test_arm64_install_and_expert_disable_brltty(self):
        self._check_arch("arm64")

    def test_rescue_entry_is_left_alone(self):
        # Rescue is the interactive/diagnostic path; the preseed answer covers
        # the generic-US-serial question there. Only Install/Expert carry the
        # autodetect-disable token.
        for arch in ("amd64", "arm64"):
            o = entries(build_conf(arch))["NCZ-OS Installer -- Rescue mode"]
            self.assertNotIn("brltty", o, f"{arch} rescue: {o}")

    def test_token_matches_the_upstream_udev_guard(self):
        # /lib/udev/brltty.sh: `grep -q brltty /proc/cmdline && exit 0` -- the
        # substring must be present for the guard to fire.
        self.assertIn("brltty", BRLTTY_TOKEN)
        self.assertNotIn(" ", BRLTTY_TOKEN)


if __name__ == "__main__":
    unittest.main()
