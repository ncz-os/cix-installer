#!/bin/bash
# test-timezone-region.sh -- the installer's region timezone must reach the
# installed system, and /etc/timezone must agree with /etc/localtime (r201).
#
# MS-R1 (arm64) chose US / America/New_York in the region dialog and installed
# with /etc/timezone=UTC: preseed/region-chooser.sh wrote /tmp/ncz-region in
# d-i and nothing copied it to the target, so 37-ntp-hostname.sh forced UTC.
# On amd64 /etc/localtime pointed at America/New_York next to an EMPTY
# /etc/timezone. This test runs the real blocks (extracted by marker) from
# preseed/late.sh (NCZ-REGION-PERSIST) and post-install/37-ntp-hostname.sh
# (NCZ-TIMEZONE) against a fixture root.
#
# Run: bash build/test-timezone-region.sh     Exit 0 = pass, 1 = a case failed.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${NCZ_TEST_ROOT:-$(cd "$HERE/.." && pwd)}"
HOOK="$ROOT/post-install/37-ntp-hostname.sh"
LATE="$ROOT/preseed/late.sh"
CHOOSER="$ROOT/preseed/region-chooser.sh"
W="$(mktemp -d -t tz-region.XXXXXX)"; trap 'rm -rf "$W"' EXIT
PASS=0; FAIL=0
ok()  { echo "  PASS  $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'; }
extract() { awk -v b="$2" -v e="$3" 'index($0, b) {f=1; next} index($0, e) {f=0} f' "$1"; }

extract "$HOOK" 'NCZ-TIMEZONE-BEGIN' 'NCZ-TIMEZONE-END' > "$W/tz.sh"
extract "$LATE" 'NCZ-REGION-PERSIST-BEGIN' 'NCZ-REGION-PERSIST-END' > "$W/late.sh"
[ -s "$W/tz.sh" ] || { echo "FATAL: NCZ-TIMEZONE block not found in $HOOK" >&2; exit 2; }
[ -s "$W/late.sh" ] || { echo "FATAL: NCZ-REGION-PERSIST block not found in $LATE" >&2; exit 2; }

# mkroot NAME LOCALTIME [TIMEZONE-CONTENT] -> fixture root; zone files exist only under the root
mkroot() {
    local r="$W/$1"
    rm -rf "$r"; mkdir -p "$r/etc/cix-installer" "$r/usr/share/zoneinfo/America" "$r/usr/share/zoneinfo/Asia" \
        "$r/usr/share/zoneinfo/Europe" "$r/usr/share/zoneinfo/Etc"
    for z in America/New_York Asia/Shanghai Asia/Tokyo Europe/Paris Etc/UTC UTC; do : > "$r/usr/share/zoneinfo/$z"; done
    # absolute link, as on a real system; resolved relative to the fixture by the reader below
    [ -n "$2" ] && ln -s "/usr/share/zoneinfo/$2" "$r/etc/localtime"
    [ $# -ge 3 ] && printf '%s' "$3" > "$r/etc/timezone"
    echo "$r"
}
run_tz() { ( NCZ_TZ_SYSROOT="$1"; shift; for kv in "$@"; do export "${kv?}"; done; set -u; . "$W/tz.sh" ) > "$W/tz.log" 2>&1; }
zone_of() { readlink "$1/etc/localtime" | sed 's|^.*/zoneinfo/||'; }
region() { printf 'en_US.UTF-8\nUS\n%s\nus\n' "$2" > "$1/etc/cix-installer/ncz-region"; }

echo "=== region-chooser writes the timezone on line 3 ==="
body=$(awk '/^cat > "\$NCZ_TMP\/ncz-region" <<REGION$/ {f=1; next} f && /^REGION$/ {exit} f' "$CHOOSER")
[ "$(printf '%s\n' "$body" | sed -n 3p)" = '${CHOSEN_TZ}' ] && ok "ncz-region line 3 is \${CHOSEN_TZ}" || bad "ncz-region layout changed" "$body"

echo "=== late.sh copies /tmp/ncz-region onto the target ==="
mkdir -p "$W/late/target/etc/cix-installer"
printf 'en_US.UTF-8\nUS\nAmerica/New_York\nus\n' > "$W/late/ncz-region"
sed "s#/target#$W/late/target#g" "$W/late.sh" > "$W/late-sb.sh"
( NCZ_REGION_FILE="$W/late/ncz-region"; . "$W/late-sb.sh" ) > "$W/late.log" 2>&1
cmp -s "$W/late/ncz-region" "$W/late/target/etc/cix-installer/ncz-region" && ok "target has etc/cix-installer/ncz-region" || bad "region file not copied" "$(cat "$W/late.log")"
rm -f "$W/late/target/etc/cix-installer/ncz-region"
( NCZ_REGION_FILE="$W/late/absent"; . "$W/late-sb.sh" ) > "$W/late.log" 2>&1 && [ ! -e "$W/late/target/etc/cix-installer/ncz-region" ] \
    && ok "no region file: nothing copied, no failure" || bad "absent region file mishandled" "$(cat "$W/late.log")"

echo "=== arm64 (MS-R1): vendor UTC rootfs + region America/New_York ==="
r=$(mkroot arm64 UTC "UTC"); region "$r" America/New_York
run_tz "$r"
[ "$(zone_of "$r")" = America/New_York ] && ok "/etc/localtime -> America/New_York" || bad "localtime is $(zone_of "$r")" "$(cat "$W/tz.log")"
[ "$(cat "$r/etc/timezone")" = America/New_York ] && ok "/etc/timezone = America/New_York" || bad "/etc/timezone is '$(cat "$r/etc/timezone")'"
[ -e "$r/etc/cix-installer/ncz-region.applied" ] && ok "applied marker written" || bad "no applied marker"

echo "=== re-run after the operator changed the zone: their choice stays ==="
ln -sfn /usr/share/zoneinfo/Europe/Paris "$r/etc/localtime"
run_tz "$r"
[ "$(zone_of "$r")" = Europe/Paris ] && [ "$(cat "$r/etc/timezone")" = Europe/Paris ] && ok "Europe/Paris preserved, /etc/timezone follows" \
    || bad "re-run reverted the operator zone: $(zone_of "$r") / $(cat "$r/etc/timezone")" "$(cat "$W/tz.log")"

echo "=== amd64: localtime already America/New_York, EMPTY /etc/timezone ==="
r=$(mkroot amd64 America/New_York ""); region "$r" America/New_York
run_tz "$r"
[ "$(cat "$r/etc/timezone")" = America/New_York ] && [ "$(zone_of "$r")" = America/New_York ] && ok "/etc/timezone filled in, localtime unchanged" \
    || bad "amd64: '$(cat "$r/etc/timezone")' / $(zone_of "$r")" "$(cat "$W/tz.log")"

echo "=== baked rootfs zone differs from the choice: the choice wins at install ==="
r=$(mkroot baked America/New_York "America/New_York"); region "$r" Asia/Tokyo
run_tz "$r"
[ "$(zone_of "$r")" = Asia/Tokyo ] && [ "$(cat "$r/etc/timezone")" = Asia/Tokyo ] && ok "Asia/Tokyo applied" || bad "got $(zone_of "$r")" "$(cat "$W/tz.log")"

echo "=== no region file (old media / no chooser): legacy rules ==="
r=$(mkroot shanghai Asia/Shanghai)
run_tz "$r"
[ "$(zone_of "$r")" = UTC ] && [ "$(cat "$r/etc/timezone")" = UTC ] && ok "Asia/Shanghai vendor default -> UTC" || bad "got $(zone_of "$r")"
r=$(mkroot nolink "")
run_tz "$r"
[ "$(zone_of "$r")" = UTC ] && ok "unset localtime -> UTC" || bad "got '$(zone_of "$r")'"

echo "=== bogus region zone is ignored, never linked ==="
r=$(mkroot bogus UTC); region "$r" "../../etc/passwd"
run_tz "$r"
[ "$(zone_of "$r")" = UTC ] && ok "path-traversal zone rejected" || bad "linked $(zone_of "$r")"
r=$(mkroot mars UTC); region "$r" "Mars/Olympus_Mons"
run_tz "$r"
[ "$(zone_of "$r")" = UTC ] && grep -q "not in" "$W/tz.log" && ok "unknown zone warned and ignored" || bad "unknown zone handling" "$(cat "$W/tz.log")"

echo "=== NCZ_TIMEZONE overrides the region file ==="
r=$(mkroot env UTC); region "$r" America/New_York
run_tz "$r" NCZ_TIMEZONE=Europe/Paris
[ "$(zone_of "$r")" = Europe/Paris ] && ok "NCZ_TIMEZONE=Europe/Paris wins" || bad "got $(zone_of "$r")"

echo "timezone/region tests: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
