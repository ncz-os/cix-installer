#!/bin/bash
# 51-ncz-tour-slides.sh — install the NCZ-OS tour slides for the desktop.
#
# NCZ-MIXED-HOOK: the four data-only NCZ slides (wallpapers, online wallpapers,
# screensavers, lock screen) are generic; 85-ncz-chromium-vpu.slide is installed
# ONLY on arm64/Sky1 (the platform that ships chromium-ncz-sky1, the NCZ Chromium
# with VPU video acceleration). Arch-gated with the shared NCZ-PLATFORM-GUARD
# idiom so an amd64 install never shows it. The first-login tour launcher is
# generic. TODO split the Sky1 slide into a platform hook when phase C lands
# (docs/platform-inventory.tsv, docs/PLATFORM-SPLIT-DESIGN.md).
#
# The Singularity tour (dev.sinty.tour) ships ten upstream slides in
# /opt/singularity/share/singularity/tour/, owned by the ncz-singularity-desktop
# payload package. This hook drops additional, data-only NCZ slides beside
# them so the tour tells the user about the wallpaper packs, the online
# wallpaper sources, the screensaver catalogue, the lock-screen screensaver and
# (on Sky1) the NCZ Chromium's VPU video acceleration. Nothing is overwritten:
# the NCZ slides use free Order values (55/56/65/75/85) and new filenames, so
# they are added to the deck rather than replacing a slide.
#
# Discovery (verified against upstream singularity-tour @ 5dfe27a, pinned in
# assets/singularity/upstream-pins.tsv): the app reads every *.slide from the
# XDG data dirs — the session sets
# XDG_DATA_DIRS=/opt/singularity/share:/usr/local/share:/usr/share — plus its
# compiled-in gresource, de-duplicates by filename and sorts by Order. Files
# added to the payload's own directory are picked up at the next launch, and at
# first login, since dev.sinty.desktop:show-tour defaults to true (the shell
# opens the tour once and clears the flag).
#
# The same hook also installs the first-login tour launcher. The shell's own
# first-run path (dev.sinty.desktop:show-tour) is unconditional; NCZ opens the
# tour from a guarded, once-only autostart entry instead and disables the
# upstream switch in the NCZ gschema override (20-desktop.sh). See
# assets/branding/first-login-tour/ncz-first-login-tour for the full rationale
# and the guard list. The entry uses OnlyShowIn=Singularity, which the shipped
# shell's AutostartManager requires for a SYSTEM /etc/xdg/autostart entry.
#
# Generic (both target architectures) for the four common slides + the launcher;
# the Sky1 slide is arch-gated. Desktop only: a Server/headless image has no
# Singularity payload, so the hook exits without doing anything.
#
# Idempotent (install -m 0644 overwrites in place). Safe on a live rootfs.
#
# Test seams (build/test-tour-slides.sh): NCZ_TOUR_SLIDES_ASSETS,
# NCZ_TOUR_FIRSTLOGIN_ASSETS, NCZ_TOUR_SLIDES_DIR, NCZ_TOUR_SLIDES_ROOT (prefix
# for the absolute /etc and /usr/local paths so the hook can run unprivileged in
# a sandbox), and NCZ_TARGET_ARCH (the platform-selection override run-all.sh
# already uses; an undetectable arch does NOT add the Sky1 slide).

set -uo pipefail

# NCZ-PLATFORM-GUARD: sky1-arm64 only (docs/PLATFORM-SPLIT-DESIGN.md). Arch
# order matches run-all.sh: NCZ_TARGET_ARCH, then the late.sh BUILD_ARCH stamp,
# then dpkg. An undetectable arch is treated as NOT Sky1, so a Sky1-only slide
# is never shown on a platform we cannot identify (fail safe).
_ncz_pg_arch="${NCZ_TARGET_ARCH:-}"
[ -n "$_ncz_pg_arch" ] || _ncz_pg_arch=$(cat /usr/local/lib/cix-installer/BUILD_ARCH 2>/dev/null | tr -d '[:space:]')
[ -n "$_ncz_pg_arch" ] || _ncz_pg_arch=$(dpkg --print-architecture 2>/dev/null || true)

ASSETS="${NCZ_TOUR_SLIDES_ASSETS:-/usr/local/lib/cix-installer/assets/branding/tour-slides}"
FIRSTLOGIN_ASSETS="${NCZ_TOUR_FIRSTLOGIN_ASSETS:-${ASSETS%/*}/first-login-tour}"
TOURDIR="${NCZ_TOUR_SLIDES_DIR:-/opt/singularity/share/singularity/tour}"
ROOT="${NCZ_TOUR_SLIDES_ROOT:-}"

# The slides every desktop shows, and the Sky1-only one. Split so the arch gate
# and the tests can name them without re-parsing the loop.
NCZ_TOUR_SLIDES_COMMON="55-ncz-wallpapers 56-ncz-online-wallpapers 65-ncz-screensavers 75-ncz-lock"
NCZ_TOUR_SLIDES_SKY1="85-ncz-chromium-vpu"

if [ ! -d "$TOURDIR" ]; then
    echo "[51] no Singularity tour payload at $TOURDIR — skipping NCZ tour slides"
    exit 0
fi
if [ ! -d "$ASSETS" ]; then
    echo "[51] WARN: NCZ tour slide assets missing at $ASSETS — nothing installed" >&2
    exit 0
fi

slides="$NCZ_TOUR_SLIDES_COMMON"
case "$_ncz_pg_arch" in
    arm64|aarch64) slides="$slides $NCZ_TOUR_SLIDES_SKY1" ;;
    *) echo "[51] arch='${_ncz_pg_arch:-unknown}' is not Sky1/arm64; skipping $NCZ_TOUR_SLIDES_SKY1.slide" ;;
esac

installed=0
# shellcheck disable=SC2086  # $slides is a deliberate whitespace-separated list
for s in $slides; do
    src="$ASSETS/$s.slide"
    if [ ! -f "$src" ]; then
        echo "[51] WARN: $src missing" >&2
        continue
    fi
    install -m 0644 "$src" "$TOURDIR/$s.slide"
    installed=$((installed + 1))
done
echo "[51] installed $installed NCZ tour slide(s) into $TOURDIR"

# --- first-login tour launcher (guarded, once-only) -----------------------------
# /etc/ncz is the admin opt-out dir (/etc/ncz/no-first-login-tour); create it so
# an operator can drop the opt-out file without inventing the directory.
install -d -m 0755 "$ROOT/etc/ncz"
if [ -f "$FIRSTLOGIN_ASSETS/ncz-first-login-tour" ] && \
   [ -f "$FIRSTLOGIN_ASSETS/ncz-first-login-tour.desktop" ]; then
    install -d -m 0755 "$ROOT/usr/local/bin"
    install -m 0755 "$FIRSTLOGIN_ASSETS/ncz-first-login-tour" "$ROOT/usr/local/bin/ncz-first-login-tour"
    install -d -m 0755 "$ROOT/etc/xdg/autostart"
    install -m 0644 "$FIRSTLOGIN_ASSETS/ncz-first-login-tour.desktop" \
        "$ROOT/etc/xdg/autostart/ncz-first-login-tour.desktop"
    echo "[51] first-login tour: /usr/local/bin/ncz-first-login-tour + /etc/xdg/autostart/ncz-first-login-tour.desktop"
else
    echo "[51] WARN: first-login tour assets missing at $FIRSTLOGIN_ASSETS — the tour will not auto-open" >&2
fi

exit 0
