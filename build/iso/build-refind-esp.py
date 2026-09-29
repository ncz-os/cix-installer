#!/usr/bin/env python3
"""
build-refind-esp.py — Build a deterministic FAT ESP image carrying rEFInd,
the Debian Installer kernel + initrd, and an explicit refind.conf menu.

Layout produced (file paths inside the FAT ESP image):

    EFI/BOOT/BOOTX64.EFI                 (refind_x64.efi, renamed for fallback boot)
    EFI/BOOT/REFIND.CONF                 (explicit menu — no auto-scan reliance)
    EFI/BOOT/STARTUP.NSH                 (OVMF EFI Shell auto-launch hint)
    EFI/REFIND/REFIND-X64.EFI            (refind_x64.efi under arch-named path)
    EFI/REFIND/REFIND.CONF               (copy for the installed path)
    /linux                               (d-i kernel, embedded in the FAT image)
    /initrd.gz                           (d-i initrd, embedded in the FAT image)

The kernel + initrd live INSIDE this FAT image. rEFInd loads them via its
own EFI_SIMPLE_FILE_SYSTEM_PROTOCOL on the running volume — no ISO 9660
read is needed at boot, and no rEFInd filesystem driver has to bind the
optical disc. The ISO 9660 filesystem driver is NOT shipped from this
ESP, and no drivers_x64/ subdirectory is created here (see the long-form
comment in build_esp_dir for the rationale).

The d-i kernel and initrd are REQUIRED inputs. There is no fallback to
the ISO 9660 filesystem: a missing kernel or initrd is a fatal error
(see main()). Earlier revisions of this script emitted a refind.conf
with three enabled menu entries pointing at /linux and /initrd.gz
whether or not those files were present, and the rEFInd ISO 9660 driver
that would have allowed a fallback was deliberately removed. Shipping
a config that points at files that do not exist would let rEFInd boot
into a "loader not found" dead-end at runtime instead of failing the
build, which is exactly the kind of latent bug we want to catch at
compose time.

The ESP is built with mtools (mformat + mcopy): a flat file image,
deterministically populated from the rEFInd .deb payload. We omit the
``-F 32`` flag so mformat selects FAT12 / FAT16 based on the image
size, matching what Debian's own working netboot ISO does for a
similar-size El Torito EFI image.

Output: <out_dir>/esp.img  + <out_dir>/receipt.json
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess

# mtools prompts on stdin when it dislikes the FAT geometry it probes.
# A non-interactive build has nobody to answer, so mmd / mformat / mcopy
# block forever -- observed 2026-09-26 on both arches, stuck at
# "[5/6] building rEFInd ESP" at 0%% CPU with mmd hung in poll().
# Set it in os.environ so every mtools subprocess inherits it.
os.environ.setdefault("MTOOLS_SKIP_CHECK", "1")
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent


def _read_release_conf() -> dict:
    """Minimal KEY="value" reader for release.conf -- not a shell
    source (this script has no other shell dependency), just enough to
    pull the real product identity for the boot-menu info line."""
    path = REPO_ROOT / "release.conf"
    out = {}
    if not path.is_file():
        return out
    import re
    for m in re.finditer(r'^([A-Z_]+)="([^"]*)"', path.read_text(), re.MULTILINE):
        out[m.group(1)] = m.group(2)
    return out


def build_info_line(arch: str) -> str:
    """Real, dynamic 'what build is this' text for the installer's own
    boot menu -- product/version/codename from release.conf, the real
    kernel-line versions this ISO stages (from assets/kernel/<arch>-*/KVER,
    if present), and today's real date. Shown as a disabled (visible,
    non-bootable) rEFInd menu entry since rEFInd has no header/footer
    text area outside of banners -- see build-refind-esp.py's own
    docstring for why textonly (no banner) is used here."""
    import datetime
    rel = _read_release_conf()
    product = rel.get("NCZ_PRODUCT_NAME", "NCZ-OS")
    version = rel.get("NCZ_RELEASE_VERSION", "")
    codename = rel.get("NCZ_RELEASE_CODENAME", "")
    build_date = datetime.date.today().isoformat()

    kver_bits = []
    for line in ("stable", "edge"):
        kver_path = REPO_ROOT / "assets" / "kernel" / f"{arch}-{line}" / "KVER"
        if kver_path.is_file():
            kver_bits.append(f"{line} {kver_path.read_text().strip()}")
    kver_text = " / ".join(kver_bits) if kver_bits else "kernel line unknown"

    ident = f"{product} {version} {codename}".strip()
    return f"{ident} -- built {build_date} -- {kver_text}"


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def find_refind_extract(arch: str) -> Path:
    """Locate the extracted rEFInd .deb payload.

    amd64 -> prototype/work/refind-ar/refind-extract/usr/share/refind/refind
    arm64 -> prototype/work/refind-arm-ar/refind-extract/usr/share/refind/refind
    """
    if arch == "amd64":
        base = REPO_ROOT / "prototype" / "work" / "refind-ar" / "refind-extract" / "usr" / "share" / "refind" / "refind"
    elif arch == "arm64":
        base = REPO_ROOT / "prototype" / "work" / "refind-arm-ar" / "refind-extract" / "usr" / "share" / "refind" / "refind"
    else:
        raise ValueError(f"unsupported arch: {arch}")
    if not base.is_dir():
        # The tracked runtime rEFInd tree is already the source of truth used
        # by post-install/70-bootloader.sh on both architectures.  Requiring a
        # developer's untracked prototype/work extraction made the nominal
        # arm64 path impossible on a clean checkout even though the required
        # binary, icons and artwork were all committed.
        tracked = REPO_ROOT / "assets" / "refind"
        efi = tracked / ("refind_x64.efi" if arch == "amd64" else "refind_aa64.efi")
        if efi.is_file() and (tracked / "icons").is_dir():
            return tracked
        raise FileNotFoundError(
            f"rEFInd extract not found at {base}, and tracked fallback {tracked} "
            f"does not contain {efi.name} plus icons/"
        )
    return base


# Match the old builder's unattended DI_OPTS for the normal Install entry.
# auto=true makes d-i apply the preseed at the auto-install point, after
# networking is configured, instead of allowing choose-mirror to race DHCP's
# resolv.conf update.  The preseed early_command mounts the raw-GPT ext4 data
# partition at /cdrom after USB rescan, before cdrom-detect runs; that makes the
# explicit medium path valid on this hd-media layout too.  Expert remains the
# human/on-screen path (the old DI_OPTS_GFX): it deliberately omits auto=true
# because d-i's single-console preseeding path can select a firmware UART and
# make the installer disappear from the local display.  Rescue is not an
# automatic/preseeded install either.
AMD64_INSTALL_OPTIONS = (
    "auto=true priority=critical preseed/file=/cdrom/ncz-payload/preseed.cfg "
    "ipv6.disable=1 interface=auto "
    "netcfg/dhcp_timeout=120 locale=en_US.UTF-8 "
    "keyboard-configuration/layoutcode=us DEBIAN_FRONTEND=newt "
    "quiet loglevel=3 vt.global_cursor_default=0 consoleblank=0 console=tty0"
)
AMD64_EXPERT_OPTIONS = (
    "priority=low ipv6.disable=1 interface=auto netcfg/dhcp_timeout=120 "
    "DEBIAN_FRONTEND=newt loglevel=4 vt.global_cursor_default=0 consoleblank=0 console=tty0"
)
AMD64_RESCUE_OPTIONS = (
    "rescue/enable=true ipv6.disable=1 interface=auto netcfg/dhcp_timeout=120 "
    "DEBIAN_FRONTEND=newt console=ttyS0,115200n8 console=tty0"
)

# The on-screen arm64 entries offer NO serial console at all.  Root-caused
# live on real O6N hardware via SSH into a broken boot (see the commit
# message): reopen-console enters its single-console preseeding path because
# "interface=auto" matches its own grep -qw auto /proc/cmdline test -- removing
# auto=true does NOT disable it -- and in that path it picks the console
# carrying the kernel C (CON_CONSDEV) flag.  On Sky1 the PL011 registers at
# ~0.9s, after tty0 at ~0.0001s, and the later registration takes CON_CONSDEV,
# so console= ORDER cannot change the outcome.  reopen-console then writes a
# single inittab entry for that UART and d-i never appears on the monitor.
# Offering no serial here leaves no device carrying C, so reopen-console falls
# through to its [ -c /dev/tty1 ] fallback and picks tty1 -- the screen.
# This is exactly why the pre-rEFInd GRUB ISOs worked: they named ttyAMA2,
# which does not exist on O6N, so no serial console ever registered.
# Serial tracing remains available on the Rescue entry and via diag-console.
SKY1_GFX_OPTIONS = (
    "console=tty0 efi=noruntime acpi=force "
    "arm-smmu-v3.disable_bypass=0 audit_backlog_limit=8192 clk_ignore_unused "
    "panic=30 nmi_watchdog=0 module_blacklist=typec_rts5453,rts5453,linlon_dp,trilin_dpsub"
)
# linlon_dp / trilin_dpsub are the Sky1 display-controller DRM drivers. The installer
# kernel has no simpledrm (CONFIG_DRM_SIMPLEDRM is not set) and draws on the firmware
# framebuffer (CONFIG_FB_EFI=y). Loading these modules mid-install (udev coldplug of the
# ACPI device CIXH50C0, or hw-detect after anna adds components) makes DRM take the
# display away from efifb: the panel is re-modeset and fbcon re-attaches, i.e. the screen
# goes blank and d-i is redrawn. The installer needs no accelerated display, so keep the
# firmware framebuffer for the whole install; the installed system's own boot entries
# (70-bootloader.sh) are unaffected and load them normally.
ARM64_INSTALL_OPTIONS = AMD64_INSTALL_OPTIONS.rsplit(" console=tty0", 1)[0] + " " + SKY1_GFX_OPTIONS
ARM64_EXPERT_OPTIONS = AMD64_EXPERT_OPTIONS.rsplit(" console=tty0", 1)[0] + " " + SKY1_GFX_OPTIONS
ARM64_RESCUE_OPTIONS = (
    "rescue/enable=true ipv6.disable=1 interface=auto netcfg/dhcp_timeout=120 "
    "DEBIAN_FRONTEND=newt consoleblank=0 console=tty0 console=ttyAMA0,115200 "
    "efi=noruntime acpi=force arm-smmu-v3.disable_bypass=0 "
    "audit_backlog_limit=8192 clk_ignore_unused keep_bootcon panic=30 "
    "nmi_watchdog=0 module_blacklist=typec_rts5453,rts5453"
)


REFIND_CONF_TEXT_TEMPLATE = """\
#
# refind.conf -- generated by build/iso/build-refind-esp.py
#
# Every entry is explicit; we do NOT rely on rEFInd's auto-scan because
# auto-scan would have rEFInd enumerate ISO 9660 contents, and on this
# image rEFInd has no ISO 9660 driver loaded (see build_esp_dir() for
# why). The loader/initrd paths below point at files INSIDE THIS FAT
# ESP IMAGE -- not at the ISO 9660 filesystem.
#
# Why no rEFInd filesystem driver is shipped from the El Torito ESP:
#
# On the real OVMF/qemu boot chain used to qualify this layout, loading
# the rEFInd ISO 9660 driver from the FAT El Torito boot image
# reproducibly caused a "Load Error while (re)opening our installation
# volume" failure at boot, dropping the operator to the EFI Internal
# Shell without ever reaching the kernel. The reproducible observation
# is the failure mode with the ISO 9660 driver specifically; we have
# not independently verified any other rEFInd filesystem driver (ext4,
# XFS, NTFS, HFS+, ...) on this image, so we do not claim that
# "BlockIo-claiming drivers in general" cause the failure -- just that
# the ISO 9660 driver did, and we did not test the others. The
# mitigation we observed to work on real OVMF is the same either way:
# do not ship any driver from this ESP, and put the kernel + initrd
# inside the FAT image so rEFInd reads them via its own SFS handle.
# rEFInd can still auto-load drivers from a drivers_x64/ directory
# under EFI/REFIND/ at install time on real hardware; we simply do not
# ship that directory here.
#
# timeout 3: 3s before default boot (graphical install) if no key press.
# scanfor manual: ignore auto-scanned disks; use only the explicit entries.
# textonly: keep output compatible with serial consoles and QEMU's default
#           headless mode -- graphical banners add boot time we don't need.
#

timeout 3
textonly
scanfor manual

menuentry "{info_line}" {{
    disabled
}}

menuentry "NCZ-OS Installer -- Install" {{
    loader /linux
    initrd /initrd.gz
    options "{install_options}"
}}

menuentry "NCZ-OS Installer -- Install (expert)" {{
    loader /linux
    initrd /initrd.gz
    options "{expert_options}"
}}

menuentry "NCZ-OS Installer -- Rescue mode" {{
    loader /linux
    initrd /initrd.gz
    options "{rescue_options}"
}}

menuentry "NCZ-OS Installer -- Reinstall (preserve installed system)" {{
    disabled
}}
"""


# arm64 netboot: same layout as amd64, EXCEPT the serial console. Sky1
# real hardware (O6N) exposes its debug UART as ttyAMA0 (PL011), not the
# 8250-style ttyS0 that amd64/T2 hardware uses -- confirmed both by the
# working post-install rEFInd generator (assets/refind/ncz-refind-refresh.sh,
# which already correctly emits console=ttyAMA0,115200 for arm64) and by a
# real O6N boot test on 2026-09-25: REFIND_CONF_TEXT_ARM64_TEMPLATE used to
# be a bare alias of the amd64 template (console=ttyS0,115200n8), so ttyS0
# never bound as a console on real Sky1 hardware -- the kernel booted fine
# (confirmed live on the local/HDMI console: real xHCI/PCIe/Sky1 hardware
# enumeration, netconsole started) but every byte of it silently went only
# to tty0, since ttyS0 doesn't exist on this board. The serial capture
# looked exactly like a hang/wedge until the local display was checked.
REFIND_CONF_TEXT_ARM64_TEMPLATE = REFIND_CONF_TEXT_TEMPLATE


# amd64 full-netinst: same layout as amd64 netboot. The d-i kernel and
# initrd surface at /linux and /initrd.gz in the ESP either way.
REFIND_CONF_TEXT_AMD64_FULL_TEMPLATE = REFIND_CONF_TEXT_TEMPLATE


# OVMF's startup.nsh. When the firmware boots the EFI Internal Shell from
# the OVMF volume, it auto-runs startup.nsh if found on the boot device.
# We put one in EFI/BOOT/ so OVMF reads it and launches rEFInd. This
# also makes the image qualify under a stricter firmware that does not
# present "EFI Internal Shell" as the default — rEFInd's own loader will
# take over once it runs.
STARTUP_NSH = """\\
@echo -off
\\EFI\\BOOT\\bootx64.efi
\\EFI\\BOOT\\bootaa64.efi
"""


def build_esp_dir(esp_root: Path, refind_src: Path, arch: str,
                   d_i_kernel: Path, d_i_initrd: Path, info_line: str) -> dict:
    """Materialize the EFI/ tree inside esp_root/, with the d-i kernel +
    initrd embedded at the FAT image root (/linux, /initrd.gz). The kernel
    and initrd are REQUIRED: we never want a refind.conf pointing at files
    that don't exist (the prior fallback-to-ISO9660 story is gone; this
    ESP no longer ships a filesystem driver, so a missing /linux or
    /initrd.gz would surface as a silent boot failure at runtime).

    Returns a dict of file inventory (relative paths) for the receipt.
    """
    if not d_i_kernel.is_file():
        raise FileNotFoundError(
            f"required d-i kernel is missing or not a file: {d_i_kernel}"
        )
    if not d_i_initrd.is_file():
        raise FileNotFoundError(
            f"required d-i initrd is missing or not a file: {d_i_initrd}"
        )

    if esp_root.exists():
        shutil.rmtree(esp_root)
    esp_root.mkdir(parents=True)

    if arch == "amd64":
        efi_arch = "x64"
        # rEFInd binary name. Use the same lower-case name as upstream's
        # refind-cd-<ver>.iso: ``bootx64.efi``. EFI specifies case-insensitive
        # matching but matching upstream removes one class of edge cases with
        # strict firmwares and matches what an operator already expects.
        boot_loader = "bootx64.efi"
        refind_loader = "refind_x64.efi"
        conf_text = REFIND_CONF_TEXT_TEMPLATE.format(
            info_line=info_line,
            install_options=AMD64_INSTALL_OPTIONS,
            expert_options=AMD64_EXPERT_OPTIONS,
            rescue_options=AMD64_RESCUE_OPTIONS,
        )
        conf_basename = "refind.conf"
    else:  # arm64
        efi_arch = "aa64"
        boot_loader = "bootaa64.efi"
        refind_loader = "refind_aa64.efi"
        conf_text = REFIND_CONF_TEXT_ARM64_TEMPLATE.format(
            info_line=info_line,
            install_options=ARM64_INSTALL_OPTIONS,
            expert_options=ARM64_EXPERT_OPTIONS,
            rescue_options=ARM64_RESCUE_OPTIONS,
        )
        conf_basename = "refind.conf"

    # Locate source files in the extracted .deb
    refind_efi_src = refind_src / f"refind_{efi_arch}.efi"

    if not refind_efi_src.is_file():
        raise FileNotFoundError(f"missing rEFInd EFI binary: {refind_efi_src}")

    boot_dir = esp_root / "EFI" / "BOOT"
    boot_dir.mkdir(parents=True)
    shutil.copy2(str(refind_efi_src), str(boot_dir / boot_loader))

    # Place refind's arch-named binary under EFI/REFIND/ for tools that
    # look there (e.g. `refind-install`, recovery flows).
    refind_dir = esp_root / "EFI" / "REFIND"
    refind_dir.mkdir()
    shutil.copy2(str(refind_efi_src), str(refind_dir / refind_loader))

    # Why we do NOT install a drivers_x64/ (or drivers_aa64/) subdirectory
    # in this El Torito boot layout:
    #
    # On the real OVMF/qemu boot chain used to qualify this layout, the
    # rEFInd ISO 9660 driver reproducibly caused a "Load Error while
    # (re)opening our installation volume" failure at boot, dropping the
    # operator to the EFI Internal Shell without ever reaching the
    # kernel. The reproducible observation is the failure mode with the
    # ISO 9660 driver specifically; we did not test other rEFInd
    # filesystem drivers (ext4, XFS, NTFS, HFS+, ...) so we do not
    # generalize the failure to "any BlockIo-claiming driver". The
    # mitigation that we observed to work on real OVMF is to not ship
    # any driver from this ESP and put the kernel + initrd inside the
    # FAT image so rEFInd reads them via its own
    # EFI_SIMPLE_FILE_SYSTEM_PROTOCOL. rEFInd can still auto-load
    # drivers from a drivers_x64/ directory under EFI/REFIND/ at install
    # time on real hardware; we simply do not ship that directory here.

    # Place refind.conf NEXT TO the running binary. rEFInd's
    # CONFIG_FILE_NAME ("refind.conf", case-insensitive on FAT) is
    # resolved relative to SelfDir -- the directory containing the
    # current rEFInd binary. When launched as EFI/BOOT/BOOTX64.EFI
    # (the El Torito fallback boot path), SelfDir is EFI/BOOT/. Putting
    # refind.conf only at EFI/REFIND/REFIND.CONF (the install path) is
    # incorrect for the El Torito boot and produces the message
    # "Configuration file 'refind.conf' missing!" at startup, followed
    # by rEFInd continuing with only its built-in tools menu. We write
    # the file at BOTH EFI/BOOT/ (correct for the fallback boot) AND
    # EFI/REFIND/ (correct for the installed path) so the same image
    # works in both contexts.
    (boot_dir / conf_basename).write_text(conf_text)
    (refind_dir / conf_basename.upper()).write_text(conf_text)

    # Place startup.nsh in EFI/BOOT so OVMF's "EFI Internal Shell" launches
    # rEFInd on first boot (a strict firmware without rEFInd written into
    # NVRAM boot entries needs an explicit launch).
    (boot_dir / "startup.nsh").write_text(STARTUP_NSH)

    # Place d-i payload (kernel + initrd) at the FAT image root. Loaded
    # via rEFInd's own EFI Simple File System protocol on the running
    # volume; no filesystem driver involved.
    shutil.copy2(str(d_i_kernel), str(esp_root / "linux"))
    shutil.copy2(str(d_i_initrd), str(esp_root / "initrd.gz"))
    payload_files = ["linux", "initrd.gz"]

    # mcopy copies modes 0644 by default but we chmod anyway for determinism.
    for root, dirs, files in os.walk(esp_root):
        for d in dirs:
            os.chmod(Path(root) / d, 0o755)
        for f in files:
            os.chmod(Path(root) / f, 0o644)

    inventory = sorted(
        str(p.relative_to(esp_root)) for p in esp_root.rglob("*") if p.is_file()
    )
    return {"inventory": inventory, "d_i_payload_files": payload_files}


def _required_esp_mib(esp_root: Path, requested_mib: int) -> int:
    """Grow the ESP so its contents fit, treating requested_mib as a floor.

    The size was a fixed --size-mib from the caller. When the amd64 d-i
    initrd reached 246.9 MiB the 256 MiB image overflowed and mcopy failed
    with "Disk full" (2026-09-26). A larger constant only defers that.

    FAT needs room past the payload for reserved sectors, both FAT copies
    and per-file cluster slack, and mformat picks the cluster size from the
    image size. 15% plus an 8 MiB floor covers that at the sizes we ship.
    """
    total = sum(f.stat().st_size for f in esp_root.rglob("*") if f.is_file())
    needed_bytes = int(total * 1.15) + 8 * 1024 * 1024
    needed_mib = -(-needed_bytes // (1024 * 1024))  # ceil
    return max(requested_mib, needed_mib)


def make_fat_image_mtools(esp_root: Path, out_img: Path, size_mib: int = 4) -> dict:
    """Build a FAT image using mtools (mformat + mcopy). mtools is the
    portable, deterministic path: it writes a flat file directly and supports
    8.3 only (which is fine for our small file set).

    FAT type selection: we deliberately do NOT pass ``-F 32`` to mformat.
    With ``-F 32`` mformat forces FAT32, but FAT32's spec minimum size is
    ~32 MiB and a 4 MiB ``-F 32`` image was observed to fail to enumerate
    any bootable entry on real OVMF (BdsDxe "failed to load Boot0002 ...
    Not Found"). Without ``-F``, mformat picks FAT12 / FAT16 / FAT32
    based on the image size and matches what Debian's own working netboot
    ISO does for a similar-size El Torito EFI image (``file(1)`` reports
    ``FAT (12 bit)`` on their /boot/grub/efi.img).

    The ``-i`` option is required on macOS (and accepted everywhere) to
    point mtools at a flat image file instead of a drive letter."""
    mformat = shutil.which("mformat")
    mcopy = shutil.which("mcopy")
    mmd = shutil.which("mmd")
    if not (mformat and mcopy and mmd):
        raise RuntimeError("mtools (mformat/mcopy/mmd) is required on PATH")

    size_mib = _required_esp_mib(esp_root, size_mib)

    out_img.parent.mkdir(parents=True, exist_ok=True)
    if out_img.exists():
        out_img.unlink()

    # Create the flat image file
    with out_img.open("wb") as f:
        f.truncate(size_mib * 1024 * 1024)

    # Format with the selected FAT type (FAT12/16/32 chosen by mformat
    # based on image size; see docstring for why we do not force FAT32)
    # and a fixed-volume label. mformat derives the geometry from the
    # file size and picks FAT32 only when the image is large enough;
    # smaller images get FAT12 or FAT16, which is what we want for a
    # 64 MiB ESP carrying the kernel + initrd. We pin a numeric serial
    # (4 bytes) so the formatted image is reproducible.
    serial = "0x4bcd8d9c"
    subprocess.run([
        mformat,
        "-i", str(out_img),   # image file (replaces the positional device arg)
        "-v", "REFIND",       # volume label
        "-N", serial,         # serial number (stable)
    ], check=True)

    # Recursive copy. mtools' -s flag preserves modes but does NOT
    # auto-create parent directories. Walk the source tree and copy file
    # by file, creating each parent directory with mmd. We pin the file
    # copy order (sorted by path) so the image is reproducible.
    for src_file in sorted(esp_root.rglob("*")):
        if not src_file.is_file():
            continue
        rel = src_file.relative_to(esp_root).as_posix()
        # Build the parent directory path with leading slash.
        parent_parts = src_file.relative_to(esp_root).parent.parts
        # Create each parent directory level if missing.
        cur = ""
        for part in parent_parts:
            cur = f"{cur}/{part}"
            # Repeated parents are expected while walking multiple files.
            # mmd prompts on /dev/tty for an existing directory unless its
            # primary-name clash policy is explicit; -D s makes that case a
            # non-interactive skip (exit 2, intentionally ignored here).
            subprocess.run([mmd, "-D", "s", "-i", str(out_img), f"::{cur}"],
                           check=False, capture_output=True)
        subprocess.run([
            mcopy, "-i", str(out_img), "-pQ",
            str(src_file), f"::{rel}",
        ], check=True)

    return {
        "tool": "mtools",
        "tool_version": subprocess.check_output(["mformat", "-V"], text=True).strip(),
        "image": str(out_img),
        "size_bytes": out_img.stat().st_size,
        "serial": serial,
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--arch", required=True, choices=["amd64", "arm64"])
    ap.add_argument("--out-dir", required=True, type=Path)
    ap.add_argument("--size-mib", type=int, default=64,
                    help="ESP image size in MiB (default 64; must be large "
                         "enough for the d-i kernel + initrd)")
    ap.add_argument("--keep-tree", action="store_true",
                    help="keep the intermediate EFI/ tree on disk")
    ap.add_argument("--d-i-kernel", required=True, type=Path,
                    help="path to a d-i kernel (linux) image; REQUIRED "
                         "(embedded in the FAT ESP so rEFInd reads it via "
                         "its own SFS protocol)")
    ap.add_argument("--d-i-initrd", required=True, type=Path,
                    help="path to a d-i initrd (initrd.gz) image; REQUIRED "
                         "(embedded in the FAT ESP so rEFInd reads it via "
                         "its own SFS protocol)")
    args = ap.parse_args()

    refind_src = find_refind_extract(args.arch)
    esp_root = args.out_dir / "esp-tree"
    info_line = build_info_line(args.arch)
    build_info = build_esp_dir(
        esp_root,
        refind_src,
        args.arch,
        d_i_kernel=args.d_i_kernel,
        d_i_initrd=args.d_i_initrd,
        info_line=info_line,
    )

    esp_img = args.out_dir / "esp.img"
    info = make_fat_image_mtools(esp_root, esp_img, args.size_mib)

    esp_img_sha = sha256_file(esp_img)
    esp_img_size = esp_img.stat().st_size

    refind_efi_path = refind_src / ("refind_x64.efi" if args.arch == "amd64" else "refind_aa64.efi")

    payload_sha = {
        "linux_sha256": sha256_file(args.d_i_kernel),
        "linux_size_bytes": args.d_i_kernel.stat().st_size,
        "initrd_sha256": sha256_file(args.d_i_initrd),
        "initrd_size_bytes": args.d_i_initrd.stat().st_size,
    }

    receipt = {
        "schema_version": "esp-receipt/v1",
        "arch": args.arch,
        "esp_image": str(esp_img.relative_to(args.out_dir)),
        "esp_image_sha256": esp_img_sha,
        "esp_image_size_bytes": esp_img_size,
        "build_tool": info,
        "refind_efi_sha256": sha256_file(refind_efi_path),
        "esp_tree_inventory": build_info["inventory"],
        "d_i_payload_in_esp": build_info["d_i_payload_files"],
        "d_i_payload": payload_sha,
    }
    (args.out_dir / "receipt.json").write_text(json.dumps(receipt, indent=2, sort_keys=True))
    print(f"ESP image: {esp_img}")
    print(f"  sha256:  {esp_img_sha}")
    print(f"  size:    {esp_img_size} bytes ({esp_img_size / 1024 / 1024:.2f} MiB)")
    print(f"  build:   {info['tool']} ({info.get('tool_version', '')})")
    print(f"  d-i payload embedded: {build_info['d_i_payload_files']}")

    if not args.keep_tree:
        shutil.rmtree(esp_root)
    return 0


if __name__ == "__main__":
    sys.exit(main())
