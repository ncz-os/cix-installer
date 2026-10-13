#!/bin/bash
# test-installer-flow.sh -- behaviour tests for the interactive installer flow (operator photos 2026-10-06,
# PEGASUS / ASUS ROG, r199 amd64 build de5f9f06). Runs the REAL chooser scripts against a file-backed stand-in for
# cdebconf (values, seen flags, question existence, every db_input recorded) so a question that is asked twice, a
# template that renders a literal "\n", or a seed that would let d-i's own user-setup ask again all fail here.
#
#  A. region-chooser.sh: the template lists every region (country names, codes in Choices-C), Default us, no
#     literal backslash-n; one pick sets locale + country + timezone + keymap (exact keymap, not "us ca");
#     ncz_region=<code> works for codes other than us; a second --prompt run asks nothing.
#  B. user-chooser.sh: without --prompt it seeds d-i's passwd/* questions (seen, locked placeholder password) even
#     before user-setup-udeb's templates exist, so user-setup-ask asks nothing; a kernel-cmdline passwd/username
#     is kept; --prompt asks username + password + confirm ONCE, replaces the placeholder; a re-run asks nothing.
#  C. component-selector.sh: a second --prompt run asks nothing and keeps the operator's answer.
#  D. net-pick.sh: with a cable-less PCI NIC and a USB NIC that has carrier, the USB NIC is pinned and the link
#     wait drops to 10 s; a defensive second evaluation re-applies the pin; with no carrier, or no NIC at all
#     (O6N: only lo), netcfg is left on auto with the preseeded wait.
#  E. preseed.cfg wiring: the defensive re-apply branch uses helpers that source confmodule; the
#     partman/early_command order is region, user, components, disk with the hostname automatic.
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
PRE="${NCZ_PRESEED_DIR:-$ROOT/preseed}"
# The installer runs these scripts under busybox ash; the suite runs once with sh and again with busybox sh.
SHX="${NCZ_TEST_SH:-sh}"
echo "-- shell: $SHX"
W="$(mktemp -d "${TMPDIR:-/tmp}/installer-flow.XXXXXX")"
trap 'rm -rf "$W"' EXIT
PASS=0; FAILS=0
ok()    { echo "ok   $1"; PASS=$((PASS+1)); }
bad()   { echo "FAIL $1"; FAILS=$((FAILS+1)); }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: got '$2' want '$3'"; fi; }

# ---------------------------------------------------------------- fake cdebconf ------------------------------------
# $FDB/q/<key> exists = the question exists; $FDB/v/<key> value; $FDB/s/<key> "true" when seen;
# $FDB/inputs lists every db_input that would be SHOWN (critical priority and not seen), one per line.
# $FDB/ans/<key> is what the operator types when that question is shown (absent = accept the default).
cat > "$W/confmodule" <<'EOF'
_k() { printf '%s' "$1" | tr '/' '%'; }
db_exists() { [ -e "$FDB/q/$(_k "$1")" ]; }
db_set() { db_exists "$1" || return 10; printf '%s' "$2" > "$FDB/v/$(_k "$1")"; return 0; }
db_get() { RET=""; db_exists "$1" || return 10; RET=$(cat "$FDB/v/$(_k "$1")" 2>/dev/null); return 0; }
db_fset() { db_exists "$1" || return 10; [ "$2" = seen ] && printf '%s' "$3" > "$FDB/s/$(_k "$1")"; return 0; }
db_fget() { RET=false; db_exists "$1" || return 10; [ "$2" = seen ] && RET=$(cat "$FDB/s/$(_k "$1")" 2>/dev/null || echo false); return 0; }
db_settitle() { return 0; }
db_subst() { return 0; }
db_capb() { return 0; }
db_progress() { return 0; }
db_input() {
    db_exists "$2" || return 10
    [ "$1" = critical ] || return 30
    [ "$(cat "$FDB/s/$(_k "$2")" 2>/dev/null)" = true ] && return 30
    echo "$2" >> "$FDB/inputs"; echo "$2" >> "$FDB/pending"; return 0
}
db_go() {
    [ -s "$FDB/pending" ] || return 0
    while read -r _q; do
        [ -e "$FDB/ans/$(_k "$_q")" ] && cp "$FDB/ans/$(_k "$_q")" "$FDB/v/$(_k "$_q")"
        printf true > "$FDB/s/$(_k "$_q")"
    done < "$FDB/pending"
    : > "$FDB/pending"; return 0
}
EOF
mkdir -p "$W/bin"
# debconf-loadtemplate OWNER FILE: creates each Template: question (Default -> value when new); keeps a copy.
cat > "$W/bin/debconf-loadtemplate" <<'EOF'
#!/bin/sh
cp "$2" "$FDB/tpl/$(basename "$2")"
awk '/^Template:/{t=$2} /^Default:/{sub(/^Default:[ ]*/,""); d[t]=$0} /^Template:/{n[++c]=$2} END{for(i=1;i<=c;i++) print n[i] "\t" d[n[i]]}' "$2" |
while IFS="$(printf '\t')" read -r q d; do
    k=$(printf '%s' "$q" | tr '/' '%')
    [ -e "$FDB/q/$k" ] || { : > "$FDB/q/$k"; printf '%s' "$d" > "$FDB/v/$k"; }
done
EOF
# debconf-set-selections FILE: "owner question type value" -> creates the question, sets value, marks seen.
cat > "$W/bin/debconf-set-selections" <<'EOF'
#!/bin/sh
while read -r _o q _t v; do
    [ -n "$q" ] || continue
    k=$(printf '%s' "$q" | tr '/' '%'); : > "$FDB/q/$k"; printf '%s' "$v" > "$FDB/v/$k"; printf true > "$FDB/s/$k"
done < "$1"
EOF
chmod +x "$W/bin/"*
newdb() { FDB="$W/db.$1"; rm -rf "$FDB"; mkdir -p "$FDB/q" "$FDB/v" "$FDB/s" "$FDB/ans" "$FDB/tpl"; : > "$FDB/inputs"; : > "$FDB/pending"
          STMP="$W/tmp.$1"; rm -rf "$STMP"; mkdir -p "$STMP"; printf '%s\n' "${2:-quiet}" > "$W/cmdline.$1"; export FDB; }
mkq()  { : > "$FDB/q/$(printf '%s' "$1" | tr '/' '%')"; [ $# -ge 2 ] && printf '%s' "$2" > "$FDB/v/$(printf '%s' "$1" | tr '/' '%')"; return 0; }
val()  { cat "$FDB/v/$(printf '%s' "$1" | tr '/' '%')" 2>/dev/null; }
seen() { cat "$FDB/s/$(printf '%s' "$1" | tr '/' '%')" 2>/dev/null || echo false; }
ans()  { printf '%s' "$2" > "$FDB/ans/$(printf '%s' "$1" | tr '/' '%')"; }
asked(){ grep -cx "$1" "$FDB/inputs" 2>/dev/null || true; }
run()  {   # tag script args...
    local tag=$1 s=$2; shift 2
    PATH="$W/bin:$PATH" NCZ_CONFMODULE="$W/confmodule" NCZ_CMDLINE="$W/cmdline.$tag" NCZ_TMP="$W/tmp.$tag" \
        NCZ_COMP_STATE="$W/tmp.$tag/state" NCZ_TARGET="$W/tmp.$tag/target" \
        NCZ_UI_PAYLOAD=/nonexistent $SHX "$PRE/$s" "$@" >> "$W/log.$tag" 2>&1
}
tpl()  { cat "$FDB/tpl/$1" 2>/dev/null; }
mkdi() { local q; for q in debian-installer/locale debian-installer/language debian-installer/country keyboard-configuration/xkb-keymap \
             keyboard-configuration/layoutcode keyboard-configuration/variant clock-setup/utc time/zone; do mkq "$q"; done; }

# ---------------------------------------------------------------- A. region ----------------------------------------
echo "== A. region-chooser.sh"
newdb ra; mkdi
run ra region-chooser.sh --prompt
T=$(tpl ncz-region.templates)
[ -n "$T" ] && ok "region template was loaded" || bad "region template was never loaded"
printf '%s\n' "$T" | grep -q '\\n' && bad "region template contains a literal backslash-n: $(printf '%s\n' "$T" | grep '\\n')" || ok "region template has no literal backslash-n"
printf '%s\n' "$T" | grep -q ' us - US' && bad "region template still lists 'us - US' in the description" || ok "no 'code - CODE' list in the description"
nc=$(printf '%s\n' "$T" | sed -n 's/^Choices-C: //p' | tr ',' '\n' | grep -c .)
nl=$(printf '%s\n' "$T" | sed -n 's/^Choices: //p' | tr ',' '\n' | grep -c .)
[ "${nc:-0}" -ge 19 ] && ok "Choices-C offers every region ($nc codes)" || bad "Choices-C offers only ${nc:-0} region(s) (r199 offered 1: 'us')"
check "Choices labels match Choices-C one to one" "${nl:-0}" "${nc:-0}"
printf '%s\n' "$T" | sed -n 's/^Choices: //p' | grep -q 'United States' && ok "the list shows country names (United States)" || bad "the list does not show country names"
check "Default is us (Enter accepts United States)" "$(printf '%s\n' "$T" | sed -n 's/^Default: //p')" "us"
check "region asked once" "$(asked ncz/region)" 1
check "default pick: locale/country/tz/keymap" "$(tr '\n' ' ' < "$STMP/ncz-region")" "en_US.UTF-8 US America/New_York us "
check "default pick: xkb-keymap is exactly 'us' (r199 pushed 'us ca')" "$(val keyboard-configuration/xkb-keymap)" "us"
check "default pick: debian-installer/locale seen" "$(seen debian-installer/locale)" true
check "default pick: time/zone" "$(val time/zone)" "America/New_York"
run ra region-chooser.sh --prompt
check "a second --prompt run (partman restarted) does not ask again" "$(asked ncz/region)" 1
check "the re-run keeps the answer" "$(val debian-installer/locale)" "en_US.UTF-8"

newdb rb; mkdi; mkq ncz/region; ans ncz/region de
run rb region-chooser.sh --prompt
check "pick de: locale" "$(val debian-installer/locale)" "de_DE.UTF-8"
check "pick de: country" "$(val debian-installer/country)" "DE"
check "pick de: timezone" "$(val time/zone)" "Europe/Berlin"
check "pick de: keymap" "$(val keyboard-configuration/xkb-keymap)" "de"
check "pick de: language" "$(val debian-installer/language)" "de"

newdb rc "quiet ncz_region=jp"; mkdi
run rc region-chooser.sh --prompt
check "ncz_region=jp is accepted without a dialog" "$(asked ncz/region)" 0
check "ncz_region=jp sets ja_JP.UTF-8 (r199 rejected every code but us)" "$(val debian-installer/locale)" "ja_JP.UTF-8"
check "ncz_region=jp sets Asia/Tokyo" "$(val time/zone)" "Asia/Tokyo"

# ---------------------------------------------------------------- B. user ------------------------------------------
echo "== B. user-chooser.sh"
# d-i's own user-setup-ask (user-setup-udeb 1.109) asks passwd/user-fullname, passwd/username, passwd/user-password
# and -again at CRITICAL priority unless they are seen, and skips both password questions when
# passwd/user-password-crypted is non-empty. These assertions are exactly that contract.
native_would_ask() {
    local n=""
    [ "$(seen passwd/user-fullname)" = true ] || n="$n user-fullname"
    [ "$(seen passwd/username)" = true ] || n="$n username"
    if [ -z "$(val passwd/user-password-crypted)" ]; then
        [ "$(seen passwd/user-password)" = true ] || n="$n user-password"
        [ "$(seen passwd/user-password-again)" = true ] || n="$n user-password-again"
    fi
    echo "${n# }"
}
newdb ua   # first early_command: user-setup-udeb is not loaded yet, no passwd/* question exists
run ua user-chooser.sh
check "seed before user-setup-udeb is loaded: d-i's user-setup would ask nothing" "$(native_would_ask)" ""
check "seed: default username ncz" "$(val passwd/username)" "ncz"
check "seed: locked placeholder password" "$(val passwd/user-password-crypted)" "!"
check "seed asks nothing itself" "$(wc -l < "$FDB/inputs" | tr -d ' ')" 0
# the NCZ dialogs in partman/early_command (user-setup-udeb templates are loaded by then)
mkq passwd/user-password; mkq passwd/user-password-again
mkq ncz/username; ans ncz/username pegasus; mkq ncz/password; ans ncz/password 's3cret pw'; mkq ncz/password-confirm; ans ncz/password-confirm 's3cret pw'
run ua user-chooser.sh --prompt
check "username asked once" "$(asked ncz/username)" 1
check "password asked once" "$(asked ncz/password)" 1
check "password confirm asked once" "$(asked ncz/password-confirm)" 1
check "username applied" "$(val passwd/username)" "pegasus"
check "password applied" "$(val passwd/user-password)" "s3cret pw"
check "the locked placeholder no longer outranks the real password" "$(val passwd/user-password-crypted)" ""
run ua user-chooser.sh --prompt
run ua user-chooser.sh
check "a re-run (--prompt and seed) asks nothing more" "$(wc -l < "$FDB/inputs" | tr -d ' ')" 3
check "a re-run keeps the username" "$(val passwd/username)" "pegasus"
check "a re-run keeps the password" "$(val passwd/user-password)" "s3cret pw"
check "a re-run does not bring the placeholder back" "$(val passwd/user-password-crypted)" ""

newdb ub "quiet ncz_unattended=1"   # KVM gate: passwd/* preseeded on the kernel command line (seen)
mkq passwd/username nczuser; printf true > "$FDB/s/passwd%username"
mkq passwd/user-password nczpassword123; printf true > "$FDB/s/passwd%user-password"
mkq passwd/user-password-again nczpassword123; printf true > "$FDB/s/passwd%user-password-again"
mkq passwd/user-fullname NCZTestUser; printf true > "$FDB/s/passwd%user-fullname"
run ub user-chooser.sh
check "seed keeps a cmdline passwd/username" "$(val passwd/username)" "nczuser"
check "seed sets no placeholder when a password is preseeded" "$(val passwd/user-password-crypted)" ""
run ub user-chooser.sh --prompt
check "unattended --prompt asks nothing" "$(wc -l < "$FDB/inputs" | tr -d ' ')" 0
check "unattended keeps the preseeded username" "$(val passwd/username)" "nczuser"
check "unattended keeps the preseeded password" "$(val passwd/user-password)" "nczpassword123"

newdb uc "quiet ncz_username=gate ncz_password=pw1"
run uc user-chooser.sh
check "seed applies ncz_username=" "$(val passwd/username)" "gate"
check "seed applies ncz_password= (no placeholder)" "$(val passwd/user-password):$(val passwd/user-password-crypted)" "pw1:"
check "ncz_* seed leaves nothing for user-setup to ask" "$(native_would_ask)" ""

# ---------------------------------------------------------------- C. components ------------------------------------
echo "== C. component-selector.sh"
newdb ca; mkq ncz/components; ans ncz/components "desktop, rescue-partition"
NCZ_UNAME_M=aarch64 run ca component-selector.sh --prompt
NCZ_UNAME_M=aarch64 run ca component-selector.sh --prompt
NCZ_UNAME_M=aarch64 run ca component-selector.sh
check "components asked once across three runs" "$(asked ncz/components)" 1
check "the operator's component answer survives the re-runs" "$(cat "$STMP/ncz-components")" "desktop,browsers,wallpaper-rotator,rescue-partition"

# ---------------------------------------------------------------- D. net-pick ----------------------------------------
echo "== D. net-pick.sh"
mksys() {   # dir: PCI eno2 (carrier $2), USB enx (carrier $3)
    local d=$1; rm -rf "$d"; mkdir -p "$d/net" "$d/pci/0000:3c:00.0" "$d/devices/pci0000:00/0000:3c:00.0" "$d/devices/pci0000:00/0000:00:14.0/usb1/1-10/1-10:1.0"
    echo 0x020000 > "$d/pci/0000:3c:00.0/class"
    mkdir -p "$d/net/lo" "$d/net/eno2" "$d/net/enx00e05c6701d5"
    echo "$2" > "$d/net/eno2/carrier"; echo "$3" > "$d/net/enx00e05c6701d5/carrier"
    ln -s "$d/devices/pci0000:00/0000:3c:00.0" "$d/net/eno2/device"
    ln -s "$d/devices/pci0000:00/0000:00:14.0/usb1/1-10/1-10:1.0" "$d/net/enx00e05c6701d5/device"
}
netrun() { local tag=$1 sys=$2; shift 2
    PATH="$W/bin:$PATH" NCZ_CONFMODULE="$W/confmodule" NCZ_SYS_NET="$sys/net" NCZ_SYS_PCI="$sys/pci" NCZ_NET_STATE="$W/tmp.$tag/picked" \
        NCZ_NET_TICK=0 NCZ_NET_SETTLE=3 NCZ_NET_MAXWAIT=5 NCZ_NET_TTY=/dev/null NCZ_IP=true $SHX "$PRE/net-pick.sh" "$@" >> "$W/log.$tag" 2>&1; }
newdb na; mkq netcfg/choose_interface auto; mkq netcfg/link_wait_timeout 60
mksys "$W/sys.na" 0 1
netrun na "$W/sys.na" scan
check "PEGASUS shape: the USB NIC with carrier is pinned, not the cable-less eno2" "$(val netcfg/choose_interface)" "enx00e05c6701d5"
check "the pin is seen (netcfg does not ask)" "$(seen netcfg/choose_interface)" true
check "link wait for any other interface drops to 10 s" "$(val netcfg/link_wait_timeout)" "10"
# a defensive second evaluation: choose_interface back to auto, link wait back to 60; the apply pass restores them
printf auto > "$FDB/v/netcfg%choose_interface"; printf 60 > "$FDB/v/netcfg%link_wait_timeout"
netrun na "$W/sys.na"
check "a second evaluation (defensive) restores the pin" "$(val netcfg/choose_interface)" "enx00e05c6701d5"
check "a second evaluation (defensive) restores the short wait" "$(val netcfg/link_wait_timeout)" "10"
newdb nb; mkq netcfg/choose_interface auto; mkq netcfg/link_wait_timeout 60
mksys "$W/sys.nb" 1 1
netrun nb "$W/sys.nb" scan
check "PCI NIC with carrier wins over USB" "$(val netcfg/choose_interface)" "eno2"
newdb nc; mkq netcfg/choose_interface auto; mkq netcfg/link_wait_timeout 60
mksys "$W/sys.nc" 0 0
netrun nc "$W/sys.nc" scan
check "no carrier anywhere: netcfg stays on auto" "$(val netcfg/choose_interface)" "auto"
check "no carrier anywhere: the full preseeded wait stays" "$(val netcfg/link_wait_timeout)" "60"
newdb nd; mkq netcfg/choose_interface auto; mkq netcfg/link_wait_timeout 60
rm -rf "$W/sys.nd"; mkdir -p "$W/sys.nd/net/lo" "$W/sys.nd/pci"
s0=$(date +%s); netrun nd "$W/sys.nd" scan; rc=$?; s1=$(date +%s)
check "O6N shape (only lo): exits 0" "$rc" 0
check "O6N shape (only lo): netcfg stays on auto so d-i reports its own no-interface error" "$(val netcfg/choose_interface)" "auto"
[ $((s1 - s0)) -le 5 ] && ok "O6N shape (only lo): bounded, no hang ($((s1 - s0)) s)" || bad "O6N shape took $((s1 - s0)) s"

# ---------------------------------------------------------------- E. preseed.cfg wiring ------------------------------
echo "== E. preseed.cfg wiring"
CFG="$ROOT/preseed/preseed.cfg"
EARLY=$(awk '/^d-i preseed\/early_command string/{f=1} f{print} f && !/\\$/{exit}' "$CFG" | tr -d '\n\\')
DUP=${EARLY%%: > /tmp/.ncz-early-command-ran*}
case "$DUP" in *"sh /tmp/net-pick.sh "*) ok "duplicate early_command run re-applies the NIC pick through net-pick.sh" ;;
    *) bad "duplicate early_command run does not call net-pick.sh (the inline re-apply never had db_set)" ;; esac
case "$DUP" in *"command -v db_set"*) bad "duplicate run still gates on db_set, which preseed_command's sh -c never defines" ;;
    *) ok "duplicate run does not gate on an undefined db_set" ;; esac
case "$DUP" in *"sh /tmp/user-chooser.sh "*) ok "duplicate run re-seeds passwd/*" ;; *) bad "duplicate run does not re-seed passwd/*" ;; esac
case "$EARLY" in *"net-pick.sh scan"*) ok "first run scans through net-pick.sh" ;; *) bad "first run does not call net-pick.sh scan" ;; esac
case "$EARLY" in *"sh /tmp/user-chooser.sh >>"*) ok "first run seeds passwd/* before user-setup-udeb runs" ;; *) bad "first run does not seed passwd/*" ;; esac
PART=$(awk '/^d-i partman\/early_command string/{f=1} f{print} f && !/\\$/{exit}' "$CFG" | tr -d '\n\\')
pos() { printf '%s' "$PART" | grep -boE "$1" | head -1 | cut -d: -f1; }
a=$(pos '/tmp/region-chooser\.sh[[:space:]]+--prompt'); b=$(pos '/tmp/user-chooser\.sh[[:space:]]+--prompt')
c=$(pos '/tmp/component-selector\.sh[[:space:]]+--prompt'); d=$(pos 'sh[[:space:]]+"\$D/disk-fs-chooser\.sh"')
if [ -n "$a" ] && [ -n "$b" ] && [ -n "$c" ] && [ -n "$d" ] && [ "$a" -lt "$b" ] && [ "$b" -lt "$c" ] && [ "$c" -lt "$d" ]; then
    ok "partman/early_command order: region, user, components, disk"
else bad "partman/early_command order is not region < user < components < disk ($a $b $c $d)"; fi
printf '%s' "$PART" | grep -qE 'hostname-suggest\.sh[[:space:]]+--prompt' && bad "the hostname is still prompted" || ok "the hostname is automatic (no --prompt)"
grep -qE '^[[:space:]]*"net-pick\.sh",' "$ROOT/build/iso/patch-initrd-t2-kernel.py" && ok "net-pick.sh is baked into the initrd" || bad "net-pick.sh missing from BAKED_HELPERS"

echo "installer flow tests ($SHX): $PASS passed, $FAILS failed"
rc=0; [ "$FAILS" = 0 ] || rc=1
if [ -z "${NCZ_TEST_SH:-}" ] && command -v busybox >/dev/null 2>&1 && busybox sh -c 'exit 0' 2>/dev/null; then
    NCZ_TEST_SH="busybox sh" bash "$0" || rc=1
fi
exit $rc
