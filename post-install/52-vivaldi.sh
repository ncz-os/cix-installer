#!/bin/bash
# 52-vivaldi.sh — install Vivaldi (arm64) OFFLINE from a staged .deb + make it
# the DEFAULT browser.
#
# r181 (operator, .66 metal): the MNEMOS + agent desktop launchers Exec
# /usr/bin/vivaldi-stable, but Vivaldi was never installed (only epiphany +
# firefox; falkon was half-configured), so those launchers errored. And epiphany
# (WebKitGTK) can't play YouTube on arm64. Vivaldi is Chromium-based and ships
# /opt/vivaldi/libffmpeg.so proprietary codecs, so it plays YouTube (Widevine DRM
# downloads on first run). Bundle the .deb in the image + install it here.
#
# Offline-clean: Vivaldi is self-contained (no dep closure issues), so we dpkg -i
# the staged .deb rather than adding repo.vivaldi.com to the mirror. The .deb's
# postinst writes a repo.vivaldi.com apt source; we NEUTRALISE it to keep the
# installed image CDROM-only (r180 apt-setup doctrine) — Vivaldi updates become a
# deliberate operator action, not an every-boot network apt hit.
#
# RUNS INSIDE CHROOT (build-squashfs-layers.sh desktop loop / run-all.sh).
set +e

echo "[52] Vivaldi browser (offline .deb) + default-browser"

VARIANT=desktop
[ -f /usr/local/lib/cix-installer/BUILD_VARIANT ] && \
    VARIANT=$(tr -d ' \t\r\n' < /usr/local/lib/cix-installer/BUILD_VARIANT)
case "$VARIANT" in
    server|headless)
        echo "[52] BUILD_VARIANT=$VARIANT — headless SKU; skipping browser"
        exit 0
        ;;
esac

VIV_DIR=/usr/local/lib/cix-installer/assets/vivaldi
DEB=$(ls "$VIV_DIR"/vivaldi-stable_*_arm64.deb 2>/dev/null | sort -V | tail -1)
if [ -z "$DEB" ]; then
    echo "[52] WARN: no staged Vivaldi .deb under $VIV_DIR — skipping (launchers targeting vivaldi-stable will error)"
    exit 0
fi

echo "[52] installing $(basename "$DEB")"
DEBIAN_FRONTEND=noninteractive dpkg -i "$DEB" 2>&1 | tail -6
# r189.1: was --no-download, relying on Vivaldi's own dependency closure being
# fully pre-satisfied -- but fonts-liberation was never actually staged that way,
# leaving vivaldi-stable stuck dpkg `iU` (half-configured) on every fresh install
# (found validating r189). 24-apt-sources.sh now wires real persistent apt
# sources (Ubuntu universe + Buildkite, which mirrors fonts-liberation itself)
# BEFORE this hook runs, so --fix-broken can actually resolve the dependency
# instead of only working when it happens to already be cached.
DEBIAN_FRONTEND=noninteractive apt-get -y -f install 2>&1 | tail -6 || true

if [ ! -x /usr/bin/vivaldi-stable ]; then
    echo "[52] ERROR: vivaldi-stable not present after dpkg -i" >&2
    exit 0
fi

# --- DEFAULT browser: alternatives (the .deb installs at a low priority; force) ---
update-alternatives --install /usr/bin/x-www-browser     x-www-browser     /usr/bin/vivaldi-stable 500
update-alternatives --set     x-www-browser     /usr/bin/vivaldi-stable 2>/dev/null
update-alternatives --install /usr/bin/gnome-www-browser gnome-www-browser /usr/bin/vivaldi-stable 500
update-alternatives --set     gnome-www-browser /usr/bin/vivaldi-stable 2>/dev/null

# --- system-wide xdg default + mime handlers -> Vivaldi ---
mkdir -p /etc/xdg
cat > /etc/xdg/mimeapps.list <<'MIME'
[Default Applications]
text/html=vivaldi-stable.desktop
x-scheme-handler/http=vivaldi-stable.desktop
x-scheme-handler/https=vivaldi-stable.desktop
x-scheme-handler/ftp=vivaldi-stable.desktop
x-scheme-handler/chrome=vivaldi-stable.desktop
x-scheme-handler/about=vivaldi-stable.desktop
x-scheme-handler/unknown=vivaldi-stable.desktop
application/x-extension-htm=vivaldi-stable.desktop
application/x-extension-html=vivaldi-stable.desktop
application/xhtml+xml=vivaldi-stable.desktop
inode/directory=thunar.desktop
MIME
# also seed the per-user default so the very first login already defaults right
install -d /etc/skel/.config
cp -f /etc/xdg/mimeapps.list /etc/skel/.config/mimeapps.list 2>/dev/null

# --- keep the image CDROM-only: neutralise the repo.vivaldi.com apt source the
#     .deb postinst wrote (r180 apt-setup doctrine). Keyrings stay (harmless). ---
for s in /etc/apt/sources.list.d/vivaldi.sources /etc/apt/sources.list.d/vivaldi.list; do
    [ -f "$s" ] && mv -f "$s" "$s.disabled" && echo "[52] disabled network apt source $(basename "$s") (image stays CDROM-only)"
done

# --- prominent Vivaldi desktop launcher (the default browser icon on the desktop) ---
install -d -m0755 /etc/skel/Desktop
if [ -f /usr/share/applications/vivaldi-stable.desktop ]; then
    cp -f /usr/share/applications/vivaldi-stable.desktop /etc/skel/Desktop/Vivaldi.desktop
    chmod 0755 /etc/skel/Desktop/Vivaldi.desktop
fi

# --- drop falkon launchers: falkon is no longer shipped (removed from
#     manifests/desktop.pkgs); a stale .desktop would error like the mnemos one. ---
rm -f /usr/share/applications/org.kde.falkon.desktop \
      /etc/skel/Desktop/*[Ff]alkon*.desktop \
      /usr/share/applications/*[Ff]alkon*.desktop 2>/dev/null

update-desktop-database 2>&1 | tail -1
echo "[52] Vivaldi $( /usr/bin/vivaldi-stable --version 2>/dev/null ) installed + set default (x-www-browser + xdg mime); falkon launchers dropped"
