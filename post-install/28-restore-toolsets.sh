#!/bin/bash
# 28-restore-toolsets.sh — restore operator dev + testing toolset on every fresh
# cixmini flash. Idempotent: re-runnable safely after first boot.
#
# RATIONALE (2026-05-21):
#
# cixmini reflashes every few days during ncz/cix development. Each fresh image
# arrives missing the toolsets the operator + Claude/automation depend on:
#
#   1. codex CLI (Claude/automation review per CLAUDE.md directive 6) — needs node+npm
#   2. dev essentials (htop / vim / tmux / jq / ripgrep / rsync) — operator default
#   3. STUDIO ssh pubkey in mini@authorized_keys — eliminates fail2ban-bait
#      password retry dance on every reflash (per CLAUDE.md fail2ban gotcha)
#   4. Python uv (already installed by upstream cix-installer pyproject but verify)
#   5. Validated paths from MNEMOS `mem_1779327100546_354016` (NPU smoke marker)
#
# Other essential layers already covered elsewhere in cix-installer:
#   * Internet apt source                    21-internet-apt.sh
#   * CIX userspace runtime (cix-noe-umd)    25-cix-ppa.sh
#   * GPU/Mesa userspace                     26-gpu-userspace.sh
#   * telnetd + openbsd-inetd                36-telnetd.sh
#
# This script focuses on what's NOT in those.
set -uo pipefail

echo "[28] restore-toolsets — operator dev + testing layer"

# ----------------------------------------------------------------------------
# 1. STUDIO ssh pubkey for ncz-claude / Claude Code access
# ----------------------------------------------------------------------------
STUDIO_PUBKEY_HASH="claude-code-access"
STUDIO_PUBKEY_FULL=""

# Try fleet-auth-sync key store first (preferred); fall back to a baked-in copy.
FLEET_AUTH_KEY=/etc/nclawzero/keys/claude-code-access.pub
if [ -f "$FLEET_AUTH_KEY" ]; then
    STUDIO_PUBKEY_FULL="$(/usr/bin/cat "$FLEET_AUTH_KEY")"
fi

# Bootstrap fallback — STUDIO's ed25519 public component. Operator
# replaces this baked value if it ever rotates. Safe in plaintext —
# it's a PUBLIC key.
if [ -z "$STUDIO_PUBKEY_FULL" ]; then
    STUDIO_PUBKEY_FULL='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBWhvtpqz62EwigHBSXFkxGR+B7pF5B1Bl5RgWKv4F+E claude-code-access'
fi

if [ -n "$STUDIO_PUBKEY_FULL" ] && [ "${STUDIO_PUBKEY_FULL/REPLACE_WITH_BAKED_PUBKEY_FROM_STUDIO}" = "$STUDIO_PUBKEY_FULL" ]; then
    mkdir -p /home/mini/.ssh
    chmod 700 /home/mini/.ssh
    touch /home/mini/.ssh/authorized_keys
    if ! /usr/bin/grep -q "$STUDIO_PUBKEY_HASH" /home/mini/.ssh/authorized_keys 2>/dev/null; then
        echo "$STUDIO_PUBKEY_FULL" >> /home/mini/.ssh/authorized_keys
        echo "[28] added STUDIO pubkey ($STUDIO_PUBKEY_HASH) to mini@authorized_keys"
    else
        echo "[28] STUDIO pubkey already present in mini@authorized_keys"
    fi
    chmod 600 /home/mini/.ssh/authorized_keys
    chown -R mini:mini /home/mini/.ssh
else
    echo "[28] WARN: STUDIO pubkey not baked into script and no $FLEET_AUTH_KEY found"
    echo "[28]       operator must scp pubkey + run \`grep -q ... || echo >> ~/.ssh/authorized_keys\` manually"
fi

# ----------------------------------------------------------------------------
# 2. Dev essentials apt packages (idempotent)
# ----------------------------------------------------------------------------
echo "[28] installing dev essentials (htop / vim / tmux / jq / ripgrep / rsync / curl / git)"
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    htop vim tmux jq ripgrep rsync curl git \
    ca-certificates 2>&1 | /usr/bin/tail -5 || \
    echo "[28] WARN: dev-essentials apt-install incomplete"

# ----------------------------------------------------------------------------
# 3. Node.js + npm (prerequisite for codex CLI)
# ----------------------------------------------------------------------------
echo "[28] node.js + npm via NodeSource (matches PYTHIA/CERBERUS fleet pattern)"
if ! command -v node >/dev/null 2>&1; then
    /usr/bin/curl -fsSL https://deb.nodesource.com/setup_22.x | bash - 2>&1 | /usr/bin/tail -5 || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs 2>&1 | /usr/bin/tail -5 || \
        echo "[28] WARN: nodejs install failed; codex CLI install will be skipped"
fi
if command -v node >/dev/null 2>&1; then
    echo "[28] node $(node --version) / npm $(npm --version) ready"
else
    echo "[28] WARN: node still absent — codex CLI cannot install"
fi

# ----------------------------------------------------------------------------
# 4. codex CLI (per CLAUDE.md directive 6 — ChatGPT Plus sub quota)
# ----------------------------------------------------------------------------
if command -v node >/dev/null 2>&1 && ! command -v codex >/dev/null 2>&1; then
    echo "[28] installing codex CLI via npm -g @openai/codex"
    npm install -g @openai/codex 2>&1 | /usr/bin/tail -5 || \
        echo "[28] WARN: codex CLI install failed (network or perms)"
fi
if command -v codex >/dev/null 2>&1; then
    echo "[28] codex $(codex --version 2>&1 | /usr/bin/head -1) installed"
    echo "[28] OPERATOR NOTE: run \`codex login\` once to bind ChatGPT Plus OAuth"
else
    echo "[28] WARN: codex CLI not on PATH after install attempt"
fi

# ----------------------------------------------------------------------------
# 5. Python uv (Python project manager — used by InvestorClaw / RiskyEats /
#    everything that runs in a uv-managed venv)
# ----------------------------------------------------------------------------
if ! command -v uv >/dev/null 2>&1; then
    echo "[28] installing uv (Python project manager)"
    /usr/bin/curl -LsSf https://astral.sh/uv/install.sh | bash 2>&1 | /usr/bin/tail -3 || \
        echo "[28] WARN: uv install failed"
fi
if [ -x /home/mini/.local/bin/uv ] && [ ! -e /usr/local/bin/uv ]; then
    ln -sf /home/mini/.local/bin/uv /usr/local/bin/uv 2>/dev/null || true
fi
command -v uv >/dev/null 2>&1 && echo "[28] uv $(uv --version | /usr/bin/head -1) ready"

# ----------------------------------------------------------------------------
# 6. Stamp the restore-toolsets state file for idempotent re-runs
# ----------------------------------------------------------------------------
STAMP=/var/lib/nclawzero/restore-toolsets.stamp
mkdir -p "$(dirname "$STAMP")"
{
    echo "restored_at=$(date -Iseconds)"
    echo "script_version=2026-05-21-r1"
    echo "node=$(node --version 2>/dev/null || echo absent)"
    echo "npm=$(npm --version 2>/dev/null || echo absent)"
    echo "codex=$(codex --version 2>&1 | /usr/bin/head -1 || echo absent)"
    echo "uv=$(uv --version 2>/dev/null || echo absent)"
    echo "git=$(git --version 2>/dev/null || echo absent)"
} > "$STAMP"
echo "[28] toolset state stamped at $STAMP"

echo "[28] restore-toolsets complete — operator dev + testing layer ready"
exit 0
