#!/usr/bin/env python3
"""
patch-initrd-t2-kernel.py -- swap the d-i installer's OWN boot kernel for
our real T2 kernel, and append a modules overlay for it onto the d-i
initrd. Real, proven mechanism ported from build/build-iso-di.sh's
arm64/Sky1 kernel-swap (Step 2+3, ~line 2544) -- that script explicitly
skips this for amd64 ("stock d-i kernel/initrd already boot correctly on
generic PC hardware") because that's true for GENERIC amd64 PCs. It is
NOT true for T2 Macs: Debian's stock d-i kernel lacks the exact
Thunderbolt/USB module set and hardware quirks our own kernel already
carries (confirmed 2026-09-24: a Thunderbolt-hub-connected keyboard did
not work at d-i boot with the stock kernel; our T2 kernel ships
thunderbolt.ko).

Architecture (same as the arm64 precedent, adapted):
  1. Swap the d-i kernel binary (/linux in the ESP) for our real T2
     vmlinuz.
  2. Do NOT rebuild the base d-i initrd's userspace at all. Concatenate the
     base and overlay CPIO archives inside ONE gzip member. The kernel's
     initramfs unpacker extracts each CPIO archive in sequence, later entries
     winning on conflict. Do not concatenate gzip members: the Sky1 arm64
     kernel stops after the first member and silently loses the overlay.
  3. Real gotchas ported verbatim from the arm64 precedent:
     - d-i's own kmod udeb cannot decompress .ko.xz despite claiming to
       (zero lzma code linked in) -- decompress every .ko.xz in the
       overlay to plain .ko first, or modules silently fail to load
       ("Invalid module format").
     - NEVER emit a bare top-level "lib" directory entry in the overlay
       cpio. A usr-merged base (lib -> usr/lib symlink) has that symlink
       DELETED by the kernel's initramfs clean_path() if a later archive
       tries to create a directory at the same path -- taking libc and
       the dynamic loader with it, and initramfs will hard fail to find
       ANY working init. `find lib -mindepth 1` avoids ever emitting the
       top-level entry.
     - depmod -a -b <overlay-root> <kver> regenerates modules.dep etc
       WITHIN the overlay's own module tree before packing -- this does
       not touch the base initrd's own (now-unused, different-kver)
       module index at all.

  Deliberately does NOT prune wireless/bluetooth/mac80211 the way the
  arm64 precedent does -- T2 Macs need real WiFi (brcmfmac) support in
  d-i itself (see patch-initrd-firmware.py), so those categories stay.
  Only prunes sound (no audio need in a text-mode d-i bootstrap) to keep
  the overlay reasonably sized.

Usage:
    patch-initrd-t2-kernel.py --base-initrd PATH --kernel-deb PATH
        --arch {amd64,arm64} [--cache-root DIR] [--force]
        [--firmware-pool POOL [--net-firmware-table TSV]]

  --firmware-pool bakes the NIC/Bluetooth blobs that manifests/net-firmware.tsv
  scopes "initrd+target" (rtl_nic/*, MT79xx BT) into the overlay at
  /lib/firmware, extracted from the offline mirror's firmware-*.deb.

Output: <cache-root>/ncz-initrd-t2kernel/<node_key>/{linux,initrd.gz}
        + receipt.json
"""
from __future__ import annotations

import argparse
import functools
import gzip
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import zlib
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
DEFAULT_CACHE_ROOT = REPO_ROOT / "build" / "iso-cache" / "v1"

# Categories with no real use in a text-mode d-i bootstrap. Kept
# deliberately short -- when in doubt, keep the module; the overlay is
# appended, not baked into a firmware-size-limited image the way Sky1's
# is, so there is no real size pressure forcing aggressive pruning here.
PRUNE_MOD_DIRS = ["sound"]

# One-kernel policy (docs/ONE-KERNEL.md, design rule 2026-10-10: "ship
# only OUR kernel").  A Debian d-i kernel-module/binary/helper udeb carries
# the substrate's own kernel modules; once we swap the running kernel for ours
# and bake our module tree into the overlay those udebs are dead weight AND a
# provenance failure (`*-modules-<kver>-*-di` is a non-NCZ kernel artifact).
# The base d-i initrd is not ours to rebuild, so we prune these records from
# its dpkg status (and drop the dead /lib/modules/<debian-kver> tree and the
# status file itself, replacing it with the pruned copy in the overlay).
# Must mirror build/forky-provenance.py:KERNEL_ARTIFACT_RE /
# build/classify-sid-exceptions.py:KERNEL_ARTIFACT_RE.
_KERNEL_ARTIFACT_RE = re.compile(
    r"^(linux-image|linux-headers|linux-modules|linux-binary|kernel-image)"
    r"|^linux-base-"
    r"|(^.+-(modules|binary)-.*-di$)"
)
# The netinst's own build marker (`Package: debian-installer`,
# `Version: cdrom-isolinux-<date>`, deliberately Architecture-less).  It is not
# a real udeb and cannot be authorized by the pin/ledger; drop it.
_DI_MARKER_PACKAGE = "debian-installer"
_STATUS_REL = "var/lib/dpkg/status"
_MODULES_DIR_RE = re.compile(
    r"^(?:\./)?(?:usr/)?lib/modules/(?P<kver>[^/]+)(?P<child>/.*)?$"
)


def patch_check_missing_firmware(source: str) -> str:
    """Make d-i's firmware audit retain the complete kernel boot log."""
    truncate_start = source.find("\t# Truncate if needed:\n")
    truncate_end = source.find(
        "\n\tif [ -s $dmesg_file ]; then", truncate_start
    )
    if truncate_start < 0 or truncate_end < 0:
        raise RuntimeError(
            "FATAL: check-missing-firmware timestamp logic changed upstream; "
            "refusing to ship an unverified patch"
        )
    replacement = (
        "\t# NCZ downstream: always retain the full boot log. Firmware load\n"
        "\t# failures can predate hw-detect's saved timestamp.\n"
        "\tlog \"looking at complete dmesg (NCZ firmware audit)\"\n"
    )
    return source[:truncate_start] + replacement + source[truncate_end:]


def write_single_member_initrd(base_initrd: Path, overlay_initrd: Path,
                               output: Path) -> None:
    """Write base + overlay CPIO archives inside one gzip member.

    Python's gzip reader consumes concatenated input members, which also makes
    this safe if an upstream initrd already uses that representation. The
    output deliberately has one member for kernels that stop inflating after
    the first gzip stream (observed with the Sky1 arm64 installer kernel).
    """
    with output.open("wb") as raw_out:
        with gzip.GzipFile(fileobj=raw_out, mode="wb", compresslevel=9,
                           mtime=0) as gz_out:
            for source in (base_initrd, overlay_initrd):
                with gzip.open(source, "rb") as gz_in:
                    shutil.copyfileobj(gz_in, gz_out)


def module_name(path: Path) -> str:
    """foo.ko / foo.ko.xz / foo.ko.zst -> foo"""
    return path.name.split(".ko")[0]


_CPIO_MAGIC = (b"070701", b"070702")
_CPIO_TRAILER = "TRAILER!!!"
_HEX_DIGITS = frozenset(b"0123456789abcdefABCDEF")
_S_IFMT = 0o170000
_S_IFREG = 0o100000


class CpioError(ValueError):
    """A newc cpio stream the kernel's initramfs unpacker would reject."""


def _parse_newc_entries(data: bytes):
    """Strictly parse a (possibly concatenated) newc cpio stream.

    Matches the kernel initramfs unpacker: every archive must end in a
    TRAILER!!!; header/name/body offsets must stay in bounds; names must be
    NUL-terminated; 070702 entries must sum-match; and no nonzero junk may
    remain. Raises CpioError instead of silently stopping, so a truncated
    archive is rejected even when /preseed.cfg and the hook were already seen.

    Do NOT shell out to `cpio` for this: GNU cpio stops at the first
    TRAILER!!! and silently ignores every appended archive, so it never sees
    the overlay's /preseed.cfg.
    """
    pos, end = 0, len(data)
    archive_open = False
    archives = 0
    while True:
        while pos < end and data[pos] == 0:
            pos += 1
        if pos == end:
            break
        if pos + 110 > end:
            raise CpioError(f"truncated cpio header at offset {pos}")
        header = data[pos : pos + 110]
        magic = header[:6]
        if magic not in _CPIO_MAGIC:
            raise CpioError(f"junk at offset {pos}: {header[:8]!r}")
        # All 13 fixed 8-byte fields (104 bytes) must be ASCII hex. newc fields
        # are unsigned hex, so a sign, space, or other non-hex byte in ANY field
        # -- even inode/uid/gid, which this parser does not otherwise read -- is
        # a corrupt archive the kernel would reject. Refuse it here too.
        if not _HEX_DIGITS.issuperset(header[6:110]):
            raise CpioError(f"non-hex cpio header field at offset {pos}")
        mode = int(header[14:22], 16)
        filesize = int(header[54:62], 16)
        namesize = int(header[94:102], 16)
        check = int(header[102:110], 16)
        if namesize < 1:
            raise CpioError(f"cpio entry with namesize 0 at offset {pos}")
        name_end = pos + 110 + namesize
        if name_end > end:
            raise CpioError(f"truncated cpio name at offset {pos}")
        raw_name = data[pos + 110 : name_end]
        if raw_name[-1] != 0:
            raise CpioError(f"cpio name not NUL-terminated at offset {pos}")
        if b"\0" in raw_name[:-1]:
            # The kernel treats the name as a C string, so "preseed.cfg\0x"
            # would really overwrite /preseed.cfg while this parser saw a
            # different member (and would ignore it). Refuse embedded NULs.
            raise CpioError(f"cpio name has an embedded NUL at offset {pos}")
        name = raw_name[:-1].decode("utf-8", "surrogateescape")
        data_start = name_end
        data_start += (-data_start) % 4
        if data_start + filesize > end:
            raise CpioError(f"truncated cpio body at offset {pos}")
        payload = data[data_start : data_start + filesize]
        if magic == b"070702" and (sum(payload) & 0xFFFFFFFF) != check:
            raise CpioError(f"cpio 070702 CRC mismatch at offset {pos}")
        entry_start = pos
        pos = data_start + filesize
        pos += (-pos) % 4
        # `start`/`end` are the byte span of the whole entry (header + name +
        # padding + body + padding) in `data`, so a caller can filter the
        # stream by copying verbatim slices instead of re-serialising.
        yield {"name": name, "mode": mode, "payload": payload,
               "start": entry_start, "end": pos}
        if name == _CPIO_TRAILER:
            archive_open = False
            archives += 1
        else:
            archive_open = True
    if archive_open:
        raise CpioError("cpio archive ended without TRAILER!!!")
    if archives == 0:
        raise CpioError("no cpio archive found")


def _member_target(name: str, targets: tuple) -> tuple:
    """Resolve a cpio member name the way the kernel would, for the two paths
    we care about.

    Returns (target, exact). `exact` is False when the name reaches a target
    only through an alias -- absolute, `..`, `.`, or extra path structure --
    which the kernel could place somewhere else (or overwrite); callers refuse
    those instead of trusting a placement that may not boot.
    """
    candidate = name.removeprefix("./")
    parts: list = []
    for segment in candidate.split("/"):
        if segment in ("", "."):
            continue
        if segment == "..":
            if parts:
                parts.pop()
            continue
        parts.append(segment)
    resolved = "/".join(parts)
    if resolved not in targets:
        return None, False
    return resolved, candidate == resolved


def _decompress_single_gzip(initrd: Path) -> bytes:
    """Decompress one gzip member, failing on truncation or concatenation."""
    decomp = zlib.decompressobj(16 + zlib.MAX_WBITS)
    try:
        stream = decomp.decompress(initrd.read_bytes())
        stream += decomp.flush()
    except zlib.error as exc:
        raise RuntimeError(f"FATAL: {initrd} is not a gzip initrd: {exc}")
    if not decomp.eof:
        raise RuntimeError(
            f"FATAL: {initrd} gzip stream is truncated (no end-of-stream marker)"
        )
    if decomp.unused_data:
        raise RuntimeError(
            f"FATAL: {initrd} holds more than one gzip member; the Sky1 arm64 "
            f"kernel stops after the first member and drops the overlay"
        )
    return stream


def filter_base_cpio(data: bytes, our_kver: str) -> tuple[bytes, set, int]:
    """Prune a Debian d-i initrd cpio stream for the one-kernel policy.

    Drops, byte-verbatim, every member under ``[usr/]lib/modules/<kver>`` for
    any kernel version other than ours, plus the base's own
    ``var/lib/dpkg/status`` (the overlay bakes a pruned copy which, as the
    later archive, is the one the kernel/initrd actually uses and the one the
    provenance scanner reads).

    Returns ``(pruned_bytes, dropped_kvers, n_dropped_members)``.  Byte-exact
    copies of the kept members preserve every header field (inode, uid/gid,
    mode, mtime, nlink, rdev) so the pruned archive is deterministic and the
    kernel's unpacker sees exactly the entries it saw before minus the dead
    kernel.  Raises CpioError on a malformed stream (fail closed).
    """
    out = bytearray()
    dropped_kvers: set = set()
    dropped = 0
    for entry in _parse_newc_entries(data):
        name = entry["name"]
        n = name.removeprefix("./")
        m = _MODULES_DIR_RE.match(n)
        if m is not None and m.group("kver") != our_kver:
            dropped_kvers.add(m.group("kver"))
            dropped += 1
            continue
        if n in (_STATUS_REL, "usr/" + _STATUS_REL):
            dropped += 1
            continue
        out += data[entry["start"]:entry["end"]]
    return bytes(out), dropped_kvers, dropped


def prune_initrd_status(text: str) -> tuple[str, list]:
    """Return (pruned dpkg-status text, [dropped package names]).

    Removes every Debian kernel-artifact udeb stanza (the one-kernel policy)
    and the netinst's Architecture-less ``debian-installer`` build marker,
    which can be authorized by neither the pin nor the review ledger.  Stanzas
    are kept byte-for-byte otherwise; a malformed/empty result is not silently
    accepted by the caller.
    """
    dropped: list = []
    kept: list = []
    for stanza in re.split(r"\n[ \t]*\n", text.strip("\n")):
        if not stanza.strip():
            continue
        pkg = ""
        has_arch = False
        for line in stanza.split("\n"):
            if line.startswith("Package: "):
                pkg = line[len("Package: "):].strip()
            elif line.startswith("Architecture: "):
                has_arch = True
        if _KERNEL_ARTIFACT_RE.search(pkg) or (
            pkg == _DI_MARKER_PACKAGE and not has_arch
        ):
            dropped.append(pkg)
            continue
        kept.append(stanza)
    return "\n\n".join(kept) + "\n", dropped


def verify_baked_preseed(
    initrd: Path, preseed_cfg: Path, hook_name: str | None = None
) -> dict:
    """Prove the FINAL initrd actually carries the baked preseed and hook.

    Decompresses the single gzip member and strictly walks its concatenated
    cpio archives, so a dropped member, a truncated gzip or archive, junk, a
    non-regular or aliased member, or a wrong hook body all fail the build
    instead of shipping. /preseed.cfg and the hook bytes are compared to their
    sources.
    """
    if hook_name is None:
        hook_name = NCZ_STARTUP_HOOK_NAME
    if not initrd.is_file():
        raise RuntimeError(f"FATAL: patched initrd missing: {initrd}")
    stream = _decompress_single_gzip(initrd)
    hook_rel = "usr/lib/debian-installer-startup.d/" + hook_name
    targets = ("preseed.cfg", hook_rel)
    preseed: bytes | None = None
    hook: bytes | None = None
    try:
        for entry in _parse_newc_entries(stream):
            resolved, exact = _member_target(entry["name"], targets)
            if resolved is None:
                continue
            if not exact:
                raise RuntimeError(
                    f"FATAL: initrd {initrd} reaches /{resolved} via "
                    f"non-canonical member {entry['name']!r}; refusing an "
                    f"alias the kernel may not place where we expect"
                )
            if entry["mode"] & _S_IFMT != _S_IFREG:
                raise RuntimeError(
                    f"FATAL: /{resolved} in {initrd} is not a regular file "
                    f"(mode {oct(entry['mode'])})"
                )
            if resolved == hook_rel and entry["mode"] & 0o777 != 0o755:
                raise RuntimeError(
                    f"FATAL: /{hook_rel} in {initrd} has mode "
                    f"{oct(entry['mode'] & 0o777)}, want 0o755 (d-i only runs "
                    f"executable startup scripts)"
                )
            if resolved == "preseed.cfg":
                preseed = entry["payload"]
            else:
                hook = entry["payload"]
    except CpioError as exc:
        raise RuntimeError(f"FATAL: malformed initrd cpio {initrd}: {exc}")
    if preseed is None:
        raise RuntimeError(f"FATAL: patched initrd {initrd} has no /preseed.cfg member")
    if hook is None:
        raise RuntimeError(f"FATAL: patched initrd {initrd} has no /{hook_rel} member")
    want_sha = sha256_bytes(preseed_cfg.read_bytes())
    got_sha = sha256_bytes(preseed)
    if got_sha != want_sha:
        raise RuntimeError(
            f"FATAL: baked /preseed.cfg in {initrd} does not match "
            f"{preseed_cfg} (initrd {got_sha} != source {want_sha})"
        )
    if hook != NCZ_STARTUP_HOOK_BODY.encode("utf-8"):
        raise RuntimeError(
            f"FATAL: /{hook_rel} in {initrd} does not match NCZ_STARTUP_HOOK_BODY"
        )
    return {
        "preseed_member": "preseed.cfg",
        "preseed_sha256": want_sha,
        "hook_member": hook_rel,
        "hook_mode": "0755",
    }


def verify_one_kernel_initrd(initrd: Path, our_kver: str) -> dict:
    """Fail the build if the FINAL initrd still carries a Debian kernel.

    The one-kernel policy (docs/ONE-KERNEL.md) forbids any second kernel; after
    `filter_base_cpio` + the pruned status this must hold for both the raw
    module trees and the dpkg status records.  Uses the same strict walk as the
    provenance scanner (every concatenated archive), so a hidden `/usr/lib`
    alias or a stale second copy cannot slip through.
    """
    if not initrd.is_file():
        raise RuntimeError(f"FATAL: patched initrd missing: {initrd}")
    stream = _decompress_single_gzip(initrd)
    bad_paths: list = []
    bad_pkgs: list = []
    try:
        for entry in _parse_newc_entries(stream):
            n = entry["name"].removeprefix("./")
            m = _MODULES_DIR_RE.match(n)
            if m is not None and m.group("kver") != our_kver:
                bad_paths.append(n)
            if n in (_STATUS_REL, "usr/" + _STATUS_REL):
                _, dropped = prune_initrd_status(
                    entry["payload"].decode("utf-8", "surrogateescape")
                )
                # Anything prune_initrd_status WOULD drop must already be gone.
                if dropped:
                    bad_pkgs.extend(dropped)
    except CpioError as exc:
        raise RuntimeError(f"FATAL: malformed initrd cpio {initrd}: {exc}")
    if bad_paths:
        raise RuntimeError(
            f"FATAL: one-kernel policy violated: {initrd} still carries "
            f"{len(bad_paths)} Debian kernel module path(s) (e.g. "
            f"{sorted(set(bad_paths))[:5]})"
        )
    if bad_pkgs:
        raise RuntimeError(
            f"FATAL: one-kernel policy violated: {initrd} dpkg status still "
            f"lists Debian kernel-artifact package(s): {sorted(set(bad_pkgs))}"
        )
    return {"our_kver": our_kver, "debian_kernel_paths": 0,
            "debian_kernel_status_pkgs": 0}


def _verify_node_outputs(
    node_dir: Path, preseed_cfg: Path, hook_name: str | None = None
) -> dict:
    """Verify a completed (possibly cached) node: kernel present and the
    preseed/hook bytes in the final initrd. Called on cache hits too, so a
    corrupt or half-written node is never trusted just because receipt.json
    exists."""
    if not (node_dir / "linux").is_file():
        raise RuntimeError(f"FATAL: initrd node {node_dir} has no kernel file (linux)")
    return verify_baked_preseed(node_dir / "initrd.gz", preseed_cfg, hook_name)


def module_depends(paths: dict) -> dict:
    """{module name -> [dependency names]} for every module in `paths`.

    Batched modinfo with a hard alignment check: modinfo prints one line per
    input file, but an empty depends field is easy to get wrong, so if the
    line count does not match the batch we fall back to one call per file
    rather than silently attributing one module's deps to another.
    """
    deps = {}
    names = list(paths)
    CHUNK = 400
    for i in range(0, len(names), CHUNK):
        batch = names[i:i + CHUNK]
        out = subprocess.run(
            ["/sbin/modinfo", "-F", "depends"] + [str(paths[b]) for b in batch],
            capture_output=True, text=True,
        ).stdout.split("\n")
        if out and out[-1] == "":
            out.pop()
        if len(out) != len(batch):
            for b in batch:
                line = subprocess.run(
                    ["/sbin/modinfo", "-F", "depends", str(paths[b])],
                    capture_output=True, text=True,
                ).stdout.strip()
                deps[b] = [d for d in line.split(",") if d]
            continue
        for b, line in zip(batch, out):
            deps[b] = [d for d in line.strip().split(",") if d]
    return deps


def prune_unsatisfiable_modules(overlay_modules: Path) -> list:
    """Remove every module whose dependencies pruning has taken away.

    Real, measured reason (2026-09-24, against the shipped 7.2.7-2-t2-trixie
    module set): dropping kernel/sound leaves 19 modules behind whose
    `depends` still name snd / snd-pcm / snd-soc-core, which is what produces
    the "Unknown symbol snd_pcm_new (err -2)" class of errors on every
    install boot. t2bce_audio -- the T2 codec driver, which lives under
    kernel/drivers/staging/t2bce/ and so survives a kernel/sound prune -- is
    only ONE of those 19; naming it explicitly would have fixed a twentieth
    of the problem and left the rest.

    So compute the closure instead of maintaining a list: drop anything with
    a missing dependency, repeat until it settles. Measured result on this
    kernel: 26 modules removed over 3 rounds, all audio / TV-capture /
    soundwire / USB-audio-gadget, and 0 modules left with unresolvable
    dependencies. Keeping kernel/sound instead would add 380 modules and
    ~16 MiB compressed to the overlay for a silent text-mode installer.
    """
    present = {}
    for f in overlay_modules.rglob("*.ko*"):
        present[module_name(f)] = f
    deps = module_depends(present)
    removed = []
    while True:
        gone = [m for m, ds in deps.items()
                if m in present and any(d not in present for d in ds)]
        if not gone:
            break
        for m in gone:
            present[m].unlink()
            del present[m]
            removed.append(m)
    return sorted(removed)


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def sha256_bytes(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()


def canonical_encode(obj: dict) -> bytes:
    return json.dumps(obj, sort_keys=True, separators=(",", ":")).encode("utf-8")


def log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


def _stat(path: Path) -> dict:
    if not path.exists():
        return {"present": False}
    s = path.stat()
    return {"present": True, "sha256": sha256_file(path), "size": s.st_size}


DEFAULT_NET_FIRMWARE_TABLE = REPO_ROOT / "manifests" / "net-firmware.tsv"


def load_net_firmware_table(path: Path) -> list[dict]:
    """Parse manifests/net-firmware.tsv into row dicts.

    Fails closed on a malformed row: a silently skipped row is exactly a NIC
    that boots the installer without its blob.
    """
    rows = []
    for lineno, line in enumerate(path.read_text().splitlines(), 1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        cols = line.split("\t")
        if len(cols) != 5 or not all(c.strip() for c in cols):
            raise RuntimeError(
                f"FATAL: {path}:{lineno}: expected 5 non-empty TAB-separated "
                f"columns (device driver package firmware where), got {len(cols)}"
            )
        device, driver, package, firmware, where = (c.strip() for c in cols)
        if where not in ("initrd+target", "target"):
            raise RuntimeError(
                f"FATAL: {path}:{lineno}: where={where!r} must be "
                f"'initrd+target' or 'target'"
            )
        globs = firmware.split()
        for g in globs:
            if g.startswith("/") or ".." in Path(g).parts:
                raise RuntimeError(
                    f"FATAL: {path}:{lineno}: firmware glob {g!r} must be "
                    f"relative to /usr/lib/firmware"
                )
        rows.append({"device": device, "driver": driver, "package": package,
                     "globs": globs, "initrd": where == "initrd+target"})
    if not rows:
        raise RuntimeError(f"FATAL: {path} has no firmware rows")
    return rows


def firmware_bom_for_arch(arch: str, root: Path = REPO_ROOT) -> Path | None:
    """The arch-scoped firmware BOM: manifests/firmware-$arch.pkgs, else the
    complete architecture-neutral manifests/firmware.pkgs, else None."""
    for name in (f"firmware-{arch}.pkgs", "firmware.pkgs"):
        p = root / "manifests" / name
        if p.is_file():
            return p
    return None


def bom_package_names(bom: Path) -> set[str]:
    return {
        line.split()[0]
        for line in bom.read_text().splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    }


def filter_net_firmware_rows(rows: list[dict], bom: Path | None) -> tuple[list[dict], list[str]]:
    """Drop net-firmware rows whose package is not in the arch BOM.

    The initrd must carry only firmware the arch actually ships (an arm64
    initrd has no use for the amd64-only i915 row). Returns the kept rows and
    the sorted dropped package names for logging/receipts. No BOM -> no filter.
    """
    if bom is None:
        return list(rows), []
    packages = bom_package_names(bom)
    kept = [r for r in rows if r["package"] in packages]
    dropped = sorted({r["package"] for r in rows if r["package"] not in packages})
    return kept, dropped


def _deb_version_key(deb: Path) -> str:
    return deb.name.split("_")[1] if deb.name.count("_") >= 2 else ""


def find_pool_deb(pool: Path, package: str) -> Path:
    """Newest <package>_*.deb anywhere under an apt pool (flat or hashed)."""
    debs = list(pool.rglob(f"{package}_*.deb"))
    if not debs:
        raise RuntimeError(
            f"FATAL: {package} not found under {pool} -- the offline mirror "
            f"must carry it (manifests/firmware.pkgs) before the installer "
            f"initrd can be built"
        )
    if len(debs) == 1:
        return debs[0]

    def _cmp(a: Path, b: Path) -> int:
        va, vb = _deb_version_key(a), _deb_version_key(b)
        if va == vb:
            return 0
        gt = subprocess.run(["dpkg", "--compare-versions", va, "gt", vb],
                            check=False).returncode == 0
        return 1 if gt else -1

    # Debian version order (dpkg), never filename order.
    return max(debs, key=functools.cmp_to_key(_cmp))


def stage_initrd_firmware(rows: list[dict], pool: Path, dest_root: Path,
                          scratch: Path,
                          debs: dict[str, Path] | None = None) -> list[dict]:
    """Copy every initrd-scoped firmware glob out of its pool .deb.

    Files land at <dest_root>/lib/firmware/<path relative to
    /usr/lib/firmware>.  Returns [{path, size, package}] sorted by path.
    Every glob must match at least one regular file, so a package that
    renames or drops a blob breaks the build instead of shipping an
    installer that silently lacks it.
    """
    if not pool.is_dir():
        raise RuntimeError(f"FATAL: firmware pool not found: {pool}")
    staged: dict[str, dict] = {}
    extracted: dict[str, Path] = {}
    for row in rows:
        if not row["initrd"]:
            continue
        pkg = row["package"]
        if pkg not in extracted:
            deb = (debs or {}).get(pkg) or find_pool_deb(pool, pkg)
            out = scratch / pkg
            out.mkdir(parents=True, exist_ok=True)
            subprocess.run(["dpkg-deb", "-x", str(deb), str(out)], check=True)
            fw_root = out / "usr" / "lib" / "firmware"
            if not fw_root.is_dir():
                fw_root = out / "lib" / "firmware"
            if not fw_root.is_dir():
                raise RuntimeError(f"FATAL: {deb} ships no /usr/lib/firmware tree")
            extracted[pkg] = fw_root
        fw_root = extracted[pkg]
        for g in row["globs"]:
            matches = [m for m in sorted(fw_root.glob(g)) if m.is_file()]
            if not matches:
                raise RuntimeError(
                    f"FATAL: {pkg} has no firmware matching {g!r} "
                    f"(row: {row['device']})"
                )
            for m in matches:
                rel = m.relative_to(fw_root).as_posix()
                dst = dest_root / "lib" / "firmware" / rel
                dst.parent.mkdir(parents=True, exist_ok=True)
                # copyfile follows symlinks: the initrd gets real bytes even
                # where the package ships a compatibility symlink.
                shutil.copyfile(m, dst)
                dst.chmod(0o644)
                staged[rel] = {"path": rel, "size": dst.stat().st_size,
                               "package": pkg}
    return [staged[k] for k in sorted(staged)]


# Helpers preseed.cfg's early_command needs. They were copied off the mounted
# medium, but early_command runs at S33preseed_early_command -- right after
# S30initrd-preseed loads the baked /preseed.cfg and long before anything has
# necessarily mounted an NCZ medium anywhere. So $NCZSRC often does not resolve
# yet, the copies fail into a log nobody reads, and the diagnostic SSH server,
# the USB rescan and the component selector simply never run. Baking them into
# the initrd root gives early_command the same zero-mount-dependency guarantee
# the preseed itself already has; preseed.cfg prefers /ncz/<name> and still
# falls back to the medium.
BAKED_HELPERS = [
    "diag-console.sh",
    "usb-rescan.sh",
    "sshd-watcher.sh",
    "component-selector.sh",
    "hostname-suggest.sh",
    "ncz-hostname-gen.sh",
    "ncz-ui.sh",
    "locale-keyboard-chooser.sh",
    # 2026-09-30: 6-step interactive flow (components, region, username, password+confirm,
    # hostname, disk+fs) plus boot-progress messages and the extracted ssh-keys helper.
    "region-chooser.sh",
    "user-chooser.sh",
    "boot-progress.sh",
    "ssh-keys.sh",
    # 2026-10-06: NIC carrier scan + netcfg pin, re-applied after the media preseed reload.
    "net-pick.sh",
    # 2026-10-06: bounded background SNTP / HTTP-Date clock correction (clock-setup/ntp=false).
    "clock-sync.sh",
]

# NCZ startup hook. d-i runs its /usr/lib/debian-installer-startup.d/S* scripts
# in lexical order; S60auto-install writes /var/run/auto-install.active=1
# ("disable locale & kbd selection for now") and file-preseed.postinst used to
# set it back to 0 after loading the media preseed. The Install entry no longer
# passes preseed/file= (see build-refind-esp.py), so file-preseed is not
# installed and nothing reopens that window. This hook runs after S60 (S61 >
# S60) and clears the flag, restoring the localechooser/console-setup
# installability operators see today. It acts only when the baked /preseed.cfg
# actually drove auto mode -- the interactive Expert and Rescue entries never
# create the active file, so they are untouched. A proposed `echo 0` inside
# preseed/early_command does NOT work: early_command is S33, before S60 writes
# the 1.
NCZ_STARTUP_HOOK_NAME = "S61ncz-preseed-reenable"
NCZ_STARTUP_HOOK_REL = "usr/lib/debian-installer-startup.d/" + NCZ_STARTUP_HOOK_NAME
NCZ_STARTUP_HOOK_BODY = """#!/bin/sh
# NCZ single-preseed locale/keyboard window.
#
# The rEFInd Install entry loads preseed.cfg once (d-i S30initrd-preseed, from
# the baked /preseed.cfg) and no longer passes preseed/file=, so the
# file-preseed udeb is not installed and its postinst no longer sets
# /var/run/auto-install.active back to 0. S60auto-install writes 1 and exits;
# this hook runs after it (S61 > S60) and clears the flag so localechooser and
# console-setup-udeb stay installable, exactly as before. It acts only when the
# baked /preseed.cfg drove auto mode, so the interactive Expert and Rescue
# entries (which never create the active file) are untouched.
if [ -e /preseed.cfg ] && [ -f /var/run/auto-install.active ] && [ "$(cat /var/run/auto-install.active 2>/dev/null)" = "1" ]; then
    echo 0 > /var/run/auto-install.active
fi
"""

REQUIRED_SSH_UDEBS = (
    "libc6-udeb", "zlib1g-udeb", "libcrypt1-udeb", "libcrypto3-udeb",
    "openssh-client-udeb", "openssh-server-udeb",
)


def patch_t2_kernel(
    base_initrd: Path,
    kernel_deb: Path | None,
    arch: str,
    cache_root: Path,
    force: bool = False,
    preseed_cfg: Path | None = None,
    helper_dir: Path | None = None,
    diag_busybox: Path | None = None,
    ssh_udeb_dir: Path | None = None,
    kernel_image: Path | None = None,
    modules_tar: Path | None = None,
    firmware_pool: Path | None = None,
    net_firmware_table: Path | None = DEFAULT_NET_FIRMWARE_TABLE,
    firmware_bom: Path | None = None,
) -> tuple[Path, Path]:
    if not base_initrd.is_file():
        raise RuntimeError(f"FATAL: no base initrd at {base_initrd}")
    if kernel_deb is not None and not kernel_deb.is_file():
        raise RuntimeError(f"FATAL: kernel .deb missing: {kernel_deb}")
    if kernel_image is not None and not kernel_image.is_file():
        raise RuntimeError(f"FATAL: kernel image missing: {kernel_image}")
    if modules_tar is not None and not modules_tar.is_file():
        raise RuntimeError(f"FATAL: modules tarball missing: {modules_tar}")
    if kernel_deb is None and (kernel_image is None or modules_tar is None):
        raise RuntimeError("FATAL: provide --kernel-deb, or both --kernel-image and --modules-tar")
    if kernel_deb is not None and (kernel_image is not None or modules_tar is not None):
        raise RuntimeError("FATAL: --kernel-deb and --kernel-image/--modules-tar are mutually exclusive")
    if preseed_cfg is None or not preseed_cfg.is_file():
        raise RuntimeError(
            "FATAL: a real preseed.cfg is required -- the installer loads it "
            "once from the baked initrd and there is no media fallback. Pass a "
            "preseed file; unit fixtures use a real file, never a skip."
        )

    # The moment preseed.cfg goes into the initrd it is what every install
    # reads, so this is the last place a snapshot drift can still be cheap.
    if preseed_cfg is not None:
        gate = REPO_ROOT / "build" / "check-preseed-mirror-sync.sh"
        if gate.is_file():
            r = subprocess.run(["bash", str(gate)], capture_output=True, text=True)
            if r.returncode != 0:
                raise RuntimeError(
                    "FATAL: preseed.cfg's mirror block has drifted from "
                    "release.conf -- refusing to bake it into the initrd.\n"
                    + r.stdout + r.stderr
                )
            log(f"    {r.stdout.strip()}")
        else:
            log(f"WARNING: {gate} missing -- preseed/release.conf mirror sync NOT checked")

    helpers: list[Path] = []
    if helper_dir is not None:
        missing = [n for n in BAKED_HELPERS if not (helper_dir / n).is_file()]
        if missing:
            raise RuntimeError(
                f"FATAL: {helper_dir} is missing early_command helpers "
                f"{missing} -- baking an incomplete set would reintroduce the "
                f"silent no-op this bake exists to prevent"
            )
        helpers = [helper_dir / n for n in BAKED_HELPERS]
    if diag_busybox is not None and not diag_busybox.is_file():
        raise RuntimeError(f"FATAL: diag busybox not found: {diag_busybox}")
    ssh_udebs: list[Path] = []
    if ssh_udeb_dir is not None:
        if not ssh_udeb_dir.is_dir():
            raise RuntimeError(f"FATAL: --ssh-udeb-dir not found: {ssh_udeb_dir}")
        ssh_udebs = sorted(ssh_udeb_dir.glob("*.udeb"))
        if not ssh_udebs:
            raise RuntimeError(f"FATAL: no *.udeb files in {ssh_udeb_dir}")
        missing_ssh_udebs = [
            pkg for pkg in REQUIRED_SSH_UDEBS
            if not any(u.name.startswith(pkg + "_") for u in ssh_udebs)
        ]
        if missing_ssh_udebs:
            raise RuntimeError(
                f"FATAL: incomplete diagnostic SSH udeb closure in "
                f"{ssh_udeb_dir}; missing {missing_ssh_udebs}"
            )

    fw_rows: list[dict] = []
    fw_debs: dict[str, Path] = {}
    fw_bom: Path | None = None
    if firmware_pool is not None:
        if net_firmware_table is None or not net_firmware_table.is_file():
            raise RuntimeError(
                f"FATAL: --firmware-pool given but net firmware table missing: "
                f"{net_firmware_table}"
            )
        if not firmware_pool.is_dir():
            raise RuntimeError(f"FATAL: firmware pool not found: {firmware_pool}")
        fw_rows = load_net_firmware_table(net_firmware_table)
        # Arch-scoped: stage only rows whose package the target arch's BOM ships
        # (manifests/firmware-$arch.pkgs, else the complete firmware.pkgs). The
        # i915 row is amd64-only in practice, so an arm64 initrd no longer carries
        # Intel display firmware.
        fw_bom = firmware_bom if firmware_bom is not None else firmware_bom_for_arch(arch)
        fw_rows, _fw_dropped = filter_net_firmware_rows(fw_rows, fw_bom)
        if _fw_dropped:
            log(f"    net firmware not shipped on {arch} "
                f"({fw_bom.name if fw_bom else 'no BOM'}): "
                f"{', '.join(_fw_dropped)} -- skipped")
        for row in fw_rows:
            if row["initrd"] and row["package"] not in fw_debs:
                fw_debs[row["package"]] = find_pool_deb(firmware_pool, row["package"])

    canonical = canonical_encode(
        {
            "schema_version": "ncz-initrd-t2kernel/v7",
            "arch": arch,
            "startup_hook": {
                "name": NCZ_STARTUP_HOOK_NAME,
                "sha256": sha256_bytes(NCZ_STARTUP_HOOK_BODY.encode("utf-8")),
            },
            "base_initrd": _stat(base_initrd),
            "kernel_deb": _stat(kernel_deb) if kernel_deb else {"present": False},
            "kernel_image": _stat(kernel_image) if kernel_image else {"present": False},
            "modules_tar": _stat(modules_tar) if modules_tar else {"present": False},
            "prune_mod_dirs": PRUNE_MOD_DIRS,
            "preseed_cfg": _stat(preseed_cfg),
            "helpers": {p.name: _stat(p) for p in helpers},
            "diag_busybox": _stat(diag_busybox)
            if diag_busybox is not None
            else {"present": False},
            "ssh_udebs": sorted(u.name for u in ssh_udebs),
            "net_firmware_table": (
                _stat(net_firmware_table) if fw_rows else {"present": False}
            ),
            "firmware_bom": _stat(fw_bom) if fw_bom is not None else {"present": False},
            "net_firmware_debs": {k: _stat(v) for k, v in sorted(fw_debs.items())},
        }
    )
# Content-addressed cache nodes are created EMPTY and filled afterwards, and
# every reader treats "the directory exists" as "the build succeeded". An
# interrupted or crashed run therefore leaves a partial node that later runs
# serve as a cache HIT -- silently shipping half a build. Fix: build into a
# sibling .partial.<pid> directory and os.replace() it into its final name only
# after the receipt has been written, so a node is either absent or complete.
# A node that somehow exists without its receipt is treated as incomplete and
# rebuilt rather than trusted.
    node_key = sha256_bytes(canonical)
    node_dir = cache_root / "ncz-initrd-t2kernel" / node_key
    initrd_verify: dict | None = None
    if node_dir.exists() and not force:
        if (node_dir / "receipt.json").is_file():
            # A cache hit gets the same final-output check as a fresh build:
            # the kernel file must exist and the initrd must still carry the
            # exact preseed + hook bytes. receipt.json alone is not proof.
            _verify_node_outputs(node_dir, preseed_cfg)
            log(f"node exists: {node_dir} (verified)")
            return node_dir / "linux", node_dir / "initrd.gz"
        log(f"WARNING: incomplete cache node (no receipt.json): {node_dir} -- rebuilding")
    if node_dir.exists():
        shutil.rmtree(node_dir)
    build_dir = node_dir.parent / f"{node_key}.partial.{os.getpid()}"
    shutil.rmtree(build_dir, ignore_errors=True)
    build_dir.mkdir(parents=True)

    with tempfile.TemporaryDirectory(prefix="patch-t2kernel-") as tmp:
        tmp = Path(tmp)
        kernel_extract = tmp / "kernel"
        kernel_extract.mkdir()
        if kernel_deb is not None:
            log(f"    extracting {kernel_deb} -> {kernel_extract}")
            subprocess.run(["dpkg-deb", "-x", str(kernel_deb), str(kernel_extract)], check=True)
        else:
            log(f"    extracting Sky1 modules {modules_tar} -> {kernel_extract}")
            subprocess.run(["tar", "-xzf", str(modules_tar), "-C", str(kernel_extract)], check=True)

        modules_dirs = sorted((kernel_extract / "lib" / "modules").glob("*"))
        if len(modules_dirs) != 1:
            raise RuntimeError(
                f"FATAL: expected exactly one lib/modules/<kver> dir in "
                f"kernel input, found {len(modules_dirs)}: {modules_dirs}"
            )
        kver = modules_dirs[0].name
        log(f"    real kernel version: {kver}")

        if kernel_deb is not None:
            vmlinuz_candidates = sorted((kernel_extract / "boot").glob(f"vmlinuz-{kver}"))
            if not vmlinuz_candidates:
                raise RuntimeError(f"FATAL: no boot/vmlinuz-{kver} in {kernel_deb}")
            vmlinuz_src = vmlinuz_candidates[0]
        else:
            vmlinuz_src = kernel_image

        # --- build the modules overlay -------------------------------
        overlay_root = tmp / "overlay"
        overlay_root.mkdir()
        overlay_modules = overlay_root / "lib" / "modules" / kver
        overlay_modules.parent.mkdir(parents=True)
        shutil.copytree(modules_dirs[0], overlay_modules, symlinks=True)

        for d in PRUNE_MOD_DIRS:
            p = overlay_modules / "kernel" / d
            if p.is_dir():
                shutil.rmtree(p)
                log(f"    pruned kernel/{d}")

        # d-i's kmod udeb cannot decompress .ko.xz -- real, confirmed gotcha.
        xz_mods = list(overlay_modules.rglob("*.ko.xz"))
        if xz_mods:
            subprocess.run(["xz", "-d"] + [str(p) for p in xz_mods], check=True)
            log(f"    decompressed {len(xz_mods)} .ko.xz modules -> plain .ko "
                f"(d-i kmod cannot read xz)")

        orphans = prune_unsatisfiable_modules(overlay_modules)
        if orphans:
            log(f"    pruned {len(orphans)} modules left with unsatisfiable "
                f"dependencies by the kernel/{'+'.join(PRUNE_MOD_DIRS)} prune: "
                f"{orphans}")
        leftover = prune_unsatisfiable_modules(overlay_modules)
        if leftover:
            raise RuntimeError(
                f"FATAL: dependency prune did not converge -- still "
                f"unsatisfiable: {leftover}"
            )

        subprocess.run(
            ["sudo", "/sbin/depmod", "-a", "-b", str(overlay_root), kver],
            check=True,
        )
        if not (overlay_modules / "modules.dep").is_file():
            raise RuntimeError("FATAL: depmod did not produce modules.dep")
        subprocess.run(
            ["sudo", "chown", "-R", f"{os.getuid()}:{os.getgid()}", str(overlay_root)],
            check=True,
        )

        # --- network firmware into the overlay's /lib/firmware -----------
        # d-i ships no non-free firmware. r8169 is built into the Sky1 kernel
        # and asks for rtl_nic/* at ndo_open; btusb/btmtk asks for the MT79xx
        # BT blob at probe and, when it is missing, resets the USB device and
        # retries every ~0.4 s for the whole install. The kernel firmware
        # loader waits for the initramfs to be unpacked before searching
        # /lib/firmware, so blobs placed here are visible to built-in drivers
        # too. lib/firmware goes through the same `find lib -mindepth 1` walk
        # as lib/modules, so no bare top-level "lib" entry is emitted.
        net_fw: list[dict] = []
        if fw_rows:
            net_fw = stage_initrd_firmware(fw_rows, firmware_pool, overlay_root,
                                           tmp / "net-firmware", fw_debs)
            log(f"    baked {len(net_fw)} network firmware files "
                f"({sum(f['size'] for f in net_fw)} bytes) -> initrd "
                f"/lib/firmware from {sorted(fw_debs)}")

        # --- bake preseed.cfg into the initrd ROOT -----------------------
        # Real root cause (confirmed on metal 2026-09-24, not a QEMU
        # artifact): our boot path never does a genuine El-Torito CD-ROM
        # boot (kernel+initrd load straight off the ESP via rEFInd/UEFI),
        # so `preseed/file=/cdrom/ncz-payload/preseed.cfg` depends on
        # cdrom-detect classifying + mounting the medium before that
        # fetch runs -- timing/classification that a real USB-written
        # hybrid medium doesn't guarantee the way QEMU's clean ATAPI
        # CD-ROM emulation did. d-i's OWN initrd-preseed hook
        # (lib/debian-installer-startup.d/S30initrd-preseed) already
        # auto-loads file:///preseed.cfg straight off the initrd
        # filesystem with ZERO device/mount dependency if the file is
        # simply present at the initrd root -- so bake it there instead
        # of fetching it from /cdrom at all.
        # Since 2026-10-08 this is the ONLY preseed load: the Install entry no
        # longer passes preseed/file=, so the file-preseed udeb is not
        # installed and cannot load the same file a second time. The S61 hook
        # baked below restores the locale/keyboard component window that
        # file-preseed.postinst used to reopen.
        shutil.copy2(preseed_cfg, overlay_root / "preseed.cfg")
        log(
            f"    baked {preseed_cfg} -> initrd root /preseed.cfg "
            f"({preseed_cfg.stat().st_size} bytes)"
        )

        # --- bake early_command's helpers into the initrd too -------------
        # /ncz is a NEW top-level directory, so the usr-merge clean_path()
        # hazard documented below does not apply to it: that bites only when a
        # later archive creates a DIRECTORY where the base has a SYMLINK
        # (lib -> usr/lib). Nothing in the base initrd is called "ncz".
        ncz_dir = overlay_root / "ncz"
        if helpers or diag_busybox is not None:
            ncz_dir.mkdir(parents=True, exist_ok=True)
        for h in helpers:
            dst = ncz_dir / h.name
            shutil.copy2(h, dst)
            dst.chmod(0o755)
        if helpers:
            log(f"    baked {len(helpers)} early_command helpers -> initrd "
                f"/ncz/: {[h.name for h in helpers]}")
        if diag_busybox is not None:
            dst = ncz_dir / "busybox"
            shutil.copy2(diag_busybox, dst)
            dst.chmod(0o755)
            log(f"    baked {diag_busybox} -> initrd /ncz/busybox "
                f"({diag_busybox.stat().st_size} bytes)")
        if ssh_udebs:
            ssh_udeb_out = ncz_dir / "ssh-udebs"
            ssh_udeb_out.mkdir(parents=True, exist_ok=True)
            for u in ssh_udebs:
                shutil.copy2(u, ssh_udeb_out / u.name)
            log(f"    baked {len(ssh_udebs)} ssh udebs -> initrd "
                f"/ncz/ssh-udebs/: {[u.name for u in ssh_udebs]}")

        # Persistent installer branding ported from build-iso-di.sh's
        # brand_udeb_templates()/initrd overlay.  The components present in
        # the base initrd register these templates before media discovery, so
        # branding must be in the initrd rather than only on partition 2.
        initrd_extract = tmp / "initrd-extract"
        initrd_extract.mkdir()
        gz = subprocess.Popen(["gzip", "-dc", str(base_initrd)], stdout=subprocess.PIPE)
        cp = subprocess.run(["cpio", "-id", "--quiet"], cwd=initrd_extract,
                            stdin=gz.stdout, stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL)
        gz.stdout.close()
        gz_rc = gz.wait()
        # cpio returns 2 here solely because an unprivileged build user cannot
        # mknod the initrd's dev/{console,null}; all regular files (including
        # the templates we need) are still extracted.  Gate the actual inputs
        # below instead of rejecting that expected device-node warning.
        if gz_rc != 0 or cp.returncode not in (0, 2):
            raise RuntimeError("FATAL: could not extract base initrd for persistent UI branding")

        # Debian hw-detect's checker normally remembers the timestamp of its
        # previous invocation and discards all older dmesg lines.  Firmware
        # failures emitted during boot can therefore sit permanently behind
        # that cursor while every later check reports "no missing firmware".
        # Patch the actual d-i program in the overlay: every invocation scans
        # the complete boot log, while the rest of upstream's parsing,
        # filtering, prompting, and firmware loading remains untouched.
        fwcheck_src = initrd_extract / "usr" / "bin" / "check-missing-firmware"
        if not fwcheck_src.is_file():
            raise RuntimeError(
                "FATAL: d-i initrd has no /usr/bin/check-missing-firmware to patch"
            )
        fwcheck = patch_check_missing_firmware(
            fwcheck_src.read_text(errors="surrogateescape")
        )
        fwcheck_dst = overlay_root / "usr" / "bin" / "check-missing-firmware"
        fwcheck_dst.parent.mkdir(parents=True, exist_ok=True)
        fwcheck_dst.write_text(fwcheck, errors="surrogateescape")
        fwcheck_dst.chmod(0o755)
        log("    patched d-i check-missing-firmware to scan complete dmesg")

        replacements = (
            ("Debian installer main menu", "NCZ-OS installer main menu"),
            ("Debian GNU/Linux Installer menu", "NCZ-OS installer menu"),
            ("Debian GNU/Linux installer main menu", "NCZ-OS installer main menu"),
            ("the Debian installer", "the NCZ-OS installer"),
            ("Debian installer", "NCZ-OS installer"),
            ("Debian GNU/Linux", "NCZ-OS"),
        )
        branded = []
        for component in ("main-menu", "finish-install", "choose-mirror",
                          "di-utils", "cdrom-detect", "cdrom-checker", "anna"):
            src = initrd_extract / "var" / "lib" / "dpkg" / "info" / f"{component}.templates"
            if not src.is_file():
                continue
            text = src.read_text(errors="surrogateescape")
            changed = text
            for old, new in replacements:
                changed = changed.replace(old, new)
            if changed == text:
                continue
            dst = overlay_root / "var" / "lib" / "dpkg" / "info" / src.name
            dst.parent.mkdir(parents=True, exist_ok=True)
            dst.write_text(changed, errors="surrogateescape")
            dst.chmod(0o644)
            branded.append(component)
        log(f"    baked persistent NCZ d-i template branding: {branded}")

        # --- one-kernel: prune the substrate's Debian kernel-module udebs --
        # The base d-i initrd carries the substrate's OWN kernel module udebs
        # (`ata-modules-<kver>-<arch>-di`, `linux-base-<kver>-<arch>-di`, ...).
        # We boot OUR kernel and bake OUR module tree, so those are dead weight
        # AND a hard one-kernel provenance failure.  We cannot rebuild the
        # substrate's initrd, but we can (a) drop the dead
        # `[usr/]lib/modules/<debian-kver>` members and the base's own dpkg
        # status in filter_base_cpio, and (b) bake a pruned status (Debian
        # kernel-artifact records + the Architecture-less `debian-installer`
        # marker removed) as the overlay's later-archive copy, which both the
        # kernel and the provenance scanner read.
        base_status = initrd_extract / "var" / "lib" / "dpkg" / "status"
        if not base_status.is_file():
            raise RuntimeError(
                f"FATAL: base d-i initrd has no {_STATUS_REL}; cannot prune the "
                f"substrate's Debian kernel-module udebs (one-kernel policy)"
            )
        pruned_status, pruned_status_pkgs = prune_initrd_status(
            base_status.read_text(errors="surrogateescape")
        )
        overlay_status = overlay_root / "var" / "lib" / "dpkg" / "status"
        overlay_status.parent.mkdir(parents=True, exist_ok=True)
        overlay_status.write_text(pruned_status, errors="surrogateescape")
        log(f"    pruned {len(pruned_status_pkgs)} Debian kernel-artifact / d-i "
            f"marker dpkg records from the installer status "
            f"(one-kernel policy)")

        # --- bake the single-preseed startup hook -------------------------
        # Runs after S60auto-install to reopen the locale/keyboard window that
        # file-preseed.postinst used to (it no longer runs: preseed/file is not
        # on the Install cmdline). Lives under usr/lib, so the usr walk in the
        # filelist below picks it up; it is not the top-level lib symlink.
        hook_dst = overlay_root / NCZ_STARTUP_HOOK_REL
        hook_dst.parent.mkdir(parents=True, exist_ok=True)
        hook_dst.write_text(NCZ_STARTUP_HOOK_BODY)
        hook_dst.chmod(0o755)
        log(
            f"    baked {NCZ_STARTUP_HOOK_NAME} -> initrd /{NCZ_STARTUP_HOOK_REL} "
            f"({len(NCZ_STARTUP_HOOK_BODY)} bytes)"
        )

        # Real usr-merge gotcha (verbatim from build-iso-di.sh): NEVER
        # emit a bare top-level "lib" dir entry, or a later archive's
        # directory-creation deletes the base initrd's lib->usr/lib
        # symlink (and libc/the dynamic loader with it). preseed.cfg is
        # a plain root-level FILE (no directory-creation collision), so
        # it's safe to list explicitly alongside the lib/ walk.
        overlay_cpio_gz = tmp / "overlay.cpio.gz"
        filelist = tmp / "overlay.filelist"
        find_lib = subprocess.run(
            ["find", "lib", "-mindepth", "1", "-print"],
            cwd=overlay_root, check=True, capture_output=True, text=True,
        ).stdout
        with filelist.open("w") as fl:
            fl.write(find_lib)
            fl.write("preseed.cfg\n")
            if ncz_dir.is_dir():
                fl.write(subprocess.run(
                    ["find", "ncz", "-print"],
                    cwd=overlay_root, check=True, capture_output=True, text=True,
                ).stdout)
            fwcheck_root = overlay_root / "usr"
            if fwcheck_root.is_dir():
                fl.write(subprocess.run(
                    ["find", "usr", "-print"], cwd=overlay_root, check=True,
                    capture_output=True, text=True,
                ).stdout)
            branded_root = overlay_root / "var"
            if branded_root.is_dir():
                fl.write(subprocess.run(
                    ["find", "var", "-print"], cwd=overlay_root, check=True,
                    capture_output=True, text=True,
                ).stdout)
        with filelist.open("rb") as fl_in:
            cpio_proc = subprocess.Popen(
                ["cpio", "-o", "-H", "newc", "--quiet"],
                cwd=overlay_root, stdin=fl_in, stdout=subprocess.PIPE,
            )
            with overlay_cpio_gz.open("wb") as out_f:
                with gzip.GzipFile(fileobj=out_f, mode="wb", compresslevel=9) as gz_out:
                    shutil.copyfileobj(cpio_proc.stdout, gz_out)
            cpio_proc.wait()
        if cpio_proc.returncode != 0:
            raise RuntimeError("FATAL: overlay cpio pack failed")
        log(f"    overlay cpio: {overlay_cpio_gz.stat().st_size} bytes")

        # Prune the base archive: drop the substrate's Debian kernel module
        # tree(s) and the base dpkg status (replaced by the overlay's pruned
        # copy).  Byte-verbatim otherwise, so the archive stays deterministic.
        base_pruned = tmp / "base-pruned.cpio.gz"
        base_stream = _decompress_single_gzip(base_initrd)
        filtered, dropped_kvers, dropped_members = filter_base_cpio(base_stream, kver)
        with gzip.GzipFile(fileobj=base_pruned.open("wb"), mode="wb",
                           compresslevel=9, mtime=0) as gz_out:
            gz_out.write(filtered)
        if not dropped_kvers:
            log("    WARNING: base d-i initrd carried no Debian kernel module "
                "tree -- nothing to prune (unexpected for a Debian netinst)")
        log(f"    pruned base initrd: dropped {dropped_members} members of the "
            f"substrate kernel module tree(s) {sorted(dropped_kvers)} "
            f"(one-kernel policy); kept ours ({kver})")

        # Keep both CPIO archives in one gzip member. Concatenating the two
        # .gz files worked on amd64 but the Sky1 arm64 kernel stopped after
        # the first member, dropping /preseed.cfg and /ncz completely.
        out_initrd = build_dir / "initrd.gz"
        write_single_member_initrd(base_pruned, overlay_cpio_gz, out_initrd)
        # Read the FINAL cpio back: a missing/mismatched /preseed.cfg or a hook
        # that did not make it in fails the build here, not at KVM.
        initrd_verify = verify_baked_preseed(out_initrd, preseed_cfg)
        # Fail closed HERE if a Debian kernel artifact survived the prune
        # (the very failure the r203 provenance gate reported).
        verify_one_kernel_initrd(out_initrd, kver)
        log(
            f"    verified initrd carries /{initrd_verify['preseed_member']} "
            f"({initrd_verify['preseed_sha256'][:12]}) and "
            f"{initrd_verify['hook_member']} "
            f"(mode {initrd_verify['hook_mode']})"
        )

        out_linux = build_dir / "linux"
        shutil.copy2(vmlinuz_src, out_linux)

    receipt = {
        "schema_version": "ncz-initrd-t2kernel-receipt/v1",
        "node_key": node_key,
        "node_kind": "ncz-initrd-t2kernel",
        "arch": arch,
        "kver": kver,
        "inputs": {
            "base_initrd": str(base_initrd),
            "base_initrd_sha256": sha256_file(base_initrd),
            "kernel_deb": str(kernel_deb) if kernel_deb else None,
            "kernel_deb_sha256": sha256_file(kernel_deb) if kernel_deb else None,
            "kernel_image": str(kernel_image) if kernel_image else None,
            "modules_tar": str(modules_tar) if modules_tar else None,
            "prune_mod_dirs": PRUNE_MOD_DIRS,
            "pruned_unsatisfiable_modules": orphans,
            "one_kernel_pruned_base_kvers": sorted(dropped_kvers),
            "one_kernel_pruned_base_members": dropped_members,
            "one_kernel_pruned_status_packages": pruned_status_pkgs,
            "baked_preseed_cfg": str(preseed_cfg),
            "baked_preseed_verified": initrd_verify,
            "baked_startup_hook": NCZ_STARTUP_HOOK_NAME,
            "baked_helpers": [h.name for h in helpers],
            "baked_diag_busybox": str(diag_busybox) if diag_busybox else None,
            "baked_ssh_udebs": [u.name for u in ssh_udebs],
            "net_firmware_debs": {k: str(v) for k, v in sorted(fw_debs.items())},
            "baked_net_firmware": net_fw,
        },
        "outputs": {
            "linux": str(out_linux),
            "linux_sha256": sha256_file(out_linux),
            "linux_size": out_linux.stat().st_size,
            "initrd_gz": str(out_initrd),
            "initrd_gz_sha256": sha256_file(out_initrd),
            "initrd_gz_size": out_initrd.stat().st_size,
        },
    }
    (build_dir / "receipt.json").write_text(json.dumps(receipt, indent=2, sort_keys=True))
    # Atomic publish: until this rename, no other run can see a partial node.
    os.replace(build_dir, node_dir)
    log(f"OK: T2-kernel-patched linux+initrd at {node_dir}")
    return node_dir / "linux", node_dir / "initrd.gz"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--base-initrd", required=True, type=Path)
    group = ap.add_mutually_exclusive_group(required=True)
    group.add_argument("--kernel-deb", type=Path)
    group.add_argument("--kernel-image", type=Path,
                       help="raw Sky1 Image-cixmini.bin; requires --modules-tar")
    ap.add_argument("--modules-tar", type=Path,
                    help="Sky1 modules-cixmini.tgz used with --kernel-image")
    ap.add_argument("--arch", required=True, choices=["amd64", "arm64"])
    ap.add_argument("--cache-root", type=Path, default=DEFAULT_CACHE_ROOT)
    ap.add_argument("--force", action="store_true")
    ap.add_argument("--helper-dir", type=Path, default=REPO_ROOT / "preseed",
                     help="Directory holding the early_command helper scripts "
                          "baked into the initrd at /ncz/. Pass --helper-dir= "
                          "(empty) to skip.")
    ap.add_argument("--diag-busybox", type=Path, default=None,
                     help="Static busybox baked in at /ncz/busybox for the "
                          "diag console; defaults to "
                          "assets/diag/busybox-<arch>.")
    ap.add_argument(
        "--preseed-cfg",
        type=Path,
        default=REPO_ROOT / "preseed" / "preseed.cfg",
        help="Baked into the initrd root as /preseed.cfg (d-i's "
        "S30initrd-preseed auto-loads it with zero "
        "device/mount dependency). Required: there is no "
        "skip; the installer has no media preseed fallback.",
    )
    ap.add_argument("--ssh-udeb-dir", type=Path, default=None,
                     help="Directory of *.udeb files (openssh-server-udeb + "
                          "its real deps) baked into the initrd at "
                          "/ncz/ssh-udebs/ so early_command can udpkg -i "
                          "them with zero medium/device dependency -- d-i "
                          "never starts sshd on its own in auto=true "
                          "unattended mode (only the optional network-console "
                          "component does that), so remote diagnostics need "
                          "this to exist at all. Defaults to "
                          "assets/ssh-udebs/<arch> if present.")
    ap.add_argument("--firmware-pool", type=Path, default=None,
                     help="apt pool (the offline mirror's pool/) holding the "
                          "firmware-*.deb packages named in "
                          "--net-firmware-table; rows scoped initrd+target "
                          "are baked into the initrd at /lib/firmware. "
                          "build-installer-image.sh always passes it.")
    ap.add_argument("--net-firmware-table", type=Path,
                     default=DEFAULT_NET_FIRMWARE_TABLE,
                     help="device -> driver -> package -> firmware map "
                          "(default manifests/net-firmware.tsv)")
    ap.add_argument("--firmware-bom", type=Path, default=None,
                     help="arch-scoped firmware BOM whose packages gate which "
                          "net-firmware rows are staged (default: "
                          "manifests/firmware-<arch>.pkgs, else firmware.pkgs). "
                          "Rows whose package is not in the BOM are skipped.")
    args = ap.parse_args()
    if args.firmware_pool is None:
        log("WARNING: no --firmware-pool -- the installer initrd will carry NO "
            "NIC/Bluetooth firmware (rtl_nic/*, MT79xx BT)")
    preseed_cfg = args.preseed_cfg
    if not preseed_cfg.is_file():
        log(
            "FATAL: a real --preseed-cfg file is required. The installer loads "
            "the preseed once from the baked initrd and has no media fallback, "
            "so there is no supported skip (including --preseed-cfg=)."
        )
        return 1

    helper_dir = args.helper_dir if str(args.helper_dir) else None
    if helper_dir is not None and not helper_dir.is_dir():
        log(f"FATAL: --helper-dir {helper_dir} is not a directory")
        return 1
    diag_busybox = args.diag_busybox
    if diag_busybox is None:
        cand = REPO_ROOT / "assets" / "diag" / f"busybox-{args.arch}"
        if cand.is_file():
            diag_busybox = cand
        else:
            log(f"WARNING: no {cand} -- the diag console will have no baked "
                f"busybox and must find one on the medium")

    ssh_udeb_dir = args.ssh_udeb_dir
    if ssh_udeb_dir is None:
        cand = REPO_ROOT / "assets" / "ssh-udebs" / args.arch
        if cand.is_dir() and any(cand.glob("*.udeb")):
            ssh_udeb_dir = cand
        else:
            log(f"WARNING: no {cand} -- remote SSH diagnostics will not be "
                f"available during install (d-i never starts sshd on its "
                f"own in auto=true unattended mode)")

    try:
        linux_out, initrd_out = patch_t2_kernel(
            args.base_initrd, args.kernel_deb, args.arch,
            args.cache_root, args.force, preseed_cfg,
            helper_dir, diag_busybox, ssh_udeb_dir,
            args.kernel_image, args.modules_tar,
            args.firmware_pool, args.net_firmware_table,
            args.firmware_bom,
        )
    except RuntimeError as e:
        log(str(e))
        return 1
    print(f"{linux_out}\n{initrd_out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
