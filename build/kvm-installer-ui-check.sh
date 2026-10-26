#!/bin/bash
# kvm-installer-ui-check.sh IMAGE ARCH WORKDIR -- boot the installer image under KVM as shipped (NO preset answers for the
# hostname/components prompts), answer the dialogs, and assert on what the operator SEES:
#   * the NCZ dialogs appear in the operator's order, branded (product, release, codename in the frame title) and with the arch/build line
#   * no [diag] / [ncz ...] chatter, no credential text, no "<ERR>", no askfirst prompt on the UI terminal
#   * the console is never blank after the component dialog (a progress bar or dialog stays up)
# Both architectures are judged from the SAME text channel: the UART that d-i's newt draws on. arm64 gets it from
# auto=true (d-i picks ttyAMA0); amd64 gets it because the TEST COPY's Install entry carries console=ttyS0,115200
# (boot-screens.py --serial-console), which is what finally closes the 2026-10-17 gap: amd64 used to be sampled from
# the framebuffer only, so it could not read a dialog title, its order, the Choices/Choices-C swap, or the erase
# review. The amd64 framebuffer checks (continuity + distinct frames) run on a second boot that keeps the shipped
# console=tty0: with the UART as /dev/console d-i never draws on the monitor.
# Needs pyte: NCZ_PYTE_PYTHON (default ~/pyte-venv/bin/python, else python3 with pyte). A missing pyte FAILS the gate.
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
IMG="${1:?image}"; ARCH="${2:?arch}"; WORK="${3:?workdir}"
# The KVM gate invokes this under ncz_sudo (as root); $WORK/ui-check/* would be
# root-owned and undeletable by the build user. Hand it back on every exit path
# (cleanup only -- install the trap before the first mkdir below). 2026-10-11.
. "$HERE/lib/priv.sh" 2>/dev/null || true
if declare -F ncz_trap_chown_back >/dev/null 2>&1; then ncz_trap_chown_back "$WORK"; fi
PY="${NCZ_PYTE_PYTHON:-$HOME/pyte-venv/bin/python}"; [ -x "$PY" ] || PY=python3
"$PY" -c 'import pyte' 2>/dev/null || { echo "UI CHECK FAIL: pyte is not installed for $PY (python3 -m venv ~/pyte-venv && ~/pyte-venv/bin/pip install pyte)" >&2; exit 1; }
SECS="${NCZ_UI_CHECK_SECS:-200}"
# NCZ_UI_CHECK_VARIANT=server judges a Magnetar Server medium (the KVM gate's server set): no component dialog,
# "Magnetar Server" in every dialog title, "Cygnus" nowhere on screen, and the review screen promises no desktop.
VARIANT="${NCZ_UI_CHECK_VARIANT:-desktop}"
case "$VARIANT" in desktop|server) ;; *) echo "UI CHECK FAIL: NCZ_UI_CHECK_VARIANT must be desktop or server, got '$VARIANT'" >&2; exit 2 ;; esac
rm -rf "$WORK"; mkdir -p "$WORK"
# The operator-required chooser order (preseed.cfg partman/early_command, 2026-10-06): region, username,
# password, password confirm, components, then the target disk, root filesystem and erase confirmation;
# the hostname is automatic. --ask-disk drops the ncz_disk/ncz_fs preset so the real disk dialogs are walked.
# --answer sends a rule's keys once, when its screen matches, so every rule must be a dialog that really appears;
# a dialog that is skipped (or reaches an answer key the wrong one) stalls the capture and fails the sequence.
# The HARDWARE SUMMARY note (preseed/hw-summary.sh) follows the password confirm on an interactive install:
# Continue it, and require it in the sequence so a summary that silently stops appearing is caught too.
# Rule 0 must stay the component dialog (T_ANS below). The password is a throwaway for this capture only.
# The ERASE confirmation defaults to No and its Yes/No buttons have no keyboard accelerator. cdebconf's newt
# boolean adds the components as [Go Back] [text] [Yes] [No] with focus on No, and newt moves focus with
# Up/Left (previous) and Down/Right (next) WITHOUT wrapping, so Down on the last button does nothing and the
# Enter that follows answers No (2026-10-26, Preview4 arm64: the chooser aborted, nothing was written).
# Left then Enter selects Yes; Enter alone answers No and the install stops at the chooser.
ANS=(--answer 'optional components=\r' --answer 'select your REGION=\r' --answer 'choose a USERNAME=\r'
     --answer 'choose a PASSWORD=nczuicheck\r' --answer 'type the same PASSWORD=nczuicheck\r'
     --answer 'HARDWARE SUMMARY=\r'
     --answer 'select the TARGET DISK=\r' --answer 'root \(/\) filesystem=\r'
     --answer "${NCZ_UI_CHECK_ERASE_RX:-ERASE /dev/vda and install}=${NCZ_UI_CHECK_ERASE_KEYS:-\x1b[D\r}")
# A Magnetar Server medium shows no component dialog and titles its steps "Magnetar Server - Step n of 7: <action>"
# (preseed/ncz-ui.sh ncz_ui_title): rule 0 is the country dialog there. An --answer rule for a dialog that never
# appears would stall the capture, so the server rules are the server's own words.
SRV_SEQ=("Choose your country" "Choose a user name" "Choose a password" "Type the password again" "What we found"
         "Choose the disk to ERASE" "Choose the file system" "Erase disk and install")
if [ "$VARIANT" = server ]; then
    ANS=(--answer 'Choose your country=\r' --answer 'Choose a user name=\r'
         --answer 'Choose a password=nczuicheck\r' --answer 'Type the password again=nczuicheck\r'
         --answer 'What we found=\r'
         --answer 'Choose the disk to ERASE=\r' --answer 'Choose the file system=\r'
         --answer "${NCZ_UI_CHECK_ERASE_RX:-Erase disk and install}=${NCZ_UI_CHECK_ERASE_KEYS:-\x1b[D\r}")
fi
# The Install menuentry of a test copy's refind.conf. The console checks below read ONLY this entry: the shipped
# Rescue entry carries console=ttyS0 by design, so a whole-file grep refused every real image (and would pass a
# test copy whose Install entry lost its UART).
install_entry() { awk '/^menuentry "NCZ-OS Installer -- Install" \{/{f=1} f && /^\}/{f=0} f' "$1" 2>/dev/null; }
if [ "$ARCH" = amd64 ]; then
    # amd64 has no UART on the shipped entries (by design: console=tty0 only, see preseed/diag-console.sh), so the
    # TEST COPY gets console=ttyS0,115200 appended to its Install entry and d-i's newt draws the same dialogs there.
    # The test copy's ESP also carries a small first-stage preseed hook (boot-screens.py --serial-console) that
    # re-applies only the medium's own preseed/early_command: without it the shipped helper farm (diag console,
    # disk chooser) writes progress text over the UART dialog while newt draws and the screen text is mixed noise.
    # The shipped image is never modified -- only WORK/screens-test.img.
    "$PY" "$HERE/boot-screens.py" "$IMG" "$WORK" --arch "$ARCH" --interactive --secs "$SECS" --every 30 \
        --serial-console --ask-disk "${ANS[@]}" \
        > "$WORK/harness.log" 2>&1 \
        || { echo "UI CHECK FAIL: the capture harness failed (see $WORK/harness.log)" >&2; tail -5 "$WORK/harness.log" >&2; exit 1; }
    # The test channel is only as good as the copy that carried it: prove the booted test image (not the shipped
    # one) has both halves before judging anything the UART says.
    grep -q 'ncz_ui_check=1' "$WORK/rules.readback" 2>/dev/null \
        || { echo "UI CHECK FAIL (amd64): the test copy's ESP has no ncz_ui_check=1 preseed hook; the UART text cannot be trusted" >&2; exit 1; }
    install_entry "$WORK/refind.conf" | grep -q 'console=ttyS0,115200' \
        || { echo "UI CHECK FAIL (amd64): the test copy's Install entry has no console=ttyS0,115200; d-i never drew on the UART" >&2; exit 1; }
    # The MONITOR is judged on its own boot. With console=ttyS0 last, d-i's newt draws on the UART only and the
    # framebuffer stays on a static screen (2026-10-26, Preview4 amd64: no fb-states, 2 distinct frames), so the
    # serial boot cannot show what an operator sees. A second boot of a test copy that keeps the shipped Install
    # entry's console=tty0 answers on a timer exactly as the pre-serial check did, and the framebuffer continuity
    # and distinct-frame checks below read it.
    FBW="$WORK/fb"
    mkdir -p "$FBW"
    "$PY" "$HERE/boot-screens.py" "$IMG" "$FBW" --arch "$ARCH" --interactive --secs "$SECS" --enter-every 6 --enter-after 25 \
        > "$FBW/harness.log" 2>&1 \
        || { echo "UI CHECK FAIL: the framebuffer capture harness failed (see $FBW/harness.log)" >&2; tail -5 "$FBW/harness.log" >&2; exit 1; }
    if install_entry "$FBW/refind.conf" | grep -q 'console=ttyS0'; then
        echo "UI CHECK FAIL (amd64): the framebuffer boot's Install entry carries a UART console; the monitor would not show d-i" >&2; exit 1
    fi
else
    # arm64: auto=true already hands the UART to d-i; the interactive rules walk the same sequence.
    "$PY" "$HERE/boot-screens.py" "$IMG" "$WORK" --arch "$ARCH" --interactive --secs "$SECS" --every 30 \
        --ask-disk "${ANS[@]}" \
        > "$WORK/harness.log" 2>&1 \
        || { echo "UI CHECK FAIL: the capture harness failed (see $WORK/harness.log)" >&2; tail -5 "$WORK/harness.log" >&2; exit 1; }
fi
# ONE text contract for BOTH architectures. --start-at "select your REGION" skips the bootloader's echo of the test
# kernel command line (on amd64 that line now carries the ncz_ui_check marker, which must not be read as a dialog).
judge_text() {
    "$PY" "$HERE/check-installer-screens.py" "$WORK/serial-screens" --start-at "select your REGION" \
        --require-dialog "optional components" --require-dialog "select your REGION" \
        --require-dialog "choose a USERNAME" \
        --require-prompt-sequence "select your REGION" "choose a USERNAME" \
            "choose a PASSWORD" "type the same PASSWORD" "HARDWARE SUMMARY" "optional components" \
            "select the TARGET DISK" "root \(/\) filesystem" "ERASE /dev/vda and install" \
        --require-header "NCZ-OS [0-9.]+ [A-Za-z]+" --min-states 20 --min-dialogs 5 \
        --require-login-line "diagnostics login: root / (set by ncz_diag_pw|\S{4,})"
}
# Magnetar Server: the same sequence without the component dialog, and every dialog header names the edition.
judge_text_server() {
    "$PY" "$HERE/check-installer-screens.py" "$WORK/serial-screens" --start-at "Choose your country" \
        --require-dialog "Choose your country" --require-dialog "Choose a user name" \
        --require-prompt-sequence "${SRV_SEQ[@]}" \
        --require-header "Magnetar Server" --min-states 20 --min-dialogs 5 \
        --require-login-line "diagnostics login: root / (set by ncz_diag_pw|\S{4,})"
}
rc=0
if [ "$VARIANT" = server ]; then
    judge_text_server || rc=1
    # What the operator reported on the first real server install (2026-10-26, cyclops): the desktop codename in
    # the dialogs and the desktop component selector. Judged on every captured screen, including the boot text before
    # the first dialog: the codename must not appear anywhere on the server path.
    _srv_screens=()
    for _s in "$WORK"/serial-screens/*.txt; do [ -f "$_s" ] && _srv_screens+=("$_s"); done
    if [ "${#_srv_screens[@]}" = 0 ]; then
        echo "UI CHECK FAIL: no installer screens were captured" >&2; rc=1
    else
        _hit=$(grep -l -- "Cygnus" "${_srv_screens[@]}" 2>/dev/null | head -3 | tr '\n' ' ')
        [ -z "$_hit" ] || { echo "UI CHECK FAIL: a Magnetar Server installer screen names the desktop codename 'Cygnus': $_hit" >&2; rc=1; }
        _hit=$(grep -lE -- "optional components|Full Singularity desktop" "${_srv_screens[@]}" 2>/dev/null | head -3 | tr '\n' ' ')
        [ -z "$_hit" ] || { echo "UI CHECK FAIL: the desktop component selector appeared on a Magnetar Server medium: $_hit" >&2; rc=1; }
        grep -q -- "Magnetar Server - Step 1 of 7: Choose your country" "${_srv_screens[@]}" 2>/dev/null \
            || { echo "UI CHECK FAIL: the first server dialog is not titled 'Magnetar Server - Step 1 of 7: Choose your country'" >&2; rc=1; }
        grep -qE -- "NCZ-OS [0-9.]+ Magnetar Server \|" "${_srv_screens[@]}" 2>/dev/null \
            || { echo "UI CHECK FAIL: no server dialog carries the full edition name 'NCZ-OS 26.10 Magnetar Server' on its id line" >&2; rc=1; }
    fi
    _ncz_rule0_missing="the region dialog (answer rule 0 on a server medium) was never reached/answered"
else
    judge_text || rc=1
    _ncz_rule0_missing="the component dialog was never reached/answered"
fi
T_ANS="$(sed -n 's/^t=\([0-9]*\)s rule 0 .*/\1/p' "$WORK/answers.log" | head -1)"
[ -n "$T_ANS" ] || { echo "UI CHECK FAIL: $_ncz_rule0_missing" >&2; exit 1; }
# --max-blank-secs 12: after the erase confirmation the chooser's "erasing <disk>" progress bar is up for
# under the 2 s a state needs to be captured, so the one blank state before it measures ~8 s on this
# capture although the operator sees the progress bar (it is in serial0.log). A server medium has no component
# dialog; its screens are judged from the HARDWARE SUMMARY note, the dialog just before where that one stood.
_ncz_noblank="optional components"; [ "$VARIANT" = server ] && _ncz_noblank="What we found"
"$PY" "$HERE/check-installer-screens.py" "$WORK/serial-screens" --start-at "$_ncz_noblank" \
    --no-blank-after "$_ncz_noblank" --max-blank-secs 12 || rc=1
# The dialogs above are answered with Enter only (except the erase Yes), so the install must go ahead with the
# DEFAULTS. The erase review screen restates what was chosen: every optional component (a select/multiselect whose
# Choices-C holds labels instead of values loses the Default and returns labels, which parse as "none" -- the
# 2026-10-17 CHIMERA failure) and the rescue partition that comes with it. The d-i syslog does not reach the serial
# console, so this is judged from the captured screens.
_review_rx="ERASE /dev/vda and install"; [ "$VARIANT" = server ] && _review_rx="Erase disk and install"
_review=$(grep -l "$_review_rx" "$WORK"/serial-screens/*.txt 2>/dev/null | head -1)
if [ -z "$_review" ]; then
    echo "UI CHECK FAIL: the erase review screen was never captured" >&2; rc=1
else
    if [ "$VARIANT" = server ]; then
        # The server record is fixed (preseed/component-selector.sh: rescue partition only), so the review lists no
        # components, and it must
        # state the network requirement before the erase.
        ! grep -qE "Components:|Singularity" "$_review" \
            || { echo "UI CHECK FAIL: the Magnetar Server review lists desktop components: $(grep -oE 'Components:.*|.*Singularity.*' "$_review" | head -1)" >&2; rc=1; }
        grep -q "downloads about 3 GB" "$_review" \
            || { echo "UI CHECK FAIL: the Magnetar Server review does not say the install downloads about 3 GB before the disk is erased" >&2; rc=1; }
    else
        grep -q "Components: *Full Singularity desktop" "$_review" \
            || { echo "UI CHECK FAIL: Enter on the component dialog did not keep the default (all components): $(grep -o 'Components:.*' "$_review" | head -1)" >&2; rc=1; }
    fi
    grep -q "Rescue partition: *yes" "$_review" \
        || { echo "UI CHECK FAIL: the default rescue partition was lost: $(grep -o 'Rescue partition:.*' "$_review" | head -1)" >&2; rc=1; }
fi
# Name the two ways the 2026-10-26 arm64 capture went wrong instead of leaving only their symptoms (a syslog
# window on the console, a short capture): the erase confirmation answered No, and the debconf frontend died.
if grep -q "the operator did not confirm erasing" "$WORK/serial0.log" "$WORK"/serial-screens/*.txt 2>/dev/null; then
    echo "UI CHECK FAIL: the erase confirmation was answered No (the answer keys did not select Yes; see answers.log)" >&2; rc=1
fi
if grep -aq "lookup_directive: Assertion" "$WORK/serial0.log" 2>/dev/null; then
    echo "UI CHECK FAIL: the debconf frontend aborted (cdebconf lookup_directive assertion: a \${...} reached a displayed question)" >&2; rc=1
fi
if grep -q "not in the candidate set" "$WORK"/serial-screens/*.txt 2>/dev/null; then
    echo "UI CHECK FAIL: the disk chooser rejected its own answer (Choices/Choices-C swapped?)" >&2; rc=1
fi
if [ "$ARCH" = amd64 ]; then
    # Still judged from the FIRST frame (the bootloader menu). The framebuffer is blank once, right after it, while
    # the kernel and the initrd load (5-9 s depending on the host); that state may last up to 20 s. Every later blank
    # is a vanished UI unless it is a redraw shorter than --max-blank-secs. This now guards a real claim: d-i draws
    # on the UART, and the monitor must still show the same UI.
    "$PY" "$HERE/check-installer-screens.py" "$FBW/fb-states" --no-blank-after "framebuffer" --boot-blank-max-secs 20 2>&1 | tee "$WORK/fb-check.out"; [ "${PIPESTATUS[0]}" = 0 ] || rc=1
    # proof the installer really progressed on the framebuffer (dialogs and progress bars): many distinct frames
    ndist=$(awk '{print $2}' "$FBW/fb-frames.txt" 2>/dev/null | sort -u | wc -l | tr -d ' ')
    [ "${ndist:-0}" -ge 8 ] || { echo "check-installer-screens: FAIL only ${ndist:-0} distinct framebuffer frames captured (dialogs and progress bars expected)" >&2; rc=1; }
fi
if [ $rc = 0 ]; then
    if [ "$VARIANT" = server ]; then
        echo "UI CHECK PASS ($ARCH, Magnetar Server): every dialog names Magnetar Server, no Cygnus, no component dialog, no chatter, no blank console"
    else
        echo "UI CHECK PASS ($ARCH): dialogs branded, no chatter, no blank console after the component dialog"
    fi
else
    echo "UI CHECK FAIL ($ARCH)" >&2
fi
exit $rc
