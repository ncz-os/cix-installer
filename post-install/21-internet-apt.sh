#!/bin/bash
# 21-internet-apt.sh — enable Ubuntu ports archive as apt source on installed system.
#
# RATIONALE (2026-05-20):
#
# NCZ Reinhardt installer ships a "Thin" cdrom mirror that intentionally
# excludes most of universe/multiverse to keep the ISO small. Several
# downstream post-install hooks AND the operator's day-to-day apt usage
# need packages that aren't on the cdrom (notably inetutils-telnetd +
# openbsd-inetd per CLAUDE.md rule 9, but also any future operator
# package install).
#
# Without this hook, every `apt install <anything not on cdrom>` errors:
#   E: Failed to fetch cdrom://nclawzero cixmini resolute ...
#   E: Unable to locate package <foo>
# and the operator has to add the source manually after every reinstall
# — which gets forgotten, leaving fleet hosts without lockout-recovery
# tooling (rule 9 violation captured by mem_1779320845082_dfa764-class
# review work, 2026-05-20).
#
# Fix: drop a permanent /etc/apt/sources.list.d/ubuntu-archive.list
# pointing at ports.ubuntu.com (arm64 archive). resolute = Ubuntu 26.04
# codename per /etc/os-release UBUNTU_CODENAME.
#
# Network is best-effort during chroot late_command: this hook installs
# the source list always (persists across reboot), and runs apt-get
# update only if the network is reachable. On a fleet LAN host with
# the gateway up, this is a no-op of a few seconds; on a netinstall
# bench without uplink, the source is still in place for the operator
# to use later.
set -uo pipefail

echo "[21] writing Ubuntu ports archive source list"

# Discover the Ubuntu codename. NCZ derives from a specific Ubuntu
# release; /etc/os-release records UBUNTU_CODENAME=resolute for 26.04.
# Default to "resolute" if /etc/os-release is missing in the chroot.
UBUNTU_CODENAME="resolute"
if [ -r /etc/os-release ]; then
    candidate=$(. /etc/os-release; echo "${UBUNTU_CODENAME:-}")
    if [ -n "$candidate" ]; then
        UBUNTU_CODENAME="$candidate"
    fi
fi

SOURCES_FILE=/etc/apt/sources.list.d/ubuntu-archive.list
cat > "$SOURCES_FILE" <<EOF
# NCZ Reinhardt: Ubuntu ports archive (arm64) for packages not in the
# Thin cdrom mirror. Added by cix-installer/post-install/21-internet-apt.sh.
# CLAUDE.md rule 9 (telnetd-on-every-fleet-host) depends on this source.
deb http://ports.ubuntu.com/ubuntu-ports/ ${UBUNTU_CODENAME} main universe
deb http://ports.ubuntu.com/ubuntu-ports/ ${UBUNTU_CODENAME}-updates main universe
deb http://ports.ubuntu.com/ubuntu-ports/ ${UBUNTU_CODENAME}-security main universe
EOF
chmod 0644 "$SOURCES_FILE"
echo "[21] wrote $SOURCES_FILE (codename=$UBUNTU_CODENAME)"

# Best-effort apt-get update — network may not be up during chroot
# late_command. Subsequent hooks (25-cix-ppa, 36-telnetd) re-run
# apt-get update before installing, so a transient failure here is
# harmless. The source list persists into the booted system, which
# is the load-bearing artifact.
if apt-get update -o Acquire::Retries=2 2>&1 | tail -5; then
    echo "[21] apt-get update OK — ubuntu-archive index now available"
else
    echo "[21] WARN: apt-get update did not complete cleanly (network or DNS not ready)"
    echo "[21]       source list is in place; later hooks + operator apt usage will succeed"
fi

exit 0
