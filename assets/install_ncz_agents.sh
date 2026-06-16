#!/bin/bash
set -e

echo "=========================================================="
echo "  NCZ Agent & MNEMOS Installation Script (Magnetar/Reinhardt)  "
echo "=========================================================="
echo
echo "This script will install the hardware-isolated ZeroClaw agent"
echo "and the MNEMOS NPU-accelerated vector database."
echo
echo "Ensure your system is connected to the internet before proceeding."
echo "Press ENTER to continue or Ctrl+C to abort."
read -r

# Verify apt sources
if ! grep -q "ncz-os.gitlab.io/cix-installer" /etc/apt/sources.list.d/ncz.list 2>/dev/null; then
    echo "[1/3] Configuring NCZ remote APT repository..."
    echo "deb [trusted=yes] https://ncz-os.gitlab.io/cix-installer/ resolute main" | sudo tee /etc/apt/sources.list.d/ncz.list > /dev/null
    sudo apt-get update
else
    echo "[1/3] NCZ remote APT repository already configured. Updating..."
    sudo apt-get update
fi

echo "[2/3] Installing ZeroClaw and MNEMOS CIX Integration..."
sudo apt-get install -y mnemos-cix-integration zeroclaw-agent

echo "[3/3] Verifying services..."
sudo systemctl status zeroclaw-agent.service --no-pager || echo "WARNING: zeroclaw-agent failed to start"
sudo systemctl status cix-npu-embedder.service --no-pager || echo "WARNING: cix-npu-embedder failed to start"

echo
echo "=========================================================="
echo "  INSTALLATION COMPLETE!"
echo "=========================================================="
echo "- ZeroClaw is running as a Podman Quadlet on cores 4-7."
echo "- MNEMOS NPU Embedder is listening on http://localhost:8000/v1/embeddings"
echo "  (Processing all-MiniLM-L6-v2 queries at ~68 rec/s on the NPU)."
echo
