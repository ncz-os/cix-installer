#!/bin/bash
# 00-cix-proprietary.sh — install Cix Sky1 closed-source userspace .debs.
#
# 37 packages captured via dpkg-repack from a stock Cix factory image:
# audio DSP, GPU/Mali, NPU/NoE, VPU, ISP, mesa, libdrm, libglvnd,
# llama.cpp, MNN, ONNX runtime, whisper.cpp, gstreamer, etc.
#
# Skip the Cix kernel debs — we install our linux-cix-msr1 in 10-our-kernel.sh.
set -euo pipefail

ASSETS=/usr/local/lib/cix-installer/assets/cix-debs
[ -d "$ASSETS" ] || { echo "ERROR: $ASSETS missing"; exit 1; }

echo "[00] Cix proprietary userspace .debs from $ASSETS"
ls "$ASSETS" | wc -l
echo ""

cd "$ASSETS"
# Skip Cix's kernel debs — we install our own
dpkg -i --force-depends $(ls *.deb | grep -vE '^linux-(image|headers)-.*-cix-build-generic_') || true

# Resolve any unmet apt deps the Cix .debs pulled in (should be light —
# Cix's debs depend mostly on Debian-stock libs that the base install has)
apt-get install -fy

# Verify all installed
echo ""
echo "Cix packages now installed:"
dpkg -l | awk '/^ii.*cix-/ {print "  " $2 " " $3}'
