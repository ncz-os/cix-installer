#!/bin/bash
# test-rescue-network-owner.sh - execute the ACTUAL production
# post-install/35-ssh.sh hook inside a disposable Forky container root
# and assert, via real systemctl offline enable/reenable symlink
# semantics (not string grep), that:
#
#   native case:   ssh.service enabled for multi-user AND rescue;
#                  native Sinty unit enabled for multi-user AND
#                  rescue; NM/networkd masks preserved (not unmasked).
#   fallback case: ssh.service enabled for multi-user AND rescue;
#                  NM + networkd enabled for rescue (existing
#                  behavior preserved).
#
# Fail-closed guards: requires NCZ_RUN_DISPOSABLE_RESCUE_TESTS=1, a
# container marker (/run/.containerenv or /.dockerenv), root UID, and
# PID 1 NOT systemd. All writes stay inside the disposable container.
#
# Optional env HOOK_UNDER_TEST=/path/to/35-ssh.sh drives a negative
# case against an older hook (which lacks native rescue activation).
#
# Usage: NCZ_RUN_DISPOSABLE_RESCUE_TESTS=1 \
#          build/test-rescue-network-owner.sh native|fallback
set -euo pipefail

case "${1:-}" in
    native|fallback) CASE="$1" ;;
    *) echo "usage: $0 native|fallback" >&2; exit 2 ;;
esac

[ "${NCZ_RUN_DISPOSABLE_RESCUE_TESTS:-0}" = "1" ] \
    || { echo "refusing: set NCZ_RUN_DISPOSABLE_RESCUE_TESTS=1" >&2; exit 2; }
[ -e /run/.containerenv ] || [ -e /.dockerenv ] \
    || { echo "refusing: not inside a container" >&2; exit 2; }
[ "$(id -u)" = "0" ] || { echo "refusing: not root" >&2; exit 2; }
[ "$(ps -p 1 -o comm= 2>/dev/null || echo unknown)" != "systemd" ] \
    || { echo "refusing: PID 1 is systemd" >&2; exit 2; }

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="${HOOK_UNDER_TEST:-$REPO_ROOT/post-install/35-ssh.sh}"
[ -r "$HOOK" ] || { echo "hook not readable: $HOOK" >&2; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Private PATH with a stub apt-get only. Everything else (systemctl,
# install, mkdir, cat, awk, grep) is the real thing.
STUB="$WORK/stub"
mkdir -p "$STUB"
cat > "$STUB/apt-get" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$STUB/apt-get"
export PATH="$STUB:$PATH"

# Vendor units live under /usr/lib/systemd/system so that
# `systemctl mask` can install /etc/systemd/system/<unit> -> /dev/null
# symlinks without colliding with the fixture unit files themselves.
# Assertions still look at /etc/systemd/system (where enable/reenable
# and mask create their symlinks).
VENDORDIR=/usr/lib/systemd/system
mkdir -p "$VENDORDIR"
UNITDIR=/etc/systemd/system
mkdir -p "$UNITDIR"

cat > "$VENDORDIR/ssh.service" <<'EOF'
[Unit]
Description=OpenSSH server
[Service]
ExecStart=/usr/sbin/sshd -D
[Install]
WantedBy=multi-user.target
EOF

cat > "$VENDORDIR/ssh.socket" <<'EOF'
[Unit]
Description=OpenSSH socket
[Socket]
ListenStream=22
[Install]
WantedBy=sockets.target
EOF

cat > "$VENDORDIR/NetworkManager.service" <<'EOF'
[Unit]
Description=NetworkManager
[Service]
ExecStart=/usr/sbin/NetworkManager --no-daemon
[Install]
WantedBy=multi-user.target
EOF

cat > "$VENDORDIR/systemd-networkd.service" <<'EOF'
[Unit]
Description=systemd-networkd
[Service]
ExecStart=/lib/systemd/systemd-networkd
[Install]
WantedBy=multi-user.target
EOF

# Canonical Sinty unit: copy the actual production asset so the test
# exercises the same unit text the image ships. Do NOT duplicate the
# unit body here.
SINTY_UNIT_SRC="$REPO_ROOT/assets/sinty-nm/sinty-nm.service"
[ -r "$SINTY_UNIT_SRC" ] \
    || { echo "missing canonical unit: $SINTY_UNIT_SRC" >&2; exit 2; }
cp "$SINTY_UNIT_SRC" "$VENDORDIR/sinty-nm.service"

# Fake executable daemon fixture so the hook's -x probe succeeds.
mkdir -p /usr/bin
cat > /usr/bin/sinty-nmd <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x /usr/bin/sinty-nmd

if [ "$CASE" = "fallback" ]; then
    # Simulate non-Sinty SKU: no native daemon present.
    rm -f /usr/bin/sinty-nmd
fi

# Pre-seed the state 19-sinty-nm would leave on a native SKU: NM and
# networkd masked. On fallback SKU they are unmasked and enabled.
# Assert the mask actually took effect - a silent failure here would
# make the "masks preserved" assertion below vacuous.
if [ "$CASE" = "native" ]; then
    systemctl mask NetworkManager.service \
        || { echo "fixture: failed to mask NetworkManager.service" >&2; exit 2; }
    systemctl mask systemd-networkd.service \
        || { echo "fixture: failed to mask systemd-networkd.service" >&2; exit 2; }
    [ "$(readlink -f "$UNITDIR/NetworkManager.service")" = "/dev/null" ] \
        || { echo "fixture: NetworkManager.service mask not installed" >&2; exit 2; }
    [ "$(readlink -f "$UNITDIR/systemd-networkd.service")" = "/dev/null" ] \
        || { echo "fixture: systemd-networkd.service mask not installed" >&2; exit 2; }
    # Simulate the state 19-sinty-nm leaves on a native SKU: it enables
    # sinty-nm.service for multi-user BEFORE 35 runs. Without this, the
    # normal multi-user link would be absent and the negative case below
    # would fail for the wrong reason (missing normal, not missing rescue).
    systemctl enable sinty-nm.service \
        || { echo "fixture: failed to enable sinty-nm.service" >&2; exit 2; }
    [ -L "$UNITDIR/multi-user.target.wants/sinty-nm.service" ] \
        || { echo "fixture: sinty-nm.service not enabled for multi-user" >&2; exit 2; }
fi

# Execute the ACTUAL production hook.
bash "$HOOK"

fail() { echo "FAIL[$CASE]: $*" >&2; exit 1; }

link_exists() { [ -L "$1" ]; }

# --- ssh.service: multi-user + rescue ---
link_exists "$UNITDIR/multi-user.target.wants/ssh.service" \
    || fail "ssh.service not enabled for multi-user.target"
link_exists "$UNITDIR/rescue.target.wants/ssh.service" \
    || fail "ssh.service not enabled for rescue.target"

# --- ssh.socket: multi-user (sockets.target) only ---
# Production intentionally enables ssh.service in rescue.target; the
# socket unit is only pulled by sockets.target. Do not assert a
# rescue.target.wants/ssh.socket link.
link_exists "$UNITDIR/sockets.target.wants/ssh.socket" \
    || fail "ssh.socket not enabled for sockets.target"

if [ "$CASE" = "native" ]; then
    # Native Sinty unit must be enabled for BOTH multi-user and rescue.
    link_exists "$UNITDIR/multi-user.target.wants/sinty-nm.service" \
        || fail "sinty-nm.service not enabled for multi-user.target"
    link_exists "$UNITDIR/rescue.target.wants/sinty-nm.service" \
        || fail "sinty-nm.service not enabled for rescue.target"

    # NM/networkd masks must remain in place (not unmasked).
    [ "$(readlink -f "$UNITDIR/NetworkManager.service")" = "/dev/null" ] \
        || fail "NetworkManager.service mask was removed on native SKU"
    [ "$(readlink -f "$UNITDIR/systemd-networkd.service")" = "/dev/null" ] \
        || fail "systemd-networkd.service mask was removed on native SKU"
else
    # Fallback: existing NM/networkd rescue enablement preserved.
    link_exists "$UNITDIR/rescue.target.wants/NetworkManager.service" \
        || fail "NetworkManager.service not enabled for rescue.target (fallback)"
    link_exists "$UNITDIR/rescue.target.wants/systemd-networkd.service" \
        || fail "systemd-networkd.service not enabled for rescue.target (fallback)"
fi

echo "PASS[$CASE]: hook=$HOOK"
