#!/bin/bash
# build-image.sh -- THE single entrypoint for a repeatable, deterministic
# NCZ-OS install-image build.
#
#   build/build-image.sh --arch amd64|arm64|both [SCOPE] [OPTIONS]
#   make release-image ARCH=amd64 RELEASE_IMAGE_ARGS="--full"
#
# It runs the WHOLE pipeline in a fixed order, one stage per function, with a
# per-stage log under a run directory.  Every step the r202 reports did by hand
# (sudo password FIFO, /dev/kvm gid, kernel-staging bind mount, substrate
# pre-staging, stale-layer forcing, scratch exclusions, singularity prebuilt
# pin) is either automated here or a checked precondition with an actionable
# error.
#
# STAGES (fixed order; design rule 2026-10-10: provenance comes BEFORE the
# long stages -- a bad input must fail in minutes, not after hours of layers)
#   00 preflight          host, disk, tmpfs, tools, privilege, pins, substrate age
#   10 refresh-substrate  refresh/verify the pinned substrate (pin file)
#   20 stage-inputs       stage the checksum-pinned gitignored build inputs
#   30 refresh-sources    resolve+freeze the singularity payload sources, build its deb
#   40 offline-mirror     build the offline apt closure (stage 0)
#   50 provenance-inputs  PROVENANCE + one-kernel check on the INPUTS (fail fast)
#   60 layers             build the squashfs layers (stage 1)
#   70 image              assemble the raw GPT image + receipt (stage 2)
#   75 secret-scan        scan EVERY shipped byte for credentials (MANDATORY)
#   80 provenance-gate    forky provenance + one-kernel over the finished image
#   90 kvm-gate           install + boot the image in KVM + installer UI check
#   95 receipt            write the run metadata (NOT hashed) + gate summary
#   99 archive            copy to the image archive ONLY if every gate PASSed
#
# SCOPE (choose ONE; default --full)
#   --full                 substrate refresh + every layer + image + all gates
#   --respin,--quick-respin  reuse every layer whose input fingerprint is unchanged
#   --rebuild-base         base layer + everything above it + image
#   --rebuild-desktop      desktop layer (+ singularity payload) + hotfix + image
#   --rebuild-hotfix       hotfix layer + image
#   --components LIST      rebuild the minimum layers for the named components
#   --only-image           re-assemble the image from the cached layers
#
# OPTIONS
#   --no-publish           build + gates, never copy to the image archive
#   --gates kvm,provenance run only these gates (REQUIRES --no-publish)
#   --substrate refresh|pinned   substrate policy (refresh default for --full)
#   --resume-from STAGE    start at STAGE (skips earlier stages)
#   --run-dir DIR          run directory (logs + run metadata + tmp scratch)
#   --image PATH           an already-built image (for --resume-from kvm-gate+)
#   --host H               run on host H (remote over ssh when H is not local)
#   --container TAG        override the ncz-imagebuild container image tag
#   --jobs N               make job parallelism (never changes artifact bytes)
#   --keep-work            keep build scratch/work dirs instead of cleaning them
#   --clean                remove this run's scratch at the end (logs kept)
#   --offline              block all network; fail if anything needs to fetch
#   --dry-run              print the plan (stages + per-layer reuse) and exit
#   -h | --help            this help
#
# EXIT CODES
#   0  all requested stages passed
#   2  usage error (bad/duplicate/conflicting flags)
#   3  preflight precondition failed (actionable message printed)
#   4  determinism/pin error (base.pin stale, SDE underivable)
#   1  a build/gate stage failed (see the stage log)
#
# WHAT IT NEVER DOES: tag, ship-image, flash/reboot, reap, or touch a live
# repo/R2/Buildkite.  Those are operator-only.
# It refuses to copy a failing image to the archive: the archive stage is gated on
# the KVM + provenance gates having PASSed in this run.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
. "$ROOT/build/lib/reproducible.sh"
# shellcheck source=/dev/null
. "$ROOT/build/lib/priv.sh"
. "$ROOT/build/lib/ncz-site.sh"
LAYERPLAN_PY="$ROOT/build/lib/layerplan.py"

# ---------------------------------------------------------------------------
# argparse
# ---------------------------------------------------------------------------
ARCH="" RESUME_FROM="" RUN_DIR="" DRY_RUN=0 OFFLINE=0
USE_CONTAINER="${NCZ_BUILD_CONTAINER:-1}"
NO_ARCHIVE=0
IMAGE_ARG=""
KEEP_GOING=0
SCOPE=""              # full|respin|rebuild-base|rebuild-desktop|rebuild-hotfix|components|only-image
COMPONENTS=""         # comma list (scope=components)
GATES=""              # comma list; empty => all
NO_PUBLISH=0
SUBSTRATE=""          # refresh|pinned
SOURCES=""            # latest|pinned (singularity payload source pins)
HOST_OVERRIDE=""
JOBS=""
KEEP_WORK=0
CLEAN=0
CONTAINER_TAG=""
LAYERS_CHECK_ONLY=""  # standalone: run the per-layer post-checks on existing layers
ORIG_ARGS=("$@")      # for the both-arch re-dispatch
FORWARD=()            # child args (everything except --arch/--run-dir)

set_scope() {
    local want="$1"
    if [ -n "$SCOPE" ] && [ "$SCOPE" != "$want" ]; then
        echo "build-image.sh: scope '$SCOPE' and '$want' are mutually exclusive; choose ONE scope" >&2
        exit 2
    fi
    SCOPE="$want"
}

usage() {
    local rc="${1:-0}" out=1
    [ "$rc" != 0 ] && out=2
    cat >&$out <<'USAGE'
build-image.sh -- the single entrypoint for a repeatable, deterministic NCZ-OS install-image build.

  build/build-image.sh --arch amd64|arm64|both [SCOPE] [OPTIONS]
  make release-image ARCH=amd64 RELEASE_IMAGE_ARGS="--full"

STAGES (fixed order; provenance runs on the INPUTS before layers, and again on
the finished image BEFORE the KVM gate -- never waste hours on a doomed build)
  preflight  refresh-substrate  stage-inputs  refresh-sources  offline-mirror
  provenance-inputs  layers  image  secret-scan  provenance-gate  kvm-gate
  receipt  archive

  secret-scan is NOT optional and is NOT selectable via --gates: it runs on
  every image, immediately after 'image' and before the KVM gate.  It fails
  closed -- with no hash list ($NCZ_SECRET_HASHES_FILE, else
  ~/.config/ncz/secret-hashes-file naming it, else
  ~/.config/ncz/secret-hashes.json; never a path inside the repository) the
  build fails.  NCZ_SECRET_SCAN=skip is the ONE explicit opt-out for a build
  host without a hash list: the stage records SKIP, the gate summary is not
  all_required_passed, and the archive stage refuses the image.

SCOPE (choose ONE; default --full)
  --full                    substrate refresh + every layer + image + all gates
  --respin | --quick-respin reuse every layer whose input fingerprint is unchanged
  --rebuild-base            base layer + everything above it + image
  --rebuild-desktop         desktop layer (+ singularity payload) + hotfix + image
  --rebuild-hotfix          hotfix layer + image
  --components LIST         rebuild the minimum layers for the named components
  --only-image              re-assemble the image from the cached layers

OPTIONS
  --arch amd64|arm64|both   REQUIRED. 'both' builds the two arches in parallel on
                            their hosts (NCZ_AMD64_HOST, NCZ_ARM64_HOST)
  --no-publish              build + gates, never copy to the image archive
  --gates kvm,provenance    run only these gates (REQUIRES --no-publish)
  --substrate refresh|pinned  substrate policy (refresh is the --full default)
  --sources latest|pinned   singularity payload source pins: 'latest' resolves
                            the current upstream heads of every singularity
                            subproject (+ the labwc SceneFX/wlroots wraps) and
                            freezes them in the receipt; 'pinned' reproduces the
                            committed pins.  latest is the --full / --rebuild-
                            desktop default
  --resume-from STAGE       start at STAGE
  --run-dir DIR             run directory (logs, run metadata, tmp scratch)
  --image PATH              an already-built image (kvm-gate+ resume)
  --host H                  assert this host (or dispatch to it over ssh)
  --container TAG           override the ncz-imagebuild container tag
  --jobs N                  make job parallelism (never changes artifact bytes)
  --keep-work               keep build scratch instead of cleaning it
  --clean                   remove this run's scratch at the end (logs kept)
  --offline                 block all network; fail if anything must fetch
  --dry-run                 print the plan (stages + per-layer reuse) and exit
  --layers-check-only DIR   run the per-layer post-checks (build/check-layers.sh)
                            against EXISTING layers (a dir of *.squashfs or one
                            layer) and exit; prove the checks without a rebuild
  -h | --help               this help

WHICH FLAG DO I USE?
  new substrate / weekly build      --full
  one package changed               --components <name>
  desktop / singularity bump        --rebuild-desktop
  base change                       --rebuild-base
  both arches                       --arch both
  re-assemble from cached layers    --only-image
  local build, no copy to the archive   --no-publish

COMPONENTS
  kernel, base-assets, apt-policy, post-install, base, desktop, desktop-mirror,
  singularity, screensavers, wallpapers, plugins, installer-initrd, preseed, image

EXIT CODES
  0 all requested stages passed; 2 usage error; 3 preflight failed;
  4 pin/determinism error; 1 a build/gate stage failed.

WHAT IT NEVER DOES: tag, ship-image, flash/reboot, reap, or touch a live
repo/R2/Buildkite.  Those are operator-only.
It refuses to copy a failing image to the archive: the archive stage is gated on
the KVM + provenance gates having PASSed in this run.
USAGE
    exit "$rc"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --arch) ARCH="${2:?--arch needs amd64|arm64|both}"; shift 2 ;;
        --run-dir) RUN_DIR="${2:?--run-dir needs a path}"; shift 2 ;;
        --full) set_scope full; FORWARD+=("$1"); shift ;;
        --respin|--quick-respin) set_scope respin; FORWARD+=("--respin"); shift ;;
        --rebuild-base) set_scope rebuild-base; FORWARD+=("$1"); shift ;;
        --rebuild-desktop) set_scope rebuild-desktop; FORWARD+=("$1"); shift ;;
        --rebuild-hotfix) set_scope rebuild-hotfix; FORWARD+=("$1"); shift ;;
        --only-image) set_scope only-image; FORWARD+=("$1"); shift ;;
        --components) COMPONENTS="${2:?--components needs a comma list}"; set_scope components; FORWARD+=("--components" "$2"); shift 2 ;;
        --gates) GATES="${2:?--gates needs a comma list}"; FORWARD+=("--gates" "$2"); shift 2 ;;
        --no-publish) NO_PUBLISH=1; FORWARD+=("--no-publish"); shift ;;
        --publish) NO_PUBLISH=0; shift ;;
        --substrate) SUBSTRATE="${2:?--substrate needs refresh|pinned}"; FORWARD+=("--substrate" "$2"); shift 2 ;;
        --sources) SOURCES="${2:?--sources needs latest|pinned}"; FORWARD+=("--sources" "$2"); shift 2 ;;
        --resume-from) RESUME_FROM="${2:?--resume-from needs a stage}"; FORWARD+=("--resume-from" "$2"); shift 2 ;;
        --image) IMAGE_ARG="${2:?--image needs a path}"; FORWARD+=("--image" "$2"); shift 2 ;;
        --host) HOST_OVERRIDE="${2:?--host needs a host}"; shift 2 ;;
        --container) CONTAINER_TAG="${2:?--container needs a tag}"; FORWARD+=("--container" "$2"); shift 2 ;;
        --jobs) JOBS="${2:?--jobs needs N}"; FORWARD+=("--jobs" "$2"); shift 2 ;;
        --keep-work) KEEP_WORK=1; FORWARD+=("--keep-work"); shift ;;
        --clean) CLEAN=1; FORWARD+=("--clean"); shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --layers-check-only) LAYERS_CHECK_ONLY="${2:?--layers-check-only needs a dir or layer path}"; shift 2 ;;
        --offline) OFFLINE=1; FORWARD+=("--offline"); shift ;;
        --no-container) USE_CONTAINER=0; FORWARD+=("--no-container"); shift ;;
        --no-archive) NO_ARCHIVE=1; FORWARD+=("--no-archive"); shift ;;
        --keep-going) KEEP_GOING=1; FORWARD+=("--keep-going"); shift ;;
        -h|--help) usage 0 ;;
        --) shift; break ;;
        *) echo "build-image.sh: unknown argument: $1" >&2; usage 2 ;;
    esac
done

# ---------------------------------------------------------------------------
# validation (actionable, before any host work)
# ---------------------------------------------------------------------------
die2() { echo "build-image.sh: $*" >&2; exit 2; }
case "$ARCH" in
    amd64|arm64|both) ;;
    "") die2 "--arch amd64|arm64|both is required" ;;
    *)  die2 "bad --arch '$ARCH' (expected amd64|arm64|both)" ;;
esac

# ---------------------------------------------------------------------------
# --layers-check-only DIR : run the per-layer post-checks (build/check-layers.sh)
# against EXISTING layers (a dir of *.squashfs, or a single layer), then exit.
# DESIGN RULE 2026-10-10: this is how the checks are proven on the r202
# layers without rebuilding anything.
# ---------------------------------------------------------------------------
if [ -n "$LAYERS_CHECK_ONLY" ]; then
    [ "$ARCH" = both ] && die2 "--layers-check-only needs a single --arch (amd64|arm64)"
    _lc_targets=()
    if [ -d "$LAYERS_CHECK_ONLY" ]; then
        while IFS= read -r _f; do _lc_targets+=("$_f"); done \
            < <(find "$LAYERS_CHECK_ONLY" -maxdepth 1 -name '*.squashfs' | sort)
        [ "${#_lc_targets[@]}" -gt 0 ] || die2 "no *.squashfs found in $LAYERS_CHECK_ONLY"
    elif [ -e "$LAYERS_CHECK_ONLY" ]; then
        _lc_targets=("$LAYERS_CHECK_ONLY")
    else
        die2 "path not found: $LAYERS_CHECK_ONLY"
    fi
    _lc_rc=0
    for _l in "${_lc_targets[@]}"; do
        bash "$ROOT/build/check-layers.sh" "$_l" --arch "$ARCH" \
            --stage layers-check-only \
            ${RUN_DIR:+--run-dir "$RUN_DIR"} || _lc_rc=1
    done
    echo "[layers-check-only] arch=$ARCH targets=${#_lc_targets[@]} rc=$_lc_rc"
    exit "$_lc_rc"
fi

: "${SCOPE:=full}"
case "$SCOPE" in
    respin) SCOPE=respin ;;
esac
case "$SUBSTRATE" in
    "") [ "$SCOPE" = full ] && SUBSTRATE=refresh || SUBSTRATE=pinned ;;
    refresh|pinned) ;;
    *) die2 "bad --substrate '$SUBSTRATE' (expected refresh|pinned)" ;;
esac
# Singularity payload source pins: 'latest' resolves the current upstream heads
# of every singularity subproject (+ the labwc compositor wraps) and freezes them
# in the receipt; 'pinned' uses assets/singularity/upstream-pins.tsv unchanged.
case "$SOURCES" in
    "") case "$SCOPE" in
            full|rebuild-desktop) SOURCES=latest ;;
            *) SOURCES=pinned ;;
        esac ;;
    latest|pinned) ;;
    *) die2 "bad --sources '$SOURCES' (expected latest|pinned)" ;;
esac
if [ -n "$GATES" ]; then
    [ "$NO_PUBLISH" = 1 ] || die2 "--gates may only be used together with --no-publish (a build that skips a gate can never be published)"
    for g in ${GATES//,/ }; do
        case "$g" in
            kvm|provenance) ;;
            ui) die2 "'ui' is a sub-check of the kvm gate; select 'kvm' (it runs the installer-UI check)" ;;
            *) die2 "unknown gate '$g' (known: kvm,provenance)" ;;
        esac
    done
fi
if [ -n "$JOBS" ] && ! [[ "$JOBS" =~ ^[1-9][0-9]*$ ]]; then die2 "--jobs needs a positive integer"; fi
if [ "$ARCH" = both ] && [ -n "$HOST_OVERRIDE" ]; then
    die2 "--host is per-arch; with --arch both set NCZ_AMD64_HOST / NCZ_ARM64_HOST instead"
fi
if [ "$SCOPE" = components ]; then
    [ -n "$COMPONENTS" ] || die2 "--components needs a non-empty list (kernel,singularity,screensavers,wallpapers,installer-initrd,preseed,post-install,apt-policy,plugins,...)"
    for c in ${COMPONENTS//,/ }; do
        python3 -I "$LAYERPLAN_PY" components "$c" >/dev/null 2>&1 || die2 "unknown component '$c'"
    done
fi

# ---------------------------------------------------------------------------
# generic helpers
# ---------------------------------------------------------------------------
ncz_log()  { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
ncz_info() { ncz_log "INFO  $*"; }
ncz_warn() { ncz_log "WARN  $*" >&2; }
ncz_err()  { ncz_log "ERROR $*" >&2; }

# ---------------------------------------------------------------------------
# --arch both : parallel orchestration on the two hosts
# ---------------------------------------------------------------------------
# Each arch runs in its own child process (own run dir + log) so one failing
# arch cannot kill the other mid-write.  The combined exit code is non-zero if
# EITHER arch failed.  NCZ_ORCH_CMD (a template with {arch} {host} {run_dir}
# {log} {args}) overrides the transport; the default is ssh to the arch host.
run_arch_remote() {
    local arch="$1" host="$2" base_run="$3" log="$4"; shift 4
    local run_dir="$base_run/$arch"
    mkdir -p "$base_run"
    if [ -n "${NCZ_ORCH_CMD:-}" ]; then
        local cmd="$NCZ_ORCH_CMD"
        cmd="${cmd//\{arch\}/$arch}"; cmd="${cmd//\{host\}/$host}"
        cmd="${cmd//\{run_dir\}/$run_dir}"; cmd="${cmd//\{log\}/$log}"
        cmd="${cmd//\{args\}/$*}"
        ( eval "$cmd" ) >>"$log" 2>&1
        return $?
    fi
    local remote_root="${NCZ_REMOTE_ROOT:-$ROOT}"
    local child="--arch $arch --run-dir '$run_dir' $*"
    ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" \
        "cd '$remote_root' && bash build/build-image.sh $child" >>"$log" 2>&1
    return $?
}

run_both() {
    local base_run="${RUN_DIR:-$HOME/Projects/ncz-build-runs/both-$(date -u +%Y%m%d)}"
    # Hosts are [user@]host ssh targets: NCZ_AMD64_HOST / NCZ_ARM64_HOST or
    # ~/.config/ncz/{amd64,arm64}-build-host (build/lib/ncz-site.sh).
    local h64 hA
    h64="$(ncz_site_value NCZ_AMD64_HOST amd64-build-host)"
    hA="$(ncz_site_value NCZ_ARM64_HOST arm64-build-host)"
    if [ -z "$h64" ] || [ -z "$hA" ]; then
        ncz_err "--arch both needs the two build hosts: set NCZ_AMD64_HOST and NCZ_ARM64_HOST ([user@]host) or ~/.config/ncz/amd64-build-host and arm64-build-host"
        return 2
    fi
    mkdir -p "$base_run"
    ncz_info "both-arch build: amd64@$h64  arm64@$hA  run=$base_run"
    local p64 pA rc64 rcA
    run_arch_remote amd64 "$h64" "$base_run" "$base_run/amd64.log" "$@" & p64=$!
    run_arch_remote arm64 "$hA" "$base_run" "$base_run/arm64.log" "$@" & pA=$!
    wait "$p64"; rc64=$?
    wait "$pA"; rcA=$?
    {
        echo "== both-arch build summary =="
        echo "  amd64@$h64 : rc=$rc64  log=$base_run/amd64.log"
        echo "  arm64@$hA : rc=$rcA  log=$base_run/arm64.log"
        if [ "$rc64" = 0 ] && [ "$rcA" = 0 ]; then echo "  RESULT: BOTH PASS"; else echo "  RESULT: FAIL (amd64=$rc64 arm64=$rcA)"; fi
    } | tee "$base_run/SUMMARY.txt"
    [ "$rc64" = 0 ] && [ "$rcA" = 0 ] && return 0
    return 1
}

if [ "$ARCH" = both ]; then
    if [ "$DRY_RUN" = 1 ]; then
        echo "NCZ-OS image build plan (both arches, parallel)"
        _h="$(ncz_site_value NCZ_AMD64_HOST amd64-build-host)"; echo "  amd64 host  ${_h:-<unset: NCZ_AMD64_HOST>}"
        _h="$(ncz_site_value NCZ_ARM64_HOST arm64-build-host)"; echo "  arm64 host  ${_h:-<unset: NCZ_ARM64_HOST>}"
        echo "  scope       $SCOPE${COMPONENTS:+ ($COMPONENTS)}"
        echo "  substrate   $SUBSTRATE"
        echo "  gates       ${GATES:-kvm,provenance}"
        echo "  publish     $([ "$NO_PUBLISH" = 1 ] && echo no || echo 'yes (only if gates PASS)')"
        echo "  (each arch prints its own per-stage plan on its host)"
        exit 0
    fi
    run_both "${FORWARD[@]}"; exit $?
fi

# ---------------------------------------------------------------------------
# Kernel staging resolution (handles per-host mount spellings)
# ---------------------------------------------------------------------------
# assets/kernel/mainline is a build-local link (untracked) to the staged Sky1
# kernel release named in assets/kernel/mainline.release, generated by
# build/link-kernel-mainline.sh under this host's kernel-staging pool
# (NCZ_YOCTO_SHARED_DIR/kernel-staging).  A link left by an older tree that
# uses another host's mount spelling is still resolved through the pool
# alternate (the bind mount in preflight).
ncz_resolve_kver() {
    local arch="$1" k t
    if [ "$arch" = "amd64" ]; then
        k="$(tr -d '[:space:]' < "$ROOT/assets/kernel/amd64-stable/KVER" 2>/dev/null || true)"
        [ -n "$k" ] && { printf '%s\n' "$k"; return 0; }
    fi
    if [ -f "$ROOT/assets/kernel/mainline/KVER" ]; then
        tr -d '[:space:]' < "$ROOT/assets/kernel/mainline/KVER"; printf '\n'; return 0
    fi
    t="$(readlink "$ROOT/assets/kernel/mainline" 2>/dev/null || true)"
    [ -n "$t" ] || t="$(sed 's/#.*//' "$ROOT/assets/kernel/mainline.release" 2>/dev/null | tr -d '[:space:]')"
    [ -n "$t" ] && { basename "$t" | sed -E 's/^r[0-9]+-(.+)-sky1-ncz-[0-9]+$/\1/'; return 0; }
    return 1
}

ncz_kernel_staging_dir() {
    local target
    target="$(readlink "$ROOT/assets/kernel/mainline" 2>/dev/null || true)"
    [ -n "$target" ] && dirname "$target"
}

# ---------------------------------------------------------------------------
# Stages
# ---------------------------------------------------------------------------
STAGES=(preflight refresh-substrate stage-inputs refresh-sources offline-mirror \
        provenance-inputs layers image secret-scan provenance-gate kvm-gate \
        receipt archive)
stage_index() {
    local want="$1" i=0 s
    for s in "${STAGES[@]}"; do [ "$s" = "$want" ] && { echo "$i"; return 0; }; i=$((i+1)); done
    return 1
}

# ---------------------------------------------------------------------------
# Paths / pins
# ---------------------------------------------------------------------------
DOWNLOADS="$ROOT/downloads"
BUILD="$ROOT/build"
UPSTREAM_ISO="debian-testing-${ARCH}-netinst.iso"

ncz_repro_init "$ROOT" || exit 4
ncz_repro_env || exit 4
export NCZ_REPRO_ARCH="$ARCH"

GIT_SHA="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || true)"
GIT_FULL="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || true)"
if [ -z "$GIT_SHA" ]; then
    echo "build-image.sh: cannot read the git HEAD SHA (dubious ownership? detached?)" >&2
    exit 4
fi
PIN_DIGEST="$(ncz_pin_digest)" || exit 4
SUBSTRATE_SHA="$(make -C "$ROOT" --no-print-directory -s print-substrate-sha ARCH="$ARCH" | tr -d '[:space:]')"
if [ -z "$SUBSTRATE_SHA" ]; then
    echo "build-image.sh: no substrate pin for $ARCH (make print-substrate-sha empty)" >&2
    exit 4
fi
BUILD_DATE="$(date -u +%Y%m%d)"
: "${RUN_DIR:=$HOME/Projects/ncz-build-runs/${ARCH}-${BUILD_DATE}-${GIT_SHA}}"
RUN_DIR="$(cd "$RUN_DIR" 2>/dev/null && pwd || { mkdir -p "$RUN_DIR" && cd "$RUN_DIR" && pwd; })"
LOGS="$RUN_DIR/logs"
mkdir -p "$LOGS" "$RUN_DIR/tmp"
# Image variant: desktop (default) or server (Magnetar). Only the image stage
# and the gates after it read it; every earlier stage is identical.
NCZ_VARIANT="${NCZ_VARIANT:-desktop}"
case "$NCZ_VARIANT" in
    desktop|server) ;;
    *) echo "build-image.sh: NCZ_VARIANT must be desktop or server, got '$NCZ_VARIANT'" >&2; exit 2 ;;
esac
# Magnetar payload (base.squashfs + the asset bundle) the server medium pins:
# kept in the run dir for the secret scan, provenance and the KVM gate's
# local payload server; never uploaded by this script.
MAGNETAR_DIR="$RUN_DIR/payload"
# All scratch lives on the run dir's disk, never a tmpfs (policy).
export TMPDIR="$RUN_DIR/tmp"

# Host-level build lock (design rule 2026-10-10: layers-preflight checks
# "no other build holding the lock").  One build per build-runs dir; a stale lock
# (dead pid) is reclaimed; a live holder aborts this run before any work.
NCZ_BUILD_LOCK="${NCZ_BUILD_LOCK:-$(dirname "$RUN_DIR")/.ncz-build.lock}"
export NCZ_BUILD_LOCK NCZ_BUILD_LOCK_OWNER="$$"
if [ "$DRY_RUN" != 1 ]; then
    # Atomic acquisition via noclobber (O_EXCL): the redirect fails if the file
    # already exists, so two concurrent builds cannot both win (code review
    # 2026-10-10: the previous check-then-write was racy).
    _ncz_lock_acquire() { ( set -o noclobber; printf '%s\n' "$$" > "$NCZ_BUILD_LOCK" ) 2>/dev/null; }
    if ! _ncz_lock_acquire; then
        _lock_holder="$(tr -dc '0-9' <"$NCZ_BUILD_LOCK" 2>/dev/null | head -c 12)"
        if [ -n "$_lock_holder" ] && [ "$_lock_holder" != "$$" ] && kill -0 "$_lock_holder" 2>/dev/null; then
            echo "build-image.sh: another build (pid $_lock_holder) holds $NCZ_BUILD_LOCK" >&2
            echo "build-image.sh: refusing to run two builds on one host (layers/image/kvm all contend)" >&2
            exit 3
        fi
        # Stale (dead holder): drop it and retry atomically.
        rm -f "$NCZ_BUILD_LOCK" 2>/dev/null || true
        if ! _ncz_lock_acquire; then
            echo "build-image.sh: lost the race for $NCZ_BUILD_LOCK (another build started)" >&2
            exit 3
        fi
    fi
    trap 'rm -f "$NCZ_BUILD_LOCK" 2>/dev/null || true' EXIT
fi

RUN_PIN="$RUN_DIR/run.pin"
# generate the build-local assets/kernel/mainline link before anything reads it
MAINLINE_LINK_MSG="$(bash "$ROOT/build/link-kernel-mainline.sh" 2>&1)"; MAINLINE_LINK_RC=$?
KVER="$(ncz_resolve_kver "$ARCH" || true)"
ncz_pin_arch_file "$RUN_PIN" "$ARCH" "$SUBSTRATE_SHA" "" "$KVER" "" || exit 4

export SOURCE_DATE_EPOCH
export NCZ_IMAGEBUILD_TAG="${CONTAINER_TAG:-${NCZ_IMAGEBUILD_TAG:-localhost/ncz-imagebuild:trixie}}"
export NCZ_TARGET_ARCH="$ARCH"

# ---------------------------------------------------------------------------
# Layer plan (fingerprints + reuse/rebuild decisions)
# ---------------------------------------------------------------------------
LAYERS_DIR="${NCZ_LAYERS_DIR:-$ROOT/assets/squashfs}"
plan_json() {
    local comps="${COMPONENTS:-}"
    python3 -I "$LAYERPLAN_PY" plan --arch "$ARCH" --mode "$SCOPE" \
        --components "$comps" --layers-dir "$LAYERS_DIR" \
        --root "$ROOT" --pin "$NCZ_PIN_FILE"
}
PLAN_JSON="$(plan_json)" || { echo "build-image.sh: layer plan failed" >&2; exit 4; }
plan_get() { printf '%s' "$PLAN_JSON" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d$1)"; }
LAYER_DECISION() { plan_get "['layers']['$1']"; }
LAYER_FP() { plan_get "['fingerprints']['$1']"; }
# env contract with build-squashfs-layers.sh: "base=rebuild,desktop=reuse,..."
NCZ_LAYER_PLAN="mirror=$(LAYER_DECISION mirror),base=$(LAYER_DECISION base),desktop=$(LAYER_DECISION desktop),hotfix=$(LAYER_DECISION hotfix)"
export NCZ_LAYER_PLAN
export NCZ_LAYERS_DIR="$LAYERS_DIR"
export NCZ_JOBS="${JOBS:-}"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
RUN_START="$(date -u +%s)"
STAGE_TIMES="$RUN_DIR/stages.tsv"
: > "$STAGE_TIMES"

# ---------------------------------------------------------------------------
# Container helper
# ---------------------------------------------------------------------------
# Run a make target (or shell line) inside the pinned ncz-imagebuild container.
# Rootful podman; the substrate is pre-staged into downloads/ so the container
# does not need the host SUBSTRATE_CACHE_DIRS (r202 workaround #4).
ncz_container_run() {
    local line="$1" log="$2"
    local -a mk=()
    [ -n "$JOBS" ] && mk=(-j "$JOBS")
    if [ "$USE_CONTAINER" != "1" ]; then
        ( cd "$ROOT" && for kv in "${NCZ_CRUN_HOSTENV[@]}"; do export "${kv?}"; done
          bash -lc "$line" ) 2>&1 | tee -a "$log"
        return "${PIPESTATUS[0]}"
    fi
    local ks; ks="$(ncz_kernel_staging_dir || true)"
    local -a mounts=(-v "$ROOT":/work/cix-installer -v /dev:/dev)
    [ -n "$ks" ] && [ -d "$(dirname "$ks")" ] && mounts+=(-v "$(dirname "$ks")":"$(dirname "$ks")")
    local ysd; ysd="$(ncz_site_value NCZ_YOCTO_SHARED_DIR yocto-shared-dir)"
    [ -n "$ysd" ] && [ -d "$ysd" ] && mounts+=(-v "$ysd":"$ysd")
    # Extra env/mounts for ONE call (the server image stage); empty otherwise,
    # so every other container run is unchanged.
    [ "${#NCZ_CRUN_MOUNTS[@]}" -gt 0 ] && mounts+=("${NCZ_CRUN_MOUNTS[@]}")
    local -a renv=(
        -e NCZ_TARGET_ARCH="$ARCH" -e HOME=/root
        -e SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" -e LC_ALL=C -e LANG=C -e TZ=UTC
        -e NCZ_OFFLINE="${NCZ_OFFLINE:-0}"
        -e NCZ_REPRO_ARCH="$ARCH"
        -e NCZ_PIN_FILE=/work/cix-installer/manifests/base.pin
    )
    local kv
    while IFS= read -r kv; do renv+=(-e "$kv"); done < <(ncz_repro_env_assignments "$ARCH")
    [ "${#NCZ_CRUN_ENV[@]}" -gt 0 ] && renv+=("${NCZ_CRUN_ENV[@]}")
    ncz_sudo podman run --rm --privileged --net=host "${mounts[@]}" \
        -w /work/cix-installer "${renv[@]}" \
        "$NCZ_IMAGEBUILD_TAG" \
        bash -lc "git config --global --add safe.directory '*'; $line" 2>&1 | tee -a "$log"
    return "${PIPESTATUS[0]}"
}

# ---------------------------------------------------------------------------
# Stage runner
# ---------------------------------------------------------------------------
RUN_FROM="$(stage_index "${RESUME_FROM:-preflight}")" || {
    echo "build-image.sh: unknown --resume-from stage '${RESUME_FROM}'" >&2; exit 2
}

should_skip() {
    local idx; idx="$(stage_index "$1")"
    [ "$idx" -lt "$RUN_FROM" ] && return 0
    return 1
}

run_stage() {
    local name="$1" fn="$2"
    local idx; idx="$(stage_index "$name")"
    local log; log="$(printf '%s/%02d-%s.log' "$LOGS" "$idx" "$name")"
    if should_skip "$name"; then
        ncz_log "SKIP  [$name] (before --resume-from ${RESUME_FROM})"
        printf '%02d\t%s\tSKIP\t0\n' "$idx" "$name" >> "$STAGE_TIMES"
        return 0
    fi
    local t0; t0="$(date -u +%s)"
    ncz_log "BEGIN [$name] log=$log"
    local rc=0
    if [ -n "${NCZ_TEST_STAGE_CMD:-}" ]; then
        # Test-only hook (build/test-build-image.sh): run a fake stage command so
        # the stage ORDER and the abort-on-failure behaviour can be asserted
        # without a real build.  ${stage} expands to the stage name.
        local line="${NCZ_TEST_STAGE_CMD//\{stage\}/$name}"
        ( set -o pipefail; eval "$line" ) 2>&1 | tee -a "$log"; rc="${PIPESTATUS[0]}"
    else
        ( set -o pipefail; "$fn" "$log" ) 2>&1 | tee -a "$log"; rc="${PIPESTATUS[0]}"
    fi
    local t1; t1="$(date -u +%s)"
    printf '%02d\t%s\t%s\t%s\n' "$idx" "$name" \
        "$([ "$rc" = 0 ] && echo PASS || echo "FAIL:$rc")" "$((t1 - t0))" >> "$STAGE_TIMES"
    if [ "$rc" != 0 ]; then
        ncz_err "[$name] FAILED rc=$rc (log: $log)"
        return "$rc"
    fi
    ncz_log "OK    [$name] ($((t1 - t0))s)"
    return 0
}

# ---------------------------------------------------------------------------
# Stage 00 -- preflight
# ---------------------------------------------------------------------------
stage_preflight() {
    local log="$1"
    local fail=0
    say() { printf '[preflight] %s\n' "$*" | tee -a "$log"; }
    bad() { printf '[preflight] FAIL: %s\n' "$*" | tee -a "$log" >&2; fail=1; }

    say "arch=$ARCH host=$(hostname -s) git=$GIT_SHA sde=$SOURCE_DATE_EPOCH mode=$SCOPE"
    say "run-dir=$RUN_DIR pin-digest=$PIN_DIGEST"

    # -- host override -----------------------------------------------------
    if [ -n "$HOST_OVERRIDE" ] && [ "$HOST_OVERRIDE" != "$(hostname -s)" ] \
       && [ "$HOST_OVERRIDE" != "$(hostname)" ]; then
        bad "--host $HOST_OVERRIDE is not this host ($(hostname -s)); run build-image.sh ON the target host (or use --arch both)"
    fi

    # -- privilege model ---------------------------------------------------
    local model; model="$(ncz_priv_model || true)"
    case "$model" in
        root|sudo-nopasswd) say "privilege: $model" ;;
        sudo-stdin) say "privilege: sudo-stdin (from $NCZ_SUDO_PASS_FILE, stdin only)" ;;
        *) bad "no usable privilege model (need root or sudo; see build/lib/priv.sh)" ;;
    esac
    printf '%s\n' "$model" > "$RUN_DIR/priv.model"

    # -- scratch must not be on tmpfs --------------------------------------
    local fstype
    fstype="$(findmnt -no FSTYPE -T "$RUN_DIR" 2>/dev/null || stat -f -c %T "$RUN_DIR" 2>/dev/null || echo unknown)"
    case "$fstype" in
        tmpfs|ramfs) bad "run dir $RUN_DIR is on $fstype; put --run-dir on a real disk (never build on tmpfs)" ;;
        *) say "run dir fs=$fstype (TMPDIR=$TMPDIR)" ;;
    esac

    # -- git cleanliness ---------------------------------------------------
    if [ -n "$(git -C "$ROOT" status --porcelain 2>/dev/null)" ]; then
        say "WARN: git tree is not clean; the artifact will record git=$GIT_FULL"
    fi

    # -- pin + substrate freshness ----------------------------------------
    # Two committed pins: manifests/base.pin (substrate/snapshot provenance,
    # check-substrate-pin.sh) and manifests/determinism.pin (local input-ledger
    # aggregate, gen-base-pin.sh --check).
    if [ -f "$ROOT/build/check-substrate-pin.sh" ]; then
        if bash "$ROOT/build/check-substrate-pin.sh" "$ARCH" >>"$log" 2>&1; then
            say "substrate pin OK (check-substrate-pin.sh)"
        else
            if [ "$SUBSTRATE" = refresh ]; then
                say "substrate pin stale/absent; the refresh-substrate stage will refresh it"
            else
                bad "substrate pin failed and --substrate pinned forbids a refresh; run with --substrate refresh"
            fi
        fi
    else
        bad "build/check-substrate-pin.sh is missing; the substrate pin cannot be verified"
    fi
    if ! bash "$ROOT/build/gen-base-pin.sh" --check >>"$log" 2>&1; then
        bad "manifests/determinism.pin is stale; run build/gen-base-pin.sh and commit it"
    else
        say "determinism.pin OK (base digest $PIN_DIGEST)"
    fi
    say "run pin: $RUN_PIN"

    # -- required host tools ----------------------------------------------
    local tools="git make python3 mksquashfs mkfs.ext4 sgdisk tar sha256sum zstd unsquashfs"
    [ "$USE_CONTAINER" = "1" ] && tools="$tools podman"
    [ "$USE_CONTAINER" = "1" ] || tools="$tools rsync mformat"
    local t missing=""
    for t in $tools; do command -v "$t" >/dev/null 2>&1 || missing="$missing $t"; done
    if [ -n "$missing" ]; then bad "missing host tools:$missing"; else say "host tools OK"; fi

    # -- container image ---------------------------------------------------
    if [ "$USE_CONTAINER" = "1" ]; then
        if ncz_sudo podman image exists "$NCZ_IMAGEBUILD_TAG" 2>/dev/null; then
            say "container image present: $NCZ_IMAGEBUILD_TAG"
        else
            bad "container image $NCZ_IMAGEBUILD_TAG not found; build it from build/containers/Containerfile.ncz-imagebuild and 'podman save | sudo podman load', or pass --no-container"
        fi
    fi

    # -- kernel staging visible -------------------------------------------
    if [ "$MAINLINE_LINK_RC" = 0 ]; then
        say "kernel mainline link: $MAINLINE_LINK_MSG"
    elif [ "$ARCH" = arm64 ]; then
        bad "kernel mainline link: $MAINLINE_LINK_MSG"
    else
        say "kernel mainline link (Sky1 only, not needed for amd64): $MAINLINE_LINK_MSG"
    fi
    local ks; ks="$(ncz_kernel_staging_dir || true)"
    if [ -n "$ks" ] && [ ! -e "$ks" ]; then
        local alt; alt="$(ncz_kernel_pool_alt "$ks")"
        if [ -n "$alt" ] && [ -e "$alt" ]; then
            local rootspell; rootspell="$(dirname "$ks")"
            say "kernel staging $ks missing; bind-mounting $(dirname "$alt") -> $rootspell (automated r202 workaround #3)"
            ncz_sudo mkdir -p "$rootspell" >>"$log" 2>&1
            if ncz_sudo mountpoint -q "$rootspell" 2>/dev/null || ncz_sudo mount --bind "$(dirname "$alt")" "$rootspell" >>"$log" 2>&1; then
                say "bind mount OK: $rootspell"
            else
                bad "could not make $ks visible (bind mount failed); mount the kernel-staging pool or fix assets/kernel/mainline"
            fi
        else
            bad "kernel staging $ks not visible and no alternate pool found (assets/kernel/mainline)"
        fi
    elif [ -n "$ks" ]; then
        say "kernel staging visible: $ks"
    fi
    if [ -n "$KVER" ]; then say "kernel KVER=$KVER"; else bad "could not resolve the kernel KVER (assets/kernel/...)"; fi

    # -- substrate pre-staged ---------------------------------------------
    if [ -f "$DOWNLOADS/$UPSTREAM_ISO" ] && \
       [ "$(sha256sum "$DOWNLOADS/$UPSTREAM_ISO" | awk '{print $1}')" = "$SUBSTRATE_SHA" ]; then
        say "substrate pre-staged and pinned: $UPSTREAM_ISO ($SUBSTRATE_SHA)"
    else
        if [ "$OFFLINE" = "1" ]; then
            bad -- "--offline but the pinned substrate is not pre-staged in downloads/"
        else
            say "substrate not staged yet; the refresh-substrate stage will fetch it"
        fi
    fi

    # -- layer plan --------------------------------------------------------
    say "layer plan: $NCZ_LAYER_PLAN"
    for lyr in base desktop hotfix; do say "  $lyr fingerprint $(LAYER_FP "$lyr" | cut -c1-16)"; done

    # -- disk space --------------------------------------------------------
    local need_mb=$((20 * 1024))
    local avail_mb
    avail_mb="$(df -Pm "$RUN_DIR" 2>/dev/null | awk 'NR==2{print $4}')"
    if [ -n "$avail_mb" ] && [ "$avail_mb" -lt "$need_mb" ]; then
        bad "only ${avail_mb}MiB free at $RUN_DIR (need ~${need_mb}MiB)"
    else
        say "disk free at run dir: ${avail_mb:-?}MiB"
    fi

    # -- reaper check (policy) --------------------------------------------
    if [ -x "$ROOT/build/reap-images.sh" ]; then
        say "reaper: build/reap-images.sh present (policy: last validated image per arch + candidate only)"
    fi

    # -- /dev/kvm (warn only; the gate may use it as root) -----------------
    if [ -e /dev/kvm ]; then
        if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then say "/dev/kvm readable"; else say "WARN: /dev/kvm not directly rw; the KVM gate will run as root"; fi
    else
        say "WARN: /dev/kvm absent; the KVM gate will fall back to TCG (slow)"
    fi

    if [ "$fail" != 0 ]; then
        ncz_err "preflight failed; fix the FAIL lines above"
        return 3
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Stage 10 -- refresh substrate
# ---------------------------------------------------------------------------
stage_refresh_substrate() {
    local log="$1"
    # A fresh clone has an empty downloads/, and the image container mounts only
    # the clone (/work/cix-installer) -- never the host SUBSTRATE_CACHE_DIRS -- so
    # the pinned substrate MUST be materialized here on the host before the image
    # stage (r203/amd64 RC5 finding A: with --substrate pinned this stage verified
    # the pin and returned WITHOUT restoring the ISO, and 07 image failed 12 s in
    # with "[download] SUBSTRATE ROTATED ... pinned ISO not found").  This runs for
    # every --substrate policy; build/stage-substrate.sh copies the pinned ISO from
    # the substrate cache and sha256-verifies it against base.pin, and FAILS rather
    # than floating to whatever Debian serves today.
    if [ ! -f "$DOWNLOADS/$UPSTREAM_ISO" ] || \
       [ "$(sha256sum "$DOWNLOADS/$UPSTREAM_ISO" 2>/dev/null | awk '{print $1}')" != "$SUBSTRATE_SHA" ]; then
        if [ "$OFFLINE" = "1" ]; then
            echo "[refresh-substrate] FAIL: --offline and the pinned substrate is not staged in downloads/" | tee -a "$log" >&2
            return 3
        fi
        if [ -x "$ROOT/build/stage-substrate.sh" ]; then
            echo "[refresh-substrate] pinned substrate not staged; restoring from the substrate cache (build/stage-substrate.sh --arch $ARCH)" | tee -a "$log"
            ( cd "$ROOT" && bash build/stage-substrate.sh --arch "$ARCH" ) 2>&1 | tee -a "$log"
            local rcs="${PIPESTATUS[0]}"
            [ "$rcs" = 0 ] || return "$rcs"
        fi
    fi
    if [ "$SUBSTRATE" = pinned ]; then
        echo "[refresh-substrate] pinned policy: verifying the substrate pin (no fetch)" | tee -a "$log"
        if [ ! -f "$ROOT/build/check-substrate-pin.sh" ]; then
            echo "[refresh-substrate] FAIL: build/check-substrate-pin.sh is missing" | tee -a "$log" >&2
            return 1
        fi
        bash "$ROOT/build/check-substrate-pin.sh" "$ARCH" 2>&1 | tee -a "$log"
        return "${PIPESTATUS[0]}"
    fi
    if [ -x "$ROOT/build/refresh-substrate.sh" ]; then
        ncz_info "using build/refresh-substrate.sh --arch $ARCH"
        ( cd "$ROOT" && NCZ_TARGET_ARCH="$ARCH" bash build/refresh-substrate.sh --arch "$ARCH" ) 2>&1 | tee -a "$log"
        return "${PIPESTATUS[0]}"
    fi
    local want="$SUBSTRATE_SHA" got=""
    if [ -f "$DOWNLOADS/$UPSTREAM_ISO" ]; then
        got="$(sha256sum "$DOWNLOADS/$UPSTREAM_ISO" | awk '{print $1}')"
    fi
    if [ "$got" = "$want" ]; then
        echo "[refresh-substrate] pinned substrate already present: $UPSTREAM_ISO ($want)" | tee -a "$log"
        return 0
    fi
    if [ "$OFFLINE" = "1" ]; then
        echo "[refresh-substrate] FAIL: --offline and the pinned substrate is not staged" | tee -a "$log" >&2
        return 3
    fi
    echo "[refresh-substrate] restoring the pinned substrate from the substrate cache via make download" | tee -a "$log"
    ( cd "$ROOT" && make download ARCH="$ARCH" ) 2>&1 | tee -a "$log"
    return "${PIPESTATUS[0]}"
}

# ---------------------------------------------------------------------------
# Stage 20 -- stage inputs
# ---------------------------------------------------------------------------
stage_stage_inputs() {
    local log="$1"
    ( cd "$ROOT" && bash build/stage-build-inputs.sh --arch "$ARCH" ) 2>&1 | tee -a "$log"
    local rc="${PIPESTATUS[0]}"
    [ "$rc" = 0 ] || return "$rc"
    # amd64 installer kernel: staged from the shared kernel-staging pool
    # by build/stage-amd64-kernel.sh (pin: assets/kernel/amd64-stable/KVER). The
    # pipeline never ran it, so a fresh clone aborted at the image stage with
    # "set KERNEL_DEB to the amd64 installer kernel package" (r203 failure #2).
    # arm64 builds its Sky1 kernel during offline-mirror, so this is amd64-only.
    if [ "$ARCH" = amd64 ]; then
        ( cd "$ROOT" && bash build/stage-amd64-kernel.sh ) 2>&1 | tee -a "$log"
        rc="${PIPESTATUS[0]}"
        [ "$rc" = 0 ] || return "$rc"
    fi
    # arm64: materialize the pinned sky1-firmware + cix-debs groups from the two
    # tarballs stage-build-inputs just fetched (they are gitignored and were not
    # pinned before; r203 failure #3).
    if [ "$ARCH" = arm64 ] && [ -x "$ROOT/build/stage-arm64-assets.sh" ]; then
        ( cd "$ROOT" && bash build/stage-arm64-assets.sh ) 2>&1 | tee -a "$log"
        rc="${PIPESTATUS[0]}"
        [ "$rc" = 0 ] || return "$rc"
    fi
    # Singularity screensaver settings plugin: pinned in
    # post-install/lib/ncz-screensavers-plugin.lock and staged from the store's
    # ncz-screensavers-debs pool. The pipeline never ran
    # stage-screensaver-plugin.sh, so make image's check-ssplugin-abi would fail
    # on a fresh clone -- the same hand-staging gap as the engine deb (r203
    # failure #1). Idempotent + sha256-verified against the lock.
    if [ -x "$ROOT/build/stage-screensaver-plugin.sh" ]; then
        ( cd "$ROOT" && bash build/stage-screensaver-plugin.sh "$ARCH" ) 2>&1 | tee -a "$log"
        rc="${PIPESTATUS[0]}"
        [ "$rc" = 0 ] || return "$rc"
    fi
    # rc is 0 here (every guard above returned on failure), but return it rather
    # than a literal so a future step cannot silently report success.
    return "$rc"
}

# ---------------------------------------------------------------------------
# Stage 40 -- offline mirror
# ---------------------------------------------------------------------------
stage_offline_mirror() {
    local log="$1"
    ncz_container_run "make offline-mirror ARCH=$ARCH BUILD_SHA=$GIT_SHA" "$log" || return $?
    # Record the mirror fingerprint so a later --respin can reuse it when its
    # inputs (release.conf + the pinned snapshot + the package manifests) are
    # unchanged.
    mkdir -p "$LAYERS_DIR"
    python3 -I "$LAYERPLAN_PY" fingerprint --layer mirror --arch "$ARCH" \
        --root "$ROOT" --pin "$NCZ_PIN_FILE" > "$LAYERS_DIR/mirror.build-fingerprint" 2>/dev/null || true
    return 0
}

# ---------------------------------------------------------------------------
# Stage 45 -- provenance-inputs (PROVENANCE GATE ON THE INPUTS, fail fast)
# ---------------------------------------------------------------------------
# DESIGN RULE 2026-10-10: "Why does provenance come after KVM, that is
# backwards, it should occur before build starts."  Verify every package that
# WILL enter the image, from the INPUTS, BEFORE the hours-long layers/image work
# (and long before the KVM gate).  Anything the later image scan could find that
# comes from the inputs is caught here, with an actionable list.
stage_provenance_inputs() {
    local log="$1"
    local fail=0
    say() { printf '[provenance-inputs] %s\n' "$*" | tee -a "$log"; }
    bad() { printf '[provenance-inputs] FAIL: %s\n' "$*" | tee -a "$log" >&2; fail=1; }

    local idx="$RUN_DIR/prov-input-index"
    mkdir -p "$idx"
    local mirror="$ROOT/build/forky-mirror"
    # The freshly-built singularity payload deb is a build-timestamped NCZ
    # package: it is authorized by the run receipt refresh-sources wrote (the
    # same shape as a finished-image <img>.receipt.json ncz_timestamped_debs),
    # never by a static ledger.
    local receipt="$RUN_DIR/singularity-sources/payload-receipt.json"
    local -a fetch=(); [ "$OFFLINE" = 1 ] || fetch=(--fetch-index)

    # 1. the offline mirror bytes vs the pinned signed snapshot + the ledgers
    if [ -d "$mirror/dists" ]; then
        local -a mrec=()
        [ -f "$receipt" ] && mrec=(--receipt "$receipt")
        if ( cd "$ROOT" && bash build/check-forky-provenance.sh \
                 --verify-mirror "$mirror" --index-dir "$idx" "${mrec[@]}" "${fetch[@]}" ) >>"$log" 2>&1; then
            say "offline mirror verifies against the pinned snapshot + ledgers: $mirror"
        else
            bad "offline mirror $mirror has a package with an unreviewed origin (see the log)"
        fi
    else
        bad "offline mirror missing: $mirror/dists (the offline-mirror stage did not run)"
    fi

    # 2. every staged local/vendor deb directory
    local -a dargs=()
    local d
    for d in "$ROOT/assets/cix-debs" "$ROOT/assets/vendor-debs" "$ROOT/assets/ncz-debs" \
             "$ROOT/downloads/vendor-debs"; do
        [ -d "$d" ] || continue
        # test each glob separately: `ls "$d"/*.deb "$d"/*.udeb` fails when
        # either is empty, which would skip a dir that has only .deb
        ls "$d"/*.deb >/dev/null 2>&1 || ls "$d"/*.udeb >/dev/null 2>&1 || continue
        dargs+=(--debs "$d")
    done
    if [ "${#dargs[@]}" -gt 0 ]; then
        local -a rargs=()
        [ -f "$receipt" ] && rargs=(--receipt "$receipt")
        if ( cd "$ROOT" && bash build/check-forky-provenance.sh "${dargs[@]}" "${rargs[@]}" \
                 --index-dir "$idx" "${fetch[@]}" ) >>"$log" 2>&1; then
            say "staged deb dirs verify against the ledger/receipt (${#dargs[@]} dir(s))"
        else
            bad "a staged .deb has an unreviewed origin (see the log)"
        fi
    else
        bad "no staged .deb directory found (refresh-sources/offline-mirror did not stage inputs)"
    fi

    # 3. one-kernel INPUT rule: no Debian kernel/modules package in the pool,
    #    exactly one staged NCZ kernel version for this arch
    if [ -x "$ROOT/build/verify-no-debian-kernel.sh" ] && [ -d "$mirror/pool" ]; then
        if bash "$ROOT/build/verify-no-debian-kernel.sh" --root "$mirror/pool" \
                 --arch "$ARCH" --quiet >>"$log" 2>&1; then
            say "one-kernel input rule: no Debian kernel in the offline pool"
        else
            bad "a Debian kernel/modules package is present in the offline pool (one-kernel policy)"
        fi
    fi
    local kv; kv="$(ncz_resolve_kver "$ARCH" || true)"
    if [ -n "$kv" ] && [ -n "$KVER" ] && [ "$kv" = "$KVER" ]; then
        say "one-kernel input rule: one staged NCZ kernel version ($kv)"
    else
        bad "could not resolve exactly one NCZ kernel version for $ARCH (kver='${kv:-}' expected='${KVER:-}')"
    fi

    # 4. SceneFX static shader gate on the staged payload deb (the O6N black
    #    screen must be caught before the payload ever reaches a KVM/layers run)
    local deb; deb="$(ls -1 "$ROOT/assets/cix-debs/ncz-singularity-desktop_"*_"$ARCH".deb 2>/dev/null | sort -V | tail -1)"
    if [ -n "$deb" ]; then
        if ! command -v dpkg-deb >/dev/null 2>&1; then
            bad "dpkg-deb is required to inspect the payload deb ($deb)"
        else
            local xdir; xdir="$(mktemp -d "$RUN_DIR/tmp/prov-shader.XXXXXX")"
            if dpkg-deb -x "$deb" "$xdir" 2>/dev/null && [ -f "$xdir/opt/singularity/bin/labwc" ]; then
                if bash "$ROOT/build/check-singularity-shaders.sh" "$xdir/opt/singularity/bin/labwc" >>"$log" 2>&1; then
                    say "SceneFX static shader gate PASS on $(basename "$deb")"
                else
                    bad "SceneFX static shader gate FAILED on $(basename "$deb") (quoted #error -> O6N black screen)"
                fi
            else
                bad "could not extract the payload deb for the shader gate: $deb"
            fi
            rm -rf "$xdir"
        fi
    else
        bad "no ncz-singularity-desktop_${ARCH}.deb staged in assets/cix-debs/"
    fi

    # 5. pin freshness: base.pin (substrate/snapshot + coverage) and determinism.pin
    if bash "$ROOT/build/check-substrate-pin.sh" "$ARCH" >>"$log" 2>&1; then
        say "substrate pin fresh + snapshot coverage OK (check-substrate-pin.sh)"
    else
        bad "substrate pin stale or coverage < required (run build/refresh-substrate.sh)"
    fi
    if bash "$ROOT/build/gen-base-pin.sh" --check >>"$log" 2>&1; then
        say "determinism.pin fresh"
    else
        bad "manifests/determinism.pin is stale; run build/gen-base-pin.sh and commit it"
    fi

    if [ "$fail" != 0 ]; then
        ncz_err "[provenance-inputs] FAILED -- an input has an unreviewed origin (see the FAIL lines). Fix the input (ledger entry / rebuild) BEFORE the layers stage."
        return 1
    fi
    { printf 'gate=provenance-inputs\nresult=PASS\narch=%s\nat=%s\n' "$ARCH" "$(date -u +%s)"; } \
        > "$RUN_DIR/provenance-inputs.result"
    say "every input verified -- safe to run the layers/image stages"
    return 0
}

# ---------------------------------------------------------------------------
# Stage 30 -- refresh sources (singularity payload pins + deb)
# (runs BEFORE offline-mirror: the payload deb is consumed by
#  vendor-mirror -> sinty-out-sync -> verify-local-package-versions)
# ---------------------------------------------------------------------------
# DESIGN RULE 2026-10-10: "I want latest singularity, latest build sources."
# Resolve the current upstream heads for the Singularity desktop payload (every
# subproject + the labwc SceneFX/wlroots compositor wraps), freeze them in the
# run receipt, build the payload deb from them, and hand the deb to the layers
# stage.  --sources pinned reproduces the committed pins instead.
stage_refresh_sources() {
    local log="$1"
    local sdir="$RUN_DIR/singularity-sources"
    mkdir -p "$sdir"

    # 1. resolve + freeze the source pins (never silent).
    local rs=(--sources "$SOURCES" --output "$sdir" --arch "$ARCH")
    [ "$OFFLINE" = 1 ] && rs+=(--offline)
    ( cd "$ROOT" && TMPDIR="$RUN_DIR/tmp" bash build/refresh-singularity-sources.sh "${rs[@]}" ) 2>&1 | tee -a "$log"
    local rc="${PIPESTATUS[0]}"
    if [ "$rc" != 0 ]; then
        echo "[refresh-sources] FAIL: source resolution failed (rc=$rc)" | tee -a "$log" >&2
        return "$rc"
    fi
    local up="$sdir/upstream-pins.tsv"
    [ -s "$up" ] || { echo "[refresh-sources] FAIL: no upstream-pins.tsv produced" | tee -a "$log" >&2; return 1; }
    export NCZ_SINGULARITY_PINS="$up"

    # 2. build the payload deb -- or, for --sources pinned with a committed
    #    prebuilt deb present, reuse it (reproduces the committed build).
    local deb="" sha="" sdir_out="$sdir/out"
    mkdir -p "$sdir_out"
    local pins_sha marker="$sdir_out/.built-pins.sha256"
    pins_sha="$(sha256sum "$up" | awk '{print $1}')"
    if [ "$SOURCES" = pinned ]; then
        if [ -f "$ROOT/manifests/singularity-payload.tsv" ] && \
           awk -F'\t' -v a="$ARCH" '!/^#/ && $1==a {f=1} END{exit !f}' "$ROOT/manifests/singularity-payload.tsv"; then
            # Reproduce the committed pin exactly: stage the pinned deb into
            # assets/cix-debs/ (sha256-verified against the pin). A rebuild from
            # source carries a new timestamped version, so it is never used here.
            local so=(--arch "$ARCH")
            [ "$OFFLINE" = 1 ] && so+=(--offline)
            ( cd "$ROOT" && bash build/stage-singularity-payload.sh "${so[@]}" ) 2>&1 | tee -a "$log"
            rc="${PIPESTATUS[0]}"
            if [ "$rc" != 0 ]; then
                echo "[refresh-sources] FAIL: the pinned payload deb could not be staged (rc=$rc); --sources pinned does not rebuild it from source" | tee -a "$log" >&2
                return "$rc"
            fi
            deb="$(bash "$ROOT/build/stage-singularity-payload.sh" --arch "$ARCH" --print-path)"
        else
            deb="$(ls -1 "$ROOT/assets/cix-debs/ncz-singularity-desktop_"*_"$ARCH".deb 2>/dev/null | sort -V | tail -1)"
        fi
    fi
    if [ -n "$deb" ] && [ -f "$deb" ]; then
        echo "[refresh-sources] pinned: using committed prebuilt $(basename "$deb")" | tee -a "$log"
    elif [ -s "$marker" ] && [ "$(cat "$marker")" = "$pins_sha" ] && \
         [ -n "$(ls -1 "$sdir_out"/ncz-singularity-desktop_"*"_"$ARCH".deb 2>/dev/null)" ]; then
        # idempotent reuse: a deb already built from THESE exact resolved pins
        # (lets a `--resume-from refresh-sources` / retry avoid a full rebuild).
        deb="$(ls -1 "$sdir_out"/ncz-singularity-desktop_"*"_"$ARCH".deb 2>/dev/null | sort -V | tail -1)"
        echo "[refresh-sources] reusing the deb built from these exact pins: $(basename "$deb")" | tee -a "$log"
    else
        echo "[refresh-sources] building ncz-singularity-desktop ($ARCH) from $SOURCES sources" | tee -a "$log"
        ( cd "$ROOT" && TMPDIR="$RUN_DIR/tmp" NCZ_SINGULARITY_PINS="$up" NCZ_SINGULARITY_TRACK_HEAD=0 \
            OUT="$sdir_out" SINGULARITY_IMAGE="debian:${NCZ_BASE_CODENAME:-forky}" \
            bash build/build-singularity.sh ) 2>&1 | tee -a "$log"
        rc="${PIPESTATUS[0]}"
        if [ "$rc" != 0 ]; then
            echo "[refresh-sources] FAIL: payload build failed (rc=$rc) from $SOURCES sources." | tee -a "$log" >&2
            echo "[refresh-sources]   NOT falling back to stale pins. Re-run with --sources pinned to reproduce the committed pins, or fix the upstream break." | tee -a "$log" >&2
            return "$rc"
        fi
        local tgz="$sdir_out/singularity-opt.tgz"
        [ -s "$tgz" ] || { echo "[refresh-sources] FAIL: build-singularity.sh produced no tarball" | tee -a "$log" >&2; return 1; }
        deb="$( ( cd "$ROOT" && NCZ_SINGULARITY_ARCH="$ARCH" OUT="$sdir_out" bash build/build-singularity-deb.sh "$tgz" ) 2>&1 | tee -a "$log" | sed -n 's/^Final \.deb: //p' | tail -1 )"
        if [ -z "$deb" ] || [ ! -s "$deb" ]; then
            echo "[refresh-sources] FAIL: build-singularity-deb.sh produced no usable deb" | tee -a "$log" >&2
            return 1
        fi
        printf '%s\n' "$pins_sha" > "$marker"
    fi
    sha="$(sha256sum "$deb" | awk '{print $1}')"

    # 3. static SceneFX shader gate on the deb's labwc (the payload build also
    #    gates it in-container; this re-checks the exact artifact we will ship).
    local xdir lw; xdir="$(mktemp -d "$RUN_DIR/tmp/shader.XXXXXX")"
    if dpkg-deb -x "$deb" "$xdir" 2>/dev/null; then
        lw="$xdir/opt/singularity/bin/labwc"
        if [ -f "$lw" ]; then
            bash "$ROOT/build/check-singularity-shaders.sh" "$lw" 2>&1 | tee -a "$log"
            rc="${PIPESTATUS[0]}"
            rm -rf "$xdir"
            [ "$rc" = 0 ] || { echo "[refresh-sources] FAIL: static shader gate rejected the payload labwc" | tee -a "$log" >&2; return "$rc"; }
        else
            rm -rf "$xdir"
        fi
    else
        rm -rf "$xdir"
        echo "[refresh-sources] WARN: could not extract $deb for the static shader gate" | tee -a "$log" >&2
    fi

    # 4. hand the frozen deb to the layers stage AND stage it into
    #    assets/cix-debs/ so the offline-mirror stage (vendor-mirror ->
    #    sinty-out-sync -> verify-local-package-versions) finds it.
    export NCZ_SINGULARITY_PREBUILT_DEB="$deb"
    export NCZ_SINGULARITY_PREBUILT_SHA256="$sha"
    # Keep exactly this deb in assets/cix-debs/ (the offline-mirror stage reads
    # it).  Do NOT `rm -f` the glob and then `install` from the removed path:
    # with --sources pinned the source-of-truth deb ALREADY lives in
    # assets/cix-debs/, so the old shape deleted it and copied nothing,
    # leaving the medium with no payload (caught by the r203 re-run).  Prune
    # only SUPERSEDED versions, and copy only when the chosen deb is elsewhere.
    local keep; keep="$(basename "$deb")"
    find "$ROOT/assets/cix-debs" -maxdepth 1 \
        -name 'ncz-singularity-desktop_*.deb' ! -name "$keep" -delete 2>/dev/null || true
    if [ ! -f "$ROOT/assets/cix-debs/$keep" ]; then
        install -m 0644 "$deb" "$ROOT/assets/cix-debs/"
    fi
    # Persist as shell assignments so the layers stage can pick them up on a
    # --resume-from layers run (which skips this stage).  The receipt reads the
    # same file (key=value).
    {
        printf 'NCZ_SINGULARITY_PREBUILT_DEB=%s\n' "$deb"
        printf 'NCZ_SINGULARITY_PREBUILT_SHA256=%s\n' "$sha"
        printf 'NCZ_SINGULARITY_PINS=%s\n' "$up"
        printf 'NCZ_SINGULARITY_SOURCES=%s\n' "$SOURCES"
    } > "$sdir/result.env"
    # Pre-build provenance receipt: pins the build-timestamped payload deb so the
    # provenance-inputs stage can authorize it (identical shape to a finished
    # image's <img>.receipt.json ncz_timestamped_debs).
    local receipt="$sdir/payload-receipt.json"
    python3 -I - "$receipt" "$deb" "$sha" "$ARCH" <<'PYEOF' | tee -a "$log"
import json, os, sys
out, deb, sha, arch = sys.argv[1:5]
base = os.path.basename(deb)
stem = base[:-4] if base.endswith(".deb") else base
try:
    name_ver, _farch = stem.rsplit("_", 1)
    name, ver = name_ver.split("_", 1)
except ValueError:
    print("refresh-sources: cannot parse the payload deb name %r" % base, file=sys.stderr)
    sys.exit(1)
rec = {"schema": "ncz-payload-receipt/v1",
       "ncz_timestamped_debs": [{"name": name, "version": ver, "arch": arch, "sha256": sha}]}
with open(out, "w") as fh:
    json.dump(rec, fh, indent=2, sort_keys=True)
    fh.write("\n")
print("[refresh-sources] wrote payload receipt %s (%s %s %s)" % (out, name, ver, arch))
PYEOF
    echo "[refresh-sources] payload deb: $(basename "$deb") sha256=$sha (sources=$SOURCES)" | tee -a "$log"
    return 0
}

# ---------------------------------------------------------------------------
# Stage 50 -- layers
# ---------------------------------------------------------------------------
stage_layers() {
    local log="$1"
    # The layer build regenerates the forky base rootfs in a container and
    # requires TMPDIR to be BENEATH the repo root (build-base-rootfs.sh) so the
    # scratch dir can be bind-mounted into the container.  The run-dir TMPDIR
    # (outside the tree) is fine for every other stage; override it here.
    local ltmp="$ROOT/build/.ncz-tmp"
    mkdir -p "$ltmp"
    # Pick up the refresh-sources outputs.  On a normal run they are already in
    # the environment; on a --resume-from layers run the exporting stage was
    # skipped, so source the persisted file (otherwise the payload would be
    # rebuilt from the committed pins instead of the resolved ones).
    if [ -f "$RUN_DIR/singularity-sources/result.env" ]; then
        # shellcheck disable=SC1091
        . "$RUN_DIR/singularity-sources/result.env"
        export NCZ_SINGULARITY_PREBUILT_DEB NCZ_SINGULARITY_PREBUILT_SHA256 NCZ_SINGULARITY_PINS
        say_layers() { printf '[layers] %s\n' "$*" | tee -a "$log"; }
        say_layers "refresh-sources outputs: deb=$(basename "$NCZ_SINGULARITY_PREBUILT_DEB") sources=${NCZ_SINGULARITY_SOURCES:-?}"
    fi

    # ------------------------------------------------------------------
    # layers-preflight -- DESIGN RULE 2026-10-10: validate everything
    # BEFORE the expensive layer work; fail fast (before hours of work) with an
    # actionable list.  Runs on a --resume-from layers too (so a fix is re-checked).
    # ------------------------------------------------------------------
    if [ -n "${NCZ_SINGULARITY_PREBUILT_DEB:-}" ]; then
        say_layers "layers-preflight: frozen payload $(basename "$NCZ_SINGULARITY_PREBUILT_DEB") sha256=${NCZ_SINGULARITY_PREBUILT_SHA256:-?}"
    fi
    local -a lp=(--arch "$ARCH" --root "$ROOT" --run-dir "$RUN_DIR" --layers-dir "$LAYERS_DIR" --quarantine --lock-owner "$$")
    if [ -x "$ROOT/build/layers-preflight.sh" ]; then
        ( cd "$ROOT" && NCZ_TARGET_ARCH="$ARCH" SCOPE="$SCOPE" COMPONENTS="$COMPONENTS" \
              bash build/layers-preflight.sh "${lp[@]}" ) 2>&1 | tee -a "$log"
        local lprc="${PIPESTATUS[0]}"
        if [ "$lprc" != 0 ]; then
            ncz_err "[layers] layers-preflight FAILED (rc=$lprc); stopping before any layer work."
            ncz_err "[layers]   findings: $RUN_DIR/layer-checks.tsv (see the FAIL rows)"
            return "$lprc"
        fi
    else
        ncz_warn "[layers] build/layers-preflight.sh missing; skipping the pre-layer checks"
    fi

    # `sudo` resets the environment, so the resolved-payload vars must be
    # inlined into the command string (otherwise the layer build silently
    # rebuilds the payload from the committed pins).
    local envs="" v val
    for v in NCZ_SINGULARITY_PREBUILT_DEB NCZ_SINGULARITY_PREBUILT_SHA256 NCZ_SINGULARITY_PINS NCZ_SINGULARITY_SOURCES; do
        val="${!v:-}"
        [ -n "$val" ] && envs="$envs $v='$val'"
    done
    # Per-layer post-check hook (build-squashfs-layers.sh calls check-layers.sh
    # after each layer; env inlined because sudo resets the environment).
    local postcheck_env
    postcheck_env=" NCZ_LAYERS_CHECK=1 NCZ_LAYERS_CHECK_RUN_DIR='$RUN_DIR'"
    [ -n "${NCZ_SINGULARITY_PREBUILT_DEB:-}" ] && postcheck_env="$postcheck_env NCZ_LAYERS_CHECK_PAYLOAD='$NCZ_SINGULARITY_PREBUILT_DEB'"
    # Run the layer build through the documented privilege model (ncz_sudo_bash
    # -> one `sudo -S` with the sudo password on stdin).  The script calls bare
    # `sudo` internally (mmdebstrap/chroot/mount); as root those are no-ops, and
    # a non-interactive bare sudo would otherwise fail with "a terminal is
    # required to authenticate" on a host without passwordless sudo.
    # stage 1 drives host mount/chroot/mksquashfs (r202 workaround #1/#2: it is
    # not rootless). It must run on the host, never nested in the container
    # (arm64 report #4). The layer plan (NCZ_LAYER_PLAN) decides reuse/rebuild.
    local layers_rc=0
    ncz_sudo_bash "cd '$ROOT' && TMPDIR='$ltmp' NCZ_TARGET_ARCH='$ARCH' NCZ_LAYER_PLAN='$NCZ_LAYER_PLAN'$postcheck_env$envs bash build/build-squashfs-layers.sh all" 2>&1 | tee -a "$log"
    layers_rc="${PIPESTATUS[0]}"
    if [ "$layers_rc" != 0 ]; then
        return "$layers_rc"
    fi

    # ---------------------------------------------------------------
    # Per-layer post-checks (authoritative, with manifest + chain + payload).
    # The image stage must never consume a layer that fails these.
    # ---------------------------------------------------------------
    local chain="$RUN_DIR/layer-chain.tsv"; : > "$chain"
    local manf="$ROOT/manifests/desktop.pkgs"
    local prev="" l
    for l in base desktop desktop-hotfix; do
        local sq="$LAYERS_DIR/$l.squashfs"
        [ -e "$sq" ] || { ncz_warn "[layers] post-check: $sq absent (plan may have skipped it)"; continue; }
        local -a ca=(--arch "$ARCH" --run-dir "$RUN_DIR" --stage layers-postcheck \
                     --chain "$chain" --layer "$l" --append)
        case "$l" in
            base)  [ -f "$ROOT/manifests/installer-base-${ARCH}.pkgs" ] && ca+=(--manifest "$ROOT/manifests/installer-base-${ARCH}.pkgs") ;;
            desktop)
                # Use the ARCH-SPECIFIC seed list: the generic desktop.pkgs also
                # carries the other arch's / build-only packages which must not
                # ship in this layer.
                if [ -f "$ROOT/manifests/desktop-${ARCH}.pkgs" ]; then
                    ca+=(--manifest "$ROOT/manifests/desktop-${ARCH}.pkgs")
                elif [ -f "$manf" ]; then
                    ca+=(--manifest "$manf")
                fi
                ;;
        esac
        [ -n "${NCZ_SINGULARITY_PREBUILT_DEB:-}" ] && ca+=(--payload-deb "$NCZ_SINGULARITY_PREBUILT_DEB")
        [ -n "$prev" ] && ca+=(--prev "$prev")
        # overlay deltas: the layers under them (nearest first)
        case "$l" in
            desktop)        ca+=(--lower "$LAYERS_DIR/base.squashfs") ;;
            desktop-hotfix) ca+=(--lower "$LAYERS_DIR/desktop.squashfs" --lower "$LAYERS_DIR/base.squashfs") ;;
        esac
        ( cd "$ROOT" && bash build/check-layers.sh "$sq" "${ca[@]}" ) 2>&1 | tee -a "$log"
        local crc="${PIPESTATUS[0]}"
        if [ "$crc" != 0 ]; then
            ncz_err "[layers] post-check FAILED for $l; not handing a bad layer to the image stage"
            ncz_err "[layers]   findings: $RUN_DIR/layer-checks.tsv (layer=$l)"
            return "$crc"
        fi
        prev="$sq"
    done
    { printf 'stage=layers-postcheck\nresult=PASS\narch=%s\nat=%s\nlayers=%s\n' \
        "$ARCH" "$(date -u +%s)" "$(tr '\n' ',' < "$chain")"; } > "$RUN_DIR/layers-postcheck.result"
    return 0
}

# ---------------------------------------------------------------------------
# Stage 70 -- image
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# Magnetar (NCZ_VARIANT=server) helpers
# ---------------------------------------------------------------------------
# build-image.sh helpers for the Magnetar server variant
# (NCZ_VARIANT=server, docs/MAGNETAR-SERVER-VARIANT.md).
#
# A server medium carries neither base.squashfs nor the runtime assets: the
# installer fetches both and verifies the sha256 pins write-usb-image.py puts
# in ncz-payload/ncz-fetch-payload.manifest. So a server build needs:
#   * the pins BEFORE the image is written: the base layer's sha256 (computed
#     here from assets/squashfs/base.squashfs) and the two URLs;
#   * the exact payload bytes AFTER it, for the secret scan, the provenance
#     gate and the KVM gate's local payload server: base.squashfs (copied) and
#     the asset bundle (NCZ_ASSETS_EXPORT_DIR, exported by the writer).
#
# The payload URL is a BUILD-TIME parameter:
#   NCZ_PAYLOAD_BASE_URL   base URL for both artifacts (default: the KVM gate's
#                          own serve base from write-usb-image.py's
#                          ncz_gate_serve_payload_base_url(), e.g.
#                          http://10.0.2.2, which the gate serves from this
#                          host's loopback only)
#   NCZ_PAYLOAD_URL / NCZ_ASSETS_URL   full per-artifact URLs (override)
# A medium pinned to the gate base is a GATE medium; a release medium pins the
# published URLs, which is an operator decision (nothing here uploads).

# ncz_magnetar_prepare ROOT ARCH OUTDIR -> 0 and sets MAGNETAR_* globals.
ncz_magnetar_prepare() {
    local root="$1" arch="$2" out="$3" base_layer base
    base_layer="$root/assets/squashfs/base.squashfs"
    if [ ! -s "$base_layer" ]; then
        echo "[magnetar] FAIL: no base layer at $base_layer (the layers stage builds it)" >&2
        return 1
    fi
    MAGNETAR_DIR="$out"
    mkdir -p "$MAGNETAR_DIR" || return 1
    # stale payload from an earlier image of this run dir must never be served
    rm -f "$MAGNETAR_DIR"/base.squashfs "$MAGNETAR_DIR"/ncz-assets-*.tar.gz \
          "$MAGNETAR_DIR"/ncz-assets-*.tar.gz.sha256 "$MAGNETAR_DIR"/ncz-pool-*.tar.gz \
          "$MAGNETAR_DIR"/ncz-pool-*.tar.gz.sha256 "$MAGNETAR_DIR"/*.part
    MAGNETAR_PAYLOAD_SHA256="$(sha256sum "$base_layer" | awk '{print $1}')"
    if [ -n "${NCZ_PAYLOAD_SHA256:-}" ] && [ "$NCZ_PAYLOAD_SHA256" != "$MAGNETAR_PAYLOAD_SHA256" ]; then
        echo "[magnetar] FAIL: NCZ_PAYLOAD_SHA256=$NCZ_PAYLOAD_SHA256 is not the sha256 of $base_layer ($MAGNETAR_PAYLOAD_SHA256)" >&2
        return 1
    fi
    base="${NCZ_PAYLOAD_BASE_URL:-}"
    if [ -z "$base" ]; then
        base="$(python3 -I - "$root/build/iso/write-usb-image.py" "$arch" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("ncz_write_usb_image", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
print(mod.ncz_gate_serve_payload_base_url(sys.argv[2]))
PY
)" || { echo "[magnetar] FAIL: cannot derive the gate serve base URL" >&2; return 1; }
    fi
    base="${base%/}"
    case "$base" in
        http://*|https://*) ;;
        *) echo "[magnetar] FAIL: NCZ_PAYLOAD_BASE_URL '$base' is not an http(s) URL" >&2; return 1 ;;
    esac
    MAGNETAR_BASE_URL="$base"
    MAGNETAR_PAYLOAD_URL="${NCZ_PAYLOAD_URL:-$base/base.squashfs}"
    MAGNETAR_ASSETS_NAME="ncz-assets-$arch.tar.gz"
    MAGNETAR_ASSETS_URL="${NCZ_ASSETS_URL:-$base/$MAGNETAR_ASSETS_NAME}"
    # Option B (operator 2026-10-26): the offline apt pool is the third
    # pinned artifact, fetched like the other two.
    MAGNETAR_POOL_NAME="ncz-pool-$arch.tar.gz"
    MAGNETAR_POOL_URL="${NCZ_POOL_URL:-$base/$MAGNETAR_POOL_NAME}"
    MAGNETAR_BASE_LAYER="$base_layer"
    return 0
}

# ncz_magnetar_collect IMG -> 0 when the finished medium is a server medium
# whose receipt pins exactly the bytes now in MAGNETAR_DIR (base.squashfs is
# copied there; the bundle was exported by the writer).
ncz_magnetar_collect() {
    local img="$1" receipt="$1.receipt.json"
    [ -f "$receipt" ] || { echo "[magnetar] FAIL: no receipt $receipt" >&2; return 1; }
    cp -f "$MAGNETAR_BASE_LAYER" "$MAGNETAR_DIR/base.squashfs.part" \
        && mv -f "$MAGNETAR_DIR/base.squashfs.part" "$MAGNETAR_DIR/base.squashfs" || return 1
    python3 -I - "$receipt" "$MAGNETAR_DIR" "$MAGNETAR_PAYLOAD_URL" "$MAGNETAR_ASSETS_URL" "$MAGNETAR_POOL_URL" <<'PY'
import hashlib, json, os, sys
receipt, d, purl, aurl, lurl = sys.argv[1:6]
r = json.load(open(receipt))
def sha(p):
    h = hashlib.sha256()
    with open(p, "rb") as fh:
        for b in iter(lambda: fh.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()
bad = []
if r.get("variant") != "server":
    bad.append(f"receipt variant is {r.get('variant')!r}, not 'server'")
of = (r.get("ncz_payload") or {}).get("online_fetch") or {}
if not of:
    bad.append("receipt has no ncz_payload.online_fetch pins")
else:
    if of.get("payload_url") != purl:
        bad.append(f"receipt payload_url {of.get('payload_url')!r} != {purl!r}")
    if of.get("assets_url") != aurl:
        bad.append(f"receipt assets_url {of.get('assets_url')!r} != {aurl!r}")
    if of.get("pool_url") != lurl:
        bad.append(f"receipt pool_url {of.get('pool_url')!r} != {lurl!r}")
    for key, name in (("payload_sha256", of.get("payload_name", "base.squashfs")),
                      ("assets_sha256", of.get("assets_name", "")),
                      ("pool_sha256", of.get("pool_name", ""))):
        p = os.path.join(d, name)
        if not name or not os.path.isfile(p):
            bad.append(f"payload file {p} is missing")
        elif sha(p) != of.get(key):
            bad.append(f"{name}: sha256 {sha(p)} != receipt {key} {of.get(key)}")
if bad:
    for b in bad:
        print("[magnetar] FAIL:", b, file=sys.stderr)
    sys.exit(1)
print(f"[magnetar] payload pinned and present: {of['payload_name']} {of['payload_sha256'][:16]}..., "
      f"{of['assets_name']} {of['assets_sha256'][:16]}..., {of['pool_name']} {of['pool_sha256'][:16]}...")
PY
}

NCZ_CRUN_ENV=(); NCZ_CRUN_MOUNTS=(); NCZ_CRUN_HOSTENV=()
stage_image() {
    local log="$1"
    if [ "$NCZ_VARIANT" = server ]; then
        # Magnetar: pin the payload BEFORE the medium exists (ncz_magnetar_prepare above).
        if ! ncz_magnetar_prepare "$ROOT" "$ARCH" "$MAGNETAR_DIR" >>"$log" 2>&1; then
            tail -3 "$log" >&2; return 1
        fi
        echo "[image] Magnetar server medium: payload ${MAGNETAR_PAYLOAD_URL} (sha256 ${MAGNETAR_PAYLOAD_SHA256}), assets ${MAGNETAR_ASSETS_URL}, pool ${MAGNETAR_POOL_URL}" | tee -a "$log"
        local -a srv=(NCZ_VARIANT=server "NCZ_PAYLOAD_URL=$MAGNETAR_PAYLOAD_URL"
                      "NCZ_PAYLOAD_SHA256=$MAGNETAR_PAYLOAD_SHA256" "NCZ_ASSETS_URL=$MAGNETAR_ASSETS_URL"
                      "NCZ_POOL_URL=$MAGNETAR_POOL_URL")
        [ -n "${NCZ_GATE_SERVER_HOST:-}" ] && srv+=("NCZ_GATE_SERVER_HOST=$NCZ_GATE_SERVER_HOST")
        local kv
        NCZ_CRUN_ENV=(); for kv in "${srv[@]}"; do NCZ_CRUN_ENV+=(-e "$kv"); done
        NCZ_CRUN_ENV+=(-e NCZ_ASSETS_EXPORT_DIR=/work/magnetar-payload)
        NCZ_CRUN_MOUNTS=(-v "$MAGNETAR_DIR":/work/magnetar-payload)
        NCZ_CRUN_HOSTENV=("${srv[@]}" "NCZ_ASSETS_EXPORT_DIR=$MAGNETAR_DIR")
    fi
    ncz_container_run "make image ARCH=$ARCH BUILD_SHA=$GIT_SHA" "$log"
    local mrc=$?
    NCZ_CRUN_ENV=(); NCZ_CRUN_MOUNTS=(); NCZ_CRUN_HOSTENV=()
    [ "$mrc" = 0 ] || return "$mrc"
    # Resolve and record the image path HERE: the provenance gate now runs BEFORE
    # kvm-gate and needs the path, so it can no longer be written by the KVM gate.
    local img="${IMAGE_ARG:-}"
    if [ -z "$img" ]; then
        img="$(ls -1 "$BUILD"/ncz-os-"$ARCH"-*-"$GIT_SHA".img 2>/dev/null | tail -1)"
    fi
    if [ -z "$img" ] || [ ! -f "$img" ]; then
        echo "[image] FAIL: no image found for $ARCH $GIT_SHA" | tee -a "$log" >&2
        return 1
    fi
    printf '%s\n' "$img" > "$RUN_DIR/image.path"
    echo "[image] $img" | tee -a "$log"
    if [ "$NCZ_VARIANT" = server ]; then
        # the writer ran as root in the container: hand the exported bundle back
        ncz_sudo chown -R "$(id -u):$(id -g)" "$MAGNETAR_DIR" 2>/dev/null || true
        ncz_magnetar_collect "$img" 2>&1 | tee -a "$log"
        [ "${PIPESTATUS[0]}" = 0 ] || return 1
        { printf 'variant=server\nimage=%s\npayload_url=%s\npayload_sha256=%s\nassets_url=%s\nassets_sha256=%s\npool_url=%s\npool_sha256=%s\nbase_url=%s\npublished=no\nat=%s\n' \
            "$img" "$MAGNETAR_PAYLOAD_URL" "$MAGNETAR_PAYLOAD_SHA256" "$MAGNETAR_ASSETS_URL" \
            "$(awk '{print $1}' "$MAGNETAR_DIR/$MAGNETAR_ASSETS_NAME.sha256")" "$MAGNETAR_POOL_URL" \
            "$(awk '{print $1}' "$MAGNETAR_DIR/$MAGNETAR_POOL_NAME.sha256")" "$MAGNETAR_BASE_URL" "$(date -u +%s)"; } \
            > "$RUN_DIR/payload.result"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Stage 75 -- shipped-artifact credential scan (MANDATORY image-build gate)
# ---------------------------------------------------------------------------
# Preview2 shipped arm64 only because this scan was run BY HAND; amd64 was
# never scanned at all.  It is a stage now: it reads the finished image
# read-only, extracts every shipped byte (each squashfs layer, every
# initrd/initramfs cpio segment, the rescue rootfs tar.zst, every .deb
# data/control archive in every pool and cache on the image) and matches the
# extracted text against a salted-SHA-256 hash list plus a token-shape scan.
#
# FAIL CLOSED: no hash list, an unreadable layer or a scanner crash all fail
# the build.  The hash list is the ONLY way the hashed half can run, and the
# build host never holds a plaintext secret -- the operator generates the list
# on a trusted machine with build/make-secret-hashes.py and copies just the
# digests to ~/.config/ncz/secret-hashes.json, outside every git tree.
#
# The scanner needs unsquashfs and zstd on this host (checked in preflight).
stage_secret_scan() {
    local log="$1"
    local img; img="$(cat "$RUN_DIR/image.path" 2>/dev/null || true)"
    [ -n "$img" ] || img="${IMAGE_ARG:-}"
    if [ -z "$img" ]; then
        img="$(ls -1 "$BUILD"/ncz-os-"$ARCH"-*-"$GIT_SHA".img 2>/dev/null | tail -1)"
    fi
    [ -n "$img" ] && [ -f "$img" ] || { echo "[secret-scan] FAIL: no image found for $ARCH $GIT_SHA" | tee -a "$log" >&2; return 1; }
    local hashf
    hashf="$(ncz_site_value NCZ_SECRET_HASHES_FILE secret-hashes-file)"
    [ -n "$hashf" ] || hashf="${XDG_CONFIG_HOME:-$HOME/.config}/ncz/secret-hashes.json"
    if [ "${NCZ_SECRET_SCAN:-}" = skip ]; then
        echo "[secret-scan] SKIPPED by NCZ_SECRET_SCAN=skip -- this image is NOT cleared" \
             "for release; the archive stage will refuse it" | tee -a "$log" >&2
        printf 'gate=secret-scan\nresult=SKIP\nreason=NCZ_SECRET_SCAN=skip\nat=%s\n' \
            "$(date -u +%s)" > "$RUN_DIR/secret-scan.result"
        return 0
    fi
    # The digests are operator data: they live outside every git worktree, so
    # a review or export of the tree can never pick them up.
    local root_real hash_real
    root_real="$(realpath -m "$ROOT")"; hash_real="$(realpath -m "$hashf")"
    case "$hash_real/" in
        "$root_real"/*)
            echo "[secret-scan] FAIL: the hash list $hashf is inside the repository;" \
                 "keep it under ~/.config/ncz/ (or NCZ_SECRET_HASHES_FILE outside the tree)" \
                 | tee -a "$log" >&2
            return 1 ;;
    esac
    # Say which half can run before doing any work: the operator must never
    # have to read a stack trace to learn the hash list is missing.
    if [ ! -f "$hashf" ]; then
        echo "[secret-scan] FAIL: no hash list at $hashf" | tee -a "$log" >&2
        echo "[secret-scan]   run build/make-secret-hashes.py on a TRUSTED machine and copy" | tee -a "$log" >&2
        echo "[secret-scan]   only the resulting digests to ~/.config/ncz/secret-hashes.json (or set" | tee -a "$log" >&2
        echo "[secret-scan]   NCZ_SECRET_HASHES_FILE).  NCZ_SECRET_SCAN=skip builds an image that" | tee -a "$log" >&2
        echo "[secret-scan]   is never archived or released." | tee -a "$log" >&2
        return 1
    fi
    local receipt="$RUN_DIR/secret-scan.receipt.json"
    local work="$RUN_DIR/secret-scan-work"
    mkdir -p "$work"
    local extra=()
    # Tests only (build/test-shipped-secret-scan.sh drives the stage against a
    # fixture image); a real build never sets these.
    [ -n "${NCZ_SECRET_SCAN_ALLOW_DETACHED:-}" ] && extra+=(--allow-detached)
    local t0 t1
    t0="$(date -u +%s)"
    # A server medium carries no layer (--variant server checks that against its
    # receipt); its payload ships off the medium and is scanned on its own.
    [ "$NCZ_VARIANT" = server ] && extra+=(--variant server)
    TMPDIR="$work" python3 -I "$ROOT/build/scan-shipped-secrets.py" \
        --image "$img" --hash-file "$hashf" --receipt "$receipt" \
        --work-dir "$work" --require-hashes --jobs "${JOBS:-$(nproc)}" \
        "${extra[@]}" 2>&1 | tee -a "$log"
    local rc="${PIPESTATUS[0]}"
    local preceipt="$RUN_DIR/secret-scan-payload.receipt.json" prc=0
    if [ "$NCZ_VARIANT" = server ] && [ "$rc" = 0 ]; then
        local -a pay=()
        local pf
        for pf in "$MAGNETAR_DIR/base.squashfs" "$MAGNETAR_DIR/ncz-assets-$ARCH.tar.gz" "$MAGNETAR_DIR/ncz-pool-$ARCH.tar.gz"; do
            [ -f "$pf" ] && pay+=(--payload "$pf")
        done
        if [ "${#pay[@]}" != 6 ]; then
            echo "[secret-scan] FAIL: the Magnetar payload is incomplete in $MAGNETAR_DIR (need base.squashfs, the asset bundle and the offline apt pool; run the image stage)" | tee -a "$log" >&2
            prc=1
        else
            TMPDIR="$work" python3 -I "$ROOT/build/scan-shipped-secrets.py" \
                "${pay[@]}" --hash-file "$hashf" --receipt "$preceipt" \
                --work-dir "$work" --require-hashes --jobs "${JOBS:-$(nproc)}" \
                2>&1 | tee -a "$log"
            prc="${PIPESTATUS[0]}"
        fi
        [ "$prc" = 0 ] || rc=1
    fi
    t1="$(date -u +%s)"
    # Keep the work dir only when the operator asked for it: a clean run must
    # leave no extracted payload behind on the build host.
    if [ "${KEEP_WORK:-0}" != 1 ]; then
        chmod -R u+rwX "$work" 2>/dev/null || true
        rm -rf "$work" 2>/dev/null || true
    fi
    if [ "$rc" != 0 ]; then
        echo "[secret-scan] FAIL: the shipped artifact is not shippable (rc=$rc); receipt: $receipt" | tee -a "$log" >&2
        return 1
    fi
    { printf 'gate=secret-scan\nresult=PASS\nimage=%s\nsha256=%s\nhash_list=%s\nelapsed_seconds=%s\nat=%s\n' \
        "$img" "$(sha256sum "$img" | awk '{print $1}')" "sha256:$(sha256sum "$hashf" | awk '{print $1}')" "$((t1 - t0))" "$(date -u +%s)"
      if [ "$NCZ_VARIANT" = server ]; then
          printf 'variant=server\npayload_receipt=%s\n' "$preceipt"
          for pf in "$MAGNETAR_DIR/base.squashfs" "$MAGNETAR_DIR/ncz-assets-$ARCH.tar.gz" "$MAGNETAR_DIR/ncz-pool-$ARCH.tar.gz"; do
              printf 'payload=%s sha256=%s\n' "$(basename "$pf")" "$(sha256sum "$pf" | awk '{print $1}')"
          done
      fi; } > "$RUN_DIR/secret-scan.result"
    echo "[secret-scan] PASS ($((t1 - t0))s) receipt: $receipt" | tee -a "$log"
    return 0
}

# ---------------------------------------------------------------------------
# Stage 90 -- KVM gate (includes the installer UI/screens check)
# ---------------------------------------------------------------------------
stage_kvm_gate() {
    local log="$1"
    local img; img="$(cat "$RUN_DIR/image.path" 2>/dev/null || true)"
    [ -n "$img" ] || img="${IMAGE_ARG:-}"
    if [ -z "$img" ]; then
        img="$(ls -1 "$BUILD"/ncz-os-"$ARCH"-*-"$GIT_SHA".img 2>/dev/null | tail -1)"
    fi
    [ -n "$img" ] && [ -f "$img" ] || { echo "[kvm-gate] FAIL: no image found for $ARCH $GIT_SHA (pass --image)" | tee -a "$log" >&2; return 1; }
    local pyvenv="/root/ncz-pyte-venv"
    if ! [ -x "$pyvenv/bin/python" ]; then
        if [ "$OFFLINE" = "1" ]; then
            echo "[kvm-gate] WARN: --offline; cannot create the pyte venv (UI check may FAIL)" | tee -a "$log"
        else
            echo "[kvm-gate] creating $pyvenv for the UI check" | tee -a "$log"
            ncz_sudo python3 -m venv "$pyvenv" >>"$log" 2>&1 && \
              ncz_sudo "$pyvenv/bin/pip" install --quiet pyte >>"$log" 2>&1 || true
        fi
    fi
    local work="${KVM_INSTALL_WORKDIR:-$RUN_DIR/kvm-gate}"
    mkdir -p "$work"
    # NCZ_CHOWN_BACK is the invoking user for the chown-back trap inside the
    # gate: passed on the sudo command line (not the environment) because sudo's
    # env_reset would otherwise drop it.  It keeps the run dir deletable by the
    # build user after the gate (2026-10-11).
    local invoker; invoker="$(id -u):$(id -g)"
    if [ "$NCZ_VARIANT" = server ]; then
        stage_kvm_gate_server "$log" "$img" "$work" "$invoker"
        return $?
    fi
    ( cd "$ROOT" && ARCH="$ARCH" TMPDIR="$RUN_DIR/tmp" \
        NCZ_PYTE_PYTHON="${NCZ_PYTE_PYTHON:-$pyvenv/bin/python}" \
        ncz_sudo_bash "ARCH=$ARCH TMPDIR='$RUN_DIR/tmp' HOME='$HOME' NCZ_CHOWN_BACK='$invoker' NCZ_PYTE_PYTHON='${NCZ_PYTE_PYTHON:-$pyvenv/bin/python}' bash build/kvm-install-gate-gpt.sh '$img' '$work'" ) 2>&1 | tee -a "$log"
    local rc="${PIPESTATUS[0]}"
    [ "$rc" = 0 ] && grep -q 'GATE PASS' "$log" || return "$rc"
    # Install-option sets: the gate above answers the component dialog with
    # every option selected; these install and boot the image again with
    # options unticked (rescue partition + management container off, then
    # every option off) and once over a disk that held an older install (btrfs
    # root over old ext4 signatures), each in its own work dir. build/kvm-install-gate-matrix.sh
    # names the sets; NCZ_KVM_GATE_VARIANTS overrides the list ("all" = every set).
    local sets mrc=0
    sets="${NCZ_KVM_GATE_VARIANTS:-norescue minimal stalefs}"
    echo "[kvm-gate] install-option sets: $sets" | tee -a "$log"
    ( cd "$ROOT" && ncz_sudo_bash "ARCH=$ARCH TMPDIR='$RUN_DIR/tmp' HOME='$HOME' NCZ_CHOWN_BACK='$invoker' NCZ_KVM_GATE_VARIANTS='$sets' bash build/kvm-install-gate-matrix.sh '$img' '$work-options'" ) 2>&1 | tee -a "$log"
    mrc="${PIPESTATUS[0]}"
    if [ "$mrc" != 0 ] || ! grep -q '^MATRIX PASS' "$log"; then
        echo "[kvm-gate] FAIL: an install-option set failed (see $work-options/matrix.tsv)" | tee -a "$log" >&2
        return 1
    fi
    { printf 'gate=kvm\nresult=PASS\nui=PASS\noptions=%s\nimage=%s\nsha256=%s\nat=%s\n' \
        "$(echo "$sets" | tr ' ' ',')" "$img" "$(sha256sum "$img" | awk '{print $1}')" "$(date -u +%s)"; } > "$RUN_DIR/kvm-gate.result"
    return 0
}

# Magnetar server medium: it carries no desktop payload, so the desktop full
# gate and the desktop option sets cannot install it. The server sets do: the
# gate reads the pins back off the medium, serves base.squashfs + the asset
# bundle from MAGNETAR_DIR on its own local HTTP server (stopped by PID on
# exit), installs and boots; the negative set proves a stopped server fails
# loud and bounded with nothing installed. The installer dialogs are the
# desktop medium's (same preseed and chooser); they are judged there.
stage_kvm_gate_server() {
    local log="$1" img="$2" work="$3" invoker="$4" sets mrc
    sets="${NCZ_KVM_GATE_SERVER_SETS:-server server-offline-negative}"
    local assets="$MAGNETAR_DIR/ncz-assets-$ARCH.tar.gz" pool="$MAGNETAR_DIR/ncz-pool-$ARCH.tar.gz"
    if [ ! -f "$MAGNETAR_DIR/base.squashfs" ] || [ ! -f "$assets" ] || [ ! -f "$pool" ]; then
        echo "[kvm-gate] FAIL: Magnetar payload missing in $MAGNETAR_DIR (run the image stage)" | tee -a "$log" >&2
        return 1
    fi
    echo "[kvm-gate] Magnetar server sets: $sets (payload from $MAGNETAR_DIR)" | tee -a "$log"
    ( cd "$ROOT" && ncz_sudo_bash "ARCH=$ARCH TMPDIR='$RUN_DIR/tmp' HOME='$HOME' NCZ_CHOWN_BACK='$invoker' NCZ_KVM_GATE_VARIANTS='$sets' NCZ_GATE_SERVER_PAYLOAD='$MAGNETAR_DIR/base.squashfs' NCZ_GATE_SERVER_ASSETS='$assets' NCZ_GATE_SERVER_POOL='$pool' bash build/kvm-install-gate-matrix.sh '$img' '$work-options'" ) 2>&1 | tee -a "$log"
    mrc="${PIPESTATUS[0]}"
    if [ "$mrc" != 0 ] || ! grep -q '^MATRIX PASS' "$log"; then
        echo "[kvm-gate] FAIL: a Magnetar server set failed (see $work-options/matrix.tsv)" | tee -a "$log" >&2
        return 1
    fi
    { printf 'gate=kvm\nresult=PASS\nvariant=server\nui=desktop-medium\noptions=%s\nimage=%s\nsha256=%s\nat=%s\n' \
        "$(echo "$sets" | tr ' ' ',')" "$img" "$(sha256sum "$img" | awk '{print $1}')" "$(date -u +%s)"; } > "$RUN_DIR/kvm-gate.result"
    return 0
}

# ---------------------------------------------------------------------------
# Stage 80 -- provenance gate (includes the one-kernel rule)
# ---------------------------------------------------------------------------
stage_provenance_gate() {
    local log="$1"
    local img; img="$(cat "$RUN_DIR/image.path" 2>/dev/null || true)"
    [ -n "$img" ] || img="${IMAGE_ARG:-}"
    [ -n "$img" ] && [ -f "$img" ] || { echo "[provenance-gate] FAIL: no image path" | tee -a "$log" >&2; return 1; }
    local work="$RUN_DIR/prov-work" idx="$RUN_DIR/prov-index"
    mkdir -p "$work" "$idx"
    # Run as root: the --image scan extracts partitions with `debugfs rdump`,
    # which needs root to chown the dumped tree; as a normal user it fails
    # ("Operation not permitted while changing ownership"), the /dists index is
    # never extracted, and every /cdrom pool deb then looks like an orphan
    # (a false 1000+ failure).  Same documented privilege model as the KVM gate.
    # NCZ_CHOWN_BACK hands prov-work/ + prov-index/ back to the invoking user on
    # the script's exit trap, so the run dir stays deletable (2026-10-11).
    local invoker; invoker="$(id -u):$(id -g)"
    # Server medium: the provenance scan also covers the payload it pins
    # (base.squashfs, the asset bundle), checked against the receipt's pins.
    local srvargs=""
    [ "$NCZ_VARIANT" = server ] && srvargs="--variant server --server-payload '$MAGNETAR_DIR'"
    ncz_sudo_bash "cd '$ROOT' && NCZ_CHOWN_BACK='$invoker' bash build/check-forky-provenance.sh --image '$img' \
        --work '$work' --index-dir '$idx' --fetch-index $srvargs" 2>&1 | tee -a "$log"
    local rc="${PIPESTATUS[0]}"
    if [ "$rc" = 0 ]; then
        { printf 'gate=provenance\nresult=PASS\none_kernel=PASS\nimage=%s\nat=%s\n' "$img" "$(date -u +%s)"
          [ "$NCZ_VARIANT" = server ] && printf 'variant=server\npayload_dir=%s\n' "$MAGNETAR_DIR"; } > "$RUN_DIR/provenance.result"
    fi
    return "$rc"
}

# ---------------------------------------------------------------------------
# Stage 80 -- receipt (NOT part of any hashed artifact)
# ---------------------------------------------------------------------------
stage_receipt() {
    local log="$1"
    local img; img="$(cat "$RUN_DIR/image.path" 2>/dev/null || true)"
    local out="$RUN_DIR/run-metadata.json"
    NCZ_RUN_META_PLAN="$PLAN_JSON" python3 -I - "$out" "$ARCH" "$GIT_FULL" "$GIT_SHA" "$PIN_DIGEST" \
        "$SOURCE_DATE_EPOCH" "$KVER" "$SUBSTRATE_SHA" "$RUN_DIR" "$ROOT" "$img" \
        "$SCOPE" "$COMPONENTS" "$GATES" "$NO_PUBLISH" "$SUBSTRATE" "$NCZ_LAYER_PLAN" "$SOURCES" <<'PYEOF' | tee -a "$log"
import json, os, socket, sys, time
(out, arch, git_full, git_sha, pin_digest, sde, kver, substrate,
 run_dir, root, img, scope, components, gates, no_publish, substrate_policy,
 layer_plan, sources_policy) = sys.argv[1:19]
plan = {}
try:
    plan = json.loads(os.environ.get("NCZ_RUN_META_PLAN", "{}"))
except Exception:
    plan = {}
def gate(name, path):
    try:
        txt = open(os.path.join(run_dir, path)).read()
        return "PASS" if "result=PASS" in txt else "FAIL"
    except OSError:
        return "not-run"
# singularity payload resolution receipt (source SHAs + deb sha256)
sing = {}
try:
    with open(os.path.join(run_dir, "singularity-sources", "result.env")) as fh:
        for ln in fh:
            k, _, v = ln.strip().partition("=")
            if k:
                sing[k] = v
except OSError:
    pass
try:
    with open(os.path.join(run_dir, "singularity-sources", "source-resolution.json")) as fh:
        sr = json.load(fh)
    sing["pins_manifest_sha256"] = sr.get("pins_manifest_sha256")
    sing["n_repos"] = sr.get("n_repos")
except Exception:
    pass
required = {"kvm", "provenance", "one_kernel", "ui", "secret_scan"}
gates_sel = [g for g in (gates or "kvm,provenance").split(",") if g]
meta = {
    "schema": "ncz-image-build-run/v1",
    "arch": arch,
    "mode": scope,
    "components": [c for c in (components or "").split(",") if c],
    "flags": {"substrate": substrate_policy, "sources": sources_policy,
              "no_publish": bool(int(no_publish)),
              "gates": gates_sel, "layer_plan": layer_plan},
    "git_commit": git_full,
    "git_sha_short": git_sha,
    "base_pin_digest": pin_digest,
    "source_date_epoch": int(sde),
    "kernel_kver": kver,
    "substrate_sha256": substrate,
    "singularity_payload": sing,
    "layers": {lyr: {"fingerprint": fp, "decision": plan.get("layers", {}).get(lyr, "?")}
               for lyr, fp in plan.get("fingerprints", {}).items()},
    "gates": {"kvm": gate("kvm", "kvm-gate.result"),
              "secret_scan": gate("secret-scan", "secret-scan.result"),
              "provenance_inputs": gate("provenance-inputs", "provenance-inputs.result"),
              "provenance": gate("provenance", "provenance.result"),
              "layers_preflight": gate("layers-preflight", "layers-preflight.result"),
              "layers_postcheck": gate("layers-postcheck", "layers-postcheck.result")},
    "required_gates": sorted(required),
    "host": socket.gethostname(),
    "finished_at": int(time.time()),
    "image": img,
    "note": "Build-time metadata ONLY. Not an input to any artifact hash; carries "
            "the wall-clock/timestamp values excluded from the deterministic "
            "artifacts (see the stage list in the header of build/build-image.sh).",
}
with open(out, "w") as fh:
    json.dump(meta, fh, indent=2, sort_keys=True)
    fh.write("\n")
# a small, non-hashed gate summary next to the image for the archive stage
if img:
    gsum = {"all_required_passed": (meta["gates"]["kvm"] == "PASS"
                                    and meta["gates"]["provenance"] == "PASS"
                                    and meta["gates"]["secret_scan"] == "PASS"),
            "gates": meta["gates"], "required": sorted(required),
            "mode": scope, "base_pin_digest": pin_digest}
    try:
        with open(img + ".gates.json", "w") as fh:
            json.dump(gsum, fh, indent=2, sort_keys=True)
            fh.write("\n")
    except OSError:
        pass
print("[receipt] wrote", out)
PYEOF
    return "${PIPESTATUS[0]}"
}

# ---------------------------------------------------------------------------
# Stage 90 -- archive (ONLY if every gate PASSed)
# ---------------------------------------------------------------------------
stage_archive() {
    local log="$1"
    if [ "$NO_PUBLISH" = 1 ]; then
        echo "[archive] skipped (--no-publish)" | tee -a "$log"
        return 0
    fi
    if [ ! -f "$RUN_DIR/kvm-gate.result" ] || ! grep -q '^result=PASS' "$RUN_DIR/kvm-gate.result"; then
        echo "[archive] FAIL: refusing to copy — the KVM gate did not PASS in this run" | tee -a "$log" >&2
        return 1
    fi
    if [ ! -f "$RUN_DIR/provenance.result" ] || ! grep -q '^result=PASS' "$RUN_DIR/provenance.result"; then
        echo "[archive] FAIL: refusing to copy — the provenance gate did not PASS in this run" | tee -a "$log" >&2
        return 1
    fi
    if [ ! -f "$RUN_DIR/secret-scan.result" ] || ! grep -q '^result=PASS' "$RUN_DIR/secret-scan.result"; then
        echo "[archive] FAIL: refusing to copy — the shipped-artifact credential scan did not PASS in this run" | tee -a "$log" >&2
        return 1
    fi
    ( cd "$ROOT" && bash build/stage-to-argonas.sh "$ARCH" "$(cat "$RUN_DIR/image.path")" "$RUN_DIR" ) 2>&1 | tee -a "$log"
    return "${PIPESTATUS[0]}"
}

# ---------------------------------------------------------------------------
# per-stage enable/disable from the scope, plan and gates
# ---------------------------------------------------------------------------
gate_selected() { [ -z "$GATES" ] && return 0; case ",$GATES," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }

stage_enabled() {
    case "$1" in
        preflight) return 0 ;;
        # Always runs: with --substrate pinned it restores the pinned ISO from
        # the substrate cache into downloads/ and verifies the pin (no fetch);
        # with --substrate refresh it fetches and re-pins.
        refresh-substrate) return 0 ;;
        stage-inputs) return 0 ;;
        offline-mirror)
            # reuse the mirror when the plan says reuse and it is present
            [ "$(LAYER_DECISION mirror)" = reuse ] && [ -d "$ROOT/build/forky-mirror" ] && return 1 || return 0 ;;
        refresh-sources)
            [ "$SCOPE" = only-image ] && return 1
            if [ "$SOURCES" = latest ]; then return 0; fi
            # pinned: only when the payload layer is actually in scope
            case "$SCOPE" in
                full|rebuild-desktop|components) return 0 ;;
                *) return 1 ;;
            esac ;;
        provenance-inputs) gate_selected provenance ;;
        layers) [ "$SCOPE" = only-image ] && return 1 || return 0 ;;
        image) return 0 ;;
        # The shipped-artifact credential gate is MANDATORY: no scope, gate
        # selection or publish flag can switch it off (see stage_secret_scan).
        secret-scan) return 0 ;;
        kvm-gate) gate_selected kvm ;;
        provenance-gate) gate_selected provenance ;;
        receipt) return 0 ;;
        archive) [ "$NO_PUBLISH" = 1 ] && return 1 || return 0 ;;
        *) return 0 ;;
    esac
}

# ---------------------------------------------------------------------------
# dry-run plan
# ---------------------------------------------------------------------------
print_plan() {
    echo "NCZ-OS image build plan"
    echo "  arch             $ARCH"
    echo "  host             $(hostname -s)"
    echo "  scope            $SCOPE${COMPONENTS:+ ($COMPONENTS)}"
    echo "  git              $GIT_FULL"
    echo "  base.pin digest  $PIN_DIGEST"
    echo "  SOURCE_DATE_EPOCH $SOURCE_DATE_EPOCH ($(date -u -d "@$SOURCE_DATE_EPOCH" 2>/dev/null || date -u -r "$SOURCE_DATE_EPOCH" 2>/dev/null))"
    echo "  substrate        $SUBSTRATE_SHA (policy: $SUBSTRATE)"
    echo "  sources          $SOURCES (singularity payload pins)"
    echo "  kernel KVER      ${KVER:-<unresolved>}"
    echo "  privilege        $(ncz_priv_model || true)"
    echo "  container        $([ "$USE_CONTAINER" = 1 ] && echo "$NCZ_IMAGEBUILD_TAG" || echo disabled)"
    echo "  jobs             ${JOBS:-<unset>}"
    echo "  offline          $OFFLINE"
    echo "  run dir          $RUN_DIR"
    echo "  from stage       ${RESUME_FROM:-preflight}"
    echo "  publish          $([ "$NO_PUBLISH" = 1 ] && echo 'no (--no-publish)' || echo 'on (only if gates PASS)')"
    echo "  gates            ${GATES:-kvm,provenance}"
    echo
    echo "  layer plan (fingerprints seed every derived UUID / reuse decision):"
    local lyr
    for lyr in mirror base desktop hotfix; do
        printf '    %-8s %-8s fp=%s\n' "$lyr" "$(LAYER_DECISION "$lyr")" "$(LAYER_FP "$lyr" | cut -c1-16)"
    done
    echo
    echo "  layers checks (harden-the-layer-checks ruling 2026-10-10):"
    echo "    layers-preflight  clean-tree, frozen-deb handshake, unique inputs,"
    echo "                      resources (>=${NCZ_LAYERS_MIN_FREE_GB:-60}GB, not tmpfs), pin consistency"
    echo "    post-checks       structural, dpkg state, one-kernel, payload facts,"
    echo "                      layer-chain, member-list determinism (build/check-layers.sh)"
    echo "                      findings -> $RUN_DIR/layer-checks.tsv"
    echo
    echo "  fixed UUIDs (derived from the pin):"
    ncz_repro_env_assignments "$ARCH" | sed 's/^/    /'
    echo
    echo "  stages:"
    local i=0 s
    for s in "${STAGES[@]}"; do
        local mark="run "
        if should_skip "$s"; then mark="skip"; elif ! stage_enabled "$s"; then mark="off "; fi
        printf '    [%s] %02d %s\n' "$mark" "$i" "$s"
        i=$((i+1))
    done
    echo
    echo "  NEVER (operator-only): tag, ship-image, flash/reboot, reap, live repo/R2/Buildkite."
}

if [ "$DRY_RUN" = 1 ]; then
    print_plan
    exit 0
fi

# ---------------------------------------------------------------------------
# offline guard: fail fast if anything tries the network
# ---------------------------------------------------------------------------
if [ "$OFFLINE" = "1" ]; then
    export NCZ_OFFLINE=1
    export http_proxy="http://127.0.0.1:9/" https_proxy="http://127.0.0.1:9/" \
           HTTP_PROXY="http://127.0.0.1:9/" HTTPS_PROXY="http://127.0.0.1:9/" \
           no_proxy="" NO_PROXY=""
    ncz_info "--offline: network access is blocked (proxy 127.0.0.1:9)"
fi

# ---------------------------------------------------------------------------
# run
# ---------------------------------------------------------------------------
ncz_info "build-image $ARCH host=$(hostname -s) git=$GIT_SHA mode=$SCOPE run=$RUN_DIR"
rc=0
for s in "${STAGES[@]}"; do
    if ! stage_enabled "$s"; then
        ncz_log "OFF   [$s] (scope/gates: not requested this run)"
        printf '%02d\t%s\tOFF\t0\n' "$(stage_index "$s")" "$s" >> "$STAGE_TIMES"
        continue
    fi
    # Capture the REAL exit status.  `if ! run_stage ...; then rc=$?` would read
    # the status of the `!` negation (always 0 on failure) and mask every stage
    # failure as success.
    run_stage "$s" "stage_${s//-/_}"
    rc=$?
    if [ "$rc" != 0 ]; then
        ncz_err "build aborted at stage '$s' (rc=$rc). Resuming: $0 --arch $ARCH --resume-from $s --run-dir $RUN_DIR $*"
        break
    fi
done

# ---------------------------------------------------------------------------
# scratch cleanup (policy: no build cruft left behind)
# ---------------------------------------------------------------------------
if [ "$KEEP_WORK" = 1 ]; then
    ncz_info "keeping work dirs ($RUN_DIR/tmp, kvm workdir) per --keep-work"
elif [ "$CLEAN" = 1 ] || [ "$rc" = 0 ]; then
    rm -rf "$RUN_DIR/tmp" 2>/dev/null || true
    [ -n "${KVM_INSTALL_WORKDIR:-}" ] || rm -rf "$RUN_DIR/kvm-gate" "$RUN_DIR/prov-work" 2>/dev/null || true
    # prov-index/ and prov-input-index/ are the provenance scan's scratch too;
    # once the chown-back trap has handed them to the build user they are
    # removable and must not linger (2026-10-11).
    rm -rf "$RUN_DIR/prov-index" "$RUN_DIR/prov-input-index" 2>/dev/null || true
    ncz_info "cleaned scratch under $RUN_DIR (logs + run metadata kept; --keep-work to retain)"
fi

if [ "$rc" = 0 ]; then
    ncz_info "build-image $ARCH COMPLETE (mode=$SCOPE, all requested gates PASS)"
    ncz_info "run metadata: $RUN_DIR/run-metadata.json"
    ncz_info "stage times:  $STAGE_TIMES"
else
    ncz_info "build-image $ARCH finished with failures (rc=$rc); see $LOGS"
fi
exit "$rc"
