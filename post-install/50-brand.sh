#!/bin/bash
# 50-brand.sh — NCZ 26.6 "Reinhardt" / "Magnetar" identity
# Note: NO `set -e` because pipefail + `find /missing/path | head -1` causes early exit.
# Each step is best-effort; any failure logs and continues.
set +e

echo "[50] NCZ 26.6 brand identity"

BUILD_ID_VALUE=""
if [ -f /usr/local/lib/cix-installer/BUILD_VERSION ]; then
    BUILD_ID_VALUE=$(tr -cd 'A-Za-z0-9._-' < /usr/local/lib/cix-installer/BUILD_VERSION)
fi
if [ -z "$BUILD_ID_VALUE" ] && [ -f /etc/cix-installer/BUILD_VERSION ]; then
    BUILD_ID_VALUE=$(tr -cd 'A-Za-z0-9._-' < /etc/cix-installer/BUILD_VERSION)
fi
[ -z "$BUILD_ID_VALUE" ] && BUILD_ID_VALUE=unknown

VARIANT_FILE=/usr/local/lib/cix-installer/BUILD_VARIANT
VARIANT="desktop"
if [ -f "$VARIANT_FILE" ]; then
    VARIANT=$(tr -d ' \t\r\n' < "$VARIANT_FILE")
fi

SKU_NAME="Reinhardt"
SKU_LOWER="reinhardt"
if [ "$VARIANT" = "server" ]; then
    SKU_NAME="Magnetar"
    SKU_LOWER="magnetar"
fi

cat > /etc/os-release <<EOF_OS
PRETTY_NAME="${SKU_NAME} 26.6 (based on Ubuntu 26.04 Resolute Raccoon)"
NAME="NCZ"
VERSION_ID="26.04"
BUILD_ID="${BUILD_ID_VALUE}"
VERSION="26.6 (${SKU_NAME}; based on Ubuntu 26.04 Resolute Raccoon)"
VERSION_CODENAME=${SKU_LOWER}
ID=ncz
ID_LIKE=ubuntu
HOME_URL="https://gitlab.com/nclawzero"
SUPPORT_URL="https://gitlab.com/nclawzero/cix-installer/-/issues"
BUG_REPORT_URL="https://gitlab.com/nclawzero/cix-installer/-/issues"
UBUNTU_CODENAME=resolute
LOGO=ncz
EOF_OS

ln -sf /etc/os-release /usr/lib/os-release 2>/dev/null || true

cat > /etc/lsb-release <<EOF_LSB
DISTRIB_ID=NCZ
DISTRIB_RELEASE=26.6
DISTRIB_CODENAME=${SKU_LOWER}
DISTRIB_DESCRIPTION="${SKU_NAME} 26.6 (based on Ubuntu 26.04 Resolute Raccoon)"
EOF_LSB

cat > /etc/issue <<EOF_ISSUE
NCZ 26.6 "${SKU_NAME}"  ·  Cix Sky1 / CP8180  (Kernel: \r)

EOF_ISSUE

cat > /etc/issue.net <<EOF_ISSUENET
NCZ 26.6 "${SKU_NAME}"  (Cix Sky1 / CP8180)

EOF_ISSUENET

cat > /etc/motd <<MOTD

   ┌─────────────────────────────────────────────────────────┐
   │  NCZ 26.6 "${SKU_NAME}"  —  Cix Sky1 / CP8180 edge agent  │
   │                                                         │
   │  Agents:  zeroclaw · openclaw · hermes · claude-code    │
   │  Kernel:  linux-cix-sky1 7.0.12-next (Yocto-built)      │
   │  GPU:     Mali-G720  (Mesa Zink+PanVK accel)            │
   │  NPU:     Zhouyi v3  (3 cores · 12 TECs · /dev/aipu)    │
   │                                                         │
   │  ✦  Workloads. Not wallpapers.                          │
   └─────────────────────────────────────────────────────────┘

MOTD

cat > /etc/update-motd.d/00-header <<HEADER
#!/bin/sh
printf "\\nNCZ 26.6 \\"${SKU_NAME}\\"  (GNU/Linux %s %s)\\n" "\$(uname -r)" "\$(uname -m)"
printf "  Cix Sky1 / CP8180 \\n\\n"
HEADER
chmod 0755 /etc/update-motd.d/00-header

echo "[50] text branding applied (os-release / issue / motd)"
