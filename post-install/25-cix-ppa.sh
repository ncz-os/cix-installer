#!/bin/bash
# 25-cix-ppa.sh — add archive.cixtech.com PPA + install cix-npu-driver-dkms + cix-vpu-driver-dkms
#
# CIX official open-source driver edition provides:
#   - cix-npu-driver-dkms     (Zhouyi NPU kernel driver, ArmChina Compass)
#   - cix-vpu-driver-dkms     (VPU kernel driver alongside in-tree amvx)
#   - Various userspace runtimes (NOE, OpenCL on Zhouyi, etc.)
#
# DKMS builds against current kernel headers — works for both LTS 6.18 + NEXT 7.0.3
# IF kernel-headers are present. We ship Yocto-built kernels which need their headers
# packaged separately (TODO r53). For r52 we install cix-* userspace + queue DKMS
# build for r53 once headers are shipped.
set -euo pipefail

echo "[25] adding CIX official PPA (archive.cixtech.com)"

# Trust CIX's signing key
mkdir -p /usr/share/keyrings
if [ -f /usr/local/lib/cix-installer/assets/cix-deb-repo.gpg ]; then
    cp /usr/local/lib/cix-installer/assets/cix-deb-repo.gpg /usr/share/keyrings/cix-deb-repo.gpg
else
    # Fallback: fetch online (network needed)
    curl -fsSL https://archive.cixtech.com/ppa-gpg-public-key.asc \
        | gpg --dearmor -o /usr/share/keyrings/cix-deb-repo.gpg 2>&1 || \
        echo "[25] WARN: could not fetch CIX GPG key online — repo will be unavailable"
fi

# Add the source list (trixie main since CIX targets Debian 13)
cat > /etc/apt/sources.list.d/cix-ppa.list <<'APT'
deb [signed-by=/usr/share/keyrings/cix-deb-repo.gpg] https://archive.cixtech.com/debian trixie main
APT

# apt update — best-effort (network may not be up post-install)
apt-get update 2>&1 | tail -5 || echo "[25] apt-get update warn (network or repo not reachable)"

# Install CIX userspace runtimes (these don't require DKMS)
# - cix-noe-umd: NPU Runtime userspace
# - libcix-* libs
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    cix-noe-umd 2>&1 | tail -3 || echo "[25] cix-noe-umd not installable (network/headers issue)"

# Try cix-npu-driver-dkms — needs linux-headers for our kernel; will build if headers present
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    cix-npu-driver-dkms 2>&1 | tail -5 || echo "[25] cix-npu-driver-dkms install incomplete (headers TBD r53)"

DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    cix-vpu-driver-dkms 2>&1 | tail -5 || echo "[25] cix-vpu-driver-dkms install incomplete (headers TBD r53)"

# Detect NPU device node creation
if [ -e /dev/zhouyi0 ] || [ -e /dev/cix-noe0 ] || [ -e /dev/aipu0 ]; then
    echo "[25] NPU device node detected"
else
    echo "[25] NPU device not bound at install time — will be created on next boot if DKMS built modules"
fi

echo "[25] CIX PPA + NPU/VPU runtime layer applied"
