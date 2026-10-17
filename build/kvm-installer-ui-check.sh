#!/bin/bash
# kvm-installer-ui-check.sh IMAGE ARCH WORKDIR -- boot the installer image under KVM as shipped (NO preset answers for the
# hostname/components prompts), answer the dialogs, and assert on what the operator SEES:
#   * the NCZ dialogs appear in the operator's order, branded (product, release, codename in the frame title) and with the arch/build line
#   * no [diag] / [ncz ...] chatter, no credential text, no "<ERR>", no askfirst prompt on the UI terminal
#   * the console is never blank after the component dialog (a progress bar or dialog stays up)
# arm64: the UI terminal is the serial port (auto=true picks the UART); amd64: the fbcon VT plus framebuffer sampling.
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
rm -rf "$WORK"; mkdir -p "$WORK"
if [ "$ARCH" = amd64 ]; then
    # amd64: the dialogs are drawn on the framebuffer console and cannot be read back from the VT once partman runs
    # them, so they are answered on a timer (Enter accepts hostname and components); judged on framebuffer sampling.
    "$PY" "$HERE/boot-screens.py" "$IMG" "$WORK" --arch "$ARCH" --interactive --secs "$SECS" --enter-every 6 --enter-after 25 \
        > "$WORK/harness.log" 2>&1 || { echo "UI CHECK FAIL: the capture harness failed (see $WORK/harness.log)" >&2; tail -5 "$WORK/harness.log" >&2; exit 1; }
else
    # The operator-required chooser order (preseed.cfg partman/early_command, 2026-10-06): region, username,
    # password, password confirm, components, then the target disk, root filesystem and erase confirmation;
    # the hostname is automatic. --ask-disk drops the ncz_disk/ncz_fs preset so the real disk dialogs are walked. Answer each one, otherwise the capture stalls on the first unanswered dialog. --interactive
    # also leaves passwd/* off the command line, so a d-i user-setup dialog sneaking back in before the NCZ ones
    # stalls the capture and fails the sequence. The HARDWARE SUMMARY note (preseed/hw-summary.sh) follows the
    # password confirm on an interactive install: Continue it, and require it in the sequence so a summary that
    # silently stops appearing is caught too. Rule 0 must stay the component dialog (T_ANS below). The password
    # is a throwaway for this capture only.
    "$PY" "$HERE/boot-screens.py" "$IMG" "$WORK" --arch "$ARCH" --interactive --secs "$SECS" --every 30 \
        --answer 'optional components=\r' --answer 'select your REGION=\r' --answer 'choose a USERNAME=\r' \
        --answer 'choose a PASSWORD=nczuicheck\r' --answer 'type the same PASSWORD=nczuicheck\r' \
        --answer 'HARDWARE SUMMARY=\r' \
        --ask-disk --answer 'select the TARGET DISK=\r' --answer 'root \(/\) filesystem=\r' \
        --answer "${NCZ_UI_CHECK_ERASE_RX:-ERASE /dev/vda and install}=${NCZ_UI_CHECK_ERASE_KEYS:-\x1b[D\r}" \
        > "$WORK/harness.log" 2>&1 \
        || { echo "UI CHECK FAIL: the capture harness failed (see $WORK/harness.log)" >&2; tail -5 "$WORK/harness.log" >&2; exit 1; }
fi
CHK=("$PY" "$HERE/check-installer-screens.py")
rc=0
if [ "$ARCH" = amd64 ]; then
    # Judged from the first frame (the bootloader menu). The framebuffer is blank once, right after it, while the
    # kernel and the initrd load (5-9 s depending on the host); that state may last up to 20 s. Every later blank is a
    # vanished UI unless it is a redraw shorter than --max-blank-secs.
    "${CHK[@]}" "$WORK/fb-states" --no-blank-after "framebuffer" --boot-blank-max-secs 20 2>&1 | tee "$WORK/fb-check.out"; [ "${PIPESTATUS[0]}" = 0 ] || rc=1
    # proof the installer really progressed on the framebuffer (dialogs and progress bars): many distinct frames
    ndist=$(awk '{print $2}' "$WORK/fb-frames.txt" 2>/dev/null | sort -u | wc -l | tr -d ' ')
    [ "${ndist:-0}" -ge 8 ] || { echo "check-installer-screens: FAIL only ${ndist:-0} distinct framebuffer frames captured (dialogs and progress bars expected)" >&2; rc=1; }
    # The amd64 harness has no text channel for the d-i dialogs (the fbcon VT reads back blank/banner text while the
    # framebuffer shows the dialog), so dialog titles, their order, the branded header, the operator prompt sequence,
    # the diagnostics login line and the boot-progress phases are NOT verified here. This is a structural limitation
    # of framebuffer-only sampling: even if a future/synthetic capture happened to extract one title, the checker
    # still cannot validate chatter/branding/order from framebuffer frames alone. So AMD is ALWAYS PASS-LIMITED when
    # its unchanged continuity/diversity checks succeed, and the unverified items are listed explicitly.
    # NCZ_UI_CHECK_REQUIRE_DIALOGS=1 rejects AMD in BOTH the zero-title and the nonzero-title case until an explicit
    # full contract (a real text channel) is implemented -- we do not invent OCR.
    if [ "${NCZ_UI_CHECK_REQUIRE_DIALOGS:-0}" = 1 ]; then
        echo "UI CHECK FAIL (amd64): NCZ_UI_CHECK_REQUIRE_DIALOGS=1 requires a full dialog contract (titles, order, branding, chatter) that framebuffer-only sampling cannot provide" >&2
        exit 1
    fi
    if [ $rc = 0 ]; then
        echo "UI CHECK PASS-LIMITED (amd64): framebuffer continuity and diversity only" >&2
        echo "UI CHECK PASS-LIMITED (amd64): UNVERIFIED: dialog chatter, dialog titles/order, branding, prompt sequence, diagnostics login line, boot-progress phases" >&2
        exit 0
    fi
else
    "${CHK[@]}" "$WORK/serial-screens" --start-at "select your REGION" \
        --require-dialog "optional components" --require-dialog "select your REGION" \
        --require-dialog "choose a USERNAME" \
        --require-prompt-sequence "select your REGION" "choose a USERNAME" \
            "choose a PASSWORD" "type the same PASSWORD" "HARDWARE SUMMARY" "optional components" \
            "select the TARGET DISK" "root \(/\) filesystem" "ERASE /dev/vda and install" \
        --require-header "NCZ-OS [0-9.]+ [A-Za-z]+" --min-states 20 --min-dialogs 5 \
        --require-login-line "diagnostics login: root / (set by ncz_diag_pw|\S{4,})" || rc=1
    T_ANS="$(sed -n 's/^t=\([0-9]*\)s rule 0 .*/\1/p' "$WORK/answers.log" | head -1)"
    [ -n "$T_ANS" ] || { echo "UI CHECK FAIL: the component dialog was never reached/answered" >&2; exit 1; }
    "${CHK[@]}" "$WORK/serial-screens" --start-at "optional components" --no-blank-after "optional components" || rc=1
    # The dialogs above are answered with Enter only, so the install must go ahead with the DEFAULTS: every
    # optional component selected (a select/multiselect whose Choices-C holds labels instead of values returns
    # labels, which parse as "none" -- the 2026-10-17 CHIMERA failure) and the offered disk accepted.
    grep -a -q "chooser complete: components=.*desktop" "$WORK/serial0.log" \
        || { echo "UI CHECK FAIL: Enter on the component dialog did not keep the default (all components); see serial0.log" >&2; rc=1; }
    grep -a -q "operator CONFIRMED erasing /dev/vda" "$WORK/serial0.log" \
        || { echo "UI CHECK FAIL: the disk, filesystem and erase dialogs did not lead to a confirmed target (see serial0.log)" >&2; rc=1; }
    if grep -a -q "not in the candidate set" "$WORK/serial0.log"; then
        echo "UI CHECK FAIL: the disk chooser rejected its own answer (Choices/Choices-C swapped?)" >&2; rc=1
    fi
fi
if [ $rc = 0 ]; then
    echo "UI CHECK PASS ($ARCH): dialogs branded, no chatter, no blank console after the component dialog"
else
    echo "UI CHECK FAIL ($ARCH)" >&2
fi
exit $rc
