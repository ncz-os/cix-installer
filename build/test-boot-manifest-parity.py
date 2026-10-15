#!/usr/bin/env python3
"""Parity checks between the cixmini-boot manifest entries and the NCZ ledger.

Run from the repository root:

    python3 build/test-boot-manifest-parity.py

Optionally point at another checkout with ROOT=/path/to/repo.
"""

import json
import os
import re
import unittest

ROOT = os.environ.get(
    "ROOT", os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
)

KERNEL_MANIFEST = os.path.join(ROOT, "assets", "kernel-manifest.json")
SKY1_MANIFEST = os.path.join(ROOT, "assets", "kernel", "sky1-manifest.json")
LEDGER = os.path.join(ROOT, "manifests", "ncz-packages.tsv")

BOOT_NAME = "cixmini-boot"
BOOT_ARCH = "arm64"


def load_json(path):
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle)


def load_ledger(path):
    rows = {}
    with open(path, "r", encoding="utf-8") as handle:
        for line in handle:
            line = line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            fields = line.split("\t")
            if len(fields) < 4:
                continue
            rows[fields[0]] = {
                "name": fields[0],
                "version": fields[1],
                "arch": fields[2],
                "sha256": fields[3],
            }
    return rows


def boot_entry_from_kernel_manifest(manifest):
    for entry in manifest["kernel_debs"]:
        if os.path.basename(entry["file"]).startswith(BOOT_NAME + "_"):
            return entry
    raise AssertionError(f"no {BOOT_NAME} entry in kernel manifest")


def boot_entry_from_sky1_manifest(manifest):
    return manifest["debs"][BOOT_NAME]


def version_from_deb_path(path):
    """Extract the version encoded in a deb filename like name_VER_arch.deb."""
    base = os.path.basename(path)
    match = re.match(r"^[^_]+_(.+)_[^_]+\.deb$", base)
    if not match:
        raise AssertionError(f"cannot parse version from deb path {path!r}")
    return match.group(1)


def check_kernel_boot_entry(entry, version, sha256, path):
    """Kernel-manifest entries carry only file+sha256; version lives in the path."""
    if entry.get("file") != path:
        raise AssertionError("boot path {!r} != {!r}".format(entry.get("file"), path))
    if version_from_deb_path(entry["file"]) != version:
        raise AssertionError(
            "boot path version {!r} != {!r}".format(
                version_from_deb_path(entry["file"]), version
            )
        )
    if entry.get("sha256") != sha256:
        raise AssertionError(
            "boot sha256 {!r} != {!r}".format(entry.get("sha256"), sha256)
        )


def check_sky1_boot_entry(entry, version, sha256):
    """Sky1-manifest entries carry version+sha256 (no file path)."""
    if entry.get("version") != version:
        raise AssertionError(
            "boot version {!r} != {!r}".format(entry.get("version"), version)
        )
    if entry.get("sha256") != sha256:
        raise AssertionError(
            "boot sha256 {!r} != {!r}".format(entry.get("sha256"), sha256)
        )


class BootManifestParityTest(unittest.TestCase):
    def setUp(self):
        self.ledger = load_ledger(LEDGER)
        self.assertIn(BOOT_NAME, self.ledger)
        self.row = self.ledger[BOOT_NAME]
        self.version = self.row["version"]
        self.sha256 = self.row["sha256"]
        self.arch = self.row["arch"]
        self.path = f"build/kernel-debs/{BOOT_NAME}_{self.version}_{self.arch}.deb"

    def test_ledger_row_is_consistent(self):
        self.assertEqual(self.row["arch"], BOOT_ARCH)
        self.assertTrue(self.version)
        self.assertTrue(self.sha256)

    def test_kernel_manifest_matches_ledger(self):
        manifest = load_json(KERNEL_MANIFEST)
        entry = boot_entry_from_kernel_manifest(manifest)
        self.assertNotIn("version", entry)
        check_kernel_boot_entry(entry, self.version, self.sha256, self.path)

    def test_sky1_manifest_matches_ledger(self):
        manifest = load_json(SKY1_MANIFEST)
        entry = boot_entry_from_sky1_manifest(manifest)
        check_sky1_boot_entry(entry, self.version, self.sha256)

    def test_kernel_manifest_mutations_are_rejected(self):
        manifest = load_json(KERNEL_MANIFEST)
        entry = boot_entry_from_kernel_manifest(manifest)
        check_kernel_boot_entry(entry, self.version, self.sha256, self.path)

        bad_hash = dict(entry)
        bad_hash["sha256"] = "0" * 64
        with self.assertRaises(AssertionError):
            check_kernel_boot_entry(bad_hash, self.version, self.sha256, self.path)

        bad_path = dict(entry)
        bad_path["file"] = f"build/kernel-debs/{BOOT_NAME}_0.0+r0_{self.arch}.deb"
        with self.assertRaises(AssertionError):
            check_kernel_boot_entry(bad_path, self.version, self.sha256, self.path)

        # Version encoded in the path must match the ledger version.
        with self.assertRaises(AssertionError):
            check_kernel_boot_entry(entry, "0.0+r0", self.sha256, self.path)

    def test_sky1_manifest_mutations_are_rejected(self):
        manifest = load_json(SKY1_MANIFEST)
        entry = boot_entry_from_sky1_manifest(manifest)
        check_sky1_boot_entry(entry, self.version, self.sha256)

        bad_version = dict(entry)
        bad_version["version"] = "0.0+r0"
        with self.assertRaises(AssertionError):
            check_sky1_boot_entry(bad_version, self.version, self.sha256)

        bad_hash = dict(entry)
        bad_hash["sha256"] = "0" * 64
        with self.assertRaises(AssertionError):
            check_sky1_boot_entry(bad_hash, self.version, self.sha256)


if __name__ == "__main__":
    unittest.main()
