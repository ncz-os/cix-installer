#!/bin/bash
# Install browser and contributed-art packages from the live NCZ repositories.
# Intentionally absent from build-squashfs-layers.sh: versions must be current
# at hardware-install time. Network failure is non-fatal for offline installs.
set +e

echo "[25-live] installing current browser and artist packages from Buildkite/R2"

VARIANT=desktop
[ -f /usr/local/lib/cix-installer/BUILD_VARIANT ] && \
    VARIANT=$(tr -d ' \t\r\n' < /usr/local/lib/cix-installer/BUILD_VARIANT)
case "$VARIANT" in
    server|headless)
        echo "[25-live] BUILD_VARIANT=$VARIANT — headless SKU; skipping browser/art packages"
        exit 0
        ;;
esac

COMP_FILE=/usr/local/lib/cix-installer/COMPONENTS
[ -r "$COMP_FILE" ] || COMP_FILE=/etc/cix-installer/COMPONENTS
[ -r "$COMP_FILE" ] || COMP_FILE=/var/lib/cix-components/COMPONENTS
COMPONENTS=""
[ -r "$COMP_FILE" ] && COMPONENTS=$(tr -d ' \t\r\n' < "$COMP_FILE" 2>/dev/null)

component_enabled() {
    [ -z "$COMPONENTS" ] || case ",$COMPONENTS," in *",$1,"*) return 0;; *) return 1;; esac
}

BROWSER_PACKAGES=""
ART_PACKAGES=""
if component_enabled desktop && component_enabled browsers; then
    BROWSER_PACKAGES="chromium-ncz-sky1 google-chrome-stable"
fi
if component_enabled desktop && component_enabled wallpaper-rotator; then
    ART_PACKAGES="ncz-wallpapers-brandon-perlow"
fi
PACKAGES="$BROWSER_PACKAGES $ART_PACKAGES"
PACKAGES=${PACKAGES# }
PACKAGES=${PACKAGES% }

if [ -z "$PACKAGES" ]; then
    echo "[25-live] selected components require no live browser/art packages"
    exit 0
fi

apt_refresh() {
    apt-get update -o Acquire::Check-Date=false \
        -o Acquire::http::Timeout=8 -o Acquire::https::Timeout=8 \
        -o Acquire::Retries=0 -o Acquire::ForceIPv4=true
}

if ! apt_refresh; then
    echo "[25-live] WARN: network/package indexes unavailable; skipping live packages: $PACKAGES" >&2
    echo "[25-live] WARN: install remains usable offline; install these packages later when networking is available" >&2
    exit 0
fi
touch /var/lib/apt/lists/.ncz-installer-refreshed 2>/dev/null || true

install_group() {
    label="$1"
    shift
    [ "$#" -gt 0 ] || return 0
    if DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"; then
        echo "[25-live] $label packages installed: $*"
        return 0
    fi
    echo "[25-live] WARN: $label package install failed; refreshing once and retrying" >&2
    if apt_refresh && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"; then
        echo "[25-live] $label packages installed after retry: $*"
        return 0
    fi
    echo "[25-live] WARN: $label packages remain absent after retry: $*" >&2
    echo "[25-live] WARN: continuing because network packages are optional for an offline install" >&2
    return 0
}

# Keep these transactions independent: an unpublished/missing artist pack must
# never prevent both browsers from installing (and vice versa).
# shellcheck disable=SC2086
install_group browser $BROWSER_PACKAGES
# shellcheck disable=SC2086
install_group artist $ART_PACKAGES

# Preserve 20-desktop's measured Sky1 audio workaround, now after live install.
if [ -f /usr/bin/chromium-ncz-sky1 ]; then
    cat > /usr/bin/chromium-ncz-sky1 <<'CHROMIUMWRAPPER'
#!/bin/sh
# Chromium NCZ Sky1 Edition launcher.
exec /opt/chromium-ncz-sky1/chrome \
  --ozone-platform=wayland \
  --enable-features=AcceleratedVideoDecoder \
  --disable-features=AudioServiceOutOfProcess,AudioServiceSandbox \
  "$@"
CHROMIUMWRAPPER
    chmod 0755 /usr/bin/chromium-ncz-sky1
    echo "[25-live] chromium-ncz-sky1 wrapper: disabled AudioServiceOutOfProcess/AudioServiceSandbox (silent-PCM fix)"
fi

echo "[25-live] live package step complete"
exit 0
