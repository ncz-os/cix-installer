#!/usr/bin/env python3
"""verify-overlays.py — verify every accelerator overlay .ko has vermagic
matching its directory KVER, and print a per-(overlay,kver) summary.

Used during the 7.2.7 + 7.3.0-rc4 overlay port (2026-09-22) to give a
pass/fail rollup across all 4 accelerator dirs and all per-kver subdirs.
"""
import os, sys, glob, importlib.util
spec = importlib.util.spec_from_file_location(
    "kernel_manifest",
    os.path.join(os.path.dirname(__file__), "kernel-manifest.py"))
_km = importlib.util.module_from_spec(spec)
sys.modules["kernel_manifest"] = _km
spec.loader.exec_module(_km)
modinfo_vermagic = _km.modinfo_vermagic

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
OVERLAYS = ["assets/kernel/mali", "assets/kernel/vpu",
            "assets/kernel/npu", "assets/kernel/panthor"]

errors = []
checked_modules = 0
checked_dirs = 0

for overdir in OVERLAYS:
    base = os.path.join(ROOT, overdir)
    if not os.path.isdir(base):
        print(f"MISSING_DIR: {overdir}")
        errors.append(overdir)
        continue
    for kver in sorted(os.listdir(base)):
        if kver in ("patches", "src"):
            continue
        d = os.path.join(base, kver)
        if not os.path.isdir(d):
            continue
        checked_dirs += 1
        kos = sorted(glob.glob(os.path.join(d, "*.ko")))
        if not kos:
            continue
        for ko in kos:
            vm = modinfo_vermagic(ko)
            checked_modules += 1
            if vm is None:
                errors.append(f"NO_VERMAGIC: {ko}")
            elif vm != kver:
                errors.append(f"VERMAGIC_MISMATCH: {ko} vm={vm} dir={kver}")

print(f"checked {checked_dirs} kver-dirs, {checked_modules} modules")
if errors:
    print("ERRORS:")
    for e in errors:
        print(f"  {e}")
    sys.exit(1)
else:
    print("ALL_PASS vermagic")
