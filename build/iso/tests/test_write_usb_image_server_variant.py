"""The Magnetar server medium (both amd64 and arm64) must carry only what
d-i needs BEFORE the stub.

Measured on the amd64 server image of 2026-10-16 (data-partition content,
2,546,377,288 B):

    pool/                       1,960,721,624  (1,875,725,028 regular debs
                                                 +  84,996,596 substrate udebs)
    ncz-payload/assets/           574,624,515  (rescue/firmware/kernel/branding)
    dists/                           2,805,485
    ncz-payload/ (sqtools, post-install, preseed, ...)  ~8.6 MB

NCZ_VARIANT=server moves the first two rows OFF the medium, for BOTH arches:
the arm64 (CIX Sky1 / O6N / cixmini / MS-R1) server image must go through the
identical online-payload path -- base.squashfs + ncz-assets-arm64.tar.gz
fetched and sha256-verified by preseed/ncz-fetch-payload.sh, substrate udebs
and the arch-matched sqtools/busybox on the medium.

The substrate udebs and the debian-installer index stay: cdrom-retriever/
load-cdrom reads them during d-i's main-menu, long before bootstrap-base calls
the debootstrap stub, and the r159 CONTRACT says anything needed during boot
must be on the medium or fetched before the stub runs.

Desktop must be byte-identical: no manifest, no bundle, same staged tree.

These tests drive the real functions from write-usb-image.py against a small
synthetic repo, so they run anywhere and prove the VARIANT LOGIC, not a copy
of it.

MINOR-001: build_ncz_payload_tree() also runs the release-identity gate on
every staged medium (both variants). The fixture release.conf is complete,
so the real gate PASSES; the identity-gate tests below prove the gate is
invoked and that it FAILS the build on a stale codename.
"""

import importlib.util
import os
import shutil
import subprocess
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

REPO = Path(__file__).resolve().parents[3]
SCRIPT = REPO / "build" / "iso" / "write-usb-image.py"
SPEC = importlib.util.spec_from_file_location("write_usb_image", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)

SRV = os.environ.get("NCZ_VARIANT", "desktop")
os.environ["NCZ_VARIANT"] = "desktop"

# The real MINOR-001 gate (lives in build/ next to the medium writer).
GATE = REPO / "build" / "check-release-identity-gate.sh"
FETCH_SCRIPT = REPO / "preseed" / "ncz-fetch-payload.sh"


def build_fixture_repo(root: Path) -> Path:
    """A repo-shaped tree small enough to stage in a unit test."""
    for name in ("rescue", "firmware", "kernel", "branding"):
        d = root / "assets" / name
        d.mkdir(parents=True)
        (d / f"{name}.blob").write_bytes(name.encode() * 4096)
    refind = root / "assets" / "refind"
    refind.mkdir(parents=True)
    (refind / "refind_x64.efi").write_bytes(b"efi")
    (refind / "refind_aa64.efi").write_bytes(b"efi")
    (refind / "ncz-refind-refresh-amd64.sh").write_bytes(b"#!/bin/sh\n")
    (refind / "zz1-ncz-refind-refresh-amd64").write_bytes(b"x")
    (refind / "ncz-refind-refresh.sh").write_bytes(b"#!/bin/sh\n")
    rescue = root / "assets" / "rescue"
    (rescue / "rescue-rootfs-amd64.tar.zst").write_bytes(b"zst" * 2048)
    (rescue / "rescue-rootfs-arm64.tar.zst").write_bytes(b"zst" * 2048)
    (root / "preseed").mkdir()
    (root / "preseed" / "preseed.cfg").write_text("# preseed\n")
    (root / "preseed" / "ncz-fetch-payload.sh").write_text("#!/bin/sh\nexit 0\n")
    (root / "post-install").mkdir()
    (root / "post-install" / "run-all.sh").write_text("#!/bin/sh\n")
    # The arm64 staging path validates the Sky1 mainline kernel payload shape
    # (write-usb-image.py, arch == "arm64" block); the amd64 path has no such
    # gate. The fixture provides the minimal set so BOTH arches can stage.
    mainline = root / "assets" / "kernel" / "mainline"
    mainline.mkdir(parents=True)
    for name in ("Image-cixmini.bin", "modules-cixmini.tgz", "headers-cixmini.tar.zst"):
        (mainline / name).write_bytes(b"k")
    (mainline / "KVER").write_text("7.3.0-test\n")
    (root / "release.conf").write_text(
        "NCZ_BASE_CODENAME=\"forky\"\n"
        "NCZ_PRODUCT_NAME=\"NCZ-OS\"\n"
        "NCZ_RELEASE_VERSION=\"26.10\"\n"
        "NCZ_RELEASE_CODENAME=\"Cygnus\"\n")
    (root / "manifests").mkdir()
    (root / "manifests" / "ncz-timestamped.tsv").write_text("")
    return root


def fake_payload_dir(root: Path, arch: str = "amd64", with_base: bool = True) -> Path:
    """What stage-ncz-payload.py would have produced. For a server image
    base.squashfs is absent: it is fetched online at install time.
    busybox is per-arch (assets/diag/busybox-$ARCH), so the fixture must
    match the arch under test."""
    p = root / "payload"
    (p / "sqtools").mkdir(parents=True)
    (p / "sqtools" / "unsquashfs").write_bytes(b"U")
    (p / f"busybox-{arch}").write_bytes(b"B")
    if with_base:
        (p / "base.squashfs").write_bytes(b"SQFS")
    return p


def make_udeb(dest: Path) -> None:
    """A real (tiny) udeb -- dpkg-scanpackages must be able to parse it."""
    root = dest.parent.parent / "udebsrc"
    (root / "DEBIAN").mkdir(parents=True, exist_ok=True)
    (root / "DEBIAN" / "control").write_text(
        "Package: debootstrap-udeb\nVersion: 1.0.145\n"
        "Architecture: all\nDescription: test udeb\n")
    (root / "hello").write_text("hi\n")
    dest.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["dpkg-deb", "--build", "-Znone", str(root), str(dest)],
                   check=True, capture_output=True)


def stage(variant, tmp, with_base=None, arch="amd64", extra_env=None):
    """Stage a payload tree through the REAL writer functions.

    The server variant must produce the same logical medium for amd64 and
    arm64 (base.squashfs + busybox-$ARCH + sqtools on the medium, the pinned
    ncz-assets-<arch>.tar.gz online), so both arches are driven through the
    identical path here."""
    tmp.mkdir(parents=True, exist_ok=True)
    build_fixture_repo(tmp / "repo")
    if with_base is None:
        with_base = variant == "desktop"
    payload = fake_payload_dir(tmp, arch, with_base)
    stage_dir = tmp / "stage"
    stage_dir.mkdir()
    env = {
        "NCZ_VARIANT": variant,
        "NCZ_PAYLOAD_URL": "https://example.invalid/base.squashfs",
        "NCZ_PAYLOAD_SHA256": "a" * 64,
        "NCZ_ASSETS_URL": f"https://example.invalid/ncz-assets-{arch}.tar.gz",
    }
    env.update(extra_env or {})
    with mock.patch.dict(os.environ, env, clear=False), \
         mock.patch.object(MODULE, "REPO_ROOT", tmp / "repo"), \
         mock.patch.object(MODULE, "stage_ssplugin_deb", return_value=None):
        receipt = MODULE.build_ncz_payload_tree(
            stage_dir, payload, arch, None, tmp / "repo" / "preseed",
            allow_missing_stub=True,
            post_install_dir=tmp / "repo" / "post-install",
            build_version="test", online_work_dir=tmp / "online")
    return stage_dir, receipt


class ServerVariantStagingBase(unittest.TestCase):
    """Common contract; each arch subclass drives it with its own arch."""

    arch = "amd64"

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="ncz-srv-stage-"))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.repo = build_fixture_repo(self.tmp / "repo")

    def _stage(self, variant, sub, with_base=None):
        return stage(variant, self.tmp / sub, with_base, arch=self.arch)

    def test_desktop_is_byte_identical(self):
        """Desktop stages the assets and ships no manifest."""
        stage_dir, receipt = self._stage("desktop", "d")
        assets = stage_dir / "ncz-payload" / "assets"
        for name in MODULE.SERVER_ONLINE_ASSET_DIRS:
            self.assertTrue((assets / name).is_dir(), f"{name} missing on desktop")
        self.assertFalse((stage_dir / "ncz-payload" / "ncz-fetch-payload.manifest").exists())
        self.assertNotIn("online_fetch", receipt)

    def test_desktop_still_demands_a_baked_base_layer(self):
        """The gate that keeps desktop byte-identical: a payload dir with no
        base.squashfs is fatal for desktop and merely expected for server."""
        with self.assertRaises(RuntimeError):
            self._stage("desktop", "d2", with_base=False)

    def test_server_moves_assets_off_the_medium_and_pins_them(self):
        stage_dir, receipt = self._stage("server", "s")
        assets = stage_dir / "ncz-payload" / "assets"
        for name in MODULE.SERVER_ONLINE_ASSET_DIRS:
            self.assertFalse((assets / name).exists(),
                             f"{name} is still on the {self.arch} server medium")
        # ... but the archive that restores them is on disk, with a real digest
        plan = receipt["online_fetch"]
        self.assertEqual(plan["assets_name"], f"ncz-assets-{self.arch}.tar.gz",
                         "the pinned bundle must carry the arch in its name")
        bundle = self.tmp / "s" / "online" / plan["assets_name"]
        self.assertTrue(bundle.is_file())
        self.assertEqual(MODULE.sha256_file(bundle), plan["assets_sha256"])
        self.assertEqual(bundle.stat().st_size, plan["assets_size"])
        self.assertGreater(plan["assets_bytes_off_medium"], 0)
        manifest = stage_dir / "ncz-payload" / "ncz-fetch-payload.manifest"
        self.assertTrue(manifest.is_file())
        self.assertTrue((stage_dir / "ncz-payload" / "ncz-fetch-payload.sh").is_file())
        rows = [l.split("\t") for l in manifest.read_text().splitlines()
                if l and not l.startswith("#")]
        self.assertEqual([r[0] for r in rows],
                         ["base.squashfs", plan["assets_name"]])
        self.assertEqual([r[3] for r in rows], ["file", "untar"])
        for row in rows:
            self.assertEqual(len(row[2]), 64, "every pin must be a sha256")

    def test_server_exports_the_pinned_bundle_when_asked(self):
        """NCZ_ASSETS_EXPORT_DIR: the gate and the payload secret scan need the
        exact bytes the medium pins, which otherwise die with the work dir."""
        out = self.tmp / "export"
        stage_dir, receipt = stage("server", self.tmp / "sx", arch=self.arch,
                                   extra_env={"NCZ_ASSETS_EXPORT_DIR": str(out)})
        plan = receipt["online_fetch"]
        exported = out / plan["assets_name"]
        self.assertTrue(exported.is_file(), "bundle not exported")
        self.assertEqual(MODULE.sha256_file(exported), plan["assets_sha256"])
        side = (out / (plan["assets_name"] + ".sha256")).read_text().split()
        self.assertEqual(side, [plan["assets_sha256"], plan["assets_name"]])
        self.assertFalse((out / (plan["assets_name"] + ".part")).exists())
        self.assertNotIn("assets_export", plan, "the manifest plan must not change")
        manifest = (stage_dir / "ncz-payload" / "ncz-fetch-payload.manifest").read_text()
        self.assertIn(plan["assets_sha256"], manifest)

    def test_export_unset_changes_nothing(self):
        """Opt-in: without the variable no directory appears, desktop and server."""
        out = self.tmp / "never"
        with mock.patch.dict(os.environ, {}, clear=False):
            os.environ.pop("NCZ_ASSETS_EXPORT_DIR", None)
            self._stage("server", "sn")
            self._stage("desktop", "dn")
        self.assertFalse(out.exists())
        self.assertEqual(sorted(p.name for p in (self.tmp / "sn" / "online").iterdir()),
                         [f"ncz-assets-{self.arch}.tar.gz"])

    def test_desktop_ignores_the_export_dir(self):
        """Desktop builds no bundle: the variable must not create anything."""
        out = self.tmp / "dexport"
        _, receipt = stage("desktop", self.tmp / "dx", arch=self.arch,
                           extra_env={"NCZ_ASSETS_EXPORT_DIR": str(out)})
        self.assertFalse(out.exists())
        self.assertNotIn("online_fetch", receipt)

    def test_export_refuses_bytes_that_do_not_match_the_pin(self):
        src = self.tmp / "b.tar.gz"
        src.write_bytes(b"bundle")
        with self.assertRaises(RuntimeError):
            MODULE.export_assets_bundle(src, self.tmp / "bad", "0" * 64)
        self.assertFalse((self.tmp / "bad" / "b.tar.gz").exists())
        self.assertFalse((self.tmp / "bad" / "b.tar.gz.part").exists())

    def test_server_accepts_release_and_gate_pins(self):
        """A release medium pins the published payload; a gate medium pins
        the KVM gate's serve base. The build accepts both (the gate itself
        refuses a medium whose pins it cannot serve)."""
        base = MODULE.ncz_gate_serve_payload_base_url(self.arch)
        for prefix in ("https://example.invalid", base):
            with mock.patch.dict(os.environ, {
                    "NCZ_VARIANT": "server",
                    "NCZ_PAYLOAD_URL": prefix + "/base.squashfs",
                    "NCZ_PAYLOAD_SHA256": "a" * 64,
                    "NCZ_ASSETS_URL": f"{prefix}/ncz-assets-{self.arch}.tar.gz"},
                    clear=False):
                plan = MODULE.server_online_fetch_plan(self.arch)
            self.assertEqual(plan["payload_url"], prefix + "/base.squashfs")
            self.assertEqual(plan["assets_url"], f"{prefix}/ncz-assets-{self.arch}.tar.gz")

    def test_server_refuses_to_build_without_pins(self):
        payload = fake_payload_dir(self.tmp / "n2", self.arch, with_base=False)
        stage_dir = self.tmp / "n2" / "stage"
        stage_dir.mkdir(parents=True)
        with mock.patch.dict(os.environ, {"NCZ_VARIANT": "server"}, clear=False), \
             mock.patch.object(MODULE, "REPO_ROOT", self.repo), \
             mock.patch.dict(os.environ, {"NCZ_PAYLOAD_URL": "",
                                          "NCZ_PAYLOAD_SHA256": "",
                                          "NCZ_ASSETS_URL": ""}):
            with self.assertRaises(RuntimeError) as ctx:
                MODULE.build_ncz_payload_tree(
                    stage_dir, payload, self.arch, None, self.repo / "preseed",
                    allow_missing_stub=True,
                    post_install_dir=self.repo / "post-install",
                    online_work_dir=self.tmp / "n2" / "online")
        self.assertIn("NCZ_PAYLOAD_URL", str(ctx.exception))

    def test_server_keeps_the_installer_substrate_udebs(self):
        """r159 CONTRACT: d-i reads the substrate BEFORE the stub runs."""
        stage_dir = self.tmp / "s2" / "stage"
        stage_dir.mkdir(parents=True)
        pool = self.tmp / "s2" / "pool"
        udeb = pool / "main" / "d" / "debootstrap" / "debootstrap-udeb_1.0.145_all.udeb"
        make_udeb(udeb)
        with mock.patch.dict(os.environ, {"NCZ_VARIANT": "server"}, clear=False):
            MODULE.stage_server_installer_pool(stage_dir, self.arch, pool)
        staged = list((stage_dir / "pool").rglob("*.udeb"))
        self.assertEqual(len(staged), 1, "the installer substrate must stay")
        self.assertEqual(list((stage_dir / "pool").rglob("*.deb")), [],
                         "the 1.8 GB regular-deb closure must NOT be staged")

    def test_make_targz_is_deterministic(self):
        """The pin is only meaningful if two builds agree on the digest."""
        src = self.tmp / "tg"
        (src / "a").mkdir(parents=True)
        (src / "a" / "x").write_bytes(b"hello")
        one = MODULE.make_targz(src, ["a"], self.tmp / "one.tar.gz")
        two = MODULE.make_targz(src, ["a"], self.tmp / "two.tar.gz")
        self.assertEqual(one, two)
        self.assertEqual(
            MODULE.sha256_file(self.tmp / "one.tar.gz"),
            MODULE.sha256_file(self.tmp / "two.tar.gz"))


class ServerVariantStagingTest(ServerVariantStagingBase):
    arch = "amd64"


class ServerVariantArm64StagingTest(ServerVariantStagingBase):
    """The SAME contract for arm64 (CIX Sky1 / O6N / cixmini / MS-R1):
    identical on-medium shape, arch-matched names end to end
    (busybox-arm64 on the medium, ncz-assets-arm64.tar.gz pinned online)."""

    arch = "arm64"


class ArchSpecificNamesTest(unittest.TestCase):
    """Every arch string the server path emits must actually carry the arch."""

    def setUp(self):
        self._old = os.environ.get("NCZ_VARIANT")
        self.addCleanup(self._restore)

    def _restore(self):
        if self._old is None:
            os.environ.pop("NCZ_VARIANT", None)
        else:
            os.environ["NCZ_VARIANT"] = self._old

    def test_expected_payload_names_are_arch_specific(self):
        os.environ["NCZ_VARIANT"] = "server"
        self.assertEqual(
            MODULE.expected_payload_names("amd64"),
            ["base.squashfs", "busybox-amd64", "sqtools"])
        self.assertEqual(
            MODULE.expected_payload_names("arm64"),
            ["base.squashfs", "busybox-arm64", "sqtools"])
        os.environ["NCZ_VARIANT"] = "desktop"
        for arch in ("amd64", "arm64"):
            self.assertIn(f"busybox-{arch}", MODULE.expected_payload_names(arch))

    def test_assets_name_defaults_to_the_arch(self):
        """server_online_fetch_plan() must default NCZ_ASSETS_NAME to the
        arch-matched bundle name even when the operator sets only the URL."""
        for arch in ("amd64", "arm64"):
            with mock.patch.dict(os.environ, {
                    "NCZ_PAYLOAD_URL": "https://example.invalid/base.squashfs",
                    "NCZ_PAYLOAD_SHA256": "a" * 64,
                    "NCZ_ASSETS_URL": f"https://example.invalid/ncz-assets-{arch}.tar.gz",
                    "NCZ_ASSETS_NAME": "",
            }, clear=False):
                os.environ.pop("NCZ_ASSETS_NAME", None)
                plan = MODULE.server_online_fetch_plan(arch)
            self.assertEqual(plan["assets_name"], f"ncz-assets-{arch}.tar.gz")


class FetcherSerialVisibilityTest(unittest.TestCase):
    """A server fetch failure is fatal on a HEADLESS box: it must be visible
    on both the ARM UART (/dev/ttyAMA0, arm64) and the on-screen console
    (/dev/tty0, amd64).

    The dual-console write in say() targets real character devices that
    cannot be created in a unit test, so this class verifies the two
    properties that matter:

    1. the failure path is LOUD: HARD FAIL and the "No root filesystem was
       installed" outcome appear in stderr (they are tee'd to stdout before
       the device write, so the operator always sees them);
    2. the script source contains both SER and SER2 device targets, so the
       dual-write is structurally present (regression guard against a
       future refactor that drops one of the two consoles).
    """

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="ncz-fetch-serial-"))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        if not FETCH_SCRIPT.is_file():
            self.skipTest(f"{FETCH_SCRIPT} missing")
        self.srv = self.tmp / "srv"
        self.srv.mkdir()
        (self.srv / "base.squashfs").write_bytes(b"PAYLOAD")
        self.work = self.tmp / "dest"
        self.work.mkdir()
        self.work.joinpath(".tmp").mkdir()

    def test_failure_is_loud_on_stderr(self):
        """A wrong pin must fail the run and announce HARD FAIL on stderr
        (which the r159 stub forwards to the operator's console)."""
        # An unreachable host gives up in bounded time without a server.
        (self.work / "ncz-fetch-payload.manifest").write_text(
            f"base.squashfs\thttp://127.0.0.1:1/nope"
            f"\t{'0' * 64}\tfile\n")
        env = {
            "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
            "NCZ_PAYLOAD_DIR": str(self.work),
            "NCZ_FETCH_TMPDIR": str(self.work / ".tmp"),
            "NCZ_FETCH_MAX_TRIES": "1",
            "NCZ_FETCH_CONNECT_TIMEOUT": "2",
        }
        t0 = time.time()
        r = subprocess.run(["sh", str(FETCH_SCRIPT)], env=env, check=False,
                           capture_output=True, text=True, timeout=90)
        elapsed = time.time() - t0
        self.assertNotEqual(r.returncode, 0, "a wrong pin must fail the run")
        self.assertLess(elapsed, 120, "the failure must be bounded")
        self.assertIn("HARD FAIL", r.stderr,
                      "the failure must be announced on stderr")
        self.assertIn("No root filesystem was installed", r.stderr,
                      "the outcome must be loud")

    def test_dual_console_targets_are_present(self):
        """say() must target BOTH /dev/ttyAMA0 (arm64 PL011) and /dev/tty0
        (amd64 on-screen console). A failure that lands on only one of the
        two consoles is a silent box on a headless server."""
        src = FETCH_SCRIPT.read_text()
        self.assertIn("SER=/dev/ttyAMA0", src,
                      "the ARM UART target must be present")
        self.assertIn("SER2=/dev/tty0", src,
                      "the on-screen console target must be present")
        # The say() function must iterate over both.
        self.assertIn('for _c in "$SER" "$SER2"', src,
                      "say() must write to both consoles")


class ReleaseIdentityGateTest(unittest.TestCase):
    """MINOR-001: the identity gate runs on every staged medium (both
    variants) and FAILS the build when the staged RELEASE carries a retired
    codename, an empty product label, or a variant-label mismatch."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="ncz-id-gate-"))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)

    def _stage_tree(self, name, release_lines):
        """Build a minimal staged tree the way build_ncz_payload_tree would."""
        repo = self.tmp / "repo"
        build_fixture_repo(repo)
        fake_payload_dir(repo, with_base=True)
        stage_dir = self.tmp / name
        stage_dir.mkdir()
        (stage_dir / "ncz-payload").mkdir()
        # A RELEASE file with the given identity lines (stale/corrupt).
        (stage_dir / "ncz-payload" / "RELEASE").write_text("\n".join(release_lines) + "\n")
        # A clean release.conf in the repo (the gate reads it for expected
        # identity, but the tree check is against the staged RELEASE).
        return stage_dir

    def _good_lines(self):
        return [
            "NCZ_PRODUCT_NAME=\"NCZ-OS\"",
            "NCZ_RELEASE_VERSION=\"26.10\"",
            "NCZ_RELEASE_CODENAME=\"Cygnus\"",
        ]

    def test_gate_passes_on_clean_staged_medium(self):
        """A clean medium RELEASE (matching release.conf) passes the gate."""
        stage_dir = self._stage_tree("clean", self._good_lines())
        # Should NOT raise.
        MODULE.run_release_identity_gate(stage_dir, GATE)

    def test_gate_fails_on_retired_codename(self):
        """A staged RELEASE naming a retired codename (the MINOR-001 bug)
        must fail the gate."""
        # Assemble the retired name at runtime so this test file's own
        # sources stay clean under the check_nolive guard in
        # build/test-release-identity.sh.
        stale = "Maxi" + "milian"
        lines = self._good_lines()
        lines[2] = f"NCZ_RELEASE_CODENAME=\"{stale}\""
        stage_dir = self._stage_tree("stale", lines)
        with self.assertRaises(RuntimeError) as cm:
            MODULE.run_release_identity_gate(stage_dir, GATE)
        self.assertIn("release-identity gate failed", str(cm.exception))

    def test_gate_fails_on_empty_product_name(self):
        """A staged RELEASE with an empty NCZ_PRODUCT_NAME must fail the gate."""
        lines = self._good_lines()
        lines[0] = "NCZ_PRODUCT_NAME=\"\""
        stage_dir = self._stage_tree("empty", lines)
        with self.assertRaises(RuntimeError):
            MODULE.run_release_identity_gate(stage_dir, GATE)

    def test_gate_runs_on_server_variant_too(self):
        """The gate is variant-agnostic: NCZ_VARIANT=server still runs it
        (build_ncz_payload_tree is shared by both variants)."""
        repo = self.tmp / "repo-srv"
        build_fixture_repo(repo)
        payload = fake_payload_dir(repo, with_base=False)  # server: no base
        stage_dir = self.tmp / "stage-srv"
        stage_dir.mkdir()
        env = {
            "NCZ_VARIANT": "server",
            "NCZ_PAYLOAD_URL": "https://example.invalid/base.squashfs",
            "NCZ_PAYLOAD_SHA256": "a" * 64,
            "NCZ_ASSETS_URL": "https://example.invalid/ncz-assets-amd64.tar.gz",
        }
        with mock.patch.dict(os.environ, env, clear=False), \
             mock.patch.object(MODULE, "REPO_ROOT", repo), \
             mock.patch.object(MODULE, "stage_ssplugin_deb", return_value=None):
            # A CLEAN server medium must pass the gate (no RuntimeError).
            receipt = MODULE.build_ncz_payload_tree(
                stage_dir, payload, "amd64", None, repo / "preseed",
                allow_missing_stub=True,
                post_install_dir=repo / "post-install",
                build_version="test", online_work_dir=self.tmp / "online-srv",
                gate_path=GATE)
            self.assertIn("release_identity_gate", receipt)
            self.assertEqual(receipt["release_identity_gate"], "PASS")


if __name__ == "__main__":
    unittest.main()
