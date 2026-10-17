#!/bin/bash
# test-component-selection.sh -- the operator's component answer is authoritative end to end.
#
# 2026-10-13, amd64 install on a Macmini5,1 (Intel GPU only, so the dialog offered exactly desktop, mgmt-container and
# rescue-partition): the operator unticked all three and got the desktop, the ncz-recovery container and the
# NCZRESCUE partition anyway. cdebconf returns "" for a multiselect with nothing ticked, and component-selector.sh
# turned an empty answer back into the full default list before writing it.
#
# This suite runs the REAL scripts in the order d-i runs them, against a file-backed stand-in for cdebconf:
#   1. preseed/early_command      component-selector.sh            (no --prompt: must record nothing)
#   2. partman/early_command      component-selector.sh --prompt   (operator unticks everything)
#   3. a defensive early_command re-run and a partman restart      (must keep the answer, never ask again)
#   4. every consumer, extracted from its source file with only its paths redirected:
#        disk-fs-chooser.sh (erase confirmation + partman recipe), the debootstrap stub (desktop overlay),
#        late.sh (recovery into /target), post-install/run-all.sh (hook skips: desktop, 37+38 mgmt container,
#        72 rescue partition), build/70-bootloader.sh (default entry), post-install/54-gpu-accel.sh (cuda).
# It also proves the interactive failure paths stop loudly instead of installing everything, that the answer reaches
# syslog, that ncz_components=none and partial answers work, and that accepting the defaults still installs all.
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
PRE="$ROOT/preseed"
SHX="${NCZ_TEST_SH:-sh}"
echo "-- shell: $SHX"
W="$(mktemp -d "${TMPDIR:-/tmp}/component-selection.XXXXXX")"
trap 'rm -rf "$W"' EXIT
PASS=0; FAILS=0
ok()    { echo "ok   $1"; PASS=$((PASS+1)); }
bad()   { echo "FAIL $1"; FAILS=$((FAILS+1)); }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: got '$2' want '$3'"; fi; }

# ------------------------------------------------------------- fake cdebconf ---------------------------------------
# Same contract as build/test-installer-flow.sh, plus: $FDB/back = number of times the operator presses Go Back,
# $FDB/noinput = db_input fails (dialog cannot be shown).
cat > "$W/confmodule" <<'EOF'
_k() { printf '%s' "$1" | tr '/' '%'; }
db_exists() { [ -e "$FDB/q/$(_k "$1")" ]; }
db_set() { db_exists "$1" || return 10; printf '%s' "$2" > "$FDB/v/$(_k "$1")"; return 0; }
db_get() { RET=""; db_exists "$1" || return 10; RET=$(cat "$FDB/v/$(_k "$1")" 2>/dev/null); return 0; }
db_fset() { db_exists "$1" || return 10; [ "$2" = seen ] && printf '%s' "$3" > "$FDB/s/$(_k "$1")"; return 0; }
db_settitle() { return 0; }
db_input() {
    [ -e "$FDB/noinput" ] && return 1
    db_exists "$2" || return 10
    [ "$1" = critical ] || return 30
    [ "$(cat "$FDB/s/$(_k "$2")" 2>/dev/null)" = true ] && return 30
    echo "$2" >> "$FDB/inputs"; echo "$2" >> "$FDB/pending"; return 0
}
db_go() {
    [ -s "$FDB/pending" ] || return 0
    _b=$(cat "$FDB/back" 2>/dev/null || echo 0)
    if [ "$_b" -gt 0 ]; then echo $((_b - 1)) > "$FDB/back"; : > "$FDB/pending"; return 30; fi
    while read -r _q; do
        [ -e "$FDB/ans/$(_k "$_q")" ] && cp "$FDB/ans/$(_k "$_q")" "$FDB/v/$(_k "$_q")"
        printf true > "$FDB/s/$(_k "$_q")"
    done < "$FDB/pending"
    : > "$FDB/pending"; return 0
}
EOF
mkdir -p "$W/bin"
cat > "$W/bin/debconf-loadtemplate" <<'EOF'
#!/bin/sh
[ -e "$FDB/notemplate" ] && exit 1
cp "$2" "$FDB/tpl/$(basename "$2")"
awk '/^Template:/{t=$2; n[++c]=$2} /^Default:/{sub(/^Default:[ ]*/,""); d[t]=$0} END{for(i=1;i<=c;i++) print n[i] "\t" d[n[i]]}' "$2" |
while IFS="$(printf '\t')" read -r q d; do
    k=$(printf '%s' "$q" | tr '/' '%')
    [ -e "$FDB/q/$k" ] || { : > "$FDB/q/$k"; printf '%s' "$d" > "$FDB/v/$k"; }
done
EOF
# d-i's busybox logger -> the installer syslog that is copied to /var/log/installer/syslog on the target
cat > "$W/bin/logger" <<'EOF'
#!/bin/sh
_t=""; while [ $# -gt 0 ]; do case "$1" in -t) _t=$2; shift 2 ;; --) shift; break ;; *) break ;; esac; done
printf '%s: %s\n' "$_t" "$*" >> "$FDB/syslog"
EOF
# debconf-get as the stub/late.sh fallbacks see it: the raw multiselect value ("" when nothing is ticked)
cat > "$W/bin/debconf-get" <<'EOF'
#!/bin/sh
cat "$FDB/v/$(printf '%s' "$1" | tr '/' '%')" 2>/dev/null
EOF
chmod +x "$W/bin/"*

# Macmini5,1 PCI shape: Intel HD 3000 (0x8086 class 0x030000) and no NVIDIA, so cuda is not offered.
mkdir -p "$W/pci/0000:00:02.0"; echo 0x8086 > "$W/pci/0000:00:02.0/vendor"; echo 0x030000 > "$W/pci/0000:00:02.0/class"
CMDLINE_DI="BOOT_IMAGE=/install.amd/vmlinuz auto=true priority=critical DEBIAN_FRONTEND=newt quiet"

newdb() {   # tag [cmdline]
    T=$1; FDB="$W/db.$T"; STMP="$W/tmp.$T"; STATE="$W/state.$T"; TGT="$W/target.$T"
    rm -rf "$FDB" "$STMP" "$STATE" "$TGT"; mkdir -p "$FDB/q" "$FDB/v" "$FDB/s" "$FDB/ans" "$FDB/tpl" "$STMP" "$TGT"
    : > "$FDB/inputs"; : > "$FDB/pending"; : > "$FDB/syslog"
    printf '%s\n' "${2:-$CMDLINE_DI}" > "$W/cmdline.$T"; export FDB
}
ans()   { printf '%s' "$2" > "$FDB/ans/$(printf '%s' "$1" | tr '/' '%')"; }
asked() { grep -cx "$1" "$FDB/inputs" 2>/dev/null || true; }
sel()   {   # run component-selector.sh [--prompt]; prints its exit status
    PATH="$W/bin:$PATH" NCZ_CONFMODULE="$W/confmodule" NCZ_CMDLINE="$W/cmdline.$T" NCZ_TMP="$STMP" NCZ_COMP_STATE="$STATE" \
        NCZ_TARGET="$TGT" NCZ_LOGGER="$W/bin/logger" NCZ_UNAME_M="${ARCH:-x86_64}" NCZ_PCI_DEVICES="$W/pci" NCZ_UI_SH=/nonexistent \
        $SHX "$PRE/component-selector.sh" "$@" >> "$W/log.$T" 2>&1
    echo $?
}
rec()   { cat "$STATE/COMPONENTS" 2>/dev/null; }
mir()   { cat "$STMP/ncz-components" 2>/dev/null; }

# ---- consumers, extracted from their real sources (paths redirected into the sandbox, logic untouched) -------------
extract() { awk -v s="$2" -v e="$3" 'f==0 && $0 ~ s {f=1; print; next} f==1 {print; if ($0 ~ e) exit}' "$1"; }
redirect() {
    sed -e "s#/tmp/ncz-components#$STMP/ncz-components#g" \
        -e "s#/var/lib/ncz-components#$STATE#g" \
        -e "s#/var/lib/cdebconf/questions.dat#$W/no-questions.dat#g" \
        -e "s#/target/var/log/installer/syslog#$W/no-syslog#g" \
        -e "s#/var/log/installer/syslog#$W/no-syslog#g" \
        -e "s#/var/log/syslog#$W/no-syslog#g" \
        -e "s#/target/#$TGT/#g" \
        -e "s#\([ =]\)/usr/local/lib/cix-installer/#\1$TGT/usr/local/lib/cix-installer/#g" \
        -e "s#\([ =]\)/etc/cix-installer/#\1$TGT/etc/cix-installer/#g" \
        -e "s#\([ =]\)/var/lib/cix-components/#\1$TGT/var/lib/cix-components/#g"
}
STUB_PY="$ROOT/build/iso/patch-debootstrap-stub.py"
consumer_stub() {   # -> ROLE the r159 debootstrap stub applies (desktop = overlay extracted)
    { extract "$STUB_PY" '^    ncz_component_record[(][)] [{]' '^    [}]$'
      extract "$STUB_PY" '^    ROLE=desktop$' '^        echo "W: r159 stub: component selection unavailable'
      echo '    fi'; echo 'echo "ROLE=$ROLE"'; } | redirect > "$W/stub.$T.sh"
    PATH="$W/bin:$PATH" $SHX "$W/stub.$T.sh" 2>/dev/null | sed -n 's/^ROLE=//p'
}
consumer_disk() {   # -> "<confirm-screen rescue> <recipe WANT_RESCUE_PART>"
    { echo 'log() { :; }'
      extract "$PRE/disk-fs-chooser.sh" '^    _ncz_sel=[$][(]tr' '^    fi$'
      extract "$PRE/disk-fs-chooser.sh" '^WANT_RESCUE_PART=1$' '^fi$'
      echo 'echo "$_ncz_resc $WANT_RESCUE_PART"'; } | redirect > "$W/disk.$T.sh"
    $SHX "$W/disk.$T.sh" 2>/dev/null
}
consumer_late() {   # late.sh recovery into /target; -> recovered value
    { extract "$PRE/late.sh" '^ncz_recover_components[(][)] [{]' '^[}]$'; echo 'ncz_recover_components'; } | redirect > "$W/late.$T.sh"
    PATH="$W/bin:$PATH" $SHX "$W/late.$T.sh" 2>/dev/null
}
consumer_runall() { # -> the hooks run-all.sh still runs
    { echo 'TTY=/dev/null'
      echo 'OPT_HOOKS="20-desktop.sh 33-network.sh 37-failsafe-access.sh 38-recovery-container.sh 45-wallpaper-rotator.sh 52-vivaldi.sh 55-greeter.sh 72-rescue-partition.sh"'
      extract "$ROOT/post-install/run-all.sh" '^COMP_FILE=/usr/local/lib/cix-installer/COMPONENTS$' '^# AUDIT: name every hook'
      echo 'echo $OPT_HOOKS'; } | redirect > "$W/runall.$T.sh"
    $SHX "$W/runall.$T.sh" 2>/dev/null | tail -1
}
consumer_bootloader() { # -> default rEFInd entry
    { echo 'NEXT_AVAILABLE=1'
      extract "$ROOT/build/70-bootloader.sh" '^DEFAULT_ENTRY="cixmini-next"$' '^fi$'
      echo 'echo "DEFAULT=$DEFAULT_ENTRY"'; } | redirect > "$W/bl.$T.sh"
    $SHX "$W/bl.$T.sh" 2>/dev/null | sed -n 's/^DEFAULT=//p'
}
consumer_cuda() {   # -> yes|no
    { extract "$ROOT/post-install/54-gpu-accel.sh" '^ncz_variant[(][)] [{]' '^[}]$'
      extract "$ROOT/post-install/54-gpu-accel.sh" '^ncz_cuda_component_wanted[(][)] [{]' '^[}]$'
      echo 'ncz_cuda_component_wanted && echo yes || echo no'; } | redirect > "$W/cuda.$T.sh"
    bash "$W/cuda.$T.sh" 2>/dev/null
}

# ------------------------------------------------------------- 1. the reported sequence -----------------------------
echo "== 1. operator unticks every component (Macmini5,1 report), then early_command / partman re-run"
newdb mac
check "first early_command run exits 0" "$(sel)" 0
[ -e "$STATE/COMPONENTS" ] || [ -e "$STMP/ncz-components" ] && bad "the first (non-prompt) run recorded an answer the operator never gave: [$(rec)] [$(mir)]" || ok "the first (non-prompt) run records nothing"
check "first early_command run asks nothing" "$(asked ncz/components)" 0
ans ncz/components ""
check "--prompt run exits 0" "$(sel --prompt)" 0
check "the dialog was shown once" "$(asked ncz/components)" 1
grep -q '^Choices: desktop, mgmt-container, rescue-partition$' "$FDB/tpl/ncz-components.templates" \
    && grep -q '^Choices-C: Full Singularity desktop (GUI labwc + greetd + branding), ncz-recovery management container (nspawn), 4 GiB NCZRESCUE partition (rescue rootfs + kernel)$' "$FDB/tpl/ncz-components.templates" \
    && ok "Macmini5,1 shape: exactly the three components were offered (Choices: tokens, Choices-C: display labels)" \
    || bad "unexpected Choices/Choices-C: $(grep -E '^Choices' "$FDB/tpl/ncz-components.templates")"
check "authoritative record: nothing selected" "$(rec)" none
check "/tmp mirror matches the record" "$(mir)" none
check "target copy (etc/cix-installer) matches" "$(cat "$TGT/etc/cix-installer/COMPONENTS" 2>/dev/null)" none
check "COMPONENTS_desktop bit is 0" "$(cat "$TGT/etc/cix-installer/COMPONENTS_desktop" 2>/dev/null)" 0
grep -q 'ncz-components: component prompt answered: \[none\]' "$FDB/syslog" && ok "the answer is in syslog (tag ncz-components)" || bad "the answer never reached syslog: $(cat "$FDB/syslog")"
check "defensive early_command re-run exits 0" "$(sel)" 0
check "  ...keeps the answer" "$(rec)/$(mir)" none/none
check "partman restart (--prompt again) exits 0" "$(sel --prompt)" 0
check "  ...asks nothing" "$(asked ncz/components)" 1
check "  ...keeps the answer" "$(rec)/$(mir)" none/none
check "disk-fs-chooser: erase screen says no rescue partition, recipe has no NCZRESCUE stanza" "$(consumer_disk)" "no 0"
check "debootstrap stub: base only, no desktop overlay" "$(consumer_stub)" base
rm -rf "$TGT"; mkdir -p "$TGT"   # partman mounts the real root over /target: the selector's early copies are gone
check "late.sh recovers the record" "$(consumer_late)" none
check "late.sh persisted it into the target" "$(cat "$TGT/usr/local/lib/cix-installer/COMPONENTS" 2>/dev/null)" none
check "run-all.sh: no desktop hooks, no 37-failsafe-access/38-recovery-container, no 72-rescue-partition" "$(consumer_runall)" "33-network.sh"
check "70-bootloader: default entry is the console" "$(consumer_bootloader)" cixmini-console
check "54-gpu-accel: cuda not wanted" "$(consumer_cuda)" no
# the pre-fix flow: the stub/late fallbacks only ever saw the raw debconf value, and "" meant "everything"
rm -f "$STATE/COMPONENTS" "$STMP/ncz-components"
check "control: with the record lost, the stub falls back to the desktop (why the record must never be empty)" "$(consumer_stub)" desktop

# ------------------------------------------------------------- 2. partial and default answers -----------------------
echo "== 2. partial answers, defaults, overrides"
newdb part; sel >/dev/null; ans ncz/components "desktop"; sel --prompt >/dev/null
check "desktop only: record" "$(rec)" "desktop,browsers,wallpaper-rotator"
check "desktop only: no rescue partition" "$(consumer_disk)" "no 0"
check "desktop only: stub applies the desktop" "$(consumer_stub)" desktop
rm -rf "$TGT"; mkdir -p "$TGT"; consumer_late >/dev/null
check "desktop only: run-all skips 37, 38 and 72 only" "$(consumer_runall)" "20-desktop.sh 33-network.sh 45-wallpaper-rotator.sh 52-vivaldi.sh 55-greeter.sh"
newdb dflt; sel >/dev/null; sel --prompt >/dev/null
check "Enter on the defaults: everything" "$(rec)" "desktop,browsers,wallpaper-rotator,mgmt-container,rescue-partition"
check "Enter on the defaults: rescue partition" "$(consumer_disk)" "yes 1"
rm -rf "$TGT"; mkdir -p "$TGT"; consumer_late >/dev/null
check "Enter on the defaults: every hook runs" "$(consumer_runall)" "20-desktop.sh 33-network.sh 37-failsafe-access.sh 38-recovery-container.sh 45-wallpaper-rotator.sh 52-vivaldi.sh 55-greeter.sh 72-rescue-partition.sh"
newdb ovn "$CMDLINE_DI ncz_components=none"
check "ncz_components=none: exits 0 without --prompt" "$(sel)" 0
check "ncz_components=none: record" "$(rec)" none
sel --prompt >/dev/null
check "ncz_components=none: no dialog" "$(asked ncz/components)" 0
check "ncz_components=none: stub base only" "$(consumer_stub)" base
newdb ovd "$CMDLINE_DI ncz_components=desktop,mgmt-container,rescue-partition"; sel >/dev/null; sel --prompt >/dev/null
check "KVM gate override still installs everything" "$(rec)" "desktop,browsers,wallpaper-rotator,mgmt-container,rescue-partition"
check "KVM gate override: no dialog" "$(asked ncz/components)" 0
ARCH=aarch64 newdb arm; ARCH=aarch64 sel >/dev/null; ans ncz/components ""; ARCH=aarch64 sel --prompt >/dev/null
check "arm64 (same script): nothing ticked -> none" "$(rec)" none

# --------------------------------------------- 2b. S1-3: reassembly respects the answer ---------------------------------
# The reassembly must derive browsers/wallpaper-rotator from desktop (their
# contract) WITHOUT re-adding a component the operator explicitly deselected,
# and without dropping tokens the operator's record carries.
echo "== 2b. S1-3: the normalised record is the single source of truth"
# desktop OFF, but a stale/hand-edited record still names browsers: no browser
# packages may ride along.
newdb s13a
mkdir -p "$STATE"; printf '%s' "browsers,mgmt-container" > "$STATE/COMPONENTS"; : > "$STMP/.ncz-components-done"
sel >/dev/null
check "desktop deselected + stray browsers -> record keeps the operator's list" "$(rec)" "browsers,mgmt-container"
grep -q 'desktop=0' "$W/log.s13a" && ok "desktop stays deselected (not re-added by the reassembly)" || bad "desktop was re-added"
# the real regression: the OLD reassembly rebuilt from WANT_DESKTOP alone, so a
# record WITHOUT desktop still had browsers/wallpaper-rotator appended. Assert
# the desktop companions are absent when desktop is not selected.
grep -qE '^SELECTED COMPONENTS: .*wallpaper-rotator' "$W/log.s13a" \
    && bad "desktop off still appended the wallpaper-rotator companion" \
    || ok "desktop off: no wallpaper-rotator companion appended"
# the desktop toggle off means the desktop hooks are skipped: no browser/desktop payload is installed
rm -rf "$TGT"; mkdir -p "$TGT"; consumer_late >/dev/null
check "desktop deselected: no desktop overlay is applied" "$(consumer_stub)" base
# desktop ON: the companions ride along (contract preserved) and stay contiguous
newdb s13b
mkdir -p "$STATE"; printf '%s' "mgmt-container,desktop" > "$STATE/COMPONENTS"; : > "$STMP/.ncz-components-done"
sel >/dev/null
check "desktop on -> browsers/wallpaper-rotator ride along, operator order kept" "$(rec)" "mgmt-container,desktop,browsers,wallpaper-rotator"
# desktop ON with the companions already present: no duplicate
newdb s13c
mkdir -p "$STATE"; printf '%s' "desktop,browsers,wallpaper-rotator,cuda" > "$STATE/COMPONENTS"; : > "$STMP/.ncz-components-done"
sel >/dev/null
check "desktop on, companions already present -> deduped, order kept" "$(rec)" "desktop,browsers,wallpaper-rotator,cuda"
# a token the reassembly does not know about must not be silently dropped when it is a valid internal token
newdb s13d
mkdir -p "$STATE"; printf '%s' "cuda,mgmt-container" > "$STATE/COMPONENTS"; : > "$STMP/.ncz-components-done"
sel >/dev/null
check "no desktop, cuda + mgmt kept in the operator's order" "$(rec)" "cuda,mgmt-container"
# the per-toggle bits the hooks read must agree: desktop/browsers/wallpaper off
check "no desktop: COMPONENTS_desktop bit is 0" "$(cat "$TGT/etc/cix-installer/COMPONENTS_desktop" 2>/dev/null)" 0
check "no desktop: COMPONENTS_browsers bit is 0" "$(cat "$TGT/etc/cix-installer/COMPONENTS_browsers" 2>/dev/null)" 0
check "no desktop: COMPONENTS_wallpaper-rotator bit is 0" "$(cat "$TGT/etc/cix-installer/COMPONENTS_wallpaper-rotator" 2>/dev/null)" 0

# ------------------------------------------------------------- 3. interactive failures stop loudly ------------------
echo "== 3. a dialog that cannot be completed never becomes 'install everything'"
newdb back; sel >/dev/null; echo 1 > "$FDB/back"; ans ncz/components "mgmt-container"
check "Go Back once: asked again and exits 0" "$(sel --prompt)" 0
check "Go Back once: second answer kept" "$(rec)" mgmt-container
check "Go Back once: dialog shown twice" "$(asked ncz/components)" 2
newdb back3; sel >/dev/null; echo 9 > "$FDB/back"
rc=$(sel --prompt); [ "$rc" != 0 ] && ok "Go Back every time: exits non-zero ($rc)" || bad "Go Back every time: exit 0"
[ -e "$STATE/COMPONENTS" ] || [ -e "$STMP/ncz-components" ] && bad "Go Back every time: a record was written: [$(rec)]" || ok "Go Back every time: no record written"
grep -q 'FATAL' "$FDB/syslog" && ok "Go Back every time: FATAL logged to syslog" || bad "Go Back every time: no FATAL in syslog"
newdb noin; sel >/dev/null; : > "$FDB/noinput"
rc=$(sel --prompt); [ "$rc" != 0 ] && ok "dialog cannot be shown: exits non-zero ($rc)" || bad "dialog cannot be shown: exit 0"
[ -e "$STATE/COMPONENTS" ] && bad "dialog cannot be shown: record written [$(rec)]" || ok "dialog cannot be shown: no record written"
newdb notpl; sel >/dev/null; : > "$FDB/notemplate"
rc=$(sel --prompt); [ "$rc" != 0 ] && ok "template cannot load: exits non-zero ($rc)" || bad "template cannot load: exit 0"
[ -e "$STATE/COMPONENTS" ] && bad "template cannot load: record written [$(rec)]" || ok "template cannot load: no record written"

# ------------------------------------------------------------- 4. wiring ---------------------------------------------
echo "== 4. preseed wiring"
PART=$(awk '/^d-i partman\/early_command string/{f=1} f{print} f && !/\\$/{exit}' "$ROOT/preseed/preseed.cfg" | tr -d '\n\\')
printf '%s' "$PART" | grep >/dev/null -E 'sh /tmp/component-selector\.sh --prompt [^;]*\|\| exit \$\?' \
    && ok "partman/early_command stops the install when the component dialog fails" \
    || bad "partman/early_command ignores the component-selector --prompt exit status"
grep -q '|| CHOSEN="\$_DEFAULT"' "$PRE/component-selector.sh" && bad "component-selector.sh still maps an empty answer to the default" || ok "no empty -> default fallback left in component-selector.sh"

echo "component selection tests ($SHX): $PASS passed, $FAILS failed"
rc=0; [ "$FAILS" = 0 ] || rc=1
if [ -z "${NCZ_TEST_SH:-}" ] && command -v busybox >/dev/null 2>&1 && busybox sh -c 'exit 0' 2>/dev/null; then
    NCZ_TEST_SH="busybox sh" bash "$0" || rc=1
fi
exit $rc
