#!/bin/bash
# 81-vpu.sh — install validated amvx (Linlon MVX / Sky1 VPU) kernel-module overlay
#
# Problem: the in-tree amvx.ko shipped with the 7.0.12-cix-sky1-next kernel calls
# vb2_queue_init() from setup_vb2_queue() without ever setting vb2_queue.lock.
# From kernel v6.x onwards vb2_core_queue_init() enforces a non-NULL q->lock
# (`if (WARN_ON(!q->lock)) return -EINVAL;`, videobuf2-core.c:2645), so
# VIDIOC_REQBUFS / VIDIOC_CREATE_BUFS fail and the H264/HEVC/VP9/AV1 hardware
# codec is non-functional (gstreamer reports "not-negotiated (-4)"; the V4L2 M2M
# nodes advertise formats but no session can allocate buffers). The
# 6.18.26-cix-sky1-lts kernel's vb2 check is conditional ("... and no custom
# wait_prepare is provided"), so LTS is unaffected — which is why the VPU worked
# on earlier LTS-based builds.
#
# Fix: a rebuilt amvx.ko (source patch
# assets/kernel/patches/2020-amvx-vb2-queue-lock-7.0.patch) that assigns a
# dedicated per-port q->lock before vb2_queue_init(). amvx already serialises
# every ioctl via vsession->mutex and never enters vb2 through the locking
# helper wrappers, so the extra lock only satisfies the sanity check and never
# contends with vsession->mutex (no deadlock).
#
# Mechanism (mirrors 80-npu.sh's overlay step): install the overlay to
# /usr/lib/modules/$KVER/updates/amvx.ko, which takes depmod precedence over the
# in-tree kernel/ copy, then depmod. amvx auto-loads at boot via the Sky1 ACPI
# match (CIXH3010 -> amvx_dev), so no modules-load.d / initrd change is needed.
#
# Only the NEXT kernel (7.0.x-cix-sky1-next) ships an overlay; LTS is skipped
# (no overlay present -> the working in-tree LTS amvx is used). A vermagic guard
# refuses a mismatched module.
#
# RUNS INSIDE CHROOT / on-target (via run-all.sh), after 80-npu.sh. Owns ONLY the
# amvx/VPU module — does NOT touch the NPU SSDT/KMD, bootloader, or initrd.

set +e

INSTALLER_META=/usr/local/lib/cix-installer

KERNEL_LABELS=()
KERNEL_VERS=()
if [ -f "$INSTALLER_META/KVER_NEXT" ]; then
    KVER_NEXT=$(cat "$INSTALLER_META/KVER_NEXT" 2>/dev/null | tr -d ' \t\r\n')
    if [ -n "$KVER_NEXT" ]; then
        KERNEL_LABELS+=("edge")
        KERNEL_VERS+=("$KVER_NEXT")
    fi
fi

# --- Fallback: fold in an out-of-band NCZ edge (7.2) kernel ---
# This only picks up a 7.2-class NCZ kernel present on disk but absent from the
# KVER_NEXT sidecar, so a future amvx overlay would still reach it. De-duped
# and idempotent (vermagic-guarded install to updates/). 7.2 ships no amvx
# overlay today (the vb2 q->lock fix is in-tree), so on a normal system this
# loop finds a match only via the sidecar and is otherwise a clean no-op
# ("using in-tree amvx.ko").
for _mk in /lib/modules/*7.2*-ncz /usr/lib/modules/*7.2*-ncz; do
    [ -d "$_mk" ] || continue
    _kv="${_mk##*/}"
    _known=0
    for _k in "${KERNEL_VERS[@]}"; do [ "$_k" = "$_kv" ] && { _known=1; break; }; done
    [ "$_known" = "1" ] && continue
    echo "[81] fallback: NCZ edge kernel $_kv present but not in KVER_NEXT sidecar — folding in for VPU overlay"
    KERNEL_LABELS+=("edge")
    KERNEL_VERS+=("$_kv")
done

if [ "${#KERNEL_VERS[@]}" -eq 0 ]; then
    echo "[81] WARN: no KVER_NEXT sidecar found; skipping VPU overlay"
    exit 0
fi

echo "[81] installing Sky1 VPU (amvx) validated overlay..."

for i in "${!KERNEL_VERS[@]}"; do
    LABEL="${KERNEL_LABELS[$i]}"
    KVER="${KERNEL_VERS[$i]}"

    if [ ! -d "/usr/lib/modules/$KVER" ]; then
        echo "[81] WARN: /usr/lib/modules/$KVER does not exist; skipping $KVER"
        continue
    fi

    OVERLAY=""
    for cand in \
        "$INSTALLER_META/assets/kernel/modules-overlay/$KVER/amvx.ko" \
        "/cdrom/cixmini/assets/kernel/modules-overlay/$KVER/amvx.ko"; do
        [ -f "$cand" ] && { OVERLAY="$cand"; break; }
    done

    if [ -z "$OVERLAY" ]; then
        echo "[81] $LABEL/$KVER: no amvx overlay -> using in-tree amvx.ko"
        continue
    fi

    OVM=$(modinfo -F vermagic "$OVERLAY" 2>/dev/null | awk '{print $1}')
    if [ -n "$OVM" ] && [ "$OVM" != "$KVER" ]; then
        echo "[81] WARN: overlay $OVERLAY vermagic '$OVM' != '$KVER'; not applying"
        continue
    fi

    install -D -m 0644 "$OVERLAY" "/usr/lib/modules/$KVER/updates/amvx.ko"
    depmod -a "$KVER" 2>/dev/null
    echo "[81] $LABEL/$KVER: applied validated amvx overlay (vb2 q->lock fix, vermagic $OVM) -> updates/"
done

exit 0
