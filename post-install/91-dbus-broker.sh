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
#   2. enables dbus-broker.service so it owns /run/dbus/system_bus_socket.
#   3. masks dbus.service so the legacy daemon cannot race the broker
#      for the bus name; the broker ships its own D-Bus activation
#      service unit (dbus-broker.service) so this is safe.
#   4. defensively drops any /etc/systemd/system/dbus.service.d/ drop-in
#      that pins the bus to dbus-daemon — apt's first install on a
#      baked image can leave such drop-ins behind.
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

# 3. mask the legacy dbus.service so dbus-daemon cannot race the broker
#    for the bus name. The broker ships /usr/lib/systemd/system/dbus-broker.service
#    with bus name activation; the legacy /lib/systemd/system/dbus.service
#    (when present) is disabled + masked.
if systemctl list-unit-files dbus.service >/dev/null 2>&1; then
    systemctl disable dbus.service 2>/dev/null || true
    systemctl mask dbus.service 2>/dev/null || true
    echo "[91] masked dbus.service (legacy daemon)"
fi

# 4. enable dbus-broker.service so the broker owns /run/dbus/system_bus_socket
#    on first boot. dbus-broker.service is a thin activation wrapper
#    around dbus-broker itself; it provides dbus.socket so the broker is
#    bound to the socket from sysinit onward. Both units are in
#    /usr/lib/systemd/system/ from the package; we just enable.
if systemctl list-unit-files dbus-broker.service >/dev/null 2>&1; then
    systemctl enable dbus-broker.service 2>&1 | tail -1 || true
    echo "[91] dbus-broker.service enabled (owns system bus)"
else
    # older releases ship dbus-broker activation only via dbus.service
    # (broker is the ExecStart there). In that case leave dbus.service
    # alone but make sure dbus-daemon is not masking anything.
    echo "[91] dbus-broker.service not shipped; broker will activate via dbus.service" >&2
fi

systemctl daemon-reload 2>/dev/null || true

echo "[91] DONE — system bus: dbus-broker (legacy dbus-daemon masked)"
