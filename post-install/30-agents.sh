#!/bin/bash
# 30-agents.sh — nclawzero agent stack: podman + 3 quadlet units.
#
# Installs:
#   - podman + crun + conmon + netavark + aardvark-dns (container runtime)
#   - 3 quadlet units (.container files) for zeroclaw + openclaw + hermes
#   - hermes-isolated.network (cross-bridge isolation)
#   - /etc/nclawzero/agent-env (operator-managed; placeholder ships here)
#   - nclawzero-load-agent-images.service (deferred OCI pull on boot)
#
# Quadlet auto-converts .container files into .service units at next
# systemd daemon-reload, which we trigger here.
set -euo pipefail

echo "[30] agent stack (podman + zeroclaw + openclaw + hermes)"

DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    podman crun conmon netavark aardvark-dns catatonit

# Quadlet drop-in dir
install -d -m 0755 /etc/containers/systemd
install -d -m 0750 /etc/nclawzero

ASSETS=/usr/local/lib/cix-installer/assets/agent-stack

install -m 0644 "$ASSETS/zeroclaw.container"          /etc/containers/systemd/zeroclaw.container
install -m 0644 "$ASSETS/openclaw.container"          /etc/containers/systemd/openclaw.container
install -m 0644 "$ASSETS/hermes.container"            /etc/containers/systemd/hermes.container
install -m 0644 "$ASSETS/hermes-isolated.network"     /etc/containers/systemd/hermes-isolated.network
install -m 0640 "$ASSETS/agent-env.sample"            /etc/nclawzero/agent-env

# nclawzero-load-agent-images.service — referenced by all 3 quadlets.
# v0 is a stub (defers to podman registry pull on first activation);
# can be made smarter later if we ever want to bundle OCI tarballs in
# the installer.
cat > /etc/systemd/system/nclawzero-load-agent-images.service <<'UNIT'
[Unit]
Description=Defer agent OCI image load to podman registry pull
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/true
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
systemctl enable nclawzero-load-agent-images.service

# Quadlet generation only happens at boot — daemon-reload on a chroot
# is best-effort. systemd's quadlet generator runs on first boot anyway.
systemctl daemon-reload || true
