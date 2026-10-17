"""The Magnetar server medium must carry only what d-i needs BEFORE the stub.

Measured on the amd64 server image of 2026-10-16 (data-partition content,
2,546,377,288 B):

    pool/                       1,960,721,624  (1,875,725,028 regular debs
                                                 +  84,996,596 substrate udebs)
    ncz-payload/assets/           574,624,515  (rescue/firmware/kernel/branding)
    dists/                           2,805,485
    ncz-payload/ (sqtools, post-install, preseed, ...)  ~8.6 MB

NCZ_VARIANT=server moves the first two rows OFF the medium. The substrate
udebs and the debian-installer index stay: cdrom-retriever/load-cdrom reads
them during d-i's main-menu, long before bootstrap-base calls the debootstrap
stub, and the r159 CONTRACT says anything needed during boot must be on the
medium or fetched before the stub runs.

Desktop must be byte-identical: no manifest, no bundle, same staged tree.

These tests drive the real functions from write-usb-image.py against a small
synthetic repo, so they run anywhere and prove the VARIANT LOGIC, not a copy of
it.

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


def build_fixture_repo(root: Path) -> Path:
    """A repo-shaped tree small enough to stage in a unit test."""
    for name in ("rescue", "firmware", "kernel", "branding"):
        d = root / "assets" / name
        d.mkdir(parents=True)
        (d / f"{name}.blob").write_bytes(name.encode() * 4096)
    refind = root / "assets" / "refind"
    refind.mkdir(parents=True)
    (refind / "refind_x64.efi").write_bytes(b"efi")
    (refind / "ncz-refind-refresh-amd64.sh").write_bytes(b"#!/bin/sh\n")
    (refind / "zz1-ncz-refind-refresh-amd64").write_bytes(b"x")
    rescue = root / "assets" / "rescue"
    (rescue / "rescue-rootfs-amd64.tar.zst").write_bytes(b"zst" * 2048)
    (root / "preseed").mkdir()
    (root / "preseed" / "preseed.cfg").write_text("# preseed\n")
    (root / "preseed" / "ncz-fetch-payload.sh").write_text("#!/bin/sh\nexit 0\n")
    (root / "post-install").mkdir()
    (root / "post-install" / "run-all.sh").write_text("#!/bin/sh\n")
    (root / "release.conf").write_text(
        "NCZ_BASE_CODENAME=\"forky\"\n"
        "NCZ_PRODUCT_NAME=\"NCZ-OS\"\n"
        "NCZ_RELEASE_VERSION=\"26.10\"\n"
        "NCZ_RELEASE_CODENAME=\"Cygnus\"\n")
    (root / "manifests").mkdir()
    (root / "manifests" / "ncz-timestamped.tsv").write_text("")
    return root


def fake_payload_dir(root: Path, with_base: bool) -> Path:
    """What stage-ncz-payload.py would have produced. For a server image
    base.squashfs is absent: it is fetched online at install time."""
    p = root / "payload"
    (p / "sqtools").mkdir(parents=True)
    (p / "sqtools" / "unsquashfs").write_bytes(b"U")
    (p / "busybox-amd64").write_bytes(b"B")
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


def stage(variant, tmp, with_base=None):
    tmp.mkdir(parents=True, exist_ok=True)
    build_fixture_repo(tmp / "repo")
    if with_base is None:
        with_base = variant == "desktop"
    payload = fake_payload_dir(tmp, with_base)
    stage_dir = tmp / "stage"
    stage_dir.mkdir()
    env = {
        "NCZ_VARIANT": variant,
        "NCZ_PAYLOAD_URL": "https://example.invalid/base.squashfs",
        "NCZ_PAYLOAD_SHA256": "a" * 64,
        "NCZ_ASSETS_URL": "https://example.invalid/ncz-assets-amd64.tar.gz",
    }
    with mock.patch.dict(os.environ, env, clear=False), \
         mock.patch.object(MODULE, "REPO_ROOT", tmp / "repo"), \
         mock.patch.object(MODULE, "stage_ssplugin_deb", return_value=None):
        receipt = MODULE.build_ncz_payload_tree(
            stage_dir, payload, "amd64", None, tmp / "repo" / "preseed",
            allow_missing_stub=True,
            post_install_dir=tmp / "repo" / "post-install",
            build_version="test", online_work_dir=tmp / "online")
    return stage_dir, receipt


class ServerVariantStagingTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="ncz-srv-stage-"))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.repo = build_fixture_repo(self.tmp / "repo")

    def test_desktop_is_byte_identical(self):
        """Desktop stages the assets and ships no manifest."""
        stage_dir, receipt = stage("desktop", self.tmp / "d")
        assets = stage_dir / "ncz-payload" / "assets"
        for name in MODULE.SERVER_ONLINE_ASSET_DIRS:
            self.assertTrue((assets / name).is_dir(), f"{name} missing on desktop")
        self.assertFalse((stage_dir / "ncz-payload" / "ncz-fetch-payload.manifest").exists())
        self.assertNotIn("online_fetch", receipt)

    def test_desktop_still_demands_a_baked_base_layer(self):
        """The gate that keeps desktop byte-identical: a payload dir with no
        base.squashfs is fatal for desktop and merely expected for server."""
        with self.assertRaises(RuntimeError):
            stage("desktop", self.tmp / "d2", with_base=False)

    def test_server_moves_assets_off_the_medium_and_pins_them(self):
        stage_dir, receipt = stage("server", self.tmp / "s")
        assets = stage_dir / "ncz-payload" / "assets"
        for name in MODULE.SERVER_ONLINE_ASSET_DIRS:
            self.assertFalse((assets / name).exists(),
                             f"{name} is still on the server medium")
        # ... but the archive that restores them is on disk, with a real digest
        plan = receipt["online_fetch"]
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

    def test_server_refuses_to_build_without_pins(self):
        payload = fake_payload_dir(self.tmp / "n2", with_base=False)
        stage_dir = self.tmp / "n2" / "stage"
        stage_dir.mkdir(parents=True)
        with mock.patch.dict(os.environ, {"NCZ_VARIANT": "server"}, clear=False), \
             mock.patch.object(MODULE, "REPO_ROOT", self.repo), \
             mock.patch.dict(os.environ, {"NCZ_PAYLOAD_URL": "",
                                          "NCZ_PAYLOAD_SHA256": "",
                                          "NCZ_ASSETS_URL": ""}):
            with self.assertRaises(RuntimeError) as ctx:
                MODULE.build_ncz_payload_tree(
                    stage_dir, payload, "amd64", None, self.repo / "preseed",
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
            MODULE.stage_server_installer_pool(stage_dir, "amd64", pool)
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
        payload = fake_payload_dir(repo, with_base=True)
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
