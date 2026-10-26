#!/bin/bash
# test-desktop-app-set.sh -- the desktop app set after the stock GNOME apps
# with a native Singularity twin were dropped (operator, 2026-10-26).
#
#   1. the dropped packages are seeded nowhere (desktop manifests, SBOM seed
#      lists, component registry); the libraries/helpers we keep still are;
#   2. nothing in the hooks, assets or build scripts names a dropped app's
#      desktop id or binary (no dangling dock pin, default, script or gate);
#   3. the dock pins only Singularity apps and the browsers, with Leafs as the
#      terminal;
#   4. post-install/lib/ncz-default-apps.sh points images/PDF/text/folders/
#      fonts/calendars at the Singularity apps, only when the app exists,
#      keeps every other key, and is idempotent;
#   5. the PipeWire Bluetooth/libcamera plugins and libmtp-runtime are seeded;
#   6. rasdaemon is not seeded on client images.
# Run: bash build/test-desktop-app-set.sh   Exit 0 = pass, 1 = fail.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()  { echo "  PASS  $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL  $1"; FAIL=$((FAIL+1)); [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'; }

DROPPED="gnome-calculator gnome-calendar gnome-characters gnome-disk-utility gnome-weather
gnome-text-editor gnome-sound-recorder gnome-console gnome-font-viewer baobab epiphany-browser
epiphany-browser-data loupe papers papers-common"
seeds() { sed 's/#.*//' "$1" | awk 'NF {print $1}'; }

echo "== 1. manifests"
for m in desktop desktop-amd64; do
    f="$ROOT/manifests/$m.pkgs"
    hit=""; for p in $DROPPED; do seeds "$f" | grep -qx -- "$p" && hit="$hit $p"; done
    [ -z "$hit" ] && ok "$m.pkgs seeds none of the dropped GNOME apps" || bad "$m.pkgs still seeds:$hit"
    miss=""; for p in zenity gnome-session-canberra libadwaita-1-0 geoclue-2.0 gnome-desktop3-data xdg-desktop-portal-gtk foot; do
        seeds "$f" | grep -qx -- "$p" || miss="$miss $p"
    done
    [ -z "$miss" ] && ok "$m.pkgs keeps the shared libraries/helpers" || bad "$m.pkgs lost:$miss"
done
seeds "$ROOT/manifests/desktop-amd64.pkgs" | grep -qx gnome-online-accounts \
    && ok "desktop-amd64.pkgs keeps gnome-online-accounts" || bad "desktop-amd64.pkgs lost gnome-online-accounts"
for f in sbom/expected-packages.txt sbom/expected-packages-amd64.txt; do
    hit=""; for p in $DROPPED; do grep -qE ":$p\$" "$ROOT/$f" && hit="$hit $p"; done
    [ -z "$hit" ] && ok "$f requires none of the dropped apps" || bad "$f still requires:$hit"
done
hit=""; for p in $DROPPED; do awk -F'\t' -v p="$p" '$1 == p' "$ROOT/manifests/components.tsv" | grep -q . && hit="$hit $p"; done
[ -z "$hit" ] && ok "components.tsv lists none of the dropped apps" || bad "components.tsv still lists:$hit"

echo "== 2. no dangling references"
IDS='org\.gnome\.(Calculator|Calendar|Characters|DiskUtility|Weather|TextEditor|SoundRecorder|Console|font-viewer|baobab|Epiphany|Loupe|Papers)(\.desktop|-previewer)?|gnome-disk-image-(mounter|writer)|\bkgx\b|\b(gnome-calculator|gnome-text-editor|gnome-disks|gnome-font-viewer|gnome-sound-recorder|gnome-characters|gnome-calendar|gnome-weather|epiphany|loupe|papers) +(-|%|"|$)'
refs=$(cd "$ROOT" && git ls-files -- post-install assets build tools preseed 2>/dev/null \
    | grep -v '^build/test-desktop-app-set\.sh$' \
    | while IFS= read -r f; do [ -f "$f" ] && grep -IHnE "$IDS" "$f" 2>/dev/null; done | grep -vE ':[0-9]+:[[:space:]]*#')
[ -z "$refs" ] && ok "no hook/asset/build script names a dropped app's desktop id or binary" || bad "dangling references" "$refs"
grep -q 'inode/directory=thunar' "$ROOT/post-install/52-vivaldi.sh" \
    && bad "52-vivaldi still seeds the absent thunar.desktop as the folder handler" \
    || ok "52-vivaldi does not seed the absent thunar.desktop"

echo "== 3. dock pins"
pins=$(sed -n "s/^pinned-apps=\[\(.*\)\]$/\1/p" "$ROOT/post-install/20-desktop.sh" | tr -d "' " | tr ',' '\n')
[ -n "$pins" ] || bad "pinned-apps not found in 20-desktop.sh"
odd=$(printf '%s\n' "$pins" | grep -vE '^dev\.sinty\.[A-Za-z0-9_.-]+\.desktop$|^(chromium-ncz-sky1|google-chrome)\.desktop$' || true)
[ -z "$odd" ] && ok "dock pins only Singularity apps and the browsers" || bad "unexpected dock pins" "$odd"
printf '%s\n' "$pins" | grep -qx 'dev.sinty.leafs.desktop' && ok "dock terminal is Singularity Leafs" || bad "Leafs is not pinned"

echo "== 4. default handlers"
LIB="$ROOT/post-install/lib/ncz-default-apps.sh"
grep -q 'ncz-default-apps.sh' "$ROOT/post-install/59-desktop-curate.sh" && grep -q 'ncz_default_apps_apply' "$ROOT/post-install/59-desktop-curate.sh" \
    && ok "59-desktop-curate applies lib/ncz-default-apps.sh" || bad "59-desktop-curate does not apply the default-apps helper"
R="$T/root"; A="$R/opt/singularity/share/applications"
mkdir -p "$A" "$R/etc/xdg" "$R/etc/skel/.config"
for id in photos reader edit files fonts; do printf '[Desktop Entry]\nName=%s\n' "$id" > "$A/dev.sinty.$id.desktop"; done   # no calendar
cat > "$R/etc/xdg/mimeapps.list" <<'EOF'
[Default Applications]
text/html=vivaldi-stable.desktop
x-scheme-handler/https=vivaldi-stable.desktop
inode/directory=thunar.desktop
video/mp4=mpv.desktop

[Added Associations]
image/png=gimp.desktop;
EOF
cp "$R/etc/xdg/mimeapps.list" "$R/etc/skel/.config/mimeapps.list"
# shellcheck source=post-install/lib/ncz-default-apps.sh
apply() { ( . "$LIB"; ncz_default_apps_apply "$R" ) > "$T/apply.log" 2>&1; }
apply || bad "helper exited non-zero" "$(cat "$T/apply.log")"
dflt() { awk -v k="$2" '/^\[/{g=($0=="[Default Applications]")} g && index($0,k"=")==1 {sub(/^[^=]*=/,""); print}' "$1"; }
for m in "$R/etc/xdg/mimeapps.list" "$R/etc/skel/.config/mimeapps.list"; do
    n=${m#"$R"}
    for kv in image/png=dev.sinty.photos.desktop image/jpeg=dev.sinty.photos.desktop application/pdf=dev.sinty.reader.desktop \
              text/plain=dev.sinty.edit.desktop inode/directory=dev.sinty.files.desktop font/ttf=dev.sinty.fonts.desktop \
              text/html=vivaldi-stable.desktop x-scheme-handler/https=vivaldi-stable.desktop video/mp4=mpv.desktop; do
        got=$(dflt "$m" "${kv%%=*}")
        [ "$got" = "${kv#*=}" ] && ok "$n: ${kv%%=*} -> $got" || bad "$n: ${kv%%=*} -> '$got' (want ${kv#*=})"
    done
    [ -z "$(dflt "$m" text/calendar)" ] && ok "$n: no default names the absent Calendar app" || bad "$n: text/calendar set although Calendar is absent"
    grep -qx 'image/png=gimp.desktop;' "$m" && ok "$n: [Added Associations] left as written" || bad "$n: [Added Associations] changed" "$(cat "$m")"
    [ "$(grep -c '^\[Default Applications\]$' "$m")" = 1 ] && [ "$(grep -c '^\[Added Associations\]$' "$m")" = 1 ] \
        && [ "$(awk '/^\[Added Associations\]$/{g=1; next} /^\[/{g=0} g && NF' "$m")" = 'image/png=gimp.desktop;' ] \
        && ok "$n: both groups kept once; nothing was moved into [Added Associations]" || bad "$n: group structure changed" "$(cat "$m")"
    dup=$(awk -F= '/^\[/{g=$0} !/^\[/ && NF {print g"|"$1}' "$m" | sort | uniq -d)
    [ -z "$dup" ] && ok "$n: every key appears once per group" || bad "$n: duplicate keys" "$dup"
done
cp "$R/etc/xdg/mimeapps.list" "$T/first"
apply
cmp -s "$T/first" "$R/etc/xdg/mimeapps.list" && ok "second run changes nothing (idempotent)" || bad "second run changed the file" "$(diff "$T/first" "$R/etc/xdg/mimeapps.list")"
R2="$T/fresh"; mkdir -p "$R2/opt/singularity/share/applications"
printf '[Desktop Entry]\n' > "$R2/opt/singularity/share/applications/dev.sinty.reader.desktop"
# shellcheck source=post-install/lib/ncz-default-apps.sh
( . "$LIB"; ncz_default_apps_apply "$R2" ) >/dev/null 2>&1
[ "$(dflt "$R2/etc/xdg/mimeapps.list" application/pdf)" = dev.sinty.reader.desktop ] && head -1 "$R2/etc/xdg/mimeapps.list" | grep -qx '\[Default Applications\]' \
    && ok "no mimeapps.list yet: one is created with the group header" || bad "fresh root" "$(cat "$R2/etc/xdg/mimeapps.list" 2>&1)"

if [ "$(id -u)" != 0 ]; then
    R3="$T/ro"; mkdir -p "$R3/opt/singularity/share/applications" "$R3/etc/xdg" "$R3/etc/skel/.config"
    printf '[Desktop Entry]\n' > "$R3/opt/singularity/share/applications/dev.sinty.reader.desktop"
    printf '[Default Applications]\n' > "$R3/etc/xdg/mimeapps.list"; chmod 0555 "$R3/etc/xdg"
    # shellcheck source=post-install/lib/ncz-default-apps.sh
    ( . "$LIB"; ncz_default_apps_apply "$R3" ) >/dev/null 2>&1 && bad "an unwritable mimeapps.list is not reported" || ok "an unwritable mimeapps.list makes the helper return non-zero"
    [ "$(cat "$R3/etc/xdg/mimeapps.list")" = '[Default Applications]' ] && ok "the unwritable file is left intact" || bad "unwritable file changed"
    chmod 0755 "$R3/etc/xdg"
fi

echo "== 5. PipeWire plugins and mtp-probe"
# wireplumber logged "SPA handle 'api.bluez5.enum.dbus' could not be loaded" at
# every login and udev "Failed to find and pin callout binary
# /usr/lib/udev/mtp-probe" for every USB device (Chimera/Medusa, 2026-10-26).
for m in desktop desktop-amd64; do
    miss=""; for p in libspa-0.2-bluetooth libspa-0.2-libcamera libcamera-ipa libmtp-runtime; do
        seeds "$ROOT/manifests/$m.pkgs" | grep -qx -- "$p" || miss="$miss $p"
    done
    [ -z "$miss" ] && ok "$m.pkgs seeds the Bluetooth/libcamera SPA plugins and libmtp-runtime" || bad "$m.pkgs is missing:$miss"
done

echo "== 6. rasdaemon is not on client images"
# 9x "Can't get traces from cxl:*" + 9x "Can't write to set_event" every boot,
# nothing depends on it (2026-10-26).
hit=""; for f in "$ROOT"/manifests/*.pkgs; do seeds "$f" | grep -qx rasdaemon && hit="$hit ${f##*/}"; done
[ -z "$hit" ] && ok "no manifest seeds rasdaemon" || bad "rasdaemon still seeded by:$hit"

echo
echo "test-desktop-app-set: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
