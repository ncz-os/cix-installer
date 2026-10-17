#!/usr/bin/env python3
"""magnetar_substrate.py -- WHICH debian-installer udebs a Magnetar (server)
medium must carry, and why.

The server variant shipped all 231 substrate udebs (84,996,596 B on the amd64
substrate of 2026-10-13) because it staged the whole d-i pool. Most of that set
can never run on this medium, and the reason is in the CONTRACT itself, not in
a guess: on an NCZ medium d-i boots ONE kernel and ONE preselected component
set before it ever looks at /cdrom.

Two independent mechanisms decide what runs, and this module models both:

1. THE INITRD ALREADY CARRIES THEM. d-i's own initrd is built with
   ANNA_EXTRAS covering the modules+main component closure (from
   ANNA_EXTRAS=$ARCH/package-list in the d-i build). Every udeb in that
   closure is unpacked into the initrd at build time and included in
   /var/lib/dpkg/status, so anna sees it as already installed and NEVER
   fetches it from the medium. Only OPTIONAL components in the component
   list (e.g. network-console) are retriever-fetched. Proven against the real
   substrate initrd. CORRECTION (2026-10-17 re-measurement): extracting
   /install.amd/initrd.gz of debian-testing-amd64-netinst-20261013 shows
   104 packages in /var/lib/dpkg/status, and partman-base, netcfg, pkgsel,
   user-setup-udeb, clock-setup, choose-mirror, partman-auto, partman-ext3,
   base-installer and bootstrap-base are NOT among them: anna loads them
   from the /cdrom pool. The build therefore uses slim_keep_set(), which
   drops only provable classes (provable_drop_reason) and keeps the rest.

2. OUR PRESEED SKIPS THE REST. preseed/preseed.cfg answers/skips whole
   components before main-menu would ask: grub-installer/skip=true,
   systemd-boot-installer/skip=true, partman-auto/method=regular,
   partman-auto/choose_recipe=cixmini (fixed recipe -- no interactive
   partitioning), no swap (no partman-auto-crypto/lvm/raid), no network
   console on the normal path, and anna/no_kernel_modules=true. Anything reachable
   ONLY from a component the preseed skips is dead weight on this medium.

The keep-list below is the union of: (a) the measured initrd-builtin set,
(b) the udebs our own preseed/early_command installs by path (the NIC driver
udebs and the SSH diagnostics stack), and (c) the explicit rescues seeded in
manifests/magnetar-substrate-keep.tsv. Every dropped package is reported with
the reason it can go, so a reviewer can check the argument instead of trusting
it.

Usage:
  magnetar_substrate.py --installer-pool POOL --initrd-initrd PATH|--initrd-status PATH
                        [--arch amd64] [--keep-tsv manifests/magnetar-substrate-keep.tsv]
  magnetar_substrate.py --pool-index PATH --arch amd64     # what to keep
"""

from __future__ import annotations

import argparse
import gzip
import lzma
import os
import re
import sys
from pathlib import Path

# ---------------------------------------------------------------------------
# Module->package mapping.
#
# kernel-wedge names every kernel udeb "<flavour>-modules-<kver>-<arch>-di".
# The flavour is not decorative: d-i's nic-modules / scsi-modules / sata-modules
# / etc. are SPLIT BY FLAVOUR (sound-modules-i386, ...), and a server medium
# boots exactly one flavour (ours: the NCZ kernel packaged from the same
# substrate tree, kernel-wedge flavour "amd64" / "arm64"). A module udeb for a
# flavour we never boot can never be modprobed by any code path on this
# medium. This is the one drop class that needs no per-package argument: it is
# a property of the file NAME and the single kernel we ship (docs/ONE-KERNEL.md
# makes the one-kernel rule explicit for the medium).
# ---------------------------------------------------------------------------
FLAVOUR_MODULE_SUFFIX = "-di"


# The ONLY module udebs that can be dropped by name are ones whose drivers are
# provably not needed by the install path at all. Measured 2026-10-17 on the
# r20261013 amd64 substrate:
#
#   initrd kernel modules .......... 448 .ko (initramfs' own set)
#   of those, drivers/net/* ........ 0   (only net/rfkill/rfkill.ko)
#   nic-modules udeb ............... 122 .ko, 0 of them in the initrd
#   crypto-modules udeb ............ 12 .ko, 0 of them in the initrd
#   btrfs-modules udeb ............. 2 .ko, 0 of them in the initrd
#
# So nic-modules is NOT redundant -- it is the ONLY source of NIC drivers
# before the network exists, and preseed/early_command installs it by path.
# An earlier revision of this module dropped it as a "second copy"; that was
# wrong and the measurement above is what caught it. Same for crypto-modules
# (wpa/WPA3 and the preseed's own clock-setup TLS path) and btrfs-modules
# (partman-btrfs is dropped, but hw-detect can still load btrfs for a
# pre-existing partition layout on a reinstall).
#
# What IS provable with no boot at all: the non-server filesystem module sets.
# The medium's only installed root is ext4 (cixmini recipe, partman-ext3) and
# the data partition is ext4; partman-xfs/partman-btrfs are preseed-excluded
# and one-kernel policy removes any second kernel. xfs-modules and
# jfs-modules therefore serve no udeb that main-menu can reach here.
DROPPABLE_FS_MODULES = {
    "xfs-modules": "installed root and data partitions are ext4; partman-xfs is "
                   "preseed-excluded and no reachable component modprobes xfs",
    "jfs-modules": "no JFS support in the installer path (partman-jfs is not "
                   "shipped at all on this medium)",
}


def is_droppable_driver_udeb(pkg: str, arch: str, flavour: str) -> bool:
    """True for a kernel-module udeb whose drivers the install cannot use."""
    if not pkg.endswith(f"-{arch}{FLAVOUR_MODULE_SUFFIX}"):
        return False
    head = pkg.split("-modules-", 1)[0] + "-modules"
    # xfs-modules, jfs-modules, btrfs-modules: the base name is in the map.
    # jfs/xfs kernel-wedge packages are NOT "<fs>-modules-<kver>-<arch>-di"
    # consistently -- some substrates name them "<fs>-modules", others
    # "<fs>_modules" -- so match on the head token with any separator.
    return head.replace("_", "-") in DROPPABLE_FS_MODULES


# Components our preseed provably skips (see the module docstring). A udeb
# that exists ONLY to serve one of these is dead on this medium.
#
# NEVER list here: partman-btrfs (btrfs is the DEFAULT root filesystem offered
# by preseed/disk-fs-chooser.sh), grub-installer / systemd-boot-installer
# (preseeded skip=true; removing them changes main-menu's bootloader step
# from "skipped" to "absent", which no gate has exercised), save-logs (the
# installer's own "Save debug logs" path).
SKIPPED_COMPONENT_REASONS = {
    "partman-auto-crypto": "preseed partman-auto/method=regular; no crypto recipe",
    "partman-crypto": "preseed partman-auto/method=regular; partman-auto-crypto is not loaded",
    "partman-auto-lvm": "preseed partman-auto/method=regular; cixmini recipe has no LVM",
    "partman-auto-raid": "preseed partman-auto/method=regular; cixmini recipe has no RAID",
    "partman-lvm": "cixmini expert recipe is plain partitions",
    "partman-md": "cixmini expert recipe is plain partitions",
    "partman-multipath": "no multipath on the supported hardware",
    "partman-iscsi": "no iSCSI on the supported hardware",
    "partman-nbd": "no NBD on the supported hardware",
    "partman-xfs": "installed root filesystem is ext4 (partman-ext3)",
    "depthcharge-tools-installer": "no depthcharge/ChromeOS firmware on the supported hardware",
    "espeakup-udeb": "no speech synthesis in the installer (docs/ACCESSIBILITY.md)",
    "espeak-ng-data-udeb": "no speech synthesis in the installer (docs/ACCESSIBILITY.md)",
    "matchbox-keyboard-udeb": "on-screen keyboard is not used by the newt install path",
    "matchbox-window-manager-udeb": "on-screen keyboard is not used by the newt install path",
    "network-preseed": "preseed is baked into the initrd, fetched nowhere",
    "oldsys-preseed": "preseed is baked into the initrd, fetched nowhere",
    "initrd-kickseed": "unattended answers come from preseed.cfg, not kickstart",
    "kickseed-common": "unattended answers come from preseed.cfg, not kickstart",
    "kexec-tools-udeb": "kexec is not used by any NCZ boot path",
    "iprutils-iprutils": "IBM pSeries RAID tools; no supported hardware",
}

# MAINTAINER-SCRIPT DEPENDENCIES -- the cdrom-retriever contract.
#
# anna resolves a udeb's Depends: against the initrd's dpkg status first and
# only pulls from the medium what is genuinely absent. Measured on the
# 2026-10-13 amd64 substrate pool (dpkg-deb -f, reproduced by
# build/test-magnetar-substrate.py):
#
#   debootstrap-udeb Depends: mounted-partitions
#   netcfg Depends: libc6-udeb, libdebconfclient0-udeb,
#                  libdebian-installer4-udeb, libiw30-udeb,
#                  ethernet-card-detection, wpasupplicant-udeb,
#                  crypto-modules, rdnssd-udeb, ndisc6-udeb,
#                  wide-dhcpv6-client-udeb
#
# Every one of those is either already unpacked in the initrd, a virtual
# dependency anna resolves from the status file (mounted-partitions,
# ethernet-card-detection, crypto-modules), or -- for the last four -- a
# fallback alternative d-i only probes when the primary path fails. The
# measured keep-set covers the whole real dependency closure, and the test
# asserts that for every kept udeb, every Depends: alternative is either kept,
# already in the initrd, or virtual. That is the guarantee this list used to
# stand in for, and unlike a hand-written list it cannot go stale: a new
# dependency in a future substrate fails the test instead of shipping broken.
NO_SCRIPT_DEPENDENCY_UDEBS = ()


# Proven from the substrate initrd itself (see module docstring): these are
# unpacked into the initrd's /var/lib/dpkg/status and therefore already
# installed before anna starts. Kept here as the documented expectation, not
# as the source of truth -- measure_substrate_initrd() reads the real initrd.
INITRD_BUILTIN_EXPECTED_SAMPLE = (
    "partman-base",
    "partman-auto",
    "partman-partitioning",
    "partman-basicfilesystems",
    "partman-ext3",
    "partman-target",
    "netcfg",
    "pkgsel",
    "user-setup-udeb",
    "clock-setup",
    "choose-mirror",
    "bootstrap-base",
    "base-installer",
    "debootstrap-udeb",
    "apt-setup-udeb",
    "finish-install",
    "nobootloader",
    "efi-reader",
    "cdrom-retriever",
    "media-retriever",
    "mountmedia",
)

# RUNTIME-REACHABLE udebs. Measured: these are NOT in the initrd's
# /var/lib/dpkg/status on the r20261013 substrate, yet main-menu loads them
# from the medium on the normal path (netcfg is the component that brings the
# interface up; net-retriever fetches the installer's own udeb chain and needs
# udpkg to unpack it). anna therefore MUST find them in the /cdrom pool before
# any network source exists. Keeping them is the cdrom-retriever contract.
RUNTIME_REQUIRED_UDEBS = {
    "netcfg": "main-menu component: configures the interface before the network exists",
    "net-retriever": "anna's own retriever: fetches the rest of the udeb chain",
    # netcfg-static is NOT here: measured 2026-10-17, the amd64 substrate pool
    # does not carry it, so the preseed's DHCP path never loads it either.
}

# The NIC driver udebs preseed/early_command udpkg-installs by path (see
# "_nicudebs" there) -- d-i's nic-modules et al. are NOT in the initrd, which
# is exactly why early_command installs them. Dropping any of these breaks the
# installer's network before DHCP.
# Kernel-wedge names them "<flavour>-modules-<kver>-<arch>-di"; the plain
# names below are what preseed/early_command asks for by basename, and
# keep_set() matches them as prefixes of the real pool names.
PRESEED_NIC_UDEBS = (
    "nic-usb-modules",
    "nic-modules",
    "nic-shared-modules",
    "nic-pcmcia-modules",
    "nic-wireless-modules",
)

# The SSH diagnostics stack early_command installs from /ncz/ssh-udebs, NOT
# from /cdrom, so on a server medium these need not be in the /cdrom pool at
# all. Kept on the medium anyway: stage_installer_substrate() indexes the
# pool dpkg-scanpackages builds, and these are small; removing them would be
# an unproven save.
PRESEED_SSH_UDEBS = ()


def _parse_depends_field(value: str) -> list[str]:
    """Alternation-aware dependency list: 'a, b (>= 1), c | d' -> tokens."""
    out = []
    for group in (value or "").split(","):
        group = group.strip()
        if not group:
            continue
        alternatives = [alt.strip() for alt in group.split("|") if alt.strip()]
        out.extend(alternatives)
    return out


def package_name_of(token: str) -> str:
    """'libc6-udeb (>= 2.43)' -> 'libc6-udeb'."""
    return token.split("(", 1)[0].strip().lower()


class Pool:
    """Index of the substrate pool: package -> udeb path."""

    def __init__(self, root: Path):
        self.root = root
        self.by_name: dict[str, Path] = {}
        for path in sorted(root.rglob("*.udeb")):
            name = path.name.split("_", 1)[0].lower()
            self.by_name[name] = path
            # Filename-derived names follow a convention, not a guarantee.
            # Cross-check against the Package: control field and fail loudly
            # rather than silently keying the pool wrong (which would corrupt
            # the whole dependency closure). Unreadable control is tolerated:
            # the caller's own dpkg-deb probe reports it.
            control = _dpkg_control(path, "Package").strip().lower()
            if control and control != name:
                raise SystemExit(
                    f"magnetar-substrate: {path.name} declares Package: "
                    f"{control!r} but is filed as {name!r}; the pool index "
                    f"would be wrong")

    def __contains__(self, name: str) -> bool:
        return name in self.by_name

    def keys(self):
        return self.by_name.keys()

    def udeb(self, name: str) -> Path:
        return self.by_name[name]


def _dpkg_control(path: Path, field: str) -> str:
    import subprocess

    out = subprocess.run(["dpkg-deb", "-f", str(path), field],
                         capture_output=True, text=True, check=False)
    return out.stdout.strip() if out.returncode == 0 else ""


def read_depends(pool: Pool) -> dict[str, list[str]]:
    """package -> set of dependency tokens (alternations flattened)."""
    deps: dict[str, list[str]] = {}
    for name in pool.keys():
        value = _dpkg_control(pool.udeb(name), "Depends")
        deps[name] = _parse_depends_field(value)
    return deps


def _initrd_status_packages(initrd: Path, work_dir: Path | None = None) -> set[str]:
    """Package names in the initrd's dpkg status (i.e. already unpacked).

    work_dir keeps the scratch extraction off tmpfs; callers in the build pass
    their own work directory.
    """
    import subprocess
    import tempfile

    with tempfile.TemporaryDirectory(prefix="ncz-initrd-status-",
                                     dir=work_dir) as tmp:
        raw: bytes
        data = initrd.read_bytes()
        if data[:2] == b"\x1f\x8b":
            raw = gzip.decompress(data)
        elif data[:6] == b"\xfd7zXZ\x00":
            raw = lzma.decompress(data)
        else:
            raw = data
        proc = subprocess.run(
            ["cpio", "-idm", "--quiet", "var/lib/dpkg/status", "debootstrap-debs"],
            cwd=tmp, input=raw, capture_output=True, check=False)
        status = Path(tmp) / "var/lib/dpkg/status"
        if not status.is_file():
            raise SystemExit(
                f"magnetar-substrate: {initrd} carries no var/lib/dpkg/status "
                "(cpio failed: "
                f"{proc.stderr.decode(errors='replace').strip()[:200]})")
        return {
            line.split(":", 1)[1].strip().lower()
            for line in status.read_text(errors="replace").splitlines()
            if line.startswith("Package:")
        }


def measure_substrate_initrd(status: Path) -> set[str]:
    """Package names already installed in the substrate initrd."""
    return {
        line.split(":", 1)[1].strip().lower()
        for line in status.read_text(errors="replace").splitlines()
        if line.startswith("Package:")
    }


def load_keep_tsv(path: Path) -> tuple[set[str], dict[str, str]]:
    """Extra keeps (name<TAB>reason) that are not derivable from the initrd."""
    keep: set[str] = set()
    reasons: dict[str, str] = {}
    if not path.is_file():
        return keep, reasons
    for line in path.read_text().splitlines():
        if not line.strip() or line.startswith("#"):
            continue
        if "\t" not in line:
            # A space-separated row would become one bogus package name and
            # quietly shrink the medium; the manifest is load-bearing.
            raise SystemExit(
                f"magnetar-substrate: {path}: expected name<TAB>reason, "
                f"got {line!r}")
        parts = line.split("\t")
        name = parts[0].strip().lower()
        if not name:
            continue
        if " " in name:
            raise SystemExit(
                f"magnetar-substrate: {path}: package name {name!r} has a "
                f"space (tab-separated rows, one package per line)")
        if name in keep:
            raise SystemExit(
                f"magnetar-substrate: {path} lists {name!r} twice")
        keep.add(name)
        reasons[name] = parts[1].strip() if len(parts) > 1 else ""
    return keep, reasons


def closure(
    wanted: set[str],
    pool: Pool,
    deps: dict[str, list[str]],
    initrd_builtin: set[str],
) -> tuple[set[str], dict[str, str]]:
    """Grow `wanted` by dependencies that are NOT already in the initrd.

    d-i's anna resolves dependencies against the initrd's dpkg status first and
    only falls back to the medium for packages that are missing. A dependency
    already unpacked in the initrd therefore needs no copy in the pool: it can
    satisfy no retrieval, and udpkg would skip it as already installed. Only
    dependencies that are genuinely absent from the initrd have to be kept.
    """
    kept = {n for n in wanted if n in pool}
    missing_from_pool = sorted(n for n in wanted if n not in pool)
    reasons: dict[str, str] = {}
    frontier = list(kept)
    seen: set[str] = set()
    while frontier:
        pkg = frontier.pop()
        if pkg in seen:
            continue
        seen.add(pkg)
        for token in deps.get(pkg, ()):
            name = package_name_of(token)
            if not name or name in seen:
                continue
            if name in initrd_builtin:
                reasons[name] = f"dependency of {pkg}; already unpacked in the initrd"
                continue
            if name not in pool:
                # virtual dependency (harddrive-detection, mounted-partitions,
                # configured-network, ...) provided by another udeb -- anna
                # resolves those against the status file, so nothing to stage.
                continue
            if name not in kept:
                kept.add(name)
                reasons[name] = f"dependency of {pkg}"
                frontier.append(name)
    for name in missing_from_pool:
        # A virtual package (provider chosen at runtime) is fine; a real one
        # that is absent is a build error the caller reports.
        reasons.setdefault(name, "absent from the pool (virtual or unproven)")
    return kept, reasons


def keep_set(pool: Pool, arch: str, flavour: str,
             initrd_builtin: set[str],
             extra_keep: set[str],
             extra_reasons: dict[str, str]) -> tuple[set[str], dict[str, str]]:
    """Minimal keep-set (initrd + NIC + runtime + manifest + closure).

    NOT used by the build: it assumes the initrd carries partman and
    base-installer, which re-measurement disproved. See slim_keep_set().
    """
    wanted: set[str] = set()
    reasons: dict[str, str] = {}
    for name in pool.keys():
        if name in initrd_builtin:
            wanted.add(name)
            reasons[name] = "unpacked into the d-i initrd itself (anna never fetches it)"
    for prefix in PRESEED_NIC_UDEBS:
        # Kernel-wedge package names are "<flavour>-modules-<kver>-<arch>-di".
        # Match the family at BOTH boundaries so nic-modules does not match
        # nic-wireless-modules, while still matching the bare pooled name.
        rx = re.compile(rf"^{re.escape(prefix)}(-\d[^ ]*)?$")
        for name in pool.keys():
            if not rx.match(name):
                continue
            wanted.add(name)
            reasons[name] = (
                f"preseed/early_command installs {prefix} by path (NIC "
                f"drivers); the initrd carries no drivers/net/*.ko")
    # udebs main-menu loads from the medium BEFORE the network exists, whose
    # absence from the initrd status is measured, not assumed.
    for name, why in RUNTIME_REQUIRED_UDEBS.items():
        if name not in pool:
            raise SystemExit(
                f"magnetar-substrate: refusing to ship a medium without "
                f"{name!r} ({why}): the pool at {pool.root} is not the "
                f"substrate this module was measured against")
        wanted.add(name)
        reasons[name] = f"runtime-required: {why}"
    for name in extra_keep:
        if name not in pool:
            raise SystemExit(
                f"magnetar-substrate: keep manifest lists {name!r}, which is "
                f"not in {pool.root} -- the manifest is stale and a stale "
                f"manifest is how an installer loses a component")
        wanted.add(name)
        reasons[name] = extra_reasons.get(name) or "listed in the keep manifest"
    deps = read_depends(pool)
    kept, dep_reasons = closure(wanted, pool, deps, initrd_builtin)
    for name, why in dep_reasons.items():
        reasons.setdefault(name, why)
    return kept, reasons


def provable_drop_reason(name: str, arch: str, flavour: str) -> str | None:
    """The reason a udeb can leave the medium, or None if none is proven.

    Only two classes qualify: components the preseed skips outright and
    filesystem module sets for filesystems the install never uses. Everything
    else stays, whatever the initrd holds: measured on the 2026-10-13 amd64
    substrate the netinst initrd carries 104 packages, and partman-*,
    base-installer, pkgsel, choose-mirror and finish-install are NOT among
    them -- anna loads them from /cdrom, so the pool must keep them.
    """
    if name in SKIPPED_COMPONENT_REASONS:
        return SKIPPED_COMPONENT_REASONS[name]
    if is_droppable_driver_udeb(name, arch, flavour):
        head = name.split("-modules-", 1)[0] + "-modules"
        return DROPPABLE_FS_MODULES[head.replace("_", "-")]
    return None


def slim_keep_set(pool: Pool, arch: str, flavour: str,
                  initrd_builtin: set[str],
                  extra_keep: set[str],
                  extra_reasons: dict[str, str]) -> tuple[set[str], dict[str, str]]:
    """Keep everything except provable drops, then re-add any provable drop
    that a kept udeb still Depends on. The initrd set only lets the closure
    skip dependencies d-i already has; it never removes a package."""
    for name in extra_keep:
        if name not in pool:
            raise SystemExit(
                f"magnetar-substrate: keep manifest lists {name!r}, which is "
                f"not in {pool.root} -- the manifest is stale")
    wanted: set[str] = set()
    reasons: dict[str, str] = {}
    for name in pool.keys():
        if name in extra_keep or provable_drop_reason(name, arch, flavour) is None:
            wanted.add(name)
            reasons[name] = extra_reasons.get(name) or "no proven drop reason"
    kept, dep_reasons = closure(wanted, pool, read_depends(pool), initrd_builtin)
    for name, why in dep_reasons.items():
        reasons.setdefault(name, why)
    return kept, reasons


def drop_reason(name: str, arch: str, flavour: str,
                initrd_builtin: set[str]) -> str:
    """Why a udeb the keep-set excluded can go."""
    if name in SKIPPED_COMPONENT_REASONS:
        return SKIPPED_COMPONENT_REASONS[name]
    if is_droppable_driver_udeb(name, arch, flavour):
        head = name.split("-modules-", 1)[0] + "-modules"
        return DROPPABLE_FS_MODULES[head.replace("_", "-")]
    if name in initrd_builtin:
        return "unpacked into the d-i initrd itself"
    return "not reachable from the preseed path (verify before shipping)"


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--installer-pool", type=Path, required=True)
    ap.add_argument("--arch", default=os.environ.get("NCZ_TARGET_ARCH", "amd64"))
    ap.add_argument("--flavour", default=None,
                    help="kernel-wedge flavour we boot (default: arch)")
    ap.add_argument("--initrd-status", type=Path,
                    help="path to the substrate initrd's var/lib/dpkg/status")
    ap.add_argument("--initrd", type=Path,
                    help="path to the substrate initrd (gz/xz cpio)")
    ap.add_argument("--keep-tsv", type=Path,
                    default=Path(__file__).resolve().parents[2]
                    / "manifests" / "magnetar-substrate-keep.tsv")
    ap.add_argument("--report", action="store_true",
                    help="print every kept/dropped package with its reason")
    args = ap.parse_args(argv)

    flavour = args.flavour or args.arch
    pool = Pool(args.installer_pool)
    if not pool.keys():
        raise SystemExit(f"magnetar-substrate: no udebs under {args.installer_pool}")
    if args.initrd_status:
        initrd_builtin = measure_substrate_initrd(args.initrd_status)
    elif args.initrd:
        initrd_builtin = _initrd_status_packages(args.initrd)
    else:
        raise SystemExit(
            "magnetar-substrate: --initrd or --initrd-status is required; the "
            "keep-set is MEASURED from d-i's own initrd, never assumed")
    extra, extra_reasons = load_keep_tsv(args.keep_tsv)
    kept, reasons = slim_keep_set(pool, args.arch, flavour, initrd_builtin,
                                  extra, extra_reasons)

    total = sum(pool.udeb(n).stat().st_size for n in pool.keys())
    kept_bytes = sum(pool.udeb(n).stat().st_size for n in kept)
    dropped = sorted(set(pool.keys()) - kept)
    dropped_bytes = total - kept_bytes
    print(f"[substrate] pool: {len(pool.keys())} udebs, {total} bytes",
          file=sys.stderr)
    print(f"[substrate] keep: {len(kept)} udebs, {kept_bytes} bytes "
          f"({kept_bytes * 100 // max(total, 1)}%)", file=sys.stderr)
    print(f"[substrate] drop: {len(dropped)} udebs, {dropped_bytes} bytes",
          file=sys.stderr)
    if args.report:
        for name in sorted(kept):
            print(f"KEEP\t{name}\t{reasons.get(name, '')}")
        for name in dropped:
            print(f"DROP\t{name}\t{provable_drop_reason(name, args.arch, flavour)}")
    for name in sorted(kept):
        print(name)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
