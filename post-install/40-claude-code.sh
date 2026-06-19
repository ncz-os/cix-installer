#!/bin/bash
# 40-claude-code.sh — install Claude Code CLI (Anthropic's agent dev tool).
#
# Per fleet directive, Claude is **NOT** wired in as an LLM provider for
# the nclawzero agents (against Anthropic ToS for agent-runtime use). It
# IS available as an operator-side dev CLI — for the human at the keyboard
# to write code, not for runtime inference. Different scope.
#
# Installed via `npm install -g` so it picks up new releases via apt-free
# `npm update -g @anthropic-ai/claude-code` cadence.
set -euo pipefail

echo "[40] Claude Code CLI substrate"

DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    nodejs npm

# claude-code
# Network-dependent — if no network in chroot, log and continue. The CLI
# can be apt'd or npm'd post-boot if this fails.
if npm install -g @anthropic-ai/claude-code; then
    echo "claude-code installed: $(claude --version 2>/dev/null || echo unknown)"
else
    echo "WARN: claude-code npm install deferred to first boot (network during"
    echo "      chroot install was unavailable). Run 'sudo npm install -g"
    echo "      @anthropic-ai/claude-code' after first boot."
fi
