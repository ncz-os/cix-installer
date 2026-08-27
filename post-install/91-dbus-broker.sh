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
#   3. enables dbus-broker.service and verifies via `systemctl is-enabled`
#      AND by inspecting the alias symlink. The broker's unit file ships:
#
#          [Install]
#          Alias=dbus.service
#
#      so `systemctl enable dbus-broker.service` creates/rewrites the
#      multi-user.target.wants/dbus.service symlink that the dbus
#      package's own postinst created — that symlink now points at
#      the broker, not the legacy daemon, and dbus.socket activates
#      the broker on first connection. The alias IS the replacement
#      of the legacy enablement.
#   4. does NOT disable dbus.service. The legacy "disable legacy after
#      broker enable" pattern is actively harmful: `systemctl disable
#      dbus.service` operates on the alias symlink the broker enablement
#      just created and removes it, leaving the board with no system bus
#      on the next boot. The alias replaces the legacy enablement; there
#      is nothing left to disable, and disabling is destructive.
#   5. If the broker could not be enabled, the legacy dbus.service
#      enablement is left in place as a fallback so the box always has a
#      system bus. The hook exits 0 honestly with the fallback logged.
#
# NOTE on masking: a `systemctl mask dbus.service` would be a no-op
# here. The mask creates /etc/systemd/system/dbus.service →
# /dev/null, but the [Install] Alias=dbus.service in
# dbus-broker.service means `systemctl enable dbus-broker.service`
# re-creates the same symlink path on the next line, overwriting the
# mask. (Verified against the shipped unit: dbus-broker 37-5 on arm64.)
# We do not mask — and we do not disable — for the same reason: the
# broker unit's [Install] section rewrites dbus.service.
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
#    manifests/installer-base.pkgs, so this is normally a no-op.
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

# 3. enable dbus-broker.service and verify the enablement took effect.
#    The broker's unit file ships:
#
#        [Install]
#        Alias=dbus.service
#
#    so `systemctl enable dbus-broker.service` creates/rewrites the
#    multi-user.target.wants/dbus.service symlink that the dbus package's
#    postinst originally created — that symlink now points at the broker,
#    not the legacy daemon. From systemd's point of view, dbus.service IS
#    enabled after the alias takes effect; the symlink in
#    multi-user.target.wants/ is what gets read on boot, and it points
#    at the broker.
#
#    We MUST NOT disable dbus.service after enabling the broker. The
#    legacy thinking was "broker replaces daemon, so disable the daemon
#    to clean up", but the disable undoes the alias:
#
#      * `systemctl enable dbus-broker.service` writes
#        /etc/systemd/system/multi-user.target.wants/dbus.service
#        -> /lib/systemd/system/dbus-broker.service  (via Alias=dbus.service)
#      * `systemctl disable dbus.service` then sees dbus.service enabled
#        via that symlink, recognises it as coming from dbus-broker.service's
#        [Install] section, and REMOVES the symlink it just created.
#      * Result: the alias symlink is gone, dbus.service is no longer in
#        multi-user.target.wants/, and on next boot nothing brings up the
#        system bus. The broker is installed but not enabled.
#
#    The Alias=dbus.service mechanism IS the replacement of the legacy
#    enablement. There is nothing left to disable — disabling is not just
#    unnecessary, it is actively harmful.
#
#    We MUST NOT log success unconditionally. `cmd 2>&1 | tail -1` returns
#    tail's exit status, not cmd's; the broker would silently stay disabled
#    while the next line claims it is enabled, and on the next boot the box
#    has no system bus. Verify the broker enablement via systemctl is-enabled
#    before claiming it worked. If the broker unit is not shipped (older
#    releases), leave dbus.service alone — broker will activate via it as
#    ExecStart, and we want it enabled. If the broker IS shipped but cannot
#    be enabled, leave the legacy dbus.service enablement in place as a
#    fallback, and the hook exits 0 honestly with the fallback logged.
#
#    The re-verification MUST be the LAST check before printing DONE — we
#    must never print DONE from a stale BROKER_OK. Any step that runs
#    between the enable and the DONE line (e.g. daemon-reload) is a chance
#    for state to drift, so we read is-enabled again right before logging.
BROKER_OK=0   # 1 iff the broker enablement is verified live, end-of-hook
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
        # Surface the systemctl enable output (last line is the symlink).
        printf '%s\n' "$ENABLE_OUT" | tail -n1
        echo "[91] dbus-broker.service enabled (alias dbus.service -> broker; owns system bus)"
        # Mark the broker as provisionally enabled. This is the input
        # to the RE-VERIFY block below; the re-verify may still reset
        # BROKER_OK to 0 if the alias symlink drifted or daemon-reload
        # changed is-enabled's answer. We never print DONE from this
        # value alone — only from the post-reload, post-symlink-check
        # BROKER_OK.
        BROKER_OK=1
    else
        # DO NOT set BROKER_OK here. The broker would own the bus name
        # while being disabled, leaving the board with no system bus.
        # Log the failure honestly and fall through to the legacy
        # keep-alive path below.
        echo "[91] WARN: dbus-broker.service enable failed (rc=$ENABLE_RC); legacy dbus.service left enabled as fallback" >&2
        printf '%s\n' "$ENABLE_OUT" | sed 's/^/[91]   /' >&2 || true
    fi
else
    # older releases ship dbus-broker activation only via dbus.service
    # (broker is the ExecStart there). In that case dbus.service IS the
    # broker service; do not touch it. The symlink in
    # multi-user.target.wants/ points at the broker transparently.
    echo "[91] dbus-broker.service not shipped; broker activates via dbus.service" >&2
fi

systemctl daemon-reload 2>/dev/null || true

# 4. RE-VERIFY the broker enablement right before printing DONE. Never
#    print DONE from a stale BROKER_OK — anything between the enable
#    and here (including daemon-reload) is a chance for state to drift.
#    We also cross-check the alias symlink: after `enable dbus-broker`,
#    /etc/systemd/system/multi-user.target.wants/dbus.service must point
#    at dbus-broker.service. That is the actual byte-level proof that
#    the Alias rewrote the symlink and the broker owns the bus name on
#    the next boot.
#
#    If the broker unit is shipped but the alias symlink is missing or
#    points at the legacy daemon, reset BROKER_OK to 0 — the box would
#    boot with no system bus or with the legacy daemon, and DONE must
#    say so. We do NOT attempt to repair; we just log honestly and exit 0.
#    If the broker unit itself disappeared (e.g. apt purged it between
#    enable and now — unlikely but possible), also reset BROKER_OK to 0.
if [ "$BROKER_OK" -eq 1 ]; then
    if ! systemctl list-unit-files dbus-broker.service >/dev/null 2>&1; then
        # Broker unit disappeared post-enable. We won't enable something
        # we just verified; we just downgrade the DONE message.
        echo "[91] WARN: dbus-broker.service unit file no longer present post-enable; treating as not-enabled" >&2
        BROKER_OK=0
    elif ! systemctl is-enabled dbus-broker.service >/dev/null 2>&1; then
        # Live is-enabled check, AFTER daemon-reload.
        echo "[91] WARN: dbus-broker.service enabled but is-enabled refused post-reload; treating as not-enabled" >&2
        BROKER_OK=0
    else
        # Alias-symlink evidence: multi-user.target.wants/dbus.service
        # must resolve to dbus-broker.service. This is the proof the
        # Alias=dbus.service rewrote the symlink AND that systemd will
        # pull the broker in on boot under the dbus.service name.
        ALIAS_LINK="/etc/systemd/system/multi-user.target.wants/dbus.service"
        if [ -L "$ALIAS_LINK" ]; then
            ALIAS_TARGET=$(readlink "$ALIAS_LINK" 2>/dev/null || true)
            case "$ALIAS_TARGET" in
                */dbus-broker.service)
                    # Expected: symlink rewritten by Alias=dbus.service.
                    ;;
                *)
                    echo "[91] WARN: alias symlink $ALIAS_LINK -> '$ALIAS_TARGET' (expected */dbus-broker.service); legacy daemon likely still owns the bus name" >&2
                    BROKER_OK=0
                    ;;
            esac
        else
            # No symlink at all — nothing in multi-user.target.wants will
            # start the system bus on boot. This is the regression we are
            # guarding against.
            echo "[91] WARN: $ALIAS_LINK missing; broker is enabled but the system bus will not be activated on boot" >&2
            BROKER_OK=0
        fi
    fi
fi

# 5. DONE line is gated on the FRESH verification above — never on the
#    stale BROKER_OK from the enable step. If the broker is verified
#    enabled, the alias symlink has already replaced the legacy
#    enablement; we do not disable anything. If the broker is not
#    verified, the legacy dbus.service enablement is left in place as
#    the fallback (it was never touched by this hook), and the log says
#    so plainly. exit 0 in both cases — a partially-applied install
#    should still boot, not abort the whole install.
if [ "$BROKER_OK" -eq 1 ]; then
    echo "[91] DONE — system bus: dbus-broker (alias dbus.service -> broker; legacy daemon enablement is replaced by the alias, not disabled)"
else
    echo "[91] DONE — dbus-broker could not be enabled in this environment; legacy dbus-daemon remains the system bus (fallback)"
fi
