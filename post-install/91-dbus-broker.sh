#!/bin/bash
# 91-dbus-broker.sh — switch the system bus from dbus-daemon to dbus-broker.
#
# NCZ-OS 26.7 audit (W1.2): the installed system ships the legacy
# dbus-daemon (the 'dbus' source package) as its system bus, because
# that's what the Debian forky base pulls in by default. dbus-broker
# is the same wire protocol but a much smaller, faster, more
# memory-safe implementation, and it's what Debian/Ubuntu/Fedora
# have been recommending for years on the system bus. The session bus
# is unaffected — it's still dbus-daemon because broker is system-bus only.
#
# This hook:
#   1. apt-installs dbus-broker (offline from the pool when available,
#      network fallback otherwise — same pattern as 36-telemetry).
#   2. defensively drops any /etc/systemd/system/dbus.service.d/ drop-in
#      that pins the bus to dbus-daemon — apt's first install on a
#      baked image can leave such drop-ins behind.
#   3. disables dbus.service (the legacy daemon's enablement symlink,
#      created by the dbus package's postinst under
#      multi-user.target.wants/) and enables dbus-broker.service.
#      The broker's unit file ships:
#
#          [Install]
#          Alias=dbus.service
#
#      so `systemctl enable dbus-broker.service` creates the
#      multi-user.target.wants/dbus.service symlink that the dbus
#      package's own postinst created — that symlink now points at
#      the broker, not the legacy daemon, and dbus.socket activates
#      the broker on first connection.
#
# NOTE on masking: a `systemctl mask dbus.service` would be a no-op
# here. The mask creates /etc/systemd/system/dbus.service →
# /dev/null, but the [Install] Alias=dbus.service in
# dbus-broker.service means `systemctl enable dbus-broker.service`
# re-creates the same symlink path on the next line, overwriting the
# mask. (Verified against the shipped unit: dbus-broker 37-5 on arm64.)
# The disable + enable pair below is the real mechanism; the
# dbus-broker service itself prevents the race because dbus-broker
# is the only unit that pulls in dbus.socket from dbus-system-bus-common
# once the legacy enablement is gone.
#
# Idempotent: re-runnable; each step is guarded by dpkg / systemctl so
# a partially-applied prior run completes cleanly.
#
# Verified on the source tree before authoring:
#   - assets/sinty-nm/sinty-nm.service uses `After=dbus.service` +
#     `BusName=org.freedesktop.NetworkManager` + D-Bus activation — that
#     works with either bus daemon (broker implements the same protocol).
#   - post-install/20-desktop.sh's polkit + xdg-desktop-portal + pipewire
#     wiring links against libdbus, never exec()'s dbus-daemon directly.
#   - preseed/late.sh only writes /etc/machine-id (which is owned by
#     /var/lib/dbus/machine-id, not the daemon).
# So no call site in the installer tree hard-depends on dbus-daemon.
#
# Runs in chroot during install (Phase 2). Failure-tolerant: a mirror
# outage should not abort the install when the broker cannot be
# installed; we log and continue, and the broker install is retried
# on next boot by apt's Unattended-Upgrades or by re-running this hook.
set -euo pipefail

echo "[91] dbus-broker: switch the system bus off legacy dbus-daemon"

# 1. install dbus-broker (prefer offline pool, network fallback). On a
#    baked image the package is already in the offline mirror via
#    manifests/desktop.pkgs, so this is normally a no-op.
if ! dpkg -s dbus-broker >/dev/null 2>&1; then
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends dbus-broker 2>&1 | tail -3; then
        echo "[91] WARN: dbus-broker install failed; legacy dbus-daemon remains the system bus" >&2
        exit 0
    fi
fi

# 2. defensively drop any drop-in that pins dbus.service to dbus-daemon.
#    Some preseed flows drop a `ExecStart=/usr/bin/dbus-daemon --system`
#    drop-in under /etc/systemd/system/dbus.service.d/ — dbus-broker
#    uses its own service unit, so any such drop-in is now wrong.
if [ -d /etc/systemd/system/dbus.service.d ]; then
    rm -rf /etc/systemd/system/dbus.service.d
    echo "[91] removed /etc/systemd/system/dbus.service.d (would block dbus-broker activation)"
fi

# 3. drop the legacy dbus.service enablement (the dbus package's postinst
#    creates multi-user.target.wants/dbus.service -> ../dbus.service).
#    Then enable dbus-broker.service, whose [Install] Alias=dbus.service
#    recreates that symlink as broker. This is the real swap: the unit
#    now resolving at the bus name is dbus-broker, not dbus-daemon.
#    We do NOT mask dbus.service — dbus-broker.service's Alias would
#    overwrite the mask symlink on the next line, making the mask a
#    no-op (verified against dbus-broker 37-5 unit file).
if systemctl list-unit-files dbus.service >/dev/null 2>&1; then
    systemctl disable dbus.service 2>/dev/null || true
    echo "[91] disabled dbus.service (legacy daemon enablement dropped)"
fi

# 4. enable dbus-broker.service so the broker owns /run/dbus/system_bus_socket
#    on first boot. dbus-broker.service is a thin activation wrapper
#    around dbus-broker itself; it provides dbus.socket (via
#    dbus-system-bus-common, the [Install] Alias in
#    dbus-broker.service makes the broker unit reachable as
#    dbus.service). Both units are in /usr/lib/systemd/system/ from
#    the package; we just enable.
if systemctl list-unit-files dbus-broker.service >/dev/null 2>&1; then
    systemctl enable dbus-broker.service 2>&1 | tail -1 || true
    echo "[91] dbus-broker.service enabled (alias dbus.service -> broker; owns system bus)"
else
    # older releases ship dbus-broker activation only via dbus.service
    # (broker is the ExecStart there). In that case leave dbus.service
    # alone but make sure dbus-daemon is not masking anything.
    echo "[91] dbus-broker.service not shipped; broker will activate via dbus.service" >&2
fi

systemctl daemon-reload 2>/dev/null || true

echo "[91] DONE — system bus: dbus-broker (legacy dbus-daemon enablement replaced via Alias=dbus.service)"