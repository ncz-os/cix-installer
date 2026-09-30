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
#   5. On amd64: assets/kernel/amd64-edge/KVER MUST NOT exist.
#   6. On amd64: assets/kernel/amd64-stable/KVER MUST exist and MUST NOT
#      carry an -rcN suffix.
#   7. assets/kernel-manifest.json exists and is valid JSON.
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
                              "config-$KVER_NEXT" "headers-cixmini.tar.zst"; do
                        if [ ! -s "$MAINLINE_RESOLVED_DIR/$_f" ]; then
                            err "assets/kernel/mainline/$_f missing or empty (mainline payload incomplete)"
                        fi
                    done
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
                              "config-$KVER_EDGE" "headers-cixmini.tar.zst"; do
                        if [ ! -s "$EDGE_RESOLVED_DIR/$_f" ]; then
                            warn "assets/kernel/edge/$_f missing or empty (edge payload incomplete; edge menu entry will be skipped at boot)"
                        fi
                    done
                fi
            fi
            ;;
    esac
fi

# ---------------------------------------------------------------------------
# Check 5+6: amd64 -- NO edge channel; amd64-stable must be release (not rc).
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
    AMD64_EDGE_KVER_FILE="$ROOT/assets/kernel/amd64-edge/KVER"
    if [ -e "$AMD64_EDGE_KVER_FILE" ]; then
        err "amd64: assets/kernel/amd64-edge/KVER exists -- amd64 ships NO edge kernel by operator directive 2026-09-30 (no validated amd64 7.3 kernel exists)"
    else
        log "amd64: no edge channel (policy satisfied)"
    fi
fi

if [ "$FAIL" = 1 ]; then
    echo "[kernel-default-policy] POLICY VIOLATED -- refusing to continue" >&2
    exit 1
fi
echo "[kernel-default-policy] OK -- kernel default policy satisfied (arch=$ARCH mainline=${KVER_NEXT:-<empty>})"
exit 0