#!/bin/bash
# nightly-canary.sh -- THE nightly "build everything we depend on from HEAD"
# canary + the weekly full build.
#
#   build/nightly-canary.sh --arch amd64|arm64|both --mode nightly|weekly \
#       [--unattended] [--out-root DIR] [--run-id ID] [--no-build] [--no-hw] \
#       [--sources latest|pinned] [--max-disk-pct N] [--stage-timeout SEC]
#
# WHAT IT DOES
#   nightly: refresh the pinned substrate, resolve the upstream HEAD of every
#     source-buildable component, rebuild those from HEAD (singularity payload +
#     compositor wraps, wallpapers, apt-policy, libdrm, DKMS, debootstrap stub,
#     usb-recovery), resolve the kernel HEADs and `git apply --check` every
#     carried kernel patch (NO full kernel build), emit the run's
#     ledger-candidates.tsv, run the pre-build provenance gate in nightly mode,
#     the static shader gate, component unit tests and the four-host hardware
#     smoke, then write status/<date>.json + latest/last-green + TRIAGE.md and
#     enforce retention.  A red nightly is the point: it reports what broke at
#     HEAD.
#   weekly: additionally `build/build-image.sh --arch both --full --sources
#     latest --no-publish` (all gates incl. KVM/UI, provenance, installer
#     messages) + a determinism compare of layers on one arch + full kernel
#     builds when the kernel trees changed.
#
# ARTIFACTS: $OUT_ROOT/<run-id>/{amd64,arm64}/{debs,sha256,run-metadata.json,
# ledger-candidates.tsv}; images only for weekly.  NEVER to
# .../ncz-os-assets/images/, never published/tagged/shipped.  Retention: the job
# keeps the last 3 nightly run dirs and the last 2 weekly (see the retention
# stage).  The newest weekly that PASSED all gates is the last-known-good
# candidate; promotion is operator-only.
#
# SAFETY (--unattended): no prompts, a lock so runs never overlap, refuses to
#   start if the host disk is > --max-disk-pct (default 70%) or another build is
#   running, runs the scratch reaper --check at start and the cleanup at the end,
#   strict per-stage timeouts, nice/ionice, NEVER tmpfs.
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CANARY="$HERE/nightly-canary.sh"

ARCH=""; MODE="nightly"; UNATTENDED=0; OUT_ROOT="${NCZ_NIGHTLY_ROOT:-$HOME/Projects/ncz-nightly-runs}"
RUN_ID=""; DRY_RUN=0; INVENTORY=0; NO_BUILD=0; NO_HW=0; NO_REAPER=0
SOURCES="latest"; MAX_DISK_PCT=70; STAGE_TIMEOUT="${NCZ_NIGHTLY_STAGE_TIMEOUT:-7200}"
ONLY=""
while [ $# -gt 0 ]; do
    case "$1" in
        --arch) ARCH="${2:?}"; shift 2 ;;
        --mode) MODE="${2:?}"; shift 2 ;;
        --unattended) UNATTENDED=1; shift ;;
        --out-root) OUT_ROOT="${2:?}"; shift 2 ;;
        --run-id) RUN_ID="${2:?}"; shift 2 ;;
        --dry-run|--plan) DRY_RUN=1; shift ;;
        --inventory) INVENTORY=1; shift ;;
        --no-build) NO_BUILD=1; shift ;;
        --no-hw) NO_HW=1; shift ;;
        --no-reaper) NO_REAPER=1; shift ;;
        --sources) SOURCES="${2:?}"; shift 2 ;;
        --max-disk-pct) MAX_DISK_PCT="${2:?}"; shift 2 ;;
        --stage-timeout) STAGE_TIMEOUT="${2:?}"; shift 2 ;;
        --only) ONLY="${2:?}"; shift 2 ;;
        -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
        *) echo "nightly-canary: unknown arg: $1" >&2; exit 2 ;;
    esac
done
if [ "$INVENTORY" != 1 ]; then
    case "$ARCH" in amd64|arm64|both) ;; *) echo "nightly-canary: --arch amd64|arm64|both required" >&2; exit 2 ;; esac
fi
case "$MODE" in nightly|weekly) ;; *) echo "nightly-canary: --mode nightly|weekly" >&2; exit 2 ;; esac
case "$SOURCES" in latest|pinned) ;; *) echo "nightly-canary: --sources latest|pinned" >&2; exit 2 ;; esac
: "${RUN_ID:=$(date -u +%Y%m%d)}"

REG="$ROOT/build/nightly/components.tsv"
say()  { printf '[nightly %s] %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }
warn() { printf '[nightly %s] WARN %s\n' "$(date -u +%H:%M:%SZ)" "$*" >&2; }
die()  { printf '[nightly %s] ERROR %s\n' "$(date -u +%H:%M:%SZ)" "$*" >&2; exit 2; }

# ---------------------------------------------------------------------------
# --inventory: the dependency inventory table (report deliverable) -----------
# ---------------------------------------------------------------------------
print_inventory() {
    printf '%-28s %-11s %-6s %-46s %-46s %-9s %s\n' \
        COMPONENT KIND ARCH SOURCE RECIPE HEAD-REF BUILDABLE-FROM-HEAD
    while IFS=$'\t' read -r comp kind arch source recipe how headref buildable why resolver url ref; do
        case "$comp" in ''|\#*) continue ;; esac
        printf '%-28s %-11s %-6s %-46s %-46s %-9s %s\n' \
            "$comp" "$kind" "$arch" "$source" "$recipe" "$headref" "$buildable"
    done < "$REG"
}
if [ "$INVENTORY" = 1 ]; then print_inventory; exit 0; fi

# ---------------------------------------------------------------------------
# run dirs
# ---------------------------------------------------------------------------
RUN_DIR="$OUT_ROOT/$RUN_ID"
STATUS_DIR="$OUT_ROOT/status"
mkdir -p "$RUN_DIR" "$STATUS_DIR"
# never tmpfs: all scratch lives under the run dir on a real disk
export TMPDIR="$RUN_DIR/tmp"; mkdir -p "$TMPDIR"

# ---------------------------------------------------------------------------
# lock (runs never overlap) + disk guard + reaper (policy)
# ---------------------------------------------------------------------------
LOCK="$OUT_ROOT/.ncz-nightly.lock"
acquire_lock() {
    if mkdir "$LOCK" 2>/dev/null; then
        printf '%s\n' "$$" > "$LOCK/pid"
        return 0
    fi
    local owner; owner="$(cat "$LOCK/pid" 2>/dev/null || echo '?')"
    if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then
        die "another nightly run is active (pid $owner, $LOCK)"
    fi
    warn "stale lock $LOCK (pid $owner not alive); reclaiming"
    rm -rf "$LOCK"; mkdir "$LOCK" && printf '%s\n' "$$" > "$LOCK/pid"
}
release_lock() { rm -rf "$LOCK" 2>/dev/null || true; }

disk_pct() { # path -> used percent on its filesystem
    df -P "$1" 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $5}'
}
check_disk() {
    local p; p="$(disk_pct "$OUT_ROOT")"
    [ -n "$p" ] || { warn "could not read disk usage for $OUT_ROOT"; return 0; }
    if [ "$p" -gt "$MAX_DISK_PCT" ]; then
        die "disk at $OUT_ROOT is ${p}% used (> ${MAX_DISK_PCT}%); refusing to start"
    fi
    say "disk at $OUT_ROOT: ${p}% used (limit ${MAX_DISK_PCT}%)"
}
reaper_bin() {
    if command -v ncz-scratch-reaper >/dev/null 2>&1; then command -v ncz-scratch-reaper; return; fi
    for c in "${NCZ_SCRATCH_REAPER:-}" "$HOME/.local/bin/ncz-scratch-reaper" "$ROOT/tools/ncz-scratch-reaper"; do
        [ -n "$c" ] && [ -x "$c" ] && { printf '%s\n' "$c"; return; }
    done
}
run_reaper() { # mode: check|clean
    [ "$NO_REAPER" = 1 ] && { say "reaper: skipped (--no-reaper)"; return 0; }
    local rb; rb="$(reaper_bin)"
    if [ -z "$rb" ]; then warn "reaper: ncz-scratch-reaper not found; policy check skipped (not a failure)"; return 0; fi
    case "$1" in
        check) "$rb" --check || warn "reaper --check reported findings" ;;
        clean) "$rb" || warn "reaper cleanup reported findings" ;;
    esac
}
run_fstype_check() {
    local fs; fs="$(df -P "$RUN_DIR" 2>/dev/null | awk 'NR==2{print $1}')"
    case "$(mount | awk -v d="$RUN_DIR" '$3==d{print $5}' | head -1)" in
        tmpfs|ramfs) die "run dir $RUN_DIR is on tmpfs; never build on tmpfs" ;;
    esac
    say "run dir fs=$fs"
}

# ---------------------------------------------------------------------------
# stage machinery
# ---------------------------------------------------------------------------
STAGES_TSV="$RUN_DIR/stages.tsv"; : > "$STAGES_TSV"
# strict per-stage timeout: run the stage in its own subshell and enforce a
# watchdog that TERMs the subshell pid, then KILLs it.  Only the stage's own
# process tree is touched (never a broad pkill/pgrep -f).  A stage with no
# `timeout(1)` (macOS) still gets the subshell watchdog.
run_stage() { # name cmd_function_or_external args...
    local name="$1"; shift
    if [ -n "$ONLY" ]; then
        case ",$ONLY," in *",$name,"*) ;; *) say "skip [$name] (not in --only)"; printf '%s\tSKIP\t0\n' "$name" >> "$STAGES_TSV"; return 0 ;; esac
    fi
    local log="$RUN_DIR/logs/$name.log"; mkdir -p "$RUN_DIR/logs"
    local t0 t1 rc=0
    t0="$(date -u +%s)"
    say "BEGIN [$name]"
    # test-only fault injection (never set in production): forces a red stage so
    # the status/TRIAGE path can be tested deterministically.
    if [ "${NCZ_NIGHTLY_TEST_FAIL_STAGE:-}" = "$name" ]; then
        echo "injected failure (NCZ_NIGHTLY_TEST_FAIL_STAGE=$name)" >>"$log"
        printf '%s\tFAIL:9\t0\n' "$name" >> "$STAGES_TSV"
        warn "[$name] injected failure (test hook)"; return 9
    fi
    ( "$@" ) >"$log" 2>&1 &
    local pid=$!
    (
        sleep "$STAGE_TIMEOUT"
        kill -TERM "$pid" 2>/dev/null || exit 0
        sleep 10
        kill -KILL "$pid" 2>/dev/null || true
    ) &
    local wd=$!
    wait "$pid"; rc=$?
    kill "$wd" 2>/dev/null || true
    wait "$wd" 2>/dev/null || true
    t1="$(date -u +%s)"
    if [ "$rc" = 143 ] || [ "$rc" = 137 ]; then
        warn "[$name] TIMED OUT after ${STAGE_TIMEOUT}s (log $log)"; rc=124
    fi
    printf '%s\t%s\t%s\n' "$name" "$([ "$rc" = 0 ] && echo PASS || echo "FAIL:$rc")" "$((t1 - t0))" >> "$STAGES_TSV"
    if [ "$rc" = 0 ]; then say "OK    [$name] ($((t1 - t0))s)"; else warn "[$name] FAILED rc=$rc (log $log)"; fi
    return "$rc"
}

# record a component provenance row for the candidates emitter
PROV_TSV="$RUN_DIR/component-provenance.tsv"
record_prov() { # output_deb recipe source_revision resolved_source_shas
    printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$PROV_TSV"
}
DEB_DIR="$RUN_DIR/debs"   # collected built debs (per arch below)

# ---------------------------------------------------------------------------
# stages
# ---------------------------------------------------------------------------
stage_preflight() {
    say "arch=$ARCH mode=$MODE host=$(hostname -s) run=$RUN_ID"
    say "run-dir=$RUN_DIR sources=$SOURCES unattended=$UNATTENDED"
    local missing="" t
    for t in git make python3 sha256sum tar df; do
        command -v "$t" >/dev/null 2>&1 || missing="$missing $t"
    done
    if [ -n "$missing" ]; then
        say "WARN missing host tools:$missing"; return 1
    fi
    say "host tools OK"
    say "registry: $REG ($(grep -vc '^#' "$REG" 2>/dev/null) component rows)"
    return 0
}

stage_refresh_substrate() {
    if [ "$SOURCES" = pinned ]; then say "substrate pinned policy: verify only"; fi
    local rc=0
    for a in ${ARCH_LIST}; do
        if [ -x "$ROOT/build/refresh-substrate.sh" ]; then
            ( cd "$ROOT" && NCZ_TARGET_ARCH="$a" bash build/refresh-substrate.sh --arch "$a" ) || rc=$?
        fi
    done
    return "$rc"
}

# resolve HEAD for every source-buildable component (singularity + wraps + git rows)
stage_resolve_heads() {
    local sdir="$RUN_DIR/singularity-sources"; mkdir -p "$sdir"
    local rc=0
    for a in ${ARCH_LIST}; do
        ( cd "$ROOT" && TMPDIR="$TMPDIR" bash build/refresh-singularity-sources.sh \
              --sources "$SOURCES" --output "$sdir/$a" --arch "$a" ) || rc=$?
    done
    # record every resolved repo SHA into run-metadata later (source-resolution.json)
    [ -f "$sdir/${ARCH_LIST%% *}/source-resolution.json" ] && say "resolved singularity sources"
    # git-row HEADs (gtk4-layer-shell) -- ls-remote only
    return "$rc"
}

stage_kernel_head_check() {
    local ko="$RUN_DIR/kernel"
    bash "$HERE/nightly/kernel-head-check.sh" --arch "$ARCH" --out "$ko" \
        ${NCZ_AMD64_KERNEL_TREE:+--tree-amd64 "$NCZ_AMD64_KERNEL_TREE"} \
        ${NCZ_ARM64_KERNEL_TREE:+--tree-arm64 "$NCZ_ARM64_KERNEL_TREE"}
}

# build one component from HEAD; appends its debs to DEB_DIR and a provenance row
build_component() { # arch component
    local a="$1" comp="$2"
    case "$comp" in
        ncz-singularity-desktop)
            local sdir="$RUN_DIR/singularity-sources/$a" out="$sdir/out"; mkdir -p "$out"
            local up="$sdir/upstream-pins.tsv"
            [ -s "$up" ] || { warn "no resolved pins for $a; skipping payload"; return 1; }
            ( cd "$ROOT" && TMPDIR="$TMPDIR" NCZ_SINGULARITY_PINS="$up" NCZ_SINGULARITY_TRACK_HEAD=1 \
                OUT="$out" SINGULARITY_IMAGE="debian:${NCZ_BASE_CODENAME:-forky}" \
                bash build/build-singularity.sh ) || return 1
            local tgz="$out/singularity-opt.tgz"
            [ -s "$tgz" ] || return 1
            local deb; deb="$( ( cd "$ROOT" && NCZ_SINGULARITY_ARCH="$a" OUT="$out" bash build/build-singularity-deb.sh "$tgz" ) 2>/dev/null | sed -n 's/^Final \.deb: //p' | tail -1 )"
            [ -n "$deb" ] && [ -s "$deb" ] || return 1
            cp -f "$deb" "$DEB_DIR/$a/" 2>/dev/null || { mkdir -p "$DEB_DIR/$a"; cp -f "$deb" "$DEB_DIR/$a/"; }
            record_prov "$(basename "$deb")" "build/build-singularity.sh + build/build-singularity-deb.sh" \
                "HEAD (resolved $(date -u +%Y%m%dT%H%M%SZ))" "$(sha256sum "$up" | awk '{print $1}')"
            ;;
        ncz-wallpapers-*)
            local pack="${comp#ncz-wallpapers-}"; [ "$pack" = cygnus-2610 ] && pack="cygnus-2610"
            ( cd "$ROOT" && bash build/build-wallpaper-contrib-deb.sh "$pack" ) || return 1
            local d; d="$(ls -1 "$ROOT/assets/wallpaper-debs/${comp}_"*.deb 2>/dev/null | sort -V | tail -1)"
            [ -n "$d" ] || return 1
            mkdir -p "$DEB_DIR/$a"; cp -f "$d" "$DEB_DIR/$a/"
            record_prov "$(basename "$d")" "build/build-wallpaper-contrib-deb.sh $pack" "in-tree" "in-tree"
            ;;
        ncz-apt-policy)
            ( cd "$ROOT" && bash build/build-ncz-apt-policy-deb.sh ) || return 1
            local d; d="$(ls -1 "$ROOT"/assets/apt-policy/ncz-apt-policy_*.deb "$ROOT"/build/ncz-apt-policy_*.deb 2>/dev/null | sort -V | tail -1)"
            # a missing artifact is a FAILURE, not a silent success (zoder review)
            [ -n "$d" ] || { warn "ncz-apt-policy built but produced no .deb"; return 1; }
            mkdir -p "$DEB_DIR/$a"; cp -f "$d" "$DEB_DIR/$a/"
            record_prov "$(basename "$d")" "build/build-ncz-apt-policy-deb.sh" "in-tree" "in-tree"
            ;;
        libdrm-ncz2)
            ( cd "$ROOT" && LIBDRM_REBUILD=1 bash build/build-libdrm-debs.sh ) || return 1
            # the resolved source revision is the NCZ libdrm patch sha pinned in
            # release.conf (never the literal variable name -- zoder review).
            local lpatch
            lpatch="$(sed -n 's/^NCZ_LIBDRM_PATCH_SHA256=\("\(.*\)"\|\(.*\)\)/\2\3/p' "$ROOT/release.conf" | head -1)"
            for d in "$ROOT"/build/libdrm-debs/*_"$a".deb "$ROOT"/build/libdrm-debs/*_all.deb; do
                [ -f "$d" ] || continue
                mkdir -p "$DEB_DIR/$a"; cp -f "$d" "$DEB_DIR/$a/"
                record_prov "$(basename "$d")" "build/build-libdrm-debs.sh" "pinned snapshot source" "libdrm-patch-sha256:${lpatch:-unknown}"
            done
            ;;
        cix-gpu-kmd-dkms|panthor-cix-dkms|cix-vpu-driver-dkms)
            ( cd "$ROOT" && bash build/build-dkms-debs.sh ) || return 1
            local d
            for d in "$ROOT"/build/dkms-debs/*.deb "$ROOT"/assets/kernel/*/output/*.deb; do
                [ -f "$d" ] || continue
                mkdir -p "$DEB_DIR/$a"; cp -f "$d" "$DEB_DIR/$a/"
                record_prov "$(basename "$d")" "build/build-dkms-debs.sh" "assets/kernel (vendored)" "in-tree"
            done
            ;;
        ncz-usb-recovery)
            ( cd "$ROOT" && bash build/build-usb-recovery-deb.sh ) || return 1
            local d; d="$(ls -1 "$ROOT"/build/ncz-usb-recovery_*.deb 2>/dev/null | sort -V | tail -1)"
            [ -n "$d" ] || return 0
            mkdir -p "$DEB_DIR/$a"; cp -f "$d" "$DEB_DIR/$a/"
            record_prov "$(basename "$d")" "build/build-usb-recovery-deb.sh" "in-tree" "in-tree"
            ;;
        *)
            warn "no in-tree recipe for $comp; recording SKIPPED"
            return 0 ;;
    esac
    return 0
}

stage_rebuild_components() {
    local rc=0
    for a in ${ARCH_LIST}; do
        mkdir -p "$DEB_DIR/$a"
        while IFS=$'\t' read -r comp kind c_arch c_source c_recipe c_how c_headref c_buildable c_why c_resolver c_url c_ref; do
            case "$comp" in ''|\#*) continue ;; esac
            [ "$kind" = source ] || continue
            [ "$c_buildable" = head ] || [ "$c_buildable" = yes ] || continue
            case "$c_arch" in all|both|"$a") ;; *) continue ;; esac
            # singularity payload + wraps are one unit (singularity-subprojects etc.)
            case "$comp" in singularity-subprojects|scenefx|wlroots|libsfdo|labwc|vetro|singularity-boot-splash|ncz-userland-shims) continue ;; esac
            build_component "$a" "$comp" || { warn "component $comp ($a) FAILED at HEAD"; rc=1; }
        done < "$REG"
    done
    # the singularity payload is one unit per arch (built from the resolved
    # HEADs); the whole stage is bounded by run_stage's watchdog.
    if [ -z "${NCZ_SINGULARITY_SKIP:-}" ]; then
        for a in ${ARCH_LIST}; do
            build_component "$a" ncz-singularity-desktop \
                || { warn "singularity payload ($a) FAILED at HEAD"; rc=1; }
        done
    fi
    return "$rc"
}

stage_ledger_candidates() {
    local prov="$PROV_TSV"
    [ -f "$prov" ] || { say "no component provenance recorded; candidates file will be header-only"; prov="/dev/null"; }
    bash "$HERE/nightly-ledger-candidates.sh" --run-id "$RUN_ID" \
        --out "$RUN_DIR/ledger-candidates.tsv" --provenance "$prov" \
        --deb-dir "$DEB_DIR/amd64" --deb-dir "$DEB_DIR/arm64"
}

stage_provenance_inputs() {
    # nightly mode: accept the run's freshly built candidates by sha; still fail
    # on any unknown package.  Index dir is required (fails closed).
    local idx="$RUN_DIR/prov-index"; mkdir -p "$idx"
    local args=(--ledger-mode nightly --ledger-candidates "$RUN_DIR/ledger-candidates.tsv"
                --index-dir "$idx" --fetch-index)
    [ -d "$DEB_DIR/amd64" ] && args+=(--debs "$DEB_DIR/amd64")
    [ -d "$DEB_DIR/arm64" ] && args+=(--debs "$DEB_DIR/arm64")
    ( cd "$ROOT" && bash build/check-forky-provenance.sh "${args[@]}" )
}

stage_shader_gate() {
    local rc=0 lw
    for lw in "$RUN_DIR"/singularity-sources/*/out/extract/opt/singularity/bin/labwc; do
        [ -f "$lw" ] || continue
        bash "$ROOT/build/check-singularity-shaders.sh" "$lw" || rc=$?
    done
    [ "$rc" = 0 ] || return "$rc"
    # fall back to any labwc already staged in the tree
    lw="$ROOT/assets/singularity/scenefx-smoke/bin/labwc"
    [ -f "$lw" ] && bash "$ROOT/build/check-singularity-shaders.sh" "$lw"
    return 0
}

stage_unit_tests() {
    # Component unit suites (meson test etc.) where present.  A suite that is
    # present and FAILS is a nightly failure (this is a canary: catching a broken
    # component at HEAD is the point); a suite that is absent is simply not run.
    local rc=0
    for t in "$ROOT"/build/test-singularity-shaders-gate.sh "$ROOT"/build/test-singularity-pins.sh; do
        [ -x "$t" ] && { bash "$t" >> "$RUN_DIR/logs/unit_tests.log" 2>&1 || rc=1; }
    done
    return "$rc"
}

stage_hw_smoke() {
    [ "$NO_HW" = 1 ] && { say "hw-smoke skipped (--no-hw)"; return 0; }
    bash "$HERE/nightly/hw-smoke.sh" --out "$RUN_DIR/hw-smoke.json" ${HW_EXECUTE:+--execute}
}

stage_weekly_image() {
    [ "$MODE" = weekly ] || { say "not weekly; no full build"; return 0; }
    local ledger=()
    if [ -s "$RUN_DIR/ledger-candidates.tsv" ]; then
        ledger=(--ledger-mode nightly --ledger-candidates "$RUN_DIR/ledger-candidates.tsv")
    fi
    ( cd "$ROOT" && bash build/build-image.sh --arch both --full --sources "$SOURCES" --no-publish "${ledger[@]}" ) || return 1
    # determinism compare on one arch (layers)
    if [ -x "$ROOT/build/test-build-determinism.sh" ]; then
        bash "$ROOT/build/test-build-determinism.sh" >> "$RUN_DIR/logs/determinism.log" 2>&1 || return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# status json + retention
# ---------------------------------------------------------------------------
write_status() { # rc
    local rc="$1"
    python3 - "$RUN_DIR" "$STATUS_DIR" "$RUN_ID" "$MODE" "$ARCH" "$rc" "$ARCH_LIST" <<'PYEOF'
import json, os, sys, time
run_dir, status_dir, run_id, mode, arch, rc, arch_list = sys.argv[1:8]
stages = []
p = os.path.join(run_dir, "stages.tsv")
if os.path.isfile(p):
    for ln in open(p):
        parts = ln.rstrip("\n").split("\t")
        if len(parts) >= 3:
            stages.append({"stage": parts[0], "result": parts[1], "seconds": int(parts[2]) if parts[2].isdigit() else 0})
first_fail = next((s for s in stages if s["result"].startswith("FAIL")), None)
meta = {}
mp = os.path.join(run_dir, "run-metadata.json")
if os.path.isfile(mp):
    try: meta = json.load(open(mp))
    except Exception: meta = {}
# suspect ranges vs the last green run's recorded resolved SHAs (best-effort)
suspects = []
green = os.path.join(status_dir, "last-green.json")
if os.path.isfile(green):
    try:
        g = json.load(open(green))
        for comp, shas in (g.get("resolved", {}) or {}).items():
            new = (meta.get("resolved", {}) or {}).get(comp)
            if new and new != shas:
                suspects.append({"component": comp, "from": shas, "to": new})
    except Exception:
        pass
status = {
    "schema": "ncz-nightly-status/v1",
    "run_id": run_id, "mode": mode, "arch": arch, "rc": int(rc),
    "green": int(rc) == 0 and all(s["result"] == "PASS" for s in stages if s["result"] != "SKIP"),
    "arch_list": arch_list.split(),
    "stages": stages,
    "first_failing_component": (first_fail or {}).get("stage"),
    "suspect_commits": suspects,
    "resolved": meta.get("resolved", {}),
    "finished_at": int(time.time()),
}
def w(path, obj):
    with open(path, "w") as fh:
        json.dump(obj, fh, indent=2, sort_keys=True); fh.write("\n")
w(os.path.join(status_dir, run_id + ".json"), status)
w(os.path.join(status_dir, "latest.json"), status)
if status["green"]:
    w(os.path.join(status_dir, "last-green.json"), status)
print("status:", "GREEN" if status["green"] else "RED",
      "first_fail=" + str(status["first_failing_component"]))
PYEOF
}

write_triage() { # rc
    local rc="$1"
    python3 - "$RUN_DIR" "$STATUS_DIR" "$RUN_ID" "$MODE" "$rc" <<'PYEOF'
import json, os, sys
run_dir, status_dir, run_id, mode, rc = sys.argv[1:6]
if int(rc) == 0:
    sys.exit(0)
lines = [f"# TRIAGE — nightly {mode} run {run_id}", "", "A red nightly is the point: this records what broke at HEAD.", ""]
latest = os.path.join(status_dir, "latest.json")
if os.path.isfile(latest):
    s = json.load(open(latest))
    ff = s.get("first_failing_component")
    lines += ["## First failing component", "", f"* stage/component: `{ff}`", ""]
    lines += ["## Stage results", ""]
    for st in s.get("stages", []):
        lines.append(f"* `{st['stage']}` — {st['result']} ({st['seconds']}s)")
    lines += ["", "## Suspect upstream commits (since the last green run)", ""]
    sus = s.get("suspect_commits") or []
    if sus:
        for c in sus:
            lines.append(f"* {c['component']}: `{c['from'][:12]}`..`{c['to'][:12]}`")
    else:
        lines.append("*(none recorded — first red run, or no prior green baseline)*")
    lines += ["", "## Log tails", ""]
    for st in s.get("stages", []):
        if st["result"].startswith("FAIL"):
            p = os.path.join(run_dir, "logs", st["stage"] + ".log")
            if os.path.isfile(p):
                lines += [f"### {st['stage']}", "```"]
                lines += open(p, errors="replace").read().splitlines()[-25:]
                lines += ["```", ""]
open(os.path.join(run_dir, "TRIAGE.md"), "w").write("\n".join(lines) + "\n")
print("wrote", os.path.join(run_dir, "TRIAGE.md"))
PYEOF
}

enforce_retention() {
    # keep the last 3 nightly run dirs and the last 2 weekly
    local keep_n=3 keep_w=2
    ls -1dt "$OUT_ROOT"/[0-9]* 2>/dev/null | tail -n +$((keep_n + 1)) | while read -r d; do
        say "retention: removing old nightly $d"; rm -rf "$d"
    done
    local wk="$OUT_ROOT/weekly"
    if [ -d "$wk" ]; then
        ls -1dt "$wk"/[0-9]* 2>/dev/null | tail -n +$((keep_w + 1)) | while read -r d; do
            say "retention: removing old weekly $d"; rm -rf "$d"
        done
    fi
}

# ---------------------------------------------------------------------------
# dry-run plan (no lock, no disk mutation beyond run dir)
# ---------------------------------------------------------------------------
ARCH_LIST=""
case "$ARCH" in both) ARCH_LIST="amd64 arm64" ;; amd64|arm64) ARCH_LIST="$ARCH" ;; esac

if [ "$DRY_RUN" = 1 ]; then
    echo "NCZ nightly canary plan"
    echo "  mode            $MODE"
    echo "  arch            $ARCH ($ARCH_LIST)"
    echo "  run id          $RUN_ID"
    echo "  out root        $OUT_ROOT"
    echo "  run dir         $RUN_DIR"
    echo "  sources         $SOURCES"
    echo "  unattended      $UNATTENDED"
    echo "  stage timeout   ${STAGE_TIMEOUT}s"
    echo "  max disk pct    $MAX_DISK_PCT"
    echo "  hardware smoke  $([ "$NO_HW" = 1 ] && echo off || echo on)"
    echo "  reaper          $([ "$NO_REAPER" = 1 ] && echo off || echo on)"
    echo
    echo "  stages:"
    for s in preflight refresh-substrate resolve-heads kernel-head-check rebuild-components \
             ledger-candidates provenance-inputs shader-gate unit-tests hw-smoke status retention; do
        echo "    - $s"
    done
    [ "$MODE" = weekly ] && echo "    - weekly-image (build-image.sh --arch both --full --sources $SOURCES --no-publish + determinism)"
    echo
    echo "  component actions (source-buildable):"
    while IFS=$'\t' read -r comp kind c_arch c_source c_recipe c_how c_headref c_buildable c_why c_resolver c_url c_ref; do
        case "$comp" in ''|\#*) continue ;; esac
        case "$c_buildable" in head|yes) ;; *) continue ;; esac
        printf '    %-28s %-6s %s\n' "$comp" "$c_arch" "$c_recipe"
    done < "$REG"
    echo
    echo "  NEVER: publish/tag/ship, write to ncz-os-assets/images/, GitHub/live Buildkite/R2, flash/reboot."
    exit 0
fi

# ---------------------------------------------------------------------------
# run
# ---------------------------------------------------------------------------
say "nightly canary mode=$MODE arch=$ARCH run=$RUN_ID root=$OUT_ROOT"
check_disk
run_fstype_check
if [ "$UNATTENDED" = 1 ]; then
    command -v ionice >/dev/null 2>&1 && ionice -c2 -n6 -p "$$" 2>/dev/null || true
    renice 10 -p "$$" >/dev/null 2>&1 || true
    run_reaper check
fi
trap 'release_lock' EXIT
if [ "$UNATTENDED" = 1 ]; then acquire_lock; fi

RC=0
# Each stage runs in a subshell with its own watchdog (see run_stage).  External
# helpers are invoked directly; shell stages are functions called by name (the
# subshell inherits every global they read).
run_stage preflight          stage_preflight            || RC=1
run_stage refresh-substrate  stage_refresh_substrate    || RC=1
run_stage resolve-heads      stage_resolve_heads        || RC=1
run_stage kernel-head-check  "bash" "$HERE/nightly/kernel-head-check.sh" --arch "$ARCH" --out "$RUN_DIR/kernel" \
                                 ${NCZ_AMD64_KERNEL_TREE:+--tree-amd64 "$NCZ_AMD64_KERNEL_TREE"} \
                                 ${NCZ_ARM64_KERNEL_TREE:+--tree-arm64 "$NCZ_ARM64_KERNEL_TREE"} || RC=1
if [ "$NO_BUILD" = 1 ]; then
    say "skip [rebuild-components] (--no-build)"
    printf 'rebuild-components\tSKIP\t0\n' >> "$STAGES_TSV"
else
    run_stage rebuild-components stage_rebuild_components || RC=1
fi
run_stage ledger-candidates  stage_ledger_candidates    || RC=1
run_stage provenance-inputs  stage_provenance_inputs    || RC=1
run_stage shader-gate        stage_shader_gate          || RC=1
run_stage unit-tests         stage_unit_tests           || RC=1
# hw-smoke writes its per-host status into hw-smoke.json and exits 0 for a
# SKIPPED host; a genuine tooling error (rc != 0) is NOT masked here.
run_stage hw-smoke           "bash" "$HERE/nightly/hw-smoke.sh" --out "$RUN_DIR/hw-smoke.json" ${NCZ_NIGHTLY_HW_EXECUTE:+--execute} || RC=1
if [ "$MODE" = weekly ]; then run_stage weekly-image stage_weekly_image || RC=1; fi

# run-metadata.json (resolved shas + build env)
python3 - "$RUN_DIR" "$RUN_ID" "$MODE" "$ARCH" "$SOURCES" "$ROOT" <<'PYEOF'
import json, os, subprocess, sys, time, socket
run_dir, run_id, mode, arch, sources, root = sys.argv[1:7]
resolved = {}
sdir = os.path.join(run_dir, "singularity-sources")
for a in os.listdir(sdir) if os.path.isdir(sdir) else []:
    p = os.path.join(sdir, a, "source-resolution.json")
    if os.path.isfile(p):
        try:
            d = json.load(open(p)); resolved["singularity/" + a] = d.get("pins_manifest_sha256")
        except Exception: pass
meta = {"schema": "ncz-nightly-run/v1", "run_id": run_id, "mode": mode, "arch": arch,
        "sources": sources, "git_commit": subprocess.run(["git", "-C", root, "rev-parse", "HEAD"],
        capture_output=True, text=True).stdout.strip(), "resolved": resolved,
        "host": socket.gethostname(), "finished_at": int(time.time())}
open(os.path.join(run_dir, "run-metadata.json"), "w").write(json.dumps(meta, indent=2, sort_keys=True) + "\n")
PYEOF

write_status "$RC"
write_triage "$RC"
enforce_retention

if [ "$UNATTENDED" = 1 ]; then run_reaper clean; fi
if [ "$RC" = 0 ]; then say "nightly canary COMPLETE (GREEN)"; else say "nightly canary finished RED (rc=$RC); see $RUN_DIR/TRIAGE.md"; fi
exit "$RC"
