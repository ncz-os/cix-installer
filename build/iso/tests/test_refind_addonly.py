"""test-refind-addonly: the zz1 postinst hook must stage/add the kernel
BEING INSTALLED ($1) -- side-by-side, never promote -- and must never
re-add a different kernel.

Regression fixture for the 2026-11-10 01:16Z hardware finding: installing
linux-image-7.4.0-rc2 printed KVER_STABLE=7.3.3-t2-ncz, staged nothing
for 7.4 and APPENDED A DUPLICATE 7.3.3 menuentry, because the hook
re-derived KVER_STABLE from a /boot mtime scan instead of using the
version dpkg was installing.
"""

import os
import subprocess
import textwrap
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[3]
ZZ1 = REPO / "assets" / "refind" / "zz1-ncz-refind-refresh-amd64"


def _make_boot(root: Path, versions) -> Path:
    boot = root / "boot"
    boot.mkdir()
    for ver, mtime in versions:
        for name in (f"vmlinuz-{ver}", f"initrd.img-{ver}"):
            p = boot / name
            p.write_bytes(b"x" * 4096)
            os.utime(p, (mtime, mtime))
    return boot


def _make_refresh(root: Path) -> Path:
    refresh = root / "ncz-refind-refresh-amd64"
    refresh.write_text(
        textwrap.dedent(
            """\
            #!/bin/bash
            {
              echo "VERB=${1:-}"
              echo "KVER_STABLE=${KVER_STABLE:-}"
              echo "SRC=${KVER_STABLE_SRC:-}"
              echo "INITRD=${KVER_STABLE_INITRD:-}"
            } >> "$NCZ_REFRESH_LOG"
            exit 0
            """
        )
    )
    refresh.chmod(0o755)
    return refresh


def _run_zz1(tmp_path, boot, refresh, arg=None):
    log = tmp_path / "refresh.log"
    env = dict(
        os.environ,
        BOOTDIR=str(boot),
        NCZ_REFIND_REFRESH=str(refresh),
        NCZ_REFRESH_LOG=str(log),
    )
    argv = [str(ZZ1)] + ([arg] if arg else [])
    return subprocess.run(argv, env=env, capture_output=True, text=True), log


def _read(log: Path) -> str:
    return log.read_text() if log.exists() else ""


def test_addonly_stages_the_installed_kernel_not_the_newest(tmp_path):
    """7.4 is being installed while 7.3.3 has the newer mtime in /boot:
    the hook must pass the 7.4 pair to --add and never mention 7.3.3."""
    boot = _make_boot(tmp_path, [("7.3.3-t2-ncz", 2000), ("7.4.0-rc2-t2-ncz", 1000)])
    refresh = _make_refresh(tmp_path)
    proc, log = _run_zz1(tmp_path, boot, refresh, arg="7.4.0-rc2-t2-ncz")
    assert proc.returncode == 0
    out = _read(log)
    assert "VERB=--add" in out
    assert "KVER_STABLE=7.4.0-rc2-t2-ncz" in out
    assert f"SRC={boot}/vmlinuz-7.4.0-rc2-t2-ncz" in out
    assert f"INITRD={boot}/initrd.img-7.4.0-rc2-t2-ncz" in out
    assert "7.3.3" not in out


def test_addonly_never_promotes_or_regenerates(tmp_path):
    boot = _make_boot(tmp_path, [("7.4.0-rc2-t2-ncz", 1000)])
    refresh = _make_refresh(tmp_path)
    proc, log = _run_zz1(tmp_path, boot, refresh, arg="7.4.0-rc2-t2-ncz")
    assert proc.returncode == 0
    out = _read(log)
    assert "--promote" not in out
    # exactly one invocation, and it is the --add verb (no no-verb regenerate)
    assert out.count("VERB=") == 1
    assert "VERB=--add" in out


def test_addonly_skips_non_ncz_kernel(tmp_path):
    """A Debian-archive kernel is never staged."""
    boot = _make_boot(tmp_path, [("7.1.0-2-amd64", 1000)])
    refresh = _make_refresh(tmp_path)
    proc, log = _run_zz1(tmp_path, boot, refresh, arg="7.1.0-2-amd64")
    assert proc.returncode == 0
    assert _read(log) == ""


def test_addonly_skips_when_initrd_missing(tmp_path):
    """Mid-transaction (no initrd yet): skip loudly, do not fabricate."""
    boot = tmp_path / "boot"
    boot.mkdir()
    (boot / "vmlinuz-7.4.0-rc2-t2-ncz").write_bytes(b"x" * 4096)
    refresh = _make_refresh(tmp_path)
    proc, log = _run_zz1(tmp_path, boot, refresh, arg="7.4.0-rc2-t2-ncz")
    assert proc.returncode == 0
    assert _read(log) == ""
    assert "mid-transaction" in proc.stderr


def test_fallback_scan_without_arg_picks_newest(tmp_path):
    """Trigger-style call with no $1 keeps the /boot scan fallback."""
    boot = _make_boot(tmp_path, [("7.3.3-t2-ncz", 2000), ("7.4.0-rc2-t2-ncz", 1000)])
    refresh = _make_refresh(tmp_path)
    proc, log = _run_zz1(tmp_path, boot, refresh, arg=None)
    assert proc.returncode == 0
    out = _read(log)
    assert "VERB=--add" in out
    assert "KVER_STABLE=7.3.3-t2-ncz" in out
