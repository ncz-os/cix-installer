#!/bin/bash
# 27-net-caps.sh - restore cap_net_raw on ping (iputils). Without it, ping
# fails with "socket: Operation not permitted" for non-root users. Some rootfs
# builds strip the file capability; re-apply it deterministically.
set -euo pipefail
echo "[27] net capabilities (ping cap_net_raw)"
for p in /usr/bin/ping /bin/ping; do
    [ -e "$p" ] || continue
    setcap cap_net_raw+ep "$p" 2>/dev/null && echo "[27] setcap cap_net_raw+ep $p" || echo "[27] WARN: setcap failed on $p"
done
