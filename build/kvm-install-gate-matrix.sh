#!/bin/bash
# kvm-install-gate-matrix.sh -- run build/kvm-install-gate-gpt.sh once per
# install-option set, so the options the installer's component dialog offers
# are each installed and booted, not only the all-selected default.
#
# The single gate always answered the dialog with every option selected, so an
# install with the rescue partition unticked was never exercised -- and that
# install failed in 70-bootloader.sh on real hardware (the boot-menu refresh
# required the rescue partition whether or not it had been selected). Each set
# below is a separate gate run in its own work directory.
#
# Usage: build/kvm-install-gate-matrix.sh IMAGE [WORKROOT] [SET...]
#   SET is a name from the table below, or `all`. Default: the sets in
#   NCZ_KVM_GATE_VARIANTS, else "norescue minimal stalefs" (the sets that
#   build-image.sh runs after the full-option gate).
#
#   full           desktop,mgmt-container,rescue-partition   (every option)
#   norescue       desktop                                   (rescue off + mgmt off)
#   norescue-mgmt  desktop,mgmt-container                    (rescue off + mgmt on)
#   nodesktop      mgmt-container,rescue-partition           (desktop off)
#   minimal        none                                      (every option off: console system)
#   stalefs        desktop,mgmt-container,rescue-partition   (btrfs root, reinstall over an old
#                                                             ext4 install: NCZ_GATE_STALE_DISK=1)
#   server         rescue-partition                          (MAGNETAR: a SERVER image installs over
#                                                             the gate's own HTTP payload server;
#                                                             requires a server image, refused on
#                                                             desktop media)
#   server-offline-negative  rescue-partition                (NEGATIVE: same server image, the payload
#                                                             server is NOT started; the install must
#                                                             fail loudly within the deadline and
#                                                             leave no rootfs on the target)
#
# Only `full` runs the installer UI check (it does not depend on the options).
# A passing set's disk images are removed to keep the work root small
# (NCZ_GATE_KEEP=1 keeps them); a failing set keeps everything for inspection.
# Every set runs even after a failure; the summary is WORKROOT/matrix.tsv.
# Exit 0 = every set passed, 1 = at least one failed, 2 = bad invocation.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
IMG="${1:?usage: kvm-install-gate-matrix.sh IMAGE.img [WORKROOT] [SET...]}"
shift
WORKROOT="${1:-}"
[ "$#" -gt 0 ] && shift
[ -n "$WORKROOT" ] || WORKROOT="$HOME/kvm-install-matrix"
[ -f "$IMG" ] || { echo "MATRIX FAIL: no such image: $IMG" >&2; exit 2; }

# NCZ-GATE-SETS-BEGIN
gate_set_components() {
    case "$1" in
        full)          echo "desktop,mgmt-container,rescue-partition" ;;
        norescue)      echo "desktop" ;;
        norescue-mgmt) echo "desktop,mgmt-container" ;;
        nodesktop)     echo "mgmt-container,rescue-partition" ;;
        minimal)       echo "none" ;;
        stalefs)       echo "desktop,mgmt-container,rescue-partition" ;;
        server)        echo "rescue-partition" ;;
        server-offline-negative) echo "rescue-partition" ;;
        *)             return 1 ;;
    esac
}
# Per-set gate server mode: "server" runs the Magnetar server gate (the gate
# serves the payload over its own HTTP server), "server-offline-negative"
# runs the NEGATIVE half (server off, install must fail loud+bounded with no
# rootfs written). "<off 0|1>" for the other sets = plain desktop gate.
gate_set_server() {
    case "$1" in
        server)                  echo "1 0" ;;
        server-offline-negative) echo "1 1" ;;
        *)                       echo "0 0" ;;
    esac
}
# Root filesystem and disk preparation per set: "<fs> <stale 0|1>".
gate_set_disk() {
    case "$1" in
        stalefs) echo "btrfs 1" ;;
        *)       echo "ext4 0" ;;
    esac
}
GATE_ALL_SETS="full norescue norescue-mgmt nodesktop minimal stalefs server server-offline-negative"
GATE_DEFAULT_SETS="norescue minimal stalefs"
# NCZ-GATE-SETS-END

SETS="$*"
[ -n "$SETS" ] || SETS="${NCZ_KVM_GATE_VARIANTS:-$GATE_DEFAULT_SETS}"
[ "$SETS" = all ] && SETS="$GATE_ALL_SETS"
for _s in $SETS; do
    gate_set_components "$_s" >/dev/null || { echo "MATRIX FAIL: unknown option set '$_s' (known: $GATE_ALL_SETS, all)" >&2; exit 2; }
done

# Never a tmpfs: each set copies the multi-GiB image and creates a target disk.
mkdir -p "$WORKROOT"
# Run as root by build-image.sh: hand the work root back to the invoking user on
# every exit path (same as the gate itself), so the run dir stays deletable.
. "$SCRIPT_DIR/lib/priv.sh" 2>/dev/null || true
if declare -F ncz_trap_chown_back >/dev/null 2>&1; then ncz_trap_chown_back "$WORKROOT"; fi
_fst=$(findmnt -no FSTYPE -T "$WORKROOT" 2>/dev/null || true)
case "$_fst" in tmpfs|ramfs) echo "MATRIX FAIL: $WORKROOT is on $_fst; use a directory on disk" >&2; exit 2 ;; esac

SUMMARY="$WORKROOT/matrix.tsv"
printf 'set\tcomponents\tresult\tseconds\twork\tcoverage\n' > "$SUMMARY"
FAILED=""
for _s in $SETS; do
    _c=$(gate_set_components "$_s")
    read -r _fs _stale <<EOF_DISK
$(gate_set_disk "$_s")
EOF_DISK
    read -r _srv _srv_off <<EOF_SRV
$(gate_set_server "$_s")
EOF_SRV
    _w="$WORKROOT/$_s"
    _ui=0; [ "$_s" = full ] && _ui="${NCZ_GATE_UI_CHECK:-1}"
    _coverage=target-logs-and-verifier
    [ "$_fs" = ext4 ] || _coverage=SKIP-target-logs-and-verifier
    [ "$_ui" != 0 ] || _coverage="$_coverage;SKIP-UI"
    [ "$_srv" = 1 ] && _coverage="$_coverage;server-variant"
    echo
    if [ "$_srv" = 1 ]; then
        echo "################ server set: $_s ($_c, root $_fs, payload server $([ "$_srv_off" = 1 ] && echo OFF || echo ON)) ################"
    else
        echo "################ install-option set: $_s ($_c, root $_fs, stale disk $_stale) ################"
    fi
    _t0=$(date +%s)
    _rc=0
    NCZ_GATE_COMPONENTS="$_c" NCZ_GATE_UI_CHECK="$_ui" NCZ_GATE_FS="$_fs" NCZ_GATE_STALE_DISK="$_stale" \
        NCZ_GATE_SERVER="$_srv" NCZ_GATE_SERVER_OFFLINE="$_srv_off" \
        bash "$SCRIPT_DIR/kvm-install-gate-gpt.sh" "$IMG" "$_w" 2>&1 | tee "$WORKROOT/$_s.log"
    _rc="${PIPESTATUS[0]}"
    _dt=$(( $(date +%s) - _t0 ))
    if [ "$_rc" = 0 ] && { grep -q '^GATE PASS' "$WORKROOT/$_s.log" || grep -q '^GATE PASS (server-offline-negative)' "$WORKROOT/$_s.log"; }; then
        printf '%s\t%s\tPASS\t%s\t%s\t%s\n' "$_s" "$_c" "$_dt" "$_w" "$_coverage" >> "$SUMMARY"
        if [ "${NCZ_GATE_KEEP:-0}" != 1 ]; then
            rm -f "$_w"/*-qemutest.img "$_w/target.qcow2" "$_w/OVMF_VARS.fd"
        fi
    else
        printf '%s\t%s\tFAIL(rc=%s)\t%s\t%s\t%s\n' "$_s" "$_c" "$_rc" "$_dt" "$_w" "$_coverage" >> "$SUMMARY"
        FAILED="$FAILED $_s"
    fi
done

echo
echo "=== install-option matrix ($(basename "$IMG")) ==="
column -t -s "$(printf '\t')" "$SUMMARY" 2>/dev/null || cat "$SUMMARY"
if [ -n "$FAILED" ]; then
    echo "MATRIX FAIL:$FAILED (logs: $WORKROOT/<set>.log, work dirs kept)" >&2
    exit 1
fi
echo "MATRIX PASS: $SETS"
exit 0
