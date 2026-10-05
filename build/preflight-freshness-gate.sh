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
#      (amd64-stable, amd64-edge, and the single arm64/Sky1 line under the
#      r<N>-*-sky1-ncz-* namespace) is genuinely newer than or equal to
#      whatever this checkout's own kernel-line pointer resolves to. Operator
#      directive 2026-10-05 reinstated amd64-edge as the pinned 7.3.0-rc6
#      AER-revert kernel; the edge line is matched to the committed
#      assets/kernel/amd64-edge/KVER pin. This does not replace
#      stage-amd64-kernel.sh (or stage-kernel.sh); it
#      exists to catch the window where a fresher kernel was JUST promoted
#      to the shared pool but a concurrently-running or freshly-started
#      build hasn't picked it up, so the operator gets an explicit answer
#      instead of silently shipping the older kernel. Measured 2026-09-28
#      on ULTRA: an arm64 image shipped with the WRONG Sky1 kernel because
#      this check [3] had no arm64 arm -- a real rc5-vs-7.2.8 mismatch
#      went all the way through the install, post-install/10-our-kernel.sh
#      installed rc5, and the post-install then looked for /boot/vmlinuz-
#      7.2.8-sky1-ncz which had never been written. The amd64 side of the
#      same night caught its equivalent drift immediately via the gate.
#
# Exit 0 = clean, safe to build. Exit 1 = a real problem was found and
# printed; do not proceed with the build until it's resolved or explicitly
# acknowledged.
#
# Usage: build/preflight-freshness-gate.sh [--kernel-staging-dir DIR]
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

# Mount spelling DIFFERS PER HOST (ARGONAS kernel-staging export):
#   ULTRA:           /mnt/argonas-yocto-shared
#   TYDEUS:          /nfs-shared
#   PROTEUS/ARGOS/
#   HYDRA/ACHILLES/
#   CERBERUS:        /mnt/argonas/datapool/yocto-shared
# build/stage-amd64-kernel.sh already probes three of these; copy the
# pattern so a fresh build host never has to edit either script to find
# the same shared pool. The override flag still wins, by design.
KERNEL_STAGING_DIR=""
for candidate in /mnt/argonas/datapool/yocto-shared/kernel-staging \
                  /mnt/argonas-yocto-shared/kernel-staging \
                  /nfs-shared/kernel-staging; do
    [ -d "$candidate" ] && KERNEL_STAGING_DIR="$candidate" && break
done
KERNEL_STAGING_DIR="${KERNEL_STAGING_DIR:-/mnt/argonas/datapool/yocto-shared/kernel-staging}"
while [ $# -gt 0 ]; do
    case "$1" in
        --kernel-staging-dir) KERNEL_STAGING_DIR="$2"; shift 2 ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

# Same arch-detection pattern post-install/10-our-kernel.sh:51-57 and
# 10-amd64-kernel.sh:32-38 already use: env var first, then the
# late.sh-stamped BUILD_ARCH file, then dpkg as a last-resort fallback.
# This gate is at BUILD time, not install time, so BUILD_ARCH is normally
# absent -- but the pattern is the project's canonical one and using it
# here means an operator who sets NCZ_TARGET_ARCH in either phase gets
# the same answer.
NCZ_SYSTEM_ARCH="${NCZ_TARGET_ARCH:-}"
if [ -z "$NCZ_SYSTEM_ARCH" ] && [ -r "$REPO_ROOT/.cix/BUILD_ARCH" ]; then
    NCZ_SYSTEM_ARCH=$(tr -d '[:space:]' < "$REPO_ROOT/.cix/BUILD_ARCH")
fi
NCZ_SYSTEM_ARCH="${NCZ_SYSTEM_ARCH:-$(dpkg --print-architecture 2>/dev/null || true)}"

# Reuse assets/refind/zz1-ncz-refind-refresh-amd64's exact classifier:
# the only difference between a "stable" and a "prerelease" kernel here is
# the presence of -rc<digit> in its name (7.3.0-rc5 vs 7.2.8). Anything
# carrying -rc<N> is in the prerelease/edge class; everything else is
# stable. The amd64 rEFInd helper does this already; the same logic
# works for the single-namespace Sky1 pool (r272/r273/r274/r277/r278).
is_prerelease() {
    case "$1" in *-rc[0-9]*) return 0 ;; *) return 1 ;; esac
}

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
    if timeout 20 env GIT_SSH_COMMAND='sshpass -f "$HOME/.config/ncz/argonas.pass" ssh -o PubkeyAuthentication=no -o StrictHostKeyChecking=no -o ConnectTimeout=10' \
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
#
# Two parallel arms -- amd64 and arm64 (Sky1). Both consume the SAME
# shared ARGONAS pool, but their packaging and naming differ:
#
#   amd64 has TWO live namespaces (amd64-stable-* and amd64-edge-*); each
#   line's payload is a .deb pair (linux-image-*.deb + linux-headers-*.deb)
#   the installer dpkg-installs. Comparison: sha256 of the .deb in the pool
#   vs the .deb in assets/kernel/<line>/. Operator directive 2026-10-05
#   reinstated amd64-edge as the pinned 7.3.0-rc6 AER-revert kernel
#   (7.3.0-rc6-1-t2-edge-aerfix); the edge line is selected by the committed
#   assets/kernel/amd64-edge/KVER pin rather than by mtime, so a stale rc5
#   build in the pool cannot masquerade as the shipping edge. The
#   amd64-t2-* trees are multi-variant experiment/build trees (never staged
#   wholesale); only the pinned member is consumed.
#
#   arm64 (Sky1) has ONE namespace (r<N>-<kver>-sky1-ncz-<date>) with the
#   -rc marker splitting the same set into a stable class and a
#   prerelease class -- identical to how assets/refind/zz1-ncz-refind-
#   refresh-amd64 classifies amd64 kernels. Since 2026-09-29 there are
#   TWO local pointers, one per class, mirroring amd64's two lines:
#     assets/kernel/mainline -> <pool>/r<N>-7.2.x-...   (SHIPPING, stable)
#     assets/kernel/edge     -> <pool>/r<N>-7.3.0-rcN-... (TEST-ONLY, prerelease)
#   Each payload is Image-cixmini.bin + modules-cixmini.tgz + ... -- NOT a
#   .deb. Comparison: resolve the symlink, take its basename, require the
#   pointer's own class, and compare to the newest pool dir of that class
#   (by mtime).
#
# Pool-mount discovery and the -rc classifier are both duplicated by
# design from existing files (stage-amd64-kernel.sh and the rEFInd
# helper respectively) rather than imported -- a build-host that lacks
# the helper dir or has a renamed pool layout still gets a working gate.

# arm64 arm -- one call per local channel pointer. The class of the pin is
# part of the contract, not an observation:
#   assets/kernel/mainline  MUST be stable class (no -rc). It is the only
#                           kernel build-kernel-debs.sh packages and the
#                           vendor mirror publishes, so a prerelease here
#                           ships an rc. Required.
#   assets/kernel/edge      MUST be prerelease class (-rc). It is the
#                           test-only 7.3.x line (non-default boot entry).
#                           Optional: absent is a WARN.
# FAIL when the pointer is missing (required), not a symlink, dangling,
# outside the pool, the WRONG class (the 2026-09-28 incident: the single
# shipping pointer was repointed at r278 rc5, and a 7.2.8 kernel then sat
# under "edge"), or not the newest build of its class.
check_arm64_channel() {
    local local_pointer="$1" want_class="$2" required="$3"
    local label
    label="$(basename "$local_pointer")"
    if [ ! -L "$local_pointer" ] && [ ! -e "$local_pointer" ]; then
        if [ "$required" = required ]; then
            echo "[3] FAIL: arm64 $label -- $local_pointer is missing (the $label line is required)"
            FAIL=$((FAIL + 1))
        else
            echo "[3] WARN: arm64 $label -- $local_pointer is absent; no $label line will be staged"
            WARN=$((WARN + 1))
        fi
        return
    fi
    if [ ! -L "$local_pointer" ]; then
        echo "[3] FAIL: arm64 $label -- $local_pointer is not a symlink (Sky1 builds consume the pool via an absolute symlink)"
        FAIL=$((FAIL + 1))
        return
    fi
    local target
    target="$(readlink "$local_pointer")"
    if [ ! -e "$target" ]; then
        echo "[3] FAIL: arm64 $label -- $local_pointer is dangling (readlink -> $target)"
        echo "          the pool path this host sees is $(cd "$KERNEL_STAGING_DIR" 2>/dev/null && pwd || echo 'unknown')"
        echo "          but the symlink was made on a host where the pool mounts at a different path."
        echo "          repoint: ln -sfn \"$KERNEL_STAGING_DIR/<pool-dir>\" $local_pointer"
        FAIL=$((FAIL + 1))
        return
    fi
    # Resolve to absolute for the "points outside the pool" check -- a
    # relative symlink would silently misbehave against every consumer.
    local abs_target
    abs_target="$(cd "$(dirname "$target")" && pwd)/$(basename "$target")"
    case "$abs_target" in
        "$KERNEL_STAGING_DIR"/*) ;;
        *)
            echo "[3] FAIL: arm64 $label -- $local_pointer resolves to $abs_target"
            echo "          which is OUTSIDE the kernel-staging pool ($KERNEL_STAGING_DIR)."
            echo "          Nothing in the build reads from a path outside the pool."
            FAIL=$((FAIL + 1))
            return
            ;;
    esac
    local pin_name pin_class
    pin_name="$(basename "$abs_target")"
    if is_prerelease "$pin_name"; then pin_class="prerelease"; else pin_class="stable"; fi
    if [ "$pin_class" != "$want_class" ]; then
        echo "[3] FAIL: arm64 $label -- $local_pointer -> $pin_name is a $pin_class build;"
        echo "          the $label line only takes $want_class builds (mainline = 7.2.x release,"
        echo "          edge = 7.3.x -rc test kernel). Repoint the right channel instead."
        FAIL=$((FAIL + 1))
        return
    fi
    # Newest in the pointer's class, by mtime (lexical order is wrong for
    # the same reason the amd64 loop sorts by mtime -- see its inline
    # comment). %T@ gives fractional seconds (e.g. 1790570677.4776231330);
    # strip everything past the decimal so `-gt` can compare integers.
    local newest="" newest_mtime=-1
    local d name mt line
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        d="${line#* }"
        name="$(basename "$d")"
        mt="${line%% *}"
        mt="${mt%%.*}"
        if is_prerelease "$name"; then
            [ "$want_class" = prerelease ] || continue
        else
            [ "$want_class" = stable ] || continue
        fi
        [ "$mt" -gt "$newest_mtime" ] && { newest_mtime="$mt"; newest="$name"; }
    done <<EOF
$(find "$KERNEL_STAGING_DIR" -maxdepth 1 -type d -name 'r[0-9]*-*' -printf '%T@ %p\n' 2>/dev/null)
EOF
    if [ "$pin_name" = "$newest" ]; then
        echo "[3] OK: arm64 $label -- $local_pointer -> $pin_name (newest $want_class build)"
    else
        echo "[3] FAIL: arm64 $label -- $local_pointer -> $pin_name ($want_class class) but the pool's newest $want_class build is $newest"
        echo "          Newer builds of the SAME class exist; the operator's pin is stale."
        echo "          Repoint to $newest, or confirm the operator explicitly wants $pin_name."
        FAIL=$((FAIL + 1))
    fi
}

# amd64 arm -- one function per line, parameterised only by the line name
# so the loop body is in one place. The body is BYTE-FOR-BYTE the same as
# the original inline loop: same find, same mtime sort, same sha256
# comparison against assets/kernel/<line>/, same OK/FAIL/WARN output.
# This is the explicit posture the task brief asked for: refactor plus
# an arm64 arm, NOT a rewrite.
check_amd64_line() {
    local line="$1"
    local newest=""
    # The edge line is pinned, not newest-by-mtime: a stale amd64-edge-rc5
    # build lingering in the pool must not be selected over the committed
    # 7.3.0-rc6 revert build. Look for any pool directory (a published
    # amd64-edge-* or a member of an amd64-t2-* build tree) whose KVER
    # sidecar matches the pin; fall back to mtime only when there is no pin.
    if [ "$line" = "amd64-edge" ] && [ -s "assets/kernel/amd64-edge/KVER" ]; then
        local _pin _d _cands
        _pin="$(tr -d '[:space:]' < assets/kernel/amd64-edge/KVER)"
        mapfile -t _cands < <(find "$KERNEL_STAGING_DIR" -maxdepth 2 -type d \( -name 'amd64-edge-*' -o -path '*/amd64-t2-*/*' \) 2>/dev/null)
        for _d in "${_cands[@]}"; do
            [ -d "$_d" ] || continue
            [ -s "$_d/KVER" ] || continue
            if [ "$(tr -d '[:space:]' < "$_d/KVER")" = "$_pin" ]; then
                newest="$_d"
                break
            fi
        done
    fi
    # Directory names are NOT lexically ordered by recency (e.g. an
    # "...-rc4-3-t2-xhcifix-DATE" variant sorts before a same-date
    # "...-rc4-t2-trixie-DATE" one because '3' < 't' lexically, even
    # though the xhcifix one was staged later) -- match
    # stage-amd64-kernel.sh's own selection (ls -dt, real mtime) or this
    # check disagrees with what actually got staged. Found + fixed
    # 2026-09-23 after it produced a false FAIL against a genuinely
    # fresher local stage.
    if [ -z "$newest" ]; then
        newest="$(find "$KERNEL_STAGING_DIR" -maxdepth 1 -type d -name "${line}-*" -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-)"
    fi
    if [ -z "$newest" ]; then
        echo "[3] WARN: no staged kernel found for line '$line' under $KERNEL_STAGING_DIR"
        WARN=$((WARN + 1))
        return
    fi
    local newest_name
    newest_name="$(basename "$newest")"
    local local_kver_dir="assets/kernel/$line"
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
        local staged_deb
        staged_deb="$(find "$newest" -maxdepth 1 -iname 'linux-image-*.deb' 2>/dev/null | head -1)"
        local local_debs
        local_debs=("$local_kver_dir"/linux-image-*.deb)
        if [ -n "$staged_deb" ] && [ -e "${local_debs[0]}" ]; then
            local staged_sum
            staged_sum="$(sha256sum "$staged_deb" 2>/dev/null | cut -d' ' -f1)"
            local match=0 local_deb local_sum
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
}

if [ -d "$KERNEL_STAGING_DIR" ]; then
    case "$NCZ_SYSTEM_ARCH" in
        amd64)
            # Operator directive 2026-10-05: amd64 ships the 7.2.9 stable
            # line as the default plus the pinned 7.3.0-rc6 AER-revert edge
            # line. Both are checked; the edge check selects the pool dir
            # matching assets/kernel/amd64-edge/KVER, not newest-by-mtime.
            check_amd64_line amd64-stable
            check_amd64_line amd64-edge
            ;;
        arm64)
            check_arm64_channel assets/kernel/mainline stable required
            check_arm64_channel assets/kernel/edge prerelease optional
            ;;
        *)
            # An arch we don't recognise. Don't claim OK -- say we don't
            # know and let the operator route by hand. WARN, not FAIL,
            # so an unknown future arch doesn't break the build pipeline,
            # but the operator sees the gap.
            echo "[3] WARN: NCZ_SYSTEM_ARCH='$NCZ_SYSTEM_ARCH' -- neither amd64 nor arm64, skipping kernel freshness check (set NCZ_TARGET_ARCH=amd64|arm64 to force)"
            WARN=$((WARN + 1))
            ;;
    esac

    # ORPHANED PREFIXES. Both arms above glob only their own prefix, and
    # nothing else in the pipeline sees anything else. So a kernel that
    # was published under a name NEITHER arm matches (e.g. the legacy
    # sky1-<ver>-<date> namespace, an amd64-t2- prefix variant, a typo'd
    # edge name) is invisible to every consumer -- not an error anywhere,
    # just silently never staged. Measured 2026-09-27: two real, correctly
    # -built amd64 kernels went in as amd64-t2-* and were ignored for a
    # full build cycle while this very check reported "matches the newest
    # in the shared pool". Measured 2026-09-28: the pool held
    # sky1-7.2.8-20260927 (no r<N>, no sky1-ncz suffix) which matched
    # neither arm64 glob nor the prior amd64 glob. A guard cannot see
    # what it does not glob, so look for the names nothing globs. We
    # enumerate EVERY subdir of the pool (not just the ones matching one
    # arm's prefix -- otherwise the orphan is invisible by construction).
    orphans=""
    while IFS= read -r d; do
        [ -n "$d" ] || continue
        case "$(basename "$d")" in
            # amd64: the two live lines (operator directive 2026-10-05).
            # amd64-stable-* is the default; amd64-edge-* is the pinned
            # 7.3.0-rc6 AER-revert edge.
            amd64-stable-*|amd64-edge-*) ;;
            # arm64: the single live namespace -- r<N>-<kver>-sky1-ncz-<date>.
            # The trailing * lets a future suffix (e.g. -xhcifix) still
            # classify instead of falling through unseen, same posture as
            # assets/refind/zz1-ncz-refind-refresh-amd64's classifier.
            r[0-9]*-*-sky1-ncz*) ;;
            # Bisect trees are experiments by definition (a T2 bisect run keeps its per-step builds here);
            # they are never staged into an image, so they are not orphans. Added 2026-09-29 after a live
            # amd64-t2-bisect-* run failed every image build's freshness gate.
            *-bisect-*) ;;
            # amd64-t2-* build trees hold several edge/APIC variants side by
            # side; only the member matching assets/kernel/amd64-edge/KVER is
            # staged (pin-aware, see check_amd64_line). The tree itself is an
            # experiment pool, not an orphan namespace.
            amd64-t2-*) ;;
            # Anything else under the pool that LOOKS like a kernel
            # build (starts with amd64-, r<digit>-, or sky1-) is an
            # orphan. Plain top-level dirs (lost+found, etc.) are not.
            amd64-*|r[0-9]*-*|sky1-*) orphans="$orphans $(basename "$d")" ;;
            *) ;;
        esac
    done <<EOF
$(find "$KERNEL_STAGING_DIR" -maxdepth 1 -mindepth 1 -type d 2>/dev/null)
EOF
    if [ -n "$orphans" ]; then
        echo "[3] FAIL: kernel-staging holds build(s) under a prefix nothing consumes:"
        for o in $orphans; do echo "          $o"; done
        echo "          The amd64 branch globs amd64-stable-* and amd64-edge-*;"
        echo "          the arm64 branch globs r<digit>*-*-sky1-ncz*. Anything else"
        echo "          will NEVER be staged into an image."
        echo "          Rename to the correct line prefix, or republish with"
        echo "          build/publish-amd64-kernel.sh stable|edge <deb-dir> (amd64)"
        echo "          or build/stage-kernel.sh (arm64)."
        FAIL=$((FAIL + 1))
    fi
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