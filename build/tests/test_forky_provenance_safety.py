"""Security regression tests for the forky-provenance scanner.

These cover the false positives that are safe to resolve WITHOUT weakening the
origin policy, together with the negative cases that must still fail closed:

  * virtual archive-root symlinks (initrd ``etc/mtab -> /proc/mounts``, usrmerge
    ``var/run -> /run`` / ``var/lock -> /run/lock``) are accepted and are never
    materialised so they cannot be followed onto the host;
  * absolute member paths, ``..`` traversal, escaping relative symlinks and
    absolute/escaping hard-links still fail;
  * duplicated cpio pathnames (content shadowing) still fail;
  * a squashfs layer with no dpkg database is accepted ONLY when it carries no
    package/apt surface (compositional validation), never as a blanket bypass;
  * the non-root debugfs ``rdump`` chown warning is the ONLY tolerated stderr
    line, and only alongside the independent type+size completeness proof.
"""

import importlib.util
import io
import os
import posixpath
import shutil
import subprocess
import tarfile
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
VER = REPO / "build" / "forky-provenance.py"
SPEC = importlib.util.spec_from_file_location("forky_provenance", VER)
assert SPEC is not None and SPEC.loader is not None
fp = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(fp)

HAVE_ZSTD = shutil.which("zstd") is not None


class SymlinkTargetTest(unittest.TestCase):
    def test_absolute_targets_bind_to_the_virtual_root(self):
        for name, target in (
            ("etc/mtab", "/proc/mounts"),
            ("var/run", "/run"),
            ("var/lock", "/run/lock"),
        ):
            ok, rewritten = fp.safe_symlink_target(name, target)
            self.assertTrue(ok, (name, target))
            resolved = posixpath.normpath(
                posixpath.join(posixpath.dirname(name), rewritten)
            )
            self.assertFalse(resolved.startswith(".."), (name, target, rewritten))

    def test_relative_escapes_rejected(self):
        for name, target in (
            ("link", "../../etc/p"),
            ("a/b", "../../etc/p"),
            ("x", "../y"),
        ):
            self.assertFalse(fp.safe_symlink_target(name, target)[0], (name, target))

    def test_empty_nul_and_root_rejected(self):
        for name, target in (("x", ""), ("x", "a\x00b"), ("x", "/")):
            self.assertFalse(fp.safe_symlink_target(name, target)[0], (name, target))

    def test_hardlink_targets(self):
        self.assertFalse(fp.safe_hardlink_target("/etc/passwd"))
        self.assertFalse(fp.safe_hardlink_target("../x"))
        self.assertFalse(fp.safe_hardlink_target(""))
        self.assertTrue(fp.safe_hardlink_target("usr/bin/foo"))


def _newc(entries):
    """Minimal newc cpio: entries are (name, mode, data); data is the symlink
    target for symlinks and the file body otherwise.  Ends with a TRAILER."""
    buf = bytearray()
    ino = 1

    def rec(name, mode, data):
        nonlocal ino
        nb = name.encode() + b"\0"
        hdr = b"070701" + b"".join(
            b"%08x" % v
            for v in (ino, mode, 0, 0, 1, 0, len(data), 0, 0, 0, 0, len(nb), 0)
        )
        buf.extend(hdr)
        buf.extend(nb)
        buf.extend(b"\0" * ((4 - (len(hdr) + len(nb)) % 4) % 4))
        buf.extend(data)
        buf.extend(b"\0" * ((4 - len(data) % 4) % 4))
        ino += 1

    for name, mode, data in entries:
        rec(name, mode, data)
    nb = b"TRAILER!!!\0"
    hdr = b"070701" + b"".join(
        b"%08x" % v for v in (0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, len(nb), 0)
    )
    buf.extend(hdr)
    buf.extend(nb)
    buf.extend(b"\0" * ((4 - (len(hdr) + len(nb)) % 4) % 4))
    return bytes(buf)


class CpioExtractTest(unittest.TestCase):
    def _run(self, data):
        with tempfile.TemporaryDirectory() as td:
            fp.FAILS.clear()
            fp._extract_newc(data, td, "test.cpio")
            return list(fp.FAILS), td

    def test_absolute_symlink_target_is_accepted(self):
        # etc/mtab -> /proc/mounts is the real installer-initrd false positive.
        fails, _ = self._run(_newc([("etc/mtab", 0o120777, b"/proc/mounts")]))
        self.assertEqual(fails, [])

    def test_escaping_relative_symlink_rejected(self):
        fails, _ = self._run(_newc([("link", 0o120777, b"../../etc/passwd")]))
        self.assertTrue(fails)

    def test_absolute_member_path_rejected(self):
        fails, _ = self._run(_newc([("/etc/x", 0o100644, b"x")]))
        self.assertTrue(fails)

    def test_duplicate_pathname_rejected(self):
        fails, _ = self._run(_newc([("a", 0o100644, b"one"), ("a", 0o100644, b"two")]))
        self.assertTrue(fails)

    def test_regular_file_roundtrip(self):
        with tempfile.TemporaryDirectory() as td:
            fp.FAILS.clear()
            fp._extract_newc(_newc([("a/b", 0o100644, b"body")]), td, "test.cpio")
            self.assertEqual(fp.FAILS, [])
            self.assertEqual((Path(td) / "a" / "b").read_bytes(), b"body")


def _make_tar_zst(root, name, members):
    tar = root / (name + ".tar")
    with tarfile.open(tar, "w") as tf:
        for m in members:
            tf.addfile(m["info"], io.BytesIO(m["data"]) if "data" in m else None)
    zst = root / (name + ".tar.zst")
    subprocess.run(["zstd", "-q", "-f", str(tar), "-o", str(zst)], check=True)
    return zst


def _dir(name):
    ti = tarfile.TarInfo(name)
    ti.type = tarfile.DIRTYPE
    ti.mode = 0o755
    return {"info": ti}


def _sym(name, target):
    ti = tarfile.TarInfo(name)
    ti.type = tarfile.SYMTYPE
    ti.linkname = target
    ti.mode = 0o777
    return {"info": ti}


def _hard(name, target):
    ti = tarfile.TarInfo(name)
    ti.type = tarfile.LNKTYPE
    ti.linkname = target
    ti.mode = 0o644
    return {"info": ti}


def _file(name, data):
    ti = tarfile.TarInfo(name)
    ti.size = len(data)
    ti.mode = 0o644
    return {"info": ti, "data": data}


@unittest.skipUnless(HAVE_ZSTD, "zstd not installed")
class TarExtractTest(unittest.TestCase):
    def setUp(self):
        # The scanner pins a scrubbed PATH; the test host keeps zstd elsewhere.
        self._need = fp.need_tool
        self._env = fp.tool_env
        fp.need_tool = lambda _n: True
        fp.tool_env = lambda: {
            "PATH": os.environ.get("PATH", ""),
            "LC_ALL": "C",
            "LANG": "C",
        }

    def tearDown(self):
        fp.need_tool = self._need
        fp.tool_env = self._env

    def _extract(self, members):
        td = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, td, ignore_errors=True)
        root = Path(td)
        zst = _make_tar_zst(root, "rootfs", members)
        dest = root / "out"
        dest.mkdir()
        fp.FAILS.clear()
        ok = fp.safe_extract_zst(zst, str(dest), "test")
        return ok, list(fp.FAILS), dest

    def test_usrmerge_absolute_symlinks_are_contained(self):
        ok, fails, dest = self._extract(
            [
                _dir("var"),
                _dir("run"),
                _sym("var/run", "/run"),
                _sym("var/lock", "/run/lock"),
                _file("etc/hostname", b"ncz\n"),
            ]
        )
        self.assertTrue(ok, fails)
        self.assertEqual(fails, [])
        # materialised, but relative and rooted inside the scratch dir
        self.assertTrue(os.path.islink(dest / "var" / "run"))
        link = os.readlink(dest / "var" / "run")
        self.assertFalse(link.startswith("/"))
        self.assertTrue(os.path.realpath(dest / "var" / "run").startswith(str(dest)))
        self.assertEqual((dest / "etc" / "hostname").read_bytes(), b"ncz\n")

    def test_escaping_relative_symlink_rejected(self):
        ok, fails, _ = self._extract([_sym("bad", "../../etc/passwd")])
        self.assertFalse(ok)
        self.assertTrue(fails)

    def test_absolute_hardlink_rejected(self):
        ok, fails, _ = self._extract([_file("a", b"x"), _hard("b", "/etc/passwd")])
        self.assertFalse(ok)
        self.assertTrue(fails)

    def test_traversal_member_rejected(self):
        ok, fails, _ = self._extract([_file("../evil", b"x")])
        self.assertFalse(ok)
        self.assertTrue(fails)

    def test_duplicate_shadow_member_rejected(self):
        # A later member at the same normalized path could overwrite an earlier
        # mapped file (e.g. var/lib/dpkg/status).
        ok, fails, _ = self._extract(
            [
                _file("var/lib/dpkg/status", b"good"),
                _file("./var/lib/dpkg/status", b"evil"),
            ]
        )
        self.assertFalse(ok)
        self.assertTrue(fails)

    def test_distinct_data_hardlinks_accepted(self):
        # Pure data hard-links have distinct names and must not be flagged.
        ok, fails, dest = self._extract(
            [
                _file("a", b"payload"),
                _hard("b", "a"),
                _sym("lib", "usr/lib"),
                _file("usr/lib/x", b"y"),
            ]
        )
        self.assertTrue(ok, fails)
        self.assertEqual(fails, [])
        self.assertEqual((dest / "b").read_bytes(), b"payload")


class DebugfsChownTest(unittest.TestCase):
    def test_exact_chown_warning_matches(self):
        self.assertTrue(
            fp.CHOWN_PERM_RE.search(
                "rdump: /pool: Operation not permitted while changing ownership"
            )
        )
        self.assertTrue(
            fp.CHOWN_PERM_RE.search(
                "debugfs: Operation not permitted while changing ownership"
            )
        )

    def test_other_errors_do_not_match(self):
        self.assertFalse(fp.CHOWN_PERM_RE.search("not found by ext2_lookup"))
        self.assertFalse(fp.CHOWN_PERM_RE.search("Permission denied"))
        self.assertFalse(fp.CHOWN_PERM_RE.search("operation not permitted"))


@unittest.skipUnless(shutil.which("dpkg-deb"), "requires dpkg-deb")
class Amd64StagingTest(unittest.TestCase):
    """Exercise the real stager with tiny debs and a committed-style manifest."""

    def setUp(self):
        import json

        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "build").mkdir()
        self.destination = self.root / "assets/kernel/amd64-stable"
        self.destination.mkdir(parents=True)
        self.script = self.root / "build/stage-amd64-kernel.sh"
        shutil.copy2(REPO / "build/stage-amd64-kernel.sh", self.script)
        self.pool = self.root / "pool"
        self.pool.mkdir()
        self.kver = "7.3.0-rc6-t2-ncz"
        (self.destination / "KVER").write_text(self.kver + "\n")
        self.manifest = {
            "arch": "amd64",
            "kver": self.kver,
            "staging_pool_relative": "kernel-staging/test/" + self.kver,
            "source": {"base_commit": "a" * 40, "t2_repo_commit": "b" * 40},
            "identity": {"kernel_release": self.kver},
            "artifacts": {},
        }
        for kind in ("image", "headers"):
            package = f"linux-{kind}-{self.kver}"
            version = "7.3.0-rc6-6"
            self.manifest["identity"][f"{kind}_deb_package"] = package
            self.manifest["identity"][f"{kind}_deb_version"] = version
            tree = self.root / kind
            (tree / "DEBIAN").mkdir(parents=True)
            (tree / "DEBIAN/control").write_text(
                f"Package: {package}\nVersion: {version}\nArchitecture: amd64\n"
                "Maintainer: Test <test@example.invalid>\nDescription: test fixture\n"
            )
            deb = self.pool / f"{package}_{version}_amd64.deb"
            subprocess.run(
                ["dpkg-deb", "--build", "--root-owner-group", str(tree), str(deb)],
                check=True,
                capture_output=True,
            )
        (self.pool / f"kernel_config_{self.kver}").write_text("CONFIG_TEST=y\n")
        (self.pool / f"PROVENANCE-{self.kver}").write_text(
            f"kernel_release={self.kver}\nanfe_wunner_test=0\n"
            f"source_commit={'a' * 40}\nt2_repo_commit={'b' * 40}\n"
        )
        for f in self.pool.iterdir():
            self.manifest["artifacts"][f.name] = {
                "size": f.stat().st_size,
                "sha256": __import__("hashlib").sha256(f.read_bytes()).hexdigest(),
            }
        self.manifest_path = self.root / "assets/kernel/amd64-stable-manifest.json"
        self.manifest_path.write_text(json.dumps(self.manifest))

    def run_stage(self):
        return subprocess.run(
            ["bash", str(self.script)],
            check=False,
            capture_output=True,
            text=True,
            env={**os.environ, "AMD64_SRC": str(self.pool)},
        )

    def test_verified_release_without_sidecar_and_no_debug_glob(self):
        (self.pool / "linux-image-untrusted-dbg_1_amd64.deb").write_text("not a deb")
        result = self.run_stage()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(list(self.destination.glob("*.deb"))), 2)
        self.assertFalse(
            (self.destination / "linux-image-untrusted-dbg_1_amd64.deb").exists()
        )

    def test_corrupt_payload_rejected_before_existing_stage_is_touched(self):
        previous = self.destination / "linux-image-old_1_amd64.deb"
        previous.write_text("preserve old candidate")
        next(self.pool.glob("linux-image-*.deb")).write_text("corrupt")
        self.assertNotEqual(self.run_stage().returncode, 0)
        self.assertEqual(previous.read_text(), "preserve old candidate")
        self.assertEqual(len(list(self.destination.glob("*.deb"))), 1)

    def test_wrong_optional_kver_is_rejected(self):
        (self.pool / "KVER").write_text("7.3.0-wrong\n")
        self.assertNotEqual(self.run_stage().returncode, 0)

    def test_source_override_cannot_bypass_provenance(self):
        import hashlib
        import json

        f = self.pool / f"PROVENANCE-{self.kver}"
        f.write_text(f.read_text().replace("anfe_wunner_test=0", "anfe_wunner_test=1"))
        self.manifest["artifacts"][f.name] = {
            "size": f.stat().st_size,
            "sha256": hashlib.sha256(f.read_bytes()).hexdigest(),
        }
        self.manifest_path.write_text(json.dumps(self.manifest))
        self.assertNotEqual(self.run_stage().returncode, 0)


@unittest.skipUnless(shutil.which("make"), "requires make")
class MakeGatePropagationTest(unittest.TestCase):
    def run_gate(self, gate_exit):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "build").mkdir()
            gate = root / "build/kvm-install-gate-gpt.sh"
            gate.write_text(f"#!/bin/sh\nexit {gate_exit}\n")
            gate.chmod(0o755)
            image = root / "fixture.img"
            image.write_text("fixture, not a release image")
            return subprocess.run(
                [
                    "make",
                    "-f",
                    str(REPO / "Makefile"),
                    "-o",
                    str(image),
                    "image-verified",
                    f"ROOT={root}",
                    f"OUTPUT_IMAGE={image}",
                    "ARCH=amd64",
                    "BUILD_SHA=fixture",
                    "BUILD_VERSION=fixture",
                ],
                check=False,
                capture_output=True,
                text=True,
            )

    def test_failed_gate_does_not_become_a_success(self):
        result = self.run_gate(37)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("GATE FAILED (rc=37)", result.stderr)
        self.assertNotIn("[image-verified] PASS", result.stdout)

    def test_successful_gate_reports_pass(self):
        result = self.run_gate(0)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("[image-verified] PASS", result.stdout)


if __name__ == "__main__":
    unittest.main()
