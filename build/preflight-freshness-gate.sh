#!/bin/bash
# preflight-freshness-gate.sh — refuse to start an ISO build against a stale
# checkout, a stale kernel-staging pool, or a downstream patch that no longer
# applies (already merged upstream, or conflicts with a newer upstream tree).
#
# WHY THIS EXISTS (2026-09-20/21). In one session:
#   - An ISO build ran from cix-installer commit 68eb4cb while the real branch
#     tip was already 7 commits ahead (3d47ca2..9af205b) — real GPU/WiFi/crash
#     fixes silently absent from the resulting ISO, with nothing catching it.
#   - A kernel fix (7.2.6-2, the Navi14 UCLK-defer patch) was built and
#     KVM-gated on one host, but a DIFFERENT host's ISO build read the shared
#     kernel-staging pool BEFORE that kernel was promoted there, and silently
#     shipped the older 7.2.6-1 kernel instead — again nothing caught it.
#   - A standalone singularity-desktop rebuild was dispatched in parallel with
#     a full ISO build that would have produced its own (potentially
#     different) singularity-desktop payload from the same patch set — wasted
#     build cycles and a real risk of the two drifting apart.
#
# Every one of these was "we forgot to check," exactly the class of mistake
# this project's other gates (dkms-abi-gate.sh, kvm-kernel-gate.sh) exist to
# turn into a mechanical, unskippable check instead of a remembered step.
#
# WHAT THIS CHECKS, and WHY each one is a real build-breaking condition if
# skipped (not just cosmetic):
#
#   1. cix-installer checkout is not behind its own remote tracking branch.
#      A build from a stale checkout silently omits every commit landed
#      since the checkout was last updated -- exactly the 68eb4cb incident.
#
#   2. Every downstream patch in assets/singularity/patches/<subproject>/
#      still applies cleanly against that subproject's REAL current
#      upstream default branch. A patch that no longer applies is either
#      (a) already merged upstream -- harmless but the entry is now
#      misleading and should be deleted per that directory's own README
#      convention -- or (b) genuinely broken by upstream drift, which is
#      NOT harmless: build-singularity.sh treats a failed patch apply as a
#      hard build failure, so this check exists to catch that BEFORE a long
#      build fails partway through, not after.
#
#   3. The kernel-staging pool's newest dated directory for each line
#      (amd64-stable, amd64-edge) is genuinely newer than or equal to
#      whatever this checkout's own kernel-line pointer resolves to. This
#      does not replace stage-amd64-kernel.sh; it exists to catch the
#      window where a fresher kernel was JUST promoted to the shared pool
#      but a concurrently-running or freshly-started build hasn't picked
#      it up, so the operator gets an explicit answer instead of silently
#      shipping the older kernel.
#
# Exit 0 = clean, safe to build. Exit 1 = a real problem was found and
# printed; do not proceed with the build until it's resolved or explicitly
# acknowledged.
#
# Usage: build/preflight-freshness-gate.sh [--kernel-staging-dir DIR]
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

KERNEL_STAGING_DIR="/mnt/argonas/datapool/yocto-shared/kernel-staging"
for candidate in /mnt/argonas-yocto-shared/kernel-staging /nfs-shared/kernel-staging; do
    [ -d "$candidate" ] && KERNEL_STAGING_DIR="$candidate"
done
while [ $# -gt 0 ]; do
    case "$1" in
        --kernel-staging-dir) KERNEL_STAGING_DIR="$2"; shift 2 ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

FAIL=0
WARN=0

echo "=== preflight-freshness-gate: $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
echo "repo: $REPO_ROOT"

# --- 1. Checkout freshness -------------------------------------------------
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
if [ -z "$BRANCH" ] || [ "$BRANCH" = HEAD ]; then
    echo "[1] WARN: detached HEAD or unknown branch -- cannot compare against a remote tracking branch"
    WARN=$((WARN + 1))
else
    # NEVER a bare, unbounded `git fetch` here. Confirmed live on HYDRA
    # 2026-09-21, TWICE, even after fixing client ~/.ssh/config fleet-wide
    # (IdentitiesOnly + MaxAuthTries): a plain fetch against the ARGONAS
    # origin can still hang indefinitely with no error, no timeout, no
    # diagnostic (stderr was even redirected to /dev/null) -- it silently
    # stalled an entire ISO build for 30+ minutes, twice, exactly the class
    # of problem this gate exists to prevent. `timeout` bounds the hang;
    # the sshpass password-auth wrapper is the same fleet-standard fallback
    # every other network call in this repo already uses (kernel-build-
    # checklist.md §0f) -- don't rely on client SSH config alone here.
    if timeout 20 env GIT_SSH_COMMAND='sshpass -p "changeme" ssh -o PubkeyAuthentication=no -o StrictHostKeyChecking=no -o ConnectTimeout=10' \
        git fetch origin "$BRANCH" --quiet 2>/dev/null; then
        LOCAL_SHA="$(git rev-parse HEAD)"
        REMOTE_SHA="$(git rev-parse "origin/$BRANCH" 2>/dev/null)"
        if [ -z "$REMOTE_SHA" ]; then
            echo "[1] WARN: no origin/$BRANCH tracking ref found after fetch -- cannot verify freshness"
            WARN=$((WARN + 1))
        elif [ "$LOCAL_SHA" = "$REMOTE_SHA" ]; then
            echo "[1] OK: checkout is at origin/$BRANCH tip ($LOCAL_SHA)"
        else
            BEHIND="$(git rev-list --count "$LOCAL_SHA..$REMOTE_SHA" 2>/dev/null)"
            if [ "${BEHIND:-0}" -gt 0 ]; then
                echo "[1] FAIL: checkout is $BEHIND commit(s) behind origin/$BRANCH"
                echo "          local:  $LOCAL_SHA"
                echo "          remote: $REMOTE_SHA"
                echo "          git pull (or fetch+rebase) before building."
                FAIL=$((FAIL + 1))
            else
                echo "[1] OK: checkout is ahead of or diverged from origin/$BRANCH in a way that isn't 'stale' (local has unpushed work) -- not a freshness failure"
            fi
        fi
    else
        echo "[1] WARN: git fetch origin/$BRANCH failed (no network, or pubkey exhaustion -- see kernel-build-checklist.md §0f) -- cannot verify freshness"
        WARN=$((WARN + 1))
    fi
fi

# --- 2. Downstream singularity patches still apply -------------------------
PATCH_ROOT="assets/singularity/patches"
if [ -d "$PATCH_ROOT" ]; then
    for sub_dir in "$PATCH_ROOT"/*/; do
        [ -d "$sub_dir" ] || continue
        sub_name="$(basename "$sub_dir")"
        patches=("$sub_dir"*.patch)
        [ -e "${patches[0]}" ] || continue

        case "$sub_name" in
            singularity-shell) upstream_url="https://github.com/singularityos-lab/singularity-shell.git" ;;
            singularity-desktop) upstream_url="https://github.com/singularityos-lab/singularity-desktop.git" ;;
            singularity-plugins) upstream_url="https://github.com/singularityos-lab/singularity-plugins.git" ;;
            libsingularity) upstream_url="https://github.com/singularityos-lab/libsingularity.git" ;;
            labwc) upstream_url="https://github.com/singularityos-lab/labwc.git" ;;
            *)
                echo "[2] WARN: no known upstream URL for patch subproject '$sub_name' -- skipping its patch(es), add a case here if this is real"
                WARN=$((WARN + 1))
                continue
                ;;
        esac

        tmp_clone="$(mktemp -d)"
        trap 'rm -rf "$tmp_clone"' RETURN
        if ! timeout 30 git clone --quiet --depth 50 "$upstream_url" "$tmp_clone" 2>/dev/null; then
            echo "[2] WARN: could not clone $upstream_url to verify $sub_name patches -- no network, or a transient failure"
            WARN=$((WARN + 1))
            rm -rf "$tmp_clone"
            continue
        fi

        # Apply for real (not --check) IN SEQUENCE, since later patches in a
        # subproject commonly depend on earlier ones' changes already being
        # present -- a dry-run --check against the unmodified base would
        # falsely report every non-first patch as failing.
        for p in "${patches[@]}"; do
            if git -C "$tmp_clone" apply "$REPO_ROOT/$p" 2>/dev/null; then
                echo "[2] OK: $sub_name/$(basename "$p") applies cleanly against real current upstream default branch"
            else
                echo "[2] FAIL: $sub_name/$(basename "$p") does NOT apply against real current upstream default branch"
                echo "          Either it already merged (check the upstream PR; if merged, delete this"
                echo "          patch file and its README entry per assets/singularity/patches/README.md's"
                echo "          own convention) or upstream drifted and this patch needs a real rebase."
                FAIL=$((FAIL + 1))
            fi
        done
        rm -rf "$tmp_clone"
        trap - RETURN
    done
else
    echo "[2] OK: no $PATCH_ROOT directory -- nothing to verify"
fi

# --- 3. Kernel-staging pool freshness ---------------------------------------
if [ -d "$KERNEL_STAGING_DIR" ]; then
    for line in amd64-stable amd64-edge; do
        # Directory names are NOT lexically ordered by recency (e.g. an
        # "...-rc4-3-t2-xhcifix-DATE" variant sorts before a same-date
        # "...-rc4-t2-trixie-DATE" one because '3' < 't' lexically, even
        # though the xhcifix one was staged later) -- match
        # stage-amd64-kernel.sh's own selection (ls -dt, real mtime) or this
        # check disagrees with what actually got staged. Found + fixed
        # 2026-09-23 after it produced a false FAIL against a genuinely
        # fresher local stage.
        newest="$(find "$KERNEL_STAGING_DIR" -maxdepth 1 -type d -name "${line}-*" -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-)"
        if [ -z "$newest" ]; then
            echo "[3] WARN: no staged kernel found for line '$line' under $KERNEL_STAGING_DIR"
            WARN=$((WARN + 1))
            continue
        fi
        newest_name="$(basename "$newest")"
        local_kver_dir="assets/kernel/$line"
        if [ -d "$local_kver_dir" ]; then
            # build/post-install/10-amd64-kernel.sh actually CONSUMES the
            # highest-version file via `sort -V | tail -1`, so an older file
            # sitting alongside a freshly-staged newer one (stage-amd64-
            # kernel.sh never deletes the old version) is harmless to the
            # real build -- checking only the FIRST `find` result (unsorted,
            # arbitrary order) produced a false FAIL here 2026-09-21 even
            # though the newest kernel was already staged correctly. Check
            # whether the staged newest's checksum exists ANYWHERE locally,
            # matching what the build will actually pick.
            staged_deb="$(find "$newest" -maxdepth 1 -iname 'linux-image-*.deb' 2>/dev/null | head -1)"
            local_debs=("$local_kver_dir"/linux-image-*.deb)
            if [ -n "$staged_deb" ] && [ -e "${local_debs[0]}" ]; then
                staged_sum="$(sha256sum "$staged_deb" 2>/dev/null | cut -d' ' -f1)"
                match=0
                for local_deb in "${local_debs[@]}"; do
                    local_sum="$(sha256sum "$local_deb" 2>/dev/null | cut -d' ' -f1)"
                    if [ "$local_sum" = "$staged_sum" ]; then
                        match=1
                        break
                    fi
                done
                if [ "$match" -eq 1 ]; then
                    echo "[3] OK: $line -- locally staged kernel matches the newest in the shared pool ($newest_name)"
                else
                    echo "[3] FAIL: $line -- locally staged kernel does NOT match the newest in the shared pool"
                    echo "          shared pool has: $newest_name"
                    echo "          local has:       $(basename -a "${local_debs[@]}" | paste -sd, -)"
                    echo "          run build/stage-amd64-kernel.sh $line (or the Sky1 equivalent) before building."
                    FAIL=$((FAIL + 1))
                fi
            else
                echo "[3] WARN: $line -- could not find a linux-image-*.deb locally or in $newest to compare"
                WARN=$((WARN + 1))
            fi
        else
            echo "[3] WARN: no local $local_kver_dir to compare against shared pool's $newest_name"
            WARN=$((WARN + 1))
        fi
    done
else
    echo "[3] WARN: kernel-staging dir not found/mounted ($KERNEL_STAGING_DIR) -- cannot verify kernel freshness on this host"
    WARN=$((WARN + 1))
fi

# --- 4. Debian base-mirror snapshot pin staleness ---------------------------
# WARN only, never FAIL: an old pin doesn't make a build wrong (it's still
# fully reproducible against that snapshot), it just means the shipped
# package set is behind what a deliberate `build/pin-forky-snapshot.sh` bump
# would pick up. forky moves fast enough that this is worth surfacing.
if [ -f "$REPO_ROOT/release.conf" ] && grep -q '^NCZ_BASE_MIRROR_SNAPSHOT=' "$REPO_ROOT/release.conf"; then
    if ! bash "$REPO_ROOT/build/pin-forky-snapshot.sh" --check 2>&1 | sed 's/^/[4] /'; then
        echo "[4] WARN: base-mirror snapshot pin is stale -- run build/pin-forky-snapshot.sh to bump it"
        WARN=$((WARN + 1))
    fi
else
    echo "[4] OK: base mirror is not pinned (live deb.debian.org) -- nothing to check"
fi

echo "=== preflight-freshness-gate: $FAIL failure(s), $WARN warning(s) ==="
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
