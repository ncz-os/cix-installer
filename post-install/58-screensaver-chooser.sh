#!/bin/bash
set -euo pipefail

echo "[58] installing NCZ-OS Singularity screensaver plugin"
VARIANT=desktop
[ -f /usr/local/lib/cix-installer/BUILD_VARIANT ] && VARIANT=$(tr -d ' \t\r\n' < /usr/local/lib/cix-installer/BUILD_VARIANT)
case "$VARIANT" in server|headless) exit 0;; esac

SRC=/usr/local/lib/cix-installer/assets/screensaver-chooser
[ -d "$SRC" ] || SRC=/cdrom/ncz-payload/assets/screensaver-chooser
[ -d "$SRC" ] || { echo "[58] ERROR: screensaver chooser assets not staged" >&2; exit 1; }

BUILD=/root/build-tmp/ncz-screensaver-chooser
install -d -m0755 "$BUILD"
PKG_CONFIG_PATH=/opt/singularity/lib/pkgconfig \
VALAFLAGS=--vapidir=/opt/singularity/share/vala/vapi \
meson setup --wipe "$BUILD" "$SRC" --prefix=/opt/singularity
meson compile -C "$BUILD"
install -D -m0755 "$BUILD/libscreensaver-chooser.so" \
    /opt/singularity/lib/singularity/plugins/screensaver-chooser/libscreensaver-chooser.so
install -D -m0644 "$BUILD/screensaver-chooser.plugin" \
    /opt/singularity/lib/singularity/plugins/screensaver-chooser/screensaver-chooser.plugin
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
# The Singularity shell reads /opt/singularity (GSETTINGS_SCHEMA_DIR); keep its
# compiled database fresh on the same path too (O6N 2026-10-04 stale-cache).
if [ -d /opt/singularity/share/glib-2.0/schemas ] && command -v glib-compile-schemas >/dev/null 2>&1; then
    glib-compile-schemas /opt/singularity/share/glib-2.0/schemas 2>&1 | tail -1 || true
fi
systemctl --global enable ncz-idle-manager.service >/dev/null
echo "[58] installed screensaver plugin and ext-idle-notify-v1 manager"
