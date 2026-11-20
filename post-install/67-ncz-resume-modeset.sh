#!/bin/bash
# 67-ncz-resume-modeset.sh -- amd64 desktops: re-modeset the internal panel
# after every suspend/hibernate resume.
#
# THE BUG (measured 2026-11-18, MacBookPro16,1, amdgpu eDP): after ANY S3
# resume the internal panel flickers (desktop and lock-screen saver) although
# the kernel log shows a clean resume; a fresh boot is steady. It reproduced on
# three kernels (base, base + 7002 Navi14, + the AER series), so it is not a
# regression of any one patch set. One output off/on cycle through the
# compositor cures it. An Intel-iGPU laptop left a greeter that stopped
# painting after resume: the same family. So this applies to ALL amd64
# hardware, not only T2 Macs.
#
# WHAT IT INSTALLS
#   /usr/local/sbin/ncz-resume-modeset              the helper (post-install/lib/)
#   /usr/lib/systemd/system-sleep/ncz-resume-modeset the hook: on `post` it
#       schedules the helper ~0.5 s later (systemd-run --no-block) so the resume
#       is never delayed; the panel flickers from the moment of resume until
#       the re-modeset, so it is started as early as the compositor allows.
# The helper only acts where a Wayland compositor socket and wlr-randr exist, so
# on nodesktop/minimal/server images it does nothing.
#
# NOT ON ARM64/Sky1: an output disable->enable cycle is the DP AUX-engine wedge
# trigger on those boards (post-install/55-greeter.sh), so this hook is only in
# hooks.list.amd64 and also refuses to install on any other architecture.
#
# Test seam: NCZ_RESUME_MODESET_ROOT prefixes every path; NCZ_TARGET_ARCH pins
# the architecture (same pattern as 64-t2-power-cap.sh).
set -eu
ROOT="${NCZ_RESUME_MODESET_ROOT:-}"

# NCZ-PLATFORM-GUARD: amd64 only (docs/PLATFORM-SPLIT-DESIGN.md). Arch order
# matches run-all.sh: NCZ_TARGET_ARCH, then the late.sh BUILD_ARCH stamp, then
# dpkg. An undetectable arch is treated as NOT amd64 (fail safe): an output
# off/on cycle wedges the DP AUX engine on Sky1 boards, so this must never run
# on a platform we cannot identify.
_ncz_pg_arch="${NCZ_TARGET_ARCH:-}"
[ -n "$_ncz_pg_arch" ] || _ncz_pg_arch=$(cat /usr/local/lib/cix-installer/BUILD_ARCH 2>/dev/null | tr -d '[:space:]')
[ -n "$_ncz_pg_arch" ] || _ncz_pg_arch=$(dpkg --print-architecture 2>/dev/null || true)
case "$_ncz_pg_arch" in
    amd64|x86_64) ;;
    *)
        echo "[67] ${_ncz_pg_arch:-unknown arch}: resume re-modeset not installed (amd64 only; an output off/on cycle wedges the Sky1 DP AUX engine)"
        exit 0
        ;;
esac

HELPER_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/ncz-resume-modeset"
if [ ! -r "$HELPER_SRC" ]; then
    echo "[67] WARN: $HELPER_SRC missing; cannot install ncz-resume-modeset" >&2
    exit 1
fi

# _wr MODE DEST -- write stdin to DEST with MODE (same helper as 64-t2-power-cap.sh).
_wr() {
    local mode="$1" dest="$2"
    mkdir -p "$(dirname "$dest")" || return 1
    cat > "$dest" || return 1
    chmod "$mode" "$dest"
}

_wr 0755 "$ROOT/usr/local/sbin/ncz-resume-modeset" < "$HELPER_SRC" || exit 1

_wr 0755 "$ROOT/usr/lib/systemd/system-sleep/ncz-resume-modeset" <<'SLEEPEOF'
#!/bin/bash
# After a resume, re-modeset the internal panel (post-install/67-ncz-resume-modeset.sh).
# ($1 = pre|post, $2 = suspend|hibernate|hybrid-sleep|suspend-then-hibernate)
# Never delays or fails the resume: the work is scheduled, ~0.5 s later, detached.
[ "${1:-}" = post ] || exit 0
case "${2:-}" in
    suspend|hibernate|hybrid-sleep|suspend-then-hibernate) ;;
    *) exit 0 ;;
esac
H="${NCZ_RMS_HELPER:-/usr/local/sbin/ncz-resume-modeset}"
[ -x "$H" ] || exit 0
if command -v systemd-run >/dev/null 2>&1; then
    systemd-run --no-block --quiet --on-active=500ms --timer-property=AccuracySec=50ms \
        "$H" >/dev/null 2>&1 && exit 0
fi
( sleep 0.5; "$H" ) >/dev/null 2>&1 &
exit 0
SLEEPEOF

echo "[67] installed ncz-resume-modeset (system-sleep post-resume panel re-modeset)"
exit 0
