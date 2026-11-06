#!/bin/bash
# substrate-ci.sh -- entry point for the automatic substrate CI.
#
# Design: docs/automatic-substrate-ci.md. This is the stage driver the pipeline
# calls; the decision logic lives in build/substrate-ci.py and the individual
# resolvers are the existing tools named in the plan below.
#
# Safety rule, and the reason this wrapper exists rather than the pipeline calling
# python directly: stages that MOVE A PIN refuse to run unless --apply is given, and
# the stages that are not implemented yet refuse even then. A CI job cannot move a
# pin by accident, and it cannot silently no-op a stage it thinks it ran.
#
# Usage:
#   substrate-ci.sh                 # stage 0 preflight, read-only (default)
#   substrate-ci.sh --stage plan    # print what every stage would do
#   substrate-ci.sh --stage preflight --json
#   substrate-ci.sh --stage propose --apply   # refuses: not implemented
#
# Exit codes: 0 proceed/degraded (see the JSON), 2 hard stop (expired or broken pin),
# 1 usage or tool error, 3 stage not implemented or --apply missing.
set -uo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

STAGE=preflight
APPLY=0
JSON=0

while [ $# -gt 0 ]; do
    case "$1" in
        --stage)   STAGE="${2:-}"; shift 2 ;;
        --stage=*) STAGE="${1#*=}"; shift ;;
        --apply)   APPLY=1; shift ;;
        --json)    JSON=1; shift ;;
        -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "substrate-ci: unknown argument '$1'" >&2; exit 1 ;;
    esac
done

pin_age() {
    # Days since the pinned snapshot timestamp, derived from the snapshot id itself
    # (YYYYMMDDThhmmssZ). Cheap and offline; the CI's authoritative measure is the
    # deriver's own freshness check.
    local snap
    snap="$(awk -F'\t' '!/^#/ && $1=="amd64"{print $4; exit}' "$ROOT/manifests/base.pin" 2>/dev/null)"
    [ -n "$snap" ] || return 1
    local y=${snap:0:4} mo=${snap:4:2} d=${snap:6:2} h=${snap:9:2} mi=${snap:11:2} s=${snap:13:2}
    local then_s now_s
    then_s=$(date -u -d "${y}-${mo}-${d} ${h}:${mi}:${s}" +%s 2>/dev/null) || return 1
    now_s=$(date -u +%s)
    echo $(( (now_s - then_s) / 86400 ))
}

case "$STAGE" in
    preflight)
        base="${NCZ_BASE_MIRROR:-}"
        if [ -z "$base" ] && [ -r "$ROOT/release.conf" ]; then
            # release.conf derives NCZ_BASE_MIRROR from the pinned snapshot, so the
            # driver works from a plain checkout rather than needing a sourced shell.
            # shellcheck source=/dev/null
            . "$ROOT/release.conf"
            base="${NCZ_BASE_MIRROR:-}"
        fi
        if [ -z "$base" ]; then
            echo "substrate-ci: NCZ_BASE_MIRROR is unset and release.conf is unreadable" >&2
            exit 1
        fi
        age="$(pin_age || true)"
        args=(preflight --base "$base")
        [ -n "$age" ] && args+=(--pin-age-days "$age")
        [ "$JSON" = 1 ] && args+=(--json)
        python3 -I "$HERE/substrate-ci.py" "${args[@]}"
        exit $?
        ;;

    plan)
        cat <<'PLAN'
substrate-ci stages (docs/automatic-substrate-ci.md)

  0 preflight  IMPLEMENTED  build/substrate-ci.py preflight - mirror health, pin age
  1 resolve    TODO         derive-base-pin.py, resolve-sky1-kernel-inputs.sh,
                            singularity-pins.sh propose, runtime-mirror revs
  2 prove      IMPLEMENTED  build/substrate-ci.py aggregate - coverage, one snapshot,
                            two-host InRelease digests
  3 propose    IMPLEMENTED  build/substrate-ci.py changelog + apply-pin (transactional)
  4-5 build    TODO         rootfs + image per arch on the build hosts
  6 gate       TODO         existing gate scripts, aggregated
  7 decide     IMPLEMENTED  build/substrate-ci.py decide - auto-merge or open an MR
  8 retain     IMPLEMENTED  build/substrate-ci.py retention

A pin move needs --apply. Until stages 1, 4-6 exist, --apply exits 3 rather than
pretending the stage ran.
PLAN
        exit 0
        ;;

    propose|build|gate)
        if [ "$APPLY" != 1 ]; then
            echo "substrate-ci: stage '$STAGE' moves a pin; refusing without --apply" >&2
            exit 3
        fi
        echo "substrate-ci: stage '$STAGE' is not implemented yet (see --stage plan)" >&2
        exit 3
        ;;

    *)
        echo "substrate-ci: unknown stage '$STAGE' (see --stage plan)" >&2
        exit 1
        ;;
esac
