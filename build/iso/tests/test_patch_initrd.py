import gzip
import importlib.util
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).parents[1] / "patch-initrd-t2-kernel.py"
SPEC = importlib.util.spec_from_file_location("patch_initrd_t2_kernel", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


class SingleMemberInitrdTest(unittest.TestCase):
    def test_combines_payloads_without_a_second_gzip_member(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            base = root / "base.gz"
            overlay = root / "overlay.gz"
            output = root / "initrd.gz"
            with gzip.open(base, "wb") as stream:
                stream.write(b"base-cpio")
            with gzip.open(overlay, "wb") as stream:
                stream.write(b"overlay-cpio")

            MODULE.write_single_member_initrd(base, overlay, output)

            self.assertEqual(gzip.decompress(output.read_bytes()),
                             b"base-cpiooverlay-cpio")
            # zlib's unused_data exposes another gzip header if a second
            # member was appended; the production regression was that layout.
            import zlib
            inflater = zlib.decompressobj(16 + zlib.MAX_WBITS)
            inflater.decompress(output.read_bytes())
            self.assertEqual(inflater.unused_data, b"")


class MissingFirmwarePatchTest(unittest.TestCase):
    def test_removes_timestamp_truncation_but_keeps_following_logic(self):
        source = """get_fresh_dmesg() {
\tdmesg > $dmesg_file
\t# Truncate if needed:
\tif [ -f $dmesg_ts ]; then
\t\tsed -i "1,$ln d" $dmesg_file
\telse
\t\tlog first
\tfi

\tif [ -s $dmesg_file ]; then
\t\tlog save
\tfi
}
"""
        patched = MODULE.patch_check_missing_firmware(source)
        self.assertNotIn('sed -i "1,$ln d"', patched)
        self.assertIn("looking at complete dmesg (NCZ firmware audit)", patched)
        self.assertIn("if [ -s $dmesg_file ]; then", patched)

    def test_fails_closed_if_upstream_shape_changes(self):
        with self.assertRaisesRegex(RuntimeError, "changed upstream"):
            MODULE.patch_check_missing_firmware("get_fresh_dmesg() { dmesg; }")


OUR_KVER = "7.3.0-rc7-t2-ncz"
DEB_KVER = "7.2.9+deb14-amd64"


def newc(entries):
    """Build a minimal, valid newc cpio archive (GNU-compatible)."""
    out = bytearray()
    ino = 1
    for name, mode, payload in entries:
        nameb = name.encode() + b"\0"
        fields = [ino, mode, 0, 0, 1, 0, len(payload), 0, 0, 0, 0,
                  len(nameb), 0]
        header = b"070701" + b"".join(b"%08X" % f for f in fields)
        out += header + nameb
        out += b"\0" * ((-(len(header) + len(nameb))) % 4)
        out += payload
        out += b"\0" * ((-len(payload)) % 4)
        ino += 1
    trailer = b"TRAILER!!!\0"
    fields = [ino, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, len(trailer), 0]
    header = b"070701" + b"".join(b"%08X" % f for f in fields)
    out += header + trailer
    out += b"\0" * ((-(len(header) + len(trailer))) % 4)
    return bytes(out)


STATUS = (
    "Package: base-modules-7.2.9+deb14-amd64-di\n"
    "Status: install ok unpacked\nVersion: 7.2.9-1\n\n"
    "Package: linux-base-7.2.9+deb14-amd64-di\n"
    "Status: install ok unpacked\nVersion: 7.2.9-1\n\n"
    "Package: debian-installer\n"
    "Status: install ok installed\n"
    "Version: cdrom-isolinux-20261005-00:02:17\n\n"
    "Package: partman-lvm\nStatus: install ok unpacked\nVersion: 159\n\n"
)


class OneKernelPruneTest(unittest.TestCase):
    def _base(self):
        return newc([
            ("lib", 0o040755, b""),
            ("lib/modules", 0o040755, b""),
            ("lib/modules/" + DEB_KVER, 0o040755, b""),
            ("lib/modules/" + DEB_KVER + "/kernel/ata.ko", 0o100644, b"dead"),
            ("lib/modules/" + OUR_KVER, 0o040755, b""),
            ("lib/modules/" + OUR_KVER + "/kernel/our.ko", 0o100644, b"ours"),
            ("var", 0o040755, b""),
            ("var/lib", 0o040755, b""),
            ("var/lib/dpkg", 0o040755, b""),
            ("var/lib/dpkg/status", 0o100644, STATUS.encode()),
            ("preseed.cfg", 0o100644, b"x"),
        ])

    def test_filter_drops_foreign_kernel_tree_and_status(self):
        pruned, kvers, dropped = MODULE.filter_base_cpio(self._base(), OUR_KVER)
        self.assertEqual(kvers, {DEB_KVER})
        self.assertNotIn(b"lib/modules/" + DEB_KVER.encode(), pruned)
        self.assertIn(b"lib/modules/" + OUR_KVER.encode(), pruned)
        self.assertNotIn(b"var/lib/dpkg/status", pruned)
        self.assertGreater(dropped, 0)
        # The pruned stream is still a valid, parseable archive.
        names = [e["name"] for e in MODULE._parse_newc_entries(pruned)]
        self.assertIn("lib/modules/" + OUR_KVER + "/kernel/our.ko", names)
        self.assertNotIn("var/lib/dpkg/status", names)

    def test_filter_keeps_our_kernel_even_when_versions_match(self):
        base = newc([
            ("lib/modules/" + OUR_KVER + "/kernel/our.ko", 0o100644, b"ours"),
        ])
        pruned, kvers, _ = MODULE.filter_base_cpio(base, OUR_KVER)
        self.assertEqual(kvers, set())
        self.assertIn(b"our.ko", pruned)

    def test_prune_status_removes_kernel_and_marker_only(self):
        text, dropped = MODULE.prune_initrd_status(STATUS)
        self.assertIn("base-modules-" + DEB_KVER + "-di", dropped)
        self.assertIn("linux-base-" + DEB_KVER + "-di", dropped)
        self.assertIn("debian-installer", dropped)
        self.assertNotIn("base-modules-", text)
        self.assertNotIn("debian-installer", text)
        self.assertIn("partman-lvm", text)
        # Idempotent: pruning the pruned text drops nothing more.
        text2, dropped2 = MODULE.prune_initrd_status(text)
        self.assertEqual(dropped2, [])
        self.assertEqual(text2, text)

    def test_verify_fails_on_surviving_debian_kernel_tree(self):
        with tempfile.TemporaryDirectory() as td:
            bad = Path(td) / "bad.gz"
            with gzip.open(bad, "wb") as fh:
                fh.write(newc([
                    ("lib/modules/" + DEB_KVER + "/kernel/ata.ko", 0o100644, b"x"),
                ]))
            with self.assertRaisesRegex(RuntimeError, "one-kernel policy"):
                MODULE.verify_one_kernel_initrd(bad, OUR_KVER)

    def test_verify_fails_on_surviving_status_records(self):
        with tempfile.TemporaryDirectory() as td:
            bad = Path(td) / "bad.gz"
            with gzip.open(bad, "wb") as fh:
                fh.write(newc([
                    ("var/lib/dpkg/status", 0o100644, STATUS.encode()),
                ]))
            with self.assertRaisesRegex(RuntimeError, "dpkg status still"):
                MODULE.verify_one_kernel_initrd(bad, OUR_KVER)

    def test_verify_passes_on_pruned_initrd(self):
        with tempfile.TemporaryDirectory() as td:
            good = Path(td) / "good.gz"
            pruned, _, _ = MODULE.filter_base_cpio(self._base(), OUR_KVER)
            text, _ = MODULE.prune_initrd_status(STATUS)
            overlay = newc([("var/lib/dpkg/status", 0o100644, text.encode())])
            with gzip.open(good, "wb") as fh:
                fh.write(pruned + overlay)
            out = MODULE.verify_one_kernel_initrd(good, OUR_KVER)
            self.assertEqual(out["debian_kernel_paths"], 0)


# The member set brltty-udeb 6.9.1 puts into the forky d-i initrd (both arches),
# trimmed to one table per directory.
BRAILLE_MEMBERS = [
    ("etc/brltty", 0o040755, b""),
    ("etc/brltty/Contraction", 0o040755, b""),
    ("etc/brltty/Contraction/en.ctb", 0o100644, b"t"),
    ("usr/bin/brltty", 0o100755, b"ELF"),
    ("usr/lib/brltty", 0o040755, b""),
    ("usr/lib/brltty/brltty.sh", 0o100755, b"stty cols 80 < /dev/tty1"),
    ("usr/lib/debian-installer-startup.d/S37brltty", 0o100755,
     b"if grep -q brltty /proc/cmdline; then /lib/brltty/brltty.sh -E; fi"),
    ("usr/lib/debian-installer.d/S19brltty", 0o100644, b""),
    ("usr/lib/finish-install.d/07brltty", 0o100755, b"#!/bin/sh"),
    ("usr/lib/udev/brltty.sh", 0o100755, b"#!/bin/sh"),
    ("usr/lib/udev/rules.d/brltty.rules", 0o100644, b"SUBSYSTEM"),
    ("usr/share/brltty-udeb", 0o040755, b""),
    ("usr/share/brltty-udeb/mate-preseed.cfg", 0o100644, b"d-i"),
    ("var/lib/dpkg/info/brltty-udeb.postinst", 0o100755, b"#!/bin/sh"),
    ("var/lib/dpkg/info/brltty-udeb.templates", 0o100644, b"Template:"),
]
BRAILLE_STATUS = (
    "Package: brltty-udeb\nStatus: install ok unpacked\n"
    "Version: 6.9.1+repack-2\nInstaller-Menu-Item: 1050\n\n"
    "Package: partman-lvm\nStatus: install ok unpacked\nVersion: 159\n\n"
)
KEEP_MEMBERS = [
    ("usr/lib/debian-installer-startup.d/S37speakup", 0o100755, b"speakup"),
    ("usr/lib/debian-installer.d/S20speakup", 0o100644, b""),
    ("usr/lib/udev/rules.d/60-persistent-storage.rules", 0o100644, b"x"),
    ("usr/bin/main-menu", 0o100755, b"ELF"),
]


class NoBrailleInstallerTest(unittest.TestCase):
    def test_filter_drops_every_braille_member_and_keeps_the_rest(self):
        base = newc(BRAILLE_MEMBERS + KEEP_MEMBERS)
        pruned, _, dropped = MODULE.filter_base_cpio(base, OUR_KVER)
        names = [e["name"] for e in MODULE._parse_newc_entries(pruned)]
        self.assertEqual(dropped, len(BRAILLE_MEMBERS))
        for name, _, _ in BRAILLE_MEMBERS:
            self.assertNotIn(name, names)
        for name, _, _ in KEEP_MEMBERS:
            self.assertIn(name, names)

    def test_prune_status_drops_brltty_udeb(self):
        text, dropped = MODULE.prune_initrd_status(BRAILLE_STATUS)
        self.assertEqual(dropped, ["brltty-udeb"])
        self.assertNotIn("brltty", text)
        self.assertIn("partman-lvm", text)

    def _gz(self, td, name, data):
        p = Path(td) / name
        with gzip.open(p, "wb") as fh:
            fh.write(data)
        return p

    def test_verify_fails_on_any_braille_member(self):
        with tempfile.TemporaryDirectory() as td:
            for member in BRAILLE_MEMBERS:
                bad = self._gz(td, "bad.gz", newc(KEEP_MEMBERS + [member]))
                with self.assertRaisesRegex(RuntimeError, "braille"):
                    MODULE.verify_no_braille_initrd(bad)

    def test_verify_fails_when_a_later_archive_re_adds_brltty(self):
        with tempfile.TemporaryDirectory() as td:
            bad = self._gz(td, "bad.gz", newc(KEEP_MEMBERS) + newc(
                [("usr/lib/debian-installer-startup.d/S37brltty", 0o100755, b"x")]))
            with self.assertRaisesRegex(RuntimeError, "braille"):
                MODULE.verify_no_braille_initrd(bad)

    def test_verify_fails_on_a_status_record(self):
        with tempfile.TemporaryDirectory() as td:
            bad = self._gz(td, "bad.gz", newc(
                [("var/lib/dpkg/status", 0o100644, BRAILLE_STATUS.encode())]))
            with self.assertRaisesRegex(RuntimeError, "brltty-udeb"):
                MODULE.verify_no_braille_initrd(bad)

    def test_verify_passes_after_the_prune(self):
        with tempfile.TemporaryDirectory() as td:
            pruned, _, _ = MODULE.filter_base_cpio(
                newc(BRAILLE_MEMBERS + KEEP_MEMBERS), OUR_KVER)
            text, _ = MODULE.prune_initrd_status(BRAILLE_STATUS)
            good = self._gz(td, "good.gz", pruned + newc(
                [("var/lib/dpkg/status", 0o100644, text.encode())]))
            self.assertEqual(MODULE.verify_no_braille_initrd(good)["braille_members"], 0)


class RequiredInitrdPackagesTest(unittest.TestCase):
    """wget-udeb must be in the final initrd: the Magnetar fetcher uses GNU
    wget because d-i's busybox has no wget applet (2026-10-26)."""

    STATUS_OK = ("Package: wget-udeb\nStatus: install ok unpacked\nVersion: 1.25.0-3\n\n"
                 "Package: busybox-udeb\nStatus: install ok unpacked\nVersion: 1:1.38.0-3\n")

    def _gz(self, td, data):
        p = Path(td) / "initrd.gz"
        p.write_bytes(gzip.compress(data))
        return p

    def test_passes_with_status_and_binary(self):
        with tempfile.TemporaryDirectory() as td:
            good = self._gz(td, newc([("usr/bin/wget", 0o100755, b"ELF"),
                                      ("var/lib/dpkg/status", 0o100644, self.STATUS_OK.encode())]))
            self.assertEqual(MODULE.verify_required_initrd_packages(good)["required_initrd_packages"],
                             ["wget-udeb"])

    def test_fails_without_the_status_record(self):
        with tempfile.TemporaryDirectory() as td:
            bad = self._gz(td, newc([("usr/bin/wget", 0o100755, b"ELF"),
                                     ("var/lib/dpkg/status", 0o100644,
                                      b"Package: busybox-udeb\nStatus: install ok unpacked\n")]))
            with self.assertRaisesRegex(RuntimeError, "wget-udeb .not in the initrd dpkg status"):
                MODULE.verify_required_initrd_packages(bad)

    def test_fails_without_the_binary(self):
        with tempfile.TemporaryDirectory() as td:
            bad = self._gz(td, newc([("var/lib/dpkg/status", 0o100644, self.STATUS_OK.encode())]))
            with self.assertRaisesRegex(RuntimeError, "no /usr/bin/wget member"):
                MODULE.verify_required_initrd_packages(bad)

    def test_the_later_status_wins(self):
        """The overlay's pruned status (later archive) is the effective one."""
        with tempfile.TemporaryDirectory() as td:
            bad = self._gz(td, newc([("usr/bin/wget", 0o100755, b"ELF"),
                                     ("var/lib/dpkg/status", 0o100644, self.STATUS_OK.encode())])
                               + newc([("var/lib/dpkg/status", 0o100644,
                                        b"Package: busybox-udeb\nStatus: install ok unpacked\n")]))
            with self.assertRaises(RuntimeError):
                MODULE.verify_required_initrd_packages(bad)


if __name__ == "__main__":
    unittest.main()
