#!/usr/bin/env python3
"""verify-overlay-modversions.py: the committed Sky1 accelerator overlay .ko
files must carry the MODVERSIONS symbol CRCs of the pinned kernel.

WHY (2026-10-06, Sky1 r282 -> r284 pin). The r282-era overlays committed under
assets/kernel/{mali,vpu,npu,panthor}/7.3.0-rc6-sky1-ncz/ had the SAME KVER and
the same vermagic string as the r284 kernel, so build/verify-overlays.py
(vermagic only) passed them. Against the r284 Module.symvers they carried 648
symbol CRC mismatches. The r284 kernel has CONFIG_MODVERSIONS=y, so the loader
refuses every one of them ("disagrees about version of symbol"): an image with
no GPU, VPU or NPU while every gate reported success. A rebuild that keeps the
KVER (r282, r283, r284 are all 7.3.0-rc6-sky1-ncz) cannot be caught by any
KVER/vermagic check; only the CRCs tell the builds apart.

WHAT IT CHECKS, for the kernel pinned by assets/kernel/mainline:
  - KVER comes from <staging>/KVER (and must equal variants.mainline.kver in
    assets/kernel-manifest.json when that file exists);
  - every overlay dir (mali, vpu, npu, panthor) has at least one .ko for KVER;
  - every .ko has a __versions section, a vermagic that starts with KVER, and
    for every versioned symbol either the same CRC as the kernel's
    Module.symvers (low 32 bits, as the loader compares them) or an export by
    one of the other overlay modules (__ksymtab_<sym>); anything else is a
    CRC MISMATCH or UNRESOLVED and fails the gate.

Usage:
  build/verify-overlay-modversions.py [--root DIR] [--staging DIR]
                                      [--symvers FILE] [--kver KVER]
Environment: VERIFY_ROOT (same as --root), OVERLAY_STAGING_DIR (--staging).

The staging dir defaults to the target of the assets/kernel/mainline symlink;
when that path is not mounted under its committed spelling, the same
kernel-staging entry is tried under this host's shared Yocto export root
(NCZ_YOCTO_SHARED_DIR, or the first line of ~/.config/ncz/yocto-shared-dir).

Exit: 0 pass, 1 gate failure (every failure printed), 2 inputs not found or bad
invocation. Pure Python, no kmod/binutils needed, any host arch.
"""

import argparse
import json
import os
import struct
import sys

OVERLAY_DIRS = ("mali", "vpu", "npu", "panthor")


def yocto_shared_root():
    """NCZ_YOCTO_SHARED_DIR, else the first line of ~/.config/ncz/yocto-shared-dir."""
    v = os.environ.get("NCZ_YOCTO_SHARED_DIR", "")
    if not v:
        cfg = os.environ.get("XDG_CONFIG_HOME") or os.path.join(
            os.path.expanduser("~"), ".config"
        )
        try:
            with open(os.path.join(cfg, "ncz", "yocto-shared-dir")) as f:
                v = f.readline().strip()
        except OSError:
            v = ""
    return v.rstrip("/")


MODVERSION_ENTRY = (
    64  # struct modversion_info on 64-bit: unsigned long crc + char name[56]
)


class ElfError(Exception):
    pass


def read_sections(path):
    """Return ({name: bytes}, [symbol names]) for an ELF64 little-endian file."""
    with open(path, "rb") as f:
        data = f.read()
    if data[:4] != b"\x7fELF":
        raise ElfError("not an ELF file")
    if data[4] != 2 or data[5] != 1:
        raise ElfError(
            f"not ELF64 little-endian (EI_CLASS={data[4]} EI_DATA={data[5]})"
        )
    try:
        (e_shoff,) = struct.unpack_from("<Q", data, 0x28)
        e_shentsize, e_shnum, e_shstrndx = struct.unpack_from("<HHH", data, 0x3A)
        shdrs = []
        for i in range(e_shnum):
            off = e_shoff + i * e_shentsize
            name, typ, _flags, _addr, offset, size, link, _info, _align, entsize = (
                struct.unpack_from("<IIQQQQIIQQ", data, off)
            )
            shdrs.append((name, typ, offset, size, link, entsize))
        stroff, strsize = shdrs[e_shstrndx][2], shdrs[e_shstrndx][3]
        shstr = data[stroff : stroff + strsize]
    except (struct.error, IndexError) as exc:
        raise ElfError(f"truncated or malformed section headers: {exc}") from exc

    def cstr(buf, off):
        end = buf.find(b"\0", off)
        return buf[off : end if end >= 0 else len(buf)].decode("latin-1")

    sections = {}
    symbols = []
    for name, typ, offset, size, link, entsize in shdrs:
        sname = cstr(shstr, name)
        body = data[offset : offset + size] if typ != 8 else b""  # SHT_NOBITS
        sections[sname] = body
        if typ == 2 and entsize:  # SHT_SYMTAB
            strtab = data[shdrs[link][2] : shdrs[link][2] + shdrs[link][3]]
            for k in range(size // entsize):
                (st_name,) = struct.unpack_from("<I", body, k * entsize)
                if st_name:
                    symbols.append(cstr(strtab, st_name))
    return sections, symbols


def modversions(sections):
    body = sections.get("__versions")
    if body is None:
        return None
    out = []
    for off in range(0, len(body) - MODVERSION_ENTRY + 1, MODVERSION_ENTRY):
        (crc,) = struct.unpack_from("<Q", body, off)
        raw = body[off + 8 : off + MODVERSION_ENTRY]
        out.append((crc & 0xFFFFFFFF, raw.split(b"\0", 1)[0].decode("latin-1")))
    return out


def vermagic(sections):
    for item in sections.get(".modinfo", b"").split(b"\0"):
        if item.startswith(b"vermagic="):
            return item[len(b"vermagic=") :].decode("latin-1")
    return None


def load_symvers(path):
    crcs = {}
    with open(path, encoding="latin-1") as f:
        for line in f:
            parts = line.rstrip("\n").split("\t")
            if len(parts) >= 2 and parts[0].startswith("0x"):
                crcs[parts[1]] = int(parts[0], 16) & 0xFFFFFFFF
    return crcs


def resolve_staging(root, explicit):
    if explicit:
        return explicit if os.path.isdir(explicit) else None, explicit
    link = os.path.join(root, "assets", "kernel", "mainline")
    if os.path.isdir(link):
        return os.path.realpath(link), link
    if not os.path.islink(link):
        return None, link
    target = os.readlink(link)
    root = yocto_shared_root()
    marker = "/kernel-staging/"
    if root and marker in target:
        alt = root + marker + target.split(marker, 1)[1]
        if os.path.isdir(alt):
            return alt, target
    return None, target


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    here = os.path.dirname(os.path.abspath(__file__))
    ap.add_argument(
        "--root", default=os.environ.get("VERIFY_ROOT") or os.path.dirname(here)
    )
    ap.add_argument("--staging", default=os.environ.get("OVERLAY_STAGING_DIR"))
    ap.add_argument("--symvers")
    ap.add_argument("--kver")
    a = ap.parse_args()
    tag = "verify-overlay-modversions"

    staging, wanted = resolve_staging(a.root, a.staging)
    kver = a.kver
    if not kver:
        if not staging:
            print(
                f"{tag}: ERROR: pinned kernel staging dir not found: {wanted}",
                file=sys.stderr,
            )
            return 2
        try:
            with open(os.path.join(staging, "KVER")) as f:
                kver = f.read().strip()
        except OSError as exc:
            print(
                f"{tag}: ERROR: cannot read KVER in {staging}: {exc}", file=sys.stderr
            )
            return 2
    symvers = a.symvers
    if not symvers:
        if not staging:
            print(
                f"{tag}: ERROR: pinned kernel staging dir not found: {wanted}",
                file=sys.stderr,
            )
            return 2
        symvers = os.path.join(
            staging, "headers-dir", "lib", "modules", kver, "build", "Module.symvers"
        )
    if not os.path.isfile(symvers):
        print(f"{tag}: ERROR: Module.symvers not found: {symvers}", file=sys.stderr)
        return 2
    try:
        kcrc = load_symvers(symvers)
    except OSError as exc:
        print(f"{tag}: ERROR: cannot read {symvers}: {exc}", file=sys.stderr)
        return 2
    if not kcrc:
        print(
            f"{tag}: ERROR: no CRC rows in {symvers} (kernel without MODVERSIONS?)",
            file=sys.stderr,
        )
        return 2

    failures = []
    manifest = os.path.join(a.root, "assets", "kernel-manifest.json")
    if os.path.isfile(manifest):
        try:
            with open(manifest) as f:
                mk = json.load(f)["variants"]["mainline"]["kver"]
        except (OSError, ValueError, KeyError, TypeError) as exc:
            mk = None
            failures.append(
                f"kernel-manifest.json has no variants.mainline.kver ({exc})"
            )
        if mk is not None and mk != kver:
            failures.append(
                f"KVER {kver} (staging) != variants.mainline.kver {mk} (kernel-manifest.json)"
            )

    kos = []
    for d in OVERLAY_DIRS:
        base = os.path.join(a.root, "assets", "kernel", d, kver)
        found = (
            sorted(os.path.join(base, n) for n in os.listdir(base) if n.endswith(".ko"))
            if os.path.isdir(base)
            else []
        )
        if not found:
            failures.append(f"MISSING overlay set: assets/kernel/{d}/{kver}/*.ko")
        kos.extend(found)

    parsed = {}
    sibling = set()
    for ko in kos:
        try:
            sections, symbols = read_sections(ko)
        except (OSError, ElfError) as exc:
            failures.append(f"{os.path.relpath(ko, a.root)}: unreadable: {exc}")
            continue
        parsed[ko] = sections
        sibling.update(
            s[len("__ksymtab_") :] for s in symbols if s.startswith("__ksymtab_")
        )

    total_bad = 0
    for ko, sections in parsed.items():
        rel = os.path.relpath(ko, a.root)
        vm = vermagic(sections)
        versions = modversions(sections)
        bad = miss = sib = 0
        if vm is None or not (vm == kver or vm.startswith(kver + " ")):
            failures.append(f"{rel}: vermagic {vm!r} does not start with {kver}")
        if not versions:
            failures.append(
                f"{rel}: no __versions entries (kernel has CONFIG_MODVERSIONS=y; the loader refuses it)"
            )
            versions = []
        for crc, sym in versions:
            if sym in kcrc:
                if kcrc[sym] != crc:
                    bad += 1
                    print(
                        f"  CRC MISMATCH {rel} {sym} module=0x{crc:08x} kernel=0x{kcrc[sym]:08x}"
                    )
            elif sym in sibling:
                sib += 1
            else:
                miss += 1
                print(f"  UNRESOLVED {rel} {sym}")
        if bad or miss:
            failures.append(f"{rel}: crc_mismatch={bad} unresolved={miss}")
        total_bad += bad
        state = "FAIL" if (bad or miss or not versions) else "OK"
        print(
            f"{state} {rel}: versions={len(versions)} crc_mismatch={bad} sibling_overlay={sib} unresolved={miss}"
        )

    print(
        f"{tag}: kver={kver} symvers={symvers} ({len(kcrc)} CRCs) modules={len(parsed)}"
    )
    if failures:
        for msg in failures:
            print(f"{tag}: FAIL: {msg}")
        print(f"{tag}: FAIL ({total_bad} CRC mismatches in total)")
        print(
            f"{tag}: rebuild the overlays against this kernel's headers (build/build-accel-overlays.sh) "
            "or copy the staging dir's overlays/<dir>/<kver>/*.ko"
        )
        return 1
    print(f"{tag}: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
