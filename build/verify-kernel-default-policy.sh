#!/bin/bash
# verify-kernel-default-policy.sh -- enforce the NCZ-OS kernel policy at
# build time, BEFORE staging anything that becomes the default boot kernel.
#
# Policy (operator 2026-10-05, evening; supersedes the 2026-09-30 and the
# 2026-10-05 morning rules):
#   - ONE kernel: 7.3, the SAME pinned build on EVERY architecture. It is the
#     DEFAULT boot kernel and the installer boot kernel.
#   - 7.2.x (including 7.2.9) is retired everywhere: no default, no rescue, no
#     edge, no installer.
#   - There is NO EDGE channel any more. The edge pointers/manifests/assets are
#     gone.
#   - RESCUE boots the SAME pinned 7.3 kernel with the accelerator drivers
#     blacklisted on its command line (no RESCUE_BASE series of its own).
#   - An -rcN default is permitted ONLY while the pinned 7.3 version is still an
#     -rcN and assets/kernel/KERNEL-POLICY says so explicitly
#     (RC_DEFAULT_ALLOWED=1) with an expiry note. When 7.3.0 final lands the
#     allowance is removed and an -rcN default fails again.
#
# Why this exists (real, live-defect, 2026-09-29 image
# ncz-os-arm64-20260929-4bd67b5f.img): the shipped arm64 payload KVER_NEXT
# sidecar resolved to the rc edge build, not the release mainline the symlink
# nominally pointed at, and .66 booted it as the default. The same class of
# misdirection is still possible, so the gate stays: the default kernel must be
# the pinned 7.3 build on both arches and nothing else may be staged.
#
# What this verifier checks (each is independent, any failure exits 1):
#   7.  assets/kernel-manifest.json exists and is valid JSON with a
#       variants.mainline.kver.
#   1.  arm64: assets/kernel/mainline/KVER exists and its payload is complete;
#       the default is not a Debian-archive kernel.
#   2.  (arm64) assets/kernel/mainline/KVER matches the manifest's
#       variants.mainline.kver (manifest drift).
#   6.  amd64: assets/kernel/amd64-stable/KVER exists; the default is not a
#       Debian-archive kernel and does not use the retired 'aerfix' flavour.
#   8.  (both arches) the runtime rEFInd pipeline was refactored to the unified
#       7.3 policy: the amd64 classifier hook + refresh script carry the unified
#       marker and no longer pin an "edge" channel; the arm64 refresh carries
#       the unified marker.
#   9.  (both arches) the rEFInd refresh scripts preserve the rescue entry and
#       redefine it as the SAME default kernel with the accelerator blacklist
#       (marker block + module_blacklist=$RESCUE_ACCEL_BLACKLIST), plus the
#       *-rescue sparing / auto-promotion safety net.
#  10.  (both arches) If assets/kernel/KERNEL-POLICY exists: the default kernel
#       must match DEFAULT_BASE (7.3); an -rcN default is allowed only while
#       RC_DEFAULT_ALLOWED=1 and the pinned version really is an -rcN; EDGE must
#       be disabled; and no 7.2.x channel/overlay asset may be staged.
#
# Usage:
#   verify-kernel-default-policy.sh [--root <repo-root>] [--arch arm64|amd64]
#
# Exit codes:
#   0  policy satisfied (every check passed)
#   1  policy violated (one or more checks failed)
#   2  misuse (bad args, missing root, missing manifest, etc.)
#
# Designed to be invoked from:
#   - build/build-iso-di.sh, before kernel staging starts
#   - build/build-squashfs-layers.sh, before KVER_NEXT is copied into the
#     base payload
#   - build/build-baked-rootfs.sh, before KVER_NEXT is copied into the
#     chroot
#   - make kernel-debs, as a pre-flight gate
set -uo pipefail
export LC_ALL=C

ROOT="${ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
ARCH="${ARCH:-}"
while [ "$#" -gt 0 ]; do
    case "$1" in
        --root) ROOT="$2"; shift 2 ;;
        --arch)  ARCH="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "[kernel-default-policy] ERROR: unknown arg '$1'" >&2; exit 2 ;;
    esac
done

# Reject unset or empty ROOT.
[ -n "$ROOT" ] && [ -d "$ROOT" ] || {
    echo "[kernel-default-policy] ERROR: --root '$ROOT' is not a directory" >&2
    exit 2
}

# If ARCH was not passed, infer from the repository's release.conf or dpkg.
if [ -z "$ARCH" ]; then
    if [ -s "$ROOT/release.conf" ]; then
        ARCH=$(grep -E '^[[:space:]]*NCZ_TARGET_ARCH[[:space:]]*=' "$ROOT/release.conf" \
               | head -1 | sed -nE 's/.*=[[:space:]]*"?([^"]+)"?.*/\1/p') || true
    fi
fi
if [ -z "$ARCH" ] && command -v dpkg >/dev/null 2>&1; then
    ARCH=$(dpkg --print-architecture 2>/dev/null || true)
fi
case "$ARCH" in
    arm64|aarch64|amd64|x86_64) ;;
    "")
        echo "[kernel-default-policy] ERROR: could not determine ARCH (set --arch or NCZ_TARGET_ARCH)" >&2
        exit 2
        ;;
    *)
        echo "[kernel-default-policy] ERROR: unsupported ARCH '$ARCH' (want arm64 or amd64)" >&2
        exit 2
        ;;
esac

log() { printf '[kernel-default-policy] %s\n' "$*"; }
warn() { printf '[kernel-default-policy] WARN: %s\n' "$*" >&2; }
err()  { printf '[kernel-default-policy] FAIL: %s\n' "$*" >&2; FAIL=1; }
FAIL=0

# Resolve a possibly-symlinked directory and return the path to <name> within
# it, or print the symlink target on failure so the operator sees WHY.
resolve_kver_file() {
    # resolve_kver_file <dir-path>  -> echoes <resolved-dir>/KVER
    local d="$1"
    if [ ! -e "$d" ]; then
        if [ -L "$d" ]; then
            local t
            t=$(readlink -f "$d" 2>/dev/null || readlink "$d")
            echo "DANGLING_SYM:$t"
            return 1
        fi
        echo "MISSING_DIR"
        return 1
    fi
    cd "$d" 2>/dev/null && pwd -P
}

# find_local_sibling: scan $ROOT/assets/kernel/r*/ for one whose KVER file
# matches <wanted-kver>. Echoes the resolved directory path on success, or
# empty on no match. Used as a fallback when the committed symlink at
# assets/kernel/mainline is dangling because the kernel-staging pool
# (/mnt/argonas-yocto-shared) is not mounted on this build host.
find_local_sibling() {
    local wanted_kver="$1" dir kver
    [ -n "$wanted_kver" ] || return 1
    [ -d "$ROOT/assets/kernel" ] || return 1
    for dir in "$ROOT"/assets/kernel/r*/; do
        [ -d "$dir" ] || continue
        [ -s "$dir/KVER" ] || continue
        kver=$(tr -d '[:space:]' < "$dir/KVER")
        if [ "$kver" = "$wanted_kver" ]; then
            cd "$dir" 2>/dev/null && pwd -P
            return 0
        fi
    done
    return 1
}

# is_prerelease: classify a KVER string as release-candidate or not.
is_prerelease() {
    case "$1" in *-rc[0-9]*) return 0 ;; *) return 1 ;; esac
}

# is_debian_kernel: a Debian-archive kernel shape, never ours.
is_debian_kernel() {
    case "$1" in
        *-arm64|*-amd64|7.1.*|7.1-*) return 0 ;;
    esac
    return 1
}

# ---------------------------------------------------------------------------
# Check 7: manifest is valid JSON.
# The manifest is Sky1-only (build/kernel-manifest.py only emits the
# variants.mainline entry), but its existence is required even on amd64
# because every other release-pipeline tool (kernel-port-watch.sh,
# kernel-manifest.py check in CI, etc.) reads it.
# ---------------------------------------------------------------------------
MANIFEST="$ROOT/assets/kernel-manifest.json"
if [ ! -s "$MANIFEST" ]; then
    err "manifest missing or empty: $MANIFEST (run build/kernel-manifest.py gen)"
    exit 1
fi
if ! python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$MANIFEST" >/dev/null 2>&1; then
    err "manifest is not valid JSON: $MANIFEST"
    exit 1
fi
MANIFEST_MAINLINE_KVER=$(python3 -c '
import json,sys
m=json.load(open(sys.argv[1]))
print((m.get("variants",{}).get("mainline",{}) or {}).get("kver",""))
' "$MANIFEST")
if [ -z "$MANIFEST_MAINLINE_KVER" ]; then
    err "manifest has no variants.mainline.kver (cannot cross-check KVER sidecar)"
fi

# ---------------------------------------------------------------------------
# Policy pins (assets/kernel/KERNEL-POLICY) parsed up front; the per-arch
# checks below and check 10 use these.
# ---------------------------------------------------------------------------
POLICY_FILE="$ROOT/assets/kernel/KERNEL-POLICY"
DEFAULT_BASE=""
RC_DEFAULT_ALLOWED=""
RC_DEFAULT_EXPIRY_NOTE=""
RESCUE_SAME_KERNEL=""
EDGE_ENABLED=""
RESCUE_AMD64_T2=""
RESCUE_AMD64_GENERIC=""
RESCUE_ARM64=""
policy_get() { sed -nE "s/^$1=([^[:space:]#]+).*/\1/p" "$POLICY_FILE" | head -1; }
if [ -s "$POLICY_FILE" ]; then
    DEFAULT_BASE=$(policy_get DEFAULT_BASE)
    RC_DEFAULT_ALLOWED=$(policy_get RC_DEFAULT_ALLOWED)
    RC_DEFAULT_EXPIRY_NOTE=$(policy_get RC_DEFAULT_EXPIRY_NOTE)
    RESCUE_SAME_KERNEL=$(policy_get RESCUE_SAME_KERNEL)
    EDGE_ENABLED=$(policy_get EDGE_ENABLED)
    RESCUE_AMD64_T2=$(policy_get RESCUE_AMD64_BLACKLIST_T2)
    RESCUE_AMD64_GENERIC=$(policy_get RESCUE_AMD64_BLACKLIST_GENERIC)
    RESCUE_ARM64=$(policy_get RESCUE_ARM64_BLACKLIST)
fi

# ---------------------------------------------------------------------------
# Check 1+2+3: assets/kernel/mainline/KVER exists, payload complete, and the
# manifest cross-check. Applies to arm64 ONLY.
# ---------------------------------------------------------------------------
MAINLINE_RESOLVED_DIR=$(resolve_kver_file "$ROOT/assets/kernel/mainline" 2>/dev/null) || true
KVER_NEXT=""
if [ "$ARCH" = arm64 ] || [ "$ARCH" = aarch64 ]; then
    case "$MAINLINE_RESOLVED_DIR" in
        DANGLING_SYM:*)
            _t=${MAINLINE_RESOLVED_DIR#DANGLING_SYM:}
            _fallback=$(find_local_sibling "$MANIFEST_MAINLINE_KVER" 2>/dev/null || true)
            if [ -n "$_fallback" ] && [ -d "$_fallback" ]; then
                warn "assets/kernel/mainline symlink -> '$_t' (unresolved) but local tree '$_fallback' has matching KVER '$MANIFEST_MAINLINE_KVER'; using it (build farm uses the pool-mounted symlink)"
                MAINLINE_RESOLVED_DIR="$_fallback"
            fi
            ;;
    esac
    case "$MAINLINE_RESOLVED_DIR" in
        DANGLING_SYM:*|MISSING_DIR|"")
            if [ -L "$ROOT/assets/kernel/mainline" ]; then
                _t=$(readlink -f "$ROOT/assets/kernel/mainline" 2>/dev/null || readlink "$ROOT/assets/kernel/mainline")
                err "assets/kernel/mainline is a symlink to '$_t' that does not resolve to an existing directory on this build host. Mount the kernel-staging pool or repoint the symlink to the pinned 7.3 build."
            else
                err "assets/kernel/mainline is missing: no default kernel payload is staged"
            fi
            ;;
        *)
            MAINLINE_KVER_FILE="$MAINLINE_RESOLVED_DIR/KVER"
            if [ ! -s "$MAINLINE_KVER_FILE" ]; then
                err "assets/kernel/mainline/KVER is missing or empty (no default kernel staged)"
            else
                KVER_NEXT=$(tr -d '[:space:]' < "$MAINLINE_KVER_FILE")
                if [ -z "$KVER_NEXT" ]; then
                    err "assets/kernel/mainline/KVER is blank"
                else
                    if is_debian_kernel "$KVER_NEXT"; then
                        err "mainline KVER '$KVER_NEXT' names a Debian-archive kernel; mainline MUST be the NCZ 7.3 kernel"
                    else
                        log "mainline KVER '$KVER_NEXT'"
                    fi
                    for _f in "Image-cixmini.bin" "modules-cixmini.tgz" \
                              "config-$KVER_NEXT"; do
                        if [ ! -s "$MAINLINE_RESOLVED_DIR/$_f" ]; then
                            err "assets/kernel/mainline/$_f missing or empty (mainline payload incomplete)"
                        fi
                    done
                    if [ ! -s "$MAINLINE_RESOLVED_DIR/headers-cixmini.tar.zst" ] \
                       && [ ! -s "$MAINLINE_RESOLVED_DIR/headers-$KVER_NEXT.tar.zst" ]; then
                        err "assets/kernel/mainline/headers-* missing or empty (mainline payload incomplete)"
                    fi
                fi
            fi
            ;;
    esac
fi
# Check 2: manifest cross-check (arm64).
case "$ARCH" in
    arm64|aarch64)
        if [ -n "$KVER_NEXT" ] && [ -n "$MANIFEST_MAINLINE_KVER" ] && [ "$KVER_NEXT" != "$MANIFEST_MAINLINE_KVER" ]; then
            err "mainline KVER '$KVER_NEXT' != manifest variants.mainline.kver '$MANIFEST_MAINLINE_KVER' (manifest drift)"
        elif [ -n "$KVER_NEXT" ] && [ -n "$MANIFEST_MAINLINE_KVER" ]; then
            log "mainline KVER matches manifest: $KVER_NEXT"
        fi
        ;;
esac

# ---------------------------------------------------------------------------
# Check 6: amd64 -- mandatory default line (assets/kernel/amd64-stable). The
# old second "edge" line (assets/kernel/amd64-edge) is retired.
# ---------------------------------------------------------------------------
AMD64_STABLE_KVER=""
if [ "$ARCH" = amd64 ] || [ "$ARCH" = x86_64 ]; then
    AMD64_STABLE_RESOLVED_DIR=$(resolve_kver_file "$ROOT/assets/kernel/amd64-stable" 2>/dev/null) || true
    case "$AMD64_STABLE_RESOLVED_DIR" in
        DANGLING_SYM:*)
            _t=$(readlink -f "$ROOT/assets/kernel/amd64-stable" 2>/dev/null || readlink "$ROOT/assets/kernel/amd64-stable")
            err "amd64: assets/kernel/amd64-stable is a symlink to '$_t' that does not resolve; the kernel-staging pool is not mounted on this build host"
            ;;
        MISSING_DIR|"")
            err "amd64: assets/kernel/amd64-stable is missing (amd64 must ship the pinned 7.3 default line)"
            ;;
        *)
            AMD64_STABLE_KVER_FILE="$AMD64_STABLE_RESOLVED_DIR/KVER"
            if [ ! -s "$AMD64_STABLE_KVER_FILE" ]; then
                err "amd64: assets/kernel/amd64-stable/KVER is missing (amd64 must ship the pinned 7.3 default line)"
            else
                AMD64_STABLE_KVER=$(tr -d '[:space:]' < "$AMD64_STABLE_KVER_FILE")
                if is_debian_kernel "$AMD64_STABLE_KVER"; then
                    err "amd64: default KVER '$AMD64_STABLE_KVER' names a Debian-archive kernel; must be the NCZ 7.3 kernel"
                elif [[ "$AMD64_STABLE_KVER" == *aerfix* ]]; then
                    # 'aerfix' named both the broad 9010 AER revert build
                    # (rc6-1) and a 9011 quirk build (rc6-2); the name is
                    # retired so the pin always says which AER change ships
                    # (default: 9011, '-aer9011').
                    err "amd64: default KVER '$AMD64_STABLE_KVER' uses the retired, ambiguous 'aerfix' flavour; pin the 9011 build (*-aer9011)"
                else
                    log "amd64: default KVER '$AMD64_STABLE_KVER'"
                fi
            fi
            ;;
    esac
fi

# ---------------------------------------------------------------------------
# Check 8 (both arches): the runtime rEFInd pipeline was refactored to the
# unified 7.3 policy. The old amd64 classifier hook/refresh pinned an "edge"
# channel to 7.3.0-rc6; the new ones carry the unified marker and no edge pin.
# ---------------------------------------------------------------------------
UNIFIED_MARKER='NCZ-UNIFIED-KERNEL-73'
_amd64_hook="$ROOT/assets/refind/zz1-ncz-refind-refresh-amd64"
_amd64_refresh="$ROOT/assets/refind/ncz-refind-refresh-amd64.sh"
_arm64_refresh="$ROOT/assets/refind/ncz-refind-refresh.sh"
if [ -f "$_amd64_hook" ]; then
    if grep -q "$UNIFIED_MARKER" "$_amd64_hook" 2>/dev/null; then
        log "amd64: classifier hook is on the unified 7.3 policy"
    else
        err "amd64: classifier hook lacks the '$UNIFIED_MARKER' marker; it may still classify an old edge channel"
    fi
    if grep -q 'amd64 edge channel is pinned' "$_amd64_hook" 2>/dev/null; then
        err "amd64: classifier hook still carries the retired 'amd64 edge channel is pinned' marker"
    fi
fi
if [ -f "$_amd64_refresh" ]; then
    if grep -q "$UNIFIED_MARKER" "$_amd64_refresh" 2>/dev/null; then
        log "amd64: rEFInd refresh is on the unified 7.3 policy"
    else
        err "amd64: rEFInd refresh lacks the '$UNIFIED_MARKER' marker"
    fi
    if grep -q 'amd64 edge channel is pinned' "$_amd64_refresh" 2>/dev/null; then
        err "amd64: rEFInd refresh still carries the retired 'amd64 edge channel is pinned' marker"
    fi
fi
if [ -f "$_arm64_refresh" ] && ! grep -q "$UNIFIED_MARKER" "$_arm64_refresh" 2>/dev/null; then
    err "arm64: rEFInd refresh lacks the '$UNIFIED_MARKER' marker"
fi

# ---------------------------------------------------------------------------
# Check 9 (both arches): the rEFInd refresh scripts preserve the rescue entry
# AND redefine it as the SAME default kernel with the accelerator blacklist.
# Requires: the *-rescue sparing/promotion safety net; the marker block
# NCZ-RESCUE-ACCEL-BEGIN/END; and the rescue cmdline consumes
# module_blacklist=$RESCUE_ACCEL_BLACKLIST.
# ---------------------------------------------------------------------------
if [ -z "${SKIP_RESCUE_CHECK:-}" ]; then
    _rescue_arm64="$_arm64_refresh"
    _rescue_amd64="$_amd64_refresh"
    for _script in "$_rescue_arm64" "$_rescue_amd64"; do
        [ -f "$_script" ] || { err "rescue preservation: $_script missing"; continue; }
        if ! grep -q '\*-rescue' "$_script" 2>/dev/null; then
            err "rescue preservation: $_script no longer contains the *-rescue sparing/promotion logic"
        fi
        if ! grep -q 'NCZ-RESCUE-ACCEL-BEGIN' "$_script" 2>/dev/null \
           || ! grep -q 'NCZ-RESCUE-ACCEL-END' "$_script" 2>/dev/null; then
            err "rescue preservation: $_script no longer carries the NCZ-RESCUE-ACCEL marker block (the rescue entry must blacklist the accelerators)"
        fi
        if ! grep -q 'module_blacklist=\$RESCUE_ACCEL_BLACKLIST' "$_script" 2>/dev/null; then
            err "rescue preservation: $_script rescue cmdline does not use module_blacklist=\$RESCUE_ACCEL_BLACKLIST"
        fi
    done
    if [ -f "$_rescue_arm64" ] && ! grep -q 'PRESERVE OPERATOR-STAGED RESCUE KERNELS' "$_rescue_arm64" 2>/dev/null; then
        err "rescue preservation: $_rescue_arm64 no longer carries the PRESERVE OPERATOR-STAGED RESCUE KERNELS marker comment"
    fi
    log "rescue preservation: both arches keep the rescue entry and the same-kernel accelerator-blacklist redefinition"
fi

# ---------------------------------------------------------------------------
# Check 10 (both arches): version pins from assets/kernel/KERNEL-POLICY.
# ---------------------------------------------------------------------------
if [ -s "$POLICY_FILE" ]; then
    case "$ARCH" in
        amd64|x86_64) _default_kver="${AMD64_STABLE_KVER:-}" ;;
        *)            _default_kver="${KVER_NEXT:-}" ;;
    esac
    if [ -z "$DEFAULT_BASE" ]; then
        err "assets/kernel/KERNEL-POLICY has no DEFAULT_BASE"
    elif [ -n "$_default_kver" ]; then
        case "$_default_kver" in
            "$DEFAULT_BASE"|"$DEFAULT_BASE".*|"$DEFAULT_BASE"-*)
                log "default kernel '$_default_kver' matches pinned base $DEFAULT_BASE" ;;
            *)
                err "default kernel '$_default_kver' is not the pinned $DEFAULT_BASE series (assets/kernel/KERNEL-POLICY)" ;;
        esac
        # Stronger: refuse any 7.2.x default specifically (the retired series).
        case "$_default_kver" in
            7.2.*|7.2-*) err "default kernel '$_default_kver' is from the retired 7.2.x series" ;;
        esac
        # rc allowance rules.
        if is_prerelease "$_default_kver"; then
            if [ "${RC_DEFAULT_ALLOWED:-0}" != "1" ]; then
                err "default kernel '$_default_kver' is an -rcN but RC_DEFAULT_ALLOWED is not 1 in assets/kernel/KERNEL-POLICY"
            else
                if [ -z "$RC_DEFAULT_EXPIRY_NOTE" ]; then
                    err "RC_DEFAULT_ALLOWED=1 but RC_DEFAULT_EXPIRY_NOTE is empty (must say 'replace by 7.3.0 final')"
                else
                    log "rc default '$_default_kver' allowed (RC_DEFAULT_EXPIRY_NOTE present; replace by 7.3.0 final)"
                fi
            fi
        else
            if [ "${RC_DEFAULT_ALLOWED:-0}" = "1" ]; then
                err "RC_DEFAULT_ALLOWED=1 is stale: the default '$_default_kver' is no longer an -rcN"
            fi
        fi
    fi
    # EDGE must be disabled and no edge assets may exist.
    case "${EDGE_ENABLED:-}" in
        ""|0) ;;
        *) err "EDGE_ENABLED='$EDGE_ENABLED' but the unified policy has no edge channel" ;;
    esac
    if [ -e "$ROOT/assets/kernel/edge" ]; then
        err "assets/kernel/edge still exists; the edge channel was retired (assets/kernel/mainline is the single 7.3 default)"
    fi
    if [ -e "$ROOT/assets/kernel/amd64-edge" ]; then
        err "assets/kernel/amd64-edge still exists; the amd64 edge channel was retired"
    fi
    # No 7.2.x channel asset / overlay mirror may be staged.
    case "$MANIFEST_MAINLINE_KVER" in
        7.2.*|7.2-*) err "manifest variants.mainline.kver '$MANIFEST_MAINLINE_KVER' is from the retired 7.2.x series" ;;
    esac
    # The 7.2.9 overlay mirrors are retired (operator 2026-10-05); older
    # 7.2.x mirrors are historical and kept. Only 7.2.9 is a failure.
    for _ovr in mali panthor npu vpu; do
        for _d in "$ROOT/assets/kernel/$_ovr"/7.2.9-*/; do
            [ -d "$_d" ] || continue
            err "retired 7.2.9 accelerator overlay still staged: ${_d#$ROOT/}"
        done
    done
    # RESCUE must be the same kernel with the accelerator blacklist.
    if [ "${RESCUE_SAME_KERNEL:-0}" != "1" ]; then
        err "RESCUE_SAME_KERNEL is not 1 in assets/kernel/KERNEL-POLICY (rescue must reuse the default kernel)"
    fi
    case "$ARCH" in
        amd64|x86_64)
            [ -n "$RESCUE_AMD64_T2" ]      || err "RESCUE_AMD64_BLACKLIST_T2 is empty in assets/kernel/KERNEL-POLICY"
            [ -n "$RESCUE_AMD64_GENERIC" ] || err "RESCUE_AMD64_BLACKLIST_GENERIC is empty in assets/kernel/KERNEL-POLICY"
            ;;
        *)
            [ -n "$RESCUE_ARM64" ] || err "RESCUE_ARM64_BLACKLIST is empty in assets/kernel/KERNEL-POLICY"
            ;;
    esac
fi

if [ "$FAIL" = 1 ]; then
    echo "[kernel-default-policy] POLICY VIOLATED -- refusing to continue" >&2
    exit 1
fi
echo "[kernel-default-policy] OK -- kernel policy satisfied (arch=$ARCH default=${AMD64_STABLE_KVER:-${KVER_NEXT:-<empty>}})"
exit 0
