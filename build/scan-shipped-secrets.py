#!/usr/bin/env python3
"""scan-shipped-secrets.py -- the MANDATORY shipped-artifact credential gate.

One file is shipped: the raw GPT ``.img``.  Everything a customer can read is
inside it, so everything a customer can read is inside the scope of this scan:

  * every squashfs layer in ``/ncz-payload`` (base, desktop, desktop-hotfix,
    rescue, mgmt, and any other ``*.squashfs`` a future variant adds) --
    extracted in FULL, every file, inode-level;
  * every initrd/initramfs on the ESP and in the payload (``initrd.gz``,
    ``initrd.img``, ``*.cpio*``), every cpio segment inside every
    (possibly concatenated) compressed member -- the kernel unpacks every
    segment, so we do too;
  * every ``*.tar.zst`` / ``*.tar.xz`` / ``*.tar.gz`` rootfs archive (the
    rescue rootfs, the mgmt rootfs) -- those are extracted from inside the
    layer that carries them and every file scanned;
  * every ``.deb`` in every pool/cache directory anywhere on the image
    (``/pool``, ``/ncz-payload``, embedded apt caches, ...): both archives of
    each deb -- ``data.tar.*`` and ``control.tar.*`` -- are decompressed and
    every member scanned.  A deb member that is itself a compressed archive
    is expanded recursively (a tarball inside a deb is still shipped bytes);
  * every other regular file the image carries (ESP files, preseed, scripts),
    straight from the filesystem image.

Matching is HASHED.  The gate never receives a plaintext secret: it reads a
hash file (``manifests/secret-hashes.local`` by default, or the path in
``NCZ_SECRET_HASHES_FILE``) produced by ``build/make-secret-hashes.py`` on a
trusted machine.  That file holds salted SHA-256 digests of every known secret
value in every form it can be embedded as:

    offsets 0, 1, 2  -- a secret embedded mid-token (``TOKEN=glpat-xxx``,
                        ``xxx``, ``gitlab+deploy-token-1:xxx@``) is not a
                        prefix of the shipped bytes, so a prefix-only hash
                        would miss it;
    urlenc(), quote_plus(), quote(), quote_plus(safe='')
                     -- the value inside a URL or a JSON string;
    b64 [a:b]        -- base64 of each offset form, sliced at byte offset
                        [a:b] mod 3 so that the base64 of the secret found
                        mid-string (whose encoding does not sit on a 3-byte
                        boundary) is covered too.

Every window of every text-ish candidate the extractor produces is hashed and
looked up.  A hit names the layer, the archive member and the byte offset --
never the value.

On top of the hash list, a token-shape scan catches credentials nobody has
listed yet (``glpat-``, ``ghp_``, ``github_pat_``, ``xox*``, ``AKIA``,
``AIza``, ``sk-``, PEM private-key blocks), with the documented public apt
keyrings excluded by path AND by content (``.asc`` files that parse as a
PGP public key are the apt trust anchors; a PRIVATE KEY block never is).

FAIL CLOSED.  An unreadable image, partition, extractor, layer, archive or
member is a FAILURE, not a warning: an artifact we cannot prove clean is not
shipped.  The receipt (JSON) lists the layers, the archive/member counts and
every hit location, and carries no secret value.

Usage:
  build/scan-shipped-secrets.py --image PATH [--receipt PATH]
                                [--hash-file PATH] [--allow-detached]
                                [--require-hashes] [--jobs N] [--quiet]

Exit: 0 PASS, 1 FAIL (a finding or an unreadable artifact), 2 usage error.
"""

from __future__ import annotations

import argparse
import base64
import bz2
import collections
import gzip
import hashlib
import io
import json
import lzma
import os
import re
import shutil
import stat
import struct
import subprocess
import sys
import tarfile
import tempfile
import time
import uuid
import urllib.parse
import zipfile
import zlib

GATE_VERSION = "1"

# Salt the operator's hash file is generated with (make-secret-hashes.py).
DEFAULT_SALT = "ncz-shipped-secret-scan-v1"

# No layer on the image is bigger than ~2 GiB extracted; a single text
# candidate (a member, or one codebook chunk of one member) is bounded so a
# bytecode extractor cannot hash gigabytes forever.  Both are overridable for
# the unit tests, which use tiny fixtures.
MAX_MEMBER_BYTES = 512 << 20
MAX_WINDOW_BYTES = 4 << 20

# Shortest secret hash in the file.  make-secret-hashes.py refuses values
# shorter than this: an 8-byte window of a 3-byte password occurs by chance.
HASH_MIN_LEN = 8

# Longest value make-secret-hashes.py accepts.  Also bounds the per-offset
# loop above, so a 1 MiB hex blob is O(n * 256) hashes, not O(n^2).
MAX_SECRET_LEN = 256

# Bytes per lexing chunk.  The chunks OVERLAP by ``lex_overlap()`` bytes so a
# token straddling a chunk boundary is still seen whole.
CHUNK_BYTES = 1 << 20

TOKEN_SHAPES = collections.OrderedDict([
    ("gitlab-pat", re.compile(rb"glpat-[A-Za-z0-9_.\-]{20,}")),
    ("gitlab-runner", re.compile(rb"glrt-[A-Za-z0-9_\-]{20,}")),
    ("gitlab-deploy", re.compile(rb"gldt-[A-Za-z0-9_\-]{20,}")),
    ("github-pat", re.compile(rb"ghp_[A-Za-z0-9]{30,}")),
    ("github-fine-pat", re.compile(rb"github_pat_[A-Za-z0-9_]{30,}")),
    ("github-oauth", re.compile(rb"gh[ous]_[A-Za-z0-9]{30,}")),
    ("slack", re.compile(rb"xox[abprs]-[A-Za-z0-9\-]{10,}")),
    ("aws-akia", re.compile(rb"(?<![A-Za-z0-9])AKIA[0-9A-Z]{16}(?![A-Za-z0-9])")),
    ("google-api", re.compile(rb"AIza[0-9A-Za-z_\-]{35}")),
    ("openai-sk", re.compile(rb"(?<![A-Za-z0-9])sk-[A-Za-z0-9_\-]{20,}")),
    ("pem-private-key", re.compile(
        rb"-----BEGIN ([A-Z0-9 ]{0,40})PRIVATE KEY-----")),
])

# PEM blocks that are NOT credentials.  The kernel's own trust material ships
# as a public-key block, and the documented public apt keyrings are public
# bytes on purpose.  Excluding a PUBLIC key never hides a leak: a private key
# body cannot be written as a valid public-key PEM object.
NON_SECRET_PEM_LABELS = re.compile(
    rb"-----BEGIN (?:PGP )?PUBLIC KEY BLOCK-----|-----BEGIN CERTIFICATE-----"
    rb"|-----BEGIN (?:RSA )?PUBLIC KEY-----")

# Documented, shipped-by-design apt/package trust anchors (public keys only).
PUBLIC_KEYRING_NAMES = re.compile(
    r"(debian-archive-keyring|debian-testing-cd-signing|cilium-apt|"
    r"google-chrome-apt-keyring|vivaldi-apt-keyring|microsoft|"
    r"nvidia|intel|cix-deb-repo|ncz-repo|ncz-apt-policy)\.(asc|gpg)$", re.I)
PUBLIC_KEYRING_DIRS = re.compile(
    r"^/etc/apt/(trusted\.gpg\.d|keyrings)/|/usr/share/keyrings/|"
    r"/usr/share/(apt/)?keyrings?/|/usr/local/share/keyrings/")

# Tokenised-candidate vocabulary (let first, so "My " joins "P" -> "MyP...").
TOKEN_RUN = re.compile(rb"[A-Za-z0-9_+\-/=.:~!@$%^&*()'\"]{3,}")
ALNUM_RUN = re.compile(rb"[A-Za-z0-9_+\-]{8,}")
SLUG_WORDS = re.compile(rb"[a-z]+(?:_[a-z]+)*")
SLUG_SPLIT = re.compile(rb"[^a-z]+")

TEXT_EXT = {
    ".conf", ".cfg", ".cnf", ".ini", ".txt", ".json", ".yaml", ".yml",
    ".sh", ".bash", ".py", ".service", ".socket", ".target", ".timer",
    ".mount", ".path", ".list", ".sources", ".sources.d", ".pref", ".desktop",
    ".xml", ".rules", ".env", ".properties", ".toml", ".tsv", ".csv", ".md",
    ".hook", ".link", ".netdev", ".network", ".profile", ".aliases",
}
# Files with no extension that still hold configuration (apt/dpkg/e2fs).
TEXT_NAMES = {
    "config", "conf", "shadow", "passwd", "group", "gshadow", "fstab",
    "crypttab", "hosts", "hostname", "environment", "os-release",
    "lsb-release", "rc.local", "preseed.cfg", "sources.list", "modprobe.d",
    "authorized_keys", "known_hosts", "xorg.conf", "nsswitch.conf",
    "rkhunter.conf", "sudoers", "policy-rc.d", "adjtime", "ncz.conf",
}

COMPRESSED_MAGIC = (
    (b"\x1f\x8b\x08", "gzip"),
    (b"BZh", "bzip2"),
    (b"\xfd7zXZ\x00", "xz"),
    (b"\x28\xb5\x2f\xfd", "zstd"),
    (b"\x5d\x00\x00", "lzma"),
    (b"\x04\x22\x4d\x18", "lz4"),
    (b"\x89LZO\x00\r\n\x1a\n", "lzo"),
)
ARCHIVE_MAGIC = (
    (b"070701", "cpio-newc"),
    (b"070702", "cpio-crc"),
    (b"070707", "cpio-odc"),
    (b"ustar", "tar"),
    (b"PK\x03\x04", "zip"),
)

FIXTURE_SECRET = ["ncz", "fixture", "leak", "token"]


def lex_overlap() -> int:
    """Overlap between lexing chunks: comfortably longer than any token we
    look at (the longest documented secret form is a 40-byte PEM line), so a
    token straddling a chunk boundary is lexed whole in the next chunk."""
    return 256


class Unreadable(Exception):
    """Anything that stops us proving a byte range clean.  Always fatal."""


# ---------------------------------------------------------------------------
# tiny helpers
# ---------------------------------------------------------------------------
def human(n: int) -> str:
    step = 0.0
    val = float(n)
    for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
        if val < 1024 or unit == "TiB":
            return f"{val:.1f}{unit}" if unit != "B" else f"{int(val)}B"
        val /= 1024
    return f"{n}B"


def which_all(names):
    """[(name, path-or-None)] -- a missing tool is reported, never guessed."""
    return [(n, shutil.which(n)) for n in names]


def b64_variant(raw: bytes) -> bytes:
    """base64 with the punctuation (and lenient padding) that survives being
    embedded in shell, JSON and YAML."""
    return base64.b64encode(raw)


# ---------------------------------------------------------------------------
# hash list
# ---------------------------------------------------------------------------
class HashSet:
    """Salted-SHA256 hash list, nothing else.  Never holds a plaintext value."""

    def __init__(self, salt: str = DEFAULT_SALT):
        self.salt = salt.encode()
        self.digests = set()

    def add(self, value: bytes) -> None:
        self.digests.add(hashlib.sha256(self.salt + value).hexdigest())

    def __len__(self) -> int:
        return len(self.digests)

    def digest(self, value: bytes) -> str:
        return hashlib.sha256(self.salt + value).hexdigest()

    def __contains__(self, value: bytes) -> bool:
        return self.digest(value) in self.digests

    def load(self, path: str) -> int:
        """Load a hash file (strict JSON).  A malformed line is fatal: a hash
        list we cannot trust is the same as no gate at all."""
        try:
            with open(path, "r", encoding="utf-8") as fh:
                doc = json.load(fh)
        except OSError as exc:
            raise Unreadable(f"cannot read the hash file {path}: {exc}")
        except ValueError as exc:
            raise Unreadable(f"the hash file {path} is not valid JSON: {exc}")
        if not isinstance(doc, dict):
            raise Unreadable(f"the hash file {path} is not a JSON object")
        if doc.get("format") != "ncz-secret-hashes":
            raise Unreadable(
                f"the hash file {path} has no 'format': 'ncz-secret-hashes' "
                f"marker -- produce it with build/make-secret-hashes.py")
        salt = doc.get("salt")
        if not isinstance(salt, str) or not salt:
            raise Unreadable(f"the hash file {path} has no salt")
        entries = doc.get("hashes")
        if not isinstance(entries, list):
            raise Unreadable(f"the hash file {path} has no 'hashes' list")
        self.salt = salt.encode()
        for item in entries:
            h = item.get("sha256") if isinstance(item, dict) else None
            if not isinstance(h, str) or not re.fullmatch(r"[0-9a-f]{64}", h):
                raise Unreadable(f"the hash file {path} holds a malformed entry")
            self.digests.add(h)
        return len(self.digests)


def secret_variants(values, salt: str = DEFAULT_SALT) -> list[dict]:
    """Every form a value can be embedded as, as (kind, sha256) pairs.

    Shared verbatim by build/make-secret-hashes.py (which writes them) and this
    gate (which looks them up), so the two can never disagree about coverage.

      raw / urlenc / base64   at offsets 0, 1 and 2.  Offset 0 is the value at
                              the start of a token ("export TOKEN=<value>");
                              offsets 1 and 2 are the value mid-token
                              ("x<value>", "gitlab+deploy-token-1:<value>@").
      b64[p:s]                the base64 of a value that sits at byte phase p
                              (p bytes of foreign data in front of it in the
                              same 3-byte group), looked up starting s base64
                              characters in.  A secret found mid-string does
                              not sit on a base64 boundary of its own, and a
                              JSON/URL encoder does not care.

    No prefix form: a prefix of a secret that happens to appear in shipped
    bytes would fail the gate on innocent text without covering anything a
    suffix/offset form does not.
    """
    out: list[dict] = []
    seen: set[str] = set()

    def add(kind: str, raw: bytes, min_len: int) -> None:
        if len(raw) < min_len:
            return
        h = hashlib.sha256(salt.encode() + raw).hexdigest()
        if h in seen:
            return
        seen.add(h)
        out.append({"kind": kind, "sha256": h})

    for value in values:
        if not value:
            continue
        forms = [("raw", value)]
        try:
            text = value.decode("utf-8")
        except UnicodeDecodeError:
            text = None
        if text is not None:
            for helper, label in (
                (urllib.parse.quote_plus, "urlenc-plus"),
                (urllib.parse.quote, "urlenc"),
                (lambda t: urllib.parse.quote_plus(t, safe=""), "urlenc-all"),
            ):
                enc = helper(text).encode()
                if enc != value:
                    forms.append((label, enc))
        b64 = base64.b64encode(value)
        forms.append(("base64", b64))
        if b64.rstrip(b"=") != b64:
            forms.append(("base64-unpadded", b64.rstrip(b"=")))
        for label, enc in forms:
            # base64 output is already aligned to a 3-byte group of its own,
            # so offset forms of it would only duplicate b64[0:s]; it still
            # needs the s>0 covers below.
            for offset in ((0,) if label.startswith("base64") else (0, 1, 2)):
                add(f"{label}:o{offset}", enc[offset:], 8)
        for label, enc in forms:
            if label.startswith("base64"):
                continue
            for phase in (0, 1, 2):
                body = base64.b64encode(b"\x00" * phase + enc)
                # the first ceil(phase*4/3) chars encode our synthetic pad
                cut = (4 * phase) // 3
                tail = body.rstrip(b"=")
                for start in range(0, 3):
                    part = tail[cut + start:]
                    add(f"b64[{phase}:{start}]", part, 8)
    return out


# ---------------------------------------------------------------------------
# GPT + partitions (no loop mount, no root, image opened read-only)
# ---------------------------------------------------------------------------
# A GPT type GUID is stored as the 16 raw on-disk bytes, i.e. the first three
# fields little-endian (mixed-endian).  Comparing the raw bytes is the only
# correct test: hex()-ing them yields "28732ac1..." for the EFI System
# Partition, NOT the "c12a7328-..." form every tool prints.  Getting this
# wrong sent the ESP down the ext4 path and failed the gate on a valid image.
ESP_TYPE_GUID = uuid.UUID("c12a7328-f81f-11d2-ba4b-00a0c93ec93b").bytes_le
LINUX_FS_TYPE_GUID = uuid.UUID("0fc63daf-8483-4772-8e79-3d69d8477de4").bytes_le
# Data partitions we know how to read; anything else must still be readable
# (fail closed) but is announced in the receipt.
EXT_TYPE_GUIDS = {
    LINUX_FS_TYPE_GUID: "linux-fs",
    uuid.UUID("e6d6d379-f507-44c2-a23c-238f2a3df928").bytes_le: "linux-lvm",
    uuid.UUID("0657fd6d-a4ab-43c4-84e5-0933c84b4f4f").bytes_le: "linux-swap",
}


def guid_kind(raw: bytes) -> str:
    if raw == ESP_TYPE_GUID:
        return "fat"
    if raw in EXT_TYPE_GUIDS:
        return "ext"
    return "ext"          # unknown layout: read as ext, fail closed if not


def parse_gpt(fh) -> list[dict]:
    """Partitions from a protective-MBR GPT.  Verifies both header CRCs and
    the entry-array CRC, so a corrupt table is an error, not an empty disk."""
    fh.seek(0)
    mbr = fh.read(512)
    if len(mbr) < 512:
        raise Unreadable("the image is shorter than one sector")
    parts: list[dict] = []
    if mbr[510:512] != b"\x55\xAA":
        raise Unreadable("the image has no MBR signature")
    for slot in range(4):
        ent = mbr[446 + slot * 16: 446 + (slot + 1) * 16]
        ptype = ent[4]
        if ptype == 0xEE:
            break
    else:
        raise Unreadable("no protective MBR entry: this is not a GPT image")
    fh.seek(512)
    hdr = fh.read(92)
    if len(hdr) < 92 or hdr[:8] != b"EFI PART":
        raise Unreadable("no GPT header in LBA 1")
    hdr_size = struct.unpack_from("<I", hdr, 12)[0]
    if not 92 <= hdr_size <= 512:
        raise Unreadable(f"implausible GPT header size {hdr_size}")
    fh.seek(512)
    full = fh.read(hdr_size)
    if struct.unpack_from("<I", full, 16)[0] != zlib.crc32(full[:16] + b"\0\0\0\0" + full[20:]):
        raise Unreadable("GPT header CRC mismatch")
    lba, n_ent, ent_size = struct.unpack_from("<QII", hdr, 72)
    if ent_size < 128 or ent_size % 8 or n_ent == 0 or n_ent > 1024:
        raise Unreadable("implausible GPT entry array")
    fh.seek(lba * 512)
    arr = fh.read(n_ent * ent_size)
    if len(arr) != n_ent * ent_size:
        raise Unreadable("truncated GPT entry array")
    if struct.unpack_from("<I", hdr, 88)[0] != zlib.crc32(arr):
        raise Unreadable("GPT entry-array CRC mismatch")
    for i in range(n_ent):
        e = arr[i * ent_size:(i + 1) * ent_size]
        if e[:16] == b"\0" * 16:
            continue
        first, last = struct.unpack_from("<QQ", e, 32)
        parts.append({
            "index": i + 1,
            "type_guid": str(uuid.UUID(bytes_le=bytes(e[:16]))),
            "kind": guid_kind(bytes(e[:16])),
            "first_lba": first,
            "last_lba": last,
            "offset": first * 512,
            "length": (last - first + 1) * 512,
        })
    if not parts:
        raise Unreadable("the GPT has no partitions")
    return parts


def fat_walk(img_fh, part: dict) -> list[dict]:
    """Files on a FAT12/16/32 ESP.  Directories are walked by hand (the ESP is
    small); every file is returned with its byte span inside the image."""
    base = part["offset"]
    img_fh.seek(base)
    bs = img_fh.read(512)
    if len(bs) < 512 or bs[510:512] != b"\x55\xAA":
        raise Unreadable(f"partition {part['index']}: no FAT boot sector")
    bps, spc, reserved, nfats, root_entries, tot16, media, fat16 = struct.unpack_from(
        "<HBHBHHBH", bs, 11)
    tot32 = struct.unpack_from("<I", bs, 32)[0]
    fat32_size = struct.unpack_from("<I", bs, 36)[0]
    if bps not in (512, 1024, 2048, 4096):
        raise Unreadable(f"partition {part['index']}: bad FAT sector size {bps}")
    fatsz = fat16 or fat32_size
    if not fatsz or not spc:
        raise Unreadable(f"partition {part['index']}: FAT geometry is zero")
    total = tot16 or tot32
    if not total:
        raise Unreadable(f"partition {part['index']}: FAT sector count is zero")
    root_secs = ((root_entries * 32) + bps - 1) // bps
    data_sec = reserved + nfats * fatsz + root_secs
    cluster_bytes = bps * spc
    if cluster_bytes == 0:
        raise Unreadable(f"partition {part['index']}: zero cluster size")
    nclusters = max(0, (total - data_sec) // spc)
    fat_bits = 32 if (fat32_size and not fat16 and nclusters >= 65525) else (12 if nclusters < 4085 else 16)

    def read_fat() -> bytes:
        img_fh.seek(base + reserved * bps)
        return img_fh.read(fatsz * bps)

    fat = read_fat()
    if len(fat) < fatsz * bps:
        raise Unreadable(f"partition {part['index']}: truncated FAT")

    def next_cluster(n: int) -> int:
        if fat_bits == 32:
            off = n * 4
            if off + 4 > len(fat):
                raise Unreadable(f"partition {part['index']}: FAT32 entry out of range")
            v = struct.unpack_from("<I", fat, off)[0] & 0x0FFFFFFF
            return -1 if v >= 0x0FFFFFF8 else (-2 if v == 0x0FFFFFF7 else v)
        if fat_bits == 16:
            off = n * 2
            if off + 2 > len(fat):
                raise Unreadable(f"partition {part['index']}: FAT16 entry out of range")
            v = struct.unpack_from("<H", fat, off)[0]
            return -1 if v >= 0xFFF8 else (-2 if v == 0xFFF7 else v)
        off = (n * 3) // 2
        if off + 2 > len(fat):
            raise Unreadable(f"partition {part['index']}: FAT12 entry out of range")
        v = struct.unpack_from("<H", fat, off)[0]
        v = (v >> 4) if (n & 1) else (v & 0x0FFF)
        return -1 if v >= 0xFF8 else (-2 if v == 0xFF7 else v)

    def cluster_off(n: int) -> int:
        return base + (data_sec + (n - 2) * spc) * bps

    def chain(start: int) -> list[int]:
        out, seen, cur = [], set(), start
        while cur >= 2:
            if cur in seen or len(out) > total:
                raise Unreadable(f"partition {part['index']}: FAT cluster loop")
            seen.add(cur)
            out.append(cur)
            cur = next_cluster(cur)
        if cur == -2:
            raise Unreadable(f"partition {part['index']}: bad FAT cluster")
        return out

    files: list[dict] = []
    lfn = ""
    queue = [("", 0 if fat_bits == 32 else None)]

    def entries_of(cluster: int | None):
        if cluster is None:
            img_fh.seek(base + (reserved + nfats * fatsz) * bps)
            return img_fh.read(root_entries * 32)
        # seek() returns the new offset (never falsy for cluster 2+), so
        # `seek(...) or read(...)` reads NOTHING -- seek, then read.
        chunks = []
        for c in chain(cluster):
            img_fh.seek(cluster_off(c))
            chunks.append(img_fh.read(cluster_bytes))
        return b"".join(chunks)

    while queue:
        path, cluster = queue.pop()
        raw = entries_of(cluster)
        lfn = ""
        for i in range(0, len(raw) - 31, 32):
            ent = raw[i:i + 32]
            if ent[0] == 0:
                break
            if ent[0] == 0xE5:
                lfn = ""
                continue
            attr = ent[11]
            if attr == 0x0F:
                chunk = ent[1:11] + ent[14:26] + ent[28:32]
                if ent[0] & 0x40:
                    lfn = ""
                lfn = chunk.decode("utf-16-le", "ignore").split("\x00")[0] + lfn
                continue
            short = ent[0:8].decode("ascii", "replace").rstrip()
            ext = ent[8:11].decode("ascii", "replace").rstrip()
            name = lfn or (short + (("." + ext) if ext else ""))
            lfn = ""
            if name in (".", ".."):
                continue
            if attr & 0x08:
                continue  # volume label
            hi = struct.unpack_from("<H", ent, 20)[0] if fat_bits == 32 else 0
            start = (hi << 16) | struct.unpack_from("<H", ent, 26)[0]
            size = struct.unpack_from("<I", ent, 28)[0]
            full = f"{path}/{name}".lstrip("/")
            if attr & 0x10:
                queue.append((full, start))
            else:
                clusters = chain(start) if start >= 2 else []
                chunks = []
                for c in clusters:
                    img_fh.seek(cluster_off(c))
                    chunks.append(img_fh.read(cluster_bytes))
                    if sum(len(x) for x in chunks) >= size:
                        break
                span = b"".join(chunks)
                # A file whose cluster chain is shorter than its size would
                # be scanned truncated -- a secret past the cut would pass.
                if len(span) < size:
                    raise Unreadable(f"partition {part['index']}: FAT cluster chain "
                                     f"for /{full} is short ({len(span)} < {size})")
                files.append({"path": "/" + full, "bytes": span[:size]})
    return files


def blocked_features() -> list[tuple[int, int, str]]:
    """(section, bit, name) for every feature that changes how file BYTES are
    stored and that the reader in ext4_walk() does NOT implement.  Sections:
    0 = s_feature_compat @92, 1 = s_feature_incompat @96,
    2 = s_feature_ro_compat @100 (little-endian u32 each).

    Everything listed fails closed: content we cannot read is content we
    cannot clear.  Everything NOT listed is either harmless metadata or is
    walked below (extents 0x40, 64bit descriptors 0x80, FILETYPE 0x2
    directories, FLEX_BG 0x200, CHECKSUM_SEED 0x2000, classic indirect
    blocks, htree directories scanned linearly, metadata_csum inodes).

    The bits that MUST NOT appear here, from the ext4 on-disk layout:
      - incompat 0x2 FILETYPE, 0x40 EXTENTS, 0x80 64BIT and 0x200 FLEX_BG
        are set by every ext4 mke2fs creates, so blocking them rejects every
        real image;
      - incompat 0x10 META_BG (not 0x200);
      - bigalloc is RO_COMPAT 0x200, not incompat;
      - VERITY is RO_COMPAT 0x80000, CASEFOLD 0x10000, INLINE_DATA 0x40000,
        ENCRYPT 0x8000, all RO_COMPAT.
    A previous revision read section 96 for all three and shifted most of
    these, so the gate rejected a clean fixture image.
    """
    return [
        # --- incompat: the layout itself is unreadable
        (1, 0x0010, "meta-bg"),          # group descriptors are not in a flat table
        (1, 0x0008, "journal-dev"),      # data lives on an external journal
        # --- ro_compat: readable only by a filesystem that knows the feature
        (2, 0x0200, "bigalloc"),         # clusters != blocks; the guard below refuses it
        (2, 0x8000, "encrypt"),          # ciphertext on disk
        (2, 0x10000, "casefold"),        # names are transformed on disk
        (2, 0x40000, "inline-data"),     # small files live inside the inode
        (2, 0x80000, "verity"),          # a digest we cannot check
    ]


def blocked_incompat_features():
    """Backwards-compatible view: the incompat+ro_compat bits that block."""
    return [(bit, name) for sect, bit, name in blocked_features() if sect in (1, 2)]


def ext4_walk(img_fh, part: dict) -> list[dict]:
    """Files on an ext2/3/4 data partition (the payload partition)."""
    base = part["offset"]
    img_fh.seek(base + 1024)
    sb = img_fh.read(1024)
    if len(sb) < 1024 or struct.unpack_from("<H", sb, 56)[0] != 0xEF53:
        raise Unreadable(f"partition {part['index']}: no ext superblock")
    # s_log_block_size is the log2 of the block size MINUS 10: 0 is the legal
    # 1024-byte block mke2fs picks for a small filesystem (the fixture images,
    # and any operator-built payload partition under 512 MiB).
    log_bs = struct.unpack_from("<I", sb, 24)[0]
    if not 0 <= log_bs <= 6:
        raise Unreadable(f"partition {part['index']}: bad ext block size (log2-10={log_bs})")
    bs = 1 << (log_bs + 10)
    blocks_lo, = struct.unpack_from("<I", sb, 4)
    blocks_hi = (struct.unpack_from("<I", sb, 0x150)[0]
                 if struct.unpack_from("<I", sb, 0x60)[0] & 0x1 else 0)
    nblocks = blocks_lo | (blocks_hi << 32)
    inode_size, = struct.unpack_from("<H", sb, 88)
    n_inodes, = struct.unpack_from("<I", sb, 0)
    desc_size = (struct.unpack_from("<H", sb, 0xFE)[0]
                 if struct.unpack_from("<I", sb, 0x60)[0] & 0x80 else 32)
    # Layout (ext4 superblock): s_feature_compat @92, s_feature_incompat @96,
    # s_feature_ro_compat @100, s_desc_size @254.  Refuse only the incompat
    # features that change how file BYTES are stored; the normal mke2fs
    # defaults (extents, 64bit, dir_index, metadata_csum ...) are all read
    # below.  Inline data and encryption in particular would hide content
    # from a plain byte reader, so they fail closed.
    compat, = struct.unpack_from("<I", sb, 92)
    incompat, = struct.unpack_from("<I", sb, 96)
    ro_compat, = struct.unpack_from("<I", sb, 100)
    for sect, bit, name in blocked_features():
        if (compat, incompat, ro_compat)[sect] & bit:
            raise Unreadable(f"partition {part['index']}: ext4 {name} "
                             f"(compat=0x{compat:x} incompat=0x{incompat:x} "
                             f"ro_compat=0x{ro_compat:x})")
    has_64bit = bool(incompat & 0x80)
    inodes_per_group, = struct.unpack_from("<I", sb, 40)
    if not inode_size or not inodes_per_group:
        raise Unreadable(f"partition {part['index']}: zero inode geometry")
    desc_per_block = bs // desc_size
    # Block that holds the superblock: 0 for a 1KiB filesystem (the 1024-byte
    # superblock sits at byte 1024), 1 for every larger block size.
    superblock_block = 1 if bs == 1024 else 0
    groups = (nblocks - struct.unpack_from("<I", sb, 12)[0] - 1) // struct.unpack_from(
        "<I", sb, 32)[0] + 1 if struct.unpack_from("<I", sb, 32)[0] else 0
    if groups <= 0:
        raise Unreadable(f"partition {part['index']}: zero block groups")

    def read_block(n: int) -> bytes:
        if not 0 <= n < nblocks:
            raise Unreadable(f"partition {part['index']}: block {n} is outside "
                             f"the filesystem (0..{nblocks - 1})")
        img_fh.seek(base + n * bs)
        return img_fh.read(bs)

    def group_desc(g: int) -> tuple[int, int]:
        # The group descriptor table starts in the block AFTER the superblock
        # block: with a 1KiB block size the superblock is block 0, so the GDT
        # begins at block 1 -> byte 1024 -> which is *block 1* only when
        # bs > 1024.  The spec form is 1 + s_first_data_block... no: it is
        # the block following the superblock, i.e. block
        # (1024 // bs) + 1 when bs <= 1024 and 1 otherwise.  Reading block 1
        # of a 1KiB filesystem lands INSIDE the superblock and yields garbage
        # inode-table pointers (this was a live bug: every 1KiB ext4 failed).
        blk = (superblock_block + 1) + (g // desc_per_block)
        off = (g % desc_per_block) * desc_size
        d = read_block(blk)
        if len(d) < off + desc_size:
            raise Unreadable(f"partition {part['index']}: truncated group descriptor")
        hi_lo = struct.unpack_from("<I", d, off)[0]  # block bitmap lo
        ino_tbl, = struct.unpack_from("<I", d, off + 8)
        if has_64bit:
            ino_tbl |= struct.unpack_from("<I", d, off + 0x28)[0] << 32
        return hi_lo, ino_tbl

    def inode(i: int) -> dict:
        if not 1 <= i <= n_inodes:
            raise Unreadable(f"partition {part['index']}: directory entry points "
                             f"at inode {i} (valid: 1..{n_inodes})")
        g, idx = divmod(i - 1, inodes_per_group)
        _, tbl = group_desc(g)
        blk = tbl + (idx * inode_size) // bs
        off = (idx * inode_size) % bs
        raw = read_block(blk)[off:off + inode_size]
        if len(raw) < inode_size:
            raise Unreadable(f"partition {part['index']}: truncated inode {i}")
        mode, = struct.unpack_from("<H", raw, 0)
        size = struct.unpack_from("<I", raw, 4)[0]
        size |= struct.unpack_from("<I", raw, 108)[0] << 32
        flags, = struct.unpack_from("<I", raw, 32)
        blocks = list(struct.unpack_from("<15I", raw, 40))
        extra = 0
        if (flags & 0x80000) and inode_size >= 160:
            extra, = struct.unpack_from("<H", raw, 128)
        return {"mode": mode, "size": size, "flags": flags, "blocks": blocks,
                "extra": extra}

    def extents(ino: dict) -> list[tuple[int, int, int, bool]]:
        """[(logical, length, physical-or-target, unwritten)]"""
        if ino["flags"] & 0x80000:
            # i_block (60 bytes, = ino["blocks"][:15] as u32s) IS the root
            # extent header + entries, whatever s_extra_isize says.  Reading
            # blocks[0] as a block number was a live bug: 127754 is the first
            # four bytes of the header, not a disk address.
            root = struct.pack("<15I", *ino["blocks"])
            out = []
            stack = [bytes(root)]
            while stack:
                node = stack.pop()
                magic, entries, _max, depth = struct.unpack_from("<HHHH", node, 0)
                if magic != 0xF30A:
                    raise Unreadable(f"partition {part['index']}: bad extent magic")
                for k in range(entries):
                    e = node[12 + k * 12: 24 + k * 12]
                    if len(e) < 12:
                        raise Unreadable(f"partition {part['index']}: truncated extent entry")
                    if depth:
                        child_lo, = struct.unpack_from("<I", e, 4)
                        child_hi, = struct.unpack_from("<H", e, 8)
                        stack.append(read_block(child_lo | (child_hi << 32)))
                    else:
                        # struct ext4_extent: ee_block(u32 @0) ee_len(u16 @4)
                        # ee_start_hi(u16 @6) ee_start_lo(u32 @8).  EE_LEN
                        # 0x8000 marks an initialized; 0x8000 alone means
                        # uninitialized, and EXT4_EXTENT_EOF (0x20000000) is
                        # a sentinel, not a physical block.
                        lblk, raw_len, start_hi, start_lo = struct.unpack_from(
                            "<IHHI", e, 0)
                        uninit = bool(raw_len & 0x8000)
                        ln = raw_len & 0x7FFF
                        if ln == 0:
                            continue
                        if lblk & 0x20000000:
                            continue          # EXT4_EXTENT_EOF sentinel
                        out.append((lblk, ln, start_lo | (start_hi << 32),
                                    uninit))
            return out
        # classic block map: 12 direct + single + double + triple indirect
        out: list[tuple[int, int, int, bool]] = []
        per = bs // 4
        nblocks_total = (ino["size"] + bs - 1) // bs

        for b in ino["blocks"][:12]:
            out.append((len(out), 1, b, False))
        def walk_indirect(ptr, depth, limit):
            if len(out) >= limit:
                return
            if ptr < 1 or ptr > nblocks:
                raise Unreadable(f"partition {part['index']}: indirect block out of range")
            data = read_block(ptr)
            for k in range(per):
                nxt, = struct.unpack_from("<I", data, k * 4)
                if len(out) >= limit:
                    return
                if depth == 1:
                    if nxt:
                        out.append((len(out), 1, nxt, False))
                elif nxt:
                    walk_indirect(nxt, depth - 1, limit)
        walk_indirect(ino["blocks"][12], 1, nblocks_total)
        if nblocks_total > per:
            walk_indirect(ino["blocks"][13], 2, nblocks_total)
        if nblocks_total > per + per * per:
            walk_indirect(ino["blocks"][14], 3, nblocks_total)
        return out

    def file_bytes(ino: dict) -> bytes:
        """The file's LOGICAL bytes, with holes as zeroes, so the length always
        equals st_size.  A short buffer here silently truncates an artifact
        (unsquashfs then reports "file system corruption" on bytes the gate
        handed it), so the extent map is applied to the size we were told."""
        size = ino["size"]
        out = bytearray(size)
        for lblk, ln, phys, _unwritten in sorted(extents(ino)):
            if phys == 0:
                continue      # a hole reads as zeroes; nothing to scan
            if phys > nblocks:
                raise Unreadable(f"partition {part['index']}: extent points past "
                                 f"the last block ({phys} > {nblocks})")
            start = lblk * bs
            if start >= size:
                continue
            n = min(ln * bs, size - start)
            img_fh.seek(base + phys * bs)
            chunk = img_fh.read(n)
            if len(chunk) < n:
                raise Unreadable(f"partition {part['index']}: short read at "
                                 f"block {phys} (wanted {n}, got {len(chunk)})")
            out[start:start + n] = chunk
        return bytes(out)

    def dir_entries(ino: dict):
        data = file_bytes(ino)
        pos = 0
        while pos + 8 <= len(data):
            child, rec_len = struct.unpack_from("<IH", data, pos)
            name_len = data[pos + 6]
            if rec_len < 8 or pos + rec_len > len(data):
                raise Unreadable(f"partition {part['index']}: corrupt directory entry")
            # inode 0 is the "unused/deleted" marker (a tail entry has it);
            # a nameless remainder entry is padding, not a child.
            if child and name_len:
                yield child, data[pos + 8: pos + 8 + name_len].decode("utf-8", "replace")
            pos += rec_len

    files: list[dict] = []
    stack = [("/", 2)]
    seen = set()
    while stack:
        path, ino_no = stack.pop()
        if ino_no in seen:
            continue
        seen.add(ino_no)
        ino = inode(ino_no)
        if not stat.S_ISDIR(ino["mode"]):
            continue
        for child, name in dir_entries(ino):
            if name in (".", ".."):
                continue
            full = path.rstrip("/") + "/" + name
            ci = inode(child)
            if stat.S_ISDIR(ci["mode"]):
                stack.append((full, child))
            elif stat.S_ISREG(ci["mode"]):
                files.append({"path": full, "bytes": file_bytes(ci)})
    return files


# ---------------------------------------------------------------------------
# archives (tar / cpio / deb / zip), recursively expanded
# ---------------------------------------------------------------------------
def is_public_keyring(path: str) -> bool:
    return bool(PUBLIC_KEYRING_DIRS.search(path) or PUBLIC_KEYRING_NAMES.search(path))


def decompress_chain(data: bytes, label: str) -> list[tuple[str, bytes]]:
    """Every decompression layer of ``data``: [('gzip', plain), ...].  Nested
    compression (xz inside gzip inside cpio) is expanded to the bottom.  Every
    intermediate stream is itself returned so it is scanned too."""
    out: list[tuple[str, bytes]] = []
    cur = data
    for _ in range(4):
        kind = None
        for magic, name in COMPRESSED_MAGIC:
            if cur.startswith(magic):
                kind = name
                break
        if kind is None:
            break
        try:
            if kind == "gzip":
                # every gzip MEMBER, then every cpio segment inside each
                parts, rest = [], cur
                while rest.startswith(b"\x1f\x8b\x08"):
                    d = zlib.decompressobj(16 + zlib.MAX_WBITS)
                    plain = d.decompress(rest) + d.flush()
                    if not d.eof:
                        raise ValueError("truncated gzip member")
                    parts.append(plain)
                    rest = d.unused_data
                cur = b"\n".join(parts) if parts else b""
            elif kind == "bzip2":
                cur = bz2.decompress(cur)
            elif kind == "xz":
                cur = lzma.decompress(cur)
            elif kind == "lzma":
                cur = lzma.decompress(cur, format=lzma.FORMAT_ALONE)
            elif kind == "zstd":
                cur = subprocess.run(["zstd", "-dcq"], input=cur,
                                     capture_output=True, check=False)
                if cur.returncode != 0:
                    raise Unreadable(f"{label}: zstd refused the stream: "
                                     f"{cur.stderr[:200].decode('replace')}")
                cur = cur.stdout
            else:
                raise Unreadable(f"{label}: {kind} compression is not supported "
                                 "by this gate; refusing to call the bytes clean")
        except (OSError, ValueError, zlib.error, lzma.LZMAError) as exc:
            raise Unreadable(f"{label}: {kind} stream is corrupt: {exc}")
        if len(cur) > MAX_MEMBER_BYTES:
            raise Unreadable(f"{label}: {kind} expands past {MAX_MEMBER_BYTES} bytes")
        out.append((kind, cur))
    return out


def _truncate(b: bytes, label: str) -> bytes:
    if len(b) > MAX_MEMBER_BYTES:
        raise Unreadable(f"{label}: member exceeds {MAX_MEMBER_BYTES} bytes")
    return b


def cpio_members(data: bytes, label: str):
    """Yield (name, payload) for every entry of every concatenated cpio
    segment.  Strict, like the kernel: junk, truncation and a missing TRAILER
    are errors -- a stream we cannot fully parse is a stream we cannot clear."""
    pos, end, segments, seen_trailer = 0, len(data), 0, False
    while True:
        while pos < end and data[pos] == 0:
            pos += 1
        if pos >= end:
            break
        if pos + 110 > end:
            raise Unreadable(f"{label}: truncated cpio header at {pos}")
        magic = data[pos:pos + 6]
        if magic in (b"070701", b"070702"):
            hdr = data[pos:pos + 110]
            try:
                filesize = int(hdr[54:62], 16)
                namesize = int(hdr[94:102], 16)
            except ValueError:
                raise Unreadable(f"{label}: non-hex cpio header at {pos}")
            if namesize < 1:
                raise Unreadable(f"{label}: cpio entry with an empty name at {pos}")
            name_end = pos + 110 + namesize
            if name_end > end or data[name_end - 1] != 0:
                raise Unreadable(f"{label}: truncated cpio name at {pos}")
            name = data[pos + 110:name_end - 1].decode("utf-8", "replace")
            body = name_end + ((-name_end) % 4)
            if body + filesize > end:
                raise Unreadable(f"{label}: truncated cpio body for {name}")
            payload = data[body:body + filesize]
            nxt = body + filesize
            pos = nxt + ((-nxt) % 4)
            if name == "TRAILER!!!":
                segments += 1
                seen_trailer = True
                continue
            seen_trailer = False
            # A directory ("." and every subdirectory) is an entry, not
            # content: it is yielded with an empty payload so the caller's
            # member count stays honest, and expand() drops it.
            if name in (".", "./") and payload:
                raise Unreadable(f"{label}: directory entry '.' carries data")
            yield name, payload
            continue
        if magic == b"070707":
            raise Unreadable(f"{label}: odc cpio is not produced by any NCZ "
                             "build; refusing to parse it loosely")
        raise Unreadable(f"{label}: junk at offset {pos} ({data[pos:pos + 8]!r})")
    if segments == 0 or not seen_trailer:
        raise Unreadable(f"{label}: no terminated cpio segment found")


def tar_members(data: bytes, label: str):
    try:
        with tarfile.open(fileobj=io.BytesIO(data), mode="r:") as tf:
            for m in tf:
                if m.isfile():
                    fh = tf.extractfile(m)
                    yield m.name, _truncate(fh.read(), f"{label}/{m.name}")
                elif m.issym() or m.islnk():
                    # a link target is a name, not content; scan the string
                    yield m.name, m.linkname.encode("utf-8", "replace")
    except (tarfile.TarError, OSError) as exc:
        raise Unreadable(f"{label}: tar stream is corrupt: {exc}")


def ar_members(data: bytes, label: str):
    """[(name, payload)] of a .deb (ar archive), strictly."""
    if not data.startswith(b"!<arch>\n"):
        raise Unreadable(f"{label}: not an ar archive")
    pos, end = 8, len(data)
    out = []
    while pos < end:
        if pos + 60 > end:
            raise Unreadable(f"{label}: truncated ar header")
        hdr = data[pos:pos + 60]
        if hdr[58:60] != b"`\n":
            raise Unreadable(f"{label}: bad ar header terminator")
        name = hdr[0:16].decode("ascii", "replace").strip().rstrip("/")
        try:
            size = int(hdr[48:58].decode("ascii").strip() or "0")
        except ValueError:
            raise Unreadable(f"{label}: bad ar member size")
        start = pos + 60
        if start + size > end:
            raise Unreadable(f"{label}: truncated ar member {name}")
        out.append((name, data[start:start + size]))
        pos = start + size + (size & 1)
    return out


def expand(name: str, data: bytes, label: str, depth: int = 0):
    """Yield (member_path, payload) for everything ``data`` contains, recursing
    through nested archives and compression."""
    if depth > 4:
        raise Unreadable(f"{label}: nested archives deeper than 4 levels")
    for kind, plain in decompress_chain(data, label):
        data = plain
    if data.startswith(b"!<arch>\n"):
        for mname, payload in ar_members(data, label):
            if mname.startswith(("data.tar", "control.tar")):
                yield from expand(mname, payload, f"{label}/{mname}", depth + 1)
            else:
                yield f"{label}/{mname}", payload
        return
    if data[:6] in (b"070701", b"070702", b"070707"):
        for mname, payload in cpio_members(data, label):
            if not payload or mname in (".", "./"):
                continue          # a directory entry, never content
            yield f"{label}/{mname.lstrip('./')}", payload
        return
    if len(data) > 262 and data[257:262] == b"ustar":
        for mname, payload in tar_members(data, label):
            yield f"{label}/{mname}", payload
        return
    if data.startswith(b"PK\x03\x04"):
        try:
            with zipfile.ZipFile(io.BytesIO(data)) as zf:
                for info in zf.infolist():
                    if info.is_dir():
                        continue
                    yield (f"{label}/{info.filename}",
                           _truncate(zf.read(info), f"{label}/{info.filename}"))
        except (zipfile.BadZipFile, OSError) as exc:
            raise Unreadable(f"{label}: zip stream is corrupt: {exc}")
        return
    # a leaf: the (already decompressed) bytes themselves
    return


# ---------------------------------------------------------------------------
# matching engine
# ---------------------------------------------------------------------------
def looks_textual(path: str) -> bool:
    base = os.path.basename(path)
    if base in TEXT_NAMES or re.match(r"^(shadow|passwd|group|gshadow)-?$", base):
        return True
    ext = os.path.splitext(base)[1].lower()
    if ext in TEXT_EXT:
        return True
    if base.startswith(("/etc/", "/usr/lib/systemd/", "/etc/systemd/")) and "." not in base:
        return True
    return False


def is_binary(data: bytes) -> bool:
    sample = data[:4096]
    if b"\x00" in sample:
        return True
    if not sample:
        return False
    ctrl = sum(1 for b in sample if b < 9 or (13 < b < 32))
    return ctrl / len(sample) > 0.05


class Scanner:
    """Hashes candidate windows against the hash list and runs the token-shape
    scan.  Findings carry a location and a kind -- never a value."""

    def __init__(self, hashes: HashSet, shapes: bool = True):
        self.hashes = hashes
        self.shapes = shapes

    # -- token shapes ---------------------------------------------------
    def scan_shapes(self, data: bytes, path: str) -> list[dict]:
        hits: list[dict] = []
        public_keyring = is_public_keyring(path)
        for name, rx in TOKEN_SHAPES.items():
            for m in rx.finditer(data):
                if name == "pem-private-key":
                    window = data[max(0, m.start() - 4096):m.start()]
                    if NON_SECRET_PEM_LABELS.search(window[-120:]):
                        continue
                    hits.append({"kind": "token-shape", "shape": name,
                                 "offset": m.start()})
                    continue
                if public_keyring:
                    continue
                hits.append({"kind": "token-shape", "shape": name,
                             "offset": m.start()})
        return hits


def tokenise(data: bytes) -> list[bytes]:
    """Candidate strings the hash list is looked up against.

    Runs (``[A-Za-z0-9_+\\-/=.:~!@$%^&*()'"]{3,}``) cover config/shell/JSON
    embeddings; alphanumeric runs cover a secret abutted by punctuation;
    lowercase word slugs cover a passphrase written with spaces
    ("\"my leaked phrase\"").  Adjacent runs are joined per chunk so
    ``TOKEN=glpat-...`` is looked up as a whole as well.  A slug only ever
    contains its own words, so a multi-word secret can never be *created* by
    joining ordinary prose.  Chunks overlap by ``lex_overlap()`` bytes so a
    token straddling a boundary is seen whole at least once.
    """
    if len(data) > MAX_MEMBER_BYTES:
        raise Unreadable(f"candidate exceeds {MAX_MEMBER_BYTES} bytes")
    out: list[bytes] = []
    seen: set[bytes] = set()
    step = CHUNK_BYTES
    pos = 0
    while True:
        chunk = data[pos:pos + step + lex_overlap()]
        for rx in (TOKEN_RUN, ALNUM_RUN, SLUG_WORDS):
            for m in rx.finditer(chunk):
                tok = m.group(0)
                if len(tok) < 6 or tok in seen:
                    continue
                seen.add(tok)
                out.append(tok)
        if pos + step >= len(data):
            break
        pos += step
    return out


def scan_candidate(scanner: Scanner, data: bytes, path: str) -> list[dict]:
    """All findings for one candidate: hashed slots first (the authoritative
    check), then token shapes.  Never returns a value."""
    hits: list[dict] = []
    # The documented PUBLIC apt/cert trust anchors are shipped by design and
    # their base64 bodies routinely match the base64 form of an unrelated
    # secret by chance.  The exclusion has to apply to the HASHED half too --
    # applying it only to the shape scan flagged every clean image.
    public_keyring = is_public_keyring(path)
    if scanner.hashes and not public_keyring:
        # O(len * MAX_SECRET_LEN) hashes per candidate, no quadratic blow-up:
        # for every start offset, extend the window while its digest misses
        # and stop at the first hit (a hit is a whole value; its extension is
        # a different value and would not be in the list).
        digest = scanner.hashes.digest
        known = scanner.hashes.digests
        for tok in tokenise(data):
            stop = 0
            hit = False
            for start in range(len(tok)):
                if start < stop:
                    continue
                for length in range(HASH_MIN_LEN,
                                    min(MAX_SECRET_LEN, len(tok) - start) + 1):
                    if digest(tok[start:start + length]) in known:
                        hits.append({"kind": "known-secret", "length": length})
                        stop = start + length
                        hit = True
                        break
            if hit:
                break  # one location per candidate is enough for the receipt
    if scanner.shapes:
        hits.extend(scanner.scan_shapes(data, path))
    return hits


# ---------------------------------------------------------------------------
# what counts as a shipped layer, and how it is opened
# ---------------------------------------------------------------------------
LAYER_SUFFIXES = (".squashfs", ".sqfs", ".sfs")
INITRD_RE = re.compile(
    r"(^|/)(initrd|initramfs|initrd\.img|initrd\.gz)([-._][^/]*)?$|"
    r"\.(cpio|cpio\.gz|cpio\.xz|cpio\.zst|cpio\.bz2|img)$|^initrd", re.I)
ROOTFS_TAR_RE = re.compile(
    r"\.tar\.(zst|xz|gz|bz2)$|\.tar$", re.I)
DEB_RE = re.compile(r"\.deb$", re.I)


def layer_kind(path: str) -> str | None:
    if path.endswith(LAYER_SUFFIXES):
        return "squashfs"
    return None


def initrd_kind(path: str) -> str | None:
    base = os.path.basename(path)
    if base in ("initrd", "initrd.gz", "initrd.img", "initramfs") or \
       base.startswith("initrd") or base.startswith("initramfs") or \
       ".cpio" in base:
        return "initrd"
    return None


def unsquashfs_files(tool: str, layer: str, dest: str) -> None:
    """Extract a layer in full with the system unsquashfs.  Any nonzero exit
    is fatal: an unreadable layer is a failure, never a clean layer."""
    os.makedirs(dest, exist_ok=True)
    r = subprocess.run([tool, "-no-progress", "-d", dest, layer],
                       capture_output=True, check=False)
    if r.returncode != 0:
        tail = (r.stderr or r.stdout)[-600:].decode("utf-8", "replace")
        raise Unreadable(f"unsquashfs cannot fully extract {layer} "
                         f"(rc={r.returncode}): {tail}")
    # unsquashfs drops what it cannot restore (xattrs, device nodes) and only
    # warns.  A layer we cannot extract byte-for-byte is not provably clean.
    err = (r.stderr or b"").decode("utf-8", "replace").splitlines()
    fatal = [ln for ln in err
             if re.search(r"(Failed|ERROR|error): ", ln)
             and not re.search(r"\d+ errors?\b", ln)]
    if fatal:
        raise Unreadable(f"unsquashfs reported extraction failures for {layer}: "
                         + " | ".join(fatal[:3])[:400])


# ---------------------------------------------------------------------------
# the walk
# ---------------------------------------------------------------------------
class Report:
    def __init__(self):
        self.layers: list[dict] = []
        self.findings: list[dict] = []
        self.counts = collections.Counter()
        self.errors: list[str] = []
        self.units: dict[str, int] = collections.defaultdict(int)

    def add(self, layer: str, path: str, hits: list[dict]) -> None:
        for h in hits:
            if len(self.findings) >= 200:
                return
            self.findings.append({"layer": layer, "path": path, **h})


def scan_payload(rep: Report, scanner: Scanner, layer: str, path: str,
                 data: bytes, depth: int = 0) -> None:
    """Scan one member of a layer/archive, expanding archives inside it."""
    rep.units[layer] += 1
    expanded = False
    # Every initrd/initramfs is a (possibly multi-segment) cpio stream, often
    # compressed: expand() walks all segments.  Without this an initrd was
    # scanned as one opaque blob and its members were never looked at.
    is_initrd = initrd_kind(path) is not None
    if depth < 3 and (is_initrd or DEB_RE.search(path) or ROOTFS_TAR_RE.search(path)
                      or re.search(r"\.(cpio|cpio\.gz|cpio\.xz|cpio\.zst|tar\.dz)$", path)):
        try:
            members = list(expand(path, data, path, depth))
        except Unreadable:
            raise
        if members:
            expanded = True
            for mpath, payload in members:
                scan_payload(rep, scanner, layer, mpath, payload, depth + 1)
    if not expanded:
        rep.counts["files_scanned"] += 1
        rep.counts["bytes_scanned"] += len(data)
        hits = scan_candidate(scanner, data, path)
        if hits:
            rep.add(layer, path, hits)


def scan_layer_tree(rep: Report, scanner: Scanner, layer: str, root: str) -> None:
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        for name in sorted(filenames):
            full = os.path.join(dirpath, name)
            rel = "/" + os.path.relpath(full, root)
            try:
                st = os.lstat(full)
            except OSError as exc:
                raise Unreadable(f"{layer}: cannot stat {rel}: {exc}")
            if not stat.S_ISREG(st.st_mode):
                continue
            if st.st_nlink > 1 and not os.path.islink(full):
                rep.counts["hardlinks"] += 1
            if os.path.islink(full):
                # a symlink target is a name; scan it as text
                try:
                    target = os.readlink(full).encode("utf-8", "replace")
                except OSError as exc:
                    raise Unreadable(f"{layer}: cannot readlink {rel}: {exc}")
                rep.counts["files_scanned"] += 1
                hits = scan_candidate(scanner, target, rel)
                if hits:
                    rep.add(layer, rel, hits)
                continue
            try:
                with open(full, "rb") as fh:
                    data = fh.read()
            except OSError as exc:
                raise Unreadable(f"{layer}: cannot read {rel}: {exc}")
            scan_payload(rep, scanner, layer, rel, data)


def walk_image(img: str, scanner: Scanner, workdir: str, hashes_given: bool,
               jobs: int) -> Report:
    from concurrent.futures import ThreadPoolExecutor

    rep = Report()
    tools = dict(which_all(["unsquashfs", "zstd"]))
    for tool, path in tools.items():
        if tool in ("unsquashfs", "zstd") and not path:
            raise Unreadable(f"the {tool} tool is missing; the gate cannot "
                             "extract the artifact without it")
    try:
        fh = open(img, "rb")
    except OSError as exc:
        raise Unreadable(f"cannot open the image {img} read-only: {exc}")
    with fh:
        st = os.stat(fh.fileno())
        if not stat.S_ISREG(st.st_mode):
            raise Unreadable(f"{img} is not a regular file")
        parts = parse_gpt(fh)
        rep.counts["partitions"] = len(parts)
        layers: list[dict] = []

        for part in parts:
            kind = part["kind"]
            try:
                files = fat_walk(fh, part) if kind == "fat" else ext4_walk(fh, part)
            except Unreadable as exc:
                raise Unreadable(f"partition {part['index']} is unreadable: {exc}")
            for f in files:
                path = f["path"]
                data = f["bytes"]
                lk = layer_kind(path)
                if lk:
                    layers.append({"path": path, "part": part["index"],
                                   "bytes": data, "kind": lk})
                    continue
                # everything else directly on the partition (ESP files)
                rep.units["esp" if kind == "fat" else "partition"] += 1
                scan_payload(rep, scanner,
                             "esp" if kind == "fat" else f"part{part['index']}",
                             path, data)

        if not layers:
            raise Unreadable(
                "the image carries no squashfs layer at all: nothing was "
                "scanned, so nothing can be declared clean")

        layer_dirs = []
        for layer in sorted(layers, key=lambda l: l["path"]):
            name = layer["path"].strip("/").replace("/", "_")
            dest = os.path.join(workdir, name)
            # write the layer out of the image, then extract it
            raw = os.path.join(workdir, name + ".squashfs")
            with open(raw, "wb") as out:
                out.write(layer["bytes"])
            unsquashfs_files(tools["unsquashfs"], raw, dest)
            os.unlink(raw)
            layer["dest"] = dest
            layer["name"] = os.path.basename(layer["path"])
            layer_dirs.append(layer)
            rep.layers.append({
                "path": layer["path"],
                "partition": layer["part"],
                "format": "squashfs",
                "bytes": len(layer["bytes"]),
                "files": 0,
            })

        def run(layer):
            before_units = rep.units[layer["name"]]
            before_files = rep.counts["files_scanned"]
            before_bytes = rep.counts["bytes_scanned"]
            scan_layer_tree(rep, scanner, layer["name"], layer["dest"])
            return (layer["name"],
                    rep.units[layer["name"]] - before_units,
                    rep.counts["files_scanned"] - before_files,
                    rep.counts["bytes_scanned"] - before_bytes)

        with ThreadPoolExecutor(max_workers=max(1, min(jobs, len(layer_dirs)))) as ex:
            results = list(ex.map(run, layer_dirs))
        for entry, (name, units, files, nbytes) in zip(rep.layers, results):
            entry["members_scanned"] = units
            entry["files_scanned"] = files
            entry["bytes_scanned"] = nbytes
    return rep


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
def default_hash_file(root: str) -> str:
    env = os.environ.get("NCZ_SECRET_HASHES_FILE")
    if env:
        return env
    return os.path.join(root, "manifests", "secret-hashes.local")


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=(__doc__ or "").splitlines()[0])
    ap.add_argument("--image", required=True, help="the finished .img")
    ap.add_argument("--receipt", help="write the JSON receipt here")
    ap.add_argument("--hash-file", help="hash list (default: "
                    "manifests/secret-hashes.local or NCZ_SECRET_HASHES_FILE)")
    ap.add_argument("--allow-detached", action="store_true",
                    help="proceed without a hash list (token shapes only); "
                    "recorded in the receipt as NOT detached-clean")
    ap.add_argument("--require-hashes", action="store_true",
                    help="fail when the hash list has no entries")
    ap.add_argument("--no-shapes", action="store_true",
                    help="skip the token-shape scan (tests only)")
    ap.add_argument("--work-dir", help="scratch dir (default: TMPDIR)")
    ap.add_argument("--jobs", type=int, default=4)
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args(argv)

    def say(msg: str) -> None:
        if not args.quiet:
            print(msg, flush=True)

    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    hash_file = args.hash_file or default_hash_file(root)
    started = time.time()
    hashes = HashSet()
    hashes_given = False
    hash_error = None
    if os.path.exists(hash_file):
        try:
            n = hashes.load(hash_file)
            hashes_given = True
            say(f"shipped-secret-scan: hash list {hash_file} ({n} digests)")
        except Unreadable as exc:
            hash_error = str(exc)
    else:
        hash_error = f"no hash list at {hash_file}"

    if hash_error and not args.allow_detached:
        print(f"shipped-secret-scan: FAIL — {hash_error}\n"
              "  The shipped-artifact credential gate is mandatory: run "
              "build/make-secret-hashes.py on a trusted machine and copy the "
              "result to manifests/secret-hashes.local (or point "
              "NCZ_SECRET_HASHES_FILE at it).  --allow-detached only records "
              "that the hashed half of the gate did not run.", file=sys.stderr)
        return 1
    if args.require_hashes and not len(hashes):
        print("shipped-secret-scan: FAIL — --require-hashes and the hash list "
              "is empty (nothing to match)", file=sys.stderr)
        return 1

    workdir = args.work_dir or os.environ.get("TMPDIR") or tempfile.mkdtemp(prefix="ncz-shipped-scan-")
    os.makedirs(workdir, exist_ok=True)
    scratch = tempfile.mkdtemp(prefix="scan-", dir=workdir)
    report = None
    failed = False
    error = None
    try:
        report = walk_image(args.image, Scanner(hashes, not args.no_shapes),
                            scratch, hashes_given, args.jobs)
    except Unreadable as exc:
        failed = True
        error = str(exc)
    except MemoryError:
        failed = True
        error = "the image needs more memory than this host has"
    finally:
        shutil.rmtree(scratch, ignore_errors=True)

    elapsed = round(time.time() - started, 1)
    img_bytes = os.path.getsize(args.image) if os.path.exists(args.image) else 0
    receipt = {
        "gate": "shipped-secret-scan",
        "version": GATE_VERSION,
        "image": os.path.basename(args.image),
        "image_bytes": img_bytes,
        "arch_env": os.environ.get("NCZ_TARGET_ARCH") or os.environ.get("ARCH") or "",
        "hash_list": {
            "path": os.path.basename(hash_file),
            "present": hashes_given,
            "digests": len(hashes),
            "error": hash_error,
        },
        "token_shapes": not args.no_shapes,
        "result": "FAIL" if (failed or (report and report.findings)) else "PASS",
        "error": error,
        "elapsed_seconds": elapsed,
        "layers": report.layers if report else [],
        "counts": dict(report.counts) if report else {},
        "units_by_layer": dict(report.units) if report else {},
        "findings": report.findings if report else [],
    }
    if args.receipt:
        try:
            with open(args.receipt, "w", encoding="utf-8") as fh:
                json.dump(receipt, fh, indent=2, sort_keys=True)
                fh.write("\n")
        except OSError as exc:
            print(f"shipped-secret-scan: FAIL — cannot write the receipt "
                  f"{args.receipt}: {exc}", file=sys.stderr)
            return 1

    for entry in receipt["layers"]:
        say(f"  layer {entry['path']}: {entry['bytes']} bytes, "
            f"{entry['members_scanned']} members, {entry['files_scanned']} files")
    say(f"  scanned {receipt['counts'].get('files_scanned', 0)} files, "
        f"{human(receipt['counts'].get('bytes_scanned', 0))} in {elapsed}s")

    if receipt["result"] == "PASS":
        if not hashes_given:
            print("shipped-secret-scan: FAIL — the token-shape half passed but "
                  "the hashed half did not run; the artifact is NOT cleared",
                  file=sys.stderr)
            return 1
        say("SHIPPED-SCAN: PASS ✅  no credentials in the shipped artifact")
        return 0

    print("SHIPPED-SCAN: FAIL ❌  the artifact is not shippable", file=sys.stderr)
    if error:
        print(f"  {error}", file=sys.stderr)
    for f in receipt["findings"][:20]:
        print(f"  {f['kind']}"
              + (f" [{f['shape']}]" if f.get("shape") else "")
              + f" in layer {f['layer']}: {f['path'][:200]}"
              + (f" at offset {f['offset']}" if f.get("offset") is not None else ""),
              file=sys.stderr)
    if len(receipt["findings"]) > 20:
        print(f"  ... {len(receipt['findings']) - 20} more (see the receipt)",
              file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
