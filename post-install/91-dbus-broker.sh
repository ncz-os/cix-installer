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
#   3. enables dbus-broker.service FIRST and verifies the enablement
#      via `systemctl is-enabled` BEFORE touching the legacy enablement.
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
#   4. only when the broker is confirmed enabled, drops the legacy
#      dbus.service enablement. If the broker could not be enabled,
#      the legacy dbus.service enablement is left in place as a
#      fallback so the box always has a system bus.
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

# 3. enable dbus-broker.service FIRST, and prove it took effect before we
#    touch the legacy dbus.service enablement. The broker's [Install] ships:
#
#        Alias=dbus.service
#
#    so `systemctl enable dbus-broker.service` creates the
#    multi-user.target.wants/dbus.service symlink that the dbus package's
#    postinst created — that symlink now points at the broker, not the
#    legacy daemon, and dbus.socket activates the broker on first
#    connection.
#
#    We MUST NOT log success unconditionally. `cmd 2>&1 | tail -1` returns
#    tail's exit status, not cmd's; the broker would silently stay disabled
#    while the next line claims it is enabled, and on the next boot the box
#    has no system bus. Verify the broker enablement via systemctl is-enabled
#    before claiming it worked, and only then disable the legacy path.
#    If the broker unit is not shipped (older releases), leave dbus.service
#    alone — broker will activate via it as ExecStart, and we want it
#    enabled. If the broker IS shipped but cannot be enabled, the legacy
#    dbus.service enablement is left in place as a fallback, and the hook
#    exits 0 honestly with the fallback logged.
BROKER_OK=0   # 1 iff the broker enablement is verified
if systemctl list-unit-files dbus-broker.service >/dev/null 2>&1; then
    # `systemctl enable` may print to stdout (the symlink path) and exit
    # 0 on success or non-zero on failure. Capture BOTH streams and the
    # REAL exit status before any pipe to tail. (cmd 2>&1 | tail -1
    # returns tail's rc, not cmd's; the broker would silently stay
    # disabled while the next line claimed it was enabled.)
    set +e
    ENABLE_OUT=$(systemctl enable dbus-broker.service 2>&1)
    ENABLE_RC=$?
    set -e
    # systemctl is-enabled reports the persistent state. This is the
    # proof; the rc of `enable` alone isn't enough because a unit can
    # be already-enabled and print nothing useful, but exit 0.
    if [ "$ENABLE_RC" -eq 0 ] \
            && systemctl is-enabled dbus-broker.service >/dev/null 2>&1; then
        BROKER_OK=1
        # Surface the systemctl enable output (last line is the symlink).
        printf '%s\n' "$ENABLE_OUT" | tail -n1
        echo "[91] dbus-broker.service enabled (alias dbus.service -> broker; owns system bus)"
    else
        # DO NOT touch the legacy dbus.service enablement in this
        # branch — the broker would own the bus name while being
        # disabled, leaving the board with no system bus. Log the
        # failure honestly and fall through to the legacy keep-alive
        # path below.
        echo "[91] WARN: dbus-broker.service enable failed (rc=$ENABLE_RC); legacy dbus.service left enabled as fallback" >&2
        printf '%s\n' "$ENABLE_OUT" | sed 's/^/[91]   /' >&2 || true
    fi
else
    # older releases ship dbus-broker activation only via dbus.service
    # (broker is the ExecStart there). In that case dbus.service is the
    # broker service; do not disable it. The dbus-daemon symlink is the
    # same one the dbus package's postinst created, and it now points
    # at the broker.
    echo "[91] dbus-broker.service not shipped; broker activates via dbus.service" >&2
fi

# 4. drop the legacy dbus.service enablement ONLY when the broker is
#    confirmed enabled. The dbus package's postinst creates
#    multi-user.target.wants/dbus.service -> ../dbus.service; that symlink
#    is now rewritten by the broker enablement above (Alias=dbus.service)
#    so this disable only acts on the legacy daemon's own logic. If the
#    broker could not be enabled, we leave the legacy enablement alone —
#    the box still boots with a system bus.
#
#    We do NOT mask dbus.service — dbus-broker.service's Alias would
#    overwrite the mask symlink on the next line, making the mask a
#    no-op (verified against dbus-broker 37-5 unit file).
if [ "$BROKER_OK" -eq 1 ] && systemctl list-unit-files dbus.service >/dev/null 2>&1; then
    if systemctl disable dbus.service 2>/dev/null; then
        echo "[91] disabled dbus.service (legacy daemon enablement dropped; broker now owns bus name)"
    else
        echo "[91] WARN: could not disable dbus.service; broker is enabled, but the legacy daemon's enablement still exists (the broker's Alias=dbus.service has already taken the bus name, so this is cosmetic)" >&2
    fi
fi

systemctl daemon-reload 2>/dev/null || true

if [ "$BROKER_OK" -eq 1 ]; then
    echo "[91] DONE — system bus: dbus-broker (legacy dbus-daemon enablement replaced via Alias=dbus.service)"
else
    echo "[91] DONE — dbus-broker could not be enabled in this environment; legacy dbus-daemon remains the system bus (fallback)"
fi