#!/bin/bash
# test-cix-deb-server-skip.sh -- 25-cix-proprietary.sh's deb filter: a server
# root (BUILD_VARIANT=server) skips libgtk4-layer-shell0, whose libgtk-4-1
# dependency `apt-get install -fy` would otherwise pull from the offline pool
# (Preview4 arm64 Magnetar gate, 2026-10-26); a desktop root installs it.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
HOOK="${NCZ_HOOK_UNDER_TEST:-$ROOT/post-install/25-cix-proprietary.sh}"
T="$(mktemp -d "${TMPDIR:-/tmp}/cix-deb-skip.XXXXXX")" || exit 2
trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { echo "  PASS  $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1"; fail=$((fail + 1)); }
sed -n '/^# BEGIN cix-variant$/,/^# END cix-variant$/p' "$HOOK" \
    | sed "s#/usr/local/lib/cix-installer/BUILD_VARIANT#$T/BUILD_VARIANT#g" > "$T/variant.sh"
sed -n '/^# BEGIN cix-deb-filter$/,/^# END cix-deb-filter$/p' "$HOOK" > "$T/filter.sh"
if [ ! -s "$T/variant.sh" ] || [ ! -s "$T/filter.sh" ]; then
    bad "cix-variant / cix-deb-filter markers missing in the hook"; echo "--- $pass passed, $fail failed"; exit 1
fi
mkdir -p "$T/debs"
for d in libgtk4-layer-shell0_1.3.0-1+ncz20261013_arm64.deb cix-vaapi_1.0_arm64.deb \
         cix-gstreamer_1.22.1_arm64.deb ncz-singularity-desktop_1_arm64.deb; do : > "$T/debs/$d"; done
# run <BUILD_VARIANT|-> -> the debs the filter keeps, space-separated
run() {
    rm -f "$T/BUILD_VARIANT"; [ "$1" = - ] || printf '%s\n' "$1" > "$T/BUILD_VARIANT"
    ( cd "$T/debs" && . "$T/variant.sh" && . "$T/filter.sh" >/dev/null && printf '%s ' "${DEBS[@]}" )
}
case "$(run server)" in *libgtk4-layer-shell0*) bad "server: libgtk4-layer-shell0 kept ($(run server))" ;;
    *cix-vaapi*) ok "server: libgtk4-layer-shell0 skipped, the rest of the userland kept" ;; *) bad "server: $(run server)" ;; esac
case "$(run desktop)" in *libgtk4-layer-shell0*cix-vaapi*|*cix-vaapi*libgtk4-layer-shell0*) ok "desktop: libgtk4-layer-shell0 installed" ;; *) bad "desktop: $(run desktop)" ;; esac
case "$(run -)" in *libgtk4-layer-shell0*) ok "no BUILD_VARIANT recorded (desktop default): libgtk4-layer-shell0 installed" ;; *) bad "no variant: $(run -)" ;; esac
case "$(run server)" in *cix-gstreamer*|*ncz-singularity-desktop*) bad "server: an always-skipped deb was kept" ;; *) ok "the always-skipped debs stay skipped" ;; esac
echo "--- $pass passed, $fail failed"
[ "$fail" = 0 ]
