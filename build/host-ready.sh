#!/bin/bash
# host-ready.sh -- builder-host readiness check (docs/BUILD-STABILITY.md, M5).
#
# ONE question, asked BEFORE any stage runs: can THIS host satisfy THIS
# commit?  A build that starts on a host that cannot satisfy it burns the
# 13-minute offline-mirror build before the first failure is reported
# (docs/BUILD-STABILITY.md C2/C3/C6/C7/C9).  The 2026-10-29 failures were all
# of that class: a dirty tree, a stale kernel-staging pool, a substrate cache
# that did not resolve, and a host with no extraction tools.
#
# Checks.  Every check runs, so one run reports EVERY problem, and each
# finding is ONE actionable line:
#
#   dirty-tree      the clone has no uncommitted change.  FAIL for a
#                   publishable build (the artifact records the tree's git
#                   SHA, so a dirty tree ships an unreproducible artifact);
#                   a --no-publish diagnostic keeps the historic WARN.
#   kvm             /dev/kvm is usable by the build user.  Required only when
#                   this run executes the kvm gate (the default), because
#                   without it the gate falls back to TCG (slow) or fails.
#   root-owned      a uid-0 file under the clone is REPORTED ONLY.  The
#                   ownership audit and the chown-back belong to M10
#                   (docs/BUILD-STABILITY.md M10), so this check must not
#                   block a build whose debris M10 will clean up.
#   tools           the extraction toolchain exists ON THE HOST: xorriso,
#                   cpio, zstd, unsquashfs and mmdebstrap.  The substrate
#                   initrd/pool and the base rootfs are extracted on the
#                   host, not only inside the container
#                   (docs/BUILD-STABILITY.md section 5, "Risks").
#   disk            the run-dir and the clone filesystems have at least
#                   NCZ_LAYERS_MIN_FREE_GB free (default 60, the same
#                   threshold build/layers-preflight.sh enforces).
#   kernel-staging  the kernel-staging pool holds the release this commit
#                   pins, with the bytes assets/kernel-manifest.json pins.
#                   A pool that holds an older release is stale (C2/T item 5).
#   tmpfs           the build scratch is on a real disk, never on tmpfs.
#   substrate       the substrate cache (NCZ_SUBSTRATE_CACHE_DIRS or
#                   ~/.config/ncz/substrate-cache-dir) resolves and holds an
#                   ISO with the manifests/base.pin sha256 for this arch.  A
#                   cache that does not resolve costs the whole
#                   refresh-substrate stage at full speed (C6).
#   build-inputs    every manifests/build-inputs.tsv row for this arch is
#                   staged and sha256-verified (build/stage-build-inputs.sh
#                   --check, i.e. its verify-only mode).  Reuses that script
#                   rather than re-implementing its store lookup.
#   sudo-model      a privilege model exists (ncz_priv_model != none).  The
#                   password FILE IS NEVER READ: only its configured path and
#                   size are inspected.
#   stdout          this run's stdout and stderr are outside the clone
#                   (/proc/$$/fd/1 and fd/2 must not resolve under $ROOT); a
#                   log written into the tree dirties it mid-build.
#   container-image the ncz-imagebuild container image exists, unless this
#                   run passes --no-container.
#
# Exit: 0 ready, 1 not ready (the findings are printed), 2 usage error.
#
# Usage:
#   build/host-ready.sh --arch amd64|arm64 [options]
# Options:
#   --arch A          the target architecture (required)
#   --root DIR        the clone (default: this script's parent directory)
#   --run-dir DIR     the build run dir (scratch + disk check)
#   --no-publish      a diagnostic run: the dirty tree stays a WARN and
#                     NCZ_HOST_READY_MIN_FREE_GB may lower the disk
#                     threshold.  A publishable build ignores the override:
#                     the documented threshold is the contract there.
#   --gates LIST      the gates this run executes, comma separated (default:
#                     all).  The kvm check is required only when the kvm gate
#                     is in LIST.
#   --staging-dir DIR the kernel-staging pool (default: $NCZ_KERNEL_STAGING_DIR,
#                     else $NCZ_YOCTO_SHARED_DIR/kernel-staging)
#   --substrate-cache DIRS  substrate cache dirs, space separated (default:
#                     $NCZ_SUBSTRATE_CACHE_DIRS, else ~/.config/ncz/substrate-cache-dir)
#   --df-fixture FILE a `df -Pk` output used for the disk check (tests)
#   --fs-fixture FILE "<path><TAB><fstype>" lines used for the tmpfs check
#   --kvm PATH        the KVM device (default: /dev/kvm)
#   --tools "A B C"   the required tool list (default: the five above)
#   --container-image TAG  the build container image (default: $NCZ_IMAGEBUILD_TAG)
#   --no-container    this run does not use the container (skips the check)
#   --stdout-fd N     the stdout fd to inspect (default: 1; tests)
#   -h|--help         this help
set -uo pipefail
export LC_ALL=C

SELF_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=/dev/null
[ -f "$SELF_DIR/lib/ncz-site.sh" ] && . "$SELF_DIR/lib/ncz-site.sh"

ARCH=""
ROOT="$(cd "$SELF_DIR/.." && pwd)"
RUN_DIR=""
NO_PUBLISH=0
GATES=""
STAGING_DIR=""
DF_FIXTURE=""
FS_FIXTURE=""
KVM_DEV="/dev/kvm"
REQUIRED_TOOLS="xorriso cpio zstd unsquashfs mmdebstrap"
SUBSTRATE_CACHE=""
CONTAINER_IMAGE=""
USE_CONTAINER=1
STDOUT_FD=1

usage() {
    sed -n '2,81p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --arch)        ARCH="${2:-}"; shift 2 ;;
        --root)        ROOT="${2:-}"; shift 2 ;;
        --run-dir)     RUN_DIR="${2:-}"; shift 2 ;;
        --no-publish)  NO_PUBLISH=1; shift ;;
        --gates)       GATES="${2:-}"; shift 2 ;;
        --staging-dir) STAGING_DIR="${2:-}"; shift 2 ;;
        --df-fixture)  DF_FIXTURE="${2:-}"; shift 2 ;;
        --fs-fixture)  FS_FIXTURE="${2:-}"; shift 2 ;;
        --kvm)         KVM_DEV="${2:-}"; shift 2 ;;
        --tools)       REQUIRED_TOOLS="${2:-}"; shift 2 ;;
        --substrate-cache) SUBSTRATE_CACHE="${2:-}"; shift 2 ;;
        --container-image) CONTAINER_IMAGE="${2:-}"; shift 2 ;;
        --no-container)    USE_CONTAINER=0; shift ;;
        --stdout-fd)       STDOUT_FD="${2:-}"; shift 2 ;;
        -h|--help)     usage 0 ;;
        *) echo "host-ready.sh: unknown argument '$1'" >&2; usage 2 ;;
    esac
done

[ -n "$ARCH" ] || { echo "host-ready.sh: --arch amd64|arm64 is required" >&2; exit 2; }
case "$ARCH" in amd64|arm64) ;; *) echo "host-ready.sh: bad arch '$ARCH'" >&2; exit 2 ;; esac
[ -d "$ROOT" ] || { echo "host-ready.sh: --root '$ROOT' is not a directory" >&2; exit 2; }

# The documented free-space threshold.  layers-preflight.sh enforces the same
# number for the layer stage, so a host that passes here cannot run out of
# disk in the layers stage.
MIN_FREE_GB_DEFAULT="${NCZ_LAYERS_MIN_FREE_GB:-60}"

FAILS=0
WARNS=0
FAILED_CHECKS=""

_fail() { FAILS=$((FAILS+1)); FAILED_CHECKS="$FAILED_CHECKS $1"; }
_warn() { WARNS=$((WARNS+1)); }
_ok()   { printf '[host-ready] OK   %-15s %s\n' "$1" "$2"; }
_bad()  { _fail "$1"; printf '[host-ready] FAIL %-15s %s\n' "$1" "$2" >&2; }
_report(){ _warn; printf '[host-ready] WARN %-15s %s\n' "$1" "$2" >&2; }

_say() { printf '[host-ready] %s\n' "$*"; }

# Filesystem type of a path.  The nearest existing parent is used when the
# path itself does not exist yet (a run dir is created by the build).
_fstype_of() {
    local p="$1" t="" q="$1"
    if [ -n "$FS_FIXTURE" ] && [ -f "$FS_FIXTURE" ]; then
        t="$(awk -F'\t' -v p="$p" '$1==p{print $2; exit}' "$FS_FIXTURE" 2>/dev/null)"
        [ -n "$t" ] && { printf '%s\n' "$t"; return 0; }
    fi
    if command -v findmnt >/dev/null 2>&1; then
        t="$(findmnt -no FSTYPE -T "$p" 2>/dev/null || true)"
        [ -n "$t" ] && { printf '%s\n' "$t"; return 0; }
    fi
    while [ -n "$q" ] && [ ! -e "$q" ]; do
        local n; n="$(dirname "$q")"
        [ "$n" = "$q" ] && break
        q="$n"
    done
    [ -n "$q" ] && [ -e "$q" ] || { printf 'unknown\n'; return 0; }
    t="$(stat -f -c %T "$q" 2>/dev/null || true)"
    printf '%s\n' "${t:-unknown}"
}

# Free KiB on the filesystem holding a path.  A fixture (the same shape
# build/layers-preflight.sh --df-fixture takes) replaces the measurement.
_free_kb_of() {
    local p="$1"
    if [ -n "$DF_FIXTURE" ] && [ -f "$DF_FIXTURE" ]; then
        awk 'NR==2{print $4}' "$DF_FIXTURE" 2>/dev/null
        return 0
    fi
    df -Pk "$p" 2>/dev/null | awk 'NR==2{print $4}'
}

# ---------------------------------------------------------------------------
# 1. dirty-tree
# ---------------------------------------------------------------------------
check_dirty_tree() {
    local st
    st="$(git -C "$ROOT" status --porcelain 2>/dev/null)"
    if [ -z "$st" ]; then
        _ok dirty-tree "the working tree is clean"
        return
    fi
    local n; n="$(printf '%s\n' "$st" | wc -l | tr -d ' ')"
    local head; head="$(printf '%s\n' "$st" | head -5 | tr '\n' ' ')"
    if [ "$NO_PUBLISH" = 1 ]; then
        _report dirty-tree "the working tree is not clean ($n changed path(s): $head); a --no-publish diagnostic may continue, but the artifact records the dirty git SHA"
        return
    fi
    _bad dirty-tree "the working tree is not clean ($n changed path(s): $head); commit or revert them before the build (the artifact records the tree's git SHA, so a dirty tree ships an unreproducible artifact)"
}

# ---------------------------------------------------------------------------
# 2. kvm
# ---------------------------------------------------------------------------
check_kvm() {
    # The kvm gate needs /dev/kvm; a run without that gate does not.
    case ",${GATES}," in
        *,kvm,*) ;;
        ,,) _ok kvm "the kvm gate is not in this run ($GATES); /dev/kvm is not required"; return ;;
        *) _ok kvm "the kvm gate is not in this run (gates=${GATES:-none}); /dev/kvm is not required"; return ;;
    esac
    if [ ! -e "$KVM_DEV" ]; then
        _bad kvm "$KVM_DEV is absent; the kvm gate needs hardware acceleration (build the image on a host with /dev/kvm, or run without the kvm gate)"
        return
    fi
    if [ ! -r "$KVM_DEV" ] || [ ! -w "$KVM_DEV" ]; then
        _bad kvm "$KVM_DEV is not usable by the build user $(id -un) (uid=$(id -u), gid=$(id -g)); add the build user to the '$(stat -c %G "$KVM_DEV" 2>/dev/null || echo kvm)' group and re-login (the kvm gate would fall back to TCG, or fail)"
        return
    fi
    _ok kvm "$KVM_DEV is readable and writable by $(id -un)"
}

# ---------------------------------------------------------------------------
# 3. root-owned (report only -- M10 owns the enforcement)
# ---------------------------------------------------------------------------
check_root_owned() {
    local hit
    hit="$(find "$ROOT" -xdev -uid 0 -print -quit 2>/dev/null)"
    if [ -n "$hit" ]; then
        _report root-owned "a uid-0 file under the clone: $hit; reported only (docs/BUILD-STABILITY.md M10 owns the ownership audit and the chown-back); run 'sudo chown -R $(id -un):$(id -gn) \"$ROOT\"' before the build"
        return
    fi
    _ok root-owned "no uid-0 file under the clone"
}

# ---------------------------------------------------------------------------
# 4. tools (host-side extraction toolchain)
# ---------------------------------------------------------------------------
check_tools() {
    local t missing=""
    for t in $REQUIRED_TOOLS; do
        command -v "$t" >/dev/null 2>&1 || missing="$missing $t"
    done
    if [ -n "$missing" ]; then
        _bad tools "missing host tools:$missing; the substrate pool/initrd and the base rootfs are extracted on the HOST, not only inside the container (docs/BUILD-STABILITY.md section 5); install them (xorriso, cpio, zstd, unsquashfs, mmdebstrap)"
        return
    fi
    _ok tools "the host extraction toolchain is present ($REQUIRED_TOOLS)"
}

# ---------------------------------------------------------------------------
# 5. disk
# ---------------------------------------------------------------------------
check_disk() {
    local min_gb="$MIN_FREE_GB_DEFAULT"
    if [ -n "${NCZ_HOST_READY_MIN_FREE_GB:-}" ]; then
        if [ "$NO_PUBLISH" = 1 ]; then
            min_gb="$NCZ_HOST_READY_MIN_FREE_GB"
        else
            _say "NCZ_HOST_READY_MIN_FREE_GB is ignored for a publishable build (only a --no-publish diagnostic may lower the threshold); using the documented threshold ${min_gb} GiB"
        fi
    fi
    case "$min_gb" in
        ''|*[!0-9]*) _bad disk "the free-space threshold '$min_gb' is not a number of GiB (NCZ_LAYERS_MIN_FREE_GB / NCZ_HOST_READY_MIN_FREE_GB)"; return ;;
    esac
    local need_kb=$(( min_gb * 1024 * 1024 ))
    local probes=()
    [ -n "$RUN_DIR" ] && probes+=("$RUN_DIR")
    probes+=("$ROOT")
    local p free_kb
    for p in "${probes[@]}"; do
        free_kb="$(_free_kb_of "$p")"
        if [ -z "$free_kb" ]; then
            _report disk "could not measure the free space at $p (the path does not exist yet?)"
            continue
        fi
        if [ "$free_kb" -lt "$need_kb" ]; then
            _bad disk "only $(( free_kb / 1024 / 1024 )) GiB free at $p (< ${min_gb} GiB required; NCZ_LAYERS_MIN_FREE_GB=${MIN_FREE_GB_DEFAULT}); free space on the build filesystem or point --run-dir at a bigger disk"
        else
            _ok disk "$(( free_kb / 1024 / 1024 )) GiB free at $p (>= ${min_gb} GiB)"
        fi
    done
    return 0
}

# ---------------------------------------------------------------------------
# 6. kernel-staging (stale pool)
# ---------------------------------------------------------------------------
_pool_dir() {
    if [ -n "$STAGING_DIR" ]; then printf '%s\n' "$STAGING_DIR"; return 0; fi
    if [ -n "${NCZ_KERNEL_STAGING_DIR:-}" ]; then printf '%s\n' "$NCZ_KERNEL_STAGING_DIR"; return 0; fi
    local ysd=""
    if command -v ncz_site_value >/dev/null 2>&1; then
        ysd="$(ncz_site_value NCZ_YOCTO_SHARED_DIR yocto-shared-dir)"
    else
        ysd="${NCZ_YOCTO_SHARED_DIR:-}"
    fi
    [ -n "$ysd" ] && printf '%s\n' "${ysd%/}/kernel-staging"
    return 0
}

_pool_releases() {  # pool -> the rNNN release names it holds (bounded)
    local pool="$1"
    find "$pool" -maxdepth 1 -mindepth 1 -type d -name 'r[0-9]*' -printf '%f\n' 2>/dev/null \
        | LC_ALL=C sort | head -10 | tr '\n' ' '
}

check_kernel_staging() {
    local pool; pool="$(_pool_dir)"
    if [ -z "$pool" ]; then
        _bad kernel-staging "no kernel-staging pool is configured (set NCZ_YOCTO_SHARED_DIR or ~/.config/ncz/yocto-shared-dir, or pass --staging-dir); the build cannot stage the kernel this commit pins"
        return
    fi
    if [ ! -d "$pool" ]; then
        _bad kernel-staging "the kernel-staging pool $pool does not exist (mount the shared export or fix the site setting)"
        return
    fi
    case "$ARCH" in
        arm64) check_kernel_staging_arm64 "$pool" ;;
        amd64) check_kernel_staging_amd64 "$pool" ;;
    esac
}

check_kernel_staging_arm64() {
    local pool="$1" rel="" staged=""
    rel="$(sed 's/#.*//' "$ROOT/assets/kernel/mainline.release" 2>/dev/null | tr -d '[:space:]')"
    if [ -z "$rel" ]; then
        _bad kernel-staging "assets/kernel/mainline.release does not name a staged release; the pool $pool cannot be checked against this commit"
        return
    fi
    if [ -d "$pool/$rel" ]; then
        staged="$pool/$rel"
    elif [ -L "$ROOT/assets/kernel/mainline" ] && [ -d "$ROOT/assets/kernel/mainline" ]; then
        # The link may point at this host's own spelling of the pool.
        staged="$(cd "$ROOT/assets/kernel/mainline" 2>/dev/null && pwd || true)"
    fi
    if [ -z "$staged" ]; then
        _bad kernel-staging "stale kernel-staging: the pool $pool does not hold the release $rel this commit pins (it holds:$(_pool_releases "$pool")none); publish the kernel into the pool, or re-pin assets/kernel/mainline.release to a release the pool holds"
        return
    fi
    # The pinned bytes: assets/kernel-manifest.json names the Image, the
    # modules and the config of the release this commit ships.
    local mf="$ROOT/assets/kernel-manifest.json"
    if [ ! -f "$mf" ]; then
        _bad kernel-staging "assets/kernel-manifest.json is missing; the staged kernel cannot be checked against the pin"
        return
    fi
    local want got name relfile
    for relfile in Image-cixmini.bin modules-cixmini.tgz config-7.3.0-sky1-ncz; do
        want="$(python3 -I - "$mf" "$relfile" <<'PYEOF' 2>/dev/null || true
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
m = d.get("variants", {}).get("mainline", {})
key = {"Image-cixmini.bin": "image", "modules-cixmini.tgz": "modules", "config-7.3.0-sky1-ncz": "config"}[sys.argv[2]]
print(m.get(key, {}).get("sha256", ""))
PYEOF
)"
        [ -n "$want" ] || continue
        if [ ! -f "$staged/$relfile" ]; then
            _bad kernel-staging "the staged release $staged does not hold $relfile, which assets/kernel-manifest.json pins; the pool is stale"
            return
        fi
        got="$(sha256sum "$staged/$relfile" 2>/dev/null | awk '{print $1}')"
        if [ "$got" != "$want" ]; then
            _bad kernel-staging "stale kernel-staging: $staged/$relfile has sha256 $got, but assets/kernel-manifest.json pins $want; the pool holds a different build than this commit pins"
            return
        fi
    done
    _ok kernel-staging "the pool holds $rel with the bytes assets/kernel-manifest.json pins"
}

check_kernel_staging_amd64() {
    local pool="$1" kver="" d
    kver="$(tr -d '[:space:]' < "$ROOT/assets/kernel/amd64-stable/KVER" 2>/dev/null || true)"
    if [ -z "$kver" ]; then
        _bad kernel-staging "assets/kernel/amd64-stable/KVER does not name the pinned amd64 kernel; the pool $pool cannot be checked against this commit"
        return
    fi
    for d in "$pool"/amd64-t2-*/*/ "$pool"/amd64-stable-*/; do
        [ -d "$d" ] || continue
        [ -s "$d/KVER" ] || continue
        if [ "$(tr -d '[:space:]' < "$d/KVER")" = "$kver" ]; then
            _ok kernel-staging "the pool holds an amd64 build with the pinned KVER $kver ($d)"
            return
        fi
    done
    _bad kernel-staging "stale kernel-staging: no staged amd64 build under $pool has the pinned KVER $kver; publish the kernel into the pool (build/publish-amd64-kernel.sh) or re-pin assets/kernel/amd64-stable/KVER"
}

# ---------------------------------------------------------------------------
# 7. tmpfs scratch
# ---------------------------------------------------------------------------
check_tmpfs() {
    local probes=() p fst
    [ -n "$RUN_DIR" ] && probes+=("$RUN_DIR")
    [ -n "${TMPDIR:-}" ] && probes+=("$TMPDIR")
    if [ "${#probes[@]}" = 0 ]; then
        _ok tmpfs "no scratch path known (no --run-dir and TMPDIR unset); the scratch filesystem cannot be checked"
        return
    fi
    local bad=0
    for p in "${probes[@]}"; do
        fst="$(_fstype_of "$p")"
        case "$fst" in
            tmpfs|ramfs)
                _bad tmpfs "the build scratch $p is on $fst; put --run-dir (and TMPDIR) on a real disk -- a build on tmpfs cannot hold the layers"
                bad=1 ;;
            unknown)
                _report tmpfs "could not determine the filesystem of the scratch $p" ;;
            *)
                _ok tmpfs "the scratch $p is on $fst (not tmpfs)" ;;
        esac
    done
    [ "$bad" = 1 ] && return
    :
}

# ---------------------------------------------------------------------------
# 8. substrate cache (M5 item 2)
# ---------------------------------------------------------------------------
# The pinned ISO for this arch, from manifests/base.pin.  Nothing is invented:
# a pin row that is absent or malformed is itself a finding.
_substrate_pin() {
    local pin="$ROOT/manifests/base.pin"
    [ -f "$pin" ] || return 0
    awk -F'\t' -v a="$ARCH" '$1==a{print $2; exit}' "$pin" 2>/dev/null
}

substrate_cache_dirs() {  # one dir per line
    local dirs="$SUBSTRATE_CACHE" v=""
    if [ -z "$dirs" ] && command -v ncz_site_value >/dev/null 2>&1; then
        dirs="$(ncz_site_value NCZ_SUBSTRATE_CACHE_DIRS substrate-cache-dir)"
    fi
    [ -n "$dirs" ] || dirs="${NCZ_SUBSTRATE_CACHE_DIRS:-}"
    for v in $dirs; do [ -n "$v" ] && printf '%s\n' "${v%/}"; done
    return 0
}

check_substrate_cache() {
    local want short dirs f found=""
    want="$(_substrate_pin)"
    if [ -z "$want" ]; then
        _bad substrate "manifests/base.pin names no substrate sha256 for arch $ARCH; the cache cannot be checked against a pin"
        return
    fi
    case "$want" in
        *[!0-9a-f]*|'') _bad substrate "manifests/base.pin has a malformed substrate sha256 for arch $ARCH ('$want'); fix the pin, never float to what Debian serves today" ;;
    esac
    [ "${#want}" = 64 ] || { _bad substrate "manifests/base.pin substrate sha256 for arch $ARCH is ${#want} hex chars, not 64"; return; }
    short="${want:0:8}"
    dirs="$(substrate_cache_dirs)"
    if [ -z "$dirs" ]; then
        _bad substrate "no substrate cache is configured (set NCZ_SUBSTRATE_CACHE_DIRS or ~/.config/ncz/substrate-cache-dir); the pinned netinst ISO for $ARCH ($short) cannot be resolved"
        return
    fi
    for f in $dirs; do
        if [ ! -d "$f" ]; then
            _report substrate "the substrate cache dir $f does not exist"
            continue
        fi
        # Same lookup as build/stage-substrate.sh: <name>-<yyyymmdd>-<sha8>.iso
        # or the upstream name, sha256-verified against the pin.
        local cand
        for cand in "$f"/*-"$short".iso "$f"/debian-testing-"$ARCH"-netinst.iso; do
            [ -f "$cand" ] || continue
            if [ "$(sha256sum "$cand" 2>/dev/null | awk '{print $1}')" = "$want" ]; then
                found="$cand"
                break 2
            fi
        done
    done
    if [ -n "$found" ]; then
        _ok substrate "the substrate cache holds the pinned $ARCH ISO ($short) at $found"
        return
    fi
    _bad substrate "the substrate cache ($(printf '%s ' $dirs)) holds no ISO with the pinned sha256 $short for $ARCH; restore it into a cache dir, or adopt a new substrate deliberately (manifests/base.pin)"
}

# ---------------------------------------------------------------------------
# 9. build inputs (M5 item 3)
# ---------------------------------------------------------------------------
# Reuses stage-build-inputs.sh --check (its verify-only mode) so the store
# lookup, the per-row sha256 and the arch filter have ONE implementation.
check_build_inputs() {
    local script="$ROOT/build/stage-build-inputs.sh" tsv="$ROOT/manifests/build-inputs.tsv"
    if [ ! -x "$script" ] && [ ! -f "$script" ]; then
        _bad build-inputs "build/stage-build-inputs.sh is missing; the pinned build inputs cannot be verified"
        return
    fi
    if [ ! -f "$tsv" ]; then
        _bad build-inputs "manifests/build-inputs.tsv is missing; the pinned build inputs cannot be verified"
        return
    fi
    local out rc first="" nbad
    out="$(bash "$script" --arch "$ARCH" --check 2>&1)"; rc=$?
    if [ "$rc" = 0 ]; then
        _ok build-inputs "every build-inputs.tsv row for $ARCH is staged and sha256-verified"
        return
    fi
    # ONE actionable line: a count plus the first offending rows, not the dump.
    nbad="$(printf '%s\n' "$out" | grep -c 'MISSING/BAD:' 2>/dev/null || true)"
    first="$(printf '%s\n' "$out" \
        | sed -n 's/^\[build-inputs\] MISSING\/BAD: //p' \
        | sed 's/ (run build\/stage-build-inputs.sh.*$//' \
        | head -3 | tr '\n' ';' | sed 's/;$//;s/;/; /g')"
    [ -n "$first" ] || first="$(printf '%s\n' "$out" | grep -v '^\[build-inputs\] arch=\|^\[build-inputs\] OK' | head -2 | tr '\n' ';' | sed 's/;$//')"
    _bad build-inputs "${nbad:-some} build-inputs row(s) for $ARCH are not staged or do not match the pin: ${first:-see build/stage-build-inputs.sh --arch $ARCH --check}; stage them with build/stage-build-inputs.sh --arch $ARCH (a missing store is a site setting: NCZ_BUILD_INPUTS_DIR)"
}

# ---------------------------------------------------------------------------
# 10. sudo model (M5 item 4)
# ---------------------------------------------------------------------------
# Asks the ONE privilege helper which model applies.  The password file is
# never read: only its configured path and size are inspected, and its
# contents are never printed.
check_sudo_model() {
    local model="" pwfile="${NCZ_SUDO_PASS_FILE:-}"
    if [ -f "$SELF_DIR/lib/priv.sh" ]; then
        # shellcheck source=/dev/null
        model="$( . "$SELF_DIR/lib/priv.sh" >/dev/null 2>&1; ncz_priv_model 2>/dev/null || true)"
    fi
    case "$model" in
        root|direct|sudo-nopasswd)
            _ok sudo-model "privilege model: $model" ;;
        sudo-stdin)
            if [ -n "$pwfile" ] && [ -f "$pwfile" ]; then
                _ok sudo-model "privilege model: sudo-stdin (password file $(stat -c %s "$pwfile" 2>/dev/null || echo '?') B, contents not read)"
            else
                _bad sudo-model "privilege model: sudo-stdin, but no readable password file is configured; set NCZ_SUDO_PASS_FILE or ~/.config/ncz/sudo-pass-file"
            fi ;;
        none|'')
            _bad sudo-model "no usable privilege model (need root, passwordless sudo, or NCZ_SUDO_PASS_FILE; see build/lib/priv.sh); the build's mount/chroot steps cannot run" ;;
        *)
            _bad sudo-model "unrecognised privilege model '$model' (see build/lib/priv.sh)" ;;
    esac
}

# ---------------------------------------------------------------------------
# 11. stdout / stderr outside the clone (M5 item 9)
# ---------------------------------------------------------------------------
# fd 1 and fd 2 must not resolve under $ROOT: a log redirected into the tree
# dirties it mid-build, and the artifact then records a tree that changed
# while it was being built.
_fd_target() {  # fd -> the resolved path, or empty
    local fd="$1" t=""
    [ -e "/proc/$$/fd/$fd" ] || return 0
    t="$(readlink "/proc/$$/fd/$fd" 2>/dev/null || true)"
    [ -n "$t" ] && printf '%s\n' "$t"
    return 0
}

check_stdout() {
    local root_real fd t badn=0
    root_real="$(readlink -f "$ROOT" 2>/dev/null || printf '%s' "$ROOT")"
    for fd in "$STDOUT_FD" $([ "$STDOUT_FD" = 1 ] && echo 2); do
        t="$(_fd_target "$fd")"
        [ -n "$t" ] || continue
        case "$t" in
            pipe:*|socket:*|/dev/null|/dev/pts/*|/dev/tty*|anon_inode:*|'') continue ;;
        esac
        case "$t" in
            "$root_real"/*|"$ROOT"/*)
                _bad stdout "fd $fd points at $t, which is inside the clone $root_real; write the build log outside the tree (--run-dir) so the tree stays clean while it is built"
                badn=1 ;;
        esac
    done
    [ "$badn" = 1 ] && return 0
    _ok stdout "this run's stdout and stderr are outside the clone"
}

# ---------------------------------------------------------------------------
# 12. container image (M5 item 10)
# ---------------------------------------------------------------------------
check_container_image() {
    local tag="${CONTAINER_IMAGE:-${NCZ_IMAGEBUILD_TAG:-}}"
    if [ "$USE_CONTAINER" != 1 ]; then
        _ok container-image "this run passes --no-container; the build image is not required"
        return
    fi
    if [ -z "$tag" ]; then
        _bad container-image "no build container image is configured (set NCZ_IMAGEBUILD_TAG or pass --container-image); the image stage has nothing to run in"
        return
    fi
    local eng
    for eng in podman docker; do
        command -v "$eng" >/dev/null 2>&1 || continue
        if "$eng" image exists "$tag" >/dev/null 2>&1; then
            _ok container-image "the build image $tag exists ($eng)"
            return
        fi
    done
    if ! command -v podman >/dev/null 2>&1 && ! command -v docker >/dev/null 2>&1; then
        _bad container-image "neither podman nor docker is installed, so the image $tag cannot be present; install podman or pass --no-container"
        return
    fi
    _bad container-image "the build image $tag is absent; build it from build/containers/Containerfile.ncz-imagebuild ('podman save | sudo podman load'), or pass --no-container"
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
_say "arch=$ARCH root=$ROOT run=${RUN_DIR:-<none>} publish=$([ "$NO_PUBLISH" = 1 ] && echo no || echo yes) gates=${GATES:-all}"

check_dirty_tree
check_kvm
check_root_owned
check_tools
check_disk
check_kernel_staging
check_tmpfs
check_substrate_cache
check_build_inputs
check_sudo_model
check_stdout
check_container_image

if [ "$FAILS" = 0 ]; then
    _say "READY: 0 failing check(s), $WARNS warning(s)"
    exit 0
fi
_say "NOT READY: $FAILS failing check(s):$FAILED_CHECKS ($WARNS warning(s))"
exit 1
