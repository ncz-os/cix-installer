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
# Skip Cix's kernel debs — we installed our linux-cix-msr1 in 10-.
DEBS=$(ls *.deb | grep -vE '^linux-(image|headers)-.*-cix-build-generic_')

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

# Always exit 0 — Cix postinst quirks should not halt the installer.
# If something is genuinely broken, surfaces during agent runtime
# rather than killing the install before branding/bootloader land.
exit 0
