#!/bin/bash
# test-greeter-display-detect.sh -- greetd orders on cix-detect-display.service
# on arm64 only (r201).
#
# 22-display-fix.sh leaves cix-detect-display.service disabled on amd64, but the
# greetd drop-in from 55-greeter.sh carried After=/Wants=cix-detect-display, so
# the unit ran on every amd64 boot anyway (7.4 s in the MacBookPro16,1's boot blame). The
# arch-neutral drop-in (10-ncz-drm.conf) now names only ncz-usb2-rescan, and the
# display-detect ordering lives in 11-ncz-display-detect.conf, written on arm64
# and removed on every other arch. This test runs the real arch block from
# 55-greeter.sh against a fixture /etc for both architectures.
#
# Run: bash build/test-greeter-display-detect.sh     Exit 0 = pass, 1 = fail.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${NCZ_TEST_ROOT:-$(cd "$HERE/.." && pwd)}"
G="$ROOT/post-install/55-greeter.sh"
W="$(mktemp -d -t greeter-display.XXXXXX)"; trap 'rm -rf "$W"' EXIT
PASS=0; FAIL=0
ok()  { echo "  PASS  $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'; }

drm=$(awk '/^cat > \/etc\/systemd\/system\/greetd\.service\.d\/10-ncz-drm\.conf <<.GREETDDRM.$/ {f=1; next} f && $0 == "GREETDDRM" {exit} f' "$G")
[ -n "$drm" ] || { echo "FATAL: 10-ncz-drm.conf heredoc not found in $G" >&2; exit 2; }
printf '%s\n' "$drm" | grep >/dev/null 'cix-detect-display' && bad "arch-neutral 10-ncz-drm.conf still names cix-detect-display" "$drm" \
    || ok "10-ncz-drm.conf (both arches) does not name cix-detect-display"
printf '%s\n' "$drm" | grep >/dev/null -E '^Wants=.*ncz-usb2-rescan\.service' && ok "10-ncz-drm.conf keeps Wants=ncz-usb2-rescan.service" \
    || bad "ncz-usb2-rescan ordering lost" "$drm"

awk '/^_ncz_greeter_arch="\$\{NCZ_TARGET_ARCH:-\}"$/ {f=1} f {print} f && /^unset _ncz_greeter_arch$/ {exit}' "$G" > "$W/block.sh"
[ -s "$W/block.sh" ] || { echo "FATAL: arch block not found in $G" >&2; exit 2; }
sed "s#/etc/systemd/system#$W/etc/systemd/system#g; s#/usr/local/lib/cix-installer#$W/meta#g" "$W/block.sh" > "$W/block-sb.sh"

run() {   # run ARCH -> state in $W/etc
    rm -rf "$W/etc"; mkdir -p "$W/etc/systemd/system/greetd.service.d"
    printf '[Unit]\nAfter=cix-detect-display.service\n' > "$W/etc/systemd/system/greetd.service.d/11-ncz-display-detect.conf"   # stale copy
    ( NCZ_TARGET_ARCH="$1"; . "$W/block-sb.sh" ) > "$W/log" 2>&1
}
F="$W/etc/systemd/system/greetd.service.d/11-ncz-display-detect.conf"

for a in amd64 x86_64; do
    run "$a"
    [ ! -e "$F" ] && ok "$a: no display-detect drop-in (stale one removed)" || bad "$a: 11-ncz-display-detect.conf present" "$(cat "$F")"
    out=$(grep -rhE '^(Wants|Requires|After)=.*cix-detect-display' "$W/etc/systemd/system/greetd.service.d" 2>/dev/null || true)
    [ -z "$out" ] && ok "$a: nothing in greetd.service.d pulls cix-detect-display" || bad "$a: greetd still pulls it" "$out"
done
for a in arm64 aarch64; do
    run "$a"
    grep -qx 'Wants=cix-detect-display.service' "$F" 2>/dev/null && grep -qx 'After=cix-detect-display.service' "$F" \
        && ok "$a: greetd After=/Wants=cix-detect-display.service" || bad "$a: display-detect ordering missing" "$(cat "$W/log")"
done

echo "greeter display-detect tests: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
