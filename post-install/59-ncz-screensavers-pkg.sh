#!/bin/bash
# 59-ncz-screensavers-pkg.sh -- install the ncz-screensavers package (launcher,
# idle timer, ship-set hacks) from the offline mirror when it is present.
#
# This hook ONLY installs the package. It does not touch the existing chooser
# stack (58-screensaver-chooser.sh) or the held legacy 57-screensaver.sh: the
# package supersedes them on its own schedule, and the two must not be edited
# from two branches at once. It is a strict no-op on images whose mirror does
# not carry the package, so it is safe to ship before the package exists.
#
# Arch-neutral: the same hook serves arm64 and amd64 images.
set -uo pipefail

echo "[59-ncz-screensavers] checking for the ncz-screensavers package"

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

ss_installed() { dpkg -s "$1" 2>/dev/null | grep -q '^Status: install ok installed'; }
WANT=""
for _p in ncz-screensavers ncz-screensavers-plugin; do
    if ss_installed "$_p"; then
        echo "[59-ncz-screensavers] $_p already installed ($(dpkg-query -W -f='${Version}' "$_p"))"
        continue
    fi
    cand="$(apt-cache policy "$_p" 2>/dev/null | sed -n 's/^  Candidate: //p')"
    if [ -z "$cand" ] || [ "$cand" = "(none)" ]; then
        echo "[59-ncz-screensavers] no candidate for $_p in the package sources; nothing to install for it"
        continue
    fi
    WANT="$WANT $_p"
done
[ -n "$WANT" ] || { echo "[59-ncz-screensavers] nothing to install"; exit 0; }
# ncz-screensavers-gtk4-reference is the GTK4 app for OTHER distros; it must never be pulled into NCZ-OS
case " $WANT " in *" ncz-screensavers-gtk4-reference "*) echo "[59-ncz-screensavers] refusing ncz-screensavers-gtk4-reference" >&2; exit 1 ;; esac

sim="$(DEBIAN_FRONTEND=noninteractive apt-get install -s -y --no-install-recommends $WANT 2>&1)" || {
    echo "[59-ncz-screensavers] simulation failed; not installing:" >&2
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

echo "[59-ncz-screensavers] installing:$WANT"
out="$(DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $WANT 2>&1)"
rc=$?
printf '%s\n' "$out" | tail -8
if [ "$rc" -ne 0 ]; then
    echo "[59-ncz-screensavers] apt install failed rc=$rc" >&2
    exit 1
fi
for _p in $WANT; do
    ss_installed "$_p" || { echo "[59-ncz-screensavers] $_p is not in the installed state after apt" >&2; exit 1; }
    echo "[59-ncz-screensavers] installed $_p $(dpkg-query -W -f='${Version}' "$_p")"
done
