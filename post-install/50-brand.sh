#!/bin/bash
# 50-brand.sh — nclawzero distro identity (os-release, motd, hostname).
set -euo pipefail

echo "[50] nclawzero branding"

cat > /etc/os-release <<'EOF'
PRETTY_NAME="nclawzero (cixmini) 2026.05"
NAME="nclawzero"
VERSION_ID="2026.05"
VERSION="2026.05 (cixmini)"
VERSION_CODENAME=cixmini
ID=nclawzero
ID_LIKE=debian
HOME_URL="https://gitlab.com/nclawzero"
SUPPORT_URL="https://gitlab.com/nclawzero/cix-installer/-/issues"
DEBIAN_DERIVATIVE=true
EOF

# Symlink /usr/lib/os-release for tools that look there
ln -sf /etc/os-release /usr/lib/os-release || true

cat > /etc/motd <<'EOF'

   ┌─────────────────────────────────────────────────────────┐
   │  nclawzero (cixmini)  —  Cix Sky1 / CP8180 edge agent   │
   │                                                         │
   │  Agents:  zeroclaw · openclaw · hermes · claude-code    │
   │  Kernel:  linux-cix-msr1 6.6.10 (Yocto-built)           │
   │  GPU:     Mali-G720 (cix-gpu-umd)                       │
   │  NPU:     45 TOPS NoE (cix-noe-umd / cix-llama-cpp)     │
   │                                                         │
   │  Default password is the fleet factory default —        │
   │  rotate now via `sudo passwd ncz` and `sudo passwd      │
   │  root`.                                                 │
   └─────────────────────────────────────────────────────────┘

EOF

# Hostname — operator picked at install time via preseed prompt.
# Whatever they typed is in /etc/hostname; mirror it in /etc/hosts so
# sudo + apps that resolve own-host don't log "unable to resolve host"
# warnings on every invocation.
HOSTNAME=$(cat /etc/hostname 2>/dev/null | tr -d ' \t\r\n')
if [ -n "$HOSTNAME" ]; then
    grep -q "127.0.1.1.*$HOSTNAME" /etc/hosts 2>/dev/null || echo "127.0.1.1 $HOSTNAME" >> /etc/hosts
fi

# /etc/issue (login banner)
cat > /etc/issue <<'EOF'
nclawzero \r (\l)
EOF
