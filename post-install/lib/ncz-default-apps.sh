# shellcheck shell=sh
# ncz-default-apps.sh -- default handlers for documents, images, text, folders,
# fonts and calendars point at the native Singularity apps.
#
# The stock GNOME viewers/editors are not installed (manifests/desktop.pkgs,
# 2026-10-26), and the image never set defaults for these types: GLib picked
# whatever claimed the type first. Measured on a real amd64 install with the
# GNOME apps still present: image/png -> Drawing, application/pdf -> GIMP,
# inode/directory -> Disk Usage (baobab), because the seeded thunar.desktop
# does not exist. Sourced by post-install/59-desktop-curate.sh after the
# browser hooks (52-vivaldi, 53-chrome) have written their keys.
#
#   ncz_default_apps_apply [ROOT]
#
# Sets each key in ROOT/etc/xdg/mimeapps.list and ROOT/etc/skel/.config/
# mimeapps.list [Default Applications] only when the Singularity .desktop file
# exists under ROOT/opt/singularity/share/applications, so a default never
# names a missing app. Every other key (browser, video) is kept as written.
# Idempotent.

NCZ_DEFAULT_APPS_MAP="
dev.sinty.photos.desktop image/jpeg image/png image/gif image/webp image/svg+xml image/tiff image/bmp image/heic image/heif image/avif image/x-portable-pixmap image/x-portable-bitmap image/vnd.microsoft.icon
dev.sinty.reader.desktop application/pdf application/x-pdf
dev.sinty.edit.desktop text/plain text/markdown text/x-markdown text/css text/javascript text/xml application/json application/xml application/x-shellscript text/x-python text/x-csrc text/x-chdr text/x-c++src text/x-c++hdr text/x-java text/x-makefile text/x-vala text/x-yaml application/toml
dev.sinty.files.desktop inode/directory
dev.sinty.fonts.desktop font/ttf font/otf font/collection font/woff font/woff2 application/x-font-ttf application/x-font-otf
dev.sinty.calendar.desktop text/calendar
"

# _ncz_da_set FILE KEY VALUE -- set KEY=VALUE in the [Default Applications]
# group of FILE, creating the file or the group if missing.
_ncz_da_set() {
    _f=$1; _k=$2; _v=$3
    [ -f "$_f" ] || printf '[Default Applications]\n' > "$_f"
    grep -q '^\[Default Applications\]' "$_f" || printf '\n[Default Applications]\n' >> "$_f"
    awk -v k="$_k" -v v="$_v" '
        /^\[/ { if (ing && !done) { print k "=" v; done = 1 } ing = ($0 == "[Default Applications]") }
        ing && index($0, k "=") == 1 { if (!done) { print k "=" v; done = 1 } next }
        { print }
        END { if (ing && !done) print k "=" v }
    ' "$_f" > "$_f.ncz-da" && cat "$_f.ncz-da" > "$_f" && rm -f "$_f.ncz-da"
}

ncz_default_apps_apply() {
    _r=${1:-}
    _apps="$_r/opt/singularity/share/applications"
    mkdir -p "$_r/etc/xdg" "$_r/etc/skel/.config"
    printf '%s\n' "$NCZ_DEFAULT_APPS_MAP" | while read -r _id _types; do
        [ -n "$_id" ] || continue
        if [ ! -f "$_apps/$_id" ]; then
            echo "[default-apps] $_id not installed: its types keep their current handler"
            continue
        fi
        for _t in $_types; do
            for _m in "$_r/etc/xdg/mimeapps.list" "$_r/etc/skel/.config/mimeapps.list"; do
                _ncz_da_set "$_m" "$_t" "$_id"
            done
        done
        echo "[default-apps] $_id: $(printf '%s\n' $_types | wc -l | tr -d ' ') types"
    done
}
