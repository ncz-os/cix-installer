#!/bin/bash
# ship-image.sh -- publish a GATED image: ARGONAS archive + the operator Mac (.4) ~/Downloads, verify sha256 at each
# destination, record the gate marker, then show (or, with --reap-apply, perform) the reap of superseded images.
#
#   ship-image.sh IMAGE [--gate-log FILE] [--reap-apply] [--no-mac]
#
# Password auth (operator policy: every LAN host reachable by password, no key dependence): the .4 copy uses
# `sshpass -e` with SSHPASS read from $NCZ_FLEET_PASS_FILE (default ~/.config/ncz/fleet.pass, mode 0600); the
# value is never printed or placed on a command line.
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
IMG=""; GATELOG=""; REAP_APPLY=0; MAC=1
while [ $# -gt 0 ]; do
    case "$1" in
        --gate-log) GATELOG="$2"; shift 2 ;;
        --reap-apply) REAP_APPLY=1; shift ;;
        --no-mac) MAC=0; shift ;;
        *) IMG="$1"; shift ;;
    esac
done
[ -f "$IMG" ] || { echo "ship-image: no such image: $IMG" >&2; exit 2; }
ARCHIVE="${NCZ_IMAGE_ARCHIVE:-/mnt/argonas-projects/ncz-os-assets/images}"
MAC_DEST="${NCZ_MAC_DEST:-jperlow@192.168.207.4}"
PASSFILE="${NCZ_FLEET_PASS_FILE:-$HOME/.config/ncz/fleet.pass}"
NAME="$(basename "$IMG")"; ARCH="$(echo "$NAME" | sed -n 's/^ncz-os-\([a-z0-9]*\)-.*/\1/p')"
[ -n "$ARCH" ] || { echo "ship-image: cannot derive the architecture from $NAME" >&2; exit 2; }
[ -n "$GATELOG" ] && grep -q "GATE PASS (phase 1+2)" "$GATELOG" || { echo "ship-image: refusing: --gate-log must be a log containing 'GATE PASS (phase 1+2)'" >&2; exit 3; }
SHA="$(sha256sum "$IMG" | cut -d' ' -f1)"
echo "ship-image: $NAME sha256=$SHA"
echo "$SHA  $NAME" > "$IMG.sha256"
bash "$HERE/reap-images.sh" --mark-gated "$IMG" --note "KVM install gate PASS; log $(basename "$GATELOG")" >/dev/null
# 1. ARGONAS archive
mkdir -p "$ARCHIVE" && cp "$IMG" "$IMG.sha256" "$IMG.gated" "$ARCHIVE/" && { [ -f "$IMG.receipt.json" ] && cp "$IMG.receipt.json" "$ARCHIVE/"; }
got="$(sha256sum "$ARCHIVE/$NAME" | cut -d' ' -f1)"
[ "$got" = "$SHA" ] && echo "  ARGONAS archive OK ($ARCHIVE)" || { echo "  ARGONAS copy sha256 MISMATCH" >&2; exit 4; }
# 2. the operator Mac
if [ "$MAC" = 1 ]; then
    [ -r "$PASSFILE" ] || { echo "ship-image: no fleet password file at $PASSFILE (0600)" >&2; exit 5; }
    export SSHPASS="$(cat "$PASSFILE")"
    OPTS=(-o PubkeyAuthentication=no -o StrictHostKeyChecking=no -o ConnectTimeout=10)
    sshpass -e scp "${OPTS[@]}" "$IMG" "$IMG.sha256" "$IMG.receipt.json" "$MAC_DEST:Downloads/" || { echo "  scp to $MAC_DEST failed" >&2; exit 6; }
    rsha="$(sshpass -e ssh "${OPTS[@]}" "$MAC_DEST" "shasum -a 256 Downloads/$NAME | cut -d' ' -f1")"
    unset SSHPASS
    [ "$rsha" = "$SHA" ] && echo "  $MAC_DEST:~/Downloads OK (sha256 verified)" || { echo "  Mac copy sha256 MISMATCH ($rsha)" >&2; exit 7; }
fi
# 3. reap superseded images of this arch (dry run unless --reap-apply)
ARGS=(--arch "$ARCH" --archive "$ARCHIVE" --dir "$(dirname "$(readlink -f "$IMG")")")
if [ "$MAC" = 1 ]; then   # also reap on the Mac (password auth through the same wrapper)
    export SSHPASS="$(cat "$PASSFILE")"
    export SSH="sshpass -e ssh -o PubkeyAuthentication=no -o StrictHostKeyChecking=no -o ConnectTimeout=10"
    ARGS+=(--remote "$MAC_DEST:Downloads")
fi
[ $REAP_APPLY = 1 ] && ARGS+=(--apply)
bash "$HERE/reap-images.sh" "${ARGS[@]}"; rc=$?
unset SSHPASS
exit $rc
