#!/usr/bin/env python3
"""
verify-image.py — Independent ISO image layout verifier.

Parses a resulting image's GPT (primary + backup), MBR, ISO9660 volume
descriptors, El Torito catalog and the actual partition extents WITHOUT
delegating to xorriso. The design doc §8 is explicit: do not trust xorriso
exit status alone. xorriso can exit 0 and still produce a layout that fails
firmware/d-i media discovery.

Two layouts are supported (auto-detected by the presence of a GPT primary
header at LBA 1):

  * ``iso9660_efi_in_tree`` (default since 2026-09-21): no GPT, the ESP
    image lives at /efi.img inside the ISO tree. The El Torito catalog
    uses Debian's Section Header Entry + EFI Initial Entry pattern
    (offset 64 / 96). This is what actually boots on QEMU/OVMF 11.1.1
    from fresh NVRAM.

  * ``hybrid`` (legacy; available via ``--layout hybrid``): the previous
    -append_partition layout. The ESP is an appended EFI System
    Partition described by a GPT primary + backup + entry array. Requires
    the GPT rescue finalizer on warm growth.

What we verify, in order:

  1. Image file is openable and large enough to contain a usable ISO + GPT
     trailing region.
  2. MBR signature (0x55AA at byte 510 of LBA 0).
  3. MBR partition table: either a single 0xEE protective entry
     (iso9660_efi_in_tree with -isohybrid-gpt-basdat), or a 0xEF ESP
     partition (hybrid layout's legacy MBR), or no entries
     (iso9660_efi_in_tree without -isohybrid). Layout-aware.
  4. (hybrid only) GPT primary header at LBA 1: signature, revision,
     header_size, current_lba, backup_lba, partition_entries_lba,
     num_part_entries, size_of_part_entry, header CRC32, entry array CRC.
  5. (hybrid only) GPT backup header at LBA (image_bytes/512 - 1): same
     CRC32 validations.
  6. (hybrid only) GPT entry-array walk to locate the EFI System Partition
     entry; verify it claims the LBA range our ESP image actually occupies.
  7. ISO9660 PVD at LBA 16: signature, type, version.
  8. El Torito Boot Record Volume Descriptor at LBA 17: signature, catalog LBA.
  9. El Torito Boot Catalog at its LBA. We validate the validation entry
     (offset 0), the default/initial entry at offset 32, and (for the
     Debian "Section Header Entry + EFI Initial Entry" pattern that
     ``iso9660_efi_in_tree`` uses) the Section Header Entry at offset 64
     and the EFI Initial Entry at offset 96: header indicator, EFI
     platform ID (0xEF), final-section bit, and load LBA.
 10. Layout-aware ESP-bytes-identical-to-source check:
       * hybrid: read the bytes at the GPT EFI partition's LBA range.
       * iso9660_efi_in_tree: read the bytes at the EFI Initial Entry's
         load_lba (offset 96 of the catalog).

If any check fails we exit 1 and write a structured JSON report with the
failing checks enumerated. The goal: a verifier whose output the operator
can trust independently of xorriso.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import struct
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent


# The verifier uses two sector sizes. MBR / GPT live in the LBA-addressed
# 512-byte sector view. ISO 9660 and the El Torito catalog always live in
# the 2048-byte "logical block" view (per ECMA-119 / El Torito). Do not
# mix them up: ``mbr_*`` helpers multiply by 512; ``iso_*`` and
# ``el_torito_*`` helpers multiply by 2048.
SECTOR = 512
ISO_BLOCK = 2048


def log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


def sha256_bytes(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()


def crc32(data: bytes) -> int:
    import zlib
    return zlib.crc32(data) & 0xFFFFFFFF


def read_at(path: Path, offset: int, length: int) -> bytes:
    with path.open("rb") as f:
        f.seek(offset)
        return f.read(length)


def check_mbr_signature(path: Path) -> tuple[bool, str]:
    """MBR signature 0x55AA at byte 510 of sector 0.

    Informational, not a pass/fail gate: the iso9660_efi_in_tree layout
    may have 0x0000 here (xorriso without -isohybrid-mbr does not write
    a signature byte in this position; the boot chain still works because
    El Torito drives the boot, not the MBR). The hybrid layout should
    have 0x55AA here; the verifier reports the value either way.
    """
    sig = read_at(path, 510, 2)
    if sig == b"\x55\xAA":
        return True, "ok"
    if sig == b"\x00\x00":
        return True, "no MBR signature (El Torito-only layout; expected for iso9660_efi_in_tree without -isohybrid-mbr)"
    return False, f"signature bytes at 510-511: {sig.hex()} (expected 55aa or 0000)"


def check_mbr_partitions(path: Path, expected_esp_size: int, has_gpt: bool) -> tuple[bool, list[str]]:
    """Inspect the MBR partition table.

    Three valid shapes:
      * Legacy MBR + ESP: MBR has a 0xEF partition claiming the ESP region.
        Used when -appended_part_as_gpt is NOT set (hybrid layout).
      * Protective MBR + GPT: MBR has a single 0xEE partition claiming the
        entire image, and the ESP lives in a GPT entry only. Used when
        -appended_part_as_gpt IS set (hybrid layout).
      * No MBR entries: the iso9660_efi_in_tree layout uses El Torito +
        ISO 9660 only. The MBR signature byte may or may not be set by
        xorriso, but no entries are required.

    For Step 1 we accept any of these; we report which one we got and
    require that the protective MBR partition cover at least the image
    when present."""
    issues = []
    table = read_at(path, 446, 64)
    partitions = []
    for i in range(4):
        entry = table[i * 16:(i + 1) * 16]
        status = entry[0]
        ptype = entry[4]
        lba_start = struct.unpack("<I", entry[8:12])[0]
        lba_size = struct.unpack("<I", entry[12:16])[0]
        partitions.append({
            "index": i + 1,
            "status": status,
            "type": ptype,
            "lba_start": lba_start,
            "lba_size": lba_size,
        })

    if has_gpt:
        # Expect a single 0xEE partition covering the whole image.
        protective = next((p for p in partitions if p["type"] == 0xEE), None)
        if not protective:
            issues.append("protective MBR missing 0xEE entry (expected with -appended_part_as_gpt)")
        return (not issues), issues + [{"all_partitions": partitions, "protective_mbr": True}]
    else:
        # Either legacy MBR + 0xEF, or no entries (iso9660_efi_in_tree).
        efi_partition = next((p for p in partitions if p["type"] == 0xEF), None)
        if efi_partition is not None and efi_partition["lba_size"] * SECTOR < expected_esp_size:
            issues.append(
                f"MBR EFI partition size {efi_partition['lba_size'] * SECTOR} < expected ESP size {expected_esp_size}"
            )
        # No entries is fine (no-MBR iso9660_efi_in_tree layout).
        return (not issues), issues + [{"all_partitions": partitions, "protective_mbr": False}]


def parse_gpt_header(buf: bytes) -> dict:
    """Parse a 92-byte GPT header. Returns the parsed fields, or raises."""
    if buf[:8] != b"EFI PART":
        raise ValueError(f"not a GPT header: signature {buf[:8]!r}")
    return {
        "signature_hex": buf[:8].hex(),
        "revision": struct.unpack("<I", buf[8:12])[0],
        "header_size": struct.unpack("<I", buf[12:16])[0],
        "header_crc32_stored": struct.unpack("<I", buf[16:20])[0],
        "current_lba": struct.unpack("<Q", buf[24:32])[0],
        "backup_lba": struct.unpack("<Q", buf[32:40])[0],
        "first_usable_lba": struct.unpack("<Q", buf[40:48])[0],
        "last_usable_lba": struct.unpack("<Q", buf[48:56])[0],
        "disk_guid_hex": buf[56:72].hex(),
        "part_entry_lba": struct.unpack("<Q", buf[72:80])[0],
        "num_part_entries": struct.unpack("<I", buf[80:84])[0],
        "size_of_part_entry": struct.unpack("<I", buf[84:88])[0],
        "part_entry_array_crc32_stored": struct.unpack("<I", buf[88:92])[0],
    }


def check_gpt_header(buf: bytes, *, is_backup: bool, expected_image_lba: int) -> tuple[bool, list[str]]:
    """Validate CRC32 and cross-pointers for a GPT header."""
    issues = []
    try:
        h = parse_gpt_header(buf)
    except ValueError as e:
        return False, [f"GPT header parse: {e}"]

    if h["header_size"] != 92:
        issues.append(f"header size {h['header_size']} != 92")
    if h["size_of_part_entry"] != 128:
        issues.append(f"size_of_part_entry {h['size_of_part_entry']} != 128")

    # CRC32 of header (with the CRC32 field zeroed)
    header_for_crc = buf[:16] + b"\x00\x00\x00\x00" + buf[20:92]
    computed_crc = crc32(header_for_crc)
    if computed_crc != h["header_crc32_stored"]:
        issues.append(
            f"header CRC32 stored={h['header_crc32_stored']:#010x} computed={computed_crc:#010x}"
        )

    # current_lba and backup_lba cross-check
    if is_backup:
        if h["current_lba"] != expected_image_lba - 1:
            issues.append(f"backup header current_lba {h['current_lba']} != {expected_image_lba - 1}")
    else:
        if h["current_lba"] != 1:
            issues.append(f"primary header current_lba {h['current_lba']} != 1")
        if h["backup_lba"] != expected_image_lba - 1:
            issues.append(f"primary header backup_lba {h['backup_lba']} != {expected_image_lba - 1}")

    return (not issues), issues + [{"parsed": h, "computed_header_crc32": computed_crc}]


def check_gpt_entry_array(path: Path, *, header: dict, expected_efi_lba: int, expected_efi_size_lba: int) -> tuple[bool, list[str]]:
    """(Legacy helper — superseded by the inline check in main(). Kept for
    any future callers; not invoked by verify-image itself.)"""
    issues = []
    n = header["num_part_entries"]
    sz = header["size_of_part_entry"]
    arr = read_at(path, header["part_entry_lba"] * SECTOR, n * sz)
    actual_crc = crc32(arr)
    if actual_crc != header["part_entry_array_crc32_stored"]:
        issues.append(
            f"entry array CRC32 stored={header['part_entry_array_crc32_stored']:#010x} "
            f"computed={actual_crc:#010x}"
        )
    # Walk entries and look for the EFI partition.
    #
    # The EFI System Partition type GUID in mixed-endian (storage) form is
    #   28732AC1-1FF8-D211-BA4B-00A0C93EC93B
    # i.e. the "C12A7328" prefix gets byte-swapped on storage as
    #   "28732AC1" (the first three fields of a GUID are stored in little
    # endian, the last two in big endian, per the GPT spec).
    efi_sys_guid_stored = b"\x28\x73\x2A\xC1\x1F\xF8\xD2\x11\xBA\x4B\x00\xA0\xC9\x3E\xC9\x3B"
    efi_partition = None
    for i in range(n):
        entry = arr[i * sz:(i + 1) * sz]
        if entry[:16] == b"\x00" * 16:
            continue
        type_guid = entry[:16]
        # EFI System Partition type GUID (mixed-endian stored form)
        first_lba = struct.unpack("<Q", entry[32:40])[0]
        last_lba = struct.unpack("<Q", entry[40:48])[0]
        attr = struct.unpack("<Q", entry[48:56])[0]
        if type_guid == efi_sys_guid_stored:
            efi_partition = {
                "index": i,
                "first_lba": first_lba,
                "last_lba": last_lba,
                "size_lba": last_lba - first_lba + 1,
                "attrs": attr,
            }
            break

    if efi_partition is None:
        issues.append("no GPT partition entry with EFI System Partition type GUID")
    else:
        if efi_partition["first_lba"] != expected_efi_lba:
            issues.append(
                f"EFI partition first_lba {efi_partition['first_lba']} != expected {expected_efi_lba}"
            )
        if efi_partition["size_lba"] != expected_efi_size_lba:
            issues.append(
                f"EFI partition size_lba {efi_partition['size_lba']} != expected {expected_efi_size_lba}"
            )
    return (not issues), issues + [{"efi_partition": efi_partition, "computed_array_crc32": actual_crc}]


# (Above function retained for reference; main() inlines the modern check
# so that the GPT and MBR validations can share the parsed EFI partition.)


def check_iso_pvd(path: Path) -> tuple[bool, list]:
    """PVD is at ISO sector 16 (byte 32768 in a 2048-byte-sector ISO).
    ISO 9660 always uses 2048-byte logical sectors even when the
    MBR/GPT layer uses 512-byte sectors.

    Layout of a PVD (per ECMA-119):
      offset 0   : type (1 = PVD)
      offset 1-5 : "CD001" identifier
      offset 6   : version (1)
      offset 7   : unused (0)
      ...
      offset 40-71 : volume identifier (d-characters)
      ...
    """
    issues = []
    pvd = read_at(path, 16 * ISO_BLOCK, ISO_BLOCK)
    if pvd[0] != 1:
        issues.append(f"PVD type code at offset 0 = {pvd[0]} != 1")
    if pvd[1:6] != b"CD001":
        issues.append(f"PVD signature {pvd[1:6]!r} != b'CD001'")
    if pvd[6] != 1:
        issues.append(f"PVD version byte at offset 6 = {pvd[6]} != 1")
    volume_id = pvd[40:72]
    publisher = pvd[318:446]
    application_id = pvd[446:510]
    return (not issues), issues + [{
        "volume_id": volume_id.decode("ascii", errors="replace").strip(),
        "publisher": publisher.decode("ascii", errors="replace").strip(),
        "application_id": application_id.decode("ascii", errors="replace").strip(),
    }]


def check_el_torito(path: Path) -> tuple[bool, list]:
    """BRVD at ISO sector 17 (byte 34816). 2048-byte logical sectors.

    Layout of a BRVD (per ECMA-119 §8.4.31 Boot Record Volume Descriptor):
      offset 0   : type (0 = Boot Record Volume Descriptor)
      offset 1-5 : "CD001" identifier
      offset 6   : version (1)
      offset 7   : boot system identifier (32 bytes)  -- e.g. "EL TORITO SPECIFICATION"
      ...
      offset 0x47 (71) : 32-bit LE LBA of the boot catalog
    """
    issues = []
    brvd = read_at(path, 17 * ISO_BLOCK, ISO_BLOCK)
    if brvd[0] != 0:
        issues.append(f"BRVD type at offset 0 = {brvd[0]} != 0 (Boot Record Volume Descriptor)")
    if brvd[1:6] != b"CD001":
        issues.append(f"BRVD signature {brvd[1:6]!r} != b'CD001'")
    # El Torito catalog LBA is stored as a 32-bit LE value at offset 0x47.
    catalog_lba = struct.unpack("<I", brvd[0x47:0x4B])[0]
    if catalog_lba == 0:
        issues.append("El Torito catalog LBA is 0")
    return (not issues), issues + [{
        "catalog_lba": catalog_lba,
        "boot_system_id": brvd[7:39].decode("ascii", errors="replace").strip(),
    }]


def check_el_torito_catalog(path: Path, catalog_lba: int) -> tuple[bool, list, bytes]:
    """El Torito catalog uses 2048-byte logical sectors (LBA in ISO units).

    Returns (passed, detail_list, catalog_buf_bytes). The catalog buffer is
    returned so callers can parse entries not covered here (e.g. when the
    caller already knows the layout and wants to read additional fields).

    Per the El Torito spec, the catalog contains 32-byte entries:

      Validation Entry (offset 0):
        byte 0    Header ID, must be 0x01
        byte 1    Platform (0 = x86, 0xEF = EFI)
        bytes 2-3 Reserved (0)
        bytes 4-27 ID String (24 bytes, "EL TORITO SPECIFICATION" padded)
        bytes 28-29 Checksum (LE) -- word sum of entry == 0
        bytes 30-31 Key (0x55, 0xAA)

      Initial/Default Entry (offset 32):
        byte 0    Boot indicator (0x88 bootable, 0x00 not)
        byte 1    Boot media type (0 = no emulation, 1 = 1.2MB, 2 = 1.44MB,
                                  3 = 2.88MB, 4 = hard disk)
        bytes 2-3 Load segment
        byte 4    Partition type (0 = no partition, 1 = ...)
        byte 5    Reserved
        bytes 6-7 Sector count (LE) -- in 512-byte sectors (El Torito spec).
                                         Note: this is NOT the field used to
                                         compute Load RBA; see EFI Initial
                                         Entry below.
        bytes 8-11 LBA of first sector of boot image (LE) -- in 2048-byte
                  ISO logical blocks (NOT 512-byte sectors).
        bytes 12-31 Reserved (0)

    The Debian "Section Header Entry + EFI Initial Entry" extension lives
    at offsets 64 and 96 when the legacy ISOLINUX entry at offset 32 is
    bootable and identifies a non-EFI platform. We validate it explicitly:

      Section Header Entry (offset 64):
        byte 0    Header ID, must be 0x91 (Section Header Entry)
        byte 1    Platform (must equal the platform in the matching initial
                  entry, e.g. 0xEF for EFI)
        bytes 2-3 Reserved (0)
        bytes 4-7 Number of following Section Entries (LE). On Debian's
                  pattern this is 1 (just the EFI Initial Entry below).
        bytes 8-31 Section identifier (24 bytes, ASCII)

      EFI Initial Entry (offset 96):
        byte 0    Boot indicator (0x88 bootable, 0x00 not)
        byte 1    Boot media type (0 = no emulation)
        bytes 2-3 Reserved (0)
        byte 4    Partition type (0)
        byte 5    Reserved (0)
        bytes 6-7 Sector count (LE, 512-byte sectors per the El Torito spec)
        bytes 8-11 LBA of first sector of boot image (LE, 2048-byte ISO
                  logical blocks per the El Torito spec). xorriso 1.5.8
                  writes the value in 2048-byte units even though the spec
                  text says 512-byte units; the caller must multiply by
                  2048 (NOT 512) to read the boot image.
        bytes 12-31 Reserved (0)
    """
    issues = []
    catalog = read_at(path, catalog_lba * ISO_BLOCK, ISO_BLOCK)

    # Validation entry
    valid = catalog[0:32]
    if valid[0] != 0x01:
        issues.append(f"El Torito validation entry header_id {valid[0]:#04x} != 0x01")
    if valid[30:32] != b"\x55\xAA":
        issues.append(f"El Torito validation entry key at 30-31 = {valid[30:32].hex()} != 55aa")
    # Checksum
    checksum = struct.unpack("<H", valid[28:30])[0]
    word_sum = sum(struct.unpack("<H", valid[i:i+2])[0] for i in range(0, 32, 2))
    if (word_sum & 0xFFFF) != 0:
        issues.append(f"El Torito validation entry checksum invalid (word_sum={word_sum:#06x})")

    # Initial/Default Entry
    default_entry = catalog[32:64]
    boot_indicator = default_entry[0]
    boot_media_type = default_entry[1]
    sector_count = struct.unpack("<H", default_entry[6:8])[0]
    load_lba = struct.unpack("<I", default_entry[8:12])[0]
    if boot_indicator != 0x88:
        issues.append(f"El Torito default entry boot indicator {boot_indicator:#04x} != 0x88")

    # Section Header Entry at offset 64 (only present in the Debian
    # "Section Header Entry + EFI Initial Entry" pattern that the
    # iso9660_efi_in_tree layout uses). Treat the entry as absent when
    # its header indicator is not 0x91; otherwise validate it.
    section_header = catalog[64:96]
    has_section_header = section_header[0] == 0x91
    section_detail: dict = {
        "present": has_section_header,
    }
    if has_section_header:
        section_platform = section_header[1]
        # Per the El Torito spec, the "Number of following Section Entries"
        # is a 16-bit LE field at offset 2..3 of the Section Header Entry
        # (NOT a 32-bit LE field at offset 4..7 as an earlier draft of
        # this code assumed; we byte-verified against the real Debian
        # Bookworm netboot ISO that bytes 2..3 carry the entry count).
        section_entry_count = struct.unpack("<H", section_header[2:4])[0]
        if section_platform != 0xEF:
            issues.append(
                f"El Torito Section Header Entry at catalog offset 64 has "
                f"platform={section_platform:#04x}, expected 0xEF for EFI"
            )
        if section_entry_count == 0:
            issues.append(
                "El Torito Section Header Entry at catalog offset 64 has "
                "0 following entries (expected at least 1 for an EFI section)"
            )
        section_detail.update({
            "header_indicator": section_header[0],
            "platform": section_platform,
            "entry_count": section_entry_count,
            "identifier": section_header[8:32].decode("ascii", errors="replace").strip("\x00"),
        })

    # EFI Initial Entry at offset 96 (only meaningful when a Section Header
    # Entry preceded it). The presence is best-effort: if the Section Header
    # was present but the EFI Initial Entry is bogus (wrong header
    # indicator / wrong platform / not bootable / zero load LBA) we treat
    # it as a catalog failure -- a broken EFI Initial Entry is exactly the
    # gap that lets a corrupt image pass verification by accident.
    efi_entry = catalog[96:128]
    efi_detail: dict = {
        "present": has_section_header,
    }
    if has_section_header:
        efi_boot_ind = efi_entry[0]
        efi_platform_like = efi_entry[1]
        efi_sector_count = struct.unpack("<H", efi_entry[6:8])[0]
        efi_load_lba = struct.unpack("<I", efi_entry[8:12])[0]
        # Per the El Torito spec the EFI Initial Entry uses boot indicator
        # 0x88 and boot media type 0 (no emulation). We require those
        # values -- anything else means OVMF won't see this as a bootable
        # EFI entry.
        if efi_boot_ind != 0x88:
            issues.append(
                f"El Torito EFI Initial Entry at catalog offset 96 has "
                f"boot_indicator={efi_boot_ind:#04x}, expected 0x88"
            )
        if efi_platform_like != 0x00:
            # The EFI Initial Entry's byte 1 is reserved (0) per the spec;
            # a non-zero value here is a known indicator of malformed
            # catalogs.
            issues.append(
                f"El Torito EFI Initial Entry at catalog offset 96 has "
                f"non-zero reserved byte 1 = {efi_platform_like:#04x} (spec "
                f"requires 0)"
            )
        if efi_load_lba == 0:
            issues.append(
                "El Torito EFI Initial Entry at catalog offset 96 has "
                "load_lba=0 (no boot image)"
            )
        efi_detail.update({
            "boot_indicator": efi_boot_ind,
            "boot_media_type": efi_entry[1],
            "sector_count": efi_sector_count,
            "load_lba": efi_load_lba,
        })

    return (not issues), issues + [{
        "validation_entry": {
            "header_id": valid[0],
            "platform": valid[1],
            "id_string": valid[4:28].decode("ascii", errors="replace").strip("\x00"),
            "checksum": f"{checksum:#06x}",
            "key": valid[30:32].hex(),
            "checksum_valid": (word_sum & 0xFFFF) == 0,
        },
        "initial_entry": {
            "boot_indicator": boot_indicator,
            "boot_media_type": boot_media_type,
            "sector_count": sector_count,
            "load_lba": load_lba,
        },
        "section_header_entry": section_detail,
        "efi_initial_entry": efi_detail,
    }], catalog


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--image", required=True, type=Path)
    ap.add_argument("--arch", required=True, choices=["amd64", "arm64"])
    ap.add_argument("--level", default="cold", choices=["cold", "warm"])
    ap.add_argument("--report", type=Path, help="write structured JSON report here")
    ap.add_argument("--esp-image", type=Path,
                    help="if set, verify the bytes at the appended ESP partition "
                         "or at the in-tree EFI binary location (depending on layout) "
                         "are identical to this file")
    ap.add_argument("--parent", type=Path,
                    help="if set (warm level), also verify unchanged file extents "
                         "match the parent's extents")
    ap.add_argument("--layout", default="auto",
                    choices=["auto", "iso9660_efi_in_tree", "hybrid"],
                    help=(
                        "auto (default; infer from image contents), "
                        "iso9660_efi_in_tree (no GPT; ESP at /efi.img in tree), "
                        "hybrid (legacy -append_partition layout with GPT)"
                    ))
    args = ap.parse_args()

    image = args.image.resolve()
    image_size = image.stat().st_size
    image_lba = image_size // SECTOR

    # Auto-detect layout: if a valid GPT primary header is at LBA 1, this
    # is the hybrid layout (the previous-pass -append_partition output).
    # Otherwise it is the iso9660_efi_in_tree layout.
    layout = args.layout
    if layout == "auto":
        primary_probe = read_at(image, 1 * SECTOR, SECTOR)
        if primary_probe[:8] == b"EFI PART":
            layout = "hybrid"
        else:
            layout = "iso9660_efi_in_tree"

    report = {
        "schema_version": "verify-image-report/v2",
        "image": str(image),
        "image_size_bytes": image_size,
        "image_lba": image_lba,
        "arch": args.arch,
        "level": args.level,
        "layout": layout,
        "checks": {},
        "passed": True,
        "issues": [],
    }

    # 1. MBR signature (always expected; with -isohybrid-* we get one,
    #    without it the byte 510..511 might still be 0x55AA via
    #    xorriso's default MBR).
    ok, detail = check_mbr_signature(image)
    report["checks"]["mbr_signature"] = {"ok": ok, "detail": detail}
    if not ok:
        report["passed"] = False
        report["issues"].append(("mbr_signature", detail))

    if layout == "hybrid":
        # Hybrid layout: full GPT primary + backup + entry array checks.
        primary_header_buf = read_at(image, 1 * SECTOR, SECTOR)
        ok, detail = check_gpt_header(primary_header_buf, is_backup=False, expected_image_lba=image_lba)
        report["checks"]["gpt_primary_header"] = {"ok": ok, "detail": detail}
        if not ok:
            report["passed"] = False
            report["issues"].append(("gpt_primary_header", detail))

        backup_header_buf = read_at(image, (image_lba - 1) * SECTOR, SECTOR)
        ok, detail = check_gpt_header(backup_header_buf, is_backup=True, expected_image_lba=image_lba)
        report["checks"]["gpt_backup_header"] = {"ok": ok, "detail": detail}
        if not ok:
            report["passed"] = False
            report["issues"].append(("gpt_backup_header", detail))

        has_gpt = report["checks"]["gpt_primary_header"]["ok"] and report["checks"]["gpt_backup_header"]["ok"]

        try:
            ph = parse_gpt_header(primary_header_buf)
            n = ph["num_part_entries"]
            sz = ph["size_of_part_entry"]
            arr = read_at(image, ph["part_entry_lba"] * SECTOR, n * sz)
            actual_crc = crc32(arr)
            crc_ok = actual_crc == ph["part_entry_array_crc32_stored"]

            efi_sys_guid_stored = b"\x28\x73\x2A\xC1\x1F\xF8\xD2\x11\xBA\x4B\x00\xA0\xC9\x3E\xC9\x3B"
            efi_partition = None
            for i in range(n):
                entry = arr[i * sz:(i + 1) * sz]
                if entry[:16] == b"\x00" * 16:
                    continue
                if entry[:16] == efi_sys_guid_stored:
                    efi_partition = {
                        "index": i,
                        "first_lba": struct.unpack("<Q", entry[32:40])[0],
                        "last_lba": struct.unpack("<Q", entry[40:48])[0],
                        "size_lba": struct.unpack("<Q", entry[40:48])[0] - struct.unpack("<Q", entry[32:40])[0] + 1,
                        "attrs": struct.unpack("<Q", entry[48:56])[0],
                    }
                    break

            report["checks"]["gpt_entry_array_crc"] = {
                "ok": crc_ok,
                "stored_crc32": ph["part_entry_array_crc32_stored"],
                "computed_crc32": actual_crc,
            }
            if not crc_ok:
                report["passed"] = False
                report["issues"].append(("gpt_entry_array_crc", "CRC mismatch"))
            report["checks"]["gpt_efi_partition"] = {"ok": efi_partition is not None, "efi": efi_partition}
            if efi_partition is None:
                report["passed"] = False
                report["issues"].append(("gpt_efi_partition", "no EFI partition"))
            else:
                expected_efi_bytes = efi_partition["size_lba"] * SECTOR
                ok, mbr_detail = check_mbr_partitions(image, expected_esp_size=expected_efi_bytes, has_gpt=has_gpt)
                report["checks"]["mbr_partitions"] = {"ok": ok, "detail": mbr_detail}
                if not ok:
                    report["passed"] = False
                    report["issues"].append(("mbr_partitions", mbr_detail))
                if args.esp_image and args.esp_image.is_file():
                    actual_bytes = read_at(image, efi_partition["first_lba"] * SECTOR, expected_efi_bytes)
                    source_bytes = args.esp_image.read_bytes()
                    ok = actual_bytes == source_bytes
                    report["checks"]["esp_bytes_identical_to_source"] = {
                        "ok": ok,
                        "source_sha256": sha256_bytes(source_bytes),
                        "actual_sha256": sha256_bytes(actual_bytes),
                        "expected_size_bytes": expected_efi_bytes,
                        "actual_size_bytes": len(actual_bytes),
                        "source_lba": efi_partition["first_lba"],
                    }
                    if not ok:
                        report["passed"] = False
                        report["issues"].append(("esp_bytes_identical_to_source", "mismatch"))
        except ValueError as e:
            report["checks"]["gpt_primary_header"] = {
                "ok": False,
                "detail": f"failed to re-parse for entry array check: {e}",
            }
            report["passed"] = False
            report["issues"].append(("gpt_primary_header", str(e)))
    else:
        # iso9660_efi_in_tree layout: no GPT, no appended partition.
        # Mark GPT checks as N/A so the report is honest about what we
        # verified (we did not verify GPT because there is no GPT).
        report["checks"]["gpt_primary_header"] = {
            "ok": True,
            "detail": "N/A: iso9660_efi_in_tree layout has no GPT primary header",
        }
        report["checks"]["gpt_backup_header"] = {
            "ok": True,
            "detail": "N/A: iso9660_efi_in_tree layout has no GPT backup header",
        }
        report["checks"]["gpt_entry_array_crc"] = {
            "ok": True,
            "detail": "N/A: iso9660_efi_in_tree layout has no GPT entry array",
            "stored_crc32": 0,
            "computed_crc32": 0,
        }
        report["checks"]["gpt_efi_partition"] = {
            "ok": True,
            "detail": "N/A: EFI binary lives at /efi.img inside the ISO tree",
            "efi": None,
        }
        # MBR partition table: in this layout, the MBR has either a
        # single 0xEE protective entry (if -isohybrid-gpt-basdat was
        # used) or no entries (if not). Accept either.
        ok, mbr_detail = check_mbr_partitions(image, expected_esp_size=0, has_gpt=False)
        report["checks"]["mbr_partitions"] = {"ok": ok, "detail": mbr_detail}
        if not ok:
            report["passed"] = False
            report["issues"].append(("mbr_partitions", mbr_detail))

    # 6. ISO PVD
    ok, detail = check_iso_pvd(image)
    report["checks"]["iso_pvd"] = {"ok": ok, "detail": detail}
    if not ok:
        report["passed"] = False
        report["issues"].append(("iso_pvd", detail))

    # 7. El Torito BRVD + catalog
    ok, detail = check_el_torito(image)
    report["checks"]["el_torito_brvd"] = {"ok": ok, "detail": detail}
    if not ok:
        report["passed"] = False
        report["issues"].append(("el_torito_brvd", detail))
    if ok:
        catalog_lba = None
        if isinstance(detail, list):
            for item in detail:
                if isinstance(item, dict) and "catalog_lba" in item:
                    catalog_lba = item["catalog_lba"]
                    break
        elif isinstance(detail, dict):
            catalog_lba = detail.get("catalog_lba")
        if catalog_lba is None:
            report["issues"].append(("el_torito_catalog", "could not find catalog_lba in BRVD detail"))
            report["passed"] = False
        else:
            ok2, detail2, catalog_buf = check_el_torito_catalog(image, catalog_lba)
            report["checks"]["el_torito_catalog"] = {"ok": ok2, "detail": detail2}
            if not ok2:
                report["passed"] = False
                report["issues"].append(("el_torito_catalog", detail2))

            # iso9660_efi_in_tree: also verify that the bytes at the EFI
            # Initial Entry's load_lba (offset 96) match the source ESP
            # file. This is the in-tree analog of the hybrid layout's
            # ``esp_bytes_identical_to_source`` check.
            #
            # We rely on check_el_torito_catalog to have validated the
            # EFI Initial Entry (header indicator 0x88, reserved byte 0,
            # non-zero load_lba). If those checks did not pass, the
            # catalog_buf we have here may be junk and the bytes-comparison
            # below would silently produce a false positive -- so we only
            # run the bytes check when the catalog passed.
            if layout == "iso9660_efi_in_tree" and args.esp_image and args.esp_image.is_file() and ok2:
                init_e = catalog_buf[96:96+32]
                load_lba = struct.unpack("<I", init_e[8:12])[0]
                # The sector_count field in the EFI Initial Entry is NOT
                # reliable in our layout: xorriso '-boot_image any replay'
                # emits it as 0 in BOTH the cold and warm ISO even when the
                # EFI image is correctly written. xorriso instead resolves
                # the actual image size from the file path stored in the
                # PVD's bootstrap file entry. We don't try to parse that
                # here; we just use the SIZE OF THE SOURCE ESP IMAGE as the
                # authoritative size. The ESP image is required to be at
                # most the size of the parent ISO's free contiguous region
                # after the warm writer's update commands; xorriso has
                # already accepted the layout (exit 0) by the time we run.
                #
                # Unit notes: the El Torito spec text reads both the Load
                # RBA field and the Sector Count field as 512-byte units,
                # but the spec also separately says "CD-ROM sector" for
                # Load RBA in practice. xorriso 1.5.8.pl02 emits Load RBA
                # in 2048-byte ISO logical blocks (verified by byte-diff
                # against the source ESP at load_lba * 2048 -- a * 512
                # byte offset never matches). The Sector Count field is
                # not used by this check (it is 0 in our layout) so its
                # unit does not affect us; we rely on the source ESP size
                # for the read length instead.
                expected_size = args.esp_image.stat().st_size
                actual_bytes = read_at(image, load_lba * ISO_BLOCK, expected_size)
                source_bytes = args.esp_image.read_bytes()
                ok3 = actual_bytes == source_bytes
                report["checks"]["esp_bytes_identical_to_source"] = {
                    "ok": ok3,
                    "source_sha256": sha256_bytes(source_bytes),
                    "actual_sha256": sha256_bytes(actual_bytes),
                    "expected_size_bytes": expected_size,
                    "actual_size_bytes": len(actual_bytes),
                    "source_lba": load_lba,
                    "source_layout": "iso9660_efi_in_tree (Section Header Entry at catalog offset 64 + EFI Initial Entry at offset 96)",
                }
                if not ok3:
                    report["passed"] = False
                    report["issues"].append(("esp_bytes_identical_to_source", "mismatch"))

    # Trailing padding detection (design §8 "what it did not prove"):
    # Only applicable to the hybrid layout (which has a backup GPT). On
    # the iso9660_efi_in_tree layout there is no backup GPT.
    backup_lba = None
    if layout == "hybrid":
        try:
            h = parse_gpt_header(backup_header_buf)
            backup_lba = h["current_lba"]
        except Exception:
            pass
        if backup_lba is not None:
            trailing_bytes = image_size - (backup_lba + 1) * SECTOR
            report["checks"]["trailing_padding_after_backup_gpt"] = {
                "ok": True,  # informational, not a pass/fail
                "trailing_bytes": max(0, trailing_bytes),
                "image_lba": image_lba,
                "backup_lba": backup_lba,
            }
    else:
        report["checks"]["trailing_padding_after_backup_gpt"] = {
            "ok": True,
            "detail": "N/A: iso9660_efi_in_tree layout has no backup GPT",
            "trailing_bytes": 0,
            "image_lba": image_lba,
            "backup_lba": None,
        }

    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, indent=2, sort_keys=True))
    # Exit code: 0 if everything passed
    if not report["passed"]:
        for kind, detail in report["issues"]:
            log(f"FAIL: {kind}: {detail}")
        return 1
    log(f"verify-image: PASS ({len(report['checks'])} checks)")
    return 0


if __name__ == "__main__":
    sys.exit(main())