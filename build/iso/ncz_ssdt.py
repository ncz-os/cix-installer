"""ncz_ssdt.py -- stage the NPU ACPI SSDT table into the build payload.

WHY THIS EXISTS (2026-10-28, MS-R1 release blocker)
---------------------------------------------------
The MS-R1 (Micro Computer, CIX P1 CP8180) shipped with a dead NPU:

    armchina CIXH4000:00: NPU core CRE0 has no platform device
        (firmware omits _HID; NPUCRE SSDT override not loaded)
    armchina CIXH4000:00: only 0 of 3 NPU cores usable - disabling NPU

The Radxa Orion O6N works because its firmware describes the NPU compute
cores itself (\\_SB_.NPU0.CRE0/1/2 carry Name(_HID, "CIXH4010")); the MS-R1
DSDT has the same three Device objects with the same _ADR/_PR0/_PR3 and power
resources, but no _HID -- so no platform device is created and the driver has
nothing to bind.

The fix is an ACPI SSDT that adds the missing _HID (assets/npu/
ssdt-npucre.asl). It ships, and the target-side machinery to deliver it into
the initrd as an uncompressed early CPIO is complete and unit-tested
(post-install/lib/npu-ssdt.sh, assets/initramfs/hooks/ncz-npu-ssdt,
assets/dracut/modules.d/91ncz-npu-ssdt, post-install/80-npu.sh).

WHAT WAS STILL BROKEN -- the gap this module closes
---------------------------------------------------
The COMPILED TABLE never existed in any real build. assets/ is a gitignored
blob dir holding only the .asl; build/build-npu-ssdt.sh can compile it, but
the only thing that ever called that script was
build/stage-canonical-assets.sh -- and nothing in the build pipeline invokes
stage-canonical-assets.sh at all. So every image shipped
assets/npu/ on the medium without ssdt-npucre.aml, and post-install/80-npu.sh
logged, on a real MS-R1 install:

    [80] WARN: /usr/local/lib/cix-installer/assets/npu/ssdt-npucre.aml missing
         -- the initramfs hook has nothing to inject and the NPU cores will
         NOT enumerate on this board.

and then built an initrd with zero kernel/firmware/acpi/ entries (verified on
the CIXMINI board with `lsinitramfs | grep -c npucre` = 0 and
`head -c6 initrd` = zstd magic, i.e. nothing prepended).

THE CONTRACT
------------
    ensure_npu_ssdt_aml(repo_root, arch)

is called by build/iso/write-usb-image.py -- the ONE place that stages
assets/* onto the medium -- for every arm64 image. It:

  1. reuses assets/npu/ssdt-npucre.aml when its stamp
     (ssdt-npucre.aml.asl-sha256) names the current .asl and it is a
     structurally valid SSDT (content, never file times);
  2. otherwise compiles the committed .asl with iasl, verifies the result
     (ACPI signature, length field, the three _HID strings) and stages it;
  3. RAISES if it cannot. A silent warning is exactly how two image releases
     went out without a working NPU, so the build must stop instead.

amd64 has no CIX NPU and is a no-op.
"""

from __future__ import annotations

import hashlib
import shutil
import struct
import subprocess
import tempfile
from pathlib import Path
from typing import Callable, Optional

AML_NAME = "ssdt-npucre.aml"
ASL_NAME = "ssdt-npucre.asl"
CPIO_NAME = "npu-acpi-override.cpio"
# Every NPU core must receive this _HID or the driver sees fewer than 3 cores
# and disables the NPU. Checked by count, not by presence, so a table that
# lost a Scope() cannot pass.
CORE_HID = b"CIXH4010"
EXPECTED_CORES = 3

Logger = Callable[[str], None]


def _log_default(msg: str) -> None:
    print(msg, flush=True)


def _valid_aml(path: Path) -> Optional[str]:
    """Return None when `path` is a usable SSDT, else a human-readable reason."""
    try:
        data = path.read_bytes()
    except OSError as exc:
        return f"unreadable: {exc}"
    if len(data) < 36:
        return f"too short ({len(data)} bytes)"
    sig = data[0:4]
    if sig != b"SSDT":
        return f"ACPI signature is {sig!r}, expected b'SSDT'"
    # Header length field (offset 4) must agree with the file, otherwise the
    # kernel installs a truncated/garbage table.
    (declared,) = struct.unpack_from("<I", data, 4)
    if declared != len(data):
        return f"header length {declared} != file length {len(data)}"
    cores = data.count(CORE_HID)
    if cores < EXPECTED_CORES:
        return (f"{CORE_HID.decode()} appears {cores}x, expected "
                f"{EXPECTED_CORES} (a Scope() is missing)")
    return None


def _compile(asl: Path, out_aml: Path, repo_root: Path, log: Logger) -> None:
    iasl = shutil.which("iasl")
    if not iasl:
        raise RuntimeError(
            "the MS-R1 NPU SSDT cannot be built: iasl is not installed.\n"
            f"  source: {asl}\n"
            "  Fix: apt-get install acpica-tools (it is present in the\n"
            "  ncz-imagebuild container; a bare build host may lack it).\n"
            "  Without this table the MS-R1 boots with 'only 0 of 3 NPU cores\n"
            "  usable - disabling NPU', so this is a hard build failure."
        )
    with tempfile.TemporaryDirectory(prefix="ncz-ssdt-") as td:
        work = Path(td)
        staged = work / ASL_NAME
        shutil.copyfile(asl, staged)
        # iasl derives the output name from -p; keep the table name identical
        # to the payload name so the target-side CPIO builder finds it.
        proc = subprocess.run(
            [iasl, "-p", str(work / AML_NAME[:-4]), str(staged)],
            cwd=str(work),
            capture_output=True,
            text=True,
        )
        built = work / AML_NAME
        if proc.returncode != 0 or not built.is_file():
            tail = (proc.stdout or "") + (proc.stderr or "")
            raise RuntimeError(
                "iasl failed to compile the NPU SSDT\n"
                f"  source: {asl}\n"
                f"  iasl rc={proc.returncode}\n"
                + "\n".join("  " + ln for ln in tail.strip().splitlines()[-15:])
            )
        reason = _valid_aml(built)
        if reason:
            raise RuntimeError(
                f"iasl produced an unusable NPU SSDT ({reason})\n  source: {asl}"
            )
        out_aml.parent.mkdir(parents=True, exist_ok=True)
        tmp_out = out_aml.with_suffix(out_aml.suffix + ".tmp")
        shutil.copyfile(built, tmp_out)
        tmp_out.chmod(0o644)
        tmp_out.replace(out_aml)
    _stamp_source(asl, out_aml)
    log(f"    NPU SSDT compiled: {out_aml} "
        f"({out_aml.stat().st_size} bytes, {EXPECTED_CORES} CIXH4010 cores)")


_CPIO_DIRS = ("kernel", "kernel/firmware", "kernel/firmware/acpi")
_CPIO_BLOCK = 512


def _newc_header(ino: int, mode: int, nlink: int, size: int, name: str) -> bytes:
    """One newc header + name, 4-byte aligned. 13 fields: c_ino comes first
    (measured 2026-11-07: leaving it out shifted every field, so readers saw
    an entry with an empty name and the shipped scan rejected the medium)."""
    namez = name.encode() + b"\0"
    fields = (ino, mode, 0, 0, nlink, 0, size, 0, 0, 0, 0, len(namez), 0)
    header = b"070701" + b"".join(b"%08X" % f for f in fields) + namez
    return header + b"\0" * ((-len(header)) % 4)


def early_cpio_bytes(aml_data: bytes) -> bytes:
    """The early CPIO, byte-identical to build/build-npu-ssdt.sh's GNU cpio
    archive (find kernel | sort | cpio -o -H newc --owner=0:0 --reproducible,
    every time pinned to 0): the three directories, the table, the trailer,
    padded to cpio's 512-byte block. Either producer gives the same medium."""
    out = b""
    for ino, d in enumerate(_CPIO_DIRS):
        out += _newc_header(ino, 0o40755, 2, 0, d)
    out += _newc_header(len(_CPIO_DIRS), 0o100644, 1, len(aml_data),
                        f"kernel/firmware/acpi/{AML_NAME}")
    out += aml_data + b"\0" * ((-len(aml_data)) % 4)
    out += _newc_header(0, 0, 1, 0, "TRAILER!!!")
    return out + b"\0" * ((-len(out)) % _CPIO_BLOCK)


def _write_early_cpio(aml: Path, cpio: Path, log: Logger) -> None:
    """Stage the install-time convenience archive the target copies to /boot.

    post-install/80-npu.sh installs this as /boot/npu-acpi-override.cpio for
    the post-update safety net. It does NOT deliver the override by itself
    (dracut's acpi_override builds the real early segment from
    /etc/ncz/npu-acpi); its only other consumer is a prepend fallback, which
    used to need cpio(1) -- absent on a lean NCZ rootfs (measured on cixmini).
    Building it here means the medium always carries one.
    """
    payload = early_cpio_bytes(aml.read_bytes())
    tmp = cpio.with_suffix(cpio.suffix + ".tmp")
    tmp.write_bytes(payload)
    tmp.chmod(0o644)
    tmp.replace(cpio)
    log(f"    NPU SSDT early CPIO staged: {cpio} ({len(payload)} bytes)")


def _stamp_path(aml: Path) -> Path:
    return aml.with_name(aml.name + ".asl-sha256")


def _asl_digest(asl: Path) -> str:
    return hashlib.sha256(asl.read_bytes()).hexdigest()


def _stamp_source(asl: Path, aml: Path) -> None:
    """Record which .asl the .aml was compiled from (content, not mtime)."""
    _stamp_path(aml).write_text(_asl_digest(asl) + "\n")


def _built_from(asl: Path, aml: Path) -> bool:
    try:
        return _stamp_path(aml).read_text().strip() == _asl_digest(asl)
    except OSError:
        return False


def ensure_npu_ssdt_aml(
    repo_root: Path,
    arch: str,
    log: Logger = _log_default,
) -> Optional[Path]:
    """Make sure assets/npu/ssdt-npucre.aml is staged for `arch`.

    Returns the .aml path, or None on an arch that has no CIX NPU (amd64).
    Raises RuntimeError when an arm64 image cannot be given the table.
    """
    if arch != "arm64":
        return None

    npu_dir = Path(repo_root) / "assets" / "npu"
    asl = npu_dir / ASL_NAME
    aml = npu_dir / AML_NAME
    cpio = npu_dir / CPIO_NAME

    if not asl.is_file():
        raise RuntimeError(
            f"the committed NPU SSDT source is missing: {asl}\n"
            "  It is not a build artifact -- it is tracked in git. Restore it."
        )

    # Reuse is decided by content, never by file times: a fresh clone's .asl
    # is newer than any copied .aml and a copied tree's is older, so an mtime
    # test made two builds of one commit stage different tables (measured
    # 2026-11-07). The .aml is reused only when its stamp names this .asl.
    if aml.is_file() and aml.stat().st_size > 0:
        reason = _valid_aml(aml)
        stale = not _built_from(asl, aml)
        if reason is None and not stale:
            log(f"    NPU SSDT staged: {aml} ({aml.stat().st_size} bytes)")
        else:
            if reason is None:
                log(f"    NPU SSDT out of date vs {ASL_NAME} -- recompiling")
            else:
                log(f"    NPU SSDT unusable ({reason}) -- recompiling")
            _compile(asl, aml, Path(repo_root), log)
    else:
        _compile(asl, aml, Path(repo_root), log)

    # The convenience archive must carry exactly this table, or a stale blob
    # would ship and the fallback would inject the wrong one. Compared by
    # content (an mtime test depended on how the tree was checked out).
    want = early_cpio_bytes(aml.read_bytes())
    if not cpio.is_file() or cpio.read_bytes() != want:
        _write_early_cpio(aml, cpio, log)
    else:
        log(f"    NPU SSDT early CPIO staged: {cpio} ({cpio.stat().st_size} bytes)")
    return aml
