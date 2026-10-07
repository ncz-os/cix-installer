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
if [ -n "$GIT_SHA" ]; then
    GIT_TAG="git${GIT_SHA:0:8}"
elif [ -f "$TGZ" ]; then
    # No upstream SHA supplied: tag with the tarball content hash so different
    # content never reuses a version.
    GIT_TAG="tgz$(sha256sum "$TGZ" | cut -c1-8)"
else
    GIT_TAG="tgz00000000"
fi
VERSION="${NCZ_SINGULARITY_VERSION:-$(date -u +%Y%m%d)+bk${BUILDKITE_BUILD_NUMBER:-0}+${GIT_TAG}}"
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
    [ -n "$STAGE" ] && rm -rf "$STAGE" "$STAGE.depends"
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

# Depends: is derived from THIS payload's ELF closure on every build, never a
# hand-kept list. The old literal list (18 entries) omitted libraries the
# payload links -- libseat1, libinput10, libliftoff0, libxcb-errors0,
# libdisplay-info3, libpipewire-0.3-0t64, libpam0g, ... -- so a clean
# `apt-get install` produced an unrunnable desktop. The vetted published
# 20261005+...+deps1 package fixed that once by hand; this makes every head
# build carry the equivalent automatically.
#
# Source, in order:
#   1. $NCZ_SINGULARITY_DEPENDS_FILE, else "$TGZ.depends": the sidecar that
#      build-singularity.sh writes from inside its debian:<codename> build
#      container (build/singularity-deb-depends.sh --direct). Accepted only if
#      it names this exact tarball (sha256) and this architecture.
#   2. otherwise build/singularity-deb-depends.sh --container: the same
#      analysis in a fresh debian:<codename> container for $ARCH (qemu-user
#      for a foreign arch). Disable with NCZ_SINGULARITY_DEPENDS_CONTAINER=0,
#      which turns a missing/stale sidecar into a hard error.
# There is no built-in fallback list: a payload whose Depends cannot be
# derived is not packaged.
TGZ_SHA="$(sha256sum "$TGZ" | cut -d' ' -f1)"
DEPS_SIDECAR="${NCZ_SINGULARITY_DEPENDS_FILE:-$TGZ.depends}"
DEPS_SRC=""
deps_field() { sed -n "s/^$1: //p" "$2" | head -n1; }
if [ -s "$DEPS_SIDECAR" ]; then
    _sc_sha="$(deps_field X-Payload-SHA256 "$DEPS_SIDECAR")"
    _sc_arch="$(deps_field X-Architecture "$DEPS_SIDECAR")"
    if [ "$_sc_sha" = "$TGZ_SHA" ] && [ "$_sc_arch" = "$ARCH" ]; then
        DEPS_SRC="$DEPS_SIDECAR"
    else
        echo "WARN: ignoring $DEPS_SIDECAR: it describes sha256=${_sc_sha:-?} arch=${_sc_arch:-?}, not this payload (sha256=$TGZ_SHA arch=$ARCH)" >&2
    fi
fi
if [ -z "$DEPS_SRC" ]; then
    if [ "${NCZ_SINGULARITY_DEPENDS_CONTAINER:-1}" = 0 ]; then
        echo "ERROR: no Depends sidecar matching $TGZ (sha256=$TGZ_SHA arch=$ARCH) and container derivation is disabled" >&2
        echo "       build the payload with build/build-singularity.sh (it writes \$TGZ.depends), or run" >&2
        echo "       build/singularity-deb-depends.sh --container --arch $ARCH -o $TGZ.depends $TGZ" >&2
        exit 1
    fi
    echo "== deriving Depends in a debian container for $ARCH (no matching sidecar) =="
    bash "$REPO/build/singularity-deb-depends.sh" --container --arch "$ARCH" \
        --payload-sha256 "$TGZ_SHA" -o "$STAGE.depends" "$TGZ"
    DEPS_SRC="$STAGE.depends"
fi
DEPENDS="$(deps_field Depends "$DEPS_SRC")"
[ -n "$DEPENDS" ] || { echo "ERROR: $DEPS_SRC carries no Depends" >&2; exit 1; }
echo "== Depends source: $DEPS_SRC ($(printf '%s\n' "$DEPENDS" | tr ',' '\n' | wc -l) entries) =="

# Recommends: runtime modules the shell dlopens or reaches over D-Bus/GIO.
# They are not DT_NEEDED, so they cannot be derived from the ELF closure; the
# package installs without them but features degrade. Same set as the vetted
# +deps1 package (Item Q3 evidence); build/test-singularity-deb-depends.sh
# pins it so it cannot drift silently:
#   adwaita-icon-theme         desktop lists/applies the "Adwaita" icon theme
#   gsettings-desktop-schemas  shell reads org.gnome.desktop.* schemas
#   dconf-gsettings-backend    persistence backend for its GSettings use
#   glib-networking            GIO TLS backend (singularity-store, wallpapers)
#   ca-certificates            trust store for those TLS connections
#   xdg-desktop-portal         frontend for xdg-desktop-portal-singularity
#   gstreamer1.0-gtk4          playbin sink for videos/music
#   gstreamer1.0-plugins-base, -good, gstreamer1.0-libav  media playback
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

# r201 version discipline: refuse to rebuild an already-published version with
# different content (apt would show "X -> X"); see build/lib/deb-version-gate.sh.
# shellcheck source=lib/deb-version-gate.sh
. "$REPO/build/lib/deb-version-gate.sh"
ncz_deb_version_gate "$OUTDEB" || exit 1

echo "== package self-check: $OUTDEB =="
dpkg-deb -I "$OUTDEB"
dpkg-deb -c "$OUTDEB"

echo ""
echo "Final .deb: $OUTDEB"
echo "Next: publish to the apt repo:"
echo "  ssh -i ~/.ssh/id_ed25519_argonas_apt jasonperlow@192.168.207.22 < $OUTDEB"
echo "  (or, on any host with jasonperlow SSH access to ARGOS: ssh jasonperlow@192.168.207.22 < $OUTDEB"
echo "   — the includedeb+R2-publish logic lives in ARGOS:~/bin/ncz-reprepro-publish.sh)"
