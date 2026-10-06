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

Output: <cache-root>/ncz-initrd-t2kernel/<node_key>/{linux,initrd.gz}
        + receipt.json
"""
from __future__ import annotations

import argparse
import gzip
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
DEFAULT_CACHE_ROOT = REPO_ROOT / "build" / "iso-cache" / "v1"

# Categories with no real use in a text-mode d-i bootstrap. Kept
# deliberately short -- when in doubt, keep the module; the overlay is
# appended, not baked into a firmware-size-limited image the way Sky1's
# is, so there is no real size pressure forcing aggressive pruning here.
PRUNE_MOD_DIRS = ["sound"]


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
    if preseed_cfg is not None and not preseed_cfg.is_file():
        raise RuntimeError(f"FATAL: preseed.cfg not found: {preseed_cfg}")

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

    canonical = canonical_encode({
        "schema_version": "ncz-initrd-t2kernel/v4",
        "arch": arch,
        "base_initrd": _stat(base_initrd),
        "kernel_deb": _stat(kernel_deb) if kernel_deb else {"present": False},
        "kernel_image": _stat(kernel_image) if kernel_image else {"present": False},
        "modules_tar": _stat(modules_tar) if modules_tar else {"present": False},
        "prune_mod_dirs": PRUNE_MOD_DIRS,
        "preseed_cfg": _stat(preseed_cfg) if preseed_cfg is not None else {"present": False},
        "helpers": {p.name: _stat(p) for p in helpers},
        "diag_busybox": _stat(diag_busybox) if diag_busybox is not None else {"present": False},
        "ssh_udebs": sorted(u.name for u in ssh_udebs),
    })
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
    if node_dir.exists() and not force:
        if (node_dir / "receipt.json").is_file():
            log(f"node exists: {node_dir}")
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
        if preseed_cfg is not None:
            shutil.copy2(preseed_cfg, overlay_root / "preseed.cfg")
            log(f"    baked {preseed_cfg} -> initrd root /preseed.cfg "
                f"({preseed_cfg.stat().st_size} bytes)")

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
            if preseed_cfg is not None:
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

        # Keep both CPIO archives in one gzip member. Concatenating the two
        # .gz files worked on amd64 but the Sky1 arm64 kernel stopped after
        # the first member, dropping /preseed.cfg and /ncz completely.
        out_initrd = build_dir / "initrd.gz"
        write_single_member_initrd(base_initrd, overlay_cpio_gz, out_initrd)

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
            "baked_preseed_cfg": str(preseed_cfg) if preseed_cfg else None,
            "baked_helpers": [h.name for h in helpers],
            "baked_diag_busybox": str(diag_busybox) if diag_busybox else None,
            "baked_ssh_udebs": [u.name for u in ssh_udebs],
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
    ap.add_argument("--preseed-cfg", type=Path,
                     default=REPO_ROOT / "preseed" / "preseed.cfg",
                     help="Baked into the initrd root as /preseed.cfg (d-i's "
                          "S30initrd-preseed auto-loads it with zero "
                          "device/mount dependency). Pass --preseed-cfg= "
                          "(empty) to skip.")
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
    args = ap.parse_args()
    preseed_cfg = args.preseed_cfg if str(args.preseed_cfg) else None
    if preseed_cfg is not None and not preseed_cfg.is_file():
        preseed_cfg = None
        log(f"WARNING: no preseed.cfg at {args.preseed_cfg} -- initrd will "
            f"NOT carry a baked-in preseed")

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
        )
    except RuntimeError as e:
        log(str(e))
        return 1
    print(f"{linux_out}\n{initrd_out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
