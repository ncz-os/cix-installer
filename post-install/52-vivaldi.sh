#!/bin/bash
# NCZ-MIXED-HOOK: Vivaldi install generic; arm64 applies lib/sky1-browser-policy.sh (chromium-ncz-sky1 default, VA-API-off Vivaldi/Chrome) from an EXIT trap; TODO split (docs/platform-inventory.tsv; runs on every platform, listed in both hooks.list files)
# 52-vivaldi.sh — install Vivaldi (arm64) OFFLINE from a staged .deb + make it
# the DEFAULT browser.
#
# r181 (MS-R1 test-board metal): the MNEMOS + agent desktop launchers Exec
# /usr/bin/vivaldi-stable, but Vivaldi was never installed (only epiphany +
# firefox; falkon was half-configured), so those launchers errored. And epiphany
# (WebKitGTK) can't play YouTube on arm64. Vivaldi is Chromium-based; the .deb
# ships /opt/vivaldi/libffmpeg.so without the proprietary codecs (H.264/AAC).
# Those come from /opt/vivaldi/update-ffmpeg, which fetches Chromium's libffmpeg
# into /var/opt/vivaldi (--system) or ~/.local/lib/vivaldi (--user). The vivaldi
# launcher runs it for each user at first start (VIVALDI_FFMPEG_AUTO, default
# on); root can run `/opt/vivaldi/update-ffmpeg --system` once for all users.
# Widevine DRM downloads on first run. Bundle the .deb in the image + install it.
#
# Layer build (NCZ_LAYER_BUILD=1, set by build-squashfs-layers.sh): nothing is
# downloaded into the image. The .deb postinst starts update-ffmpeg in the
# background, so for the install the script is diverted to a no-op and restored
# afterwards, and the version probe runs with VIVALDI_FFMPEG_AUTO=0.
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

# NCZ-SKY1-BROWSER-BEGIN
# Sky1 (arm64) only: chromium-ncz-sky1 is the default browser and Vivaldi/Chrome
# start with VA-API off (post-install/lib/sky1-browser-policy.sh, r201: the CIX
# VA-API decoder hangs on H.264/HEVC). Applied from an EXIT trap so it also runs
# when this hook leaves early, and AFTER this hook's own default-browser writes.
_ncz_bp_arch="${NCZ_TARGET_ARCH:-}"
[ -n "$_ncz_bp_arch" ] || _ncz_bp_arch=$(tr -d '[:space:]' 2>/dev/null < /usr/local/lib/cix-installer/BUILD_ARCH || true)
[ -n "$_ncz_bp_arch" ] || _ncz_bp_arch=$(dpkg --print-architecture 2>/dev/null || uname -m)
case "$_ncz_bp_arch" in
    arm64|aarch64)
        _ncz_bp_lib="$(cd "$(dirname "$0")" && pwd)/lib/sky1-browser-policy.sh"
        [ -r "$_ncz_bp_lib" ] || _ncz_bp_lib=/usr/local/lib/cix-installer/post-install/lib/sky1-browser-policy.sh
        _ncz_sky1_browser_exit() {
            if [ -r "$_ncz_bp_lib" ]; then
                . "$_ncz_bp_lib"
                ncz_sky1_browser_policy
            else
                echo "[${0##*/}] WARN: $_ncz_bp_lib missing; Sky1 browser policy not applied" >&2
            fi
        }
        trap _ncz_sky1_browser_exit EXIT
        ;;
esac
# NCZ-SKY1-BROWSER-END

VIV_DIR=/usr/local/lib/cix-installer/assets/vivaldi
INSTALLER_META=/usr/local/lib/cix-installer
NCZ_SYSTEM_ARCH="${NCZ_TARGET_ARCH:-}"
if [ -z "$NCZ_SYSTEM_ARCH" ] && [ -r "$INSTALLER_META/BUILD_ARCH" ]; then
    NCZ_SYSTEM_ARCH=$(tr -d '[:space:]' < "$INSTALLER_META/BUILD_ARCH")
fi
NCZ_SYSTEM_ARCH="${NCZ_SYSTEM_ARCH:-$(dpkg --print-architecture 2>/dev/null || true)}"

DEB=$(ls "$VIV_DIR"/vivaldi-stable_*_"${NCZ_SYSTEM_ARCH}".deb 2>/dev/null | sort -V | tail -1)
if [ -z "$DEB" ]; then
    echo "[52] WARN: no staged Vivaldi .deb for arch=$NCZ_SYSTEM_ARCH under $VIV_DIR — skipping (launchers targeting vivaldi-stable will error)"
    exit 0
fi

echo "[52] installing $(basename "$DEB")"
NCZ_VIV_DIVERT=""
if [ "${NCZ_LAYER_BUILD:-0}" = 1 ]; then
    if dpkg-divert --local --rename --divert /opt/vivaldi/update-ffmpeg.ncz-build --add /opt/vivaldi/update-ffmpeg >/dev/null; then
        mkdir -p /opt/vivaldi
        printf '#!/bin/sh\n# layer build: no codec download into the image\nexit 0\n' > /opt/vivaldi/update-ffmpeg
        chmod 0755 /opt/vivaldi/update-ffmpeg
        NCZ_VIV_DIVERT=1
        echo "[52] layer build: update-ffmpeg diverted for the install"
    else
        echo "[52] ERROR: could not divert /opt/vivaldi/update-ffmpeg; the postinst would download codecs" >&2
    fi
fi
DEBIAN_FRONTEND=noninteractive dpkg -i "$DEB" 2>&1 | tail -6
# r189.1: was --no-download, relying on Vivaldi's own dependency closure being
# fully pre-satisfied -- but fonts-liberation was never actually staged that way,
# leaving vivaldi-stable stuck dpkg `iU` (half-configured) on every fresh install
# (found validating r189). 24-apt-sources.sh now wires real persistent apt
# sources (Debian forky via 23-base-apt-sources.sh, plus the NCZ repo whose pin
# keeps Debian names on Debian's versions) BEFORE this hook runs, so
# --fix-broken can resolve the dependency from Debian forky. Never Ubuntu: an
# Ubuntu build of fonts-liberation (1:2.1.5-3build1) leaked into the NCZ repo
# on exactly this path in r189.
DEBIAN_FRONTEND=noninteractive apt-get -y -f install 2>&1 | tail -6 || true
if [ -n "$NCZ_VIV_DIVERT" ]; then
    rm -f /opt/vivaldi/update-ffmpeg
    if dpkg-divert --local --rename --remove /opt/vivaldi/update-ffmpeg >/dev/null && grep -q '^FFMPEG_VERSION=' /opt/vivaldi/update-ffmpeg 2>/dev/null; then
        echo "[52] layer build: update-ffmpeg restored"
    else
        echo "[52] ERROR: /opt/vivaldi/update-ffmpeg not restored" >&2
    fi
    if ls /var/opt/vivaldi/media-codecs-* >/dev/null 2>&1 || ls /root/.local/lib/vivaldi/media-codecs-* >/dev/null 2>&1; then
        echo "[52] ERROR: codecs were downloaded during the layer build" >&2
    else
        echo "[52] layer build: no codec download"
    fi
fi

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
echo "[52] Vivaldi $( VIVALDI_FFMPEG_AUTO=0 /usr/bin/vivaldi-stable --version 2>/dev/null ) installed + set default (x-www-browser + xdg mime); falkon launchers dropped"
