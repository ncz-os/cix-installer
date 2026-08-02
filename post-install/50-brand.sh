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

RELEASE_FILE=/usr/local/lib/cix-installer/RELEASE
[ -s "$RELEASE_FILE" ] || RELEASE_FILE=/etc/cix-installer/RELEASE
if [ ! -s "$RELEASE_FILE" ]; then
    echo "[50] ERROR: release identity missing; refusing to generate inconsistent branding" >&2
    exit 1
fi
# shellcheck disable=SC1090
. "$RELEASE_FILE"
NCZ_RELEASE_LABEL="$NCZ_PRODUCT_NAME $NCZ_RELEASE_VERSION $NCZ_RELEASE_CODENAME"
[ "$RELEASE_FILE" = /etc/cix-installer/RELEASE ] || \
    install -D -m 0644 "$RELEASE_FILE" /etc/cix-installer/RELEASE
echo "[50] $NCZ_RELEASE_LABEL brand identity"

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
SKU_NAME="$NCZ_RELEASE_CODENAME"
SKU_LOWER=$(printf '%s' "$NCZ_RELEASE_CODENAME" | tr '[:upper:]' '[:lower:]')
VARIANT_LABEL="Desktop"
if [ "$VARIANT" = "server" ]; then
    VARIANT_LABEL="Server"
fi

cat > /etc/os-release <<EOF_OS
PRETTY_NAME="${NCZ_RELEASE_LABEL} ${VARIANT_LABEL} (based on ${NCZ_BASE_NAME} ${NCZ_BASE_VERSION} ${NCZ_BASE_LABEL})"
NAME="${NCZ_PRODUCT_NAME}"
VERSION_ID="${NCZ_RELEASE_VERSION}"
BUILD_ID="${BUILD_ID_VALUE}"
VERSION="${NCZ_RELEASE_VERSION} (${SKU_NAME} ${VARIANT_LABEL}; based on ${NCZ_BASE_NAME} ${NCZ_BASE_VERSION} ${NCZ_BASE_LABEL})"
VERSION_CODENAME=${SKU_LOWER}
NCZ_VARIANT=${VARIANT}
NCZ_RELEASE_VERSION="${NCZ_RELEASE_VERSION}"
NCZ_RELEASE_CODENAME="${NCZ_RELEASE_CODENAME}"
NCZ_BASE_VERSION="${NCZ_BASE_VERSION}"
ID=ncz
ID_LIKE=ubuntu
HOME_URL="https://gitlab.com/nclawzero"
SUPPORT_URL="https://gitlab.com/nclawzero/cix-installer/-/issues"
BUG_REPORT_URL="https://gitlab.com/nclawzero/cix-installer/-/issues"
UBUNTU_CODENAME=${NCZ_BASE_CODENAME}
LOGO=ncz
EOF_OS

ln -sf /etc/os-release /usr/lib/os-release 2>/dev/null || true

cat > /etc/lsb-release <<EOF_LSB
DISTRIB_ID=NCZ
DISTRIB_RELEASE=${NCZ_RELEASE_VERSION}
DISTRIB_CODENAME=${SKU_LOWER}
DISTRIB_DESCRIPTION="${NCZ_RELEASE_LABEL} ${VARIANT_LABEL} (based on ${NCZ_BASE_NAME} ${NCZ_BASE_VERSION} ${NCZ_BASE_LABEL})"
EOF_LSB

cat > /etc/issue <<EOF_ISSUE
${NCZ_RELEASE_LABEL} ${VARIANT_LABEL}  ·  Cix Sky1 / CP8180  (Kernel: \r)

EOF_ISSUE

cat > /etc/issue.net <<EOF_ISSUENET
${NCZ_RELEASE_LABEL} ${VARIANT_LABEL}  (Cix Sky1 / CP8180)

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
. /etc/cix-installer/RELEASE 2>/dev/null || true
SKU=$(. /etc/os-release 2>/dev/null; v="${VERSION_CODENAME^}"; [ "${NCZ_VARIANT:-}" = server ] && v="$v Server" || v="$v Desktop"; echo "$v")
[ -z "$SKU" ] && SKU="${NCZ_RELEASE_CODENAME:-Unknown} Desktop"
[ -n "${NCZ_PRODUCT_NAME:-}" ] || NCZ_PRODUCT_NAME="NCZ-OS"
[ -n "${NCZ_RELEASE_VERSION:-}" ] || NCZ_RELEASE_VERSION="unknown"
ROWS=(
  "  $NCZ_PRODUCT_NAME $NCZ_RELEASE_VERSION $SKU  ·  Cix Sky1 / CP8180 edge agent"
  ""
  "  Agents:  zeroclaw · openclaw · hermes · claude-code"
  "  Kernel:  $(uname -r)"
  "  GPU:     Mali-G720  (libmali GLES + OpenCL)"
  "  NPU:     Zhouyi v3  (/dev/aipu)"
  ""
  "  ✦  Workloads. Not wallpapers."
)
# Size the box to its OWN widest row instead of a hard-coded 58. The title row
# is already wider than that, and a longer kernel version can overflow too --
# row() then computes a NEGATIVE printf width, and printf left-justifies
# instead of padding, so the closing │ lands wherever the text ends and the
# frame breaks.
W=0
for _r in "${ROWS[@]}"; do
  _w=$(printf '%s' "$_r" | wc -m)
  [ "$_w" -gt "$W" ] && W="$_w"
done
W=$((W + 2))
bar(){ printf '   %s' "$1"; printf '─%.0s' $(seq 1 $W); printf '%s\n' "$2"; }
row(){ local c="$1" w; w=$(printf '%s' "$c" | wc -m); printf '   │%s%*s│\n' "$c" $((W - w)) ""; }
echo
bar '┌' '┐'
for _r in "${ROWS[@]}"; do row "$_r"; done
bar '└' '┘'
echo
BANNER
chmod 0755 /etc/update-motd.d/00-ncz-banner

echo "[50] text branding applied (os-release / issue / motd)"
