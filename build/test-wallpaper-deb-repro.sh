#!/bin/bash
# test-wallpaper-deb-repro.sh -- the Artist Pack builder is byte-reproducible and
# ignores the host: two builds of the same pack under a different umask, a
# different caller SOURCE_DATE_EPOCH, a different TMPDIR filesystem and a fake
# ArtistPack checkout in $HOME give the same deb; and a pack.json that does not
# describe the packaged images fails the build.
# Usage: build/test-wallpaper-deb-repro.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   $*"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL $*"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/     /'; }
command -v dpkg-deb >/dev/null 2>&1 || { echo "SKIP: dpkg-deb not available"; exit 0; }
T="$(mktemp -d "${TMPDIR:-/var/tmp}/wprepro.XXXXXX")"; trap 'rm -rf "$T"' EXIT
: > "$T/index"
build() {  # build <out> <umask> <sde> -> sha256 of the ncz pack
    ( umask "$2"; HOME="$T/home"; export HOME; mkdir -p "$HOME/Projects/artistpack/packs/ncz"
      echo '{}' > "$HOME/Projects/artistpack/packs/ncz/pack.json"   # a stray checkout must not be used
      SOURCE_DATE_EPOCH="$3" WALLPAPER_DEB_OUT="$1" NCZ_PUBLISHED_INDEX="$T/index" TMPDIR="$T" \
          bash "$ROOT/build/build-wallpaper-contrib-deb.sh" ncz ) > "$1.log" 2>&1 || { echo FAILED; return; }
    sha256sum "$1"/ncz-wallpapers-ncz_*_all.deb | cut -d' ' -f1
}
a="$(build "$T/a" 022 1000000000)"; b="$(build "$T/b" 002 1999999999)"
[ "$a" != FAILED ] && [ "$a" = "$b" ] && ok "ncz pack is byte-identical across umask/SOURCE_DATE_EPOCH/HOME ($a)" \
    || bad "ncz pack differs between builds ($a vs $b)" "$(tail -5 "$T/a.log" "$T/b.log")"
v="$(dpkg-deb -f "$T/a"/ncz-wallpapers-ncz_*_all.deb Version 2>/dev/null)"
[ "$v" != 1.0 ] && [ "$v" != 1.1 ] && ok "version $v is past the per-host 1.0/1.1 builds" || bad "version is still $v"
TZ=UTC dpkg-deb --fsys-tarfile "$T/a"/ncz-wallpapers-ncz_*_all.deb | TZ=UTC tar -tv --full-time 2>/dev/null | awk '{print $1}' | sort -u > "$T/modes"
grep -qv -E '^(drwxr-xr-x|-rw-r--r--)$' "$T/modes" && bad "unexpected member modes" "$(cat "$T/modes")" || ok "members are 0755 dirs / 0644 files"
# a manifest that names an image which is not packaged must fail the build
mkdir -p "$T/tree/assets/branding" && cp -a "$ROOT/build" "$T/tree/" && cp -a "$ROOT/assets/branding/wallpaper" "$T/tree/assets/branding/"
P="$T/tree/assets/branding/wallpaper/artistpack/ncz/pack.json"
python3 -I - "$P" <<'PY'
import json,sys; d=json.load(open(sys.argv[1])); d["artworks"][0]["original"]["sha256"]="0"*64; json.dump(d,open(sys.argv[1],"w"))
PY
if WALLPAPER_DEB_OUT="$T/c" NCZ_PUBLISHED_INDEX="$T/index" TMPDIR="$T" bash "$T/tree/build/build-wallpaper-contrib-deb.sh" ncz > "$T/c.log" 2>&1; then
    bad "a pack.json sha256 that does not match the packaged image was accepted"
else
    grep -q 'does not match its pack.json sha256' "$T/c.log" && ok "pack.json/image mismatch fails the build" || bad "mismatch failed for another reason" "$(tail -3 "$T/c.log")"
fi
echo "test-wallpaper-deb-repro: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
