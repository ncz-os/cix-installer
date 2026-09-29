#!/bin/bash
# tests for preseed/ncz-ui.sh under bash, sh, dash and the installer's own busybox ash (when it runs on this host)
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
UI="$HERE/../preseed/ncz-ui.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0; FAILS=0
eq() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "ok   $1"; else FAILS=$((FAILS+1)); echo "FAIL $1: got '$2' want '$3'"; fi; }
mkdir -p "$T/p"
printf 'NCZ_PRODUCT_NAME="NCZ-OS"\nNCZ_RELEASE_VERSION="26.7"\nNCZ_RELEASE_CODENAME="Maximilian"\n' > "$T/p/RELEASE"
echo 2026.09.29-7e1d9c2 > "$T/p/BUILD_VERSION"; echo arm64 > "$T/p/BUILD_ARCH"
SHELLS=("bash" "sh")
command -v dash >/dev/null && SHELLS+=("dash")
BB="$HERE/../assets/diag/busybox-arm64"
[ "$(uname -m)" = aarch64 ] && [ -x "$BB" ] && "$BB" ash -c true 2>/dev/null && SHELLS+=("$BB ash")
for shl in "${SHELLS[@]}"; do
    run() { NCZ_UI_PAYLOAD="$1" $shl -c ". '$UI'; $2"; }
    eq "$shl: brand"        "$(run "$T/p" ncz_ui_brand)" "NCZ-OS 26.7 Maximilian"
    eq "$shl: id arm64"     "$(run "$T/p" ncz_ui_id)"    "arm64 (Sky1) | build 7e1d9c2"
    echo amd64 > "$T/p/BUILD_ARCH"
    eq "$shl: id amd64"     "$(run "$T/p" ncz_ui_id)"    "amd64 | build 7e1d9c2"
    echo arm64 > "$T/p/BUILD_ARCH"
    eq "$shl: no payload -> plain name" "$(run "$T/none" ncz_ui_brand)" "NCZ-OS"
    out="$(run "$T/p" ncz_ui_brand)$(run "$T/p" ncz_ui_id)"
    eq "$shl: ASCII only" "$(printf '%s' "$out" | LC_ALL=C tr -d '\001-\177' | wc -c | tr -d ' ')" "0"
done
echo "ncz-ui tests: $PASS passed, $FAILS failed"; [ "$FAILS" = 0 ]
