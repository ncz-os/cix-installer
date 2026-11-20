#!/bin/bash
# test-hostname-suggest.sh -- tests for the ONE NCZ hostname algorithm.
#
#  A. preseed/ncz-hostname-gen.sh: determinism, format ^ncz-[a-z]{1,8}-[0-9]{4}$ (<= 14 chars, a valid
#     DNS label), all 252 star names valid, identity order, stability when a USB NIC / dock is swapped,
#     placeholder identifiers rejected, random fallback varies.
#  B. preseed/hostname-suggest.sh (debconf side, stubbed): unattended never prompts and marks the
#     questions seen; interactive asks at CRITICAL priority with the generated default and applies the
#     ncz_hostname= overrides; the retired --prompt branch is GONE (S2-3): the flag is inert, no dialog
#     is ever shown, nothing reads stdin, and an unattended run (stdin closed) exits rather than waiting;
#     and a defensive re-run keeps the same value after a hypothetical netcfg/get_hostname reset
#     (the 18e8a14 bug).
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
helper() {   # $1 = cmdline text, $2 = (legacy answer; S2-3: ignored, no prompt exists), extra args are flags
    printf '%s\n' "$1" > "$W/cmdline"
    PATH="$W/bin:$PATH" NCZ_DMI_DIR="$W/h/dmi" NCZ_NET_DIR="$W/h/net" NCZ_MACHINE_ID=/nonexistent \
      NCZ_CONFMODULE="$W/confmodule" NCZ_HOSTNAME_GEN="$GEN" NCZ_HOSTNAME_STATE="$W/state" NCZ_CMDLINE="$W/cmdline" \
      NCZ_EARLY_LOG="$W/log" NCZ_TEST_CALLS="$W/calls" NCZ_TEST_ANSWER="$2" sh "$HELPER" "${3:-}" </dev/null >/dev/null 2>&1
}
applied() { sed -n 's/^set netcfg\/get_hostname //p' "$W/calls" | tail -1; }

rm -f "$W/state" "$W/calls"; helper "ncz_components=desktop root=x" ""
check "unattended: netcfg/get_hostname is the generated name" "$(applied)" "$EXPECT"
grep -q '^input' "$W/calls" && bad "unattended install prompted" || ok "unattended: never prompts"
grep -q '^fset netcfg/get_hostname seen true' "$W/calls" && ok "unattended: question marked seen" || bad "unattended: not marked seen"

rm -f "$W/state" "$W/calls"; helper "ncz_unattended=1" ""
grep -q '^input' "$W/calls" && bad "ncz_unattended=1 prompted" || ok "ncz_unattended=1 never prompts"

rm -f "$W/state" "$W/calls"; helper "quiet splash" ""
grep -q '^input' "$W/calls" && bad "interactive: the run prompted (the hostname is automatic)" || ok "interactive: never prompts (the hostname is automatic)"
check "interactive run: the generated name is applied for netcfg" "$(applied)" "$EXPECT"

# S2-3: the retired --prompt branch is GONE. The flag must be inert: a caller that
# (re)adds it must NOT be able to re-enable a prompt, and nothing may read stdin.
rm -f "$W/state" "$W/calls"; helper "quiet splash" "" --prompt
grep -q '^input' "$W/calls" && bad "S2-3: --prompt still prompts (dead code path is live)" || ok "S2-3: --prompt is inert -- no dialog is ever shown"
check "S2-3: --prompt run still applies the generated name" "$(applied)" "$EXPECT"
grep -q "^set ncz/hostname " "$W/calls" && bad "S2-3: --prompt seeded an interactive question" || ok "S2-3: --prompt does not seed any interactive question"
grep -qE '^(set|fset) ncz/hostname( |$)' "$W/calls" && bad "S2-3: ncz/hostname template question still touched" || ok "S2-3: the ncz/hostname template question is never touched"
[ -e "$W/asked" ] && bad "S2-3: an \$ASKED marker is still written" || ok "S2-3: no \$ASKED marker is written"

# An answer on stdin must NOT change the outcome (nothing reads stdin).
rm -f "$W/state" "$W/calls"; printf 'Kitchen-PC\n' | helper "quiet" ""
check "S2-3: an answer on stdin is ignored" "$(applied)" "$EXPECT"

# Unattended runs must not block or prompt, even if a stray --prompt is passed.
rm -f "$W/state" "$W/calls"; helper "ncz_unattended=1" "" --prompt
grep -q '^input' "$W/calls" && bad "S2-3: --prompt on an unattended install prompted" || ok "S2-3: --prompt on an unattended install never prompts"
check "S2-3: unattended + --prompt applies the generated name" "$(applied)" "$EXPECT"

rm -f "$W/state" "$W/calls"; helper "ncz_components=desktop ncz_hostname=lab-07" ""
check "ncz_hostname= overrides the generated name" "$(applied)" "lab-07"
rm -f "$W/state" "$W/calls"; helper "ncz_components=desktop ncz_hostname=lab-07" "" --prompt
check "S2-3: ncz_hostname= still wins with a stray --prompt" "$(applied)" "lab-07"

# The script must not even LOOK at stdin: with stdin closed (unattended) it exits
# rather than waiting, and no --prompt/answer combination can make it block.
rm -f "$W/state" "$W/calls"
printf '%s\n' "quiet splash" > "$W/cmdline"
PATH="$W/bin:$PATH" NCZ_DMI_DIR="$W/h/dmi" NCZ_NET_DIR="$W/h/net" NCZ_MACHINE_ID=/nonexistent \
  NCZ_CONFMODULE="$W/confmodule" NCZ_HOSTNAME_GEN="$GEN" NCZ_HOSTNAME_STATE="$W/state" NCZ_CMDLINE="$W/cmdline" \
  NCZ_EARLY_LOG="$W/log" NCZ_TEST_CALLS="$W/calls" timeout 10 sh "$HELPER" --prompt </dev/null >/dev/null 2>&1
check "S2-3: exits 0 with stdin closed (never waits on input)" "$?" 0
# Source must not read stdin at all (S2-3 hazard: a prompt needs a read). Strip
# comment lines first, so the explanatory prose about the retired branch is not
# mistaken for live code.
sed 's/[[:space:]]*#.*$//' "$HELPER" | grep -nE '\bread\b|db_input|debconf-loadtemplate|--prompt' > "$W/reads" 2>/dev/null || true
[ -s "$W/reads" ] && bad "S2-3: hostname-suggest.sh still references prompting/reading ($(tr '\n' ';' < "$W/reads"))" || ok "S2-3: no read/db_input/template logic remains in the source"

# the 18e8a14 bug: a re-run that begins with netcfg/get_hostname reset; the state-driven re-apply
# must put the SAME name back (S2-3: via generation/state, never a prompt)
rm -f "$W/state" "$W/calls"; helper "quiet" ""
: > "$W/calls"                               # "reload": nothing carried over except /tmp state
helper "quiet" ""
check "after a preseed reload the earlier name is re-applied" "$(applied)" "$EXPECT"
grep -q '^input' "$W/calls" && bad "prompted again after the reload" || ok "no second prompt after the reload"
grep -q '^fset netcfg/get_hostname seen true' "$W/calls" && ok "re-applied value is marked seen" || bad "re-applied value not marked seen"

echo "hostname tests: $PASS passed, $FAILS failed"
[ "$FAILS" = 0 ]
