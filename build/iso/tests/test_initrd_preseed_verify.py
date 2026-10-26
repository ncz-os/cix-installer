"""Strict initrd preseed/hook verification tests.

Covers the 2026-10-08 one-load preseed verifier in
build/iso/patch-initrd-t2-kernel.py. It must accept a real GNU-cpio initrd and
reject every malformed variant (truncated gzip/archive, junk, bad CRC, aliased
or non-regular members, wrong hook body), and the cache-hit path must re-verify
the same final output and require the kernel file.
"""

import gzip
import importlib.util
import io
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

SCRIPT = Path(__file__).parents[1] / "patch-initrd-t2-kernel.py"
SPEC = importlib.util.spec_from_file_location("patch_initrd_t2_kernel", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)

REPO = Path(__file__).resolve().parents[3]
_TMPBASE = Path(os.environ.get("NCZ_TEST_TMPDIR", REPO / ".test-tmp"))
_TMPBASE.mkdir(parents=True, exist_ok=True)

HOOK_NAME = MODULE.NCZ_STARTUP_HOOK_NAME
HOOK_REL = "usr/lib/debian-installer-startup.d/" + HOOK_NAME
HOOK_BODY = MODULE.NCZ_STARTUP_HOOK_BODY.encode("utf-8")
PRESEED = b"# fixture preseed\nnetcfg/get_hostname string fixture\n"
# A final initrd must also carry the installer packages the NCZ installer
# uses (REQUIRED_INITRD_PACKAGES); the cache-hit path checks them too.
REQUIRED_ENTRIES = [
    (
        "var/lib/dpkg/status",
        b"Package: wget-udeb\nStatus: install ok unpacked\nVersion: 1.25.0-3\n\n",
        0o100644,
    ),
    ("usr/bin/wget", b"ELF", 0o100755),
]


def _has_gnu_cpio() -> bool:
    if shutil.which("cpio") is None:
        return False
    try:
        out = subprocess.run(
            ["cpio", "--version"], capture_output=True, text=True, check=False
        )
    except OSError:
        return False
    return "GNU" in out.stdout


HAS_GNU_CPIO = _has_gnu_cpio()


def _gz(data: bytes) -> bytes:
    buf = io.BytesIO()
    with gzip.GzipFile(fileobj=buf, mode="wb", mtime=0) as stream:
        stream.write(data)
    return buf.getvalue()


def _newc_entry(
    name, payload, mode=0o100644, magic=b"070701", check=0, size_override=None
):
    name_b = name.encode("utf-8") + b"\0"
    size = len(payload) if size_override is None else size_override
    fields = [1, mode, 0, 0, 1, 0, size, 0, 0, 0, 0, len(name_b)]
    header = magic + b"".join(f"{field:08x}".encode() for field in fields)
    header += f"{check:08x}".encode()
    assert len(header) == 110
    out = bytearray(header)
    out += name_b
    out += b"\0" * ((-len(out)) % 4)
    out += payload
    out += b"\0" * ((-len(out)) % 4)
    return bytes(out)


def _trailer():
    return _newc_entry("TRAILER!!!", b"", 0)


def _crafted(entries, magic=b"070701", trailer=True):
    """entries: list of (name, payload, mode)."""
    buf = bytearray()
    for name, payload, mode in entries:
        buf += _newc_entry(name, payload, mode, magic)
    if trailer:
        buf += _trailer()
    return bytes(buf)


def _gnu_archive(root: Path, names):
    proc = subprocess.run(
        ["cpio", "-o", "-H", "newc", "--quiet"],
        cwd=root,
        input=("\n".join(names) + "\n").encode(),
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        check=True,
    )
    return proc.stdout


def _gnu_stream() -> bytes:
    """Two concatenated real GNU cpio archives (base + overlay), as produced
    for the installer initrd."""
    with tempfile.TemporaryDirectory(dir=_TMPBASE) as td:
        root = Path(td)
        (root / "base-marker").write_text("base\n")
        (root / "preseed.cfg").write_bytes(PRESEED)
        hook = root / HOOK_REL
        hook.parent.mkdir(parents=True)
        hook.write_bytes(HOOK_BODY)
        hook.chmod(0o755)
        base = _gnu_archive(root, ["base-marker"])
        overlay = _gnu_archive(root, ["preseed.cfg", HOOK_REL])
        return base + overlay


class VerifyBakedPreseedTest(unittest.TestCase):
    def setUp(self):
        self._td = tempfile.TemporaryDirectory(dir=_TMPBASE)
        self.root = Path(self._td.name)
        self.src = self.root / "preseed-src.cfg"
        self.src.write_bytes(PRESEED)

    def tearDown(self):
        self._td.cleanup()

    def _initrd(self, stream: bytes, name="initrd.gz") -> Path:
        path = self.root / name
        path.write_bytes(_gz(stream))
        return path

    def _expect_error(self, initrd, needle):
        with self.assertRaises(RuntimeError) as ctx:
            MODULE.verify_baked_preseed(initrd, self.src)
        self.assertIn(needle, str(ctx.exception))

    @unittest.skipUnless(HAS_GNU_CPIO, "GNU cpio not available")
    def test_accepts_real_gnu_archive(self):
        info = MODULE.verify_baked_preseed(self._initrd(_gnu_stream()), self.src)
        self.assertEqual(info["hook_member"], HOOK_REL)

    def test_accepts_crafted_and_dot_prefixed_targets(self):
        stream = _crafted(
            [("./preseed.cfg", PRESEED, 0o100644), (HOOK_REL, HOOK_BODY, 0o100755)]
        )
        MODULE.verify_baked_preseed(self._initrd(stream), self.src)

    def test_rejects_truncated_gzip(self):
        raw = _gz(
            _crafted(
                [("preseed.cfg", PRESEED, 0o100644), (HOOK_REL, HOOK_BODY, 0o100755)]
            )
        )
        path = self.root / "trunc.gz"
        path.write_bytes(raw[:-4])
        self._expect_error(path, "truncated")

    def test_rejects_archive_without_trailer(self):
        stream = _crafted(
            [("preseed.cfg", PRESEED, 0o100644), (HOOK_REL, HOOK_BODY, 0o100755)],
            trailer=False,
        )
        self._expect_error(self._initrd(stream), "TRAILER")

    def test_rejects_truncated_body(self):
        entry = _newc_entry("preseed.cfg", PRESEED, size_override=4096)
        self._expect_error(self._initrd(entry + _trailer()), "truncated cpio body")

    def test_rejects_truncated_header(self):
        self._expect_error(self._initrd(b"070701" + b"0" * 40), "truncated cpio header")

    def test_rejects_corrupt_crc(self):
        stream = _crafted(
            [("preseed.cfg", PRESEED, 0o100644), (HOOK_REL, HOOK_BODY, 0o100755)],
            magic=b"070702",
        )
        self._expect_error(self._initrd(stream), "CRC")

    def test_rejects_non_hex_in_ignored_header_field(self):
        # The uid field (bytes 22:30) is never otherwise read; a sign/space/
        # non-hex byte there is still corruption the kernel would reject.
        entry = bytearray(_newc_entry("preseed.cfg", PRESEED, 0o100644))
        entry[22:30] = b"zzzzzzzz"
        self._expect_error(self._initrd(bytes(entry) + _trailer()), "non-hex")

    def test_rejects_embedded_nul_after_accepted_targets(self):
        # A name like "preseed.cfg\0suffix" is a different member to this
        # parser but the C-string kernel path would overwrite /preseed.cfg.
        stream = _crafted(
            [
                ("preseed.cfg", PRESEED, 0o100644),
                (HOOK_REL, HOOK_BODY, 0o100755),
                ("preseed.cfg\0suffix", b"WRONG", 0o100644),
            ]
        )
        self._expect_error(self._initrd(stream), "embedded NUL")

    def test_rejects_trailing_junk(self):
        stream = (
            _crafted(
                [("preseed.cfg", PRESEED, 0o100644), (HOOK_REL, HOOK_BODY, 0o100755)]
            )
            + b"\xde\xad\xbe\xef" * 30
        )
        self._expect_error(self._initrd(stream), "junk")

    def test_rejects_wrong_hook_body(self):
        stream = _crafted(
            [("preseed.cfg", PRESEED, 0o100644), (HOOK_REL, b"not the hook", 0o100755)]
        )
        self._expect_error(self._initrd(stream), "NCZ_STARTUP_HOOK_BODY")

    def test_rejects_non_executable_hook(self):
        stream = _crafted(
            [("preseed.cfg", PRESEED, 0o100644), (HOOK_REL, HOOK_BODY, 0o100644)]
        )
        self._expect_error(self._initrd(stream), "want 0o755")

    def test_rejects_non_regular_hook_and_preseed(self):
        hook = _crafted(
            [("preseed.cfg", PRESEED, 0o100644), (HOOK_REL, b"target", 0o120777)]
        )
        self._expect_error(self._initrd(hook, "hook.gz"), "not a regular file")
        seed = _crafted(
            [("preseed.cfg", b"target", 0o120777), (HOOK_REL, HOOK_BODY, 0o100755)]
        )
        self._expect_error(self._initrd(seed, "seed.gz"), "not a regular file")

    def test_rejects_aliased_targets(self):
        for alias in ("../preseed.cfg", "usr/../preseed.cfg", "/preseed.cfg"):
            stream = _crafted(
                [(alias, PRESEED, 0o100644), (HOOK_REL, HOOK_BODY, 0o100755)]
            )
            with self.subTest(alias=alias):
                self._expect_error(self._initrd(stream, "alias.gz"), "non-canonical")


class CachedNodeTest(unittest.TestCase):
    def setUp(self):
        self._td = tempfile.TemporaryDirectory(dir=_TMPBASE)
        self.root = Path(self._td.name)
        self.src = self.root / "preseed-src.cfg"
        self.src.write_bytes(PRESEED)
        self.base = self.root / "base-initrd"
        self.base.write_bytes(b"base")
        self.kernel = self.root / "kernel.deb"
        self.kernel.write_bytes(b"kernel")

    def tearDown(self):
        self._td.cleanup()

    def _node(self, cache_root: Path) -> Path:
        key = MODULE.sha256_bytes(b"fixed-canonical")
        node = cache_root / "ncz-initrd-t2kernel" / key
        node.mkdir(parents=True)
        stream = _crafted(
            [("preseed.cfg", PRESEED, 0o100644), (HOOK_REL, HOOK_BODY, 0o100755)]
            + REQUIRED_ENTRIES
        )
        (node / "initrd.gz").write_bytes(_gz(stream))
        (node / "linux").write_bytes(b"kernel-image")
        (node / "receipt.json").write_text("{}")
        return node

    def _call(self, cache_root):
        with (
            mock.patch.object(
                MODULE, "canonical_encode", lambda _d: b"fixed-canonical"
            ),
            mock.patch.object(MODULE, "REPO_ROOT", self.root),
        ):
            return MODULE.patch_t2_kernel(
                self.base, self.kernel, "amd64", cache_root, False, self.src
            )

    def test_cache_hit_verifies_final_output(self):
        cache_root = self.root / "cache"
        self._node(cache_root)
        linux, initrd = self._call(cache_root)
        self.assertTrue(linux.is_file())
        self.assertTrue(initrd.is_file())

    def test_cache_hit_requires_kernel_file(self):
        cache_root = self.root / "cache"
        node = self._node(cache_root)
        (node / "linux").unlink()
        with self.assertRaisesRegex(RuntimeError, "kernel file"):
            self._call(cache_root)

    def test_cache_hit_rejects_corrupt_initrd(self):
        cache_root = self.root / "cache"
        node = self._node(cache_root)
        stream = _crafted(
            [("preseed.cfg", PRESEED, 0o100644), (HOOK_REL, b"wrong", 0o100755)]
            + REQUIRED_ENTRIES
        )
        (node / "initrd.gz").write_bytes(_gz(stream))
        with self.assertRaisesRegex(RuntimeError, "NCZ_STARTUP_HOOK_BODY"):
            self._call(cache_root)

    def test_requires_a_real_preseed(self):
        with self.assertRaisesRegex(RuntimeError, "real preseed.cfg is required"):
            MODULE.patch_t2_kernel(
                self.base, self.kernel, "amd64", self.root / "cache", False, None
            )


class MainCliTest(unittest.TestCase):
    def _run(self, argv):
        with mock.patch.object(sys, "argv", ["patch-initrd-t2-kernel.py"] + argv):
            return MODULE.main()

    def test_rejects_missing_preseed_path(self):
        rc = self._run(
            [
                "--base-initrd",
                "/dev/null",
                "--kernel-deb",
                "/dev/null",
                "--arch",
                "amd64",
                "--preseed-cfg",
                "/nonexistent/preseed.cfg",
            ]
        )
        self.assertEqual(rc, 1)

    def test_rejects_empty_preseed_skip(self):
        rc = self._run(
            [
                "--base-initrd",
                "/dev/null",
                "--kernel-deb",
                "/dev/null",
                "--arch",
                "amd64",
                "--preseed-cfg=",
            ]
        )
        self.assertEqual(rc, 1)


if __name__ == "__main__":
    unittest.main()
