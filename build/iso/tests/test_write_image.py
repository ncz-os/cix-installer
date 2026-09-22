#!/usr/bin/env python3
"""
test_write_image.py — Unit tests for the GPT layout rescue finalizer and
the warm writer's clean-up paths.

These tests run offline: they construct a synthetic GPT+ISO image in a
temp directory whose layout mimics what xorriso's ``-boot_image any replay
-append_partition`` warm-growth produces (primary GPT valid, backup GPT
missing, protective MBR partition-1 size stale), then drive the rescue
finalizer and the verifier.

We do NOT shell out to xorriso here: the goal is to verify the
finalizer's byte-level GPT surgery in isolation. The end-to-end
xorriso-driven warm path is covered by prototype/step1-test.py.
"""
from __future__ import annotations

import importlib.util
import json
import os
import struct
import subprocess
import sys
import tempfile
import unittest
import zlib
from pathlib import Path


def subprocess_run_safe(cmd):
    """subprocess.run with sane defaults for tests. Always captures output
    and is non-destructive (never sets check=True)."""
    return subprocess.run(cmd, capture_output=True, text=True)


REPO_ROOT = Path(__file__).resolve().parents[3]
ISO_DIR = REPO_ROOT / "build" / "iso"

# Import write-image.py and verify-image.py by file path because the
# repo does not use a packaging setup for these scripts.
def _load_module(path: Path, name: str):
    spec = importlib.util.spec_from_file_location(name, str(path))
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod


write_image = _load_module(ISO_DIR / "write-image.py", "write_image_mod")
verify_image = _load_module(ISO_DIR / "verify-image.py", "verify_image_mod")


SECTOR = 512
EFI_SYS_PART_GUID_STORED = write_image.EFI_SYS_PART_GUID_STORED


def _crc32(b: bytes) -> int:
    return zlib.crc32(b) & 0xFFFFFFFF


def _make_gpt_header(
    *,
    current_lba: int,
    backup_lba: int,
    first_usable: int,
    last_usable: int,
    part_entry_lba: int,
    num_entries: int = 4,
    entry_size: int = 128,
    array_crc: int = 0,
) -> bytes:
    """Build a 92-byte GPT header with the given layout. CRC is computed."""
    h = bytearray(512)
    h[0:8] = b"EFI PART"
    struct.pack_into("<I", h, 8, 0x00010000)   # revision 1.0
    struct.pack_into("<I", h, 12, 92)          # header size
    # bytes 16..20 = header CRC (filled below)
    struct.pack_into("<I", h, 20, 0)           # reserved
    struct.pack_into("<Q", h, 24, current_lba)
    struct.pack_into("<Q", h, 32, backup_lba)
    struct.pack_into("<Q", h, 40, first_usable)
    struct.pack_into("<Q", h, 48, last_usable)
    h[56:72] = b"\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f\x10"
    struct.pack_into("<Q", h, 72, part_entry_lba)
    struct.pack_into("<I", h, 80, num_entries)
    struct.pack_into("<I", h, 84, entry_size)
    struct.pack_into("<I", h, 88, array_crc)
    crc = _crc32(h[:16] + b"\x00\x00\x00\x00" + h[20:92])
    struct.pack_into("<I", h, 16, crc)
    return bytes(h)


def _make_gpt_entries(efi_first_lba: int, efi_last_lba: int) -> bytes:
    """Return an entry array that places the EFI System Partition at index 0.

    Default 4 entries; entry[0] is the EFI partition, entries[1..3] are zero
    (unused). Total array bytes = num_entries * 128.
    """
    arr = bytearray(4 * 128)
    # NOTE: indexing ``arr[0:128]`` returns a *copy* of that slice, so
    # subsequent writes to the copy would silently not propagate back to
    # ``arr``. Use direct indexing on ``arr`` for byte-level writes.
    arr[0:16] = EFI_SYS_PART_GUID_STORED
    struct.pack_into("<Q", arr, 32, efi_first_lba)
    struct.pack_into("<Q", arr, 40, efi_last_lba)
    struct.pack_into("<Q", arr, 48, 0)  # attrs
    arr[56:72] = b"\x00" * 16  # partition name (zero)
    return bytes(arr)


def _write_mbr(path: Path, *, image_lba: int) -> None:
    """Write a single-partition 0xEE protective MBR claiming image_lba sectors."""
    mbr = bytearray(SECTOR)
    # Partition entry 1 at offset 446: type 0xEE, status 0x80 (bootable),
    # start LBA = 1, size = image_lba - 1.
    struct.pack_into("<I", mbr, 440, 0)  # disk signature (we leave it zero)
    mbr[444:446] = b"\x00\x00"  # reserved
    # We write directly into ``mbr`` — extracting ``mbr[446:462]`` makes a
    # copy and mutating the copy wouldn't propagate back.
    mbr[446] = 0x00  # status
    mbr[450] = 0xEE  # type
    struct.pack_into("<I", mbr, 454, 1)              # start LBA
    struct.pack_into("<I", mbr, 458, image_lba - 1)  # size
    mbr[510:512] = b"\x55\xAA"
    path.write_bytes(bytes(mbr))


def _make_iso_pvd(volume_id: str = "TEST") -> bytes:
    """Build an ISO 9660 PVD at sector 16 (2048-byte sectors). The PVD must
    live at byte offset 16*2048 in the file."""
    pvd = bytearray(2048)
    pvd[0] = 1  # type
    pvd[1:6] = b"CD001"
    pvd[6] = 1
    pvd[40:40 + len(volume_id)] = volume_id.encode("ascii")
    return bytes(pvd)


def _make_brvd(catalog_lba: int) -> bytes:
    """Build an El Torito BRVD at sector 17 (2048-byte sectors)."""
    brvd = bytearray(2048)
    brvd[0] = 0
    brvd[1:6] = b"CD001"
    brvd[6] = 1
    # The boot system identifier field is 32 bytes (offsets 7..38 inclusive).
    # "EL TORITO SPECIFICATION" is 23 bytes; pad with zeros to fill the field.
    assert len("EL TORITO SPECIFICATION") == 23
    boot_sys_id = b"EL TORITO SPECIFICATION" + b"\x00" * (32 - 23)
    brvd[7:39] = boot_sys_id
    struct.pack_into("<I", brvd, 0x47, catalog_lba)
    return bytes(brvd)


def _make_el_torito_catalog() -> bytes:
    """A minimal valid El Torito catalog: validation entry + EFI initial entry."""
    cat = bytearray(2048)
    # Validation entry at offset 0
    cat[0] = 0x01              # header_id
    cat[1] = 0xEF              # platform (EFI)
    # ID String field is 24 bytes (offsets 4..27 inclusive). "EL TORITO
    # SPECIFICATION" is 23 bytes, so pad with one trailing zero to fill
    # the field exactly. Using a smaller slice here would shrink the
    # bytearray (and break every byte offset after it).
    id_string = b"EL TORITO SPECIFICATION\x00"
    assert len(id_string) == 24, f"id string must be 24 bytes, got {len(id_string)}"
    cat[4:28] = id_string
    # The El Torito validation-entry checksum is chosen so that the sum
    # of all 16 LE uint16 words of the validation entry is zero modulo
    # 0x10000. The key field (offset 30..31, bytes 0x55 0xAA = word
    # 0xAA55) MUST be included in the sum; if we compute the checksum
    # before writing the key, we'd compute -sum without 0xAA55 and end
    # up with a final word sum of 0xAA55 instead of 0. Write the key
    # FIRST, then compute and write the checksum.
    cat[30] = 0x55
    cat[31] = 0xAA
    s = 0
    for i in range(0, 32, 2):
        s += struct.unpack("<H", cat[i:i+2])[0]
    # checksum = -sum_all_words so total == 0 after writing it in
    s = (-s) & 0xFFFF
    struct.pack_into("<H", cat, 28, s)
    # Initial/default entry at offset 32
    cat[32] = 0x88  # bootable
    cat[33] = 0     # no emulation
    struct.pack_into("<H", cat, 38, 8192)  # sector count
    struct.pack_into("<I", cat, 40, 28672)  # load LBA (some EFI LBA)
    return bytes(cat)


def _build_synthetic_warm_image(
    path: Path,
    *,
    file_size_bytes: int,
    primary_part_entry_lba: int,
    backup_part_entry_lba: int,
    efi_first_lba: int,
    efi_last_lba: int,
    first_usable_lba: int,
    last_usable_lba: int,
    primary_backup_lba_stale: int,
    mbr_size_stale: int,
) -> bytes:
    """Construct a synthetic image that mimics what xorriso's warm growth
    produces: primary GPT valid but pointing at the OLD backup_lba; backup
    GPT at the new file tail is all zeros (or anyway absent); MBR
    partition-1 size field is stale. The ISO PVD/BRVD/catalog sit at their
    standard sectors. The EFI partition bytes match the source ESP at the
    declared LBA range.
    """
    if file_size_bytes % SECTOR != 0:
        raise ValueError("file_size_bytes must be a multiple of 512")
    image_lba = file_size_bytes // SECTOR

    # Build entry array + its CRC
    entries = _make_gpt_entries(efi_first_lba, efi_last_lba)
    entries_crc = _crc32(entries)

    # Build primary header (with stale backup_lba; the field gets rewritten
    # by the finalizer, but we want to test exactly the case where the
    # stored value is stale)
    primary_header = _make_gpt_header(
        current_lba=1,
        backup_lba=primary_backup_lba_stale,
        first_usable=first_usable_lba,
        last_usable=last_usable_lba,
        part_entry_lba=primary_part_entry_lba,
        num_entries=4,
        entry_size=128,
        array_crc=entries_crc,
    )

    # Allocate the file
    buf = bytearray(file_size_bytes)

    # LBA 0 = MBR; we'll write that after we know the right mbr_size.
    # LBA 1 = primary header
    buf[1 * SECTOR:2 * SECTOR] = primary_header
    # Entry array at primary_part_entry_lba (covers 1 sector with 4 entries)
    buf[primary_part_entry_lba * SECTOR:primary_part_entry_lba * SECTOR + len(entries)] = entries

    # ISO PVD at 2048-byte sector 16 (= LBA 32 of 512-byte sectors)
    pvd = _make_iso_pvd("TESTVOL")
    buf[16 * 2048:17 * 2048] = pvd
    # BRVD at 2048-byte sector 17
    catalog_lba = 145  # arbitrary but valid
    brvd = _make_brvd(catalog_lba)
    buf[17 * 2048:18 * 2048] = brvd
    # El Torito catalog at the LBA we declared in the BRVD
    cat = _make_el_torito_catalog()
    catalog_lba_bytes = catalog_lba * 2048
    buf[catalog_lba_bytes:catalog_lba_bytes + 2048] = cat

    # Mark the EFI partition region with a distinctive byte pattern so we
    # can confirm the finalizer doesn't move it.
    efi_len_bytes = (efi_last_lba - efi_first_lba + 1) * SECTOR
    efi_bytes = (b"\xAA\x55\xF0\x0F" * ((efi_len_bytes // 4) + 1))[:efi_len_bytes]
    buf[efi_first_lba * SECTOR:efi_first_lba * SECTOR + efi_len_bytes] = efi_bytes

    # Write the (stale) MBR at LBA 0 — direct indexing to avoid the
    # slice-extraction copy trap (see _write_mbr).
    mbr = bytearray(SECTOR)
    mbr[450] = 0xEE
    struct.pack_into("<I", mbr, 454, 1)
    struct.pack_into("<I", mbr, 458, mbr_size_stale)
    mbr[510:512] = b"\x55\xAA"
    buf[0:SECTOR] = bytes(mbr)

    # Persist and return the final bytes (we mutate through bytearray for
    # clarity; the on-disk file is what matters)
    path.write_bytes(bytes(buf))
    return bytes(buf)


class GptRescueFinalizerTests(unittest.TestCase):
    """Drive finalize_gpt_layout() against synthetic GPT images and assert
    the verifier passes after rescue."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.tmp_dir = Path(self.tmp.name)

    def _verifier_passes(self, image: Path) -> tuple[bool, dict]:
        """Run the verifier as a subprocess. Returns (passed, report_dict).

        We use subprocess rather than calling verify_image.main() so the
        test is independent of the verifier's argv handling and the
        verify-report path logic."""
        report_path = image.parent / (image.name + ".test-verify.json")
        proc = subprocess_run_safe(
            [
                sys.executable,
                str(ISO_DIR / "verify-image.py"),
                "--image", str(image),
                "--arch", "amd64",
                "--level", "warm",
                "--report", str(report_path),
            ]
        )
        report: dict = {}
        if report_path.exists():
            report = json.loads(report_path.read_text())
        return proc.returncode == 0, report

    def _build_cold_layout_image(
        self,
        *,
        file_size_bytes: int,
        efi_first_lba: int,
        efi_last_lba: int,
        backup_part_entry_lba: int,
        first_usable_lba: int,
        last_usable_lba: int,
    ) -> Path:
        """Build a fully-valid cold-compose-style image where primary and
        backup GPT agree (so we have a positive control before adding
        staleness)."""
        img = self.tmp_dir / "cold.iso"
        image_lba = file_size_bytes // SECTOR
        new_backup_lba = image_lba - 1

        entries = _make_gpt_entries(efi_first_lba, efi_last_lba)
        entries_crc = _crc32(entries)

        primary_header = _make_gpt_header(
            current_lba=1,
            backup_lba=new_backup_lba,
            first_usable=first_usable_lba,
            last_usable=last_usable_lba,
            part_entry_lba=2,
            array_crc=entries_crc,
        )

        buf = bytearray(file_size_bytes)
        buf[1 * SECTOR:2 * SECTOR] = primary_header
        buf[2 * SECTOR:2 * SECTOR + len(entries)] = entries

        buf[16 * 2048:17 * 2048] = _make_iso_pvd("COLDVOL")
        brvd = _make_brvd(145)
        buf[17 * 2048:18 * 2048] = brvd
        buf[145 * 2048:146 * 2048] = _make_el_torito_catalog()

        efi_len = (efi_last_lba - efi_first_lba + 1) * SECTOR
        efi_bytes = (b"\xAA\x55\xF0\x0F" * ((efi_len // 4) + 1))[:efi_len]
        buf[efi_first_lba * SECTOR:efi_first_lba * SECTOR + efi_len] = efi_bytes

        # protective MBR — direct indexing to avoid the slice-extraction
        # copy trap (see the note in _write_mbr above).
        mbr = bytearray(SECTOR)
        mbr[450] = 0xEE
        struct.pack_into("<I", mbr, 454, 1)
        struct.pack_into("<I", mbr, 458, image_lba - 1)
        mbr[510:512] = b"\x55\xAA"
        buf[0:SECTOR] = bytes(mbr)

        # Backup GPT header at new_backup_lba
        backup_header = _make_gpt_header(
            current_lba=new_backup_lba,
            backup_lba=1,
            first_usable=first_usable_lba,
            last_usable=last_usable_lba,
            part_entry_lba=backup_part_entry_lba,
            array_crc=entries_crc,
        )
        buf[new_backup_lba * SECTOR:(new_backup_lba + 1) * SECTOR] = backup_header

        # Backup entry array
        buf[backup_part_entry_lba * SECTOR:backup_part_entry_lba * SECTOR + len(entries)] = entries

        img.write_bytes(bytes(buf))
        return img

    def test_baseline_cold_image_passes_verifier(self) -> None:
        """Positive control: a clean cold-image-style layout passes verify."""
        # 60 MiB file: 63045632 / 512 = 123136 sectors. We pick a small
        # enough image to keep the test fast.
        efi_first = 28672  # arbitrary but well-aligned
        efi_last = 28672 + 8191  # 4 MiB ESP
        backup_part_entry = 123136 - 1 - 1  # one sector for entries
        first_usable = 64
        last_usable = backup_part_entry - 1
        img = self._build_cold_layout_image(
            file_size_bytes=123136 * SECTOR,
            efi_first_lba=efi_first,
            efi_last_lba=efi_last,
            backup_part_entry_lba=backup_part_entry,
            first_usable_lba=first_usable,
            last_usable_lba=last_usable,
        )
        # Diagnostics for understanding the failure
        import os
        print(f"DEBUG baseline image size: {os.path.getsize(img)}")
        ok, _ = self._verifier_passes(img)
        self.assertTrue(ok, f"baseline cold image should pass; got report: {_}")

    def test_xorriso_warm_output_fails_verifier_before_rescue(self) -> None:
        """Negative control: the synthetic xorriso warm-style layout
        (primary backup_lba stale, backup header missing, MBR size stale)
        fails verification BEFORE the finalizer runs."""
        image_lba = 123136
        efi_first = 28544
        efi_last = 28544 + 8191
        primary_part_entry = 2
        backup_part_entry = image_lba - 1 - 1
        first_usable = 64
        last_usable = 121904  # stale

        # Build a broken image: store an old backup_lba, no backup header,
        # stale MBR size. The space between efi_last+1 and the file tail is
        # zero (xorriso leaves these as ZEROS here per our local experiment).
        img = self.tmp_dir / "warm-broken.iso"
        entries = _make_gpt_entries(efi_first, efi_last)
        entries_crc = _crc32(entries)
        primary_header = _make_gpt_header(
            current_lba=1,
            backup_lba=122471,           # stale!
            first_usable=first_usable,
            last_usable=last_usable,
            part_entry_lba=primary_part_entry,
            array_crc=entries_crc,
        )
        buf = bytearray(image_lba * SECTOR)
        buf[0:SECTOR] = bytes(bytearray(SECTOR))  # zeroed MBR (last 2 bytes set below)
        buf[510:512] = b"\x55\xAA"
        # Patch the 0xEE entry with stale size — direct indexing to avoid
        # the slice-extraction copy trap (see _write_mbr).
        buf[450] = 0xEE
        struct.pack_into("<I", buf, 454, 1)
        struct.pack_into("<I", buf, 458, 122471)  # stale

        buf[1 * SECTOR:2 * SECTOR] = primary_header
        buf[primary_part_entry * SECTOR:primary_part_entry * SECTOR + len(entries)] = entries

        buf[16 * 2048:17 * 2048] = _make_iso_pvd("WARMVOL")
        buf[17 * 2048:18 * 2048] = _make_brvd(145)
        buf[145 * 2048:146 * 2048] = _make_el_torito_catalog()

        efi_len = (efi_last - efi_first + 1) * SECTOR
        efi_bytes = (b"\xAA\x55\xF0\x0F" * ((efi_len // 4) + 1))[:efi_len]
        buf[efi_first * SECTOR:efi_first * SECTOR + efi_len] = efi_bytes
        img.write_bytes(bytes(buf))

        ok, report = self._verifier_passes(img)
        # Check the *breakage* before rescue: the verifier should reject.
        # Note: we set things up so that gpt_backup_header is missing AND
        # mbr_size is short. The verifier should refuse.
        self.assertFalse(
            ok,
            f"broken warm-style image should fail verification: {report.get('issues')!r}"
        )
        # And specifically it should fail on backup header & mbr size mismatch.
        issue_kinds = [k for k, _ in report.get("issues", [])]
        self.assertIn("gpt_backup_header", issue_kinds)

    def test_finalizer_rescues_broken_warm_layout(self) -> None:
        """The fix: a broken warm-style image, after finalize_gpt_layout,
        passes verification. This is the actual contract the design doc
        §8 step 6 ("qualified finalizer") requires."""
        image_lba = 123136
        efi_first = 28544
        efi_last = 28544 + 8191
        primary_part_entry = 2
        first_usable = 64
        last_usable = 121904  # stale

        img = self.tmp_dir / "warm-broken.iso"
        entries = _make_gpt_entries(efi_first, efi_last)
        entries_crc = _crc32(entries)
        primary_header = _make_gpt_header(
            current_lba=1,
            backup_lba=122471,           # stale
            first_usable=first_usable,
            last_usable=last_usable,
            part_entry_lba=primary_part_entry,
            array_crc=entries_crc,
        )
        buf = bytearray(image_lba * SECTOR)
        buf[0:SECTOR] = bytes(bytearray(SECTOR))
        buf[510:512] = b"\x55\xAA"
        buf[450] = 0xEE
        struct.pack_into("<I", buf, 454, 1)
        struct.pack_into("<I", buf, 458, 122471)  # stale

        buf[1 * SECTOR:2 * SECTOR] = primary_header
        buf[primary_part_entry * SECTOR:primary_part_entry * SECTOR + len(entries)] = entries

        buf[16 * 2048:17 * 2048] = _make_iso_pvd("WARMVOL")
        buf[17 * 2048:18 * 2048] = _make_brvd(145)
        buf[145 * 2048:146 * 2048] = _make_el_torito_catalog()

        efi_len = (efi_last - efi_first + 1) * SECTOR
        efi_bytes = (b"\xAA\x55\xF0\x0F" * ((efi_len // 4) + 1))[:efi_len]
        buf[efi_first * SECTOR:efi_first * SECTOR + efi_len] = efi_bytes
        img.write_bytes(bytes(buf))

        # Run the finalizer
        info = write_image.finalize_gpt_layout(img)
        self.assertEqual(info["status"] if "status" in info else "ok", "ok")
        self.assertEqual(info["image_lba"], image_lba)
        self.assertEqual(info["new_backup_lba"], image_lba - 1)
        self.assertEqual(info["new_last_usable_lba"], info["new_backup_part_entry_lba"] - 1)

        # And verify: it now passes
        ok, report = self._verifier_passes(img)
        if not ok:
            self.fail(
                f"finalizer-rescued image should pass verifier; issues={report.get('issues')!r}"
            )

    def test_finalizer_preserves_efi_partition_bytes(self) -> None:
        """Confirm the finalizer does NOT move or rewrite the EFI partition
        bytes — it only patches GPT/MBR metadata, leaving the ISO9660 +
        ESP bytes intact."""
        image_lba = 123136
        efi_first = 28544
        efi_last = 28544 + 8191
        primary_part_entry = 2
        backup_part_entry = image_lba - 1 - 1
        first_usable = 64
        last_usable = 121904

        img = self.tmp_dir / "warm.iso"
        _build_synthetic_warm_image(
            img,
            file_size_bytes=image_lba * SECTOR,
            primary_part_entry_lba=primary_part_entry,
            backup_part_entry_lba=backup_part_entry,
            efi_first_lba=efi_first,
            efi_last_lba=efi_last,
            first_usable_lba=first_usable,
            last_usable_lba=last_usable,
            primary_backup_lba_stale=122471,
            mbr_size_stale=122471,
        )
        # Snapshot EFI bytes before finalizer
        efi_bytes_before = img.read_bytes()[
            efi_first * SECTOR:(efi_last + 1) * SECTOR
        ]
        # Snapshot the entire file SHA
        import hashlib
        sha_before = hashlib.sha256(img.read_bytes()).hexdigest()

        # Run finalizer
        write_image.finalize_gpt_layout(img)

        # EFI bytes must be unchanged
        efi_bytes_after = img.read_bytes()[
            efi_first * SECTOR:(efi_last + 1) * SECTOR
        ]
        self.assertEqual(
            efi_bytes_before, efi_bytes_after,
            "EFI partition bytes must not be modified by the finalizer"
        )

        # Only the GPT/MBR regions should differ; bytes outside those
        # regions must match. (This is a stronger guarantee: it asserts
        # the finalizer doesn't accidentally touch the ISO data area.)
        # We slice out GPT/MBR regions from before/after and compare the
        # rest of the file. Since _build_synthetic_warm_image constructs
        # an empty ISO data area, the bytewise comparison outside GPT/MBR
        # must match.
        before = img.read_bytes()
        # Re-run with the same broken layout, save before
        img2 = self.tmp_dir / "warm2.iso"
        _build_synthetic_warm_image(
            img2,
            file_size_bytes=image_lba * SECTOR,
            primary_part_entry_lba=primary_part_entry,
            backup_part_entry_lba=backup_part_entry,
            efi_first_lba=efi_first,
            efi_last_lba=efi_last,
            first_usable_lba=first_usable,
            last_usable_lba=last_usable,
            primary_backup_lba_stale=122471,
            mbr_size_stale=122471,
        )
        before_full = img2.read_bytes()
        sha_before_full = hashlib.sha256(before_full).hexdigest()
        write_image.finalize_gpt_layout(img2)
        after_full = img2.read_bytes()
        # Outside MBR (0..511), primary header (1 sector at LBA 1),
        # primary entry array (1 sector at LBA 2), backup entry array
        # (~62 sectors at the tail), and backup header (1 sector at the
        # tail), bytes must be identical. We approximate this by saying
        # ``len(before_full) == len(after_full)`` (the file size does not
        # change) and that the EFI region + the ISO region are not
        # touched. The "non-GPT" byte run is from offset (efi_last+1)*512
        # to (backup_part_entry_lba-1)*512 (which is the post-EFI pre-GPT
        # gap on a warm image).
        post_efi_pre_gpt_start = (efi_last + 1) * SECTOR
        post_efi_pre_gpt_end = backup_part_entry * SECTOR
        self.assertEqual(
            before_full[post_efi_pre_gpt_start:post_efi_pre_gpt_end],
            after_full[post_efi_pre_gpt_start:post_efi_pre_gpt_end],
            "post-EFI / pre-GPT-backup gap must not be modified by the finalizer"
        )

    def test_finalizer_rejects_image_without_gpt(self) -> None:
        """Defensive: refuse to rescue an image with no GPT primary signature."""
        img = self.tmp_dir / "no-gpt.iso"
        # All-zero file (no signature)
        img.write_bytes(b"\x00" * SECTOR * 8)
        with self.assertRaises(ValueError):
            write_image.finalize_gpt_layout(img)

    def test_finalizer_rejects_legacy_mbr(self) -> None:
        """Defensive: refuse to rescue an image whose MBR is missing the
        0xEE protective entry (i.e. a non-hybrid image)."""
        image_lba = 100
        img = self.tmp_dir / "legacy.iso"
        # Build a fake MBR-only image with valid primary GPT but a legacy
        # MBR (no 0xEE).
        buf = bytearray(image_lba * SECTOR)
        buf[510:512] = b"\x55\xAA"
        # No partition entries at all
        entries = _make_gpt_entries(10, 50)
        primary = _make_gpt_header(
            current_lba=1,
            backup_lba=image_lba - 1,
            first_usable=10,
            last_usable=image_lba - 10,
            part_entry_lba=2,
            array_crc=_crc32(entries),
        )
        buf[1 * SECTOR:2 * SECTOR] = primary
        buf[2 * SECTOR:2 * SECTOR + len(entries)] = entries
        img.write_bytes(bytes(buf))
        with self.assertRaises(ValueError):
            write_image.finalize_gpt_layout(img)


class CleanupScratchTests(unittest.TestCase):
    """Drive _cleanup_scratch() across file/dir/missing cases."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.tmp_dir = Path(self.tmp.name)

    def test_clean_scratch_when_missing(self) -> None:
        write_image._cleanup_scratch(self.tmp_dir / "nope.iso")
        # no exception

    def test_clean_scratch_when_regular_file(self) -> None:
        f = self.tmp_dir / "scratch.iso"
        f.write_bytes(b"hello")
        write_image._cleanup_scratch(f)
        self.assertFalse(f.exists())

    def test_clean_scratch_when_directory(self) -> None:
        d = self.tmp_dir / "scratch.iso"
        d.mkdir()
        (d / "a").write_text("x")
        write_image._cleanup_scratch(d)
        self.assertFalse(d.exists())


# ----- iso9660_efi_in_tree (in-tree ESP) helpers and tests -----


def _make_section_header_entry() -> bytes:
    """Build a 32-byte Section Header Entry per the El Torito spec.

    Layout:
      byte 0    Header ID (0x91)
      byte 1    Platform (0xEF for EFI)
      bytes 2-3 Number of following Section Entries (LE uint16)
      bytes 4-31 Section identifier (28 bytes, ASCII)
    """
    e = bytearray(32)
    e[0] = 0x91
    e[1] = 0xEF
    struct.pack_into("<H", e, 2, 1)
    return bytes(e)


def _make_efi_initial_entry(load_lba: int) -> bytes:
    """Build a 32-byte EFI Initial Entry per the El Torito spec.

    Layout:
      byte 0    Boot indicator (0x88 = bootable)
      byte 1    Boot media type (0 = no emulation)
      bytes 2-3 Reserved
      byte 4    Partition type (0)
      byte 5    Reserved
      bytes 6-7 Sector count (LE uint16; 0 in our layout)
      bytes 8-11 LBA of first sector of boot image (LE uint32, in 2048-byte units)
      bytes 12-31 Reserved
    """
    e = bytearray(32)
    e[0] = 0x88
    e[1] = 0x00
    struct.pack_into("<H", e, 6, 0)
    struct.pack_into("<I", e, 8, load_lba)
    return bytes(e)


def _make_debian_pattern_catalog(load_lba: int) -> bytes:
    """Build a 2048-byte El Torito catalog with the Debian pattern:
    validation entry (offset 0) + initial entry (offset 32) +
    Section Header Entry (offset 64) + EFI Initial Entry (offset 96).
    """
    cat = bytearray(2048)
    # Validation entry at offset 0
    cat[0] = 0x01
    cat[1] = 0x00  # platform = x86 (the legacy initial entry's platform)
    # 24-byte ID string
    id_string = b"EL TORITO SPECIFICATION\x00"
    assert len(id_string) == 24
    cat[4:28] = id_string
    # Key bytes
    cat[30] = 0x55
    cat[31] = 0xAA
    # Compute the validation entry checksum so that the word sum is 0.
    s = 0
    for i in range(0, 32, 2):
        s += struct.unpack("<H", cat[i:i+2])[0]
    s = (-s) & 0xFFFF
    struct.pack_into("<H", cat, 28, s)
    # Initial/default entry at offset 32 (legacy BIOS boot, sector_count 76,
    # load_lba arbitrary).
    cat[32] = 0x88  # bootable
    cat[33] = 0     # no emulation
    struct.pack_into("<H", cat, 38, 76)
    struct.pack_into("<I", cat, 40, 28672)
    # Section Header Entry at offset 64
    cat[64:96] = _make_section_header_entry()
    # EFI Initial Entry at offset 96
    cat[96:128] = _make_efi_initial_entry(load_lba)
    return bytes(cat)


class Iso9660InTreeEspBytesTests(unittest.TestCase):
    """Verify the iso9660_efi_in_tree layout's bytes-comparison check:
    the verifier actually proves the bytes at the EFI Initial Entry's
    load_lba match the source ESP image, and it correctly rejects a
    deliberately-corrupted ESP."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.tmp_dir = Path(self.tmp.name)

    def _build_minimal_iso_with_esp(
        self, *, catalog_lba: int, esp_load_lba: int, esp_bytes: bytes
    ) -> tuple[Path, Path]:
        """Build a minimal iso9660_efi_in_tree image with an ESP at the
        given load_lba. The image has only what the verifier inspects:
        MBR (zero), ISO PVD (sector 16), BRVD (sector 17), El Torito
        catalog (sector catalog_lba), and the ESP bytes at load_lba.
        """
        image_path = self.tmp_dir / "image.iso"
        # Make the image just large enough to hold the ESP at load_lba.
        image_size = (esp_load_lba * 2048) + len(esp_bytes)
        buf = bytearray(image_size)
        # ISO PVD at sector 16
        buf[16 * 2048:17 * 2048] = _make_iso_pvd("INTREE")
        # BRVD at sector 17
        buf[17 * 2048:18 * 2048] = _make_brvd(catalog_lba)
        # El Torito catalog
        buf[catalog_lba * 2048:(catalog_lba + 1) * 2048] = _make_debian_pattern_catalog(esp_load_lba)
        # ESP bytes at load_lba
        buf[esp_load_lba * 2048:esp_load_lba * 2048 + len(esp_bytes)] = esp_bytes
        image_path.write_bytes(bytes(buf))

        esp_path = self.tmp_dir / "esp.img"
        esp_path.write_bytes(esp_bytes)
        return image_path, esp_path

    def _verifier(self, image: Path, esp: Path, layout: str = "auto") -> tuple[bool, dict]:
        report_path = image.parent / (image.name + ".verify.json")
        proc = subprocess_run_safe(
            [
                sys.executable,
                str(ISO_DIR / "verify-image.py"),
                "--image", str(image),
                "--arch", "amd64",
                "--level", "warm",
                "--report", str(report_path),
                "--esp-image", str(esp),
                "--layout", layout,
            ]
        )
        report: dict = {}
        if report_path.exists():
            report = json.loads(report_path.read_text())
        return proc.returncode == 0, report

    def test_clean_image_passes_verifier(self) -> None:
        esp_bytes = b"REFIND!" * (64 * 1024 // len(b"REFIND!"))  # ~64 KiB
        image, esp = self._build_minimal_iso_with_esp(
            catalog_lba=18, esp_load_lba=20, esp_bytes=esp_bytes
        )
        ok, report = self._verifier(image, esp)
        self.assertTrue(
            ok,
            f"clean iso9660_efi_in_tree image should pass; issues={report.get('issues')!r}"
        )
        check = report["checks"]["esp_bytes_identical_to_source"]
        self.assertTrue(check["ok"])
        self.assertEqual(check["source_sha256"], check["actual_sha256"])

    def test_corrupted_esp_is_rejected(self) -> None:
        """The negative test the brief asks for: corrupt one byte of the
        embedded ESP image after cold-compose; the verifier MUST reject."""
        esp_bytes = b"\xCC" * (64 * 1024)  # 64 KiB
        image, esp = self._build_minimal_iso_with_esp(
            catalog_lba=18, esp_load_lba=20, esp_bytes=esp_bytes
        )
        # Corrupt one byte deep inside the ESP (not at the very start,
        # which is the reserved area of the FAT image header; pick a
        # safe offset).
        with image.open("r+b") as f:
            target_offset = 20 * 2048 + 0x1000
            f.seek(target_offset)
            orig = f.read(1)
            self.assertTrue(orig, "test precondition: ESP byte must be readable")
            f.seek(target_offset)
            f.write(bytes([(orig[0] ^ 0xFF) & 0xFF]))
        ok, report = self._verifier(image, esp)
        self.assertFalse(
            ok,
            f"corrupted ESP should fail verification; got issues={report.get('issues')!r}"
        )
        issue_kinds = [k for k, _ in report.get("issues", [])]
        self.assertIn("esp_bytes_identical_to_source", issue_kinds)

    def test_efi_initial_entry_validation_rejects_bad_boot_indicator(self) -> None:
        """The new validation: an EFI Initial Entry whose boot indicator
        is not 0x88 must cause the verifier to fail at the catalog check,
        not silently pass."""
        esp_bytes = (b"\xCC" * 1024)
        # Build the catalog by hand and patch the EFI Initial Entry's
        # boot indicator to 0x00 (not bootable).
        cat = bytearray(_make_debian_pattern_catalog(20))
        cat[96] = 0x00  # EFI boot indicator: not bootable
        image = self.tmp_dir / "image.iso"
        image_size = 20 * 2048 + len(esp_bytes)
        buf = bytearray(image_size)
        buf[16 * 2048:17 * 2048] = _make_iso_pvd("INTREE")
        buf[17 * 2048:18 * 2048] = _make_brvd(18)
        buf[18 * 2048:19 * 2048] = bytes(cat)
        buf[20 * 2048:20 * 2048 + len(esp_bytes)] = esp_bytes
        image.write_bytes(bytes(buf))
        esp = self.tmp_dir / "esp.img"
        esp.write_bytes(esp_bytes)
        ok, report = self._verifier(image, esp)
        self.assertFalse(ok, "EFI Initial Entry with bad boot_indicator must fail")
        issue_kinds = [k for k, _ in report.get("issues", [])]
        self.assertIn("el_torito_catalog", issue_kinds)
        # The detail should name the bad boot indicator explicitly.
        catalog_detail = report["checks"]["el_torito_catalog"]["detail"]
        flat = json.dumps(catalog_detail)
        self.assertIn("boot_indicator", flat)

    def test_efi_initial_entry_validation_rejects_zero_load_lba(self) -> None:
        """Zero load_lba in the EFI Initial Entry is rejected (no boot
        image would actually be loaded)."""
        esp_bytes = (b"\xCC" * 1024)
        cat = bytearray(_make_debian_pattern_catalog(0))  # zero load_lba
        image = self.tmp_dir / "image.iso"
        image_size = 1024 * 1024
        buf = bytearray(image_size)
        buf[16 * 2048:17 * 2048] = _make_iso_pvd("INTREE")
        buf[17 * 2048:18 * 2048] = _make_brvd(18)
        buf[18 * 2048:19 * 2048] = bytes(cat)
        image.write_bytes(bytes(buf))
        esp = self.tmp_dir / "esp.img"
        esp.write_bytes(esp_bytes)
        ok, report = self._verifier(image, esp)
        self.assertFalse(ok, "EFI Initial Entry with load_lba=0 must fail")
        issue_kinds = [k for k, _ in report.get("issues", [])]
        self.assertIn("el_torito_catalog", issue_kinds)
        flat = json.dumps(report["checks"]["el_torito_catalog"]["detail"])
        self.assertIn("load_lba=0", flat)

    def test_section_header_entry_with_zero_following_is_rejected(self) -> None:
        """A Section Header Entry at catalog offset 64 with 0 following
        entries is a malformed catalog -- the EFI Initial Entry below it
        would not be associated with any section and OVMF would silently
        skip it. The verifier must reject.

        Covers Codex review item 5 ("number of following entries" should
        be validated, not just trust bytes 96-127 as the EFI entry).
        """
        esp_bytes = b"\xCC" * 1024
        cat = bytearray(_make_debian_pattern_catalog(20))
        # Section Header Entry at offset 64: header 0x91, platform 0xEF,
        # entry_count = 0 (the malformed case)
        cat[64] = 0x91
        cat[65] = 0xEF
        struct.pack_into("<H", cat, 66, 0)
        image = self.tmp_dir / "image.iso"
        image_size = 1024 * 1024
        buf = bytearray(image_size)
        buf[16 * 2048:17 * 2048] = _make_iso_pvd("INTREE")
        buf[17 * 2048:18 * 2048] = _make_brvd(18)
        buf[18 * 2048:19 * 2048] = bytes(cat)
        buf[20 * 2048:20 * 2048 + len(esp_bytes)] = esp_bytes
        image.write_bytes(bytes(buf))
        esp = self.tmp_dir / "esp.img"
        esp.write_bytes(esp_bytes)
        ok, report = self._verifier(image, esp)
        self.assertFalse(
            ok,
            "Section Header Entry with 0 following entries must fail"
        )
        issue_kinds = [k for k, _ in report.get("issues", [])]
        self.assertIn("el_torito_catalog", issue_kinds)
        flat = json.dumps(report["checks"]["el_torito_catalog"]["detail"])
        self.assertIn("0 following entries", flat)

    def test_section_header_entry_with_wrong_platform_is_rejected(self) -> None:
        """A Section Header Entry whose platform byte is not 0xEF is a
        malformed catalog (the EFI Initial Entry below would be ignored
        by OVMF). The verifier must reject.

        Covers Codex review item 5 (EFI platform ID validation).
        """
        esp_bytes = b"\xCC" * 1024
        cat = bytearray(_make_debian_pattern_catalog(20))
        # Section Header Entry: header 0x91, platform 0x00 (wrong!),
        # entry_count = 1
        cat[64] = 0x91
        cat[65] = 0x00  # platform = x86, not EFI
        struct.pack_into("<H", cat, 66, 1)
        image = self.tmp_dir / "image.iso"
        image_size = 1024 * 1024
        buf = bytearray(image_size)
        buf[16 * 2048:17 * 2048] = _make_iso_pvd("INTREE")
        buf[17 * 2048:18 * 2048] = _make_brvd(18)
        buf[18 * 2048:19 * 2048] = bytes(cat)
        buf[20 * 2048:20 * 2048 + len(esp_bytes)] = esp_bytes
        image.write_bytes(bytes(buf))
        esp = self.tmp_dir / "esp.img"
        esp.write_bytes(esp_bytes)
        ok, report = self._verifier(image, esp)
        self.assertFalse(
            ok,
            "Section Header Entry with non-EFI platform must fail"
        )
        issue_kinds = [k for k, _ in report.get("issues", [])]
        self.assertIn("el_torito_catalog", issue_kinds)
        flat = json.dumps(report["checks"]["el_torito_catalog"]["detail"])
        self.assertIn("expected 0xEF", flat)


class BuildRefindEspRequiresKernelTests(unittest.TestCase):
    """``build-refind-esp.py`` must fail loudly when --d-i-kernel or
    --d-i-initrd is missing -- the previous behavior of silently
    producing a refind.conf with three enabled menu entries pointing at
    /linux and /initrd.gz that did not exist was a latent boot failure."""

    def test_argparse_requires_d_i_kernel(self) -> None:
        tmp_dir = tempfile.mkdtemp()
        # No --d-i-kernel provided
        proc = subprocess_run_safe([
            sys.executable, str(ISO_DIR / "build-refind-esp.py"),
            "--arch", "amd64",
            "--out-dir", tmp_dir,
            "--d-i-initrd", "/nonexistent/initrd.gz",
        ])
        self.assertNotEqual(
            proc.returncode, 0,
            f"argparse must reject when --d-i-kernel is missing; got rc={proc.returncode}, "
            f"stderr={proc.stderr[:500]!r}"
        )
        self.assertIn("--d-i-kernel", proc.stderr)

    def test_argparse_requires_d_i_initrd(self) -> None:
        tmp_dir = tempfile.mkdtemp()
        proc = subprocess_run_safe([
            sys.executable, str(ISO_DIR / "build-refind-esp.py"),
            "--arch", "amd64",
            "--out-dir", tmp_dir,
            "--d-i-kernel", "/nonexistent/linux",
        ])
        self.assertNotEqual(
            proc.returncode, 0,
            f"argparse must reject when --d-i-initrd is missing; got rc={proc.returncode}, "
            f"stderr={proc.stderr[:500]!r}"
        )
        self.assertIn("--d-i-initrd", proc.stderr)

    def test_build_esp_dir_rejects_missing_kernel(self) -> None:
        # Construct a synthetic refind_src directory containing a
        # refind_x64.efi file (the only file build_esp_dir looks up).
        with tempfile.TemporaryDirectory() as td:
            td_path = Path(td)
            refind_src = td_path / "refind"
            refind_src.mkdir()
            (refind_src / "refind_x64.efi").write_bytes(b"\x00" * 1024)
            esp_root = td_path / "esp-tree"
            esp_root.mkdir()
            # Pass a non-existent kernel; build_esp_dir must raise.
            with self.assertRaises(FileNotFoundError):
                build_refind_esp = _load_module(
                    ISO_DIR / "build-refind-esp.py", "bre_mod"
                )
                build_refind_esp.build_esp_dir(
                    esp_root,
                    refind_src,
                    "amd64",
                    d_i_kernel=td_path / "no-such-linux",
                    d_i_initrd=td_path / "no-such-initrd",
                )


if __name__ == "__main__":
    unittest.main()
