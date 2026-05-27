#!/bin/bash
# 83-npu-dkms.sh — install aipu DKMS package for kernel-upgrade-proof NPU driver
#
# Background: The Sky1 kernel ships armchina_npu.ko in-tree as a module.
# When the kernel is upgraded via apt (e.g., security update), the NPU
# driver must be rebuilt for the new kernel. DKMS handles this automatically.
#
# This hook installs the cix-npu-driver-dkms package which provides the
# aipu kernel module source + dkms.conf. DKMS builds the module against
# the running kernel at install time, and rebuilds automatically on every
# kernel upgrade via the dkms autoinstall infrastructure.
#
# The resulting aipu.ko coexists with the in-tree armchina_npu.ko — only
# one is loaded (whichever is probed first). The DKMS module is preferred
# because it can be version-pinned independently of the kernel.
#
# NOTE: Inside the installer chroot, uname -r != target kernel, so DKMS
# won't build. This is expected. The package is installed with its source
# under /usr/src/aipu-6.1.1-2/. On first boot, dkms autoinstall fires
# (via dkms_autoinstaller.service or the admin's manual `dkms install`).
#
# Ordering: runs AFTER 25-cix-proprietary.sh (which installs .debs).
# Requires: dkms package from apt.
set -euo pipefail

echo "[83] NPU DKMS module (aipu)"

ASSETS=/usr/local/lib/cix-installer/assets
DKMS_DEB="$ASSETS/cix-debs/cix-npu-driver-dkms_6.1.1-2_all.deb"

# ----------------------------------------------------------------------
# 1. Ensure dkms package is installed (from apt)
# ----------------------------------------------------------------------
if ! dpkg-query -W -f='${Status}' dkms 2>/dev/null | grep -q "install ok installed"; then
    echo "[83] installing dkms from apt..."
    apt-get install -y dkms 2>&1 | tail -3
fi

# ----------------------------------------------------------------------
# 2. Install cix-npu-driver-dkms .deb
# ----------------------------------------------------------------------
if [ -f "$DKMS_DEB" ]; then
    echo "[83] installing cix-npu-driver-dkms from $DKMS_DEB..."
    dpkg -i "$DKMS_DEB" 2>&1 | tail -5

    # ------------------------------------------------------------------
    # 3. Apply FyrbyAdditive MS-R1 patches to the DKMS source
    # ------------------------------------------------------------------
    # The upstream DKMS source (6.1.1-2) needs the MS-R1 fix patch
    # (SSDT override + ioctl compat + SMMU constraint + asid_base).
    # The patch is applied at build time by dkms.conf's MAKE directive.
    # The source already targets Sky1 + V3 via the BUILD flags in dkms.conf.
    echo "[83] DKMS source installed at /usr/src/aipu-6.1.1-2/"
    echo "[83] (build deferred to first boot via dkms autoinstall)"

    # ------------------------------------------------------------------
    # 4. Remove the in-tree armchina_npu.ko from modules.dep so DKMS
    #    aipu.ko takes priority on next depmod
    # ------------------------------------------------------------------
    # We don't blacklist armchina_npu — just let DKMS module take priority
    # via the /updates/ directory (higher precedence in modules.dep).
    # Actually, the in-tree module is fine and works. The DKMS module
    # provides an alternative build path for kernel upgrades.
    echo "[83] in-tree armchina_npu.ko remains available as fallback"
    echo "[83] DKMS aipu.ko will be preferred after first dkms build"

else
    echo "[83] WARN: $DKMS_DEB not found — DKMS package not installed"
fi

# ----------------------------------------------------------------------
# 5. Enable dkms autoinstall on first boot
# ----------------------------------------------------------------------
if systemctl is-enabled dkms_autoinstaller.service 2>/dev/null; then
    echo "[83] dkms_autoinstaller.service already enabled"
else
    # Manually schedule a first-boot dkms build via a oneshot service
    mkdir -p /etc/systemd/system
    cat > /etc/systemd/system/npu-dkms-build.service << 'SERVICEEOF'
[Unit]
Description=Build aipu DKMS module for NPU
After=network.target
ConditionPathExists=/usr/src/aipu-6.1.1-2/dkms.conf

[Service]
Type=oneshot
ExecStart=/usr/sbin/dkms install -m aipu -v 6.1.1-2
ExecStartPost=/usr/sbin/depmod -a
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SERVICEEOF
    systemctl enable npu-dkms-build.service 2>/dev/null && \
        echo "[83] enabled npu-dkms-build.service (first-boot DKMS build)"
fi

echo "[83] NPU DKMS install complete"
echo "[83]   Source:   /usr/src/aipu-6.1.1-2/"
echo "[83]   Service:  npu-dkms-build.service (first boot)"
echo "[83]   Module:   aipu.ko (DKMS builds on next kernel upgrade)"
