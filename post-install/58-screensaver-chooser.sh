#!/bin/bash
set -euo pipefail

echo "[58] installing NCZ-OS Vala/GTK4 screensaver chooser"
VARIANT=desktop
[ -f /usr/local/lib/cix-installer/BUILD_VARIANT ] && VARIANT=$(tr -d ' \t\r\n' < /usr/local/lib/cix-installer/BUILD_VARIANT)
case "$VARIANT" in server|headless) exit 0;; esac

SRC=/usr/local/lib/cix-installer/assets/screensaver-chooser
[ -d "$SRC" ] || SRC=/cdrom/ncz-payload/assets/screensaver-chooser
[ -d "$SRC" ] || { echo "[58] ERROR: screensaver chooser assets not staged" >&2; exit 1; }

BUILD=/root/build-tmp/ncz-screensaver-chooser
install -d -m0755 "$BUILD"
meson setup --wipe "$BUILD" "$SRC"
meson compile -C "$BUILD"
install -D -m0755 "$BUILD/ncz-screensaver-chooser" /usr/bin/ncz-screensaver-chooser
install -D -m0755 "$SRC/ncz-screensaver-run" /usr/libexec/ncz-screensaver-run
install -D -m0755 "$SRC/ncz-idle-manager" /usr/libexec/ncz-idle-manager
install -D -m0644 "$SRC/hacks.tsv" /usr/share/ncz-screensaver-chooser/hacks.tsv
for preview in "$SRC"/previews/*.b64; do
    [ -f "$preview" ] || continue
    target=/usr/share/ncz-screensaver-chooser/previews/$(basename "${preview%.b64}")
    install -d -m0755 "$(dirname "$target")"
    base64 -d "$preview" > "$target"
    chmod 0644 "$target"
done
install -D -m0644 "$SRC/dev.ncz.screensaver.gschema.xml" /usr/share/glib-2.0/schemas/dev.ncz.screensaver.gschema.xml
install -D -m0644 "$SRC/dev.ncz.ScreensaverChooser.desktop" /usr/share/applications/dev.ncz.ScreensaverChooser.desktop
install -D -m0644 "$SRC/ncz-idle-manager.service" /usr/lib/systemd/user/ncz-idle-manager.service

cat > /usr/local/bin/ncz-lock <<'EOF'
#!/bin/sh
if pgrep -f '/opt/singularity/bin/singularity-lockscreen' >/dev/null 2>&1 || pgrep -x swaylock >/dev/null 2>&1; then
    exit 0
fi
/usr/libexec/ncz-screensaver-run --stop
if [ -x /opt/singularity/bin/singularity-lockscreen ]; then
    exec /opt/singularity/bin/singularity-lockscreen
fi
exec swaylock -f -c 000000
EOF
chmod 0755 /usr/local/bin/ncz-lock

glib-compile-schemas /usr/share/glib-2.0/schemas
systemctl --global enable ncz-idle-manager.service >/dev/null
echo "[58] installed 140-hack chooser and ext-idle-notify-v1 manager"
