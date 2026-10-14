#!/bin/bash
# apt-sim-zero-removals.sh — zero-removals pre-flight for the Singularity
# payload build. Lives OUTSIDE the in-container BUILD_SCRIPT (which is one
# single-quoted string and cannot itself contain unescaped quotes) so the
# exact dependency list, error messages, and exit semantics are normal
# shell code that uses shell quoting freely.
#
# Contract:
#   - "$1" = path inside the container where the simulation log should land.
#   - Runs `apt-get install -s -y --no-install-recommends` against the same
#     package list build-singularity.sh later installs for real.
#   - Exits 0 only when the simulation succeeds AND no "Remv " line appears
#     in the output. ANY Remv (or any non-zero apt exit) is fatal -- builds
#     never resume from a partial/zero-removals violation.
#   - Never touches /opt, kernel modules, real devices, or the host.
#
# This script is bind-mounted read-only at /ncz-build and invoked from
# BUILD_SCRIPT before the real apt-get install runs.

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
SIM_LOG="${1:-/work/tmp/apt-sim.log}"
mkdir -p "$(dirname "$SIM_LOG")"
# A short banner makes the simulation distinguishable from a real install
# log if both end up side-by-side in /work/tmp for triage.
{
    echo "== zero-removals pre-flight: apt-get install -s =="
    date -u +"  start: %Y-%m-%dT%H:%M:%SZ"
} > "$SIM_LOG"

if ! apt-get install -s -y --no-install-recommends \
        ca-certificates git golang-go \
        libglib2.0-bin \
        valac meson ninja-build pkg-config gettext \
        libgtk-4-dev libadwaita-1-dev libgtk4-layer-shell-dev \
        libwayland-dev wayland-protocols \
        libvte-2.91-gtk4-dev libgtksourceview-5-dev \
        libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev \
        gstreamer1.0-plugins-good gstreamer1.0-pipewire \
        libpulse-dev libpolkit-gobject-1-dev libpolkit-agent-1-dev \
        libjson-glib-dev libpeas-2-dev libpipewire-0.3-dev \
        libgee-0.8-dev libsoup-3.0-dev libenchant-2-dev \
        libgirepository-1.0-dev gobject-introspection \
        libupower-glib-dev \
        libatspi2.0-dev libcmocka-dev libdbusmenu-glib-dev libfontconfig-dev \
        libglib2.0-dev libgudev-1.0-dev libinput-dev libnm-dev \
        libpng-dev librsvg2-dev libsecret-1-dev libxml2-dev libpixman-1-dev \
        libpoppler-glib-dev libsystemd-dev libtracker-sparql-3.0-dev \
        libupower-glib-dev \
        libwebkitgtk-6.0-dev libxcb1-dev libxcb-ewmh-dev \
        libxcb-icccm4-dev libxkbcommon-dev \
        libpam0g-dev libgcrypt20-dev libcrypt-dev libsodium-dev \
        hwdata xwayland libxcb-dri3-dev \
        libxcb-composite0-dev libxcb-render0-dev libxcb-res0-dev \
        libxcb-xfixes0-dev libxcb-errors-dev libxcb-present-dev \
        sassc scdoc \
        libsdl2-dev libgl-dev libglu1-mesa-dev libx11-dev \
        libcairo2-dev libpango1.0-dev libwayland-bin \
        libdisplay-info-dev \
        libseat-dev \
        libliftoff-dev \
        libnm-dev \
        libgoa-1.0-dev \
        sassc \
        libdrm-dev libcairo2-dev libpango1.0-dev libgdk-pixbuf-2.0-dev \
        libinput-dev \
        libpoppler-glib-dev \
        hwdata \
        scdoc \
        libdisplay-info-dev \
        libseat-dev \
        libliftoff-dev \
        cmake libcups2-dev libfuse3-dev libges-1.0-dev libgles-dev \
        libgnutls28-dev libharfbuzz-dev liblcms2-dev libsqlite3-dev zlib1g-dev \
        libgphoto2-dev libtiff-dev libwebp-dev \
        freerdp3-dev libarchive-dev libfido2-dev libfreetype-dev liblzma-dev \
        libsane-dev libxcb-render-util0-dev libxcb-xinput-dev libzbar-dev \
        libzstd-dev nettle-dev \
        libevdev-dev libmtdev-dev libwacom-dev libtracker-sparql-3.0-dev \
        libsfdo-dev libudev-dev \
        libgstreamer-plugins-bad1.0-dev libvulkan-dev glslc libcolord-dev \
        libxcursor-dev libxdamage-dev libxi-dev libxinerama-dev libxrandr-dev \
        libxrender-dev libxext-dev libxfixes-dev libepoxy-dev libgraphene-1.0-dev \
        iso-codes libfribidi-dev libjpeg-dev \
        build-essential >> "$SIM_LOG" 2>&1; then
    {
        echo
        echo "ERROR: zero-removals pre-flight FAILED (apt-get install -s returned non-zero)."
        echo "       See $SIM_LOG for the full simulation transcript."
    } >&2
    grep '^E: ' "$SIM_LOG" | head -40 >&2 || true
    exit 1
fi

# Zero-removals gate: ANY package that apt would REMOVE during the install
# is a fatal build failure. Caught cases:
#   - a Conflicts/Replaces between a -dev we pulled and a runtime lib the
#     shipped system still needs (the most common real-world failure mode);
#   - a base image (debian:${codename}) whose package set no longer matches
#     the pinned snapshot, so a refactored metapackage is on its way out.
# No bypass: --allow-downgrades, --no-trusted, --allow-unauthenticated, and
# -t (target-release) are explicitly NOT honoured. If the dependency
# resolution itself is wrong, the build aborts here.
if grep -E '^(Remv|Remv\s) ' "$SIM_LOG"; then
    {
        echo
        echo "ERROR: zero-removals gate violated -- dependency simulation would REMOVE packages."
        echo "       See $SIM_LOG for the full simulation transcript."
        echo "       Adjust the dependency set (or the upstream pins) and rebuild."
    } >&2
    exit 1
fi

{
    echo
    echo "== zero-removals pre-flight: clean (no Remv lines) =="
    date -u +"  end:   %Y-%m-%dT%H:%M:%SZ"
} >> "$SIM_LOG"
exit 0
