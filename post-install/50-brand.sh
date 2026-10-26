#!/bin/bash
# NCZ-MIXED-HOOK: branding generic; issue SOC label detects Sky1 via uname/cpuinfo (line ~117) (docs/platform-inventory.tsv; runs on every platform, listed in both hooks.list files)
# 50-brand.sh — NCZ-OS release identity (product, version and codename
# from release.conf, e.g. 26.10 "Cygnus").
#
# The RELEASE codename applies to BOTH variants, not just desktop. The
# variant qualifier is just "Desktop" or "Server" (2026-07-27: retired the
# old per-variant codename scheme — those competed with the release name
# instead of qualifying it, and confused which name was "the" product name).
#
# Note: NO `set -e` because pipefail + `find /missing/path | head -1` causes early exit.
# Each step is best-effort; any failure logs and continues.
set +e

RELEASE_FILE=/usr/local/lib/cix-installer/RELEASE
[ -s "$RELEASE_FILE" ] || RELEASE_FILE=/etc/cix-installer/RELEASE
# Test seam (build/test-release-identity.sh): read this release file and
# print the os-release identity strings instead of writing anything.
[ -n "${NCZ_BRAND_PRINT_IDENTITY:-}" ] && RELEASE_FILE="$NCZ_BRAND_PRINT_IDENTITY"
if [ ! -s "$RELEASE_FILE" ]; then
    echo "[50] ERROR: release identity missing; refusing to generate inconsistent branding" >&2
    exit 1
fi
# shellcheck disable=SC1090
. "$RELEASE_FILE"
NCZ_RELEASE_LABEL="$NCZ_PRODUCT_NAME $NCZ_RELEASE_VERSION $NCZ_RELEASE_CODENAME"
# The base system in one phrase. NCZ_BASE_LABEL already names the
# distribution, suite and codename ("Debian Testing (Forky)"); only build
# it from the parts when a release file has no label.
NCZ_BASE_DESCRIPTION="${NCZ_BASE_LABEL:-$NCZ_BASE_NAME $NCZ_BASE_VERSION}"
[ -n "${NCZ_BRAND_PRINT_IDENTITY:-}" ] || [ "$RELEASE_FILE" = /etc/cix-installer/RELEASE ] || \
    install -D -m 0644 "$RELEASE_FILE" /etc/cix-installer/RELEASE
# MAGNETAR SERVER: which medium this install came from (MEDIUM_VARIANT=server, written by
# preseed/late.sh; post-install/lib/ncz-brand.sh decides). Used below for the server identity.
MEDIUM_VARIANT=desktop
_ncz_brand_lib="$(dirname "$0")/lib/ncz-brand.sh"
[ -r "$_ncz_brand_lib" ] || _ncz_brand_lib=/usr/local/lib/cix-installer/post-install/lib/ncz-brand.sh
if [ -r "$_ncz_brand_lib" ] && . "$_ncz_brand_lib"; then
    if [ -n "${NCZ_BRAND_PRINT_IDENTITY:-}" ]; then
        # Test seam: the medium comes from NCZ_BRAND_MEDIUM (default desktop),
        # never from the host running the test.
        MEDIUM_VARIANT="${NCZ_BRAND_MEDIUM:-desktop}"
    else
        MEDIUM_VARIANT=$(ncz_brand_medium_variant /usr/local/lib/cix-installer)
    fi
elif [ -r /usr/local/lib/cix-installer/MEDIUM_VARIANT ]; then
    echo "[50] WARN: no post-install/lib/ncz-brand.sh; a Magnetar Server install keeps the release label" >&2
fi
[ "$MEDIUM_VARIANT" = server ] || echo "[50] $NCZ_RELEASE_LABEL brand identity"

BUILD_ID_VALUE=""
if [ -f /usr/local/lib/cix-installer/BUILD_VERSION ]; then
    BUILD_ID_VALUE=$(tr -cd 'A-Za-z0-9._-' < /usr/local/lib/cix-installer/BUILD_VERSION)
fi
if [ -z "$BUILD_ID_VALUE" ] && [ -f /etc/cix-installer/BUILD_VERSION ]; then
    BUILD_ID_VALUE=$(tr -cd 'A-Za-z0-9._-' < /etc/cix-installer/BUILD_VERSION)
fi
[ -z "$BUILD_ID_VALUE" ] && BUILD_ID_VALUE=unknown

BUILD_DATE_VALUE=""
for _bd in /usr/local/lib/cix-installer/BUILD_DATE /etc/cix-installer/BUILD_DATE; do
    [ -z "$BUILD_DATE_VALUE" ] && [ -f "$_bd" ] && BUILD_DATE_VALUE=$(head -1 "$_bd" 2>/dev/null)
done
[ -z "$BUILD_DATE_VALUE" ] && BUILD_DATE_VALUE="unknown"

VARIANT_FILE=/usr/local/lib/cix-installer/BUILD_VARIANT
VARIANT="desktop"
if [ -n "${NCZ_BRAND_PRINT_IDENTITY:-}" ]; then
    VARIANT="${NCZ_BRAND_VARIANT:-desktop}"
elif [ -f "$VARIANT_FILE" ]; then
    VARIANT=$(tr -d ' \t\r\n' < "$VARIANT_FILE")
fi

# The release codename (release.conf NCZ_RELEASE_CODENAME) is the same for both
# variants — the variant is a qualifier, not a competing name. VERSION_CODENAME
# is the lowercased codename for both so anything
# that keys off it (update channels, the motd banner below) doesn't need to
# know about variants at all.
SKU_NAME="$NCZ_RELEASE_CODENAME"
SKU_LOWER=$(printf '%s' "$NCZ_RELEASE_CODENAME" | tr '[:upper:]' '[:lower:]')
VARIANT_LABEL="Desktop"
if [ "$VARIANT" = "server" ]; then
    VARIANT_LABEL="Server"
fi
# e.g. "NCZ-OS 26.10 Cygnus Desktop, based on Debian Testing (Forky)"
OS_PRETTY_NAME="${NCZ_RELEASE_LABEL} ${VARIANT_LABEL}, based on ${NCZ_BASE_DESCRIPTION}"
OS_VERSION="${NCZ_RELEASE_VERSION} (${SKU_NAME} ${VARIANT_LABEL}, based on ${NCZ_BASE_DESCRIPTION})"
# The console banner first lines (/etc/issue, /etc/issue.net).
ISSUE_LINE="${NCZ_RELEASE_LABEL} ${VARIANT_LABEL}  ·  NCZ_ISSUE_SOC_PLACEHOLDER  (Kernel: \r)"
ISSUE_NET_LINE="${NCZ_RELEASE_LABEL} ${VARIANT_LABEL}  (NCZ_ISSUE_SOC_PLACEHOLDER)"

# MAGNETAR SERVER: an install from a Magnetar Server MEDIUM (MEDIUM_VARIANT=server,
# written by preseed/late.sh) is named by its edition everywhere a person reads
# it -- "NCZ-OS 26.10 Magnetar Server" -- and os-release gains VARIANT/VARIANT_ID.
# The edition name comes from post-install/lib/ncz-brand.sh (the one place that
# spells it). The machine identity keys (VERSION_ID, VERSION_CODENAME,
# NCZ_RELEASE_CODENAME, LOGO) stay the release's, as on desktop. A desktop
# medium (including its console-only installs, BUILD_VARIANT=server) is not
# touched by this block: every string above stays as it was.
OS_VARIANT_LINES=""
if [ "$MEDIUM_VARIANT" = server ]; then
    SERVER_LABEL=$(ncz_brand_label server "" "$NCZ_PRODUCT_NAME" "$NCZ_RELEASE_VERSION")
    OS_PRETTY_NAME="${SERVER_LABEL}, based on ${NCZ_BASE_DESCRIPTION}"
    OS_VERSION="${NCZ_RELEASE_VERSION} (${NCZ_SERVER_EDITION}, based on ${NCZ_BASE_DESCRIPTION})"
    # Console text is ASCII (no middle dot) on the server.
    ISSUE_LINE="${SERVER_LABEL} - NCZ_ISSUE_SOC_PLACEHOLDER - kernel \r"
    ISSUE_NET_LINE="${SERVER_LABEL} (NCZ_ISSUE_SOC_PLACEHOLDER)"
    OS_VARIANT_LINES="VARIANT=\"${NCZ_SERVER_EDITION}\"
VARIANT_ID=magnetar-server
"
    echo "[50] Magnetar Server medium: ${SERVER_LABEL}"
fi
# os-release LOGO: the greeter (and boot-splash) look up
# /usr/share/{pixmaps,icons/hicolor/256x256/apps}/$LOGO.png, and 55-greeter.sh
# installs the approved mark at exactly that path (with a legacy ncz.png
# alias). 26.10 is the Cygnus release, so this resolves to
# ncz-os-cygnus.png. (A release whose codename has no shipped logo would
# break this contract — ship the asset before changing the codename.)
if [ -n "${NCZ_BRAND_PRINT_IDENTITY:-}" ]; then
    printf 'PRETTY_NAME=%s\nVERSION=%s\nDISTRIB_DESCRIPTION=%s\n' \
        "$OS_PRETTY_NAME" "$OS_VERSION" "$OS_PRETTY_NAME"
    [ "$MEDIUM_VARIANT" = server ] && printf '%sISSUE=%s\n' "$OS_VARIANT_LINES" "$ISSUE_LINE"
    exit 0
fi

cat > /etc/os-release <<EOF_OS
PRETTY_NAME="${OS_PRETTY_NAME}"
NAME="${NCZ_PRODUCT_NAME}"
VERSION_ID="${NCZ_RELEASE_VERSION}"
BUILD_ID="${BUILD_ID_VALUE}"
VERSION="${OS_VERSION}"
VERSION_CODENAME=${SKU_LOWER}
NCZ_VARIANT=${VARIANT}
NCZ_RELEASE_VERSION="${NCZ_RELEASE_VERSION}"
NCZ_RELEASE_CODENAME="${NCZ_RELEASE_CODENAME}"
NCZ_BASE_VERSION="${NCZ_BASE_VERSION}"
${OS_VARIANT_LINES}ID=ncz
ID_LIKE=debian
HOME_URL="https://gitlab.com/nclawzero"
SUPPORT_URL="https://gitlab.com/nclawzero/cix-installer/-/issues"
BUG_REPORT_URL="https://gitlab.com/nclawzero/cix-installer/-/issues"
LOGO=ncz-os-${SKU_LOWER}
EOF_OS

ln -sf /etc/os-release /usr/lib/os-release 2>/dev/null || true

cat > /etc/lsb-release <<EOF_LSB
DISTRIB_ID=NCZ
DISTRIB_RELEASE=${NCZ_RELEASE_VERSION}
DISTRIB_CODENAME=${SKU_LOWER}
DISTRIB_DESCRIPTION="${OS_PRETTY_NAME}"
EOF_LSB

cat > /etc/issue <<EOF_ISSUE
${ISSUE_LINE}
Build: ${BUILD_ID_VALUE}  (${BUILD_DATE_VALUE})
IP:    NCZ_ISSUE_IP_PLACEHOLDER

EOF_ISSUE

cat > /etc/issue.net <<EOF_ISSUENET
${ISSUE_NET_LINE}
Build: ${BUILD_ID_VALUE}  (${BUILD_DATE_VALUE})

EOF_ISSUENET

# Real hardware identity (SoC/GPU/NPU), probed live on the ACTUAL target at
# boot -- never baked in here. This hook usually runs inside a build-time
# chroot (no real GPU/NPU present), and even when it does run on real
# hardware, one script has to serve every arch/vendor this project ships
# (Sky1 arm64, plus amd64 spanning AMD/Intel/NVIDIA GPUs and Intel/AMD
# NPUs) -- hardcoding any one vendor's strings here is exactly the bug this
# replaces (this file used to hardcode "Cix Sky1 / CP8180" and
# "Mali-G720"/"Zhouyi v3" unconditionally, which showed up wrong on a real
# x86_64 T2 Mac with an AMD dGPU). Shared by both /etc/issue (via the
# refresh service below) and the MOTD banner further down.
install -m 0755 /dev/stdin /usr/local/bin/ncz-hw-brand <<'HWBRAND'
#!/bin/sh
# ncz-hw-brand -- print real SOC=/GPU=/NPU= identity lines for branding.
set -u

if [ "$(uname -m)" = "aarch64" ] && grep -qi 'cix\|sky1\|cp8180' \
        /proc/cpuinfo /sys/firmware/devicetree/base/compatible 2>/dev/null; then
    SOC="Cix Sky1 / CP8180"
else
    SOC=$(lscpu 2>/dev/null | awk -F: '/Model name/ {print $2; exit}' \
        | sed -E 's/\(R\)|\(TM\)|CPU @ [0-9.]+GHz//g; s/  +/ /g; s/^ *//; s/ *$//')
    [ -z "$SOC" ] && SOC=$(uname -m)
fi

# Enumerate every bound DRM driver, not just card0 -- dual-GPU machines
# (T2 Macs: AMD dGPU + Intel iGPU) have more than one real card and both
# are worth showing, not just whichever enumerated first.
GPU=""
for drv in /sys/class/drm/card[0-9]*/device/driver; do
    [ -e "$drv" ] || continue
    d=$(basename "$(readlink -f "$drv")")
    case "$d" in
        panthor) g="Mali-G720 (Panthor)" ;;
        mali|mali_kbase) g="Mali-G720 (libmali)" ;;
        amdgpu) g="AMD Radeon (amdgpu/radeonsi)" ;;
        i915) g="Intel (i915)" ;;
        nouveau) g="NVIDIA (nouveau)" ;;
        nvidia) g="NVIDIA (proprietary)" ;;
        *) g="$d" ;;
    esac
    case " $GPU " in *" $g "*) ;; *) GPU="${GPU:+$GPU + }$g" ;; esac
done
[ -z "$GPU" ] && GPU="none detected"

if [ -e /dev/aipu ]; then
    NPU="Zhouyi v3 (/dev/aipu)"
elif [ -e /dev/accel/accel0 ] || [ -e /dev/accel ]; then
    if lsmod 2>/dev/null | grep -q '^amdxdna'; then
        NPU="AMD XDNA (Ryzen AI, /dev/accel)"
    else
        NPU="Intel AI Boost (/dev/accel)"
    fi
else
    NPU="none detected"
fi

printf 'SOC=%s\nGPU=%s\nNPU=%s\n' "$SOC" "$GPU" "$NPU"
HWBRAND

# The IP/SOC lines above are placeholders: at THIS point in post-install, the
# machine may not have a network connection yet (DHCP hasn't necessarily
# run), and the network stack itself varies by build (sinty-nm normally
# owns it, NetworkManager is only the fallback when sinty-nmd isn't staged
# -- see post-install/19-sinty-nm.sh) so there's no single dispatcher-hook
# mechanism guaranteed to exist on every image. Likewise, GPU/NPU hardware
# generally is not visible from inside the build-time chroot this hook runs
# in at all. ncz-issue-refresh.service below fills in both the real address
# and the real SoC identity once it actually runs on the target.
install -m 0755 /dev/stdin /usr/local/bin/ncz-issue-refresh <<'ISSUE_REFRESH'
#!/bin/sh
# ncz-issue-refresh -- replace the IP and SoC placeholder lines in /etc/issue
# with the real values once network is up and hardware is probeable. Polls
# rather than trusting a single network-online trigger to have fired after a
# real address landed (DHCP can complete a beat after network-online.target
# is reported active).
set -u
TRIES=30
IP=""
while [ "$TRIES" -gt 0 ]; do
    # Route-based lookup, not the first line of `ip addr` -- a box with more
    # than one live interface (e.g. wired + wireless both up) lists them in
    # whatever order the kernel enumerated them, not by which one actually
    # carries the default route. Confirmed picking the WRONG interface on a
    # real dual-NIC host during this fix's own verification. `ip route get`
    # asks the kernel which source address it would actually use, which
    # respects real route metrics regardless of listing order.
    IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="src") print $(i+1)}')
    [ -z "$IP" ] && IP=$(ip -4 -o addr show scope global up 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
    [ -n "$IP" ] && break
    TRIES=$((TRIES - 1))
    sleep 2
done
[ -n "$IP" ] || IP="(no address)"
SOC="unknown"
if [ -x /usr/local/bin/ncz-hw-brand ]; then
    SOC=$(/usr/local/bin/ncz-hw-brand 2>/dev/null | awk -F= '/^SOC=/ {sub(/^SOC=/,""); print; exit}')
    [ -n "$SOC" ] || SOC="unknown"
fi
for f in /etc/issue /etc/issue.net; do
    [ -f "$f" ] || continue
    sed -i "s/NCZ_ISSUE_IP_PLACEHOLDER/$IP/; s/NCZ_ISSUE_SOC_PLACEHOLDER/$SOC/" "$f" 2>/dev/null || true
done
ISSUE_REFRESH

cat > /etc/systemd/system/ncz-issue-refresh.service <<'ISSUE_UNIT'
[Unit]
Description=Fill in the real IP address on the login console banner
# Type=simple ON PURPOSE, and no network-online ordering. This unit only
# rewrites the cosmetic IP/SoC lines in /etc/issue, and ncz-issue-refresh
# (installed just above) already polls for a real DHCP address itself (TRIES
# 30 x 2 s). As a Type=oneshot wanted by multi-user.target it would hold
# multi-user.target -- and therefore graphical.target, which is After= it --
# until that poll gave up, i.e. up to ~60 s on a slow/absent DHCP server.
# Type=simple lets the target complete while the banner refreshes in the
# background, exactly as post-install/97-firstboot-report.sh does for its 30 s
# sleep (see its [Unit] comment). Dropping the network-online dependency also
# keeps the NetworkManager-wait-online budget off this unit's start.
# It is safe because the helper is self-polling, not one-shot: if it runs
# before DHCP it keeps retrying and fills the address in when the lease lands.

[Service]
Type=simple
ExecStart=/usr/local/bin/ncz-issue-refresh

[Install]
WantedBy=multi-user.target
ISSUE_UNIT
systemctl enable ncz-issue-refresh.service >/dev/null 2>&1 || true

# Login banner is generated DYNAMICALLY at login (not baked into /etc/motd) so
# the Kernel line always shows the RUNNING kernel (uname -r), never a stale
# hard-coded version. Release name + variant are read live from os-release
# too. The box uses a width-aware row() (wc -m counts display chars, not
# bytes) so every right-edge │ aligns regardless of "<Codename> Desktop" vs
# "<Codename> Server" being different lengths, or the multi-byte ┌─│┐ / · /
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
BUILD=$(. /etc/os-release 2>/dev/null; echo "${BUILD_ID:-unknown}")
# Route-based, not the first `ip addr` line -- see ncz-issue-refresh's own
# comment for why: a dual-NIC box does not list interfaces in route-metric
# order, so the naive form picks whichever interface enumerates first, not
# the one actually carrying traffic.
IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="src") print $(i+1)}')
[ -z "$IP" ] && IP=$(ip -4 -o addr show scope global up 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
[ -z "$IP" ] && IP="(no address)"
# Real hardware probe every login (this banner is regenerated live, never
# baked in) -- see ncz-hw-brand's own header for why one script has to
# cover every arch/vendor this project ships rather than hardcoding Sky1's
# Mali/Zhouyi identity for every install.
SOC="unknown"; GPU="none detected"; NPU="none detected"
if [ -x /usr/local/bin/ncz-hw-brand ]; then
    eval "$(/usr/local/bin/ncz-hw-brand 2>/dev/null | sed -E 's/^(SOC|GPU|NPU)=/\1="/; s/$/"/')"
fi
# A Magnetar Server install records its edition as os-release VARIANT (50-brand.sh);
# its title row names the edition, never the desktop codename.
TITLE="  $NCZ_PRODUCT_NAME $NCZ_RELEASE_VERSION $SKU  ·  $SOC edge agent"
OS_EDITION=$(. /etc/os-release 2>/dev/null; echo "${VARIANT:-}")
[ -n "$OS_EDITION" ] && TITLE="  $NCZ_PRODUCT_NAME $NCZ_RELEASE_VERSION $OS_EDITION - $SOC"
ROWS=(
  "$TITLE"
  ""
  "  Agents:  zeroclaw · openclaw · hermes · claude-code"
  "  Kernel:  $(uname -r)"
  "  Build:   $BUILD"
  "  IP:      $IP"
  "  GPU:     $GPU"
  "  NPU:     $NPU"
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
