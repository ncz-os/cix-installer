#!/bin/bash
# 25-cix-proprietary.sh — install Cix Sky1 closed-source userspace .debs.
#
# Renamed from 00- to 25- so it runs AFTER 20-desktop.sh. Several Cix
# packages (notably cix-debian-misc, cix-gstreamer) have postinst
# scripts that touch GNOME-stack files (gdm3 daemon.conf, glib schema
# compilation, pulseaudio paths, fcitx, etc.) and depend on libglib2.0-*,
# gdm3, dbus, fontconfig already being installed. With 20-desktop
# pulling those in first, cix-* postinsts can complete cleanly instead
# of failing with 'glib-compile-schemas: command not found' and
# 'sed: cannot read /etc/gdm3/daemon.conf'.
#
# 37 packages captured via dpkg-repack from a stock Cix factory image:
# audio DSP, GPU/Mali, NPU/NoE, VPU, ISP, mesa, libdrm, libglvnd,
# llama.cpp, MNN, ONNX runtime, whisper.cpp, gstreamer, etc.
#
# Skip the Cix kernel debs — we installed our linux-cix-msr1 in
# 10-our-kernel.sh.
#
# Resilience: some Cix postinsts have known shell bugs ('[: too many
# arguments') that fail even when deps are met. We treat those as
# non-fatal — package contents land via dpkg --unpack/configure, and
# the install proceeds. Remaining postinst issues are logged for
# follow-up but don't halt the installer.
set -uo pipefail

ASSETS=/usr/local/lib/cix-installer/assets/cix-debs
[ -d "$ASSETS" ] || { echo "ERROR: $ASSETS missing"; exit 1; }

mkdir -p /var/log/cix-install

echo "[25] Cix proprietary userspace .debs from $ASSETS"
echo "    package count: $(ls $ASSETS | wc -l)"
echo ""

cd "$ASSETS"
# Skip:
#   1. Cix's kernel image/headers debs (we installed our own in 10-)
#   2. Cix's kernel-module driver debs (post 2026-05-03 kernel jump
#      from 6.6.10 → 6.18.14-cix-sky1, these prebuilt .ko's are
#      vermagic-incompatible — they install into /lib/modules/6.6.10-
#      cix-build-generic/extra but the kernel won't load them. Same
#      hardware is now driven by in-tree drivers shipped with the new
#      kernel: panthor (GPU, was mali_kbase), armchina-npu (NPU, was
#      aipu), amvx in-tree (VPU, replaces vendor amvx blob), drm/cix
#      (display, replaces trilin_dptx), cix_dsp_rproc with ACPI fix.
#      Installing the 6.6 .ko packages just pollutes the modules tree
#      with files that fail vermagic check. Skip entirely.)
DEBS=$(ls *.deb | grep -vE '^linux-(image|headers)-.*-cix-build-generic_' \
                | grep -vE '^cix-(npu-driver|gpu-driver|vpu-driver|isp-driver|wlan|csi-driver|noe-kmd)_' \
                | grep -vE '^cix-(npu-umd|noe-umd|npu-onnxruntime)_')

echo "Skipping vermagic-incompatible cix-*-driver debs (post-Sky1-switch):"
ls *.deb | grep -E '^cix-(npu-driver|gpu-driver|vpu-driver|isp-driver|wlan|csi-driver|noe-kmd)_' | sed 's/^/    /' || true

# ----------------------------------------------------------------------
# Patch cix-debian-misc.deb to remove its broken initramfs-tools rename
# block. The postinst unconditionally runs:
#
#   mv /usr/share/initramfs-tools/init                       original/
#   mv /usr/share/initramfs-tools/original/cix_init          init
#   mv /usr/share/initramfs-tools/scripts/init-top/udev      original/
#   mv /usr/share/initramfs-tools/original/cix_udev          init-top/udev
#   mv /usr/share/initramfs-tools/scripts/init-premount/plymouth original/
#   mv /usr/share/initramfs-tools/original/cix_plymouth      init-premount/
#
# But cix_init / cix_udev / cix_plymouth are NOT actually shipped in
# the deb's data.tar (verified 2026-05-03: only `original/` empty dir
# and `hooks/cix_ko` ship). The first mv of each pair succeeds — moving
# Debian's working scripts into original/ — then the matched mv fails
# on a missing source. End state: /usr/share/initramfs-tools/init is
# gone, and update-initramfs warns `cp: cannot stat /usr/share/
# initramfs-tools/init: No such file or directory` and builds a 221MB
# initrd that's missing /init. Booting it kernel-panics ("can't run /
# init") and triggers an infinite reboot loop on real hardware.
#
# Workaround: extract the deb, comment out only the 6 mv lines, repack,
# install the patched version. All other Cix postinst behavior (glib
# schema rebuild, gdm3 daemon.conf, logind tweaks, fcitx, pulseaudio)
# is preserved. Real fix is upstream at Cix — they need to either ship
# the cix_init etc. files or drop the rename block.
# ----------------------------------------------------------------------
CDM_ORIG="$ASSETS/cix-debian-misc_1.0.0_arm64.deb"
CDM_PATCHED=/tmp/cix-debian-misc-noinitrd-patch.deb
if [ -f "$CDM_ORIG" ]; then
    echo "--- patching cix-debian-misc.deb to neuter init-rename block ---"
    rm -rf /tmp/cdm-patch
    mkdir -p /tmp/cdm-patch
    dpkg-deb -R "$CDM_ORIG" /tmp/cdm-patch
    if [ -f /tmp/cdm-patch/DEBIAN/postinst ]; then
        # Comment any mv touching /usr/share/initramfs-tools/{init,scripts/...,original/cix_*}
        sed -i -E '\#^[[:space:]]*mv[[:space:]]+/usr/share/initramfs-tools/(init|scripts/init-(top|premount)/(udev|plymouth)|original/cix_(init|udev|plymouth))#s|^|# [25-patched] |' \
            /tmp/cdm-patch/DEBIAN/postinst
        echo "    patched postinst — commented mv lines:"
        grep -nE '^# \[25-patched\]' /tmp/cdm-patch/DEBIAN/postinst | sed 's/^/      /'
    fi
    dpkg-deb -b /tmp/cdm-patch "$CDM_PATCHED" >/dev/null
    # Swap the patched deb into the install set
    DEBS=$(echo "$DEBS" | grep -v '^cix-debian-misc_')
    cp "$CDM_PATCHED" "$ASSETS/cix-debian-misc_1.0.0_arm64.patched.deb"
    DEBS="$DEBS cix-debian-misc_1.0.0_arm64.patched.deb"
fi

echo "--- dpkg -i (collect failures, continue) ---"
dpkg -i --force-depends $DEBS 2>&1 | tee /var/log/cix-install/25-dpkg.log || true

echo ""
echo "--- apt-get install -fy (resolve unmet apt deps) ---"
apt-get install -fy 2>&1 | tee /var/log/cix-install/25-apt-fix.log || true

echo ""
echo "--- dpkg --configure -a (retry half-configured packages with deps now resolved) ---"
dpkg --configure -a 2>&1 | tee /var/log/cix-install/25-dpkg-configure.log || true

echo ""
echo "Cix packages installed (ii):"
dpkg -l | awk '/^ii.*cix-/ {print "  " $2 " " $3}' | tee /var/log/cix-install/25-cix-installed.log

echo ""
echo "Cix packages with known issues (iU/iF — half-installed):"
STUCK=$(dpkg -l 2>/dev/null | awk '/^iU|^iF/ {print $2}')
echo "$STUCK" | sed 's/^/  /'

# Force-purge any half-configured packages. Without this, every later
# apt-get call retries the broken postinst and exits non-zero, which
# kills downstream hooks (30-agents, 50-brand, ...) that have set -e.
# We've already captured what landed cleanly via dpkg -l above; the
# stuck packages weren't going to work anyway.
for pkg in $STUCK; do
    echo "    purging stuck package: $pkg"
    dpkg --purge --force-remove-reinstreq --force-remove-essential "$pkg" 2>&1 | tail -3 || true
done

# Bridge between vendor 6.6 .ko vermagic and our built kernel's KVER:
# RETIRED 2026-05-03 with the Sky1-Linux 6.18.14 switch. The cix-*-
# driver debs are now skipped entirely above (DEBS filter), and the
# in-tree 6.18 drivers (panthor, armchina-npu, in-tree amvx, drm/cix,
# cix_dsp_rproc with ACPI fix) take their place. No bridge needed.
RUNNING_KVER=$(uname -r)
echo "    running kernel: $RUNNING_KVER (no OoT bridge — Sky1-Linux in-tree)"

# Always exit 0 — Cix postinst quirks should not halt the installer.
# If something is genuinely broken, surfaces during agent runtime
# rather than killing the install before branding/bootloader land.
exit 0
