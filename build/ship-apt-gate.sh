#!/bin/bash
# ship-apt-gate.sh -- the apt live-repo gate of build/ship-image.sh, in its own script so it is testable.
#
# Ship mode is FAIL and cannot be weakened by the environment: NCZ_APT_LIVE_GATE (which a build session may
# have exported as warn/skip for preflight) is IGNORED here. The only way to weaken it is the dedicated, loud
# override NCZ_SHIP_ALLOW_APT_GATE_OVERRIDE=1 together with NCZ_APT_LIVE_GATE=warn|skip. An unreachable or
# empty live index is a failure in ship mode (no verdict, no shipment).
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
if [ "${NCZ_SHIP_ALLOW_APT_GATE_OVERRIDE:-0}" = 1 ] && [ -n "${NCZ_APT_LIVE_GATE:-}" ]; then
    echo "ship-apt-gate: WARNING *** the apt live-repo ship gate is OVERRIDDEN to '${NCZ_APT_LIVE_GATE}' (NCZ_SHIP_ALLOW_APT_GATE_OVERRIDE=1) ***" >&2
    exec bash "$HERE/apt-live-gate.sh" fail
fi
[ -z "${NCZ_APT_LIVE_GATE:-}" ] || echo "ship-apt-gate: ignoring NCZ_APT_LIVE_GATE=${NCZ_APT_LIVE_GATE} (ship mode is always fail; see NCZ_SHIP_ALLOW_APT_GATE_OVERRIDE)" >&2
exec env -u NCZ_APT_LIVE_GATE bash "$HERE/apt-live-gate.sh" fail
