#!/bin/bash
# 89-npu-embed-server.sh — OpenAI-compatible /v1/embeddings served from the
# Zhouyi NPU, so MNEMOS (or anything speaking that API) gets embeddings off a
# dedicated accelerator instead of burning CPU cores.
#
# Validated on O6N 2026-08-05, nomic-embed-text-v1.5 compiled to a NOE graph:
#   * 768-dim vectors, cosine 0.995330 vs the onnxruntime CPU reference on
#     identical tokens -- i.e. interchangeable with x86 MNEMOS vectors, so
#     federation needs no translation layer between Sky1 and x86 peers.
#   * 8.9 inf/s (112 ms). Not fast in absolute terms, but every query is
#     imperceptible and a full re-index of a 13k-memory corpus is ~25 min,
#     while 12 CPU cores stay free -- which is the point on a 40-100W box.
#
# Why the NPU and not the GPU: measured on this hardware, the Mali GPU loses
# to the CPU for inference even when Vulkan genuinely engages it (confirmed
# via /dev/mali0 fd), and the community reports the same. See
# docs/DRIVER_FIDELITY_72.md. The NPU is the only real offload here.
#
# Runs AFTER 88-noe-umd-venv.sh (needs /opt/ncz/noe-venv + libnoe).
set -euo pipefail

VENV=/opt/ncz/noe-venv
MODEL=/opt/ncz/models/nomic-embed-text-v1.5_256.cix
SERVER=/usr/local/bin/ncz-npu-embed-server.py
ASSETS=/usr/local/lib/cix-installer/assets

echo "[89] NPU embedding server (OpenAI /v1/embeddings)"

VARIANT=desktop
[ -f /usr/local/lib/cix-installer/BUILD_VARIANT ] && \
    VARIANT=$(tr -d ' \t\r\n' < /usr/local/lib/cix-installer/BUILD_VARIANT)

if [ ! -x "$VENV/bin/python" ]; then
    echo "[89]   $VENV absent (88-noe-umd-venv did not run or failed) — skipping"
    exit 0
fi

# The server binary is staged by the ISO; tolerate its absence on netinstall.
if [ -f "$ASSETS/npu/ncz-npu-embed-server.py" ]; then
    install -m0755 "$ASSETS/npu/ncz-npu-embed-server.py" "$SERVER"
    echo "[89]   installed $SERVER"
else
    echo "[89]   server script not staged — skipping"
    exit 0
fi

# transformers provides the tokenizer. The NPU venv is CPython 3.12 (the
# cix-noe-umd wheels pin <3.13), so this cannot come from the system python.
if ! "$VENV/bin/python" -c "import transformers" 2>/dev/null; then
    echo "[89]   installing transformers into the NPU venv"
    "$VENV/bin/pip" install -q transformers 2>&1 | tail -2 || \
        echo "[89]   WARN: transformers install failed; server will not start until it is present"
fi

# The .cix graph is large (~500MB) and only ships when staged.
if [ -f "$ASSETS/models/nomic-embed-text-v1.5_256.cix" ]; then
    install -d -m0755 /opt/ncz/models
    install -m0644 "$ASSETS/models/nomic-embed-text-v1.5_256.cix" "$MODEL"
    echo "[89]   installed $(basename "$MODEL")"
fi

cat > /etc/systemd/system/ncz-npu-embed.service <<'UNIT'
[Unit]
Description=NCZ NPU embedding server (OpenAI /v1/embeddings on Zhouyi NPU)
Documentation=file:///usr/share/doc/ncz/DRIVER_FIDELITY_72.md
After=network.target
# The NPU char device must exist; without it the graph load fails and the
# service would restart-loop.
ConditionPathExists=/dev/aipu

[Service]
Type=simple
ExecStart=/opt/ncz/noe-venv/bin/python /usr/local/bin/ncz-npu-embed-server.py --host 127.0.0.1 --port 8081
Restart=on-failure
RestartSec=10
# Model load is ~15s; do not let systemd think that is a hang.
TimeoutStartSec=120
Nice=0

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload 2>/dev/null || true

# Enable only when the model is actually present -- an enabled service with no
# graph is a boot-time error every single boot for no benefit.
if [ -f "$MODEL" ]; then
    systemctl enable ncz-npu-embed.service 2>/dev/null || true
    echo "[89]   service enabled (listens on 127.0.0.1:8081)"
else
    echo "[89]   model absent — unit installed but left DISABLED"
    echo "[89]   to enable: place the .cix at $MODEL then 'systemctl enable --now ncz-npu-embed'"
fi

echo "[89] done"
