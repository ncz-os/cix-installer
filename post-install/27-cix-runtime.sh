#!/bin/bash
# 27-cix-runtime.sh — verify Cix NPU userspace runtime + write the
# MNEMOS auto-detect env file.
#
# Runs AFTER 25-cix-proprietary.sh (which apt-installs cix-noe-umd +
# libnoe from the apt repo) and BEFORE 47-embedkit.sh (which sets up
# the embedkit venv + bench harness).
#
# This hook is the runtime *contract* layer: it asserts the userspace
# pieces are installed at a known-good version, fingerprints what
# landed, and writes /etc/nclawzero/embed.env so MNEMOS can auto-detect
# the NPU on first boot without having to scan dpkg state.
#
# /etc/nclawzero/embed.env shape (sourced by MNEMOS at startup):
#   EMBEDKIT_NPU=available|missing
#   EMBEDKIT_NPU_DRIVER_VERSION=<cix-noe-umd dpkg version>
#   EMBEDKIT_LIBNOE_VERSION=<libnoe dpkg version>
#   EMBEDKIT_MODELS_DIR=/opt/ncz/models
#   EMBEDKIT_DEFAULT_MODEL=bge-small-zh-v1.5
#   EMBEDKIT_DEFAULT_TIER=npu-cix
#
# MNEMOS reads these on startup to skip the cold-probe path; without
# the file, MNEMOS still works but has to dpkg-query + filesystem-stat
# on every cold start.
set -uo pipefail

echo "[27] Cix NPU userspace runtime contract"

# ----------------------------------------------------------------------
# 1. Verify cix-noe-umd + libnoe are present (25-cix-proprietary should
#    have installed them; if not, log loudly so the operator notices
#    BEFORE 47-embedkit tries to import libnoe).
# ----------------------------------------------------------------------
runtime_ok=1
for pkg in cix-noe-umd libnoe; do
    status=$(dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null || true)
    if [ "$status" = "install ok installed" ]; then
        version=$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null || echo "?")
        echo "[27]   $pkg installed: $version"
    else
        echo "[27]   WARN: $pkg NOT installed (status=$status). 25-cix-proprietary skipped or failed for this package."
        runtime_ok=0
    fi
done

# ----------------------------------------------------------------------
# 2. /dev/aipu sanity — present on Sky1 once aipu.ko loads. Not present
#    in chroot during late_command (no kernel modules) — that's fine;
#    we just record current state.
# ----------------------------------------------------------------------
if [ -c /dev/aipu ]; then
    echo "[27]   /dev/aipu present"
    AIPU_PRESENT=1
else
    echo "[27]   /dev/aipu not present at this build stage (normal in chroot)"
    AIPU_PRESENT=0
fi

# ----------------------------------------------------------------------
# 3. Models dir scaffold (47-embedkit fills it; this hook just lays
#    down the directory so MNEMOS' env file points at a real path).
# ----------------------------------------------------------------------
install -d -m 0755 /opt/ncz/models

# ----------------------------------------------------------------------
# 4. Write /etc/nclawzero/embed.env for MNEMOS auto-detect.
# ----------------------------------------------------------------------
install -d -m 0755 /etc/nclawzero

CIX_NOE_VER=$(dpkg-query -W -f='${Version}' cix-noe-umd 2>/dev/null || echo unknown)
LIBNOE_VER=$(dpkg-query -W -f='${Version}' libnoe 2>/dev/null || echo unknown)

if [ "$runtime_ok" -eq 1 ]; then
    NPU_STATE=available
    DEFAULT_TIER=npu-cix
else
    # Runtime missing — MNEMOS will fall back to GGUF/Vulkan on first
    # boot. embed.env records the fall-back stance explicitly so the
    # operator doesn't get a surprise auto-tier escalation if a later
    # apt run lands cix-noe-umd.
    NPU_STATE=missing
    DEFAULT_TIER=cpu-llamacpp
fi

cat > /etc/nclawzero/embed.env <<EOF
# /etc/nclawzero/embed.env — MNEMOS auto-detect cache for the embedding tier.
# Written by cix-installer/post-install/27-cix-runtime.sh at install time.
# Operator can rewrite manually if hardware changes (NPU added/removed
# post-flash); otherwise MNEMOS re-verifies on each cold start.
EMBEDKIT_NPU=${NPU_STATE}
EMBEDKIT_NPU_DRIVER_VERSION=${CIX_NOE_VER}
EMBEDKIT_LIBNOE_VERSION=${LIBNOE_VER}
EMBEDKIT_AIPU_DEV_AT_INSTALL=${AIPU_PRESENT}
EMBEDKIT_MODELS_DIR=/opt/ncz/models
EMBEDKIT_DEFAULT_MODEL=bge-small-zh-v1.5
EMBEDKIT_DEFAULT_TIER=${DEFAULT_TIER}
EMBEDKIT_INSTALL_TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
chmod 0644 /etc/nclawzero/embed.env

echo "[27] wrote /etc/nclawzero/embed.env (npu=${NPU_STATE} default_tier=${DEFAULT_TIER})"
cat /etc/nclawzero/embed.env | sed 's/^/    /'

exit 0
