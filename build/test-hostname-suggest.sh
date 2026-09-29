#!/bin/bash
# test-hostname-suggest.sh -- proves preseed/hostname-suggest.sh derives the
# suggested hostname from the MACHINE, not from a swappable NIC, and rejects
# placeholder identifiers. Runs the real helper under dash (and busybox ash if
# present) against fixture DMI/net trees.
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
HELPER="$HERE/../preseed/hostname-suggest.sh"
W="$(mktemp -d -t hostsuggest.XXXXXX)"
trap 'rm -rf "$W"' EXIT
PASS=0; FAILS=0

cat > "$W/confmodule" <<'EOF'
db_set()  { echo "set $1 $2" >> "$NCZ_TEST_CALLS"; }
db_fset() { echo "fset $1 $2 $3" >> "$NCZ_TEST_CALLS"; }
EOF

mkfix() {   # $1 = fixture name; creates $W/$1/{dmi,net,dev}
    rm -rf "$W/$1"; mkdir -p "$W/$1/dmi" "$W/$1/net" "$W/$1/dev/pci0000/0000:00:1c.0" "$W/$1/dev/usb1/1-1" "$W/$1/dev/virtual"
}
dmi()  { printf '%s\n' "$3" > "$W/$1/dmi/$2"; }
nic()  {   # $1 fixture  $2 name  $3 mac  $4 bus(pci|usb)  $5 kind(eth|wifi)
    mkdir -p "$W/$1/net/$2"; printf '%s\n' "$3" > "$W/$1/net/$2/address"
    if [ "$4" = usb ]; then ln -s "$W/$1/dev/usb1/1-1" "$W/$1/net/$2/device"; else ln -s "$W/$1/dev/pci0000/0000:00:1c.0" "$W/$1/net/$2/device"; fi
    [ "$5" = wifi ] && mkdir -p "$W/$1/net/$2/wireless"
    return 0
}
run() {     # $1 fixture, $2 shell -> prints "<hostname> <source>"
    rm -f "$W/calls"
    NCZ_DMI_DIR="$W/$1/dmi" NCZ_NET_DIR="$W/$1/net" NCZ_CONFMODULE="$W/confmodule" \
        NCZ_TEST_CALLS="$W/calls" NCZ_EARLY_LOG="$W/log" "${2:-sh}" "$HELPER" >/dev/null 2>&1
    local hn src
    hn=$(sed -n 's/^set netcfg\/hostname //p' "$W/calls" 2>/dev/null)
    src=$(tail -1 "$W/log" 2>/dev/null | sed -n 's/.* from \([^ ]*\) (.*/\1/p')
    echo "$hn $src"
}
check() { if [ "$2" = "$3" ]; then echo "PASS  $1"; PASS=$((PASS+1)); else echo "FAIL  $1: got '$2' want '$3'"; FAILS=$((FAILS+1)); fi; }
name() { echo "${1%% *}"; }
srcof(){ echo "${1##* }"; }

SHELLS="sh"; command -v dash >/dev/null && SHELLS="$SHELLS dash"
[ -x "$(command -v busybox)" ] && busybox --list 2>/dev/null | grep -qx sh && SHELLS="$SHELLS ash"
run_with() { case "$2" in ash) rm -f "$W/calls"; NCZ_DMI_DIR="$W/$1/dmi" NCZ_NET_DIR="$W/$1/net" NCZ_CONFMODULE="$W/confmodule" NCZ_TEST_CALLS="$W/calls" NCZ_EARLY_LOG="$W/log" busybox sh "$HELPER" >/dev/null 2>&1; rm -f "$W/calls.x"; hn=$(sed -n 's/^set netcfg\/hostname //p' "$W/calls"); echo "$hn $(tail -1 "$W/log" | sed -n 's/.* from \([^ ]*\) (.*/\1/p')";; *) run "$1" "$2";; esac; }

for SH in $SHELLS; do
    echo "== shell: $SH"
    # 1. product_uuid wins and survives a dock swap
    mkfix a; dmi a product_uuid "3F2504E0-4F89-11D3-9A0C-0305E82C3301"; nic a wlan0 "aa:bb:cc:00:00:01" pci wifi; nic a eth0 "aa:bb:cc:00:00:02" pci eth
    r1=$(run_with a $SH); : > "$W/log"
    nic a enx0 "de:ad:be:ef:00:09" usb eth; rm -rf "$W/a/net/eth0"
    r2=$(run_with a $SH)
    check "uuid: source is product_uuid" "$(srcof "$r1")" "dmi:product_uuid"
    check "uuid: name unchanged after the ethernet adapter is swapped" "$(name "$r2")" "$(name "$r1")"
    [ -n "$(name "$r1")" ] || { echo "FAIL  uuid: no hostname produced"; FAILS=$((FAILS+1)); }
    # 2. different machine, different name
    mkfix b; dmi b product_uuid "9A8B7C6D-1111-2222-3333-444455556666"; r3=$(run_with b $SH)
    [ "$(name "$r3")" != "$(name "$r1")" ] && { echo "PASS  two machines get different names"; PASS=$((PASS+1)); } || { echo "FAIL  two machines collide"; FAILS=$((FAILS+1)); }
    # 3. placeholder uuid falls to serial
    mkfix c; dmi c product_uuid "00000000-0000-0000-0000-000000000000"; dmi c product_serial "C02D51F2MD6R"
    check "zero uuid rejected, serial used" "$(srcof "$(run_with c $SH)")" "dmi:product_serial"
    mkfix c2; dmi c2 product_uuid "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF"; dmi c2 product_serial "C02D51F2MD6R"
    check "all-f uuid rejected, serial used" "$(srcof "$(run_with c2 $SH)")" "dmi:product_serial"
    # 4. Radxa-style constant placeholders are rejected, onboard wifi used, USB dock ignored
    mkfix d; dmi d product_serial "Radxa System Serial Number"; dmi d board_serial "Radxa Board Serial Number"; dmi d chassis_serial "Default string"
    nic d wlan0 "11:22:33:44:55:66" pci wifi; nic d enx1 "de:ad:be:ef:00:01" usb eth
    r4=$(run_with d $SH); check "placeholders rejected, onboard wireless used" "$(srcof "$r4")" "onboard-wireless"
    nic d enx2 "de:ad:be:ef:00:02" usb eth; rm -rf "$W/d/net/enx1"
    check "onboard-wireless name stable across dock swap" "$(name "$(run_with d $SH)")" "$(name "$r4")"
    # 5. only a USB NIC and a PCI NIC: PCI wins
    mkfix e; nic e enx1 "de:ad:be:ef:00:01" usb eth; nic e eth0 "01:02:03:04:05:06" pci eth
    check "no dmi/wifi: PCI NIC used, USB ignored" "$(srcof "$(run_with e $SH)")" "pci-nic"
    # 6. nothing at all: random, and different each time
    mkfix f; nic f enx1 "de:ad:be:ef:00:01" usb eth
    a=$(run_with f $SH); b=$(run_with f $SH)
    check "nothing usable: random source" "$(srcof "$a")" "random"
    [ "$(name "$a")" != "$(name "$b")" ] && { echo "PASS  random names differ between runs"; PASS=$((PASS+1)); } || { echo "FAIL  random names identical"; FAILS=$((FAILS+1)); }
    # 7. overridable: seen=false on interactive, seen=true when unattended is not testable
    #    without /proc/cmdline; assert the interactive branch marks the questions unseen
    mkfix g; dmi g product_uuid "3F2504E0-4F89-11D3-9A0C-0305E82C3301"; run_with g $SH >/dev/null
    grep -q "^fset netcfg/hostname seen false" "$W/calls" && { echo "PASS  interactive install leaves the hostname question unseen (overridable)"; PASS=$((PASS+1)); } || { echo "FAIL  hostname question not left unseen"; FAILS=$((FAILS+1)); }
done
echo "hostname-suggest tests: $PASS passed, $FAILS failed"
[ "$FAILS" = 0 ]
