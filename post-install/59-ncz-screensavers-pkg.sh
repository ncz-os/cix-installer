#!/bin/bash
# 59-ncz-screensavers-pkg.sh -- install the ncz-screensavers package (engine,
# idle timer, shipped 74-title catalogue) on desktop images. Hard-fails when
# no candidate is available or the install fails.
#
# Since 2026-10-05: screensavers distributed as debs are apt-installed
# during installation. This hook IS that mechanism on desktop
# variants. Headless / server variants skip the install (the lock surface and
# the catalogue have no consumer without a compositor).
#
# The hook is a no-op ONLY on server/headless. On desktop it is mandatory:
#   * no candidate in the package sources  -> exit 1 (silent skip was the bug)
#   * candidate below the version floor     -> exit 1 (stale mirror)
#   * simulate-first runs REMv              -> exit 1 (no removals)
#   * simulate-first runs ncz-screensavers-gtk4-reference -> exit 1 (wrong dist)
#   * apt install rc != 0                   -> exit 1
#   * post-install dpkg query says NOT installed -> exit 1
#
# Note on the package set: ncz-screensavers (the published package,
# amd64+arm64) bundles the engine, the idle daemon, the calibrator, the gschema
# and the shipped 74-title catalogue -- and NOTHING else: no Singularity plugin
# .so/.plugin, no GTK4 settings app, no launcher .desktop entry. The settings
# UI is the Singularity "Screensaver and Lockscreen" plugin, the SEPARATE
# package ncz-screensavers-plugin. It is not published to the NCZ apt repo; the
# image carries a pinned deb on the install medium
# (ncz-payload/assets/ncz-screensavers-plugin/, pin in
# post-install/lib/ncz-screensavers-plugin.lock) and this hook installs it
# right after the engine through post-install/lib/ncz-ssplugin-install.sh:
# sha256 against the pin, ABI against the installed Singularity payload, apt
# simulate-first with no removals, then the .so/.plugin and the
# default-enabled override asserted. A missing or mismatched plugin is a
# FATAL (exit 1): the engine stays installed, the installed-target verifier
# fails the image gate. Supply chain: post-install/lib/ncz-screensavers-plugin.lock.
# 62-cygnus-screensaver-default.sh (override validated against the compiled
# schema) sits downstream of this hook and pins the default saver to
# blackhole_gles3 / palette cygnus.
#
# Idempotent: re-running on a system that already has ncz-screensavers (and the
# pinned plugin) installed only re-asserts (installs happen when dpkg says the
# package is absent).
set -uo pipefail

echo "[59-ncz-screensavers] enforcing ncz-screensavers install on desktop variants"

VARIANT=desktop
if [ -f /usr/local/lib/cix-installer/BUILD_VARIANT ]; then
    VARIANT=$(tr -d ' \t\r\n' < /usr/local/lib/cix-installer/BUILD_VARIANT)
fi
case "$VARIANT" in
    server|headless)
        echo "[59-ncz-screensavers] BUILD_VARIANT=$VARIANT -- headless SKU; skipping"
        exit 0
        ;;
esac

# Single source of truth for the version floor. The file ships in the staging
# tree (build/) and is sourced identically by every other consumer (the
# offline-mirror builders, the test, the post-install verifier). Update once,
# in one commit; everywhere reads it through the same helper.
HERE_CI="$(cd "$(dirname "$0")" && pwd)"
# The plugin step (pin + ABI rule + offline install); see the header.
# shellcheck source=./lib/ncz-ssplugin-install.sh
. "$HERE_CI/lib/ncz-ssplugin-install.sh"
SCREENSAVERS_VERSION_ENV=""
for p in \
    "$HERE_CI/../build/screensavers-version.env" \
    /usr/local/lib/cix-installer/build/screensavers-version.env; do
    if [ -r "$p" ]; then SCREENSAVERS_VERSION_ENV="$p"; break; fi
done
if [ -z "$SCREENSAVERS_VERSION_ENV" ]; then
    echo "[59-ncz-screensavers] FATAL: build/screensavers-version.env not found -- refusing to install without a version floor" >&2
    exit 1
fi
# shellcheck disable=SC1090
. "$SCREENSAVERS_VERSION_ENV"
# set -u only catches unset names; a present-but-empty floor would make every
# dpkg --compare-versions below meaningless, so require non-empty values.
for v in NCZ_SCREENSAVERS_MIN_VERSION NCZ_SCREENSAVERS_MISSING_MSG NCZ_SCREENSAVERS_TOO_OLD_MSG; do
    if [ -z "${!v:-}" ]; then
        echo "[59-ncz-screensavers] FATAL: $v is empty or missing in $SCREENSAVERS_VERSION_ENV -- refusing to install without a version floor" >&2
        exit 1
    fi
done

# --- candidate lookup ---------------------------------------------------------
ss_installed() { dpkg -s "$1" 2>/dev/null | grep -q '^Status: install ok installed'; }

PKG=ncz-screensavers
if ss_installed "$PKG"; then
    INSTALLED_VER="$(dpkg-query -W -f='${Version}' "$PKG" 2>/dev/null)"
    echo "[59-ncz-screensavers] $PKG already installed ($INSTALLED_VER); checking floor >= ${NCZ_SCREENSAVERS_MIN_VERSION}"
    if dpkg --compare-versions "$INSTALLED_VER" ge "$NCZ_SCREENSAVERS_MIN_VERSION"; then
        echo "[59-ncz-screensavers] OK: $PKG $INSTALLED_VER >= $NCZ_SCREENSAVERS_MIN_VERSION"
        ncz_ssplugin_install; exit $?
    fi
    echo "[59-ncz-screensavers] $PKG $INSTALLED_VER is BELOW the required floor $NCZ_SCREENSAVERS_MIN_VERSION; will attempt to upgrade" >&2
fi

CAND="$(apt-cache policy "$PKG" 2>/dev/null | sed -n 's/^  Candidate: //p')"
if [ -z "$CAND" ] || [ "$CAND" = "(none)" ]; then
    echo "[59-ncz-screensavers] FATAL: no candidate for $PKG in the configured package sources" >&2
    echo "[59-ncz-screensavers]       ($NCZ_SCREENSAVERS_MISSING_MSG)" >&2
    echo "[59-ncz-screensavers]       configured sources:" >&2
    apt-cache policy 2>/dev/null | sed -n 's/^[[:space:]]*[0-9]\+[[:space:]]\+\([^ ]\+\).*/\1/p' | sort -u | sed 's/^/        /' >&2
    exit 1
fi
if ! dpkg --compare-versions "$CAND" ge "$NCZ_SCREENSAVERS_MIN_VERSION"; then
    echo "[59-ncz-screensavers] FATAL: candidate $PKG $CAND is BELOW the required floor $NCZ_SCREENSAVERS_MIN_VERSION" >&2
    echo "[59-ncz-screensavers]       ($NCZ_SCREENSAVERS_TOO_OLD_MSG)" >&2
    exit 1
fi

# --- guards: simulate-first, no removals, never the gtk4-reference app --------
WANT="$PKG"
case " $WANT " in *" ncz-screensavers-gtk4-reference "*) echo "[59-ncz-screensavers] refusing ncz-screensavers-gtk4-reference" >&2; exit 1 ;; esac

sim="$(DEBIAN_FRONTEND=noninteractive apt-get install -s -y --no-install-recommends $WANT 2>&1)" || {
    echo "[59-ncz-screensavers] simulation failed; refusing to install:" >&2
    printf '%s\n' "$sim" | tail -15 >&2
    exit 1
}
if printf '%s\n' "$sim" | grep -q '^Remv '; then
    echo "[59-ncz-screensavers] simulation would REMOVE packages; refusing:" >&2
    printf '%s\n' "$sim" | grep '^Remv ' >&2
    exit 1
fi
if printf '%s\n' "$sim" | grep -q '^Inst ncz-screensavers-gtk4-reference'; then
    echo "[59-ncz-screensavers] simulation would install ncz-screensavers-gtk4-reference; refusing" >&2
    exit 1
fi

echo "[59-ncz-screensavers] installing:$WANT (candidate $CAND, floor $NCZ_SCREENSAVERS_MIN_VERSION)"
out="$(DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $WANT 2>&1)"
rc=$?
printf '%s\n' "$out" | tail -8
if [ "$rc" -ne 0 ]; then
    echo "[59-ncz-screensavers] FATAL: apt install failed rc=$rc" >&2
    exit 1
fi

# --- post-install assertions on the live rootfs (chroot or live install) ------
ss_installed "$PKG" || { echo "[59-ncz-screensavers] FATAL: $PKG is not in the installed state after apt" >&2; exit 1; }
INSTALLED_VER="$(dpkg-query -W -f='${Version}' "$PKG" 2>/dev/null)"
echo "[59-ncz-screensavers] installed $PKG $INSTALLED_VER"

# --- upgrade to the staged build, if the medium carries one ------------------
# The pinned pool still ships 0.8.18, which cannot re-draw the black hole's
# viewing geometry and whose feed renderer ignores the height cap (O6N drew
# 4388x2468 at ~175 ms a frame). Both fixes live in the package, in the 74 hack
# binaries and in the feed path, so installing only the engine binary would leave
# the other savers -- and the lock-screen path -- on the old behaviour. The deb is
# staged on the medium by 58-screensaver-shader.sh's asset set.
ARCH="$(dpkg --print-architecture 2>/dev/null)"
STAGED=""
for c in /usr/local/lib/cix-installer/assets/screensaver "$ARCH" \
         /cdrom/ncz-payload/assets/screensaver/"$ARCH" \
         /run/ncz-payload/assets/screensaver/"$ARCH"; do
    case "$c" in
        */"$ARCH") deb="$(ls "$c"/ncz-screensavers_*.deb 2>/dev/null | sort -V | tail -1)";;
        *)         deb="$(ls "$c/$ARCH"/ncz-screensavers_*.deb 2>/dev/null | sort -V | tail -1)";;
    esac
    [ -n "$deb" ] && { STAGED="$deb"; break; }
done
if [ -n "$STAGED" ]; then
    if DEBIAN_FRONTEND=noninteractive dpkg -i "$STAGED" >/tmp/ncz-ss-upgrade.log 2>&1; then
        echo "[59-ncz-screensavers] upgraded to $(dpkg-query -W -f='${Version}' "$PKG") from $(basename "$STAGED")"
        command -v glib-compile-schemas >/dev/null 2>&1 && \
            glib-compile-schemas /usr/share/glib-2.0/schemas >/dev/null 2>&1
    else
        echo "[59-ncz-screensavers] WARN: staged upgrade failed; keeping $INSTALLED_VER" >&2
        tail -3 /tmp/ncz-ss-upgrade.log >&2
    fi
else
    echo "[59-ncz-screensavers] no staged build on the medium; pool version stands"
fi

# Engine binary + idle daemon + shipped catalogue + schema (live proof -- the
# post-install verify-installed-target.sh re-asserts the same against the
# finished squashfs, this catches "apt exited 0 but unpack failed" early).
for f in /usr/bin/ncz-screensaver \
         /usr/libexec/ncz-screensaver-idled \
         /usr/libexec/ncz-screensaver-run \
         /usr/libexec/ncz-screensavers/ncz-screensaver-calibrate \
         /usr/lib/systemd/user/ncz-screensaver-idled.service \
         /usr/share/glib-2.0/schemas/dev.ncz.screensaver.gschema.xml \
         /usr/share/ncz-screensavers/hacks.tsv; do
    if [ ! -e "$f" ]; then
        echo "[59-ncz-screensavers] FATAL: $PKG unpacked but $f is absent" >&2
        exit 1
    fi
done

# Maintainer assertion: a wrong-source mirror of a same-named package would
# silently install; the operator's email in the Maintainer field is the cheapest
# proof we are running our own artifact.
MAINT="$(dpkg-query -W -f='${Maintainer}' "$PKG" 2>/dev/null)"
if [ "$MAINT" != "$NCZ_SCREENSAVERS_REQUIRED_MAINTAINER" ]; then
    echo "[59-ncz-screensavers] FATAL: $PKG Maintainer is '$MAINT', expected '$NCZ_SCREENSAVERS_REQUIRED_MAINTAINER' (a wrong-source mirror would silently install here)" >&2
    exit 1
fi

# The shipped catalogue must be non-empty: a packaged file may be empty if the
# upstream build path broke. Row count is informational, not a gate; the
# installer owns the assertion that the catalogue carries 74 titles.
ROWS=$(wc -l < /usr/share/ncz-screensavers/hacks.tsv 2>/dev/null | tr -d ' ')
echo "[59-ncz-screensavers] shipped catalogue rows: ${ROWS:-0}"

echo "[59-ncz-screensavers] OK: $PKG $INSTALLED_VER installed and asserted"
# The settings plugin needs the engine (Depends: ncz-screensavers), so it comes last.
ncz_ssplugin_install; exit $?