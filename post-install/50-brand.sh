#!/bin/bash
# 50-brand.sh — NCZ 26.7 "Maximilian" identity.
#
# "Maximilian" is the RELEASE codename (26.7) — it applies to BOTH variants,
# not just desktop. The variant qualifier is just "Desktop" or "Server"
# (operator directive 2026-07-27: retired the old "Reinhardt"=desktop /
# "Magnetar"=server per-variant codename scheme — those competed with the
# release name instead of qualifying it, and confused which name was "the"
# product name).
#
# Note: NO `set -e` because pipefail + `find /missing/path | head -1` causes early exit.
# Each step is best-effort; any failure logs and continues.
set +e

echo "[50] NCZ 26.7 brand identity"

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

# Release codename is ALWAYS "Maximilian" — the variant is a qualifier, not
# a competing name. VERSION_CODENAME stays "maximilian" for both so anything
# that keys off it (update channels, the motd banner below) doesn't need to
# know about variants at all.
SKU_NAME="Maximilian"
SKU_LOWER="maximilian"
VARIANT_LABEL="Desktop"
if [ "$VARIANT" = "server" ]; then
    VARIANT_LABEL="Server"
fi

cat > /etc/os-release <<EOF_OS
PRETTY_NAME="${SKU_NAME} 26.7 ${VARIANT_LABEL} (based on Ubuntu 26.04 Resolute Raccoon)"
NAME="NCZ"
VERSION_ID="26.04"
BUILD_ID="${BUILD_ID_VALUE}"
VERSION="26.7 (${SKU_NAME} ${VARIANT_LABEL}; based on Ubuntu 26.04 Resolute Raccoon)"
VERSION_CODENAME=${SKU_LOWER}
NCZ_VARIANT=${VARIANT}
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
DISTRIB_RELEASE=26.7
DISTRIB_CODENAME=${SKU_LOWER}
DISTRIB_DESCRIPTION="${SKU_NAME} 26.7 ${VARIANT_LABEL} (based on Ubuntu 26.04 Resolute Raccoon)"
EOF_LSB

cat > /etc/issue <<EOF_ISSUE
NCZ-OS 26.7 ${SKU_NAME} ${VARIANT_LABEL}  ·  Cix Sky1 / CP8180  (Kernel: \r)

EOF_ISSUE

cat > /etc/issue.net <<EOF_ISSUENET
NCZ-OS 26.7 ${SKU_NAME} ${VARIANT_LABEL}  (Cix Sky1 / CP8180)

EOF_ISSUENET

# Login banner is generated DYNAMICALLY at login (not baked into /etc/motd) so
# the Kernel line always shows the RUNNING kernel (uname -r), never a stale
# hard-coded version. Release name + variant are read live from os-release
# too. The box uses a width-aware row() (wc -m counts display chars, not
# bytes) so every right-edge │ aligns regardless of "Maximilian Desktop" vs
# "Maximilian Server" being different lengths, or the multi-byte ┌─│┐ / · /
# — / ✦ glyphs — an old static heredoc with hard-coded trailing spaces
# skewed the title row whenever the label length changed.
: > /etc/motd
rm -f /etc/update-motd.d/00-header
cat > /etc/update-motd.d/00-ncz-banner <<'BANNER'
#!/bin/bash
# Force UTF-8 so `wc -m` counts display characters (not bytes) regardless of the
# login shell's locale — otherwise the box right-edge skews under a C/POSIX locale.
export LC_ALL=C.UTF-8
SKU=$(. /etc/os-release 2>/dev/null; v="${VERSION_CODENAME^}"; [ "${NCZ_VARIANT:-}" = server ] && v="$v Server" || v="$v Desktop"; echo "$v")
[ -z "$SKU" ] && SKU="Maximilian Desktop"
W=58
bar(){ printf '   %s' "$1"; printf '─%.0s' $(seq 1 $W); printf '%s\n' "$2"; }
row(){ local c="$1" w; w=$(printf '%s' "$c" | wc -m); printf '   │%s%*s│\n' "$c" $((W - w)) ""; }
echo
bar '┌' '┐'
row "  NCZ-OS 26.7 $SKU  ·  Cix Sky1 / CP8180 edge agent"
row ""
row "  Agents:  zeroclaw · openclaw · hermes · claude-code"
row "  Kernel:  $(uname -r)"
row "  GPU:     Mali-G720  (libmali GLES + OpenCL)"
row "  NPU:     Zhouyi v3  (/dev/aipu)"
row ""
row "  ✦  Workloads. Not wallpapers."
bar '└' '┘'
echo
BANNER
chmod 0755 /etc/update-motd.d/00-ncz-banner

echo "[50] text branding applied (os-release / issue / motd)"
