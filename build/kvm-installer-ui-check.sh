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
    # password, password confirm, components; the hostname is automatic and the disk dialogs stay preset
    # (ncz_disk/ncz_fs). Answer each one, otherwise the capture stalls on the first unanswered dialog. --interactive
    # also leaves passwd/* off the command line, so a d-i user-setup dialog sneaking back in before the NCZ ones
    # stalls the capture and fails the sequence. Rule 0 must stay the component dialog (T_ANS below). The password
    # is a throwaway for this capture only.
    "$PY" "$HERE/boot-screens.py" "$IMG" "$WORK" --arch "$ARCH" --interactive --secs "$SECS" --every 30 \
        --answer 'optional components=\r' --answer 'select your REGION=\r' --answer 'choose a USERNAME=\r' \
        --answer 'choose a PASSWORD=nczuicheck\r' --answer 'type the same PASSWORD=nczuicheck\r' \
        > "$WORK/harness.log" 2>&1 \
        || { echo "UI CHECK FAIL: the capture harness failed (see $WORK/harness.log)" >&2; tail -5 "$WORK/harness.log" >&2; exit 1; }
fi
CHK=("$PY" "$HERE/check-installer-screens.py")
rc=0
if [ "$ARCH" = amd64 ]; then
    # the framebuffer never goes blank (the bootloader's text stays up until the installer draws)
    "${CHK[@]}" "$WORK/fb-states" --no-blank-after "framebuffer" || rc=1
    # proof the installer really progressed on the framebuffer (dialogs and progress bars): many distinct frames
    ndist=$(awk '{print $2}' "$WORK/fb-frames.txt" 2>/dev/null | sort -u | wc -l | tr -d ' ')
    [ "${ndist:-0}" -ge 8 ] || { echo "check-installer-screens: FAIL only ${ndist:-0} distinct framebuffer frames captured (dialogs and progress bars expected)" >&2; rc=1; }
else
    "${CHK[@]}" "$WORK/serial-screens" --start-at "select your REGION" \
        --require-dialog "optional components" --require-dialog "select your REGION" \
        --require-dialog "choose a USERNAME" \
        --require-prompt-sequence "select your REGION" "choose a USERNAME" \
            "choose a PASSWORD" "type the same PASSWORD" "optional components" \
        --require-header "NCZ-OS [0-9.]+ [A-Za-z]+" --min-states 20 || rc=1
    T_ANS="$(sed -n 's/^t=\([0-9]*\)s rule 0 .*/\1/p' "$WORK/answers.log" | head -1)"
    [ -n "$T_ANS" ] || { echo "UI CHECK FAIL: the component dialog was never reached/answered" >&2; exit 1; }
    "${CHK[@]}" "$WORK/serial-screens" --start-at "optional components" --no-blank-after "optional components" || rc=1
fi
[ $rc = 0 ] && echo "UI CHECK PASS ($ARCH): dialogs branded, no chatter, no blank console after the component dialog" || echo "UI CHECK FAIL ($ARCH)" >&2
exit $rc
