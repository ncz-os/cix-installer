#!/bin/bash
# 32-quadlet-shim.sh — historically translated quadlet → .service for podman 4.3.
# r61/r78: Ubuntu resolute ships Podman with native Quadlet support.
# The shim's generated .service files now override the quadlet generator
# at /run/systemd/generator/, breaking sed-applied fixes in 30-agents.sh
# (specifically hermes Network rename + --insecure flag).
# This hook is now a no-op. Quadlet generator handles .container files natively.
set +e
PODMAN_VER=$(podman --version 2>/dev/null | awk '{print $3}' | cut -d. -f1,2)
if [ -n "$PODMAN_VER" ]; then
    case "$PODMAN_VER" in
        4.3|4.[012]|3.*|2.*|1.*)
            echo '[32] podman '$PODMAN_VER' (pre-4.4) — would need shim, but skipping'
            ;;
        *)
            echo '[32] podman '$PODMAN_VER' has native Quadlet — shim is no-op'
            ;;
    esac
else
    echo '[32] podman not detected — skip'
fi
exit 0
