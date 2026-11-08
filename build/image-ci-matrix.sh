#!/bin/bash
# image-ci-matrix.sh -- the image CI build matrix: desktop and server (Magnetar)
# media on amd64 and arm64, each built twice from clean clones and compared.
#
#   build/image-ci-matrix.sh [--arch amd64|arm64|all] [--variants desktop,server]
#                            [--no-determinism] [--repo DIR] [--ref REF] [--json]
#       DRY RUN (default): print every cell's host, clones, run dirs, exact build
#       and compare commands, gates, lock and marker. Starts and writes nothing.
#   build/image-ci-matrix.sh --foreground [--arch A] ...
#       run THIS host's cells now, in order (image-ci-run.sh calls this).
#   build/image-ci-matrix.sh --execute [--arch A] ...
#       the same, detached, holding the Hive busy marker; returns at once.
#   build/image-ci-matrix.sh --status [--ref REF] [--from LAUNCH_DIR]... [--json]
#       the release-candidate grid: one state per (variant, arch) cell, read
#       from the launch dirs of REF (default: every run of REF under the run
#       root, plus each --from dir copied back from another build host):
#         not built < built < gated < deterministic < shipped
#       built = image A in artifacts/; gated = its KVM, provenance and secret
#       scan results all PASS (provenance recorded); deterministic = gated and
#       compare.json says deterministic; shipped = deterministic and the
#       orchestrator's ship step wrote CELL/shipped. A candidate is COMPLETE
#       only when all four cells are at least deterministic. Exit 0 complete,
#       1 incomplete.
#   --keep-clones   keep src-a/ src-b/ after the compare (default: removed)
#
# A CELL is (variant, arch). Per cell, on the cell's host, in this order:
#   1. clone A: a fresh clone of REPO at REF (the exact commit) in CELL/src-a
#   2. build A: NCZ_VARIANT=<v> build/build-image.sh --arch <a> --full
#               --sources pinned --substrate pinned --no-publish --run-dir CELL/run-a
#   3. clone B + build B: the same pins in a second clean clone (determinism)
#   4. compare: compare-images.sh IMG_A IMG_B with the layers and, for server,
#               the Magnetar payload (base.squashfs, asset bundle, offline pool,
#               sha256 sidecars); report in CELL/compare.json
#   5. keep image A (+ receipt) in CELL/artifacts with SHA256SUMS, run-a/ (logs,
#      gate results, payload) and compare.json; remove both clones, payload B
#      and the cell's tmp/
# Cells on one host run one after another: desktop A, B, server A, B.
#
# Hosts: amd64 HYDRA or TYPHON, arm64 ULTRA (NCZ_IMAGE_CI_HOSTS_AMD64/_ARM64).
# Gates come from build-image.sh's own stages: provenance-predict/-inputs/-gate,
# static gates, secret scan, KVM. Desktop runs NCZ_KVM_GATE_VARIANTS; server
# runs the Magnetar sets (NCZ_KVM_GATE_SERVER_SETS) against a GATE medium: the
# payload URLs are dropped from the environment, so the medium pins the KVM
# gate's local server and nothing is uploaded anywhere.
#
# Never: publish, upload, tag, flash, reboot; build on macOS (STUDIO) or tmpfs;
# start a second matrix on a host whose marker names a live pid.
#
# Exit: 0 every cell PASS (and deterministic when compared); 1 a cell failed or
# differed; 2 bad invocation or refused; 3 a matrix is already running here.
set -uo pipefail

SELF="$(readlink -f "${BASH_SOURCE[0]}")"
HERE="$(cd "$(dirname "$SELF")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
CI_ROOT="${NCZ_IMAGE_CI_ROOT:-$HOME/Projects/ncz-image-ci}"
MARKER_DIR="${NCZ_IMAGE_CI_MARKER_DIR:-$HOME/.config/hive-worker/busy.d}"
# One lock with ad-hoc builds: build-image.sh's default run dir is under
# ~/Projects/ncz-build-runs, so its default lock is this same file.
LOCK="${NCZ_BUILD_LOCK:-$HOME/Projects/ncz-build-runs/.ncz-build.lock}"
BUILD_ARGS="${NCZ_IMAGE_CI_BUILD_ARGS:---full --sources pinned --substrate pinned --no-publish}"
DESKTOP_SETS="${NCZ_IMAGE_CI_DESKTOP_SETS:-norescue norescue-mgmt nodesktop minimal stalefs}"
SERVER_SETS="${NCZ_IMAGE_CI_SERVER_SETS:-server server-offline-negative}"
HOSTS_amd64="${NCZ_IMAGE_CI_HOSTS_AMD64:-hydra typhon}"
HOSTS_arm64="${NCZ_IMAGE_CI_HOSTS_ARM64:-ultra fedora}"
# A server CI medium is a gate medium: none of these may reach build-image.sh.
DROP_ENV=(NCZ_PAYLOAD_BASE_URL NCZ_PAYLOAD_URL NCZ_PAYLOAD_SHA256 NCZ_ASSETS_URL
          NCZ_POOL_URL NCZ_SERVER_PAYLOAD NCZ_MAC_DEST)
MARKER="$MARKER_DIR/ncz-image-ci-matrix"

MODE=dry-run JSON=0 ARCH_ARG="" VARIANTS="desktop,server" DET="${NCZ_IMAGE_CI_DETERMINISM:-1}"
REF="" KEEP_CLONES=0 LAUNCH="" FROM=()
while [ $# -gt 0 ]; do
    case "$1" in
        --execute) MODE=execute ;;
        --foreground) MODE=foreground ;;
        --json) JSON=1 ;;
        --arch) shift; ARCH_ARG="${1:?--arch needs amd64, arm64 or all}" ;;
        --variants) shift; VARIANTS="${1:?--variants needs a list}" ;;
        --no-determinism) DET=0 ;;
        --repo) shift; REPO="$(cd "${1:?--repo needs a dir}" 2>/dev/null && pwd)" \
                    || { echo "image-ci-matrix: no repo at $1" >&2; exit 2; } ;;
        --ref) shift; REF="${1:?--ref needs a commit}" ;;
        --keep-clones) KEEP_CLONES=1 ;;
        --status) MODE=status ;;
        --from) shift; FROM+=("${1:?--from needs a launch dir}") ;;
        --launch-dir) shift; LAUNCH="${1:?}" ;;   # internal: --execute -> --foreground
        -h|--help) sed -n '2,52p' "$SELF" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "image-ci-matrix: unknown argument $1" >&2; exit 2 ;;
    esac
    shift
done

die() { echo "image-ci-matrix: $*" >&2; exit 2; }

# --- what this host is ----------------------------------------------------------
H_UNAME="${NCZ_IMAGE_CI_UNAME:-$(uname -s)}"
H_NAME="$(echo "${NCZ_IMAGE_CI_HOSTNAME:-$(hostname -s 2>/dev/null || hostname)}" | tr 'A-Z' 'a-z')"
H_ARCH="$(dpkg --print-architecture 2>/dev/null || uname -m)"
case "$H_ARCH" in x86_64) H_ARCH=amd64 ;; aarch64|arm64) H_ARCH=arm64 ;; esac

hosts_for() { local v="HOSTS_$1"; printf '%s' "${!v}"; }
host_ok_for() {   # ARCH -> 0 when this host may build it
    [ "$H_UNAME" != Darwin ] && [ "$H_ARCH" = "$1" ] || return 1
    case " $(hosts_for "$1") " in *" $H_NAME "*) return 0 ;; esac
    return 1
}

# --- the matrix -------------------------------------------------------------------
case "${ARCH_ARG:-}" in
    "") if [ "$MODE" = dry-run ]; then ARCHES="amd64 arm64"; else ARCHES="$H_ARCH"; fi ;;
    all) ARCHES="amd64 arm64" ;;
    amd64|arm64) ARCHES="$ARCH_ARG" ;;
    *) die "unknown arch '$ARCH_ARG' (amd64, arm64 or all)" ;;
esac
VLIST=""
for v in $(echo "$VARIANTS" | tr ',' ' '); do
    case "$v" in desktop|server) VLIST="$VLIST $v" ;; *) die "unknown variant '$v' (desktop, server)" ;; esac
done
[ -n "$VLIST" ] || die "no variant selected"
case "$DET" in 0|1) ;; *) die "NCZ_IMAGE_CI_DETERMINISM must be 0 or 1" ;; esac

# --- the publish guard: every build is --no-publish and nothing else publishes ----
read -r -a BUILD_ARGV <<<"$BUILD_ARGS"
case " $BUILD_ARGS " in *" --no-publish "*) ;; *) die "refusing: build args lack --no-publish ($BUILD_ARGS)" ;; esac
_bare="${BUILD_ARGS//--no-publish/}"
case "$_bare" in
    *publish*|*reprepro*|*r2/*|*ship-image*) die "refusing: build args publish ($BUILD_ARGS)" ;;
esac

# --- scratch on a real disk ---------------------------------------------------
fs_of() {
    local d="$1"
    while [ ! -e "$d" ] && [ "$d" != / ]; do d="$(dirname "$d")"; done
    findmnt -no FSTYPE -T "$d" 2>/dev/null || stat -f -c %T "$d" 2>/dev/null || true
}
case "$(fs_of "$CI_ROOT")" in
    tmpfs|ramfs) die "refusing: run root $CI_ROOT is on tmpfs; set NCZ_IMAGE_CI_ROOT to a real disk under ~/Projects" ;;
esac

REF_SHA="$(git -C "$REPO" rev-parse --verify -q "${REF:-HEAD}^{commit}" 2>/dev/null)" \
    || die "cannot resolve ${REF:-HEAD} in $REPO"
if [ -z "$LAUNCH" ]; then
    # one dir per run: two runs in the same second must not share matrix.tsv
    LAUNCH="$CI_ROOT/$(date -u +%Y%m%dT%H%M%SZ)-${REF_SHA:0:12}"
    _base="$LAUNCH"; _n=1
    while [ -e "$LAUNCH" ]; do _n=$((_n + 1)); LAUNCH="$_base-$_n"; done
fi

# --- per-cell plan ------------------------------------------------------------------
gate_env() {   # VARIANT -> NAME=VALUE lines for the build
    if [ "$1" = server ]; then
        printf 'NCZ_KVM_GATE_SERVER_SETS=%s\n' "$SERVER_SETS"
    else
        printf 'NCZ_KVM_GATE_VARIANTS=%s\n' "$DESKTOP_SETS"
    fi
}
host_env_defaults() {   # HOST -> NAME=VALUE lines applied when unset and present
    case "$1" in
        hydra) printf 'NCZ_SUDO_PASS_FILE=%s\n' "$HOME/.config/ncz/sudo-pass.json" ;;
        ultra|fedora) printf 'NCZ_BUILD_INPUTS_DIR=%s\nNCZ_SUBSTRATE_CACHE_DIRS=%s\n' \
                          "$HOME/ncz-assets" "$HOME/ncz-assets/substrate" ;;
    esac
}
cell_dir() { printf '%s/%s-%s' "$LAUNCH" "$1" "$2"; }
build_cmd_text() {   # VARIANT ARCH SIDE -> the exact build, as one shell line
    local v="$1" a="$2" s="$3" c kv envs=""
    c="$(cell_dir "$v" "$a")"
    while IFS= read -r kv; do envs="$envs ${kv%%=*}='${kv#*=}'"; done < <(gate_env "$v")
    printf 'cd %s/src-%s && bash build/stage-build-inputs.sh --arch %s && env' "$c" "$s" "$a"
    printf ' -u %s' "${DROP_ENV[@]}"
    printf ' NCZ_VARIANT=%s NCZ_BUILD_LOCK=%s TMPDIR=%s/tmp%s bash build/build-image.sh --arch %s %s --run-dir %s/run-%s' \
        "$v" "$LOCK" "$c" "$envs" "$a" "$BUILD_ARGS" "$c" "$s"
}
compare_cmd_text() {
    local v="$1" a="$2" c; c="$(cell_dir "$v" "$a")"
    printf 'bash %s/src-a/build/compare-images.sh --arch %s --layers %s/src-a/assets/squashfs %s/src-b/assets/squashfs' \
        "$c" "$a" "$c" "$c"
    [ "$v" = server ] && printf ' --payload %s/run-a/payload %s/run-b/payload' "$c" "$c"
    printf ' --report %s/compare.json IMG_A IMG_B' "$c"
}

print_plan() {
    local a v c side h
    echo "image-ci matrix ($MODE) ref=${REF_SHA:0:12} repo=$REPO"
    echo "host: $H_NAME ($H_ARCH, $H_UNAME)"
    echo "root: $LAUNCH"
    echo "lock: $LOCK"
    echo "marker: $MARKER"
    echo "determinism: $([ "$DET" = 1 ] && echo 'two clean builds per cell + compare-images.sh' || echo 'off (one build per cell)')"
    for a in $ARCHES; do
        for v in $VLIST; do
            c="$(cell_dir "$v" "$a")"
            echo "cell $v/$a hosts=$(hosts_for "$a" | tr ' ' ',') runs-here=$(host_ok_for "$a" && echo yes || echo no)"
            for side in a $([ "$DET" = 1 ] && echo b); do
                echo "  build $side: $(build_cmd_text "$v" "$a" "$side")"
            done
            [ "$DET" = 1 ] && echo "  compare: $(compare_cmd_text "$v" "$a")"
            if [ "$v" = server ]; then
                echo "  gates:   KVM sets '$SERVER_SETS' (boot, payload fetch verified, ssh enabled, no telnet/desktop entries, serial login), provenance --variant server --server-payload, secret scan of medium + payload; payload pins = KVM gate base, nothing uploaded"
            else
                echo "  gates:   KVM full gate + sets '$DESKTOP_SETS', provenance gate, secret scan, static gates"
            fi
            echo "  keep:    $c/artifacts (image A, receipt, SHA256SUMS), run-a/, compare.json; clones$([ "$KEEP_CLONES" = 1 ] && echo ' kept' || echo ' removed')"
            for h in $(hosts_for "$a"); do
                [ -n "$(host_env_defaults "$h")" ] && \
                    echo "  host env ($h, when unset and present): $(host_env_defaults "$h" | tr '\n' ' ')"
            done
        done
    done
}

print_json() {
    {
        printf 'META\tref\t%s\nMETA\trepo\t%s\nMETA\tlaunch_dir\t%s\nMETA\tlock\t%s\nMETA\tmarker\t%s\nMETA\tdeterminism\t%s\n' \
            "$REF_SHA" "$REPO" "$LAUNCH" "$LOCK" "$MARKER" "$DET"
        local a v side
        for a in $ARCHES; do for v in $VLIST; do
            printf 'CELL\t%s\t%s\t%s\t%s\t%s\t%s\n' "$v" "$a" "$(hosts_for "$a")" \
                "$(host_ok_for "$a" && echo 1 || echo 0)" "$(cell_dir "$v" "$a")" \
                "$([ "$DET" = 1 ] && compare_cmd_text "$v" "$a")"
            for side in a $([ "$DET" = 1 ] && echo b); do
                printf 'BUILD\t%s\t%s\t%s\t%s\n' "$v" "$a" "$side" "$(build_cmd_text "$v" "$a" "$side")"
            done
        done; done
    } | python3 -I -c '
import json, sys
meta, cells = {}, {}
for line in sys.stdin:
    f = line.rstrip("\n").split("\t")
    if f[0] == "META":
        meta[f[1]] = f[2]
    elif f[0] == "CELL":
        cells[(f[1], f[2])] = {"variant": f[1], "arch": f[2], "hosts": f[3].split(),
                               "runs_here": f[4] == "1", "cell_dir": f[5], "compare": f[6],
                               "payload_compare": f[1] == "server" and bool(f[6]), "builds": []}
    elif f[0] == "BUILD":
        c = cells[(f[1], f[2])]
        c["builds"].append({"side": f[3], "clone": c["cell_dir"] + "/src-" + f[3],
                            "run_dir": c["cell_dir"] + "/run-" + f[3], "command": f[4]})
meta["determinism"] = meta.get("determinism") == "1"
meta["cells"] = list(cells.values())
print(json.dumps(meta, indent=2, sort_keys=True))
'
}

# --- candidate status: the 2x2 grid -------------------------------------------------
cell_state() {   # CELL_DIR -> state word
    local c="$1" g
    ls "$c"/artifacts/*.img >/dev/null 2>&1 || { echo "not built"; return; }
    for g in kvm-gate provenance secret-scan; do
        grep -q '^result=PASS' "$c/run-a/$g.result" 2>/dev/null || { echo built; return; }
    done
    python3 -I -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])).get("verdict")=="deterministic" else 1)' \
        "$c/compare.json" 2>/dev/null || { echo gated; return; }
    [ -f "$c/shipped" ] && echo shipped || echo deterministic
}
if [ "$MODE" = status ]; then
    dirs=()
    for d in "$CI_ROOT"/*-"${REF_SHA:0:12}" "$CI_ROOT"/*-"${REF_SHA:0:12}"-[0-9]*; do [ -d "$d" ] && dirs+=("$d"); done
    dirs+=("${FROM[@]}")
    rows=""
    for a in amd64 arm64; do for v in desktop server; do
        best="" bstate="not built"
        # the most advanced state any run of this ref reached; ties -> latest dir
        for d in "${dirs[@]}"; do
            [ -d "$d/$v-$a" ] || continue
            s="$(cell_state "$d/$v-$a")"
            case "$bstate:$s" in
                *":not built") ;;
                "not built:"*|"built:gated"|"built:deterministic"|"built:shipped"|"gated:deterministic"|"gated:shipped"|"deterministic:shipped") bstate="$s"; best="$d/$v-$a" ;;
                "$s:$s") best="$d/$v-$a" ;;
            esac
        done
        sha="-"; [ -n "$best" ] && sha="$(awk '/\.img$/{print $1; exit}' "$best/artifacts/SHA256SUMS" 2>/dev/null)"
        rows="$rows$v	$a	$bstate	${sha:--}	${best:--}
"
    done; done
    complete=1
    while IFS=$'\t' read -r v a s sha c; do
        [ -n "$v" ] || continue
        case "$s" in deterministic|shipped) ;; *) complete=0 ;; esac
    done <<<"$rows"
    if [ "$JSON" = 1 ]; then
        printf '%s' "$rows" | python3 -I -c '
import json, sys
cells = [dict(zip(("variant", "arch", "state", "image_sha256", "cell_dir"), l.rstrip("\n").split("\t")))
         for l in sys.stdin if l.strip()]
print(json.dumps({"ref": sys.argv[1], "complete": sys.argv[2] == "1", "cells": cells,
                  "rule": "all four cells built, gated (KVM + provenance + secret scan PASS), deterministic"},
                 indent=2, sort_keys=True))' "$REF_SHA" "$complete"
    else
        g() { awk -F'\t' -v v="$1" -v a="$2" '$1==v && $2==a {print $3}' <<<"$rows"; }
        printf '%-10s %-16s %-16s\n' "" amd64 arm64
        for v in desktop server; do printf '%-10s %-16s %-16s\n' "$v" "$(g "$v" amd64)" "$(g "$v" arm64)"; done
        echo
        while IFS=$'\t' read -r v a s sha c; do
            [ -n "$v" ] && echo "  $v/$a: $s image=$sha cell=$c"
        done <<<"$rows"
        if [ "$complete" = 1 ]; then
            echo "candidate ${REF_SHA:0:12}: COMPLETE (all four media built, gated, deterministic, provenance recorded)"
        else
            echo "candidate ${REF_SHA:0:12}: INCOMPLETE (a candidate needs all four cells at least deterministic)"
        fi
    fi
    [ "$complete" = 1 ]; exit $?
fi

if [ "$MODE" = dry-run ]; then
    if [ "$JSON" = 1 ]; then print_json; else print_plan; echo; echo "nothing started (dry run): no clone, no run dir, no marker"; fi
    exit 0
fi

# --- execute / foreground: only on a build host of the right arch ---------------
[ "$H_UNAME" != Darwin ] || die "refusing: this script never builds on macOS (STUDIO is orchestration only)"
for a in $ARCHES; do
    [ "$a" = "$H_ARCH" ] || die "refusing: this $H_ARCH host cannot build $a cells (run the $a cells on: $(hosts_for "$a"))"
    host_ok_for "$a" || die "refusing: $H_NAME is not a build host for $a (eligible: $(hosts_for "$a"); NCZ_IMAGE_CI_HOSTS_$(echo "$a" | tr a-z A-Z) adds one)"
done

# --- the Hive busy marker (first line = pid, read by the worker build gate) -----
reserve_marker() {   # PID -> 0 reserved, 3 a live matrix holds it
    mkdir -p "$MARKER_DIR" || return 2
    if ( set -C; printf '%s\n' "$1" > "$MARKER" ) 2>/dev/null; then return 0; fi
    local mpid; mpid="$(head -1 "$MARKER" 2>/dev/null | tr -dc '0-9')"
    if [ -n "$mpid" ] && kill -0 "$mpid" 2>/dev/null; then
        echo "image-ci-matrix: SKIP: a matrix is already running on $H_NAME (pid $mpid holds $MARKER)" >&2
        return 3
    fi
    echo "image-ci-matrix: clearing a stale marker (pid ${mpid:-empty} is not running)"
    rm -f "$MARKER"
    ( set -C; printf '%s\n' "$1" > "$MARKER" ) 2>/dev/null && return 0
    echo "image-ci-matrix: SKIP: another matrix reserved $MARKER first" >&2
    return 3
}

if [ "$MODE" = execute ]; then
    reserve_marker "$$" || exit $?
    mkdir -p "$LAUNCH" || { rm -f "$MARKER"; die "cannot create $LAUNCH"; }
    fwd=(--foreground --launch-dir "$LAUNCH" --arch "$ARCHES" --variants "$(echo $VLIST | tr ' ' ',')"
         --repo "$REPO" --ref "$REF_SHA")
    [ "$DET" = 1 ] || fwd+=(--no-determinism)
    [ "$KEEP_CLONES" = 1 ] && fwd+=(--keep-clones)
    log="$LAUNCH/matrix.log"
    # The child records ITS OWN pid first (no window in which the marker names a
    # dead parent), waits for the whole chain, and gives the marker back only
    # if it is still its own. Same contract as image-ci-run.sh.
    ( printf '%s\n' "$BASHPID" > "$MARKER"
      NCZ_IMAGE_CI_MATRIX_MARKER_HELD=1 setsid bash "$SELF" "${fwd[@]}" > "$log" 2>&1
      rc=$?
      [ "$(head -1 "$MARKER" 2>/dev/null)" = "$BASHPID" ] && rm -f "$MARKER"
      exit $rc ) &
    pid=$!
    if kill -0 "$pid" 2>/dev/null; then
        echo "image-ci-matrix: started pid=$pid log=$log root=$LAUNCH"
        exit 0
    fi
    [ "$(head -1 "$MARKER" 2>/dev/null)" = "$$" ] && rm -f "$MARKER"
    echo "image-ci-matrix: FAILED to start; see $log" >&2
    exit 1
fi

# foreground
if [ "${NCZ_IMAGE_CI_MATRIX_MARKER_HELD:-0}" != 1 ]; then
    reserve_marker "$$" || exit $?
    trap '[ "$(head -1 "$MARKER" 2>/dev/null)" = "$$" ] && rm -f "$MARKER"' EXIT
fi
mkdir -p "$LAUNCH" || die "cannot create $LAUNCH"
print_plan > "$LAUNCH/plan.txt"
print_plan
for kv in $(host_env_defaults "$H_NAME"); do
    n="${kv%%=*}"; val="${kv#*=}"
    if [ -z "${!n:-}" ] && [ -e "$val" ]; then export "$n=$val"; echo "host env: $n=$val"; fi
done
TSV="$LAUNCH/matrix.tsv"
[ -f "$TSV" ] || printf 'variant\tarch\tresult\tdeterminism\tstage\timage_sha256\tcell\n' > "$TSV"

run_cell() {   # VARIANT ARCH -> appends one row to matrix.tsv
    local v="$1" a="$2" c side img stage="-" det_res="not-run" result=PASS sha="-" rc kv
    local -a envs=() unset_args=()
    c="$(cell_dir "$v" "$a")"
    mkdir -p "$c/tmp"
    while IFS= read -r kv; do envs+=("$kv"); done < <(gate_env "$v")
    for kv in "${DROP_ENV[@]}"; do unset_args+=(-u "$kv"); done
    declare -A imgs=()
    echo "== cell $v/$a ($c)"
    for side in a $([ "$DET" = 1 ] && echo b); do
        if ! { git clone -q --no-checkout "$REPO" "$c/src-$side" \
               && git -C "$c/src-$side" checkout -q --detach "$REF_SHA"; } > "$c/clone-$side.log" 2>&1; then
            result=FAIL stage="clone-$side"; break
        fi
        echo "   inputs $side: staging build inputs (log $c/build-$side.log)"
        ( cd "$c/src-$side" && env "${unset_args[@]}" NCZ_VARIANT="$v" NCZ_BUILD_LOCK="$LOCK" \
              TMPDIR="$c/tmp" "${envs[@]}" bash build/stage-build-inputs.sh --arch "$a" \
              ) >> "$c/build-$side.log" 2>&1
        rc=$?
        if [ "$rc" != 0 ]; then result=FAIL stage="inputs-$side"; break; fi
        echo "   build $side: $(date -u +%H:%M:%SZ) start (log $c/build-$side.log)"
        # The server CI medium is self-contained: no payload URL is pinned to
        # the medium and base.squashfs ships inside it (the writer refuses LAN
        # URLs, and the caller's URL vars are dropped above). The desktop image
        # keeps the online default.
        if [ "$v" = server ]; then payload_mode=medium; else payload_mode=online; fi
        ( cd "$c/src-$side" && env "${unset_args[@]}" NCZ_VARIANT="$v" NCZ_SERVER_PAYLOAD="$payload_mode" \
              NCZ_BUILD_LOCK="$LOCK" TMPDIR="$c/tmp" "${envs[@]}" \
              bash build/build-image.sh --arch "$a" "${BUILD_ARGV[@]}" \
              --run-dir "$c/run-$side" ) >> "$c/build-$side.log" 2>&1
        rc=$?
        echo "   build $side: $(date -u +%H:%M:%SZ) rc=$rc"
        if [ "$rc" != 0 ]; then result=FAIL stage="build-$side"; break; fi
        img="$(cat "$c/run-$side/image.path" 2>/dev/null)"
        if [ -z "$img" ] || [ ! -f "$img" ]; then result=FAIL stage="image-$side"; break; fi
        imgs[$side]="$img"
    done
    if [ "$result" = PASS ] && [ "$DET" = 1 ]; then
        local -a cmp=(--arch "$a" --layers "$c/src-a/assets/squashfs" "$c/src-b/assets/squashfs")
        [ "$v" = server ] && cmp+=(--payload "$c/run-a/payload" "$c/run-b/payload")
        [ -f "$c/src-a/manifests/determinism-expect.tsv" ] && cmp+=(--expect "$c/src-a/manifests/determinism-expect.tsv")
        bash "$c/src-a/build/compare-images.sh" "${cmp[@]}" --report "$c/compare.json" \
            "${imgs[a]}" "${imgs[b]}" > "$c/compare.log" 2>&1
        case $? in
            0) det_res=deterministic ;;
            1) det_res=differing; result=NONDETERMINISTIC; stage=compare ;;
            *) det_res=compare-error; result=FAIL; stage=compare ;;
        esac
    fi
    # keep image A (gated by its own build) and its receipt; then clean up
    if [ -n "${imgs[a]:-}" ] && [ -f "${imgs[a]}" ]; then
        mkdir -p "$c/artifacts"
        mv -f "${imgs[a]}" "$c/artifacts/" && [ -f "${imgs[a]}.receipt.json" ] && mv -f "${imgs[a]}.receipt.json" "$c/artifacts/"
        ( cd "$c/artifacts" && sha256sum -- * 2>/dev/null | grep -v ' SHA256SUMS$' > SHA256SUMS )
        sha="$(awk '/\.img$/{print $1; exit}' "$c/artifacts/SHA256SUMS")"
    fi
    rm -rf "$c/run-b/payload" "$c/tmp"
    if [ "$KEEP_CLONES" != 1 ]; then
        rm -rf "$c/src-a" "$c/src-b" 2>/dev/null
        for side in a b; do
            [ -e "$c/src-$side" ] && echo "   kept (could not remove, check ownership): $c/src-$side"
        done
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$v" "$a" "$result" "$det_res" "$stage" "$sha" "$c" >> "$TSV"
    echo "   cell $v/$a: $result ($det_res) stage=$stage image=$sha"
}

for a in $ARCHES; do
    for v in $VLIST; do run_cell "$v" "$a"; done
done

echo
echo "summary ($TSV):"
bad=0
while IFS=$'\t' read -r v a result det stage sha c; do
    [ "$v" = variant ] && continue
    case "$result" in
        PASS) echo "  $v/$a PASS $det sha256=$sha" ;;
        NONDETERMINISTIC) echo "  $v/$a NONDETERMINISTIC (see $c/compare.log)"; bad=1 ;;
        *) echo "  $v/$a FAIL at $stage (see $c/${stage}.log)"; bad=1 ;;
    esac
done < <(tail -n +2 "$TSV")
exit "$bad"
