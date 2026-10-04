#!/bin/bash
# 61-chromium-icon.sh -- install the Cygnus-coloured NCZ Chromium icon (Sky1 only).
#
# The chromium-ncz-sky1 package ships the launcher icon `chromium-ncz-sky1` in hicolor at
# 16 22 24 32 48 64 128 256 512 px in the 26.7 Maximilian orange. 26.10 Cygnus uses a
# magenta -> violet -> cyan ring around the black hole (branding/cygnus/tools/
# render-chromium-icon.py, assets/branding/icons/chromium-ncz-sky1/).
#
# The package owns those files, so overwriting them would be undone by the next package
# upgrade. Each owned file is therefore diverted (dpkg-divert --rename) and ours installed at
# the original path: dpkg then installs the package's version next to it and ours stays.
# The scalable SVG is not owned by the package and is installed directly.
#
# Idempotent. Never fails the install: every problem is a warning and the hook exits 0.
# Test seams (used by build/test-chromium-icon.sh): NCZ_ICON_ROOT, NCZ_ICON_ASSETS,
# NCZ_ICON_PACKAGE_PRESENT=1 (skip the dpkg query).
set -u

# NCZ-PLATFORM-GUARD: sky1-arm64 only (docs/PLATFORM-SPLIT-DESIGN.md). Arch order matches
# run-all.sh: NCZ_TARGET_ARCH, then the late.sh BUILD_ARCH stamp, then dpkg. An
# undetectable arch does NOT skip (legacy behavior).
_ncz_pg_arch="${NCZ_TARGET_ARCH:-}"
[ -n "$_ncz_pg_arch" ] || _ncz_pg_arch=$(cat /usr/local/lib/cix-installer/BUILD_ARCH 2>/dev/null | tr -d '[:space:]')
[ -n "$_ncz_pg_arch" ] || _ncz_pg_arch=$(dpkg --print-architecture 2>/dev/null || true)
case "$_ncz_pg_arch" in
    arm64|aarch64|"") ;;
    *) echo "[${0##*/}] platform guard: arch=$_ncz_pg_arch is not sky1-arm64; skipping"; exit 0 ;;
esac

ICON_ROOT="${NCZ_ICON_ROOT:-/usr/share/icons/hicolor}"
ASSETS="${NCZ_ICON_ASSETS:-/usr/local/lib/cix-installer/assets/branding/icons/chromium-ncz-sky1}"
NAME=chromium-ncz-sky1
SIZES="16 22 24 32 48 64 128 256 512"
SUFFIX=maximilian-orig

echo "[61] Cygnus NCZ Chromium icon"

if [ -z "${NCZ_ICON_PACKAGE_PRESENT:-}" ]; then
    if ! dpkg-query -W -f='${Status}' chromium-ncz-sky1 2>/dev/null | grep -q "install ok installed"; then
        echo "[61]   chromium-ncz-sky1 is not installed; nothing to recolour"
        exit 0
    fi
fi
if [ ! -d "$ASSETS" ]; then
    echo "[61]   WARN: icon assets absent ($ASSETS); keeping the package icons" >&2
    exit 0
fi

n=0
for s in $SIZES; do
    src="$ASSETS/$s.png"
    dst="$ICON_ROOT/${s}x${s}/apps/$NAME.png"
    [ -s "$src" ] || { echo "[61]   WARN: missing $src" >&2; continue; }
    if [ -e "$dst" ] && ! dpkg-divert --list "$dst" 2>/dev/null | grep -q "$dst"; then
        dpkg-divert --package ncz-cygnus-branding --divert "$dst.$SUFFIX" --rename --add "$dst" >/dev/null 2>&1 \
            || echo "[61]   WARN: could not divert $dst" >&2
    fi
    install -d -m0755 "$(dirname "$dst")"
    install -m0644 "$src" "$dst" && n=$((n + 1))
done

if [ -s "$ASSETS/$NAME.svg" ]; then
    install -d -m0755 "$ICON_ROOT/scalable/apps"
    install -m0644 "$ASSETS/$NAME.svg" "$ICON_ROOT/scalable/apps/$NAME.svg" && n=$((n + 1))
fi

if [ -z "${NCZ_ICON_ROOT:-}" ] && command -v gtk-update-icon-cache >/dev/null 2>&1; then
    gtk-update-icon-cache -q -f "$ICON_ROOT" 2>/dev/null || true
fi
echo "[61]   installed $n Cygnus icon file(s) for $NAME"
exit 0
