#!/bin/bash
# 21-flatpak-arch-filter.sh — register Flathub with the NCZ-OS target-architecture filter.
#
# Flatpak remotes normally expose every architecture they publish. An
# unfiltered remote makes an app store advertise software that cannot run on
# the installed NCZ target. A local remote filter is enforced below using the
# system's canonical BUILD_ARCH metadata. If the signed Flathub descriptor
# cannot be reached during an offline install, no remote is added — an
# unfiltered catalogue is never a fallback.
set -uo pipefail

echo "[21] Flatpak target-architecture catalogue policy"

if ! command -v flatpak >/dev/null 2>&1; then
    echo "[21] flatpak unavailable — skipping"
    exit 0
fi

# 20-desktop enables G_MESSAGES_DEBUG=all for crash traceability. GLib writes
# those diagnostics into command output on this image, so keep them out of the
# machine-readable Flatpak architecture check below.
flatpak_cmd() {
    env -u G_MESSAGES_DEBUG flatpak "$@"
}

INSTALLER_META=/usr/local/lib/cix-installer
NCZ_SYSTEM_ARCH="${NCZ_TARGET_ARCH:-}"
if [ -z "$NCZ_SYSTEM_ARCH" ] && [ -r "$INSTALLER_META/BUILD_ARCH" ]; then
    NCZ_SYSTEM_ARCH=$(tr -d '[:space:]' < "$INSTALLER_META/BUILD_ARCH")
fi
NCZ_SYSTEM_ARCH="${NCZ_SYSTEM_ARCH:-$(dpkg --print-architecture 2>/dev/null || true)}"

case "$NCZ_SYSTEM_ARCH" in
    arm64) FLATPAK_ARCH=aarch64 ;;
    amd64) FLATPAK_ARCH=x86_64 ;;
    *)
        echo "[21] unsupported NCZ_TARGET_ARCH=$NCZ_SYSTEM_ARCH; leaving Flathub unconfigured"
        exit 0
        ;;
esac

POLICY_DIR=/usr/local/share/ncz-os/flatpak
FILTER="$POLICY_DIR/flathub-${FLATPAK_ARCH}.filter"
install -d -m 0755 "$POLICY_DIR"
cat > "$FILTER" <<EOF
# NCZ-OS architecture policy. Keep the system AppStream catalogue and every
# selectable application on the target architecture; runtime dependencies match.
deny *
allow app/*/${FLATPAK_ARCH}/*
allow runtime/*/${FLATPAK_ARCH}/*
allow appstream2/*/${FLATPAK_ARCH}
EOF
chmod 0644 "$FILTER"

if flatpak_cmd remote-modify --system --enable --filter="$FILTER" flathub 2>/dev/null; then
    echo "[21] updated existing Flathub remote with ${FLATPAK_ARCH} filter"
else
    # The .flatpakrepo endpoint supplies Flathub's signed GPG key.  Do not use
    # --no-gpg-verify and do not create an unfiltered fallback remote.
    if ! flatpak_cmd remote-add --system --if-not-exists --filter="$FILTER" \
            flathub https://dl.flathub.org/repo/flathub.flatpakrepo; then
        echo "[21] WARN: signed Flathub descriptor unavailable; no remote added"
        exit 0
    fi
fi

# Catalog verification is deliberately fail-closed: if a malformed or
# unsupported Flatpak version ever ignores the filter, disable the remote so
# application UIs cannot present incompatible refs. Updating the remote filter
# invalidates its cached summary, so this refreshes when networking is present;
# an offline install safely defers verification with the filter still applied.
ARCHES="$(flatpak_cmd remote-ls --system --app --arch='*' --columns=arch flathub 2>/dev/null \
    | grep -xE 'aarch64|x86_64|i386|arm' | sort -u || true)"
BAD_ARCHES="$(printf '%s\n' "$ARCHES" | grep -vx "$FLATPAK_ARCH" || true)"
if [ -n "$BAD_ARCHES" ]; then
    echo "[21] ERROR: non-${FLATPAK_ARCH} refs escaped filter: $BAD_ARCHES"
    flatpak_cmd remote-modify --system --disable flathub 2>/dev/null || true
    echo "[21] Flathub disabled rather than exposing incompatible applications"
elif [ -n "$ARCHES" ]; then
    echo "[21] Flathub configured and verified: ${FLATPAK_ARCH} only"
else
    echo "[21] Flathub filter installed; catalog verification deferred until first refresh"
fi
