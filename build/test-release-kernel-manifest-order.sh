#!/bin/bash
# test-release-kernel-manifest-order.sh -- M9/Sky1 lane-defect fix (test-first).
# A KVER bump must not stop at the accelerator-overlay gate: release-kernel.sh
# must regenerate the kernel manifest BEFORE it calls stage-accel-overlays.sh.
set -u
S="$(cd "$(dirname "$0")/.." && pwd)/build/release-kernel.sh"
[ -f "$S" ] || { echo "FAIL: no release-kernel.sh"; exit 1; }
gen=$(grep -n 'kernel-manifest.py gen' "$S" | head -1 | cut -d: -f1)
ov=$(grep -n '\$REPO/build/stage-accel-overlays.sh' "$S" | head -1 | cut -d: -f1)
if [ -z "$gen" ] || [ -z "$ov" ]; then echo "FAIL: manifest gen or overlay call missing"; exit 1; fi
if [ "$gen" -lt "$ov" ]; then
    echo "PASS: manifest gen (line $gen) precedes the overlay gate (line $ov)"
else
    echo "FAIL: manifest gen (line $gen) is after the overlay gate (line $ov)"
    exit 1
fi
