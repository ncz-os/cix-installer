#!/bin/bash
# verify-kernel-default-policy.sh -- enforce the NCZ-OS kernel default policy
# at build time, BEFORE staging anything that becomes the default boot kernel.
#
# Policy (operator 2026-09-30, .66 incident: Sky1 booted 7.3.0-rc5 by default):
#   - Default kernel = 7.2.8 (or 7.2.x-sky1-ncz, 7.2.x-t2-trixie) on EVERY
#     architecture. This is what userspace and every DKMS overlay is
#     validated against.
#   - On Sky1/arm64 ONLY, an additional bootable NON-default 'edge' entry
#     for 7.3.0-rc5 is allowed -- it is a separate menu entry, NEVER the
#     default, NEVER installed as the only kernel.
#   - On amd64, NO 7.3-rc5 line is shipped at all -- no edge kernel .debs,
#     no edge menu entry, no edge KVER sidecar. The decision to ship only
#     7.2.8 on amd64 is by lack of a validated amd64 7.3 kernel, not by
#     preference.
#   - The rescue boot entry is preserved on both arches.
#
# Why this exists (real, live-defect, 2026-09-29 image:
# ncz-os-arm64-20260929-4bd67b5f.img):
#   - The shipped arm64 image's payload KVER_NEXT sidecar resolved to
#     7.3.0-rc5-sky1-ncz, NOT 7.2.8-sky1-ncz as the symlink
#     assets/kernel/mainline nominally pointed at.
#   - The build scripts read KVER_NEXT from
#     $ROOT/assets/kernel/mainline/KVER, which is a SYMLINK into the shared
#     kernel-staging pool (/mnt/argonas-yocto-shared/kernel-staging/...).
#     Whoever ran the build on `fedora` retargeted the symlink to a
#     7.3-rc5 tree without reverting it; the resulting image baked
#     7.3-rc5 as KVER_NEXT and installed it as the default kernel on .66.
#   - The build-kernel-debs.sh and the apt pin check would have caught
#     drift BETWEEN the .deb set and the symlink target, but they ran
#     AFTER the symlink was already misdirected; both checks used the
#     same wrong source of truth and agreed with each other.
#
# What this verifier checks (each is independent, any failure exits 1):
#   1. assets/kernel/mainline/KVER exists AND does NOT carry an -rcN
#      suffix. The mainline channel is the default kernel; an -rc
#      version there means the build is shipping a release-candidate as
#      default.
#   2. assets/kernel/mainline/KVER matches the kver declared in
#      assets/kernel-manifest.json (variants.mainline.kver). Mismatch =
#      manifest drift.
#   3. assets/kernel/mainline/ has all required files: KVER, Image-
#      cixmini.bin, modules-cixmini.tgz, config-<KVER>, headers-cixmini.
#      tar.zst.
#   4. On arm64: if assets/kernel/edge/KVER exists, it MUST be different
#      from the mainline KVER, AND it MUST carry an -rcN suffix.
#   5. On amd64: assets/kernel/amd64-edge/KVER MAY exist (operator
#      directive 2026-10-05 supersedes the 2026-09-30 ban: the validated
#      amd64 7.3 edge kernel is the AER ANFE revert build). If it does
#      exist, it MUST carry an -rcN suffix and MUST match the pinned
#      EDGE_BASE (check 10). Any other -rc edge is refused.
#   6. On amd64: assets/kernel/amd64-stable/KVER MUST exist and MUST NOT
#      carry an -rcN suffix.
#   7. assets/kernel-manifest.json exists and is valid JSON.
#   8. (amd64) The runtime rEFInd refresh pipeline (classifier hook
#      assets/refind/zz1-ncz-refind-refresh-amd64 AND refresh script
#      assets/refind/ncz-refind-refresh-amd64.sh) only surfaces the
#      pinned 7.3.0-rc6 revert edge as EDGE and refuses every other -rc
#      kernel. This is the runtime analogue of checks 5 and 10 -- a
#      stray non-pinned kernel installed on the box cannot become a boot
#      entry.
#   9. (both arches) The rEFInd refresh scripts preserve the rescue
#      entry (the *-rescue sparing logic and the auto-promote-outgoing
#      logic). The operator directive says "keep the rescue entry"; a
#      future refactor that drops either piece silently removes the
#      safety net, and a verifier running on the build host can catch
#      that statically by requiring the rescue-promotion markers to
#      still be present in both scripts.
#  10. (both arches) If assets/kernel/KERNEL-POLICY exists: the default kernel
#      must be the pinned STABLE_BASE (7.2.9) and a staged edge kernel
#      (arm64 edge, or the amd64 edge revert build) must be the pinned
#      EDGE_BASE (7.3.0-rc6). See
#      docs/reports/2026-10-05-kernel-channel-policy.md.
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

# find_local_sibling: scan $ROOT/assets/kernel/r*/ (and adjacent top-level
# dirs that look like kernel trees) for one whose KVER file matches
# <wanted-kver>. Echoes the resolved directory path on success, or empty on
# no match. Used as a fallback when the committed symlink at
# assets/kernel/mainline (or edge) is dangling because the kernel-staging
# pool (/mnt/argonas-yocto-shared) is not mounted on this build host.
# The staging pool is the canonical source on the build farm; this fallback
# exists only to keep the verifier runnable on dev hosts that have the
# kernel tree vendored in-tree (assets/kernel/r277-... etc.) but no NFS
# share mounted. The verifier always logs a WARN when the fallback fires.
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

# ---------------------------------------------------------------------------
# Check 7: manifest is valid JSON.
# The manifest is Sky1-only (build/kernel-manifest.py only emits the
# variants.mainline entry), but its existence is required even on amd64
# because every other release-pipeline tool (kernel-port-watch.sh,
# kernel-manifest.py check in CI, etc.) reads it. A missing manifest
# means a regression in repo plumbing that should fail the build.
# ---------------------------------------------------------------------------
MANIFEST="$ROOT/assets/kernel-manifest.json"
if [ ! -s "$MANIFEST" ]; then
    err "manifest missing or empty: $MANIFEST (run build/kernel-manifest.py gen)"
    # Without the manifest we cannot run check 2 meaningfully. Exit early.
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
# Check 1+2+3: assets/kernel/mainline/KVER exists, no -rc suffix, full
# payload present, manifest cross-check.
# Applies to arm64 ONLY (amd64 uses assets/kernel/amd64-stable and has no
# mainline/ directory). The manifest cross-check ALWAYS uses the manifest's
# variants.mainline.kver regardless of arch -- the manifest is the contract
# for the SHIPPING kernel that becomes the default.
# ---------------------------------------------------------------------------
MAINLINE_RESOLVED_DIR=$(resolve_kver_file "$ROOT/assets/kernel/mainline" 2>/dev/null) || true
KVER_NEXT=""
if [ "$ARCH" = arm64 ] || [ "$ARCH" = aarch64 ]; then
    # If the committed mainline symlink is dangling (the kernel-staging pool
    # at /mnt/argonas-yocto-shared is not mounted on this build host), look
    # for a sibling tree vendored in assets/kernel/ whose KVER matches the
    # manifest's variants.mainline.kver. This is a dev-host convenience: the
    # build farm always has the pool mounted and uses the symlinked path.
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
                err "assets/kernel/mainline is a symlink to '$_t' that does not resolve to an existing directory on this build host. Mount the kernel-staging pool or repoint the symlink to a 7.2.x-sky1-ncz release tree (operator directive 2026-09-30: mainline MUST be a release version, NOT -rcN)."
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
                    if is_prerelease "$KVER_NEXT"; then
                        err "mainline KVER '$KVER_NEXT' is a release-candidate (contains -rcN); mainline is the DEFAULT kernel and must be a release version (operator directive 2026-09-30)"
                    else
                        log "mainline KVER '$KVER_NEXT' (release)"
                    fi
                    # Check 3: required files present.
                    for _f in "Image-cixmini.bin" "modules-cixmini.tgz" \
                              "config-$KVER_NEXT"; do
                        if [ ! -s "$MAINLINE_RESOLVED_DIR/$_f" ]; then
                            err "assets/kernel/mainline/$_f missing or empty (mainline payload incomplete)"
                        fi
                    done
                    # Headers: accept either the legacy generic filename
                    # (headers-cixmini.tar.zst) or the per-KVER filename
                    # (headers-<kver>.tar.zst) that newer trees use.
                    if [ ! -s "$MAINLINE_RESOLVED_DIR/headers-cixmini.tar.zst" ] \
                       && [ ! -s "$MAINLINE_RESOLVED_DIR/headers-$KVER_NEXT.tar.zst" ]; then
                        err "assets/kernel/mainline/headers-* missing or empty (mainline payload incomplete)"
                    fi
                fi
            fi
            ;;
    esac
fi
# Check 2: manifest cross-check.
# - On arm64: KVER_NEXT (from assets/kernel/mainline/KVER) MUST equal the
#   manifest's variants.mainline.kver. The manifest is the contract for
#   the Sky1 shipping kernel.
# - On amd64: the manifest does NOT cover the amd64-stable channel
#   (build/kernel-manifest.py only emits the Sky1 mainline variant), so
#   no cross-check against assets/kernel/amd64-stable/KVER is performed
#   here -- the amd64-stable path is enforced by the per-arch branch
#   below ("KVER must exist and must not carry -rcN").
case "$ARCH" in
    arm64|aarch64)
        if [ -n "$KVER_NEXT" ] && [ -n "$MANIFEST_MAINLINE_KVER" ] && [ "$KVER_NEXT" != "$MANIFEST_MAINLINE_KVER" ]; then
            err "mainline KVER '$KVER_NEXT' != manifest variants.mainline.kver '$MANIFEST_MAINLINE_KVER' (manifest drift)"
        elif [ -n "$KVER_NEXT" ] && [ -n "$MANIFEST_MAINLINE_KVER" ]; then
            log "mainline KVER matches manifest: $KVER_NEXT"
        fi
        ;;
    amd64|x86_64)
        # Manifest does not cover amd64-stable (Sky1-only contract); skip
        # the cross-check and rely on the per-arch branch below for the
        # presence + non-rc assertions on amd64-stable.
        ;;
esac

# ---------------------------------------------------------------------------
# Check 4: arm64 -- edge KVER (if any) must be DIFFERENT from mainline AND
# must carry an -rc suffix.
# ---------------------------------------------------------------------------
if [ "$ARCH" = arm64 ] || [ "$ARCH" = aarch64 ]; then
    EDGE_RESOLVED_DIR=$(resolve_kver_file "$ROOT/assets/kernel/edge" 2>/dev/null) || true
    KVER_EDGE=""
    # Same fallback as mainline: if the edge symlink is dangling AND we have
    # a local sibling tree, use it (with WARN). The edge kernel carries -rc,
    # so the fallback is keyed on "any sibling tree with -rc KVER".
    case "$EDGE_RESOLVED_DIR" in
        DANGLING_SYM:*)
            _t=${EDGE_RESOLVED_DIR#DANGLING_SYM:}
            for _dir in "$ROOT"/assets/kernel/r*/; do
                [ -d "$_dir" ] || continue
                [ -s "$_dir/KVER" ] || continue
                _kver=$(tr -d '[:space:]' < "$_dir/KVER")
                if is_prerelease "$_kver"; then
                    warn "assets/kernel/edge symlink -> '$_t' (unresolved) but local rc tree '$_dir' has KVER '$_kver'; using it as the edge channel (build farm uses the pool-mounted symlink)"
                    EDGE_RESOLVED_DIR=$(cd "$_dir" 2>/dev/null && pwd -P)
                    break
                fi
            done
            ;;
    esac
    case "$EDGE_RESOLVED_DIR" in
        DANGLING_SYM:*|MISSING_DIR|"")
            if [ -L "$ROOT/assets/kernel/edge" ]; then
                _t=$(readlink -f "$ROOT/assets/kernel/edge" 2>/dev/null || readlink "$ROOT/assets/kernel/edge")
                warn "assets/kernel/edge is a symlink to '$_t' that does not resolve on this build host; no edge channel staged (single-kernel release is permitted)"
            else
                log "no edge channel staged (single-kernel release; that is permitted)"
            fi
            ;;
        *)
            EDGE_KVER_FILE="$EDGE_RESOLVED_DIR/KVER"
            if [ ! -s "$EDGE_KVER_FILE" ]; then
                warn "assets/kernel/edge/KVER exists but is empty (edge channel incomplete; edge menu entry will be skipped)"
            else
                KVER_EDGE=$(tr -d '[:space:]' < "$EDGE_KVER_FILE")
                if [ -z "$KVER_EDGE" ]; then
                    warn "assets/kernel/edge/KVER is blank (edge channel incomplete; no edge menu entry)"
                else
                    if [ -n "$KVER_NEXT" ] && [ "$KVER_EDGE" = "$KVER_NEXT" ]; then
                        err "edge KVER '$KVER_EDGE' equals mainline KVER (a copy-paste symlink error; edge must be a DISTINCT experimental kernel)"
                    fi
                    if ! is_prerelease "$KVER_EDGE"; then
                        # Edge with a release suffix is allowed (an OLD mainline can be
                        # carried as edge) but warn -- operator policy is edge = rc.
                        warn "edge KVER '$KVER_EDGE' is a release version, not -rcN; edge is conventionally the rc channel"
                    else
                        log "edge KVER '$KVER_EDGE' (rc; non-default experimental entry)"
                    fi
                    for _f in "Image-cixmini.bin" "modules-cixmini.tgz" \
                              "config-$KVER_EDGE"; do
                        if [ ! -s "$EDGE_RESOLVED_DIR/$_f" ]; then
                            warn "assets/kernel/edge/$_f missing or empty (edge payload incomplete; edge menu entry will be skipped at boot)"
                        fi
                    done
                    # Headers: accept either the legacy generic filename
                    # (headers-cixmini.tar.zst) or the per-KVER filename
                    # (headers-<kver>.tar.zst) that newer trees use.
                    if [ ! -s "$EDGE_RESOLVED_DIR/headers-cixmini.tar.zst" ] \
                       && [ ! -s "$EDGE_RESOLVED_DIR/headers-$KVER_EDGE.tar.zst" ]; then
                        warn "assets/kernel/edge/headers-* missing or empty (edge payload incomplete; edge menu entry will be skipped at boot)"
                    fi
                fi
            fi
            ;;
    esac
fi

# ---------------------------------------------------------------------------
# Check 5+6+8: amd64 -- optional pinned edge channel (2026-10-05) and a
# mandatory release amd64-stable line; the rEFInd pipeline must pin edge.
# ---------------------------------------------------------------------------
if [ "$ARCH" = amd64 ] || [ "$ARCH" = x86_64 ]; then
    AMD64_STABLE_RESOLVED_DIR=$(resolve_kver_file "$ROOT/assets/kernel/amd64-stable" 2>/dev/null) || true
    case "$AMD64_STABLE_RESOLVED_DIR" in
        DANGLING_SYM:*)
            _t=$(readlink -f "$ROOT/assets/kernel/amd64-stable" 2>/dev/null || readlink "$ROOT/assets/kernel/amd64-stable")
            err "amd64: assets/kernel/amd64-stable is a symlink to '$_t' that does not resolve; the kernel-staging pool is not mounted on this build host"
            ;;
        MISSING_DIR|"")
            err "amd64: assets/kernel/amd64-stable is missing (amd64 must ship the 7.2.x stable line)"
            ;;
        *)
            AMD64_STABLE_KVER_FILE="$AMD64_STABLE_RESOLVED_DIR/KVER"
            if [ ! -s "$AMD64_STABLE_KVER_FILE" ]; then
                err "amd64: assets/kernel/amd64-stable/KVER is missing (amd64 must ship the 7.2.x stable line)"
            else
                AMD64_STABLE_KVER=$(tr -d '[:space:]' < "$AMD64_STABLE_KVER_FILE")
                if is_prerelease "$AMD64_STABLE_KVER"; then
                    err "amd64: stable KVER '$AMD64_STABLE_KVER' carries -rcN; amd64 must ship the release 7.2.x line only (operator directive 2026-09-30)"
                else
                    log "amd64: stable KVER '$AMD64_STABLE_KVER' (release)"
                fi
            fi
            ;;
    esac
    # Check 5 (amd64, operator directive 2026-10-05): an edge channel MAY
    # now be staged. If present it must be a release-candidate and must
    # match the pinned EDGE_BASE (enforced by check 10). A non-rc edge is
    # refused outright; an unpinned rc edge is refused by check 10.
    AMD64_EDGE_RESOLVED_DIR=$(resolve_kver_file "$ROOT/assets/kernel/amd64-edge" 2>/dev/null) || true
    AMD64_EDGE_KVER=""
    case "$AMD64_EDGE_RESOLVED_DIR" in
        DANGLING_SYM:*)
            _t=${AMD64_EDGE_RESOLVED_DIR#DANGLING_SYM:}
            err "amd64: assets/kernel/amd64-edge is a symlink to '$_t' that does not resolve on this build host"
            ;;
        MISSING_DIR|"")
            log "amd64: no edge channel staged (single-kernel release permitted)"
            ;;
        *)
            if [ ! -s "$AMD64_EDGE_RESOLVED_DIR/KVER" ]; then
                err "amd64: assets/kernel/amd64-edge/KVER is missing or empty (edge payload incomplete)"
            else
                AMD64_EDGE_KVER=$(tr -d '[:space:]' < "$AMD64_EDGE_RESOLVED_DIR/KVER")
                if [ -z "$AMD64_EDGE_KVER" ]; then
                    err "amd64: assets/kernel/amd64-edge/KVER is blank"
                elif ! is_prerelease "$AMD64_EDGE_KVER"; then
                    err "amd64: edge KVER '$AMD64_EDGE_KVER' is not a release-candidate (edge must be -rcN)"
                else
                    log "amd64: edge KVER '$AMD64_EDGE_KVER' (rc; non-default experimental entry)"
                    # amd64 edge is a SPECIFIC build, not just any rc base:
                    # the pinned 7.3.0-rc6 T2 AER-revert kernel. Derive the
                    # base from KERNEL-POLICY when present and require the
                    # t2-edge-aerfix discriminator, so an unpinned rc6
                    # variant (plain/rev/...) cannot be staged as edge.
                    _policy="$ROOT/assets/kernel/KERNEL-POLICY"
                    if [ -s "$_policy" ]; then
                        _ebase=$(sed -nE 's/^EDGE_BASE=([^[:space:]#]+).*/\1/p' "$_policy" | head -1)
                        if [ -n "$_ebase" ]; then
                            case "$AMD64_EDGE_KVER" in
                                "$_ebase"-[0-9]-t2-edge-aerfix|"$_ebase"-[0-9][0-9]-t2-edge-aerfix) log "amd64: edge KVER matches the pinned revert build ${_ebase}-<N>-t2-edge-aerfix" ;;
                                *) err "amd64: edge KVER '$AMD64_EDGE_KVER' is not the pinned ${_ebase}-<N>-t2-edge-aerfix revert build (assets/kernel/KERNEL-POLICY, operator 2026-10-05)" ;;
                            esac
                        fi
                    fi
                fi
            fi
            ;;
    esac

    # Check 8 (amd64): the runtime rEFInd refresh pipeline must only
    # surface the pinned 7.3.0-rc6 revert edge as EDGE and must refuse
    # every other -rc kernel. This is the runtime analogue of checks 5
    # and 10 -- the build-time gate stages only the pinned edge, and the
    # runtime scripts (classifier hook + refresh) must refuse to surface
    # an unpinned rc even if a stray kernel is installed on the box. If
    # the pinned-edge marker is absent, the build fails closed here.
    _hook="$ROOT/assets/refind/zz1-ncz-refind-refresh-amd64"
    _refresh="$ROOT/assets/refind/ncz-refind-refresh-amd64.sh"
    if [ -f "$_hook" ]; then
        if grep -q 'amd64 edge channel is pinned to 7.3.0-rc6' "$_hook" 2>/dev/null; then
            log "amd64: classifier hook pins the edge channel to 7.3.0-rc6 (directive 2026-10-05)"
        else
            err "amd64: classifier hook does not contain the 'amd64 edge channel is pinned to 7.3.0-rc6' directive-2026-10-05 marker; the classifier could surface an unpinned -rc kernel as edge on a live amd64 box"
        fi
    fi
    if [ -f "$_refresh" ]; then
        if grep -q 'amd64 edge channel is pinned to 7.3.0-rc6' "$_refresh" 2>/dev/null; then
            log "amd64: rEFInd refresh accepts only the pinned 7.3.0-rc6 edge (directive 2026-10-05)"
        else
            err "amd64: rEFInd refresh $_refresh does not contain the 'amd64 edge channel is pinned to 7.3.0-rc6' directive-2026-10-05 marker; an unpinned edge menu entry could be written even when KVER_EDGE is passed in"
        fi
    fi
fi

# Check 10 (both arches): version pins from assets/kernel/KERNEL-POLICY
# (operator 2026-10-05: stable 7.2.9, edge 7.3.0-rc6). Optional file: absent means
# no pin is enforced, so older trees and fixtures behave as before.
POLICY_FILE="$ROOT/assets/kernel/KERNEL-POLICY"
if [ -s "$POLICY_FILE" ]; then
    STABLE_BASE=$(sed -nE 's/^STABLE_BASE=([^[:space:]#]+).*/\1/p' "$POLICY_FILE" | head -1)
    EDGE_BASE=$(sed -nE 's/^EDGE_BASE=([^[:space:]#]+).*/\1/p' "$POLICY_FILE" | head -1)
    case "$ARCH" in
        amd64|x86_64) _default_kver="${AMD64_STABLE_KVER:-}"; _edge_kver="${AMD64_EDGE_KVER:-}" ;;
        *)            _default_kver="${KVER_NEXT:-}";         _edge_kver="${KVER_EDGE:-}" ;;
    esac
    if [ -n "$STABLE_BASE" ] && [ -n "$_default_kver" ]; then
        case "$_default_kver" in
            "$STABLE_BASE"|"$STABLE_BASE"[-+]*) log "default kernel '$_default_kver' matches pinned stable $STABLE_BASE" ;;
            *) err "default kernel '$_default_kver' is not the pinned stable $STABLE_BASE (assets/kernel/KERNEL-POLICY, operator 2026-10-05)" ;;
        esac
    fi
    if [ -n "$EDGE_BASE" ] && [ -n "$_edge_kver" ]; then
        case "$_edge_kver" in
            "$EDGE_BASE"|"$EDGE_BASE"[-+]*) log "edge kernel '$_edge_kver' matches pinned edge $EDGE_BASE" ;;
            *) err "edge kernel '$_edge_kver' is not the pinned edge $EDGE_BASE (assets/kernel/KERNEL-POLICY, operator 2026-10-05)" ;;
        esac
    fi
fi

# Check 9 (both arches): the rEFInd refresh scripts preserve the rescue
# entry. Operator directive 2026-09-30: keep the rescue entry on both
# arches. The rescue mechanism has two parts -- a *-rescue sparing rule
# in the ESP-wipe loop, and an auto-promote-outgoing rule that copies
# the outgoing kernel's vmlinuz/initrd to <RESC>-file names. Both
# scripts carry matching markers (the unique phrase "PRESERVE OPERATOR-
# STAGED RESCUE KERNELS" in the arm64 file and "RESCUE menu entry" +
# "-rescue" promotion in both); require them to still be present.
#
# This check runs only against the real repo (the path the verifier is
# pointed at with --root). Fixture tests build a synthetic asset tree
# without these scripts on purpose; fixture tests skip this check via
# the SKIP_RESCUE_CHECK marker so the rescue logic is exercised only
# against the actual repo, not every synthesized root.
if [ -z "${SKIP_RESCUE_CHECK:-}" ]; then
    _rescue_arm64="$ROOT/assets/refind/ncz-refind-refresh.sh"
    _rescue_amd64="$ROOT/assets/refind/ncz-refind-refresh-amd64.sh"
    for _script in "$_rescue_arm64" "$_rescue_amd64"; do
        if [ ! -f "$_script" ]; then
            err "rescue entry preservation: $_script missing -- the rEFInd menu cannot preserve the rescue kernel"
            continue
        fi
        if ! grep -q '\*-rescue' "$_script" 2>/dev/null; then
            err "rescue entry preservation: $_script no longer contains the *-rescue sparing/promotion logic; the rescue menu entry would be wiped (operator directive 2026-09-30)"
        fi
    done
    # The arm64 script additionally carries the "PRESERVE OPERATOR-STAGED
    # RESCUE KERNELS" header comment that documents the rescue-promotion
    # contract; require that too.
    if [ -f "$_rescue_arm64" ] && ! grep -q 'PRESERVE OPERATOR-STAGED RESCUE KERNELS' "$_rescue_arm64" 2>/dev/null; then
        err "rescue entry preservation: $_rescue_arm64 no longer carries the PRESERVE OPERATOR-STAGED RESCUE KERNELS marker comment; the rescue-promotion contract was deleted"
    fi
    log "rescue entry preservation: both arches carry the *-rescue sparing/promotion logic (directive 2026-09-30)"
fi

if [ "$FAIL" = 1 ]; then
    echo "[kernel-default-policy] POLICY VIOLATED -- refusing to continue" >&2
    exit 1
fi
echo "[kernel-default-policy] OK -- kernel default policy satisfied (arch=$ARCH mainline=${KVER_NEXT:-<empty>})"
exit 0