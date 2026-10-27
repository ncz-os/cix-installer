#!/bin/bash
# Fixture tests for build/check-installer-screens.py (both directions) and the ASCII-only template rule.
# 2026-09-30: added --require-prompt-sequence and --require-boot-progress tests covering the
# operator-mandated 6-step interactive flow (components + region + username + password +
# password-confirm + hostname + disk + erase-confirm) and the boot-progress [NCZ HH:MM:SS +Ns]
# messages (Loading installer / Detecting hardware / Detecting storage/USB / Starting network /
# Preparing installer dialogs / Ready).
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0; FAILS=0
expect() { local n="$1" want="$2"; shift 2; "$@" >"$T/out" 2>&1; local rc=$?
    if { [ "$want" = 0 ] && [ $rc = 0 ]; } || { [ "$want" != 0 ] && [ $rc != 0 ]; }; then PASS=$((PASS+1)); echo "ok   $n"
    else FAILS=$((FAILS+1)); echo "FAIL $n (rc=$rc)"; sed 's/^/     /' "$T/out"; fi; }
mk() { rm -rf "$T/s"; mkdir -p "$T/s"; printf '# t=20s\n%s\n' "$1" > "$T/s/0000-0020s.txt"; }
GOOD=$'  NCZ-OS 26.10 Cygnus | arm64 (Sky1) | build abc1234\n  lqqqqqqqqqqqqqqqqqqqqqu [!!] NCZ-OS install tqqqqqqqqqqqqqqqk\n  x Untick to skip an optional component.  x\n  x  [*] Full Singularity desktop           x\n  mqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqj'
chk() { python3 "$HERE/check-installer-screens.py" "$T/s" "$@"; }
mk "$GOOD";                                                   expect "clean dialog passes"                    0 chk --require-dialog "optional component"
mk "$GOOD"$'\n[diag] sshd running pid=1';                      expect "[diag] chatter fails"                    1 chk
mk "$GOOD"$'\n   ssh root@10.0.2.15 (password: diags)';         expect "password hint fails"                     1 chk
mk "${GOOD/Full Singularity desktop/desktop <ERR>}";           expect "<ERR> row fails"                         1 chk
mk "$GOOD"$'\n[ncz components] showing component prompt';      expect "[ncz ...] prefix fails"                  1 chk
mk "$GOOD"$'\nPlease press Enter to activate this console.';   expect "askfirst prompt fails"                   1 chk
mk "$GOOD";                                                   expect "missing required dialog text fails"      1 chk --require-dialog "name this computer"
mk "$GOOD";                                                   expect "header present passes"                   0 chk --require-header "NCZ-OS [0-9.]+ [A-Za-z]+ \\|"
mk $'  lqqqqqqqqqqqqqqu title tqqqqqqk\n  x hello x\n  mqqqqqqqqqqqqqqqqqqj'; expect "dialog without header fails" 1 chk --require-header "NCZ-OS [0-9.]+"
mk2() { rm -rf "$T/s"; mkdir -p "$T/s"; printf '# t=20s\n%s\n' "$1" > "$T/s/0000-0020s.txt"; printf '# t=30s\n%s\n' "$2" > "$T/s/0001-0030s.txt"; }
BLANK=$'[                    (1**installer)  2 shell  3 shell  4- log'
mk3() { rm -rf "$T/s"; mkdir -p "$T/s"; printf '# t=20s\n%s\n' "$1" > "$T/s/0000-0020s.txt"; printf '# t=%s\n%s\n' "$3" "$2" > "$T/s/0001-0030s.txt"; printf '# t=%s\n%s\n' "$4" "$1" > "$T/s/0002-0060s.txt"; }
mk3 "$GOOD" "$BLANK" 30s 60s; expect "a 30 s blank console after the dialog fails" 1 chk --no-blank-after "optional component"
mk3 "$GOOD" "$BLANK" 30s 34s; expect "a 4 s redraw gap is tolerated" 0 chk --no-blank-after "optional component"
mk2 "$GOOD" "$BLANK";                                         expect "a trailing blank console fails"     1 chk --no-blank-after "optional component"
mk2 "$GOOD" "$GOOD";                                          expect "a dialog that stays up passes"            0 chk --no-blank-after "optional component"
mk2 "$BLANK" "$BLANK";                                        expect "blank BEFORE the marker dialog is not judged" 0 chk --no-blank-after "optional component"
rm -rf "$T/s"; mkdir "$T/s";                                  expect "empty capture fails"                     1 chk
# --- the blank after the bootloader frame (amd64 framebuffer sampling, kernel + initrd load) ---
FB=$'[framebuffer: dialog or progress on screen, 11.7% non-background pixels]'
mkt() { rm -rf "$T/s"; mkdir -p "$T/s"; local i=0; while [ $# -ge 2 ]; do
    printf '# t=%ss\n%s\n' "$1" "$2" > "$T/s/$(printf '%04d-%04ds' "$i" "$1").txt"; i=$((i+1)); shift 2; done; }
mkt 0 "$FB" 6 "" 15 "$FB" 20 "$FB";  expect "a 9 s blank after the bootloader frame fails without --boot-blank-max-secs" 1 chk --no-blank-after "framebuffer"
mkt 0 "$FB" 6 "" 15 "$FB" 20 "$FB";  expect "a 9 s blank after the bootloader frame passes with --boot-blank-max-secs 20" 0 chk --no-blank-after "framebuffer" --boot-blank-max-secs 20
mkt 0 "$FB" 6 "" 31 "$FB" 40 "$FB";  expect "a 25 s blank after the bootloader frame fails with --boot-blank-max-secs 20" 1 chk --no-blank-after "framebuffer" --boot-blank-max-secs 20
mkt 0 "$FB" 6 "" 10 "$FB" 30 "" 39 "$FB"; expect "a later 9 s blank still fails with --boot-blank-max-secs 20" 1 chk --no-blank-after "framebuffer" --boot-blank-max-secs 20
mkt 0 "$FB" 6 "" 10 "$FB" 30 "" 39 "$FB"; expect "--allow-first-blank would hide that later blank (why it is not used)" 0 chk --no-blank-after "framebuffer" --allow-first-blank
mkt 0 "$BLANK" 5 "$FB" 6 "" 15 "$FB";  expect "no boot allowance when judging starts after the first state" 1 chk --no-blank-after "framebuffer" --boot-blank-max-secs 20
# --- state count is a floor + evidence, not an equality (r201: arm64 35 -> 33 -> 32, same dialogs) ---
mk "$GOOD";                                                   expect "--min-states floor: 1 state < 5 fails"   1 chk --min-states 5
mk "$GOOD";                                                   expect "--min-states floor met passes"           0 chk --min-states 1
mk "$GOOD"; chk >"$T/ev" 2>&1
if grep -q 'dialogs in capture order (1): NCZ-OS install' "$T/ev"; then PASS=$((PASS+1)); echo "ok   OK output names the dialogs in capture order"
else FAILS=$((FAILS+1)); echo "FAIL dialog evidence line missing"; sed 's/^/     /' "$T/ev"; fi
# --- operator-required 6-step prompt sequence (2026-09-30) -------------------
# Components, region, username, password, password-confirm, hostname, target disk, erase-confirm.
# Each prompt is a distinct dialog state. The regex tokens are the operator's phrases
# from disk-fs-chooser.sh / region-chooser.sh / user-chooser.sh / hostname-suggest.sh /
# component-selector.sh -- if the chooser source changes a title, the test catches it.
DIALOG_COMP=$'  NCZ-OS 26.10 Cygnus | arm64 (Sky1) | build abc1234\n  lqqqqqqqqq [NCZ-OS install - optional components tqqqqqqqqqq k\n  x Untick to skip an optional component.  x\n  mqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqj'
DIALOG_REG=$'  NCZ-OS 26.10 Cygnus | arm64 (Sky1) | build abc1234\n  lqqqqqqqqq [NCZ-OS install - select your REGION tqqqqqqqqqq k\n  x body x\n  mqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqj'
DIALOG_USR=$'  NCZ-OS 26.10 Cygnus | arm64 (Sky1) | build abc1234\n  lqqqqqqqqq [NCZ-OS install - choose a USERNAME tqqqqqqqqqq k\n  x body x\n  mqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqj'
DIALOG_PWD=$'  NCZ-OS 26.10 Cygnus | arm64 (Sky1) | build abc1234\n  lqqqqqqqqq [NCZ-OS install - choose a PASSWORD for ncz tqqqqq k\n  x body x\n  mqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqj'
DIALOG_PWDC=$'  NCZ-OS 26.10 Cygnus | arm64 (Sky1) | build abc1234\n  lqqqqqqqqq [NCZ-OS install - type the same PASSWORD again tqqq k\n  x body x\n  mqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqj'
DIALOG_HOST=$'  NCZ-OS 26.10 Cygnus | arm64 (Sky1) | build abc1234\n  lqqqqqqqqq [NCZ-OS install - name this computer (hostname) tqqqq k\n  x body x\n  mqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqj'
DIALOG_DISK=$'  NCZ-OS 26.10 Cygnus | arm64 (Sky1) | build abc1234\n  lqqqqqqqqq [NCZ-OS install - select the TARGET DISK tqqqqqqqqq k\n  x body x\n  mqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqj'
DIALOG_ROOTFS=$'  NCZ-OS 26.10 Cygnus | arm64 (Sky1) | build abc1234\n  lqqqqqqqqq [NCZ-OS install - root (/) filesystem tqqqqqqqqqq k\n  x body x\n  mqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqj'
# Note: the regex tokens passed to --require-prompt-sequence are Python
# re patterns; "(" and ")" are regex metacharacters, so the dialog-title
# regex for the root-fs prompt uses the unique substring "root" + "filesystem"
# to avoid the metachar trap while still uniquely identifying the dialog.
DIALOG_ERASE=$'  NCZ-OS 26.10 Cygnus | arm64 (Sky1) | build abc1234\n  lqqqqqqqqq [NCZ-OS install - ERASE /dev/sda and install? tqqqq k\n  x body x\n  mqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqj'
# The required flow is 9 dialog states (step 4 = 2 password prompts,
# step 6 = target-disk + root-fs + erase confirmation = 3 dialogs). The first
# 8 of 9 are checked by the existing mk8 helper; the full 9-state flow is
# checked separately by mk9 below so a regression that reorders the disk-stage
# dialogs (target disk / root fs / erase confirmation) is caught here too.
mk8() { rm -rf "$T/s"; mkdir -p "$T/s"
    printf '# t=15s\n%s\n' "$1" > "$T/s/0000-0015s.txt"
    printf '# t=20s\n%s\n' "$2" > "$T/s/0001-0020s.txt"
    printf '# t=25s\n%s\n' "$3" > "$T/s/0002-0025s.txt"
    printf '# t=27s\n%s\n' "$4" > "$T/s/0003-0027s.txt"
    printf '# t=30s\n%s\n' "$5" > "$T/s/0004-0030s.txt"
    printf '# t=33s\n%s\n' "$6" > "$T/s/0005-0033s.txt"
    printf '# t=37s\n%s\n' "$7" > "$T/s/0006-0037s.txt"
    printf '# t=41s\n%s\n' "$8" > "$T/s/0007-0041s.txt"; }
mk8 "$DIALOG_COMP" "$DIALOG_REG" "$DIALOG_USR" "$DIALOG_PWD" "$DIALOG_PWDC" "$DIALOG_HOST" "$DIALOG_DISK" "$DIALOG_ROOTFS"
expect "operator-required 8-of-9 dialog sequence (components region user password password-confirm hostname target-disk root-fs) passes" 0 chk --require-prompt-sequence "optional components" "select your REGION" "choose a USERNAME" "choose a PASSWORD" "type the same PASSWORD" "name this computer" "TARGET DISK" "root \\(/\\) filesystem"
mk9() { rm -rf "$T/s"; mkdir -p "$T/s"
    printf '# t=15s\n%s\n' "$1" > "$T/s/0000-0015s.txt"
    printf '# t=18s\n%s\n' "$2" > "$T/s/0001-0018s.txt"
    printf '# t=21s\n%s\n' "$3" > "$T/s/0002-0021s.txt"
    printf '# t=24s\n%s\n' "$4" > "$T/s/0003-0024s.txt"
    printf '# t=27s\n%s\n' "$5" > "$T/s/0004-0027s.txt"
    printf '# t=30s\n%s\n' "$6" > "$T/s/0005-0030s.txt"
    printf '# t=33s\n%s\n' "$7" > "$T/s/0006-0033s.txt"
    printf '# t=36s\n%s\n' "$8" > "$T/s/0007-0036s.txt"
    printf '# t=40s\n%s\n' "$9" > "$T/s/0008-0040s.txt"; }
mk9 "$DIALOG_COMP" "$DIALOG_REG" "$DIALOG_USR" "$DIALOG_PWD" "$DIALOG_PWDC" "$DIALOG_HOST" "$DIALOG_DISK" "$DIALOG_ROOTFS" "$DIALOG_ERASE"
expect "operator-required full 9-dialog sequence (6-step + 2x password + target/root-fs/erase) passes" 0 chk --require-prompt-sequence "optional components" "select your REGION" "choose a USERNAME" "choose a PASSWORD" "type the same PASSWORD" "name this computer" "TARGET DISK" "root \\(/\\) filesystem" "ERASE"
# Negative: out-of-order swap of root-fs and erase-confirm must FAIL.
mk9 "$DIALOG_COMP" "$DIALOG_REG" "$DIALOG_USR" "$DIALOG_PWD" "$DIALOG_PWDC" "$DIALOG_HOST" "$DIALOG_DISK" "$DIALOG_ERASE" "$DIALOG_ROOTFS"
expect "operator-required 9-step sequence fails when root-fs and ERASE are swapped" 1 chk --require-prompt-sequence "optional components" "select your REGION" "choose a USERNAME" "choose a PASSWORD" "type the same PASSWORD" "name this computer" "TARGET DISK" "root \\(/\\) filesystem" "ERASE"
# 2026-10-06 operator flow (photos from GU502LV): region FIRST, username, password, confirm, components, then the disk
# dialogs; no hostname dialog. The checker accepts that sequence and rejects the r199 order (components before region).
SEQ_NEW=("select your REGION" "choose a USERNAME" "choose a PASSWORD" "type the same PASSWORD" "optional components" "TARGET DISK" "root \\(/\\) filesystem" "ERASE")
mk8 "$DIALOG_REG" "$DIALOG_USR" "$DIALOG_PWD" "$DIALOG_PWDC" "$DIALOG_COMP" "$DIALOG_DISK" "$DIALOG_ROOTFS" "$DIALOG_ERASE"
expect "2026-10-06 flow (region, user, password, confirm, components, disk, fs, erase) passes" 0 chk --require-prompt-sequence "${SEQ_NEW[@]}"
mk8 "$DIALOG_COMP" "$DIALOG_REG" "$DIALOG_USR" "$DIALOG_PWD" "$DIALOG_PWDC" "$DIALOG_DISK" "$DIALOG_ROOTFS" "$DIALOG_ERASE"
expect "the r199 order (components before region) fails the 2026-10-06 sequence" 1 chk --require-prompt-sequence "${SEQ_NEW[@]}"
DIALOG_BAD=$'  NCZ-OS 26.10 Cygnus | arm64 (Sky1) | build abc1234\n  lqqqqqqqqq [NCZ-OS install - WRONG-ORDER dialog tqqqqqqqqqq k\n  x body x\n  mqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqj'
mk6() { rm -rf "$T/s"; mkdir -p "$T/s"
    printf '# t=15s\n%s\n' "$1" > "$T/s/0000-0015s.txt"
    printf '# t=20s\n%s\n' "$2" > "$T/s/0001-0020s.txt"
    printf '# t=25s\n%s\n' "$3" > "$T/s/0002-0025s.txt"
    printf '# t=30s\n%s\n' "$4" > "$T/s/0003-0030s.txt"
    printf '# t=35s\n%s\n' "$5" > "$T/s/0004-0035s.txt"; }
mk6 "$DIALOG_REG" "$DIALOG_COMP" "$DIALOG_USR" "$DIALOG_HOST" "$DIALOG_DISK"
expect "operator-required 6-step sequence fails when out of order" 1 chk --require-prompt-sequence "optional components" "select your REGION" "choose a USERNAME" "name this computer" "TARGET DISK"
mk6 "$DIALOG_COMP" "$DIALOG_REG" "$DIALOG_USR" "$DIALOG_HOST" "$DIALOG_DISK"
expect "operator-required 6-step sequence fails when a prompt is missing" 1 chk --require-prompt-sequence "optional components" "select your REGION" "type the same PASSWORD" "name this computer" "TARGET DISK"
# --- boot-progress regression: 6 phases + dialog fixture in ONE captured state ---
# The operator-reported "silent boot" regression (an empty framebuffer from
# ~14 s to ~27 s on arm64 KVM) is gated by --require-boot-progress asserting
# that ALL 6 phases appear in order BEFORE the dialog. A regression that drops
# the boot-progress helper (e.g. removes the `ncz_boot_msg` calls in
# preseed.cfg's early_command) breaks the gate here at the build-host level
# rather than on real hardware.
DIALOG_TAIL=$'  [NCZ 14:22:30 +0s] Loading installer...\n  [NCZ 14:22:31 +1s] Detecting hardware...\n  [NCZ 14:22:33 +3s] Detecting storage/USB devices...\n  [NCZ 14:22:34 +4s] Starting network...\n  [NCZ 14:22:36 +6s] Preparing installer dialogs...\n  [NCZ 14:22:38 +8s] Ready: installer UI is loading...\n  NCZ-OS 26.10 Cygnus | arm64 (Sky1) | build abc1234\n  lqqqqqqqqq [NCZ-OS install - optional components tqqqqqqqqq k\n  x body x\n  mqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqj'
rm -rf "$T/s"; mkdir -p "$T/s"; printf '# t=20s\n%s\n' "$DIALOG_TAIL" > "$T/s/0000-0020s.txt"
expect "full boot-progress (6 phases) + first dialog passes" 0 chk --require-boot-progress "Loading installer" "Detecting hardware" "Detecting storage/USB devices" "Starting network" "Preparing installer dialogs" "Ready: installer UI is loading" --require-dialog "optional components"
# Negative cases for --require-boot-progress: a missing phase, an out-of-order
# phase, and a phase embedded in d-i chatter (not in the [NCZ ...] prefix).
DIALOG_BP_MISS=$'  [NCZ 14:22:30 +0s] Loading installer...\n  [NCZ 14:22:31 +1s] Detecting hardware...\n  [NCZ 14:22:33 +3s] Detecting storage/USB devices...\n  [NCZ 14:22:34 +4s] Starting network...\n  [NCZ 14:22:38 +8s] Ready: installer UI is loading...\n  lqqqqqqqqq [NCZ-OS install - optional components tqqqqqqqqq k'
rm -rf "$T/s"; mkdir -p "$T/s"; printf '# t=20s\n%s\n' "$DIALOG_BP_MISS" > "$T/s/0000-0020s.txt"
expect "boot-progress fails when one phase is missing" 1 chk --require-boot-progress "Loading installer" "Detecting hardware" "Detecting storage/USB devices" "Starting network" "Preparing installer dialogs" "Ready: installer UI is loading"
DIALOG_BP_OOO=$'  [NCZ 14:22:30 +0s] Detecting hardware...\n  [NCZ 14:22:31 +1s] Loading installer...\n  [NCZ 14:22:33 +3s] Detecting storage/USB devices...\n  [NCZ 14:22:34 +4s] Starting network...\n  [NCZ 14:22:36 +6s] Preparing installer dialogs...\n  [NCZ 14:22:38 +8s] Ready: installer UI is loading...'
rm -rf "$T/s"; mkdir -p "$T/s"; printf '# t=20s\n%s\n' "$DIALOG_BP_OOO" > "$T/s/0000-0020s.txt"
expect "boot-progress fails when phases are out of order" 1 chk --require-boot-progress "Loading installer" "Detecting hardware" "Detecting storage/USB devices" "Starting network" "Preparing installer dialogs" "Ready: installer UI is loading"
# --- source-level regression: only ONE --prompt invocation per interactive chooser ---
# The installer flow spec: "(5) machine name: ONE step showing the
# auto-generated name that the user accepts or overrides; remove the redundant
# second hostname prompt." A regression that re-invokes any chooser with
# --prompt (e.g. a duplicate early_command block that calls hostnam_sudo twice)
# is caught at this gate by counting the occurrences in preseed.cfg.
ROOT="$(cd "$HERE/.." && pwd)"
PRCFG="$ROOT/preseed/preseed.cfg"
expect_one_presource() {
    local name="$1"; local file="$2"
    local n
    # Strip line continuations (lines ending with `\`) so a chooser invocation
    # that spans multiple lines of the joined early_command counts once.
    n=$(tr -d '\n\\' < "$file" | grep -oE "/tmp/${name}\\.sh[[:space:]]+--prompt" | wc -l)
    [ "$n" = 1 ] || { echo "expected exactly 1 --prompt invocation of $name in $file, got $n" >&2; return 1; }
    return 0
}
expect "preseed.cfg invokes component-selector.sh --prompt exactly once" 0 expect_one_presource component-selector "$PRCFG"
expect "preseed.cfg invokes region-chooser.sh --prompt exactly once"   0 expect_one_presource region-chooser   "$PRCFG"
expect "preseed.cfg invokes user-chooser.sh --prompt exactly once"      0 expect_one_presource user-chooser      "$PRCFG"
# 2026-10-06 operator flow: the hostname is generated, never asked (no hostname-suggest.sh --prompt anywhere).
expect_no_presource() {
    local n
    n=$(tr -d '\n\\' < "$2" | grep -oE "/tmp/${1}\\.sh[[:space:]]+--prompt" | wc -l)
    [ "$n" = 0 ] || { echo "expected NO --prompt invocation of $1 in $2 (hostname is automatic), got $n" >&2; return 1; }
}
expect "preseed.cfg never prompts for the hostname (hostname-suggest.sh has no --prompt call)" 0 expect_no_presource hostname-suggest "$PRCFG"
# --- source-level regression: the dialog templates carry the operator's required phrases ---
expect_template_phrase() {
    local file="$1"; local phrase="$2"
    grep -qF "$phrase" "$file" 2>/dev/null || { echo "missing operator phrase '$phrase' in $file" >&2; return 1; }
    return 0
}
expect "region-chooser.sh template sets locale, country, tz, keyboard from one pick" 0 expect_template_phrase "$ROOT/preseed/region-chooser.sh" "select your REGION"
expect "user-chooser.sh template asks for username, password, password-confirm" 0 expect_template_phrase "$ROOT/preseed/user-chooser.sh" "choose a USERNAME"
expect "user-chooser.sh password prompt is present"                              0 expect_template_phrase "$ROOT/preseed/user-chooser.sh" "choose a PASSWORD for"
expect "user-chooser.sh password-confirm prompt is present"                      0 expect_template_phrase "$ROOT/preseed/user-chooser.sh" "type the same PASSWORD again"
# S2-3: the hostname is automatic -- hostname-suggest.sh must NOT carry a dialog at all
# (the retired --prompt template is deleted, so there is no "name this computer" step).
expect "hostname-suggest.sh carries no hostname dialog (S2-3: the name is automatic)" 1 expect_template_phrase "$ROOT/preseed/hostname-suggest.sh" "name this computer"
expect "disk-fs-chooser.sh template shows the disk-select prompt"                0 expect_template_phrase "$ROOT/preseed/disk-fs-chooser.sh" "select the TARGET DISK"
expect "disk-fs-chooser.sh template shows the root-fs prompt"                     0 expect_template_phrase "$ROOT/preseed/disk-fs-chooser.sh" "root (/) filesystem"
expect "disk-fs-chooser.sh template shows the erase-confirm prompt"              0 expect_template_phrase "$ROOT/preseed/disk-fs-chooser.sh" "ERASE"
# --- source-level regression: the disk-select prompt is NOT skipped on a single candidate ---
# The installer flow spec: "if exactly one non-media candidate disk, show it
# plainly in the filesystem/confirmation step (single explicit confirm is fine);
# if more than one, the user must choose." A regression that re-introduces an
# `NDISK==1` auto-pick branch is caught here by scanning for the forbidden
# pattern in disk-fs-chooser.sh.
expect_no_silent_autopick() {
    local file="$1"
    # Strip comments and heredoc bodies first; we are looking for an executable
    # branch like `elif [ NDISK -eq 1 ]`, `if [ "$NDISK" -eq 1 ]`, or
    # `[ NDISK == 1 ]`. Comment text mentioning "the old NDISK==1 branch" is fine.
    awk '
        /^[[:space:]]*#/ { next }
        /^<<-?AUNCH\/.*TPL/,/^[[:space:]]*AUNCH\/.*TPL/ { next }
        /^<<-?TPL/,/^TPL$/ { next }
        { print }
    ' "$file" | grep -nE 'NDISK[^A-Za-z0-9_]+-eq[[:space:]]*1|NDISK[^A-Za-z0-9_]+==[[:space:]]*1' >/dev/null 2>&1 \
        && { echo "$file: a silent auto-pick on NDISK==1 was re-introduced (operator safety requirement)" >&2; return 1; }
    return 0
}
expect "disk-fs-chooser.sh never auto-picks on a single candidate" 0 expect_no_silent_autopick "$ROOT/preseed/disk-fs-chooser.sh"
# --- source-level regression: boot-progress helper is sourced + 6 ncz_boot_msg calls are present ---
expect_boot_progress() {
    local cfg="$1"
    grep -qE '\. /ncz/boot-progress\.sh|ncz_boot_msg' "$cfg" >/dev/null 2>&1 || { echo "$cfg: boot-progress helper is not sourced / no ncz_boot_msg call" >&2; return 1; }
    local n
    n=$(grep -cE 'ncz_boot_msg[[:space:]]+[a-z]+[[:space:]]+"' "$cfg" 2>/dev/null || echo 0)
    [ "$n" = 6 ] || { echo "$cfg: expected 6 ncz_boot_msg calls (one per phase), got $n" >&2; return 1; }
    return 0
}
expect "preseed.cfg sources boot-progress + calls ncz_boot_msg exactly 6 times" 0 expect_boot_progress "$PRCFG"
# --- source-level regression: boot-progress messages go to tty1+tty3+console (operator's "verify that is not invisible" requirement) ---
# The prior orchestrator handoff called out a defect where the previous worker
# put boot messages only on VT4 (a non-displayed diagnostic console). The
# fix here routes the messages to /dev/tty1 (the operator's framebuffer),
# /dev/tty3 (the Alt-F3 diagnostic console), and /dev/console (the kernel's
# preferred console that the installer's serial capture also reads). A
# regression that drops any one of those TTYs fails this gate.
expect_boot_progress_ttys() {
    local f="$1"
    # Find the printf loop (must iterate over multiple /dev/ttyN + /dev/console targets)
    grep -qE 'for[[:space:]]+_V[[:space:]]+in[[:space:]]+/dev/tty1[[:space:]]+/dev/tty3[[:space:]]+/dev/console' "$f" \
        || { echo "$f: boot-progress messages are not routed to /dev/tty1 + /dev/tty3 + /dev/console (operator 'invisible boot' regression)" >&2; return 1; }
    return 0
}
expect "boot-progress.sh writes to /dev/tty1 + /dev/tty3 + /dev/console (operator's 'invisible boot' regression guard)" 0 expect_boot_progress_ttys "$ROOT/preseed/boot-progress.sh"
# --- source-level regression: the ncz_rev banner is one-shot, on tty1+tty3+console ---
# Install testing 2026-09-30 ("the earlier commit put messages only on VT4,
# verify that is not invisible to the user"). The "==== NCZ-OS INSTALLER ${rev}
# ====" banner used to run in a 2-second heartbeat loop from early_command. The
# historical version wrote it ONLY to /dev/tty4 -- a non-displayed console.
# A regression that returns to the VT4-only routing makes the banner
# invisible to the operator and breaks the install-grep "NCZ-OS INSTALLER"
# marker on serial-only captures (at least 4 KVM install gates rely on that
# marker being in $ILOG). It MUST iterate over at least /dev/tty1 (operator
# framebuffer), /dev/tty3 (Alt-F3 diag console) and /dev/console (serial
# capture); a bare `for V in /dev/tty4` fails.
# 2026-10-12 (unattended amd64 installer defect): the loop was ALSO a smear bug: it
# kept painting the banner over the running newt dialogs for 120 s (the
# operator's "[NCZ hh:mm:ss] ==== NCZ-OS INSTALLER unknown ====" every ~2 s).
# The banner is now a ONE-SHOT print before newt starts: no sleep/while on its
# line, and exactly one banner line in the file.
expect_rev_banner_not_vt4_only() {
    local f="$1"
    # The "==== NCZ-OS INSTALLER ${rev} ====" banner must be present.
    # The printf format string puts the rev token after the literal
    # "NCZ-OS INSTALLER " (with intervening %s / ${NCZREV:-unknown}), so
    # match on the literal alone -- the for-targets and the literal token
    # are both required separately below.
    grep -qE 'NCZ-OS INSTALLER' "$f" \
        || { echo "$f: the NCZ-OS INSTALLER banner is missing entirely" >&2; return 1; }
    # Find the banner's for-loop line. The banner is the only thing in
    # preseed.cfg that contains the literal "NCZ-OS INSTALLER", so the
    # first hit is the banner's own line. Strip the line-number prefix.
    local banner_line
    banner_line=$(grep -nE 'NCZ-OS INSTALLER' "$f" | head -1 | sed 's/^[0-9]*://')
    # require /dev/tty1, /dev/tty3 and /dev/console all appear on the banner line
    local miss=""
    case "$banner_line" in
        */dev/tty1*) : ;;
        *) miss="$miss /dev/tty1" ;;
    esac
    case "$banner_line" in
        */dev/tty3*) : ;;
        *) miss="$miss /dev/tty3" ;;
    esac
    case "$banner_line" in
        */dev/console*) : ;;
        *) miss="$miss /dev/console" ;;
    esac
    [ -z "$miss" ] || { echo "$f: the NCZ-OS INSTALLER banner is missing target(s):$miss (operator's 'invisible boot' regression -- the prior commit put the banner on /dev/tty4 only)" >&2; return 1; }
    # negative check: the VT4-only defect must not return. The banner's
    # for-loop must not iterate ONLY /dev/tty4. (A banner that iterates
    # /dev/tty4 + any of tty1/tty3/console is allowed -- the operator's
    # complaint was VT4-only, not "VT4 must be excluded".)
    local targets
    targets=$(printf '%s\n' "$banner_line" | sed -nE 's/.*for[[:space:]]+V[[:space:]]+in[[:space:]]+([^;]+);.*/\1/p' | head -1)
    case "$targets" in
        "/dev/tty4"|"/dev/tty4 ") echo "$f: the NCZ-OS INSTALLER banner for-loop iterates ONLY /dev/tty4 (operator's 'invisible boot' regression, 2026-09-30)" >&2; return 1 ;;
    esac
    # banner-ONCE (2026-10-12): a repeating loop (sleep/while on the
    # banner line, or more than one banner line) is the smear regression.
    case "$banner_line" in
        *sleep*|*while*|*"&"*) echo "$f: the NCZ-OS INSTALLER banner repeats / is backgrounded -- it must print ONCE at boot and never over the newt UI (banner smear regression)" >&2; return 1 ;;
    esac
    local n
    n=$(grep -cE 'NCZ-OS INSTALLER' "$f")
    [ "$n" = 1 ] || { echo "$f: expected exactly ONE NCZ-OS INSTALLER banner line, found $n (smear regression)" >&2; return 1; }
    return 0
}
expect "preseed.cfg NCZ-OS INSTALLER banner is visible on /dev/tty1 + /dev/tty3 + /dev/console (NOT VT4-only, operator's invisible-boot regression guard)" 0 expect_rev_banner_not_vt4_only "$ROOT/preseed/preseed.cfg"
# --- source-level regression: the password-confirm mismatch leaves the password UNSET (operator UX requirement) ---
# Design rule: "(4) default password with confirm (2x)". The confirm
# mismatch is logged as a WARNING and the password is left UNSET (the operator
# can set one from the live system). A regression that silently accepts a
# mismatched confirm violates this contract.
expect_password_confirm_mismatch() {
    local f="$1"
    grep -qF 'do not match' "$f" || { echo "$f: missing the 'password and confirm do not match' WARNING" >&2; return 1; }
    # The mismatch branch must clear CHOSEN_PASS (the password is left UNSET)
    awk '
        /do not match/ { in_branch=1; next }
        in_branch && /CHOSEN_PASS=""/ { ok=1; exit }
        in_branch && /^fi$/           { in_branch=0 }
        END { exit !ok }
    ' "$f" >/dev/null 2>&1 || { echo "$f: the password-confirm mismatch branch does not clear CHOSEN_PASS (operator UX regression)" >&2; return 1; }
    return 0
}
expect "user-chooser.sh leaves password UNSET on a confirm mismatch (operator UX guard)" 0 expect_password_confirm_mismatch "$ROOT/preseed/user-chooser.sh"
# --- source-level regression: disk-fs-chooser.sh verifies the partman pins are byte-identical before wiping ---
# Safety rule: "keep partman pin byte-compare". The chooser
# sets partman-auto/disk + partman-auto/expert_recipe + partman-auto/choose_recipe
# via db_set, then db_get + exact-string compare the pinned recipe to the one
# WE set. A regression that drops the byte-identical compare would let a
# stale/failed debconf pin pass and wipe a disk that was NOT the operator's
# choice.
expect_partman_pin_byte_compare() {
    local f="$1"
    # The runtime equality assertion must be present and uncommented (a
    # regression that drops or comments out the `[ "$_pinned_recipe" = "$RECIPE" ]`
    # would let a stale pin pass and wipe a disk that was NOT the operator's
    # choice). grep for the literal line on its own (column-0 anchor).
    grep -nE '^[[:space:]]*\[[[:space:]]+"\$_pinned_recipe"[[:space:]]+=[[:space:]]+"\$RECIPE"[[:space:]]+\]' "$f" >/dev/null 2>&1 \
        || { echo "$f: missing the runtime [ \"\$_pinned_recipe\" = \"\$RECIPE\" ] equality assertion (partman pin safety regression -- the literal token 'byte-identical' in a comment is NOT enough; the actual comparison must execute)" >&2; return 1; }
    # The exact equality error path (the abort must be triggered if the pin
    # does not match -- a regression that only logs the mismatch is also a defect).
    grep -qF 'pinned expert_recipe is not byte-identical' "$f" || { echo "$f: missing the 'pinned expert_recipe is not byte-identical' abort path" >&2; return 1; }
    # The root-stanza-specific filesystem check (catches the old 'plain
    # substring test' defect where ext4 would falsely pass against the rescue
    # partition's filesystem{ ext4 } token)
    grep -qF 'mountpoint{ / }' "$f" || { echo "$f: missing the root-stanza filesystem check" >&2; return 1; }
    # The disk pin
    grep -qF 'partman-auto/disk did not pin' "$f" || { echo "$f: missing the partman-auto/disk pin verification" >&2; return 1; }
    return 0
}
expect "disk-fs-chooser.sh verifies partman pins are byte-identical before wiping (operator safety guard)" 0 expect_partman_pin_byte_compare "$ROOT/preseed/disk-fs-chooser.sh"
# --- source-level regression: disk-fs-chooser.sh refuses a media-disk target (safety rule) ---
# Safety rule: "keep ... media-disk protection". The install
# media (Ventoy / dm / md / loop backing) must never be a candidate. The
# guard resolves a candidate's parent via parent_disk_of_dev and rejects
# any backing that does not resolve to a list-devices disk candidate.
expect_media_disk_protection() {
    local f="$1"
    # The parent_disk_of_dev function MUST be DEFINED (so it can resolve a
    # candidate's parent and reject Ventoy / dm / md / loop backing).
    grep -qF 'parent_disk_of_dev()' "$f" || { echo "$f: parent_disk_of_dev() is not defined (operator safety regression)" >&2; return 1; }
    # The parent_disk_of_dev function MUST be CALLED for every candidate
    # (so a candidate whose parent does not resolve to a list-devices disk is
    # rejected). Look for the call-site pattern.
    grep -qE 'parent_disk_of_dev[[:space:]]+"?\$_?[A-Za-z0-9_]+' "$f" || { echo "$f: parent_disk_of_dev is not invoked on any candidate (operator safety regression)" >&2; return 1; }
    # The list-devices disk canonicalisation (the parent_disk_of_dev call
    # must resolve to one of these candidates).
    grep -qE 'list-devices[[:space:]]+disk' "$f" || { echo "$f: missing the list-devices disk canonicalisation (operator safety regression)" >&2; return 1; }
    return 0
}
expect "disk-fs-chooser.sh enforces media-disk protection via parent_disk_of_dev + list-devices disk (operator safety guard)" 0 expect_media_disk_protection "$ROOT/preseed/disk-fs-chooser.sh"
# --- source-level regression: the ncz_disk= / ncz_fs= cmdline overrides still work for unattended use ---
# Safety rule: "ncz_disk=/ncz_fs= overrides stay for unattended
# use". The override MUST canonicalize to one of the list-devices disk
# whole-disk candidates (a misspelled / partition / install-medium value is
# rejected).
expect_cmdline_overrides() {
    local f="$1"
    grep -qF 'ncz_disk=' "$f" || { echo "$f: missing the ncz_disk= cmdline override (operator unattended-use regression)" >&2; return 1; }
    grep -qF 'ncz_fs='   "$f" || { echo "$f: missing the ncz_fs= cmdline override (operator unattended-use regression)"   >&2; return 1; }
    grep -qF 'not one of the whole-disk candidates' "$f" || { echo "$f: missing the canonicalisation rejection of the ncz_disk= override" >&2; return 1; }
    return 0
}
expect "disk-fs-chooser.sh honours ncz_disk= / ncz_fs= cmdline overrides with canonicalisation (unattended-use regression guard)" 0 expect_cmdline_overrides "$ROOT/preseed/disk-fs-chooser.sh"
# --- source-level regression: the required 6-step sequence is the ONLY chooser order in preseed.cfg ---
# A regression that re-orders the chooser invocations in preseed.cfg's
# partman/early_command (e.g. swaps hostname with disk) violates the
# installer flow spec. This test pins the EXACT order by joining the
# line-continued early_command and asserting the chooser invocations appear
# in the required sequence.
expect_orchestrator_order() {
    local cfg="$1"
    # Extract ONLY the partman/early_command block (the required
    # order check is for the chooser sequence IN partman/early_command, not
    # for every mention of those names anywhere in the file -- disk-fs-chooser.sh
    # appears earlier as a variable name in the debootstrap-stub guard).
    local payload
    payload=$(awk '
            /d-i partman\/early_command string[[:space:]]*\\/    { in_block=1; print; next }
            in_block && /^[[:space:]]*\\/                       { print; next }
            in_block && /^d-i partman\/early_command seen true/  { print; in_block=0; next }
            in_block                                              { print }
        ' "$cfg")
    [ -n "$payload" ] || { echo "$cfg: could not extract partman/early_command block" >&2; return 1; }
    # Join line-continued invocations
    local joined
    joined=$(printf '%s' "$payload" | tr -d '\n\\')
    # Order (2026-10-06): region -> user -> component -> disk. The
    # password + password-confirm are inside user-chooser.sh; the hostname is
    # automatic (hostname-suggest.sh re-applied WITHOUT --prompt).
    local a b c d e
    a=$(printf '%s' "$joined" | grep -boE '/tmp/region-chooser\.sh[[:space:]]+--prompt'   | head -1 | cut -d: -f1)
    b=$(printf '%s' "$joined" | grep -boE '/tmp/user-chooser\.sh[[:space:]]+--prompt'      | head -1 | cut -d: -f1)
    c=$(printf '%s' "$joined" | grep -boE '/tmp/hostname-suggest\.sh[[:space:]]+>>'         | head -1 | cut -d: -f1)
    d=$(printf '%s' "$joined" | grep -boE '/tmp/component-selector\.sh[[:space:]]+--prompt' | head -1 | cut -d: -f1)
    # For disk-fs-chooser.sh we must skip the early guard references (the
    # `if ! [ -f /cdrom/.../disk-fs-chooser.sh ]` tests) and pick the
    # actual invocation, which uses the variable form `sh "$D/disk-fs-chooser.sh"`.
    e=$(printf '%s' "$joined" | grep -boE 'sh[[:space:]]+"\$D/disk-fs-chooser\.sh"' | head -1 | cut -d: -f1)
    [ -n "$a" ] && [ -n "$b" ] && [ -n "$c" ] && [ -n "$d" ] && [ -n "$e" ] || { echo "$cfg: one of the 5 chooser invocations is missing from partman/early_command" >&2; return 1; }
    # Order check (each must come strictly AFTER the previous)
    [ "$a" -lt "$b" ] && [ "$b" -lt "$c" ] && [ "$c" -lt "$d" ] && [ "$d" -lt "$e" ] \
        || { echo "$cfg: chooser invocations are not in the operator-required order (region -> user -> hostname(auto) -> component -> disk)" >&2; return 1; }
    return 0
}
expect "preseed.cfg invokes region->user->hostname(auto)->component->disk in the operator-required order (partman/early_command)" 0 expect_orchestrator_order "$PRCFG"
# --- source-level regression: the 6 choosers each set a debconf question with seen=true on the required d-i questions ---
# The installer flow spec: the choosers REPLACE d-i's native locale/
# country/keymap/user/password/hostname questions. If a chooser stops
# marking its d-i question seen=true, d-i will raise the native prompt
# AGAIN after the chooser, blowing the single-prompt-per-step contract.
expect_seen_true() {
    local file="$1"; local dquestion="$2"; local n
    # Count db_fset <dquestion> seen true (with optional quoting)
    n=$(grep -cE "db_fset[[:space:]]+${dquestion}[[:space:]]+seen[[:space:]]+true" "$file" 2>/dev/null || echo 0)
    [ "$n" -ge 1 ] || { echo "$file: db_fset ${dquestion} seen true is missing (d-i would re-prompt the operator after the chooser)" >&2; return 1; }
    return 0
}
expect "region-chooser.sh marks debian-installer/locale seen true (d-i does not re-prompt)"  0 expect_seen_true "$ROOT/preseed/region-chooser.sh" "debian-installer/locale"
expect "region-chooser.sh marks keyboard-configuration/xkb-keymap seen true"               0 expect_seen_true "$ROOT/preseed/region-chooser.sh" "keyboard-configuration/xkb-keymap"
expect "region-chooser.sh marks time/zone seen true"                                        0 expect_seen_true "$ROOT/preseed/region-chooser.sh" "time/zone"
expect "user-chooser.sh marks passwd/username seen true"                                     0 expect_seen_true "$ROOT/preseed/user-chooser.sh"  "passwd/username"
expect "user-chooser.sh marks passwd/user-password seen true"                                0 expect_seen_true "$ROOT/preseed/user-chooser.sh"  "passwd/user-password"
expect "user-chooser.sh marks passwd/user-password-again seen true"                          0 expect_seen_true "$ROOT/preseed/user-chooser.sh"  "passwd/user-password-again"
expect "hostname-suggest.sh marks netcfg/get_hostname seen true"                             0 expect_seen_true "$ROOT/preseed/hostname-suggest.sh" "netcfg/get_hostname"
expect "disk-fs-chooser.sh marks partman-auto/disk seen true"                                0 expect_seen_true "$ROOT/preseed/disk-fs-chooser.sh" "partman-auto/disk"
expect "disk-fs-chooser.sh marks partman-auto/expert_recipe seen true"                       0 expect_seen_true "$ROOT/preseed/disk-fs-chooser.sh" "partman-auto/expert_recipe"
rm -rf "$T/s"; mkdir "$T/s";                                  expect "empty capture fails"                     1 chk
# templates that d-i draws with newt must be ASCII: the em dash rendered "<ERR>" and truncated the title on hardware
ROOT="$(cd "$HERE/.." && pwd)"
tpl_ascii() { local f; for f in "$ROOT"/preseed/component-selector.sh "$ROOT"/preseed/disk-fs-chooser.sh "$ROOT"/preseed/hostname-suggest.sh "$ROOT"/preseed/region-chooser.sh "$ROOT"/preseed/user-chooser.sh "$ROOT"/preseed/locale-keyboard-chooser.sh "$ROOT"/preseed/late.sh; do
    [ -f "$f" ] || continue
    awk -v f="$f" '
        !r && match($0, /<<-?[\047"]?[A-Z]*TPL/) { w=substr($0, RSTART, RLENGTH); gsub(/[<\047"-]/, "", w); r=1; next }
        r && $0 == w { r=0; next }
        (r || /LONG=/) && /[^\001-\177]/ { print f ": non-ASCII in template text: " $0; bad=1 }
        END { exit bad }' "$f" || return 1
done; }
expect "d-i template sources are ASCII" 0 tpl_ascii
printf 'Template: x/y\nDescription: NCZ install \xe2\x80\x94 pick\n' > "$T/bad.sh"
tpl_bad() { awk '/^Description/ { if ($0 ~ /[^\001-\177]/) bad=1 } END{exit !bad}' "$T/bad.sh"; }
expect "a non-ASCII template line is detected" 0 tpl_bad
# --- adversarial: each interactive chooser exposes the EXPECTED template TYPE ---
# A regression that re-registers an interactive chooser as `Type: note` (which
# auto-dismisses without operator input) would skip the operator's prompt for
# that step. Pin the type so a regression is caught at this gate. The 5
# interactive choosers each expose at least one interactive
# template; the type MUST be one of: select (disk/fs/region/components),
# string (username/hostname), password (password/password-confirm), boolean
# (erase-confirm). Note/title/error/text are FORBIDDEN for the interactive
# step (note auto-dismisses; text is non-interactive; error aborts but is
# non-interactive).
expect_chooser_type() {
    local file="$1"; local interactive_type="$2"
    # Pull the template TYPE lines out of any heredoc that defines a Template:
    # of the form ncz/* or nclawzero/*. Skip the late.sh 'remove-media' note
    # (post-install, not part of the 6-step interactive flow).
    awk -v want="$interactive_type" -v f="$file" '
        BEGIN { found=0; bad=0 }
        /<<-?[\047"]?[A-Z]*TPL/ { in_tpl=1; next }
        in_tpl && /^[[:space:]]*[A-Z]*TPL[[:space:]]*$/ { in_tpl=0; next }
        in_tpl && /^Type:[[:space:]]+/ {
            t = substr($0, index($0, ":")+1)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", t)
            # text/template types are non-interactive (post-install progress
            # bars and the bootloader banner). Only `note` is FORBIDDEN in
            # an INTERACTIVE chooser (a note template auto-dismisses without
            # operator input; text is fine for db_progress progress bars).
            if (t == "select" || t == "string" || t == "password" || t == "boolean" || t == "multiselect") {
                if (t == want) { found=1 }
            } else if (t == "note") {
                # A `note` template in an INTERACTIVE chooser is the regression
                # we are guarding against -- the operator prompt would vanish.
                bad=1
                print f ": an interactive template was registered as Type: " t " (operator would never be asked)" > "/dev/stderr"
            }
        }
        END { if (bad) exit 2; exit !found }
    ' "$file"
}
expect "component-selector.sh exposes a Type: multiselect template (the prompt right before the disk dialogs)" 0 expect_chooser_type "$ROOT/preseed/component-selector.sh" multiselect
expect "region-chooser.sh exposes a Type: select template (the operator's first interactive prompt)"   0 expect_chooser_type "$ROOT/preseed/region-chooser.sh"     select
expect "user-chooser.sh exposes a Type: string template (username is the second interactive prompt)"     0 expect_chooser_type "$ROOT/preseed/user-chooser.sh"      string
expect "user-chooser.sh exposes a Type: password template (the password + confirm step)"               0 expect_chooser_type "$ROOT/preseed/user-chooser.sh"      password
# S2-3: hostname-suggest.sh registers NO cdebconf template at all -- the retired
# --prompt block (which held the Type: string template) was deleted, and the helper
# now only db_set/db_fset the d-i-native netcfg questions.
expect_no_hostname_template() {
    local f="$1"
    grep -qE '^Type:[[:space:]]*string' "$f" 2>/dev/null \
        && { echo "$f: carries a Type: string template (S2-3: the hostname dialog was removed)" >&2; return 1; }
    grep -qE 'debconf-loadtemplate' "$f" 2>/dev/null \
        && { echo "$f: still loads a template (S2-3: no dialog may exist)" >&2; return 1; }
    return 0
}
expect "hostname-suggest.sh registers no template (S2-3: hostname automatic, dialog removed)" 0 expect_no_hostname_template "$ROOT/preseed/hostname-suggest.sh"
expect "disk-fs-chooser.sh exposes a Type: select template (the sixth interactive prompt, target disk)" 0 expect_chooser_type "$ROOT/preseed/disk-fs-chooser.sh"   select
expect "disk-fs-chooser.sh exposes a Type: boolean template (the sixth-step erase confirmation)"       0 expect_chooser_type "$ROOT/preseed/disk-fs-chooser.sh"   boolean
# --- adversarial: user-chooser.sh has EXACTLY 3 interactive templates (username + password + password-confirm) ---
# A regression that registers password-confirm as something other than a
# Type: password (e.g. a Type: string) would let the confirm mismatch branch
# be skipped (password retyped without `*` masking on screen) and would let
# the operator's typo escape. Pin the count and the types.
expect_user_chooser_3_templates() {
    local f="$1"
    # Count the Type: lines that are select/string/password/boolean (interactive)
    local n
    n=$(grep -cE '^Type:[[:space:]]+(select|string|password|boolean)$' "$f" 2>/dev/null || echo 0)
    [ "$n" = 3 ] || { echo "$f: expected exactly 3 interactive templates in user-chooser.sh (username, password, password-confirm), got $n" >&2; return 1; }
    # The three MUST be: string (username), password (password), password (password-confirm)
    grep -qE '^Type:[[:space:]]+string$'   "$f" || { echo "$f: user-chooser.sh is missing the Type: string template (username)" >&2; return 1; }
    local npw
    npw=$(grep -cE '^Type:[[:space:]]+password$' "$f" 2>/dev/null || echo 0)
    [ "$npw" = 2 ] || { echo "$f: expected 2 Type: password templates (password + password-confirm), got $npw" >&2; return 1; }
    return 0
}
expect "user-chooser.sh has exactly 3 interactive templates (string username + 2x password)" 0 expect_user_chooser_3_templates "$ROOT/preseed/user-chooser.sh"
# --- adversarial: no chooser calls db_go which would silently advance past a step ---
# db_go is d-i's "advance past the current question without operator input"
# helper. The installer flow spec is that every chooser step MUST require
# the operator's input (db_input + db_go is the ONLY safe combination; raw
# db_go without a prior db_input is the dangerous pattern).
expect_no_unguarded_db_go() {
    local f="$1"
    # The pattern we forbid is a bare `db_go` line OUTSIDE an `if db_input` block.
    # We accept `db_go` only as the conditional-branch body (preceded by
    # `if db_input ... ; then ... db_go`). A bare `db_go` on its own line at
    # column 0 is the regression.
    grep -nE '^[[:space:]]*db_go[[:space:]]*$' "$f" 2>/dev/null \
        && { echo "$f: bare db_go at column 0 (would silently advance past a step without operator input)" >&2; return 1; }
    return 0
}
expect "component-selector.sh has no bare db_go (each step must require operator input)" 0 expect_no_unguarded_db_go "$ROOT/preseed/component-selector.sh"
expect "region-chooser.sh has no bare db_go"   0 expect_no_unguarded_db_go "$ROOT/preseed/region-chooser.sh"
expect "user-chooser.sh has no bare db_go"      0 expect_no_unguarded_db_go "$ROOT/preseed/user-chooser.sh"
expect "hostname-suggest.sh has no bare db_go"  0 expect_no_unguarded_db_go "$ROOT/preseed/hostname-suggest.sh"
expect "disk-fs-chooser.sh has no bare db_go"   0 expect_no_unguarded_db_go "$ROOT/preseed/disk-fs-chooser.sh"
# --- adversarial: the partman/early_command block in preseed.cfg does NOT re-invoke hostname-suggest ---
# The installer flow spec: "(5) machine name: ONE step showing the
# auto-generated name". A regression that adds a SECOND /tmp/hostname-suggest.sh
# --prompt invocation outside partman/early_command (e.g. in another
# d-i early_command or in the late_command) would re-show the hostname dialog
# after the operator already answered it. The expect_one_presource check above
# catches ALL --prompt invocations, but this check verifies the SINGLE one is
# inside partman/early_command (so the operator's answer cannot be silently
# overwritten by a re-prompt in another hook).
expect_hostname_only_in_partman_early_command() {
    local cfg="$1"
    # Extract ONLY the partman/early_command block.
    local payload
    payload=$(awk '
            /d-i partman\/early_command string[[:space:]]*\\/    { in_block=1; print; next }
            in_block && /^[[:space:]]*\\/                       { print; next }
            in_block && /^d-i partman\/early_command seen true/  { print; in_block=0; next }
            in_block                                              { print }
        ' "$cfg")
    # The orchestrator's hostname invocation MUST be inside this block (it is the
    # one allowed invocation; expect_one_presource already pinned the global count
    # to 1, so this is just the location check).
    printf '%s' "$payload" | tr -d '\n\\' | grep >/dev/null -E '/tmp/hostname-suggest\.sh[[:space:]]+>>' \
        || { echo "$cfg: hostname-suggest.sh is not re-applied inside partman/early_command" >&2; return 1; }
    printf '%s' "$payload" | tr -d '\n\\' | grep >/dev/null -E '/tmp/hostname-suggest\.sh[[:space:]]+--prompt' \
        && { echo "$cfg: partman/early_command still PROMPTS for the hostname (operator 2026-10-06: hostname automatic)" >&2; return 1; }
    return 0
}
expect "hostname-suggest.sh is re-applied in partman/early_command without a dialog (hostname automatic)" 0 expect_hostname_only_in_partman_early_command "$PRCFG"
# --- adversarial: the disk-fs-chooser ERASE confirmation names the actual chosen disk (not a placeholder) ---
# A regression that registered the ERASE confirm template with the literal
# text "ERASE ${DISK}" without expanding ${CHOSEN_DISK} would show the same
# template name regardless of the operator's disk choice -- making the
# confirm dialog look like it had already been answered. Pin the expansion.
expect_erase_names_chosen_disk() {
    local f="$1"
    # The Description: line of the confirm-erase template must include the
    # chosen-disk interpolation (${CHOSEN_DISK}) and the word ERASE.
    awk '
        /<<-?[\047"]?[A-Z]*TPL/ { in_tpl=1; next }
        in_tpl && /^[[:space:]]*[A-Z]*TPL[[:space:]]*$/ { in_tpl=0; next }
        in_tpl && /^Template:[[:space:]]+ncz\/confirm-erase/ { in_erase=1; next }
        in_erase && /^Description:[[:space:]]+/ {
            desc = substr($0, index($0, ":")+1)
            if (desc ~ /ERASE/ && desc ~ /\$\{?CHOSEN_DISK\}?/) { ok=1; exit }
            in_erase=0
        }
        END { exit !ok }
    ' "$f" >/dev/null 2>&1 \
        || { echo "$f: confirm-erase template does not interpolate \${CHOSEN_DISK} (operator would not see which disk is about to be erased)" >&2; return 1; }
    return 0
}
expect "disk-fs-chooser.sh ERASE confirmation names \${CHOSEN_DISK} (operator-safety guard against a templated placeholder)" 0 expect_erase_names_chosen_disk "$ROOT/preseed/disk-fs-chooser.sh"
# --- adversarial: the filesystem step is NOT silently skipped (the earlier commit removed it) ---
# The installer flow spec (2026-09-30): "(6) filesystem" is one of the
# EXACTLY 6 operator-visible steps, and "never auto-erase silently" is the
# hard rule. A regression that comments out either `db_input critical ncz/root-fs`
# or `db_input critical ncz/confirm-erase` would silently skip the operator's
# filesystem pick (or auto-confirm the wipe with the template's Default:false
# still false -- a worse half-state). Pin all three disk-stage db_input calls
# as present + uncommented. We grep for the LITERAL token on its own line
# (not the word inside a comment); the regex anchors match an uncommented line.
expect_disk_db_inputs_present() {
    local f="$1"
    local missing=0
    for tok in 'db_input critical ncz/target-disk' 'db_input critical ncz/root-fs' 'db_input critical ncz/confirm-erase'; do
        if ! grep -nE "^[[:space:]]*${tok}\b" "$f" >/dev/null 2>&1 ; then
            echo "$f: missing the operator-visible interactive call '${tok}' (filesystem/erase step would be silently auto-dismissed)" >&2
            missing=1
        fi
    done
    return $missing
}
expect "disk-fs-chooser.sh prompts for target disk, root fs AND erase confirmation (no auto-erase regression)" 0 expect_disk_db_inputs_present "$ROOT/preseed/disk-fs-chooser.sh"
# --- adversarial: the disk-stage prompts come in the required order ---
# The orchestrator's filesystem step (step 6) is THREE prompts in a fixed
# order: target disk -> root filesystem -> erase confirmation. A regression
# that reorders them (e.g. asks for erase-confirm before root-fs, so the
# operator could confirm an erasure against the WRONG fs pick) is caught
# here. The order is operator-required because the root-fs answer affects
# the expert_recipe and partman needs the disk pin before the wipe.
expect_disk_db_input_order() {
    local f="$1"
    local t_disk t_fs t_erase n_disk n_fs n_erase
    # Capture every db_input critical ncz/<key> line (not just head -1); the
    # orchestrator MUST invoke each disk-stage template exactly once, and any
    # duplicate or out-of-order call breaks the operator-required sequence.
    t_disk=$(  grep -nE '^[[:space:]]*db_input critical ncz/target-disk'   "$f" | head -1 | cut -d: -f1)
    t_fs=$(    grep -nE '^[[:space:]]*db_input critical ncz/root-fs'      "$f" | head -1 | cut -d: -f1)
    t_erase=$( grep -nE '^[[:space:]]*db_input critical ncz/confirm-erase' "$f" | head -1 | cut -d: -f1)
    n_disk=$(  grep -cE '^[[:space:]]*db_input critical ncz/target-disk'   "$f")
    n_fs=$(    grep -cE '^[[:space:]]*db_input critical ncz/root-fs'      "$f")
    n_erase=$( grep -cE '^[[:space:]]*db_input critical ncz/confirm-erase' "$f")
    [ -n "$t_disk" ] && [ -n "$t_fs" ] && [ -n "$t_erase" ] || { echo "$f: disk-stage db_input line numbers missing" >&2; return 1; }
    [ "$n_disk"  = 1 ] && [ "$n_fs" = 1 ] && [ "$n_erase" = 1 ] \
        || { echo "$f: each disk-stage db_input must be called exactly once (target-disk=$n_disk, root-fs=$n_fs, confirm-erase=$n_erase)" >&2; return 1; }
    [ "$t_disk" -lt "$t_fs" ] && [ "$t_fs" -lt "$t_erase" ] \
        || { echo "$f: disk-stage db_input calls are NOT in the required order (target-disk < root-fs < confirm-erase)" >&2; return 1; }
    return 0
}
expect "disk-fs-chooser.sh shows the 3 disk-stage prompts in order (target-disk < root-fs < confirm-erase)" 0 expect_disk_db_input_order "$ROOT/preseed/disk-fs-chooser.sh"
# --- adversarial: the confirm-erase template MUST default to false (never auto-erase) ---
# Safety rule: "never auto-erase silently". The confirm-erase
# template's Default: line MUST be false (so the prompt opens with No selected
# and the operator must explicitly move to Yes to confirm the wipe). A regression
# that flips Default: to true (or removes the Default line) makes the dialog
# open with Yes selected -- an operator who hits Enter thinking "let me read
# this" would silently confirm the wipe. Pin the literal `Default: false` line
# inside the confirm-erase template body (not anywhere else in the file).
expect_confirm_erase_default_false() {
    local f="$1"
    awk -v f="$f" '
        /<<-?[\047"]?[A-Z]*TPL/ { in_tpl=1; next }
        in_tpl && /^[[:space:]]*[A-Z]*TPL[[:space:]]*$/ { in_tpl=0; next }
        in_tpl && /^Template:[[:space:]]+ncz\/confirm-erase/ { in_erase=1; next }
        in_erase && /^Default:[[:space:]]+false/ { ok=1; in_erase=0; next }
        in_erase && /^Default:/ { bad=1; print f ": confirm-erase template Default is NOT false (operator would auto-confirm the wipe): " $0 > "/dev/stderr"; exit }
        in_erase && /^Template:/ { in_erase=0; next }
        END { exit !(ok && !bad) }
    ' "$f" || { echo "$f: confirm-erase template is missing 'Default: false' (operator would auto-confirm the wipe by pressing Enter)" >&2; return 1; }
    return 0
}
expect "disk-fs-chooser.sh confirm-erase template defaults to false (never auto-erase)" 0 expect_confirm_erase_default_false "$ROOT/preseed/disk-fs-chooser.sh"
# --- adversarial: the confirm-erase answer is forced to false before db_input ---
# The defense in depth: even if a regression flips the template Default to
# true, db_set ncz/confirm-erase false forces the current answer to false
# right before db_input, so the operator sees No selected. Pin this so a
# regression that drops the db_set line cannot make the operator auto-erase.
expect_confirm_erase_force_false() {
    local f="$1"
    local t_dbset t_dbinput
    t_dbset=$(  grep -nE '^[[:space:]]*db_set[[:space:]]+ncz/confirm-erase[[:space:]]+false' "$f" | head -1 | cut -d: -f1)
    t_dbinput=$(grep -nE '^[[:space:]]*db_input critical ncz/confirm-erase' "$f" | head -1 | cut -d: -f1)
    [ -n "$t_dbset" ] || { echo "$f: missing 'db_set ncz/confirm-erase false' (defence in depth against an auto-erase regression)" >&2; return 1; }
    [ -n "$t_dbinput" ] || { echo "$f: missing 'db_input critical ncz/confirm-erase' (the gate the db_set must precede)" >&2; return 1; }
    [ "$t_dbset" -lt "$t_dbinput" ] \
        || { echo "$f: 'db_set ncz/confirm-erase false' (line $t_dbset) must appear BEFORE 'db_input critical ncz/confirm-erase' (line $t_dbinput) -- otherwise the operator sees the stale answer, not the forced-false one" >&2; return 1; }
    return 0
}
expect "disk-fs-chooser.sh forces ncz/confirm-erase=false before db_input (auto-erase defence in depth)" 0 expect_confirm_erase_force_false "$ROOT/preseed/disk-fs-chooser.sh"
# --- adversarial: the partman recipe's ROOT stanza uses $CHOSEN_FS (not a hardcoded fs) ---
# A regression that hardcodes `filesystem{ ext4 }` or `filesystem{ btrfs }` in the
# ROOT stanza would silently overwrite the operator's choice (the dialog shows
# =  btrfs but the wipe uses ext4). The orchestrator's "the operator's choice
# wins" contract requires the recipe to interpolate $CHOSEN_FS for the root
# stanza specifically. Pin the column-anchored pattern; a comment-only match is
# not enough because the gate below also requires the interpolation to be
# inside the RECIPE (i.e. between the assignment and the first db_set).
expect_recipe_uses_chosen_fs() {
    local f="$1"
    # Find the line range of the RECIPE assignment (the orchestrator pins this
    # to a string that starts with "cixmini ::" and ends with the second
    # trailing-quoted `.` separator). The simplest robust check: there must
    # be at least one occurrence of `filesystem{ $CHOSEN_FS }` between the
    # `RECIPE=` line and the FIRST `db_set  partman-auto/expert_recipe` line.
    awk '
        /^[[:space:]]*RECIPE="/      { in_recipe=1; next }
        in_recipe && /db_set[[:space:]]+partman-auto\/expert_recipe/ { in_recipe=0; in_pin=1; next }
        in_recipe && /filesystem\{ \$CHOSEN_FS \}/ { ok=1; next }
        END { exit !ok }
    ' "$f" >/dev/null 2>&1 \
        || { echo "$f: partman recipe's ROOT stanza does NOT interpolate \$CHOSEN_FS (operator's root-fs pick would be silently overwritten by a hardcoded fs)" >&2; return 1; }
    # Adversarial: a regression that removes the column-anchored interpolation
    # and replaces it with `filesystem{ ext4 }` or `filesystem{ btrfs }` MUST
    # fail. Make the check stricter: the exact `filesystem{ $CHOSEN_FS }`
    # token must appear (single-backslash escape in the regex because the
    # recipe literally has `$CHOSEN_FS` -- bash expands `$CHOSEN_FS` when the
    # recipe is built at runtime, NOT when the test grep runs).
    grep -nE 'filesystem\{[[:space:]]+\$CHOSEN_FS[[:space:]]+\}' "$f" >/dev/null 2>&1 \
        || { echo "$f: the partman recipe no longer interpolates \$CHOSEN_FS in the ROOT stanza filesystem{ ... } token (operator's root-fs pick would be silently overwritten)" >&2; return 1; }
    return 0
}
expect "disk-fs-chooser.sh partman recipe interpolates \$CHOSEN_FS for the ROOT stanza (operator's root-fs pick is honoured)" 0 expect_recipe_uses_chosen_fs "$ROOT/preseed/disk-fs-chooser.sh"
# --- adversarial: the required 5 choosers are baked into the initrd ---
# Each chooser must appear in BAKED_HELPERS (build/iso/patch-initrd-t2-kernel.py),
# otherwise the orchestrator's required prompt is missing at runtime (the chooser
# would silently fall through `[ -f /tmp/X.sh ] && sh ...` with no fallback).
expect_baked_helpers_complete() {
    local f="$1"
    local missing=0
    local _hname
    for _hname in component-selector.sh region-chooser.sh user-chooser.sh hostname-suggest.sh ncz-hostname-gen.sh; do
        if ! grep -qE "^[[:space:]]*\"${_hname}\"," "$f" ; then
            echo "$f: BAKED_HELPERS is missing ${_hname} (orchestrator's required chooser would be absent from the initrd)" >&2
            missing=1
        fi
    done
    return $missing
}
expect "BAKED_HELPERS in patch-initrd-t2-kernel.py includes all 5 orchestrator-required choosers + ncz-hostname-gen" 0 expect_baked_helpers_complete "$ROOT/build/iso/patch-initrd-t2-kernel.py"
# --- adversarial: NO hostname dialog at runtime at all (S2-3: the name is automatic) ---
# The operator flow is "machine name: automatic, never asked". A regression that
# re-introduces the retired --prompt branch -- e.g. by adding a
# `db_input critical ncz/hostname` (or a netcfg/get_hostname) call -- would show a
# hostname dialog again and could block an unattended install. Pin that
# hostname-suggest.sh raises ZERO critical hostname prompts; the d-i-native
# netcfg/get_hostname + netcfg/hostname questions are pinned seen=true instead, so
# d-i does not raise them either.
expect_no_hostname_dialog() {
    local f="$1"
    local n_hostname n_netcfg_get_hostname
    n_hostname=$(grep -cE 'db_input critical ncz/hostname\b' "$f" 2>/dev/null); n_hostname=${n_hostname:-0}; n_hostname=$(printf '%d' "$n_hostname" 2>/dev/null || echo 0)
    n_netcfg_get_hostname=$(grep -cE 'db_input critical netcfg/get_hostname\b' "$f" 2>/dev/null); n_netcfg_get_hostname=${n_netcfg_get_hostname:-0}; n_netcfg_get_hostname=$(printf '%d' "$n_netcfg_get_hostname" 2>/dev/null || echo 0)
    [ "$n_hostname" = 0 ] || { echo "$f: found $n_hostname 'db_input critical ncz/hostname' (S2-3: the hostname dialog must not exist)" >&2; return 1; }
    [ "$n_netcfg_get_hostname" = 0 ] || { echo "$f: found $n_netcfg_get_hostname 'db_input critical netcfg/get_hostname' (S2-3: no hostname prompt)" >&2; return 1; }
    return 0
}
expect "hostname-suggest.sh shows NO hostname dialog (S2-3: hostname automatic, never asked)" 0 expect_no_hostname_dialog "$ROOT/preseed/hostname-suggest.sh"
# --- adversarial: user-chooser.sh writes CHOSEN_USER + CHOSEN_PASS to debconf ---
# The installer flow spec: "(3) default username" + "(4) default password
# with confirm (2x)". A regression that RETURNS EARLY before db_set passwd/...
# would leave the operator's answer stuck inside CHOSEN_USER/CHOSEN_PASS
# locals (which the rest of d-i does not read). Pin the db_set calls so a
# regression that drops any one fails the gate.
expect_user_chooser_writes_debconf() {
    local f="$1"
    # All three must be present: passwd/username, passwd/user-password,
    # passwd/user-fullname.
    local missing=0
    for q in 'passwd/username' 'passwd/user-password' 'passwd/user-fullname'; do
        if ! grep -nE "^[[:space:]]*db_set[[:space:]]+${q}\b" "$f" >/dev/null 2>&1 ; then
            echo "$f: missing 'db_set ${q}' (operator's ${q} answer would NOT be persisted to debconf; d-i would raise its own ${q} question)" >&2
            missing=1
        fi
    done
    return $missing
}
expect "user-chooser.sh writes the operator's username + password to debconf (d-i does not re-prompt)" 0 expect_user_chooser_writes_debconf "$ROOT/preseed/user-chooser.sh"
# --- adversarial: region-chooser.sh writes ALL FOUR derived values to debconf ---
# The installer flow spec: "region (locale/country/timezone from one
# choice, keyboard derived)". A regression that drops one of the four
# db_set calls would leave d-i's native localechooser / keyboard-configuration
# / clock-setup chain to fire (4-7 extra dialogs).
expect_region_chooser_writes_all_four() {
    local f="$1"
    local missing=0
    for q in 'debian-installer/locale' 'debian-installer/country' 'keyboard-configuration/xkb-keymap' 'time/zone'; do
        if ! grep -nE "^[[:space:]]*db_set[[:space:]]+${q}\b" "$f" >/dev/null 2>&1 ; then
            echo "$f: missing 'db_set ${q}' (the region's ${q} would NOT be persisted; d-i's native question chain would fire 4-7 extra dialogs)" >&2
            missing=1
        fi
    done
    return $missing
}
expect "region-chooser.sh writes all 4 derived values (locale, country, keymap, tz) to debconf" 0 expect_region_chooser_writes_all_four "$ROOT/preseed/region-chooser.sh"
# --- REAL capture (r201 d90ed961 arm64 KVM gate, pyte-rendered: Unicode box characters, not ACS letters) ---
# The extraction used to match ACS letters only, so on every real capture the dialog list printed "none" and the
# branded-header check never ran. The fixture holds one state per distinct dialog of that capture.
REAL="$HERE/testdata/installer-screens/arm64-d90ed961"
real() { python3 "$HERE/check-installer-screens.py" "$REAL" "$@"; }
expect "real capture: the ordered dialog list is extracted (>= 5 titles)" 0 real --min-dialogs 5 --require-header "NCZ-OS [0-9.]+ [A-Za-z]+"
real >"$T/ev" 2>&1
if grep -q 'dialogs in capture order (8): NCZ-OS 26.10 Cygnus - select your REGION > .*choose a USERNAME > .*choose a PASSWORD.* > .*type the same PASSWORD.* > .*optional components > Installing the base system' "$T/ev"; then PASS=$((PASS+1)); echo "ok   real capture: titles come out in capture order"
else FAILS=$((FAILS+1)); echo "FAIL real capture: dialog titles/order wrong"; sed 's/^/     /' "$T/ev"; fi
expect "real capture: the operator's prompt sequence is satisfied" 0 real --require-prompt-sequence "select your REGION" "choose a USERNAME" "choose a PASSWORD" "type the same PASSWORD" "optional components"
expect "real capture: 9 dialogs required but only 8 exist fails" 1 real --min-dialogs 9
# the branded-header check is live on Unicode frames: an unbranded prompt dialog fails, a d-i progress bar does not
rm -rf "$T/s"; mkdir "$T/s"; sed 's/NCZ-OS 26.10 Cygnus - //' "$REAL/0000-0043s.txt" | sed 's/NCZ-OS 26.10 Cygnus//' > "$T/s/0000-0043s.txt"
expect "real-format unbranded prompt dialog fails the header check" 1 chk --require-header "NCZ-OS [0-9.]+ [A-Za-z]+"
rm -rf "$T/s"; mkdir "$T/s"; cp "$REAL/0005-0067s.txt" "$T/s/"
expect "real-format d-i progress dialog needs no brand" 0 chk --require-header "NCZ-OS [0-9.]+ [A-Za-z]+"
# frames that cannot be parsed must FAIL, never print "none" and pass
rm -rf "$T/s"; mkdir "$T/s"; printf '# t=20s\n  lqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqk\n  x no title bar here           x\n  mqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqj\n' > "$T/s/0000-0020s.txt"
expect "frames present but no title parseable fails" 1 chk
# a capture with no dialog text at all is reported as NOT VERIFIED (framebuffer-only amd64) and fails when dialogs are required
rm -rf "$T/s"; mkdir "$T/s"; printf '# t=0s\n[framebuffer: dialog or progress on screen, 18.3%% non-background pixels]\n' > "$T/s/0000-0000s.txt"
chk >"$T/ev" 2>&1; grep -q 'dialogs in capture order (0): NOT VERIFIED' "$T/ev" && { PASS=$((PASS+1)); echo "ok   framebuffer-only capture says the dialog order is NOT VERIFIED"; } || { FAILS=$((FAILS+1)); echo "FAIL framebuffer-only capture does not say NOT VERIFIED"; cat "$T/ev"; }
expect "framebuffer-only capture fails with --min-dialogs" 1 chk --min-dialogs 5
# --- title regex is anchored to a frame line (review: body text with "l ... t k" produced bogus titles like "ec") ---
rm -rf "$T/s"; mkdir "$T/s"
printf '# t=20s\n  Select keyboard layout for the console\n  the install will not keep it, build the kernel\n  lunch is at noon, not at six k\n' > "$T/s/0000-0020s.txt"
chk >"$T/ev" 2>&1; grep -q 'dialogs in capture order (0)' "$T/ev" && { PASS=$((PASS+1)); echo "ok   body text with l...t k yields no bogus title"; } || { FAILS=$((FAILS+1)); echo "FAIL bogus title extracted from body text"; cat "$T/ev"; }
expect "bogus body-text titles cannot satisfy --min-dialogs" 1 chk --min-dialogs 1
# --- the FULL 33-state d90ed961 arm64 gate capture, with the gate's exact arguments: must pass, 8 titles ---
FULL="$HERE/testdata/installer-screens/arm64-d90ed961-full"
fullchk() { python3 "$HERE/check-installer-screens.py" "$FULL" --start-at "select your REGION" \
    --require-dialog "optional components" --require-dialog "select your REGION" --require-dialog "choose a USERNAME" \
    --require-prompt-sequence "select your REGION" "choose a USERNAME" "choose a PASSWORD" "type the same PASSWORD" "optional components" \
    --require-header "NCZ-OS [0-9.]+ [A-Za-z]+" --min-states 20 --min-dialogs 5; }
expect "full real 33-state gate capture passes the arm64 gate arguments (no false failure)" 0 fullchk
fullchk >"$T/ev" 2>&1; grep -q 'dialogs in capture order (8): ' "$T/ev" && { PASS=$((PASS+1)); echo "ok   full capture: exactly the 8 real titles"; } || { FAILS=$((FAILS+1)); echo "FAIL full capture titles"; cat "$T/ev"; }
expect "full capture: no-blank-after the component dialog" 0 python3 "$HERE/check-installer-screens.py" "$FULL" --start-at "optional components" --no-blank-after "optional components"
# --- the state floor must track the DIAMOND COUNT, not one run's cadence (2026-10-27, job 01a17b13) ---
# The 2026-10-26 content branch (13 desktop apps removed) made the KVM gate's full-option arm64 install
# finish in under ~100 s: its d-i phase drew a steady "Finishing the installation" progress dialog that
# collapses to one or two stable states (the pre-branch fixture above has 24 of 33), and the 8bf4e6e9
# gate captured 14 COMPLETE states (all 9 required dialogs in order, login line, headers, no chatter)
# while the UART kept producing installer output until the harness' own SIGTERM. The floor was 20, so
# the image failed on cadence, not content. Re-based to 12 (kvm-installer-ui-check.sh). Pin the
# structural property the re-based floor protects: it must still fail a capture truncated right after
# the component dialog (5 states: boot diag + region + username + password + components) even though a
# full run today yields only ~14.
rm -rf "$T/s"; mkdir -p "$T/s"
printf '# t=16s\n%s\n' '=== NCZ CONSOLE DIAG ===
ttyAMA0              -W- (E  Np a)  204:64
=== END CONSOLE DIAG ===' > "$T/s/0000-0016s.txt"
printf '# t=29s\n%s\n' '[                    (1**installer)  2 shell  3 shell  4- log' > "$T/s/0001-0029s.txt"
printf '# t=33s\n%s\n' "$DIALOG_REG" > "$T/s/0002-0033s.txt"
printf '# t=37s\n%s\n' "$DIALOG_USR" > "$T/s/0003-0037s.txt"
printf '# t=40s\n%s\n' "$DIALOG_PWD" > "$T/s/0004-0040s.txt"
printf '# t=43s\n%s\n' "$DIALOG_COMP" > "$T/s/0005-0043s.txt"
# A capture whose dialog-stage content is complete but whose disk-stage states were never captured
# (truncation) must fail the re-based floor: 5 captured states < 12.
expect "truncated-after-components capture (5 states) fails the re-based floor of 12" 1 chk --min-states 12
# --- the truncation property, per cut point (2026-10-27 r2) --------------------------------
# The floor counts ALL captured files, including the repeated states one long install phase
# emits, so it is a count floor, not an end-point pin. The 14-state 8bf4e6e9 fixture
# (build/testdata/installer-screens/arm64-8bf4e6e9-14states, reconstructed from the gate's
# recorded evidence: 16..138 s, 10 dialog titles in order, install phase collapsed to its
# 1-2 stable states plus the finish states) shows where each check bites:
#
#   5 states   cut after the component dialog     floor FAIL (5 < 12),  end-point FAIL
#   8 states   cut after the erase confirmation   floor FAIL (8 < 12),  end-point FAIL
#   12 states  cut after the install phase        floor PASS (12 >= 12), end-point PASS
#   14 states  complete capture (16..138 s)       floor PASS (14 >= 12), end-point PASS
#
# Every cut BEFORE the final dialog fails at least one check; the complete capture passes
# both. The end-point rule (--last-state-matches) is the second half of the guard: a
# complete run always ends inside the install progress phase ("Installing the base system"
# or "Finishing the installation"), so a capture whose last state is the erase review
# (truncated after the confirmation, before the install drew its first stable state) fails
# the end-point rule even when its state count would beat the floor on a slower capture.
CUTFX="$HERE/testdata/installer-screens/arm64-8bf4e6e9-14states"
PROG_RX="Installing the base system|Finishing the installation"
cutbuild() { # cutbuild <n> <dir> = copy the first N state files of the fixture into <dir>
    local n="$1" d="$2" f
    rm -rf "$d"; mkdir -p "$d"
    ls "$CUTFX"/*.txt | sort | head -n "$n" | while read -r f; do cp "$f" "$d/"; done; }
cutchk() { # cutchk <n> = the first N state files of the fixture, judged with the floor + end-point rule
    local n="$1"
    cutbuild "$n" "$T/cut"
    python3 "$HERE/check-installer-screens.py" "$T/cut" --min-states 12 --last-state-matches "$PROG_RX"; }
expect "14-state complete capture passes floor 12 + end-point (the real 8bf4e6e9 run, 16..138 s)" 0 cutchk 14
expect "5-state cut after the component dialog fails floor 12" 1 cutchk 5
expect "5-state cut after the component dialog fails the end-point rule (last state = component dialog)" 1 python3 "$HERE/check-installer-screens.py" "$T/cut" --last-state-matches "$PROG_RX"
expect "8-state cut after the erase confirmation fails floor 12" 1 cutchk 8
expect "8-state cut after the erase confirmation fails the end-point rule (last state = erase review)" 1 python3 "$HERE/check-installer-screens.py" "$T/cut" --last-state-matches "$PROG_RX"
cutbuild 12 "$T/cut12"
expect "12-state cut after the install phase passes floor 12 + end-point (a capture that reached the final dialog)" 0 python3 "$HERE/check-installer-screens.py" "$T/cut12" --min-states 12 --last-state-matches "$PROG_RX"
# --- the end-point rule is deterministic: "last" = the LATEST recorded # t= time, not
# the last name in sorted order. A name with a non-zero-padded second field (14-00138s)
# sorts lexicographically FIRST but is chronologically LAST, so files[-1] would judge the
# wrong state. Build two states: a blank diag at t=16 (name 0000) and the install progress
# at t=138 (name 14-00138s, which sorts before 0000...). The end-point rule must pick the
# t=138 state (PASS) even though sorted order puts it first.
rm -rf "$T/ep"; mkdir -p "$T/ep"
printf '# t=16s\n%s\n' '=== NCZ CONSOLE DIAG ===
ttyAMA0              -W- (E  Np a)  204:64
=== END CONSOLE DIAG ===' > "$T/ep/0000-0016s.txt"
printf '# t=138s\n%s\n' '  ┌─────────────────────┤ Finishing the installation ├──────────────────────┐
  │                                   23%%                                   │
  └─────────────────────────────────────────────────────────────────────────┘' > "$T/ep/14-00138s.txt"
# sorted order = [0000-0016s, 14-00138s]; lexicographic last = 14-00138s here, but to make
# the test bite, the chronologically-last file must NOT be the lexicographic-last one:
# rename the progress state so it sorts FIRST (0000) while carrying the larger # t= value.
rm -f "$T/ep/14-00138s.txt"
printf '# t=138s\n%s\n' '  ┌─────────────────────┤ Finishing the installation ├──────────────────────┐
  │                                   23%%                                   │
  └─────────────────────────────────────────────────────────────────────────┘' > "$T/ep/0000-0138s.txt"
printf '# t=16s\n%s\n' '=== NCZ CONSOLE DIAG ===
ttyAMA0              -W- (E  Np a)  204:64
=== END CONSOLE DIAG ===' > "$T/ep/0001-0016s.txt"
# Now sorted = [0000-0138s (t=138, progress), 0001-0016s (t=16, diag)].
# Lexicographic last = 0001-0016s (the diag) -- the WRONG state.
# Chronological last = 0000-0138s (t=138, the progress) -- the RIGHT state.
# A correct end-point rule picks the t=138 state and PASSES the progress regex.
expect "end-point rule picks the chronological last state (t=138 progress), not the lexicographic last (t=16 diag)" 0 python3 "$HERE/check-installer-screens.py" "$T/ep" --last-state-matches "Finishing the installation"
# And the same two states, with the regex matching ONLY the diag, must FAIL (proves the
# rule did not fall back to the lexicographic-last diag state).
expect "end-point rule does not fall back to the lexicographic-last state (diag-only regex fails)" 1 python3 "$HERE/check-installer-screens.py" "$T/ep" --last-state-matches "NCZ CONSOLE DIAG"
# --- --last-state-matches on an EMPTY directory: report a clean FAIL, never IndexError.
# The checker's existing early-exit for an empty directory (sys.exit "no console states
# captured") fires before the end-point check, so an empty capture already fails cleanly.
# The guard in the end-point block is a belt-and-suspenders: if the early-exit is ever
# removed or reordered, files[-1] would raise IndexError. Prove no crash either way.
rm -rf "$T/empty"; mkdir -p "$T/empty"
expect "--last-state-matches on an empty capture fails cleanly (no IndexError)" 1 python3 "$HERE/check-installer-screens.py" "$T/empty" --last-state-matches "Finishing the installation"
# the gate wires the end-point rule into the judge call of BOTH judge paths
KV2="$HERE/kvm-installer-ui-check.sh"
n_lsm=$(awk '/^judge_text\(\) \{/,/^\}/' "$KV2" | grep -c -- '--last-state-matches')
n_lsm_s=$(awk '/^judge_text_server\(\) \{/,/^\}/' "$KV2" | grep -c -- '--last-state-matches')
[ "$n_lsm" = 1 ] && [ "$n_lsm_s" = 1 ] \
    && { PASS=$((PASS+1)); echo "ok   kvm-installer-ui-check.sh pins the install-progress end point in judge_text and judge_text_server"
} || { FAILS=$((FAILS+1)); echo "FAIL kvm-installer-ui-check.sh end-point wiring: judge_text=$n_lsm judge_text_server=$n_lsm_s (expected 1/1)"; }
# --- kvm-installer-ui-check.sh: amd64 is judged from a TEXT channel, not the framebuffer alone (2026-10-17) ---
# The amd64 check used to sample the framebuffer only and exit PASS-LIMITED without reading a single dialog title,
# which could not catch the disk-chooser Choices/Choices-C swap the arm64 check caught on the serial console. The
# amd64 path now boots the ui-check copy with d-i on the UART (console=ttyS0,115200 on the TEST copy) and runs the
# same text assertions as arm64; PASS-LIMITED must never come back as an amd64 outcome, and the framebuffer checks
# must stay. (The wrapper's behaviour is exercised end to end by build/test-installer-ui-wrapper.sh.)
KV="$HERE/kvm-installer-ui-check.sh"
nl="$(grep -n 'ndist=' "$KV" | head -1 | cut -d: -f1)"; vl="$(grep -n 'if \[ \$rc = 0 \]' "$KV" | head -1 | cut -d: -f1)"
[ -n "$nl" ] && [ -n "$vl" ] && [ "$nl" -lt "$vl" ] && { PASS=$((PASS+1)); echo "ok   amd64 frame-count check (line $nl) runs before the final verdict (line $vl)"; } || { FAILS=$((FAILS+1)); echo "FAIL frame-count check missing or after the verdict ($nl vs $vl)"; }
! grep -q 'PASS-LIMITED' "$KV" && { PASS=$((PASS+1)); echo "ok   no PASS-LIMITED outcome remains (amd64 has a real text channel)"; } || { FAILS=$((FAILS+1)); echo "FAIL kvm-installer-ui-check.sh still reports PASS-LIMITED"; }
grep -q -- '--serial-console' "$KV" && grep -q 'judge_text' "$KV" && { PASS=$((PASS+1)); echo "ok   the amd64 branch boots the test copy on the UART and judges BOTH arches with judge_text"; } || { FAILS=$((FAILS+1)); echo "FAIL kvm-installer-ui-check.sh has no amd64 serial text channel / shared judge"; }
grep -q 'fb-states' "$KV" && grep -q 'ndist=' "$KV" && { PASS=$((PASS+1)); echo "ok   amd64 keeps the framebuffer continuity and distinct-frame checks"; } || { FAILS=$((FAILS+1)); echo "FAIL amd64 framebuffer checks were dropped"; }
# --- the diagnostics login line: the UI-check regex, the ncz_diag_pw wording, 80-column wraps ---
# kvm-installer-ui-check.sh boots its copy with ncz_diag_pw set, so the screens say
# "root / set by ncz_diag_pw", and the 80-column console wraps the line inside the dialog
# borders and in the banner. Taken from the arm64 f83ac780 capture.
LRX="$(sed -n 's/.*--require-login-line "\([^"]*\)".*/\1/p' "$ROOT/build/kvm-installer-ui-check.sh" | head -1)"
expect "ui-check login regex accepts the ncz_diag_pw wording" 0 sh -c 'case "$1" in *"set by ncz_diag_pw"*) exit 0 ;; *) exit 1 ;; esac' _ "$LRX"
mk "$(printf '%s\n' \
'┌─── NCZ-OS 26.10 Cygnus - select your REGION ───┐' \
'│ arm64 (Sky1) | build f83ac780 | diagnostics login: root / set by        │' \
'│ ncz_diag_pw                                                             │' \
'└───┘')"
expect "login line wrapped inside dialog borders (override wording) is found" 0 chk --require-login-line "$LRX"
mk "$(printf '%s\n' '[NCZ 05:40:12] ==== NCZ-OS INSTALLER 2026.10.14-f83ac780 ==== diagnostics login:' ' root / set by ncz_diag_pw')"
expect "banner wrapped at 80 columns (override wording) is found" 0 chk --require-login-line "$LRX"
mk "$(printf '%s\n' '==== NCZ-OS INSTALLER 2026.10.14-f83ac780 ==== diagnostics login: root / rescue')"
expect "default wording on one line is found" 0 chk --require-login-line "$LRX"
mk "$(printf '%s\n' '==== NCZ-OS INSTALLER 2026.10.14-f83ac780 ====' 'nothing else')"
expect "no login line: FAIL" 1 chk --require-login-line "$LRX"
mk "$(printf '%s\n' 'diagnostics login: root / set')"
expect "a truncated 'root / set' is not the override wording: FAIL" 1 chk --require-login-line "$LRX"

echo "installer screen tests: $PASS passed, $FAILS failed"
[ "$FAILS" = 0 ]
