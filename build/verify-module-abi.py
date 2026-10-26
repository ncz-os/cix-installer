#!/usr/bin/env python3
"""verify-module-abi.py: every out-of-tree .ko must have the kernel's struct
module layout and vermagic, or the kernel refuses to load it.

WHY (2026-10-26, Preview4 desktop on O6N, kernel 7.3.0-sky1-ncz r292). The
three Mali modules shipped in updates/ had a .gnu.linkonce.this_module section
of 0x4c0 bytes; the kernel and every module built with it use 0x500. The
loader refused them ("module mali_kbase: .gnu.linkonce.this_module section
size must match the kernel's built struct module size at run time"), so the
board had no GPU and no desktop. Vermagic and MODVERSIONS CRCs were correct, so
build/verify-overlays.py and build/verify-overlay-modversions.py both passed:
the size of struct module depends on CONFIG_* options (here
DEBUG_INFO_BTF_MODULES, dropped when a host without pahole re-ran Kconfig on
the header tree), and nothing compared it. This tool does.

WHAT IT CHECKS, for one lib/modules/<kver> tree (an installed root, a kernel
.deb staging root, ...):
  - the reference is an in-tree module of the same kernel build: --ref, else
    the first .ko under <tree>/kernel/ in sorted order;
  - every .ko under <tree>/updates/ and <tree>/extra/ (recursive, so
    updates/dkms/ is included), plus any --ko files, must have the reference's
    .gnu.linkonce.this_module size and vermagic.
  A compressed module (.ko.xz) is decompressed and checked; any other
  compressed form fails (this project ships uncompressed modules).

--probe-report FILE judges the in-guest ncz-module-abi-probe output
(post-install/97-firstboot-report.sh) copied off a KVM gate guest:
  "# module-abi: <mod> OK|SKIP|INFO|FAIL ..."   one line per module
  "# module-abi-reject: <kernel log line>"       loader rejections in the log
  "# module-abi-probe=modules:N failed:M skipped:S"   summary, last
  "# module-abi-probe=skipped (not a VM guest)"  the probe did not run
It passes only on a summary with failed:0 and no FAIL or reject line; a
skipped probe fails (the gate always boots a VM, so a skip means the probe
did not see one).

Usage:
  build/verify-module-abi.py [--ref KO] [--ko KO ...] [--allow-empty] [TREE]
  build/verify-module-abi.py --probe-report FILE
Exit: 0 pass, 1 mismatch (every failure printed), 2 bad invocation or no
reference module. Pure Python, no kmod/binutils needed, any host arch.
"""

import argparse
import lzma
import os
import struct
import sys

TAG = "verify-module-abi"
OOT_DIRS = ("updates", "extra")


class ElfError(Exception):
    pass


def load(path):
    with open(path, "rb") as f:
        data = f.read()
    if path.endswith(".ko.xz"):
        try:
            data = lzma.decompress(data)
        except lzma.LZMAError as exc:
            raise ElfError(f"cannot decompress: {exc}") from exc
    elif not path.endswith(".ko"):
        raise ElfError("unsupported module compression (only .ko and .ko.xz)")
    return data


def module_abi(path):
    """Return (this_module_size, vermagic) for an ELF64 little-endian module."""
    data = load(path)
    if data[:4] != b"\x7fELF":
        raise ElfError("not an ELF file")
    if data[4] != 2 or data[5] != 1:
        raise ElfError(f"not ELF64 little-endian (EI_CLASS={data[4]} EI_DATA={data[5]})")
    try:
        (e_shoff,) = struct.unpack_from("<Q", data, 0x28)
        e_shentsize, e_shnum, e_shstrndx = struct.unpack_from("<HHH", data, 0x3A)
        shdrs = [
            struct.unpack_from("<IIQQQQIIQQ", data, e_shoff + i * e_shentsize)
            for i in range(e_shnum)
        ]
        stroff, strsize = shdrs[e_shstrndx][4], shdrs[e_shstrndx][5]
        shstr = data[stroff : stroff + strsize]
    except (struct.error, IndexError) as exc:
        raise ElfError(f"truncated or malformed section headers: {exc}") from exc
    size = None
    magic = None
    for sh in shdrs:
        end = shstr.find(b"\0", sh[0])
        name = shstr[sh[0] : end if end >= 0 else len(shstr)]
        if name == b".gnu.linkonce.this_module":
            size = sh[5]
        elif name == b".modinfo":
            for item in data[sh[4] : sh[4] + sh[5]].split(b"\0"):
                if item.startswith(b"vermagic="):
                    magic = item[len(b"vermagic=") :].decode("latin-1")
    if size is None:
        raise ElfError("no .gnu.linkonce.this_module section (not a kernel module)")
    return size, magic


def first_in_tree(tree):
    base = os.path.join(tree, "kernel")
    for dirpath, dirnames, filenames in os.walk(base):
        dirnames.sort()
        for name in sorted(filenames):
            if name.endswith(".ko") or name.endswith(".ko.xz"):
                return os.path.join(dirpath, name)
    return None


def out_of_tree(tree):
    found = []
    for sub in OOT_DIRS:
        base = os.path.join(tree, sub)
        for dirpath, _dirnames, filenames in os.walk(base):
            for name in filenames:
                if name.endswith((".ko", ".ko.xz", ".ko.zst", ".ko.gz")):
                    found.append(os.path.join(dirpath, name))
    return sorted(found)


def judge_probe(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            lines = [ln.rstrip("\n") for ln in f]
    except OSError as exc:
        print(f"{TAG}: FAIL: cannot read probe report {path}: {exc}")
        return 1
    bad = [ln for ln in lines if ln.startswith("# module-abi-reject: ")
           or (ln.startswith("# module-abi: ") and len(ln.split()) > 3 and ln.split()[3] == "FAIL")]
    summary = [ln[len("# module-abi-probe="):] for ln in lines if ln.startswith("# module-abi-probe=")]
    for ln in lines:
        if ln.startswith("# module-abi"):
            print(f"  {ln}")
    if bad:
        print(f"{TAG}: FAIL: the kernel refused out-of-tree modules ({len(bad)} line(s) above)")
        return 1
    if not summary:
        print(f"{TAG}: FAIL: no probe summary (ncz-module-abi-probe missing, or it did not finish)")
        return 1
    last = summary[-1]
    if last.startswith("skipped"):
        print(f"{TAG}: FAIL: probe skipped ({last}); a gate guest must be detected as a VM")
        return 1
    fields = dict(kv.split(":", 1) for kv in last.split() if ":" in kv)
    if "modules" not in fields or fields.get("failed") != "0":
        print(f"{TAG}: FAIL: probe summary {last!r}")
        return 1
    print(f"{TAG}: PASS (probe: {last})")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    ap.add_argument("tree", nargs="?", help="a lib/modules/<kver> directory")
    ap.add_argument("--ref", help="in-tree module of the same kernel build")
    ap.add_argument("--ko", action="append", default=[], help="extra module to check")
    ap.add_argument(
        "--allow-empty",
        action="store_true",
        help="pass when the tree has no out-of-tree modules",
    )
    ap.add_argument("--probe-report", help="judge ncz-module-abi-probe output instead")
    a = ap.parse_args()
    if a.probe_report:
        return judge_probe(a.probe_report)
    if not a.tree and not a.ko:
        ap.error("give a lib/modules/<kver> TREE and/or --ko files")
    ref = a.ref or (first_in_tree(a.tree) if a.tree else None)
    if not ref:
        print(f"{TAG}: ERROR: no reference module (no --ref, no .ko under {a.tree}/kernel)", file=sys.stderr)
        return 2
    try:
        ref_size, ref_magic = module_abi(ref)
    except (OSError, ElfError) as exc:
        print(f"{TAG}: ERROR: reference {ref}: {exc}", file=sys.stderr)
        return 2
    if not ref_magic:
        print(f"{TAG}: ERROR: reference {ref} has no vermagic", file=sys.stderr)
        return 2
    print(f"{TAG}: reference {ref}: this_module=0x{ref_size:x} vermagic={ref_magic!r}")

    kos = (out_of_tree(a.tree) if a.tree else []) + list(a.ko)
    if not kos:
        if a.allow_empty:
            print(f"{TAG}: PASS (no out-of-tree modules)")
            return 0
        print(f"{TAG}: FAIL: no out-of-tree modules under {a.tree}/{{{','.join(OOT_DIRS)}}}")
        return 1
    failures = 0
    for ko in kos:
        rel = os.path.relpath(ko, a.tree) if a.tree and ko.startswith(a.tree) else ko
        try:
            size, magic = module_abi(ko)
        except (OSError, ElfError) as exc:
            print(f"FAIL {rel}: unreadable: {exc}")
            failures += 1
            continue
        why = []
        if size != ref_size:
            why.append(
                f"this_module 0x{size:x} != kernel 0x{ref_size:x} (struct module layout differs: built against "
                "a different kernel configuration; the loader refuses it with '.gnu.linkonce.this_module "
                "section size must match')"
            )
        if magic != ref_magic:
            why.append(f"vermagic {magic!r} != kernel {ref_magic!r}")
        if why:
            failures += 1
            print(f"FAIL {rel}: " + "; ".join(why))
        else:
            print(f"OK {rel}: this_module=0x{size:x} vermagic matches")
    if failures:
        print(f"{TAG}: FAIL ({failures} of {len(kos)} module(s) do not match the kernel)")
        return 1
    print(f"{TAG}: PASS ({len(kos)} module(s) match the kernel)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
