#!/bin/bash
# Install the NCZ-owned GTK4 package update manager and session notifier.
set -euo pipefail

echo "[50] installing NCZ-OS update manager + notifier"
VARIANT=desktop
[ -f /usr/local/lib/cix-installer/BUILD_VARIANT ] && \
    VARIANT=$(tr -d ' \t\r\n' < /usr/local/lib/cix-installer/BUILD_VARIANT)
case "$VARIANT" in
    server|headless)
        echo "[50] BUILD_VARIANT=$VARIANT — skipping desktop update UI"
        exit 0
        ;;
esac

SRC=/usr/local/lib/cix-installer/assets/update-manager
[ -d "$SRC" ] || SRC=/cdrom/ncz-payload/assets/update-manager
if [ ! -d "$SRC" ]; then
    echo "[50] ERROR: update-manager assets not staged" >&2
    exit 1
fi

install -D -m0755 "$SRC/ncz-update-check" /usr/bin/ncz-update-check
install -D -m0755 "$SRC/ncz-update-manager" /usr/bin/ncz-update-manager
install -D -m0755 "$SRC/ncz-update-notifier" /usr/bin/ncz-update-notifier
install -D -m0755 "$SRC/ncz-update-apply" /usr/libexec/ncz-update-apply
install -D -m0644 "$SRC/dev.ncz.update-manager.policy" \
    /usr/share/polkit-1/actions/dev.ncz.update-manager.policy
install -D -m0644 "$SRC/dev.ncz.UpdateManager.desktop" \
    /usr/share/applications/dev.ncz.UpdateManager.desktop
install -D -m0644 "$SRC/ncz-update-notifier.desktop" \
    /etc/xdg/autostart/ncz-update-notifier.desktop

echo "[50] installed GTK4 updater, apt/polkit backend, and Singularity-session notifier"
