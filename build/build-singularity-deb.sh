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
# amd64/PEGASUS port: this was hardcoded arm64. build-singularity.sh builds
# natively for whatever arch the container engine's default platform is (no
# cross/emulation), so the produced singularity-opt.tgz binaries match the
# BUILD HOST's arch, not necessarily arm64. Default to the host's dpkg arch;
# allow an explicit override (e.g. building the .deb on a different host than
# the one that produced the tarball).
ARCH="${NCZ_SINGULARITY_ARCH:-$(dpkg --print-architecture 2>/dev/null || uname -m)}"
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

# Depends: is the runtime soname closure of the payload, not a hand-kept list.
# Item G (2026-10-05) found the previous hardcoded list omitted libraries the
# payload links (libnm0, libpulse-mainloop-glib0, libgoa-1.0-0b, libinput10,
# libliftoff0, libpoppler-glib8, libseat1, libxcb-*) so a clean
# `apt-get install` left singularity-desktop unresolvable. The list is now
# generated from the real payload by build/gen-singularity-deb-depends.sh
# (run inside debian:forky -- release.conf NCZ_BASE_CODENAME -- with apt-file)
# and checked in as:
#   build/singularity-runtime-deps.tsv   soname<TAB>package evidence
#   build/singularity-deb-depends.txt    sorted Depends: entries
# build/test-singularity-deb-deps.sh asserts every mapped soname stays covered.
DEPS_FILE="$REPO/build/singularity-deb-depends.txt"
[ -f "$DEPS_FILE" ] || { echo "ERROR: Depends source missing: $DEPS_FILE" >&2; exit 1; }
DEPENDS="$(grep -vE '^[[:space:]]*(#|$)' "$DEPS_FILE" | paste -sd, -)"
[ -n "$DEPENDS" ] || { echo "ERROR: $DEPS_FILE has no entries" >&2; exit 1; }

# Recommends: runtime modules the shell dlopens or reaches over D-Bus/GIO. They
# are not DT_NEEDED, so the package still installs without them, but features
# degrade. Evidence is the payload strings + session wrapper captured in the
# Item Q3 report (singularity-deps evidence); per entry:
#   - adwaita-icon-theme      desktop lists/applies the "Adwaita" icon theme
#   - gsettings-desktop-schemas  shell reads org.gnome.desktop.* schemas
#   - dconf-gsettings-backend the persistence backend for its GSettings use
#   - glib-networking         GIO TLS backend for the https endpoints used by
#                             singularity-store and the wallpaper plugins
#   - ca-certificates         trust store for those TLS connections
#   - xdg-desktop-portal      frontend for the shipped portal backend
#                             (GTK_USE_PORTAL=1 + xdg-desktop-portal-singularity)
#   - gstreamer1.0-gtk4       playbin sink for videos/music
#   - gstreamer1.0-plugins-base/good, gstreamer1.0-libav  codecs/autodetect
RECOMMENDS="adwaita-icon-theme, gsettings-desktop-schemas, dconf-gsettings-backend, glib-networking, ca-certificates, xdg-desktop-portal, gstreamer1.0-gtk4, gstreamer1.0-plugins-base, gstreamer1.0-plugins-good, gstreamer1.0-libav"

cat > "$STAGE/DEBIAN/control" <<CONTROL
Package: $PKG
Version: $VERSION
Architecture: $ARCH
Maintainer: Jason Perlow <jperlow@gmail.com>
Section: x11
Priority: optional
Depends: $DEPENDS
Recommends: $RECOMMENDS
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
    # Some vendored subprojects (labwc's wlroots -> libdisplay-info chain)
    # install under the GNU multiarch triplet dir instead of flat lib/,
    # because meson's default libdir isn't propagated through 3 levels of
    # nested subproject wraps. Cover both, or labwc dlopen-fails on
    # libdisplay-info.so.5 and greetd crash-loops into a black screen.
    # Confirmed live 2026-09-15 (external tester "blood", real O6 hardware).
    printf '%s\n%s\n' "/opt/singularity/lib/aarch64-linux-gnu" "/opt/singularity/lib" > /etc/ld.so.conf.d/singularity.conf
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
