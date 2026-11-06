#!/bin/bash
# check-payload-ships-patches.sh DEB
#
# A green PAYLOAD_RC=0 says the tree compiled; it says nothing about what was
# staged. On 2026-11-06 the payload built cleanly while the packaged loginui was
# the boot-splash bundle's unpatched copy, because that repo installs its own
# loginui AFTER the superproject and overwrote ours. Every gate was green and a
# ported feature was absent from the artifact.
#
# This checks the artifact instead of the build: it extracts the installed header
# and static archive from the .deb and looks for the symbols our patch queue adds.
# Add a row to EXPECTED when a patch introduces a new externally visible name.
#
# Exit 0 = every expected symbol is present, 1 = anything missing, 2 = usage/setup.
set -uo pipefail

DEB=${1:?usage: check-payload-ships-patches.sh DEB}
[ -r "$DEB" ] || { echo "cannot read $DEB" >&2; exit 2; }

# <symbol> <where: header|archive> <patch that adds it>
EXPECTED=(
    "loginui_field_label header singularity-loginui/0003"
    "loginui_field_label archive singularity-loginui/0003"
)

WORK=$(mktemp -d "${TMPDIR:-/tmp}/ncz-payload-check.XXXXXX") || exit 2
trap 'rm -rf "$WORK"' EXIT
dpkg-deb -x "$DEB" "$WORK" 2>/dev/null || { echo "dpkg-deb -x failed" >&2; exit 2; }

HDR="$WORK/opt/singularity/include/loginui.h"
LIB="$WORK/opt/singularity/lib/libloginui.a"

fail=0
for row in "${EXPECTED[@]}"; do
    set -- $row
    sym=$1; where=$2; patch=$3
    case "$where" in
        header)
            if [ -f "$HDR" ] && grep -q "$sym" "$HDR"; then
                echo "OK   $sym declared in include/loginui.h ($patch)"
            else
                echo "FAIL $sym missing from include/loginui.h ($patch)"; fail=1
            fi
            ;;
        archive)
            # nm exits non-zero when any archive member has no symbols, and this
            # script runs with pipefail - so capture first, then match.
            _syms=""
            [ -f "$LIB" ] && _syms=$(nm --defined-only "$LIB" 2>/dev/null || true)
            if printf "%s\n" "$_syms" | grep -w  "$sym" >/dev/null; then
                echo "OK   $sym defined in lib/libloginui.a ($patch)"
            else
                echo "FAIL $sym not defined in lib/libloginui.a ($patch)"; fail=1
            fi
            ;;
        *) echo "FAIL unknown where '$where'"; fail=1 ;;
    esac
done

if [ "$fail" -ne 0 ]; then
    echo "---- payload does NOT ship the ported patches it claims"
    exit 1
fi
echo "---- payload ships every symbol the queue adds"
