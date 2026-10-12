#!/bin/bash
# 51-ncz-tour-slides.sh — install the NCZ-OS tour slides for the desktop.
#
# The Singularity tour (dev.sinty.tour) ships ten upstream slides in
# /opt/singularity/share/singularity/tour/, owned by the ncz-singularity-desktop
# payload package. This hook drops four additional, data-only NCZ slides beside
# them so the tour tells the user about the wallpaper packs, the online
# wallpaper sources, the screensaver catalogue and the lock-screen screensaver.
# Nothing is overwritten: the NCZ slides use free Order values (55/56/65/75) and
# new filenames, so they are added to the deck rather than replacing a slide.
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
# Generic (both target architectures); desktop only. A Server/headless image has
# no Singularity payload, so the hook exits without doing anything.
#
# Idempotent (install -m 0644 overwrites in place). Safe on a live rootfs.

set -uo pipefail

ASSETS="${NCZ_TOUR_SLIDES_ASSETS:-/usr/local/lib/cix-installer/assets/branding/tour-slides}"
TOURDIR="${NCZ_TOUR_SLIDES_DIR:-/opt/singularity/share/singularity/tour}"

if [ ! -d "$TOURDIR" ]; then
    echo "[51] no Singularity tour payload at $TOURDIR — skipping NCZ tour slides"
    exit 0
fi
if [ ! -d "$ASSETS" ]; then
    echo "[51] WARN: NCZ tour slide assets missing at $ASSETS — nothing installed" >&2
    exit 0
fi

installed=0
for s in 55-ncz-wallpapers 56-ncz-online-wallpapers 65-ncz-screensavers 75-ncz-lock; do
    src="$ASSETS/$s.slide"
    if [ ! -f "$src" ]; then
        echo "[51] WARN: $src missing" >&2
        continue
    fi
    install -m 0644 "$src" "$TOURDIR/$s.slide"
    installed=$((installed + 1))
done
echo "[51] installed $installed NCZ tour slide(s) into $TOURDIR"
exit 0
