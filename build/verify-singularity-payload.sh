#!/bin/bash
# build/verify-singularity-payload.sh --arch ARCH --payload-deb F --plugin-deb F
#
# Offline check that a built Singularity payload deb and the settings plugin deb are
# the ones the tree pins:
#   1. the payload deb's sha256 and file name are the row in manifests/singularity-payload.tsv
#      and its sha256 is the singularity_payload_sha256_<arch> value in manifests/determinism.pin;
#   2. the payload version is the one the plugin lock names (NCZ_SSPLUGIN_PAYLOAD_<arch>);
#   3. the pinned upstream commits are well formed and every patch queue applies to them
#      (build/singularity-pins.sh validate + check-patches);
#   4. the plugin deb matches the lock and links the payload's libsingularity
#      (build/check-ssplugin-abi.sh);
#   5. the helper names the plugins look up in PATH are installed by hook 45.
# Exit: 0 all pass, 1 a check failed, 2 bad invocation.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCH=""; PAYLOAD_DEB=""; PLUGIN_DEB=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --arch) ARCH="${2:-}"; shift 2 ;;
        --payload-deb) PAYLOAD_DEB="${2:-}"; shift 2 ;;
        --plugin-deb) PLUGIN_DEB="${2:-}"; shift 2 ;;
        -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
        *) echo "unknown argument $1" >&2; exit 2 ;;
    esac
done
case "$ARCH" in amd64|arm64) ;; *) echo "--arch amd64|arm64 required" >&2; exit 2 ;; esac
[ -s "$PAYLOAD_DEB" ] && [ -s "$PLUGIN_DEB" ] || { echo "--payload-deb and --plugin-deb must name files" >&2; exit 2; }
fail=0
ok() { echo "[verify-payload] OK   $*"; }
bad() { echo "[verify-payload] FAIL $*" >&2; fail=1; }
sha() { sha256sum "$1" | cut -d' ' -f1; }

row="$(awk -F'\t' -v a="$ARCH" '$1==a{print}' "$ROOT/manifests/singularity-payload.tsv" | tail -1)"
want_sha="$(echo "$row" | cut -f2)"; want_name="$(echo "$row" | cut -f3)"
got_sha="$(sha "$PAYLOAD_DEB")"
[ "$got_sha" = "$want_sha" ] && ok "payload deb sha256 $got_sha is the manifest row" || bad "payload deb sha256 $got_sha != manifest $want_sha"
[ "$(basename "$PAYLOAD_DEB")" = "$want_name" ] && ok "payload deb name $want_name" || bad "payload deb name $(basename "$PAYLOAD_DEB") != $want_name"
pin="$(awk -F'\t' -v k="singularity_payload_sha256_$ARCH" '$1==k{print $2}' "$ROOT/manifests/determinism.pin")"
[ "$pin" = "$got_sha" ] && ok "determinism.pin carries the payload sha256" || bad "determinism.pin payload sha256 '$pin' != $got_sha"
pver="$(dpkg-deb -f "$PAYLOAD_DEB" Version)"
case "$want_name" in *"_${pver}_${ARCH}.deb") ok "package Version $pver matches the file name" ;; *) bad "package Version $pver does not match $want_name" ;; esac
lockver="$(sed -n "s/^NCZ_SSPLUGIN_PAYLOAD_${ARCH}=//p" "$ROOT/post-install/lib/ncz-screensavers-plugin.lock")"
[ "$lockver" = "$pver" ] && ok "plugin lock names payload $pver" || bad "plugin lock names payload '$lockver', payload is $pver"
if bash "$ROOT/build/singularity-pins.sh" validate >/dev/null 2>&1; then ok "upstream pins well formed, every queue pinned"; else bad "singularity-pins.sh validate"; fi
if bash "$ROOT/build/singularity-pins.sh" check-patches >/dev/null 2>&1; then ok "every patch queue applies to its pinned commit"; else bad "singularity-pins.sh check-patches"; fi
if bash "$ROOT/build/check-ssplugin-abi.sh" --arch "$ARCH" --plugin-deb "$PLUGIN_DEB" --payload-deb "$PAYLOAD_DEB" >/dev/null 2>&1; then ok "plugin deb matches the lock and links this payload's libsingularity"; else bad "check-ssplugin-abi.sh"; fi
for n in bing ocs; do
    grep -q "ln -sf ncz-wallpaper-$n /usr/local/bin/singularity-wallpaper-$n" "$ROOT/post-install/45-wallpaper-rotator.sh" \
        && ok "hook 45 installs singularity-wallpaper-$n" || bad "hook 45 does not install singularity-wallpaper-$n"
done
# the payload must carry the helper-name lookup of the new plugin head
if dpkg-deb --fsys-tarfile "$PAYLOAD_DEB" | tar -xO --wildcards './opt/singularity/lib/singularity/plugins/wallpapers-bing/*.so' 2>/dev/null | grep -aq 'singularity-wallpaper-bing'; then
    ok "wallpapers-bing plugin looks up singularity-wallpaper-bing"
else
    bad "wallpapers-bing plugin in the payload does not name singularity-wallpaper-bing"
fi
[ "$fail" = 0 ] && echo "[verify-payload] PASS ($ARCH)" || echo "[verify-payload] FAILED ($ARCH)" >&2
exit "$fail"
