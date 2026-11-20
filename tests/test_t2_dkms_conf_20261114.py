"""Regression guard for the T2 DKMS identities after the 8c7f725 re-vendor.

History: the vendor-refresh r2 tip (8fb73388) shipped two defects:
1. assets/kernel/t2smc/dkms.conf dropped all five hardening PATCH[0..4]
   entries without re-vendoring the source, so DKMS would build unpatched.
2. assets/kernel/t2gmux/dkms.conf bumped PACKAGE_VERSION 0.8 -> 0.9 with
   no source change (misleading identity).

Current state (re-vendor from KaiT2en-Fedora 8c7f725, 2026-11-14):
- t2gmux source is upstream 0.9 (MODULE_VERSION "0.9"), so the DKMS
  PACKAGE_VERSION follows it; the guard is that the two agree.
- t2smc keeps three hardening patches (0001, 0003, 0005).  0002 (temperature
  discovery) and 0004 (charge limit) were dropped because upstream contains
  those fixes (see assets/kernel/t2smc/PROVENANCE); the numbering gap is
  intentional.  Every PATCH[] entry must name an existing file and every
  file in patches/ must be listed, so a patch can neither go unlisted (DKMS
  would build unpatched) nor be listed but absent.
"""

from __future__ import annotations

import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parents[1]
T2SMC_DIR = ROOT / "assets/kernel/t2smc"
T2GMUX_DIR = ROOT / "assets/kernel/t2gmux"

EXPECTED_T2SMC_PATCHES = [
    "0001-t2smc-range-checks.patch",
    "0003-t2smc-cache-init.patch",
    "0005-t2smc-telemetry-robust.patch",
]
EXPECTED_T2GMUX_PATCHES = [
    "0001-t2gmux-bounded-drain.patch",
    "0002-t2gmux-pm-quiesce.patch",
    "0003-t2gmux-error-recording.patch",
]


def _patch_entries(text: str) -> dict[int, str]:
    return {
        int(m.group(1)): m.group(2)
        for m in re.finditer(r'^PATCH\[(\d+)\]="([^"]+)"', text, re.MULTILINE)
    }


def _check_module(moddir: pathlib.Path, expected: list[str]) -> None:
    entries = _patch_entries((moddir / "dkms.conf").read_text())
    assert [entries.get(i) for i in range(len(expected))] == expected, (
        f"{moddir.name}: PATCH[] entries are {entries}, expected {expected}"
    )
    assert len(entries) == len(expected), f"{moddir.name}: extra PATCH[] entries"
    on_disk = sorted(p.name for p in (moddir / "patches").glob("*.patch"))
    assert on_disk == sorted(expected), (
        f"{moddir.name}: patches/ holds {on_disk}, dkms.conf lists {expected}"
    )


def test_t2smc_dkms_conf_lists_the_kept_hardening_patches():
    _check_module(T2SMC_DIR, EXPECTED_T2SMC_PATCHES)


def test_t2gmux_dkms_conf_lists_the_hardening_patches():
    _check_module(T2GMUX_DIR, EXPECTED_T2GMUX_PATCHES)


def test_t2gmux_dkms_conf_version_matches_vendored_source_identity():
    text = (T2GMUX_DIR / "dkms.conf").read_text()
    m = re.search(r'^PACKAGE_VERSION="([^"]+)"', text, re.MULTILINE)
    assert m is not None, "PACKAGE_VERSION missing from t2gmux dkms.conf"
    src = (T2GMUX_DIR / "src/t2gmux.c").read_text()
    mv = re.search(r'^MODULE_VERSION\("([^"]+)"\);', src, re.MULTILINE)
    assert mv is not None, "MODULE_VERSION missing from vendored t2gmux.c"
    assert m.group(1) == mv.group(1), (
        f"t2gmux PACKAGE_VERSION {m.group(1)!r} does not match the vendored "
        f"source MODULE_VERSION {mv.group(1)!r}"
    )
