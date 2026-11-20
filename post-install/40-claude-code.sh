#!/bin/bash
# 40-claude-code.sh — install Claude Code CLI (Anthropic's agent dev tool).
#
# Per project policy, Claude is **NOT** wired in as an LLM provider for
# the nclawzero agents (against Anthropic ToS for agent-runtime use). It
# IS available as an operator-side dev CLI — for the human at the keyboard
# to write code, not for runtime inference. Different scope.
#
# Installed via `npm install -g` so it picks up new releases via apt-free
# `npm update -g @anthropic-ai/claude-code` cadence.
set -euo pipefail

# NCZ_CLAUDE_ROOT: fake-root seam for build/test-claude-code-deferred.sh.
# Empty in a real chroot install (paths are absolute target paths).
R="${NCZ_CLAUDE_ROOT:-}"
SVC="$R/etc/systemd/system/ncz-claude-code-install.service"
WANTS="$R/etc/systemd/system/multi-user.target.wants/ncz-claude-code-install.service"
HELPER="$R/usr/local/sbin/ncz-claude-code-install"
PENDING="$R/var/lib/ncz/claude-code.pending"
DONE="$R/var/lib/ncz/claude-code.done"

echo "[40] Claude Code CLI substrate"

timeout 300 env DEBIAN_FRONTEND=noninteractive \
    apt-get install -y --no-install-recommends nodejs npm

ncz_claude_cleanup_stale() {
    rm -f "$SVC" "$WANTS" "$HELPER" "$PENDING"
}

ncz_claude_arm_retry() {
    mkdir -p "$(dirname "$SVC")" "$(dirname "$WANTS")" "$(dirname "$HELPER")" "$(dirname "$PENDING")"
    cat > "$HELPER" <<'HELPEOF'
#!/bin/sh
# ncz-claude-code-install — first-boot retry for the Claude Code CLI.
# Staged by post-install/40-claude-code.sh when the chroot npm install
# fails (offline install). Bounded retries with doubling backoff; records
# /var/lib/ncz/claude-code.done and disables its own unit on success so
# the retry stops firing. Exits nonzero while the CLI is still missing so
# a caller can tell "not yet" from "installed".
set -eu
R="${NCZ_CLAUDE_ROOT:-}"
TRIES="${NCZ_CLAUDE_MAX_TRIES:-5}"
WAIT="${NCZ_CLAUDE_RETRY_WAIT:-60}"
PENDING="$R/var/lib/ncz/claude-code.pending"
DONE="$R/var/lib/ncz/claude-code.done"
n=0
wait_s="$WAIT"
while [ "$n" -lt "$TRIES" ]; do
    n=$(( n + 1 ))
    if timeout 180 npm install -g @anthropic-ai/claude-code; then
        mkdir -p "$(dirname "$DONE")"
        : > "$DONE"
        rm -f "$PENDING"
        systemctl disable ncz-claude-code-install.service >/dev/null 2>&1 || true
        echo "claude-code installed on attempt $n"
        exit 0
    fi
    if [ "$n" -lt "$TRIES" ]; then
        sleep "$wait_s"
        wait_s=$(( wait_s * 2 ))
        [ "$wait_s" -gt 1800 ] && wait_s=1800
    fi
done
echo "claude-code install still failing after $TRIES attempts; will retry on next boot" >&2
exit 1
HELPEOF
    chmod 0755 "$HELPER"
    cat > "$SVC" <<'SVCEOF'
[Unit]
Description=NCZ-OS Claude Code CLI deferred install (first-boot retry)
After=network-online.target nss-lookup.target
Wants=network-online.target
# Staged only when the chroot npm install failed; the helper removes the
# done marker's absence by writing it on success and disables this unit.
ConditionPathExists=!/var/lib/ncz/claude-code.done

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/ncz-claude-code-install
TimeoutStartSec=30min
Nice=10
IOSchedulingClass=idle

[Install]
WantedBy=multi-user.target
SVCEOF
    if ! systemctl enable ncz-claude-code-install.service >/dev/null 2>&1; then
        ln -sf ../ncz-claude-code-install.service "$WANTS"
    fi
    : > "$PENDING"
}

# claude-code
# Network-dependent — if no network in chroot, log and continue, and arm
# the first-boot retry so the CLI still arrives once the network is up.
if timeout 180 npm install -g @anthropic-ai/claude-code; then
    echo "claude-code installed: $(claude --version 2>/dev/null || echo unknown)"
    ncz_claude_cleanup_stale
else
    echo "WARN: claude-code npm install deferred to first boot (network during"
    echo "      chroot install was unavailable). ncz-claude-code-install.service"
    echo "      will retry after boot; or run 'sudo npm install -g"
    echo "      @anthropic-ai/claude-code' manually."
    ncz_claude_arm_retry
fi
