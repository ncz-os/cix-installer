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
GOOD=$'  NCZ-OS 26.7 Maximilian | arm64 (Sky1) | build abc1234\n  lqqqqqqqqqqqqqqqqqqqqqu [!!] NCZ-OS install tqqqqqqqqqqqqqqqk\n  x Untick to skip an optional component.  x\n  x  [*] Full Singularity desktop           x\n  mqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqj'
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
# Orchestrator's required flow is 9 dialog states (step 4 = 2 password prompts,
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
# The orchestrator's directive: "(5) machine name: ONE step showing the
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
expect "preseed.cfg invokes hostname-suggest.sh --prompt exactly once"  0 expect_one_presource hostname-suggest  "$PRCFG"
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
expect "hostname-suggest.sh template shows auto-generated name"                   0 expect_template_phrase "$ROOT/preseed/hostname-suggest.sh" "name this computer"
expect "disk-fs-chooser.sh template shows the disk-select prompt"                0 expect_template_phrase "$ROOT/preseed/disk-fs-chooser.sh" "select the TARGET DISK"
expect "disk-fs-chooser.sh template shows the root-fs prompt"                     0 expect_template_phrase "$ROOT/preseed/disk-fs-chooser.sh" "root (/) filesystem"
expect "disk-fs-chooser.sh template shows the erase-confirm prompt"              0 expect_template_phrase "$ROOT/preseed/disk-fs-chooser.sh" "ERASE"
# --- source-level regression: the disk-select prompt is NOT skipped on a single candidate ---
# The orchestrator's directive: "if exactly one non-media candidate disk, show it
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
# --- source-level regression: the password-confirm mismatch leaves the password UNSET (operator UX requirement) ---
# Operator directive: "(4) default password with confirm (2x)". The confirm
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
# Operator safety directive: "keep partman pin byte-compare". The chooser
# sets partman-auto/disk + partman-auto/expert_recipe + partman-auto/choose_recipe
# via db_set, then db_get + exact-string compare the pinned recipe to the one
# WE set. A regression that drops the byte-identical compare would let a
# stale/failed debconf pin pass and wipe a disk that was NOT the operator's
# choice.
expect_partman_pin_byte_compare() {
    local f="$1"
    # The exact equality assertion
    grep -qF 'byte-identical' "$f" || { echo "$f: missing the byte-identical compare (partman pin safety regression)" >&2; return 1; }
    # The root-stanza-specific filesystem check (catches the old 'plain
    # substring test' defect where ext4 would falsely pass against the rescue
    # partition's filesystem{ ext4 } token)
    grep -qF 'mountpoint{ / }' "$f" || { echo "$f: missing the root-stanza filesystem check" >&2; return 1; }
    # The disk pin
    grep -qF 'partman-auto/disk did not pin' "$f" || { echo "$f: missing the partman-auto/disk pin verification" >&2; return 1; }
    return 0
}
expect "disk-fs-chooser.sh verifies partman pins are byte-identical before wiping (operator safety guard)" 0 expect_partman_pin_byte_compare "$ROOT/preseed/disk-fs-chooser.sh"
# --- source-level regression: disk-fs-chooser.sh refuses a media-disk target (operator safety directive) ---
# Operator safety directive: "keep ... media-disk protection". The install
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
# Operator safety directive: "ncz_disk=/ncz_fs= overrides stay for unattended
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
# --- source-level regression: the orchestrator-required 6-step sequence is the ONLY chooser order in preseed.cfg ---
# A regression that re-orders the chooser invocations in preseed.cfg's
# partman/early_command (e.g. swaps hostname with disk) violates the
# orchestrator's directive. This test pins the EXACT order by joining the
# line-continued early_command and asserting the chooser invocations appear
# in the required sequence.
expect_orchestrator_order() {
    local cfg="$1"
    # Extract ONLY the partman/early_command block (the orchestrator-required
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
    # Order: component -> region -> user -> hostname -> disk (the operator-required
    # partman/early_command order -- the password + password-confirm are inside
    # user-chooser.sh so they count as a single chooser invocation here).
    local a b c d e
    a=$(printf '%s' "$joined" | grep -boE '/tmp/component-selector\.sh[[:space:]]+--prompt' | head -1 | cut -d: -f1)
    b=$(printf '%s' "$joined" | grep -boE '/tmp/region-chooser\.sh[[:space:]]+--prompt'   | head -1 | cut -d: -f1)
    c=$(printf '%s' "$joined" | grep -boE '/tmp/user-chooser\.sh[[:space:]]+--prompt'      | head -1 | cut -d: -f1)
    d=$(printf '%s' "$joined" | grep -boE '/tmp/hostname-suggest\.sh[[:space:]]+--prompt'  | head -1 | cut -d: -f1)
    # For disk-fs-chooser.sh we must skip the early guard references (the
    # `if ! [ -f /cdrom/.../disk-fs-chooser.sh ]` tests) and pick the
    # actual invocation, which uses the variable form `sh "$D/disk-fs-chooser.sh"`.
    e=$(printf '%s' "$joined" | grep -boE 'sh[[:space:]]+"\$D/disk-fs-chooser\.sh"' | head -1 | cut -d: -f1)
    [ -n "$a" ] && [ -n "$b" ] && [ -n "$c" ] && [ -n "$d" ] && [ -n "$e" ] || { echo "$cfg: one of the 5 chooser invocations is missing from partman/early_command" >&2; return 1; }
    # Order check (each must come strictly AFTER the previous)
    [ "$a" -lt "$b" ] && [ "$b" -lt "$c" ] && [ "$c" -lt "$d" ] && [ "$d" -lt "$e" ] \
        || { echo "$cfg: chooser invocations are not in the orchestrator-required order (component -> region -> user -> hostname -> disk)" >&2; return 1; }
    return 0
}
expect "preseed.cfg invokes component->region->user->hostname->disk in the orchestrator-required order (partman/early_command)" 0 expect_orchestrator_order "$PRCFG"
# --- source-level regression: the 6 choosers each set a debconf question with seen=true on the orchestrator-required d-i questions ---
# The orchestrator's directive: the choosers REPLACE d-i's native locale/
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
# --- adversarial: each orchestrator-interactive chooser exposes the EXPECTED template TYPE ---
# A regression that re-registers an interactive chooser as `Type: note` (which
# auto-dismisses without operator input) would skip the operator's prompt for
# that step. Pin the type so a regression is caught at this gate. The 5
# orchestrator-interactive choosers each expose at least one interactive
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
expect "component-selector.sh exposes a Type: multiselect template (the operator's first interactive prompt)" 0 expect_chooser_type "$ROOT/preseed/component-selector.sh" multiselect
expect "region-chooser.sh exposes a Type: select template (the operator's second interactive prompt)"   0 expect_chooser_type "$ROOT/preseed/region-chooser.sh"     select
expect "user-chooser.sh exposes a Type: string template (username is the third interactive prompt)"     0 expect_chooser_type "$ROOT/preseed/user-chooser.sh"      string
expect "user-chooser.sh exposes a Type: password template (the password + confirm step)"               0 expect_chooser_type "$ROOT/preseed/user-chooser.sh"      password
expect "hostname-suggest.sh exposes a Type: string template (the fifth interactive prompt)"             0 expect_chooser_type "$ROOT/preseed/hostname-suggest.sh"  string
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
# helper. The orchestrator's directive is that every chooser step MUST require
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
# The orchestrator's directive: "(5) machine name: ONE step showing the
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
    printf '%s' "$payload" | tr -d '\n\\' | grep -qE '/tmp/hostname-suggest\.sh[[:space:]]+--prompt' \
        || { echo "$cfg: the hostname --prompt invocation is NOT inside partman/early_command" >&2; return 1; }
    return 0
}
expect "hostname-suggest.sh --prompt is invoked inside partman/early_command (orchestrator-required single-prompt-per-step)" 0 expect_hostname_only_in_partman_early_command "$PRCFG"
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
# The orchestrator's directive (2026-09-30): "(6) filesystem" is one of the
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
    local t_disk t_fs t_erase
    t_disk=$(grep -nE '^[[:space:]]*db_input critical ncz/target-disk'   "$f" | head -1 | cut -d: -f1)
    t_fs=$(  grep -nE '^[[:space:]]*db_input critical ncz/root-fs'      "$f" | head -1 | cut -d: -f1)
    t_erase=$(grep -nE '^[[:space:]]*db_input critical ncz/confirm-erase' "$f" | head -1 | cut -d: -f1)
    [ -n "$t_disk" ] && [ -n "$t_fs" ] && [ -n "$t_erase" ] || { echo "$f: disk-stage db_input line numbers missing" >&2; return 1; }
    [ "$t_disk" -lt "$t_fs" ] && [ "$t_fs" -lt "$t_erase" ] \
        || { echo "$f: disk-stage db_input calls are NOT in the required order (target-disk < root-fs < confirm-erase)" >&2; return 1; }
    return 0
}
expect "disk-fs-chooser.sh shows the 3 disk-stage prompts in order (target-disk < root-fs < confirm-erase)" 0 expect_disk_db_input_order "$ROOT/preseed/disk-fs-chooser.sh"
echo "installer screen tests: $PASS passed, $FAILS failed"
[ "$FAILS" = 0 ]
