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
APPDIR=/usr/share/applications

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
    echo "[53] FATAL: google-chrome-stable is absent from a desktop/browser-enabled install" >&2
    echo "[53]        expected it from the offline Forky mirror seed; check google-chrome-stable in manifests/desktop.pkgs and the ISO pool" >&2
    exit 1
fi

# The Chrome .deb has used three desktop-file names across arm64 releases.
# Keep one canonical launcher so the Singularity app grid does not show three
# visually identical Chrome icons.
for duplicate in Google-Chrome.desktop com.google.Chrome.desktop; do
    rm -f "$APPDIR/$duplicate" "/etc/skel/Desktop/$duplicate" 2>/dev/null || true
done

# --- KEEP Google's apt repo ENABLED on the installed system (operator
#     directive 2026-07-29) so Chrome auto-updates from dl.google.com. The
#     r180 CDROM-only doctrine applies to the INSTALLER image, not the
#     installed desktop.
#
#     2026-08-02: this block used to look ONLY at the legacy one-line
#     /etc/apt/sources.list.d/google-chrome.list. Current Chrome debs
#     (151.0.7922.71) write deb822 google-chrome.sources instead, and their
#     postinst MAIN runs install_key -> install_deb822_sources ->
#     remove_legacy_list, i.e. it actively DELETES the .list file. So the hook
#     reported "chrome deb postinst wrote no google-chrome.list — no
#     auto-update repo" on every install while the repo was in fact configured
#     correctly the whole time. Check the deb822 path first, keep the legacy
#     path as a fallback, and only synthesise a source if BOTH are absent. ---
CHROME_SOURCES=/etc/apt/sources.list.d/google-chrome.sources
CHROME_SRC=/etc/apt/sources.list.d/google-chrome.list
# Restore a repo an earlier build disabled — but NEVER over a live one. The
# old code did an unconditional `mv -f`, so if both an active source and a
# stale .disabled backup existed, the stale copy silently overwrote the working
# one. Only promote the backup when there is nothing active to lose.
if [ -f "$CHROME_SOURCES.disabled" ] && [ ! -f "$CHROME_SOURCES" ]; then
    mv -f "$CHROME_SOURCES.disabled" "$CHROME_SOURCES"
fi
if [ -f "$CHROME_SRC.disabled" ] && [ ! -f "$CHROME_SRC" ] && [ ! -f "$CHROME_SOURCES" ]; then
    mv -f "$CHROME_SRC.disabled" "$CHROME_SRC"
fi

chrome_keyring_ok() {
    [ -f /usr/share/keyrings/google-chrome.gpg ] && return 0
    ls /etc/apt/keyrings/google-chrome.* >/dev/null 2>&1
}

if [ -f "$CHROME_SOURCES" ]; then
    echo "[53] Chrome apt repo ENABLED (deb822): $(grep -m1 '^URIs:' "$CHROME_SOURCES" 2>/dev/null)"
    chrome_keyring_ok || echo "[53] WARN: google-chrome.sources present but its signing keyring is missing — apt update will fail on it"
elif [ -f "$CHROME_SRC" ]; then
    echo "[53] Chrome apt repo ENABLED (legacy .list): $(grep -v '^#' "$CHROME_SRC" 2>/dev/null | grep -m1 dl.google.com)"
    chrome_keyring_ok || echo "[53] WARN: google-chrome.list present but its signing keyring is missing — apt update will fail on it"
else
    # Neither file exists: the postinst's repo step really did not run (it is
    # gated on repo_add_once in /etc/default/google-chrome). Chrome would then
    # sit pinned forever at whatever version the offline mirror carried — a
    # browser that never receives security updates. Write the deb822 source
    # ourselves, matching what the postinst would have produced.
    if chrome_keyring_ok; then
        CHROME_KEYRING=/usr/share/keyrings/google-chrome.gpg
        [ -f "$CHROME_KEYRING" ] || CHROME_KEYRING=$(ls /etc/apt/keyrings/google-chrome.* 2>/dev/null | head -1)
        cat > "$CHROME_SOURCES" <<EOF
# Written by post-install/53-chrome.sh: the google-chrome-stable postinst did
# not configure its own repo on this build (repo_add_once gate), so Chrome
# would never auto-update. Mirrors the postinst's own deb822 output.
X-Repolib-Name: Google Chrome
Types: deb
# NOT a typo and NOT the legacy https://dl.google.com/linux/chrome/deb/ path.
# Chrome 151's postinst gen_sources_content() writes chrome-stable/deb/ in its
# deb822 source (the chrome/deb/ form only survives in its REPOCONFIG legacy
# one-line variable). Verified 2026-08-02: this is verbatim what the postinst
# wrote to google-chrome.sources on the installed O6N, and both endpoints
# return HTTP 200 for dists/stable/Release. Match the vendor so a later
# postinst run is idempotent instead of rewriting our file.
URIs: https://dl.google.com/linux/chrome-stable/deb/
Suites: stable
Components: main
Architectures: arm64
Signed-By: $CHROME_KEYRING
EOF
        chmod 0644 "$CHROME_SOURCES"
        echo "[53] wrote $CHROME_SOURCES (Signed-By=$CHROME_KEYRING) — Chrome will auto-update"
    else
        echo "[53] WARN: no google-chrome.sources/.list AND no google-chrome keyring on the target."
        echo "[53]       Chrome is installed but will NEVER receive updates. The keyring is written"
        echo "[53]       by the deb's own postinst (install_key) — check whether that postinst ran."
    fi
fi

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
