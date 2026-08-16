#!/bin/bash
# build-singularity-deb.sh — wrap the NCZ-OS Singularity Desktop payload in a
# real Debian package for publication to the NCZ-OS apt repository.
#
# The input is the singularity-opt.tgz produced by build-singularity.sh.  The
# tarball's opt/singularity tree is retained byte-for-byte under /opt in the
# package; the package maintainer scripts only manage the ldconfig integration.
#
# Usage:
#   ./build/build-singularity-deb.sh [path-to-singularity-opt.tgz]
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
TGZ="${1:-$REPO/build/sinty-out/singularity-opt.tgz}"
PKG="ncz-singularity-desktop"
ARCH=arm64
GIT_SHA="${NCZ_SINGULARITY_GIT_SHA:-}"
VERSION="${NCZ_SINGULARITY_VERSION:-$(date -u +%Y%m%d)+bk${BUILDKITE_BUILD_NUMBER:-0}${GIT_SHA:+~g${GIT_SHA}}}"
OUT="${OUT:-$(cd "$(dirname "$TGZ")" && pwd)}"
STAGE=""

# Guard against a bad externally-supplied NCZ_SINGULARITY_VERSION (the
# computed default is always well-formed; an override is not validated
# otherwise — Codex review 2026-07-26). dpkg itself is the source of truth
# for what a valid Debian version string is.
if command -v dpkg >/dev/null 2>&1; then
    dpkg --validate-version "$VERSION" || {
        echo "ERROR: '$VERSION' is not a valid Debian version string (NCZ_SINGULARITY_VERSION override?)" >&2
        exit 1
    }
fi

[ -f "$TGZ" ] || { echo "ERROR: Singularity tarball not found: $TGZ" >&2; exit 1; }
mkdir -p "$OUT"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/ncz-singularity-deb.XXXXXX")"
cleanup() {
    rc=$?
    [ -n "$STAGE" ] && rm -rf "$STAGE"
    if [ "$rc" -ne 0 ]; then
        echo "ERROR: Singularity .deb build failed (exit $rc)" >&2
    fi
    exit "$rc"
}
trap cleanup EXIT

# Extract exactly as produced by build-singularity.sh.  In particular, do not
# broadly chmod the payload: its permissions are part of the build output.
mkdir -p "$STAGE/DEBIAN"
tar -C "$STAGE" -xzf "$TGZ"
test -x "$STAGE/opt/singularity/bin/singularity-desktop"
test -x "$STAGE/opt/singularity/bin/singularity-labwc-session"

cat > "$STAGE/DEBIAN/control" <<CONTROL
Package: $PKG
Version: $VERSION
Architecture: $ARCH
Maintainer: Jason Perlow <jperlow@gmail.com>
Section: x11
Priority: optional
Depends: libc6, libgtk-4-1, libadwaita-1-0, libgtk4-layer-shell0, libgee-0.8-2, libpeas-2-0, libjson-glib-1.0-0, libsoup-3.0-0, libvte-2.91-gtk4-0, libgtksourceview-5-0, libwebkitgtk-6.0-4, libgraphene-1.0-0, libupower-glib3, libdbusmenu-glib4, libsodium26 | libsodium23, upower, libtinysparql-3.0-0 | libtracker-sparql-3.0-0
Description: NCZ-OS Singularity Desktop runtime payload
 Bundled /opt/singularity tree: singularity-shell, libsingularity,
 singularity-greeter, singularity-boot-splash, singularity-loginui,
 singularity-lockscreen, xdg-desktop-portal-singularity,
 singularity-keyring, singularity-polkit-agent, apps, plugins, themes
 and wallpapers. See post-install/20-desktop.sh for session wiring.
CONTROL

cat > "$STAGE/DEBIAN/postinst" <<'POSTINST'
#!/bin/sh
set -e

if [ "$1" = configure ]; then
    echo "/opt/singularity/lib" > /etc/ld.so.conf.d/singularity.conf
    ldconfig

    # Compile the bundled GSettings schemas. Without this the desktop
    # SIGABRTs on startup, in a ~3s respawn loop, until greetd gives up:
    #
    #   g_settings_get_int -> g_settings_get_value -> g_log (fatal) -> abort
    #
    # GLib only ever reads gschemas.compiled; it never parses the raw XML.
    # We ship dev.sinty.*.gschema.xml plus 99-ncz-defaults.gschema.override
    # into /opt/singularity/share/glib-2.0/schemas and the session wrapper
    # correctly points GSETTINGS_SCHEMA_DIR at that directory -- but nothing
    # ever compiled it, so GLib saw zero schemas there and every
    # g_settings_* call on dev.sinty.desktop aborted the process.
    # Confirmed on O6N 2026-08-14 with r237:
    #   gsettings list-schemas | grep -c sinty   -> 0    (before)
    #   ... after glib-compile-schemas           -> 11   (desktop starts)
    if [ -x /usr/bin/glib-compile-schemas ] \
       && [ -d /opt/singularity/share/glib-2.0/schemas ]; then
        glib-compile-schemas /opt/singularity/share/glib-2.0/schemas || true
    fi
fi

exit 0
POSTINST
chmod 0755 "$STAGE/DEBIAN/postinst"

cat > "$STAGE/DEBIAN/postrm" <<'POSTRM'
#!/bin/sh
set -e

case "$1" in
    remove|purge)
        rm -f /etc/ld.so.conf.d/singularity.conf
        rm -f /opt/singularity/share/glib-2.0/schemas/gschemas.compiled
        ldconfig
        ;;
esac

exit 0
POSTRM
chmod 0755 "$STAGE/DEBIAN/postrm"

OUTDEB="$OUT/${PKG}_${VERSION}_${ARCH}.deb"
echo "== building Debian package =="
echo "   input  = $TGZ"
echo "   output = $OUTDEB"
echo "   version= $VERSION"
# Capture the help text first rather than piping it into `grep -q`. Under
# `set -o pipefail` that pipeline is a race: grep -q exits the moment it
# matches, dpkg-deb takes SIGPIPE, and the pipeline reports failure even though
# the option IS supported -- so the script falls through to the fakeroot branch
# and dies with "dpkg-deb lacks --root-owner-group and fakeroot is unavailable"
# on a host whose dpkg-deb (1.23.7) supports it perfectly well. Observed
# intermittently on 2026-08-16: the same invocation failed, succeeded, then
# failed again, and always succeeded under `bash -x` (which slows dpkg-deb
# enough to lose the race). An intermittent packaging failure is worse than a
# consistent one -- it gets retried until it passes and never investigated.
_dpkg_deb_help="$(dpkg-deb --help 2>&1 || true)"
if printf '%s' "$_dpkg_deb_help" | grep -q -- '--root-owner-group'; then
    dpkg-deb --build --root-owner-group "$STAGE" "$OUTDEB"
else
    command -v fakeroot >/dev/null 2>&1 || {
        echo "ERROR: dpkg-deb lacks --root-owner-group and fakeroot is unavailable" >&2
        exit 1
    }
    fakeroot dpkg-deb --build "$STAGE" "$OUTDEB"
fi

echo "== package self-check: $OUTDEB =="
dpkg-deb -I "$OUTDEB"
dpkg-deb -c "$OUTDEB"

echo ""
echo "Final .deb: $OUTDEB"
echo "Next: publish to the apt repo:"
echo "  ssh -i ~/.ssh/id_ed25519_argonas_apt jasonperlow@192.168.207.22 < $OUTDEB"
echo "  (or, on any host with jasonperlow SSH access to ARGOS: ssh jasonperlow@192.168.207.22 < $OUTDEB"
echo "   — the includedeb+R2-publish logic lives in ARGOS:~/bin/ncz-reprepro-publish.sh)"
