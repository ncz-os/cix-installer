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

# r75 P3: cix-noe-umd's postinst runs `pip install libnoe`; that wheel
# requires Python <3.13. Ubuntu 25.10 questing ships Python 3.13.7, so
# postinst fails and apt is left wedged with cix-noe-umd in iF state.
# The C library we actually use (libnoe.so via ctypes wrapper in
# npu_embed_v2.py) is installed by the package's data tar before
# postinst runs, so the binary payload is fine.
#
# Codex r75 review MEDIUM — this recovery only fires on iF (failed-config),
# not iU (unpacked). It first verifies that the postinst contains the
# known libnoe pip line, then patches ONLY that stanza rather than
# replacing the whole script. dpkg --configure / apt-get -f install
# failures are now hard-fatal so partial installs cannot be reported as
# success. Final check verifies libnoe.so is on disk before declaring OK.
NOE_STATE=$(dpkg-query -W -f='${db:Status-Abbrev}\n' cix-noe-umd 2>/dev/null | tr -d ' ')
if [ "$NOE_STATE" = "iF" ]; then
    echo "[25] cix-noe-umd in iF (failed-config) state — diagnosing"
    POSTINST=/var/lib/dpkg/info/cix-noe-umd.postinst
    if [ -f "$POSTINST" ] && grep -qE "pip3? install.*libnoe|python3? -m pip install.*libnoe" "$POSTINST"; then
        echo "[25] confirmed: postinst contains libnoe pip line — patching that stanza only"
        # Save canonical copy for the build record + comment-out the libnoe pip line(s)
        cp -a "$POSTINST" "$POSTINST.r75-orig"
        sed -i -E 's|^([[:space:]]*)((python3?[[:space:]]+-m[[:space:]]+pip|pip3?)[[:space:]]+install[[:space:]]+.*libnoe.*)$|\1: # r75 P3: skipped on Py3.13 -- \2|' "$POSTINST"
        chmod 0755 "$POSTINST"
        if dpkg --configure cix-noe-umd 2>&1 | tail -3; then
            apt-get -f install -y 2>&1 | tail -3 || { echo "[25] ERROR: apt-get -f install failed after postinst patch" >&2; exit 1; }
        else
            echo "[25] ERROR: dpkg --configure still failed after libnoe-pip-line patch" >&2
            exit 1
        fi
    else
        echo "[25] ERROR: cix-noe-umd in iF but postinst does not contain expected libnoe pip line" >&2
        echo "       Cause unknown — refusing to silently mask. Operator must investigate:" >&2
        echo "       /var/lib/dpkg/info/cix-noe-umd.postinst:" >&2
        sed -n '1,30p' "$POSTINST" 2>&1 | sed 's/^/         /' >&2 || true
        exit 1
    fi
elif [ "$NOE_STATE" = "iU" ]; then
    echo "[25] WARN: cix-noe-umd in iU (unpacked-not-configured) — not the known Py3.13 case; skipping P3 recovery" >&2
fi

# Verify the libnoe.so we actually use lives on disk after install/recovery.
if [ "$NOE_STATE" = "iF" ] || dpkg -l cix-noe-umd >/dev/null 2>&1; then
    if ! [ -e /usr/share/cix/lib/libnoe.so ] && ! [ -e /usr/lib/aarch64-linux-gnu/libnoe.so ] && ! find /usr -name "libnoe.so*" 2>/dev/null | grep -q .; then
        echo "[25] ERROR: cix-noe-umd reported installed but libnoe.so not found anywhere under /usr" >&2
        exit 1
    fi
    echo "[25] libnoe.so present — cix-noe-umd usable for ctypes wrapper"
fi

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
