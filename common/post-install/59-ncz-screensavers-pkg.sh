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

if dpkg -s ncz-screensavers 2>/dev/null | grep -q '^Status: install ok installed'; then
    echo "[59-ncz-screensavers] already installed ($(dpkg-query -W -f='${Version}' ncz-screensavers))"
    exit 0
fi

# Candidate must exist in the configured (offline) sources; otherwise this
# image simply does not ship the package yet.
cand="$(apt-cache policy ncz-screensavers 2>/dev/null | sed -n 's/^  Candidate: //p')"
if [ -z "$cand" ] || [ "$cand" = "(none)" ]; then
    echo "[59-ncz-screensavers] no candidate in the package sources; nothing to install"
    exit 0
fi

# Simulate first: never let this install remove anything already on the system.
sim="$(DEBIAN_FRONTEND=noninteractive apt-get install -s -y --no-install-recommends ncz-screensavers 2>&1)" || {
    echo "[59-ncz-screensavers] simulation failed; not installing:" >&2
    printf '%s\n' "$sim" | tail -15 >&2
    exit 1
}
if printf '%s\n' "$sim" | grep -q '^Remv '; then
    echo "[59-ncz-screensavers] simulation would REMOVE packages; refusing:" >&2
    printf '%s\n' "$sim" | grep '^Remv ' >&2
    exit 1
fi

echo "[59-ncz-screensavers] installing ncz-screensavers $cand"
out="$(DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ncz-screensavers 2>&1)"
rc=$?
printf '%s\n' "$out" | tail -8
if [ "$rc" -ne 0 ]; then
    echo "[59-ncz-screensavers] apt install failed rc=$rc" >&2
    exit 1
fi
if ! dpkg -s ncz-screensavers 2>/dev/null | grep -q '^Status: install ok installed'; then
    echo "[59-ncz-screensavers] package is not in the installed state after apt" >&2
    exit 1
fi
echo "[59-ncz-screensavers] installed ncz-screensavers $(dpkg-query -W -f='${Version}' ncz-screensavers)"
