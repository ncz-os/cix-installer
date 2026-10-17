#!/bin/bash
# 61-chromium-icon.sh -- install the Cygnus-coloured NCZ Chromium icon (Sky1 only).
#
# The chromium-ncz-sky1 package ships the launcher icon `chromium-ncz-sky1` in hicolor at
# 16 22 24 32 48 64 128 256 512 px, plus /usr/share/pixmaps/chromium-ncz-sky1.png (a copy of
# the 256 px icon), in the old 26.7 orange palette. 26.10 Cygnus uses a
# magenta -> violet -> cyan ring around the black hole
# (branding/cygnus/tools/render-chromium-icon.py,
# assets/branding/icons/chromium-ncz-sky1/).
#
# The package owns those files, so overwriting them would be undone by the next package
# install or upgrade. Each path is therefore diverted (dpkg-divert --rename) and ours
# installed at the original path: dpkg then writes the package's version to
# <path>.maximilian-orig and ours stays. The diversion is added whether or not the package
# is installed yet, so the order does not matter: if chromium-ncz-sky1 is installed or
# upgraded AFTER this hook, its icons land at the divert names and the Cygnus icons remain.
# The scalable SVG is not owned by the package and is installed directly.
#
# Idempotent. Never fails the install: every problem is a warning and the hook exits 0.
# Must be on run-all.sh MACHINE_HOOKS_RE as well as hooks.list.sky1-arm64, or baked
# (--mode full) installs never run it (build/test-run-all-baked-allowlist.sh).
# Test seams (used by build/test-chromium-icon.sh): NCZ_ICON_ROOT, NCZ_ICON_PIXMAPS,
# NCZ_ICON_ASSETS, NCZ_ICON_PACKAGE_PRESENT=1|0 (skip the dpkg query).
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
PIXMAPS="${NCZ_ICON_PIXMAPS:-/usr/share/pixmaps}"
ASSETS="${NCZ_ICON_ASSETS:-/usr/local/lib/cix-installer/assets/branding/icons/chromium-ncz-sky1}"
NAME=chromium-ncz-sky1
SIZES="16 22 24 32 48 64 128 256 512"
SUFFIX=maximilian-orig

echo "[61] Cygnus NCZ Chromium icon"

present="${NCZ_ICON_PACKAGE_PRESENT:-}"
if [ -z "$present" ]; then
    present=0
    dpkg-query -W -f='${Status}' "$NAME" 2>/dev/null | grep -q "install ok installed" && present=1
fi
if [ "$present" = 1 ]; then
    echo "[61]   $NAME is installed; diverting its icons"
else
    echo "[61]   $NAME is not installed yet; diverting its icon paths ahead of it"
fi
if [ ! -d "$ASSETS" ]; then
    echo "[61]   WARN: icon assets absent ($ASSETS); keeping the package icons" >&2
    exit 0
fi

# place SRC DST: divert DST away from any package (once), then install SRC at DST.
n=0
place() {
    local src="$1" dst="$2"
    [ -s "$src" ] || { echo "[61]   WARN: missing $src" >&2; return 0; }
    if ! dpkg-divert --list "$dst" 2>/dev/null | grep -qF "diversion of $dst to "; then
        dpkg-divert --package ncz-cygnus-branding --divert "$dst.$SUFFIX" --rename --add "$dst" >/dev/null 2>&1 \
            || echo "[61]   WARN: could not divert $dst; a package upgrade may restore the old icon" >&2
    fi
    install -d -m0755 "$(dirname "$dst")"
    install -m0644 "$src" "$dst" && n=$((n + 1))
    return 0
}

for s in $SIZES; do
    place "$ASSETS/$s.png" "$ICON_ROOT/${s}x${s}/apps/$NAME.png"
done
place "$ASSETS/256.png" "$PIXMAPS/$NAME.png"

if [ -s "$ASSETS/$NAME.svg" ]; then
    install -d -m0755 "$ICON_ROOT/scalable/apps"
    install -m0644 "$ASSETS/$NAME.svg" "$ICON_ROOT/scalable/apps/$NAME.svg" && n=$((n + 1))
fi

# Launchers and the dock resolve Icon=chromium-ncz-sky1 through the GTK icon cache; refresh
# it so a stale cache cannot keep serving the package's icon.
if [ -z "${NCZ_ICON_ROOT:-}" ] && command -v gtk-update-icon-cache >/dev/null 2>&1; then
    gtk-update-icon-cache -q -t -f "$ICON_ROOT" 2>/dev/null \
        || echo "[61]   WARN: gtk-update-icon-cache failed for $ICON_ROOT" >&2
fi
echo "[61]   installed $n Cygnus icon file(s) for $NAME"
exit 0
