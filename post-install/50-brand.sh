#!/bin/bash
# 50-brand.sh — NCZ 26.5 "Reinhardt" identity
# Note: NO `set -e` because pipefail + `find /missing/path | head -1` causes early exit.
# Each step is best-effort; any failure logs and continues.
set +e

echo "[50] NCZ 26.5 brand identity"

BUILD_ID_VALUE=""
if [ -f /usr/local/lib/cix-installer/BUILD_VERSION ]; then
    BUILD_ID_VALUE=$(tr -cd 'A-Za-z0-9._-' < /usr/local/lib/cix-installer/BUILD_VERSION)
fi
if [ -z "$BUILD_ID_VALUE" ] && [ -f /etc/cix-installer/BUILD_VERSION ]; then
    BUILD_ID_VALUE=$(tr -cd 'A-Za-z0-9._-' < /etc/cix-installer/BUILD_VERSION)
fi
[ -z "$BUILD_ID_VALUE" ] && BUILD_ID_VALUE=unknown

cat > /etc/os-release <<EOF
PRETTY_NAME="NCZ 26.5 \\"Reinhardt\\""
NAME="NCZ"
VERSION_ID="26.5"
BUILD_ID="$BUILD_ID_VALUE"
VERSION="26.5 (Reinhardt)"
VERSION_CODENAME=reinhardt
ID=ncz
ID_LIKE=ubuntu
HOME_URL="https://gitlab.com/nclawzero"
SUPPORT_URL="https://gitlab.com/nclawzero/cix-installer/-/issues"
BUG_REPORT_URL="https://gitlab.com/nclawzero/cix-installer/-/issues"
UBUNTU_CODENAME=questing
LOGO=ncz
EOF
ln -sf /etc/os-release /usr/lib/os-release 2>/dev/null || true

cat > /etc/lsb-release <<EOF
DISTRIB_ID=NCZ
DISTRIB_RELEASE=26.5
DISTRIB_CODENAME=reinhardt
DISTRIB_DESCRIPTION="NCZ 26.5 \\"Reinhardt\\""
EOF

cat > /etc/issue <<EOF
NCZ 26.5 "Reinhardt"  ·  Cix Sky1 / CP8180

Dr. Reinhardt has gone into the Black Hole.

EOF

cat > /etc/issue.net <<EOF
NCZ 26.5 "Reinhardt"  (Cix Sky1 / CP8180)

EOF

cat > /etc/motd <<MOTD

   ┌─────────────────────────────────────────────────────────┐
   │  NCZ 26.5 "Reinhardt"  —  Cix Sky1 / CP8180 edge agent  │
   │                                                         │
   │  Agents:  zeroclaw · openclaw · hermes · claude-code    │
   │  Kernel:  linux-cix-sky1 6.18.26-lts (Yocto-built)      │
   │  GPU:     Mali-G720  (Mesa Zink+PanVK accel)            │
   │  NPU:     Zhouyi v3  (3 cores · 12 TECs · /dev/aipu)    │
   │                                                         │
   │  ✦  Workloads. Not wallpapers.                          │
   └─────────────────────────────────────────────────────────┘

MOTD

cat > /etc/update-motd.d/00-header <<HEADER
#!/bin/sh
printf "\nNCZ 26.5 \\"Reinhardt\\"  (GNU/Linux %s %s)\n" "\$(uname -r)" "\$(uname -m)"
printf "  Cix Sky1 / CP8180  ·  Dr. Reinhardt has gone into the Black Hole.\n\n"
HEADER
chmod 0755 /etc/update-motd.d/00-header

mkdir -p /usr/share/ncz
ASSETS=/usr/local/lib/cix-installer/assets/branding
[ -f "$ASSETS/cosmic-quotes" ] && cp "$ASSETS/cosmic-quotes" /usr/share/ncz/cosmic-quotes

cat > /etc/update-motd.d/05-cosmic-quote <<COSMIC
#!/bin/sh
QUOTES=/usr/share/ncz/cosmic-quotes
[ -r "\$QUOTES" ] || exit 0
LINE=\$(shuf -n 1 "\$QUOTES" 2>/dev/null)
[ -z "\$LINE" ] && exit 0
printf "  ✦  %s\n\n" "\$LINE"
COSMIC
chmod 0755 /etc/update-motd.d/05-cosmic-quote

# Disable Ubuntu MOTD spam
for f in 50-motd-news 85-fwupd 90-updates-available 91-contract-ua-esm-status 91-release-upgrade 92-unattended-upgrades 95-hwe-eol 98-fsck-at-reboot 98-reboot-required 10-help-text; do
    [ -f "/etc/update-motd.d/$f" ] && chmod -x "/etc/update-motd.d/$f"
done

# Purge ubuntu-pro upsell
DEBIAN_FRONTEND=noninteractive apt-get purge -y ubuntu-advantage-tools ubuntu-pro-client 2>&1 | tail -1 || true
systemctl disable apt-news.service apt-news.timer esm-cache.service motd-news.service motd-news.timer 2>/dev/null || true
systemctl mask apt-news.service motd-news.service 2>/dev/null || true

# Hostname mirror
HOSTNAME=$(cat /etc/hostname 2>/dev/null | tr -d ' \t\r\n')
if [ -n "$HOSTNAME" ]; then
    grep -q "127.0.1.1.*$HOSTNAME" /etc/hosts || echo "127.0.1.1 $HOSTNAME" >> /etc/hosts
fi

# Rheinhardt-Through-and-Beyond.desktop is written by 30-agents.sh (with ncz-rocket icon).
# Defensive cleanup of any stale Reinhardt-spelled launcher from older revs.
install -d -m 0755 /etc/skel/Desktop
rm -f /etc/skel/Desktop/Reinhardt-Through-and-Beyond.desktop

echo "[50] NCZ 26.5 Reinhardt identity applied — motd box-aligned, cosmic-quotes, no Ubuntu spam"

# ----------------------------------------------------------------------
# r74: backgrounds installed directly to /usr/share/backgrounds/ncz/ by
# 45-wallpaper-rotator.sh — no migration needed.

# r62: Generate NCZ rocket-into-black-hole icon at install time
# (rsvg-convert was installed by 30-agents.sh / 25-cix-proprietary; if not, fallback gracefully)
if command -v rsvg-convert >/dev/null 2>&1; then
    mkdir -p /usr/share/icons/ncz /tmp/ncz-brand
    cat > /tmp/ncz-brand/ncz-rocket.svg << 'ROCKET_SVG'
<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="256" height="256" viewBox="0 0 256 256">
  <defs>
    <radialGradient id="bhCore" cx="50%" cy="50%" r="50%">
      <stop offset="0%" stop-color="#000000"/><stop offset="40%" stop-color="#000000"/>
      <stop offset="60%" stop-color="#1a0a00"/><stop offset="100%" stop-color="#1a0a00" stop-opacity="0"/>
    </radialGradient>
    <radialGradient id="accretionDisk" cx="50%" cy="50%" r="50%">
      <stop offset="30%" stop-color="#fbbf24" stop-opacity="0"/><stop offset="50%" stop-color="#f59e0b"/>
      <stop offset="70%" stop-color="#dc2626"/><stop offset="90%" stop-color="#7c2d12"/>
      <stop offset="100%" stop-color="#7c2d12" stop-opacity="0"/>
    </radialGradient>
    <linearGradient id="rocketBody" x1="0%" y1="0%" x2="100%" y2="0%">
      <stop offset="0%" stop-color="#fef3c7"/><stop offset="50%" stop-color="#fbbf24"/>
      <stop offset="100%" stop-color="#b45309"/>
    </linearGradient>
    <linearGradient id="flame" x1="0%" y1="0%" x2="0%" y2="100%">
      <stop offset="0%" stop-color="#fef3c7"/><stop offset="40%" stop-color="#fbbf24"/>
      <stop offset="100%" stop-color="#dc2626"/>
    </linearGradient>
  </defs>
  <rect width="256" height="256" fill="#0a0a0a"/>
  <circle cx="40" cy="30" r="1" fill="#fff" opacity="0.8"/>
  <circle cx="220" cy="50" r="1.5" fill="#fff" opacity="0.7"/>
  <circle cx="30" cy="200" r="1" fill="#fff" opacity="0.6"/>
  <circle cx="200" cy="220" r="1.2" fill="#fff" opacity="0.7"/>
  <circle cx="180" cy="20" r="0.8" fill="#fff" opacity="0.5"/>
  <ellipse cx="170" cy="160" rx="74" ry="20" fill="url(#accretionDisk)" transform="rotate(-25 170 160)"/>
  <ellipse cx="170" cy="160" rx="48" ry="48" fill="url(#bhCore)"/>
  <circle cx="170" cy="160" r="22" fill="#000"/>
  <ellipse cx="170" cy="160" rx="30" ry="30" fill="none" stroke="#fbbf24" stroke-width="1" opacity="0.6"/>
  <g transform="translate(75 75) rotate(45)">
    <path d="M 0 -50 Q -3 -30 -5 0 L 5 0 Q 3 -30 0 -50 Z" fill="url(#flame)" opacity="0.7"/>
    <path d="M -10 5 L -22 18 L -10 18 Z" fill="#7c2d12"/>
    <path d="M  10 5 L  22 18 L  10 18 Z" fill="#7c2d12"/>
    <path d="M -10 -22 Q -10 -2 -10 18 L 10 18 Q 10 -2 10 -22 Q 0 -34 -10 -22 Z" fill="url(#rocketBody)" stroke="#7c2d12" stroke-width="1.2"/>
    <circle cx="0" cy="-8" r="4.5" fill="#0c0a09"/>
    <circle cx="0" cy="-8" r="3" fill="#1e293b"/>
  </g>
</svg>
ROCKET_SVG
    for sz in 32 48 64 128 256; do
        rsvg-convert -w $sz -h $sz /tmp/ncz-brand/ncz-rocket.svg \
            -o /usr/share/icons/ncz/ncz-rocket-${sz}.png 2>/dev/null
        install -d /usr/share/icons/hicolor/${sz}x${sz}/apps
        cp /usr/share/icons/ncz/ncz-rocket-${sz}.png \
            /usr/share/icons/hicolor/${sz}x${sz}/apps/ncz-rocket.png 2>/dev/null
    done
    gtk-update-icon-cache -f -t /usr/share/icons/hicolor 2>&1 | tail -1
    echo "[50] rocket-into-black-hole icon rendered (32/48/64/128/256)"
else
    echo "[50] WARN: rsvg-convert not available, skipping rocket icon generation"
fi

# Pick a default user image: prefer NCZ rocket, then mnemos, then avatar-default
NCZ_USER_IMG=""
[ -f /usr/share/icons/ncz/ncz-rocket-256.png ] && \
    NCZ_USER_IMG=/usr/share/icons/ncz/ncz-rocket-256.png
[ -z "$NCZ_USER_IMG" ] && \
    NCZ_USER_IMG=$(find /usr/share/icons/NCZ /usr/share/icons/NCX -name 'user-trash*.png' 2>/dev/null | head -1 || true)
[ -z "$NCZ_USER_IMG" ] && [ -f /usr/share/icons/hicolor/256x256/apps/mnemos.png ] && \
    NCZ_USER_IMG=/usr/share/icons/hicolor/256x256/apps/mnemos.png
[ -z "$NCZ_USER_IMG" ] && NCZ_USER_IMG=/usr/share/icons/hicolor/256x256/status/avatar-default.png

# Pick a default greeter wallpaper
NCZ_GREETER_BG=/usr/share/backgrounds/ncz/default.jpg
if [ ! -f "$NCZ_GREETER_BG" ]; then
    # Fallback: first jpg/png in ncz dir, or xfce backdrop
    NCZ_GREETER_BG=$(find /usr/share/backgrounds/ncz -type f \( -name '*.jpg' -o -name '*.png' \) 2>/dev/null | head -1 || true)
    [ -z "$NCZ_GREETER_BG" ] && NCZ_GREETER_BG=/usr/share/xfce4/backdrops/xubuntu-wallpaper.png
fi

# NCZ-branded LightDM greeter override (loaded last in alpha order, wins)
mkdir -p /etc/lightdm/lightdm-gtk-greeter.conf.d
cat > /etc/lightdm/lightdm-gtk-greeter.conf.d/99-ncz.conf <<EOF
[greeter]
background=$NCZ_GREETER_BG
theme-name=Adwaita-dark
icon-theme-name=NCZ
font-name=Sans 11
default-user-image=$NCZ_USER_IMG
hide-user-image=false
indicators=~spacer;~clock;~spacer;~session;~language;~a11y;~power
clock-format=NCZ 26.5 "Reinhardt"  —  %a %b %d  %H:%M
position=50%,center 50%,center
xft-antialias=true
xft-hintstyle=hintslight
xft-rgba=rgb
keyboard=
screensaver-timeout=0
EOF

# Neuter xubuntu/ubuntu greeter defaults so they cannot stomp ours
mkdir -p /usr/share/lightdm/lightdm-gtk-greeter.conf.d
cat > /usr/share/lightdm/lightdm-gtk-greeter.conf.d/30_xubuntu.conf <<'EOF'
# NCZ 26.5: original xubuntu greeter overrides intentionally emptied
# (NCZ uses /etc/lightdm/lightdm-gtk-greeter.conf.d/99-ncz.conf instead)
EOF
cat > /usr/share/lightdm/lightdm-gtk-greeter.conf.d/01_ubuntu.conf <<'EOF'
# NCZ 26.5: original ubuntu greeter overrides intentionally emptied
EOF

echo "[50] LightDM greeter rebranded — bg=$NCZ_GREETER_BG, user-img=$NCZ_USER_IMG"
