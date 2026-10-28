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
cixmini/192.168.207.66 with `lsinitramfs | grep -c npucre` = 0 and
`head -c6 initrd` = zstd magic, i.e. nothing prepended).

THE CONTRACT
------------
    ensure_npu_ssdt_aml(repo_root, arch)

is called by build/iso/write-usb-image.py -- the ONE place that stages
assets/* onto the medium -- for every arm64 image. It:

  1. reuses assets/npu/ssdt-npucre.aml when it is newer than the .asl and is
     a structurally valid SSDT;
  2. otherwise compiles the committed .asl with iasl, verifies the result
     (ACPI signature, length field, the three _HID strings) and stages it;
  3. RAISES if it cannot. A silent warning is exactly how two image releases
     went out without a working NPU, so the build must stop instead.

amd64 has no CIX NPU and is a no-op.
"""

from __future__ import annotations

import shutil
import struct
import subprocess
import tempfile
from pathlib import Path
from typing import Callable, Optional

AML_NAME = "ssdt-npucre.aml"
ASL_NAME = "ssdt-npucre.asl"
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
    log(f"    NPU SSDT compiled: {out_aml} "
        f"({out_aml.stat().st_size} bytes, {EXPECTED_CORES} CIXH4010 cores)")


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

    if not asl.is_file():
        raise RuntimeError(
            f"the committed NPU SSDT source is missing: {asl}\n"
            "  It is not a build artifact -- it is tracked in git. Restore it."
        )

    if aml.is_file() and aml.stat().st_size > 0:
        reason = _valid_aml(aml)
        stale = aml.stat().st_mtime < asl.stat().st_mtime
        if reason is None and not stale:
            log(f"    NPU SSDT staged: {aml} ({aml.stat().st_size} bytes)")
            return aml
        if reason is None and stale:
            log(f"    NPU SSDT out of date vs {ASL_NAME} -- recompiling")
        else:
            log(f"    NPU SSDT unusable ({reason}) -- recompiling")

    _compile(asl, aml, Path(repo_root), log)
    return aml
