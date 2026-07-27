#!/bin/bash
# 53-chrome.sh — post-install wiring for real, official Google Chrome
# (arm64), the SECOND browser choice alongside Vivaldi (default,
# 52-vivaldi.sh). The package itself installs earlier, as part of
# 20-desktop.sh's normal apt-get install of the full desktop seed — Chrome
# is folded into the offline desktop-mirror pool by build-desktop-mirror.sh,
# pinned to an exact version + SHA256-verified against Google's own
# published Packages index. This hook only does what apt's own postinst +
# the mirror step don't: keep the image CDROM-only, and register the
# alternative.
#
# Real Google Chrome for arm64 Linux launched publicly Q2 2026 and became
# available via Google's own signed apt repo (dl.google.com/linux/chrome/deb)
# by 2026-07. See build/build-desktop-mirror.sh for the mirroring + pinning
# + checksum-verification of google-chrome-stable, and
# post-install/84-vpu-vaapi.sh for the fix that makes its hardware video
# decode (VA-API — H264/HEVC/VP9/AV1) actually work.
#
# RUNS INSIDE CHROOT (build-squashfs-layers.sh desktop loop / run-all.sh).
set +e

echo "[53] Google Chrome post-install wiring (second browser, alongside Vivaldi)"

VARIANT=desktop
[ -f /usr/local/lib/cix-installer/BUILD_VARIANT ] && \
    VARIANT=$(tr -d ' \t\r\n' < /usr/local/lib/cix-installer/BUILD_VARIANT)
case "$VARIANT" in
    server|headless)
        echo "[53] BUILD_VARIANT=$VARIANT — headless SKU; skipping browser wiring"
        exit 0
        ;;
esac

if [ ! -x /usr/bin/google-chrome-stable ]; then
    echo "[53] google-chrome-stable not installed (not in this VARIANT's desktop seed, or apt install failed earlier) — skipping"
    exit 0
fi

# --- keep the image CDROM-only: neutralise the repo google apt source the
#     .deb postinst wrote (r180 apt-setup doctrine). Keyrings stay (harmless). ---
for s in /etc/apt/sources.list.d/google-chrome.list; do
    [ -f "$s" ] && mv -f "$s" "$s.disabled" && echo "[53] disabled network apt source $(basename "$s") (image stays CDROM-only)"
done

# --- NOT the default browser: Vivaldi keeps that role. Register Chrome as a
#     lower-priority x-www-browser alternative so it's a real, selectable
#     choice without disturbing 52-vivaldi.sh's default. ---
update-alternatives --install /usr/bin/x-www-browser x-www-browser /usr/bin/google-chrome-stable 300 2>/dev/null || true

# --- desktop launcher, not as prominent as Vivaldi's ---
install -d -m0755 /etc/skel/Desktop
if [ -f /usr/share/applications/google-chrome.desktop ]; then
    cp -f /usr/share/applications/google-chrome.desktop /etc/skel/Desktop/Google-Chrome.desktop
    chmod 0755 /etc/skel/Desktop/Google-Chrome.desktop
fi

update-desktop-database 2>&1 | tail -1
echo "[53] Google Chrome $( /usr/bin/google-chrome-stable --version 2>/dev/null ) wired (second browser; Vivaldi stays default)"
