#!/bin/bash
# test-hostname-suggest.sh -- tests for the ONE NCZ hostname algorithm.
#
#  A. preseed/ncz-hostname-gen.sh: determinism, format ^ncz-[a-z]{1,8}-[0-9]{4}$ (<= 14 chars, a valid
#     DNS label), all 252 star names valid, identity order, stability when a USB NIC / dock is swapped,
#     placeholder identifiers rejected, random fallback varies.
#  B. preseed/hostname-suggest.sh (debconf side, stubbed): unattended never prompts and marks the
#     questions seen; interactive asks at CRITICAL priority with the generated default and applies the
#     operator's answer (or falls back on an invalid one); ncz_hostname= overrides; and a defensive
#     re-run keeps the same value after a hypothetical netcfg/get_hostname reset (the 18e8a14 bug).
# Runs the real scripts under sh, dash and (when present) busybox sh.
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
GEN="$HERE/../preseed/ncz-hostname-gen.sh"
HELPER="$HERE/../preseed/hostname-suggest.sh"
W="$(mktemp -d -t hostgen.XXXXXX)"
trap 'rm -rf "$W"' EXIT
PASS=0; FAILS=0
ok()   { echo "PASS  $1"; PASS=$((PASS+1)); }
bad()  { echo "FAIL  $1"; FAILS=$((FAILS+1)); }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: got '$2' want '$3'"; fi; }
RX='^ncz-[a-z]{1,8}-[0-9]{4}$'

mkfix() { rm -rf "$W/$1"; mkdir -p "$W/$1/dmi" "$W/$1/net" "$W/$1/dev/pci0000/0000:00:1c.0" "$W/$1/dev/usb1/1-1"; }
dmi()  { printf '%s\n' "$3" > "$W/$1/dmi/$2"; }
nic()  { mkdir -p "$W/$1/net/$2"; printf '%s\n' "$3" > "$W/$1/net/$2/address"
         if [ "$4" = usb ]; then ln -s "$W/$1/dev/usb1/1-1" "$W/$1/net/$2/device"; else ln -s "$W/$1/dev/pci0000/0000:00:1c.0" "$W/$1/net/$2/device"; fi
         [ "$5" = wifi ] && mkdir -p "$W/$1/net/$2/wireless"; return 0; }
gen()  { NCZ_DMI_DIR="$W/$1/dmi" NCZ_NET_DIR="$W/$1/net" NCZ_MACHINE_ID="${3:-/nonexistent}" "${2:-sh}" "$GEN" --source 2>/dev/null; }
name() { echo "${1%% *}"; }
srcof(){ echo "${1##* }"; }

SHELLS="sh"; command -v dash >/dev/null && SHELLS="$SHELLS dash"
BB="$(command -v busybox 2>/dev/null || true)"
case "$(uname -m)" in aarch64) _bbf="$HERE/../assets/diag/busybox-arm64" ;; x86_64) _bbf="$HERE/../assets/diag/busybox-amd64" ;; *) _bbf="" ;; esac
[ -x "$BB" ] || { [ -n "$_bbf" ] && [ -x "$_bbf" ] && BB="$_bbf"; }
# the installer's own shell is busybox ash: test with it whenever one is available
if [ -x "$BB" ] && "$BB" sh -c 'exit 0' 2>/dev/null; then SHELLS="$SHELLS bbsh"; fi
shrun() { case "$1" in bbsh) shift; "$BB" sh "$@" ;; *) local s=$1; shift; "$s" "$@" ;; esac; }
gen()  { local f=$1 s=${2:-sh}; NCZ_DMI_DIR="$W/$f/dmi" NCZ_NET_DIR="$W/$f/net" NCZ_MACHINE_ID="${3:-/nonexistent}" shrun "$s" "$GEN" --source 2>/dev/null; }

echo "== A. generator"
python3 - "$GEN" <<'PY' && ok "252 unique star names, each 1-8 lowercase letters" || bad "star name list"
import re,sys
s=open(sys.argv[1]).read()
n=re.search(r'_ncz_names="([^"]*)"',s).group(1).split()
assert len(n)==252 and len(set(n))==252 and all(re.fullmatch(r"[a-z]{1,8}",x) for x in n), (len(n))
PY
for SH in $SHELLS; do
    echo "-- shell: $SH"
    mkfix a; dmi a product_uuid "3F2504E0-4F89-11D3-9A0C-0305E82C3301"; nic a wlan0 "aa:bb:cc:00:00:01" pci wifi; nic a eth0 "aa:bb:cc:00:00:02" pci eth
    r1=$(gen a $SH)
    echo "$(name "$r1")" | grep >/dev/null -E "$RX" && ok "format matches $RX ($(name "$r1"))" || bad "format: $(name "$r1")"
    _n1=$(name "$r1"); [ "${#_n1}" -le 17 ] && ok "at most 17 characters (ncz- + 8 + - + 4), far inside the 63-char DNS label limit" || bad "too long: $_n1"
    check "source is product_uuid" "$(srcof "$r1")" "dmi:product_uuid"
    check "deterministic" "$(name "$(gen a $SH)")" "$(name "$r1")"
    nic a enx0 "de:ad:be:ef:00:09" usb eth; rm -rf "$W/a/net/eth0"
    check "stable when the ethernet adapter is swapped for a USB dock" "$(name "$(gen a $SH)")" "$(name "$r1")"
    mkfix b; dmi b product_uuid "9A8B7C6D-1111-2222-3333-444455556666"
    [ "$(name "$(gen b $SH)")" != "$(name "$r1")" ] && ok "a different machine gets a different name" || bad "two machines collide"
    mkfix c; dmi c product_uuid "00000000-0000-0000-0000-000000000000"; dmi c product_serial "C02D51F2MD6R"
    check "all-zero uuid rejected, serial used" "$(srcof "$(gen c $SH)")" "dmi:product_serial"
    mkfix c2; dmi c2 product_uuid "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF"; dmi c2 product_serial "C02D51F2MD6R"
    check "all-f uuid rejected, serial used" "$(srcof "$(gen c2 $SH)")" "dmi:product_serial"
    mkfix d; dmi d product_serial "Radxa System Serial Number"; dmi d board_serial "Radxa Board Serial Number"; dmi d chassis_serial "Default string"
    printf '0a9a2a28a5b04d0c9e7b1c2d3e4f5a6b\n' > "$W/d/machine-id"
    check "placeholders rejected, machine-id used" "$(srcof "$(gen d $SH "$W/d/machine-id")")" "machine-id"
    nic d wlan0 "11:22:33:44:55:66" pci wifi; nic d enx1 "de:ad:be:ef:00:01" usb eth
    r4=$(gen d $SH); check "without machine-id: onboard wireless" "$(srcof "$r4")" "onboard-wireless"
    nic d enx2 "de:ad:be:ef:00:02" usb eth; rm -rf "$W/d/net/enx1"
    check "onboard-wireless name stable across a dock swap" "$(name "$(gen d $SH)")" "$(name "$r4")"
    mkfix e; nic e enx1 "de:ad:be:ef:00:01" usb eth; nic e eth0 "01:02:03:04:05:06" pci eth
    check "PCI NIC used, USB ignored" "$(srcof "$(gen e $SH)")" "pci-nic"
    mkfix f; nic f enx1 "de:ad:be:ef:00:01" usb eth
    a=$(gen f $SH); b=$(gen f $SH)
    check "nothing usable: random" "$(srcof "$a")" "random"
    [ "$(name "$a")" != "$(name "$b")" ] && ok "random names differ between runs" || bad "random names identical"
    echo "$(name "$a")" | grep >/dev/null -E "$RX" && ok "random name still matches the format" || bad "random format: $(name "$a")"
done

echo "== B. installer helper (stubbed debconf)"
cat > "$W/confmodule" <<'EOF'
db_set()      { echo "set $1 $2" >> "$NCZ_TEST_CALLS"; [ "$1" = ncz/hostname ] && _DEFAULT="$2"; return 0; }
db_fset()     { echo "fset $1 $2 $3" >> "$NCZ_TEST_CALLS"; }
db_settitle() { return 0; }
db_input()    { echo "input $1 $2" >> "$NCZ_TEST_CALLS"; return 0; }
db_go()       { return 0; }
db_get()      { RET="${NCZ_TEST_ANSWER:-$_DEFAULT}"; return 0; }
EOF
mkdir -p "$W/bin"; printf '#!/bin/sh\nexit 0\n' > "$W/bin/debconf-loadtemplate"; chmod +x "$W/bin/debconf-loadtemplate"
mkfix h; dmi h product_uuid "3F2504E0-4F89-11D3-9A0C-0305E82C3301"
EXPECT=$(gen h sh); EXPECT=$(name "$EXPECT")
helper() {   # $1 = cmdline text, $2 = answer ("" = accept default), $3 = mode ("" or --prompt)
    printf '%s\n' "$1" > "$W/cmdline"
    PATH="$W/bin:$PATH" NCZ_DMI_DIR="$W/h/dmi" NCZ_NET_DIR="$W/h/net" NCZ_MACHINE_ID=/nonexistent \
      NCZ_CONFMODULE="$W/confmodule" NCZ_HOSTNAME_GEN="$GEN" NCZ_HOSTNAME_STATE="$W/state" NCZ_CMDLINE="$W/cmdline" \
      NCZ_HOSTNAME_ASKED="$W/asked" NCZ_EARLY_LOG="$W/log" NCZ_TEST_CALLS="$W/calls" NCZ_TEST_ANSWER="$2" sh "$HELPER" ${3:-} >/dev/null 2>&1
}
applied() { sed -n 's/^set netcfg\/get_hostname //p' "$W/calls" | tail -1; }

rm -f "$W/state" "$W/calls"; helper "ncz_components=desktop root=x" ""
check "unattended: netcfg/get_hostname is the generated name" "$(applied)" "$EXPECT"
grep -q '^input' "$W/calls" && bad "unattended install prompted" || ok "unattended: never prompts"
grep -q '^fset netcfg/get_hostname seen true' "$W/calls" && ok "unattended: question marked seen" || bad "unattended: not marked seen"

rm -f "$W/state" "$W/calls"; helper "ncz_unattended=1" ""
grep -q '^input' "$W/calls" && bad "ncz_unattended=1 prompted" || ok "ncz_unattended=1 never prompts"

rm -f "$W/state" "$W/calls" "$W/asked"; helper "quiet splash" ""
grep -q '^input' "$W/calls" && bad "interactive: the FIRST (early_command) run prompted; the dialog is deferred to partman/early_command" || ok "interactive: the early run never prompts (the dialog is deferred to right before partitioning)"
check "interactive, early run: the generated name is applied for netcfg" "$(applied)" "$EXPECT"
: > "$W/calls"; helper "quiet splash" "" --prompt
grep -q '^input critical ncz/hostname' "$W/calls" && ok "interactive --prompt: asks at CRITICAL priority (d-i's own question is suppressed at priority=critical)" || bad "interactive --prompt: no critical prompt"
grep -q "^set ncz/hostname $EXPECT" "$W/calls" && ok "interactive --prompt: the generated name is the seeded default" || bad "interactive --prompt: default not seeded"
check "interactive --prompt, Enter accepted: generated name applied" "$(applied)" "$EXPECT"
: > "$W/calls"; helper "quiet splash" "" --prompt
grep -q '^input' "$W/calls" && bad "--prompt asked twice" || ok "--prompt asks only once"

rm -f "$W/state" "$W/calls" "$W/asked"; helper "quiet" ""; helper "quiet" "Kitchen-PC" --prompt
check "interactive, operator types a name: it wins (lower-cased)" "$(applied)" "kitchen-pc"
[ "$(cat "$W/state")" = kitchen-pc ] && ok "the chosen name is saved for the installed system" || bad "state file not updated"
rm -f "$W/state" "$W/calls" "$W/asked"; helper "quiet" ""; helper "quiet" "bad name!" --prompt
check "interactive, invalid answer: falls back to the generated name" "$(applied)" "$EXPECT"
rm -f "$W/state" "$W/calls" "$W/asked"; helper "ncz_unattended=1" ""; : > "$W/calls"; helper "ncz_unattended=1" "" --prompt
grep -q '^input' "$W/calls" && bad "--prompt on an unattended install prompted" || ok "--prompt on an unattended install never prompts"

rm -f "$W/state" "$W/calls"; helper "ncz_components=desktop ncz_hostname=lab-07" ""
check "ncz_hostname= overrides the generated name" "$(applied)" "lab-07"

# the 18e8a14 bug: a re-run that begins with netcfg/get_hostname reset; the state-driven re-apply
# must put the SAME name back, without prompting again
rm -f "$W/state" "$W/calls" "$W/asked"; helper "quiet" ""; helper "quiet" "Kitchen-PC" --prompt
: > "$W/calls"                               # "reload": nothing carried over except /tmp state
helper "quiet" "somethingelse"
check "after a preseed reload the earlier choice is re-applied" "$(applied)" "kitchen-pc"
grep -q '^input' "$W/calls" && bad "prompted again after the reload" || ok "no second prompt after the reload"
grep -q '^fset netcfg/get_hostname seen true' "$W/calls" && ok "re-applied value is marked seen" || bad "re-applied value not marked seen"

echo "hostname tests: $PASS passed, $FAILS failed"
[ "$FAILS" = 0 ]
