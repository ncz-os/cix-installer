"""Network firmware in the d-i initrd (manifests/net-firmware.tsv).

Offline: fixture firmware-*.deb packages are built with dpkg-deb in a temp
dir. Set NCZ_FIRMWARE_POOL to an offline mirror pool (build/forky-mirror/pool)
to also check the table against the REAL firmware-realtek/firmware-mediatek
packages the medium carries.
"""

import importlib.util
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
SCRIPT = REPO / "build" / "iso" / "patch-initrd-t2-kernel.py"
TABLE = REPO / "manifests" / "net-firmware.tsv"
BOM = REPO / "manifests" / "firmware.pkgs"
BUILDER = REPO / "build" / "build-installer-image.sh"
SPEC = importlib.util.spec_from_file_location("patch_initrd_t2_kernel", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)

HAVE_DPKG = shutil.which("dpkg-deb") is not None and shutil.which("dpkg") is not None

# The blobs real hardware asked for and did not get (2026-10-06 logs).
LOGGED_MISSING = [
    "rtl_nic/rtl8127a-1.fw",  # MS-R1, r8169
    "rtl_nic/rtl8125b-2.fw",  # O6N, r8169
    "rtl_nic/rtl8168h-2.fw",  # PEGASUS, r8169
    "mediatek/BT_RAM_CODE_MT7922_1_1_hdr.bin",  # MS-R1, btusb/btmtk
    "i915/mtl_dmc.bin",  # PROTEUS Arrow Lake, i915 display
]


def build_deb(root: Path, package: str, version: str, files: dict) -> Path:
    tree = root / f"{package}-{version}-tree"
    (tree / "DEBIAN").mkdir(parents=True)
    (tree / "DEBIAN" / "control").write_text(
        f"Package: {package}\nVersion: {version}\nArchitecture: all\n"
        f"Maintainer: test <test@example.invalid>\nDescription: fixture\n"
    )
    for rel, data in files.items():
        dst = tree / "usr" / "lib" / "firmware" / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        dst.write_bytes(data)
    pool = root / "pool" / "main"
    pool.mkdir(parents=True, exist_ok=True)
    deb = pool / f"{package}_{version}_all.deb"
    subprocess.run(
        ["dpkg-deb", "--root-owner-group", "-Zgzip", "-b", str(tree), str(deb)],
        check=True,
        stdout=subprocess.DEVNULL,
    )
    return deb


INTEL_GFX_FILES = {
    "i915/mtl_dmc.bin": b"mtl-dmc",  # PROTEUS Arrow Lake (7d67), 2026-10-10
    "i915/tgl_dmc_ver2_12.bin": b"tgl-dmc",
    # Meteor/Arrow Lake also need GuC/HuC/GSC for a clean GT init: without them
    # i915 "declares it wedged" during the installer (PROTEUS 2026-10-10) and the
    # display is degraded, so they belong in the initrd too.
    "i915/mtl_guc_70.bin": b"guc-in-initrd",
    "i915/mtl_huc_gsc.bin": b"huc-in-initrd",
    "i915/mtl_gsc_1.bin": b"gsc-in-initrd",
}

REALTEK_FILES = {
    "rtl_nic/rtl8127a-1.fw": b"8127a",
    "rtl_nic/rtl8125b-2.fw": b"8125b",
    "rtl_nic/rtl8126a-3.fw": b"8126a",
    "rtl_nic/rtl8168h-2.fw": b"8168h",
    "rtl_nic/rtl8153a-4.fw": b"8153a",
    "rtl_nic/rtl8156b-2.fw": b"8156b",
    "rtw89/rtw8852b_fw.bin": b"wifi",
    "rtw88/rtw8822c_fw.bin": b"wifi",
    "rtl_bt/rtl8852bu_fw.bin": b"bt",
}
MEDIATEK_FILES = {
    "mediatek/BT_RAM_CODE_MT7922_1_1_hdr.bin": b"bt7922",
    "mediatek/BT_RAM_CODE_MT7961_1_2_hdr.bin": b"bt7961",
    "mediatek/WIFI_RAM_CODE_MT7922_1.bin": b"wifi",
    "mediatek/WIFI_MT7922_patch_mcu_1_1_hdr.bin": b"wifi",
    "mediatek/WIFI_RAM_CODE_MT7961_1.bin": b"wifi",
    "mediatek/WIFI_MT7961_patch_mcu_1_2_hdr.bin": b"wifi",
    "mediatek/mt7925/WIFI_RAM_CODE_MT7925_1_1.bin": b"wifi",
}


def bom_packages() -> set:
    return {
        l.split()[0]
        for l in BOM.read_text().splitlines()
        if l.strip() and not l.lstrip().startswith("#")
    }


class NetFirmwareTableTest(unittest.TestCase):
    def setUp(self):
        self.rows = MODULE.load_net_firmware_table(TABLE)

    def test_every_package_is_seeded_and_installed_by_the_bom(self):
        # firmware.pkgs seeds the offline mirror and 13-firmware-bom installs it.
        missing = sorted({r["package"] for r in self.rows} - bom_packages())
        self.assertEqual(
            missing,
            [],
            f"net-firmware.tsv packages absent from firmware.pkgs: {missing}",
        )

    def test_initrd_rows_cover_every_realtek_nic_blob_and_mt79_bt(self):
        initrd = {
            (r["package"], g) for r in self.rows if r["initrd"] for g in r["globs"]
        }
        self.assertIn(("firmware-realtek", "rtl_nic/*"), initrd)
        self.assertIn(("firmware-mediatek", "mediatek/BT_RAM_CODE_MT7922_*"), initrd)

    def test_drivers_we_ship_have_a_row(self):
        drivers = " ".join(r["driver"] for r in self.rows)
        for drv in (
            "r8169",
            "r8152",
            "mt7921e",
            "mt7925e",
            "btmtk",
            "rtw89",
            "rtw88",
            "btrtl",
            "iwlwifi",
            "brcmfmac",
            "ath10k",
            "ath11k",
            "ath12k",
        ):
            self.assertIn(drv, drivers, f"no net-firmware.tsv row for {drv}")

    def test_malformed_row_fails_closed(self):
        with tempfile.TemporaryDirectory() as td:
            bad = Path(td) / "t.tsv"
            bad.write_text("dev\tr8169\tfirmware-realtek\trtl_nic/*\n")
            with self.assertRaisesRegex(RuntimeError, "5 non-empty"):
                MODULE.load_net_firmware_table(bad)
            bad.write_text("dev\tr8169\tfirmware-realtek\t/abs/*\ttarget\n")
            with self.assertRaisesRegex(RuntimeError, "relative"):
                MODULE.load_net_firmware_table(bad)


class BuilderWiringTest(unittest.TestCase):
    def test_installer_image_builder_passes_the_firmware_pool(self):
        text = BUILDER.read_text()
        self.assertTrue(
            "--firmware-pool" in text,
            "build-installer-image.sh does not pass --firmware-pool",
        )
        self.assertTrue(
            "manifests/net-firmware.tsv" in text,
            "build-installer-image.sh does not pass net-firmware.tsv",
        )


@unittest.skipUnless(HAVE_DPKG, "dpkg-deb not available")
class StageInitrdFirmwareTest(unittest.TestCase):
    def setUp(self):
        self._td = tempfile.TemporaryDirectory()
        self.root = Path(self._td.name)
        build_deb(self.root, "firmware-realtek", "20260810-1", REALTEK_FILES)
        build_deb(self.root, "firmware-mediatek", "20260810-1", MEDIATEK_FILES)
        build_deb(self.root, "firmware-intel-graphics", "20260810-1", INTEL_GFX_FILES)
        self.pool = self.root / "pool"
        self.rows = MODULE.load_net_firmware_table(TABLE)

    def tearDown(self):
        self._td.cleanup()

    def stage(self, rows=None):
        dest = self.root / "overlay"
        staged = MODULE.stage_initrd_firmware(
            rows or self.rows, self.pool, dest, self.root / "scratch"
        )
        return dest, {s["path"] for s in staged}

    def test_all_rtl_nic_and_mt79_bt_land_in_lib_firmware(self):
        dest, paths = self.stage()
        want = {p for p in REALTEK_FILES if p.startswith("rtl_nic/")} | {
            "mediatek/BT_RAM_CODE_MT7922_1_1_hdr.bin",
            "mediatek/BT_RAM_CODE_MT7961_1_2_hdr.bin",
            "i915/mtl_dmc.bin",
            "i915/tgl_dmc_ver2_12.bin",
            "i915/mtl_guc_70.bin",
            "i915/mtl_huc_gsc.bin",
            "i915/mtl_gsc_1.bin",
        }
        self.assertEqual(paths, want)
        for p in LOGGED_MISSING:
            self.assertEqual(
                (dest / "lib" / "firmware" / p).read_bytes(),
                (REALTEK_FILES | MEDIATEK_FILES | INTEL_GFX_FILES)[p],
            )
        # never a usr/ tree in the overlay: the base initrd owns /lib layout
        self.assertFalse((dest / "usr").exists())

    def test_wifi_blobs_stay_target_only(self):
        _, paths = self.stage()
        self.assertFalse(
            any(
                "WIFI" in p or p.startswith(("rtw8", "rtl_bt/", "mediatek/mt7925"))
                for p in paths
            ),
            paths,
        )

    def test_newest_version_wins(self):
        build_deb(
            self.root,
            "firmware-realtek",
            "20250101-1",
            {"rtl_nic/rtl8127a-1.fw": b"old"},
        )
        dest, _ = self.stage()
        self.assertEqual(
            (dest / "lib" / "firmware" / "rtl_nic" / "rtl8127a-1.fw").read_bytes(),
            b"8127a",
        )

    def test_glob_with_no_match_fails(self):
        rows = [
            {
                "device": "x",
                "driver": "r8169",
                "package": "firmware-realtek",
                "globs": ["rtl_nic/rtl9999*"],
                "initrd": True,
            }
        ]
        with self.assertRaisesRegex(RuntimeError, "no firmware matching"):
            self.stage(rows)

    def test_missing_package_fails(self):
        rows = [
            {
                "device": "x",
                "driver": "iwlwifi",
                "package": "firmware-iwlwifi",
                "globs": ["iwlwifi-*"],
                "initrd": True,
            }
        ]
        with self.assertRaisesRegex(RuntimeError, "not found under"):
            self.stage(rows)


REAL_POOL = os.environ.get("NCZ_FIRMWARE_POOL")


@unittest.skipUnless(
    HAVE_DPKG and REAL_POOL, "set NCZ_FIRMWARE_POOL to a real offline mirror pool"
)
class RealPoolTest(unittest.TestCase):
    def test_initrd_carries_every_rtl_nic_blob_firmware_realtek_ships(self):
        pool = Path(REAL_POOL)
        deb = MODULE.find_pool_deb(pool, "firmware-realtek")
        listing = subprocess.run(
            ["dpkg-deb", "-c", str(deb)], check=True, capture_output=True, text=True
        ).stdout
        shipped = set()
        for line in listing.splitlines():
            name = line.split()[-1]
            if line.startswith("-") and "/usr/lib/firmware/rtl_nic/" in name:
                shipped.add(name.split("/usr/lib/firmware/", 1)[1])
        self.assertTrue(shipped)
        with tempfile.TemporaryDirectory() as td:
            staged = MODULE.stage_initrd_firmware(
                MODULE.load_net_firmware_table(TABLE),
                pool,
                Path(td) / "o",
                Path(td) / "s",
            )
        paths = {s["path"] for s in staged}
        self.assertEqual({p for p in paths if p.startswith("rtl_nic/")}, shipped)
        for p in LOGGED_MISSING:
            self.assertIn(p, paths)
        print(
            f"\n    real pool: {len(staged)} files, "
            f"{sum(s['size'] for s in staged)} bytes"
        )

    def test_every_table_glob_matches_the_real_packages(self):
        # target rows too: a renamed blob must break this, not the user's radio
        rows = [dict(r, initrd=True) for r in MODULE.load_net_firmware_table(TABLE)]
        with tempfile.TemporaryDirectory() as td:
            MODULE.stage_initrd_firmware(
                rows, Path(REAL_POOL), Path(td) / "o", Path(td) / "s"
            )


if __name__ == "__main__":
    unittest.main()
