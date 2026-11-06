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
#   substrate-ci.sh --stage gate    # run the gates that can run here (read-only)
#   substrate-ci.sh --stage propose --apply   # writes the pin move (dry run otherwise)
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
  1 resolve    PARTIAL      singularity runs for real (candidate heads vs our pins);
                            derive-base-pin.py, resolve-sky1-kernel-inputs.sh and the
                            runtime-mirror revs are still only existence-checked
  2 prove      IMPLEMENTED  build/substrate-ci.py aggregate - coverage, one snapshot,
                            two-host InRelease digests
  3 propose    IMPLEMENTED  build/substrate-ci.py changelog + apply-pin (transactional)
  4-5 build    TODO         rootfs + image per arch on the build hosts
  6 gate       PARTIAL      runs the gates that can run HERE (repo policy --live,
                            substrate pin, payload acceptance when the artifact is
                            present) and aggregates them: skip is not pass. Read-only.
                            Not wired yet: patch drift, payload ABI, image/metal
  7 decide     IMPLEMENTED  build/substrate-ci.py decide - auto-merge or open an MR
  8 retain     IMPLEMENTED  build/substrate-ci.py retention

A pin move needs --apply. Until stages 1, 4-6 exist, --apply exits 3 rather than
pretending the stage ran.
PLAN
        exit 0
        ;;

    resolve)
        # Stage 1 is not implemented yet, but its plan is still checkable: every tool
        # the design note names must exist, or the plan is fiction. This is the same
        # discipline as the acceptance gate - verify the thing, not the intention.
        rows=(
            "debian-forky|build/derive-base-pin.py"
            "kernel-firmware|build/resolve-sky1-kernel-inputs.sh"
            "kernel-pin|build/check-kernel-deb-pin.sh"
            "singularity|build/singularity-pins.sh"
            "ncz-repo-policy|build/check-ncz-repo-policy.sh"
        )
        missing=0
        for r in "${rows[@]}"; do
            name="${r%%|*}"; tool="${r#*|}"
            if [ -x "$ROOT/$tool" ]; then
                printf "OK   %-16s %s\n" "$name" "$tool"
            else
                printf "MISS %-16s %s\n" "$name" "$tool"
                missing=$((missing + 1))
            fi
        done
        if [ "$APPLY" = 1 ]; then
            echo "substrate-ci: stage 'resolve' is not implemented yet (see --stage plan)" >&2
            exit 3
        fi
        if [ "$missing" -ne 0 ]; then
            echo "substrate-ci: $missing resolver tool(s) missing - the plan names what the tree does not have" >&2
            exit 4
        fi

        # Singularity is the one resolver cheap enough to run inline: one clone plus
        # ls-remotes. Resolving candidates is read-only - moving a pin is stage 3.
        echo
        echo "== singularity: candidate heads vs our pins =="
        _cand="$(mktemp "${TMPDIR:-/tmp}/ncz-resolve.XXXXXX")" || exit 1
        if TMPDIR="${TMPDIR:-/tmp}" bash "$ROOT/build/singularity-pins.sh" propose > "$_cand" 2>/dev/null; then
            python3 -I - "$ROOT/assets/singularity/upstream-pins.tsv" "$_cand" <<'PYEOF'
import sys
cur_path, cand_path = sys.argv[1], sys.argv[2]

def read(p):
    out = {}
    for line in open(p, encoding="utf-8", errors="replace"):
        if line.startswith("#") or not line.strip():
            continue
        f = line.rstrip("\n").split("\t")
        if len(f) >= 4:
            out[f[0]] = {"url": f[1], "branch": f[2], "sha": f[3]}
    return out

cur, cand = read(cur_path), read(cand_path)
moved = []
for path, c in sorted(cand.items()):
    if path not in cur:
        moved.append((path, "NEW", c["sha"][:12]))
    elif cur[path]["sha"] != c["sha"]:
        moved.append((path, cur[path]["sha"][:12], c["sha"][:12]))
print("%d candidate rows, %d differ from the pins" % (len(cand), len(moved)))
for path, a, b in moved[:12]:
    print("  %-40s %s -> %s" % (path[:40], a, b))
if len(moved) > 12:
    print("  ... and %d more" % (len(moved) - 12))
PYEOF
        else
            echo "  WARN: propose failed; the singularity candidates are unknown this run"
        fi
        rm -f "$_cand"
        echo "---- resolution is read-only; other subsystems are still TODO"
        exit 0
        ;;

    propose|build)
        if [ "$APPLY" != 1 ]; then
            echo "substrate-ci: stage '$STAGE' moves a pin; refusing without --apply" >&2
            exit 3
        fi
        echo "substrate-ci: stage '$STAGE' is not implemented yet (see --stage plan)" >&2
        exit 3
        ;;

    gate)
        # Stage 6 runs the gates that can run HERE and aggregates them with the same rule
        # stage 2 uses: a gate that did not run is not a pass, and an empty suite proves
        # nothing. Read-only by construction - this stage never writes a pin, so --apply
        # is not accepted rather than silently ignored.
        if [ "$APPLY" = 1 ]; then
            echo "substrate-ci: stage 'gate' is read-only; it has nothing to apply" >&2
            exit 3
        fi
        # Extraction needs room, and a QUOTA ERROR inside a check reads as a gate
        # failure: dpkg-deb -x died at 40 MB on a full /tmp and the acceptance gate
        # then reported "payload does not ship the patches" about a payload it never
        # fully unpacked. So the gate suite gets its own TMPDIR on real disk.
        _ci_tmp="${NCZ_CI_TMPDIR:-$HOME/.cache/ncz-ci-tmp}"
        if mkdir -p "$_ci_tmp" 2>/dev/null && [ -w "$_ci_tmp" ]; then
            export TMPDIR="$_ci_tmp"
        else
            echo "WARN: cannot use $_ci_tmp; falling back to ${TMPDIR:-/tmp} - an extraction may fail" >&2
        fi
        _t="$(mktemp "${TMPDIR}/ncz-gates.XXXXXX.tsv")" || exit 1
        _log="$(mktemp "${TMPDIR}/ncz-gates.XXXXXX.log")" || exit 1
        _spec="$(mktemp "${TMPDIR}/ncz-gates.XXXXXX.json")" || exit 1
        trap 'rm -f "$_t" "$_log" "$_spec"' EXIT

        _gate() {  # name command...
            local name="$1"; shift
            local status fail
            if "$@" >"$_log" 2>&1; then
                status=pass
                printf 'PASS %-20s %s\n' "$name" "$(tail -1 "$_log" | tr -d '\t')"
            else
                status=fail
                fail="$(grep -c '^FAIL' "$_log" 2>/dev/null || true)"
                printf 'FAIL %-20s %s\n' "$name" "$(tail -1 "$_log" | tr -d '\t')"
            fi
            printf '%s\t%s\t%s\n' "$name" "$status" "$(tail -1 "$_log" | tr -d '\t"')" >> "$_t"
        }

        echo "== stage 6: gate suite (read-only) =="
        # Strict on reachability: a gate that cannot reach the live indexes has not
        # proven anything, and the aggregation counts "did not run" as a failure.
        _gate repo-policy env NCZ_LIVE_REQUIRE_REACHABLE=1 bash "$ROOT/build/check-ncz-repo-policy.sh" --live
        _gate substrate-pin bash "$ROOT/build/check-substrate-pin.sh"

        # The acceptance gate proves the ARTIFACT, so identify the pinned artifact by
        # name AND digest. Any .deb in the output directory is not the pin: running the
        # gate against a stale build reports "patches missing" about a payload nobody
        # shipped, which is a gate that lies. Name-only is the other trap - a rebuilt
        # deb under the pinned name would pass without being the pinned bytes.
        _arch="$(dpkg --print-architecture 2>/dev/null || uname -m)"
        _pin_row() {  # arch -> "name<TAB>sha" from the committed pin, never guessed
            awk -F'\t' -v a="$1" '$1==a{printf "%s\t%s\n", $3, $2; exit}' \
                "$ROOT/manifests/singularity-payload.tsv" 2>/dev/null
        }
        _deb="${NCZ_PAYLOAD_DEB:-}"
        if [ -z "$_deb" ]; then
            _host_name="$(_pin_row "$_arch" | cut -f1)"
            [ -n "$_host_name" ] && _deb="$ROOT/build/sinty-out/$_host_name"
        fi
        if [ -n "$_deb" ] && [ -f "$_deb" ]; then
            # The artifact's own name says which arch's row it must match, so an
            # explicitly supplied deb is judged against ITS pin, not the host's.
            _darch="$(basename "$_deb" | sed -n 's/.*_\(amd64\|arm64\)\.deb$/\1/p')"
            [ -n "$_darch" ] || _darch="$_arch"
            _row="$(_pin_row "$_darch")"
            _pin_name="$(printf '%s' "$_row" | cut -f1)"
            _pin_sha="$(printf '%s' "$_row" | cut -f2)"
            _have="$(sha256sum "$_deb" 2>/dev/null | cut -d' ' -f1)"
            if [ "$_have" = "$_pin_sha" ]; then
                _gate payload-acceptance bash "$ROOT/build/check-payload-ships-patches.sh" "$_deb"
            else
                # Present but not the pin: a real fault, not a skip - either the artifact
                # was overwritten or the pin was never rebuilt. Name-only would hide both.
                printf 'FAIL %-20s %s\n' payload-acceptance "artifact is not the pinned payload (sha ${_have:0:12} != ${_pin_sha:0:12})"
                printf 'payload-acceptance\tfail\tartifact is not the pinned payload (sha %s != %s)\n' "${_have:0:12}" "${_pin_sha:0:12}" >> "$_t"
            fi
        else
            # Not a pass: the acceptance gate proves the ARTIFACT, and this host has no
            # pinned artifact. Aggregation turns this into a blocker, which is honest.
            _stale="$(ls "$ROOT"/build/sinty-out/*.deb 2>/dev/null | xargs -r -n1 basename 2>/dev/null | tr '\n' ' ')"
            printf 'SKIP %-20s pinned %s not on this host (%s); present: %s\n' \
                payload-acceptance "${_host_name:-<no pin for $_arch>}" "$_arch" "${_stale:-none}"
            printf 'payload-acceptance\tskip\tpinned %s not on this host (%s)\n' "${_host_name:-<no pin for $_arch>}" "$_arch" >> "$_t"
        fi

        python3 -I - "$_t" "$_spec" <<'PYJSON'
import json, sys
rows = []
for line in open(sys.argv[1], encoding="utf-8"):
    parts = line.rstrip("\n").split("\t")
    if len(parts) >= 2 and parts[0]:
        rows.append({"name": parts[0], "status": parts[1],
                     "detail": parts[2] if len(parts) > 2 else ""})
json.dump(rows, open(sys.argv[2], "w", encoding="utf-8"), indent=2)
PYJSON
        echo
        python3 -I "$HERE/substrate-ci.py" gates "$_spec"
        _rc=$?
        echo "---- not wired into stage 6 yet: patch drift, payload ABI, image/metal checks"
        echo "---- a red verdict here is a finding about the artifact, not a pin move"
        exit "$_rc"
        ;;

    *)
        echo "substrate-ci: unknown stage '$STAGE' (see --stage plan)" >&2
        exit 1
        ;;
esac
