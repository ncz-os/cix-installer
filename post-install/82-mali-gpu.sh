#!/bin/bash
# 82-mali-gpu.sh — install the CIX mali_kbase GPU kernel driver for the 26.7
# "Maximilian" MALI release. 26.7 ships mali (not the in-tree panthor) as the
# GPU driver on the 7.2 edge kernel: the 7.2 (Mali) boot entry blacklists
# panthor, so mali_kbase must be present + loaded for /dev/mali0 → the CIX
# hardware GL/GLES/OpenCL stack (26-gpu-default-mali.sh). Metal-validated on
# O6N + cixmini 2026-07-23: DDK r54p1, /dev/mali0, devfreq + rate-limit fix,
# HW glamor on Mali-G720, no wedge.
#
# Two layers (belt + suspenders, doctrine "CIX drivers = DKMS"):
#   1. PRE-BUILT overlay .ko for the shipped 7.2 kernel → updates/ (works
#      out-of-box, no build/headers/toolchain needed at install; vermagic-guarded).
#   2. Register the cix-gpu-dkms SOURCE (+ the SCMI rate-limit patch) with DKMS
#      so a FUTURE kernel upgrade rebuilds mali_kbase automatically. Best-effort:
#      needs the cix-gpu-dkms deb + linux-headers; skipped cleanly if absent.
#
# mali_kbase is out-of-tree (no in-tree ACPI auto-load like amvx), so add a
# modules-load.d entry for the 7.2 kernel. LTS (7.0.12) uses in-tree panthor —
# NO mali there. RUNS INSIDE CHROOT via run-all.sh, after 81-vpu.sh.
set +e

INSTALLER_META=/usr/local/lib/cix-installer
ASSET_DIR="$INSTALLER_META/assets/kernel/mali"     # mali .ko overlay + patch + deb
RL_PATCH="$ASSET_DIR/mali-kbase-scmi-ratelimit.patch"
DKMS_DEB=$(ls "$ASSET_DIR"/cix-gpu-dkms_*_arm64.deb 2>/dev/null | head -1)
MODS=(mali_kbase memory_group_manager protected_memory_allocator)

# --- only the 7.2/edge (NEXT) kernel gets mali; LTS keeps in-tree panthor ---
KVER_NEXT=""
[ -f "$INSTALLER_META/KVER_NEXT" ] && KVER_NEXT=$(tr -d ' \t\r\n' < "$INSTALLER_META/KVER_NEXT")
if [ -z "$KVER_NEXT" ]; then
    echo "[82] no KVER_NEXT — skipping mali (LTS-only install uses panthor)"; exit 0
fi
KDIR="/usr/lib/modules/$KVER_NEXT"
if [ ! -d "$KDIR" ]; then
    echo "[82] $KDIR absent — mali skipped"; exit 0
fi

# --- 1. pre-built overlay -> updates/ (vermagic-guarded) --------------------
OVL="$ASSET_DIR/$KVER_NEXT"
installed=0
if [ -d "$OVL" ]; then
    mkdir -p "$KDIR/updates"
    for m in "${MODS[@]}"; do
        ko=$(ls "$OVL/$m.ko" "$OVL/$m.ko.xz" 2>/dev/null | head -1)
        [ -n "$ko" ] || { echo "[82] WARN: overlay missing $m — skipping"; continue; }
        # vermagic guard (xz-aware)
        vm=$(modinfo -F vermagic "$ko" 2>/dev/null | awk '{print $1}')
        if [ -n "$vm" ] && [ "$vm" != "$KVER_NEXT" ]; then
            echo "[82] REFUSE $m: vermagic '$vm' != '$KVER_NEXT'"; continue
        fi
        install -m 0644 "$ko" "$KDIR/updates/$(basename "$ko")"
        echo "[82] installed overlay $(basename "$ko") -> updates/"
        installed=$((installed+1))
    done
    depmod -a "$KVER_NEXT" 2>/dev/null
else
    echo "[82] no pre-built overlay at $OVL"
fi

# --- 2. register cix-gpu-dkms (+ rate-limit patch) for future rebuilds ------
if [ -n "$DKMS_DEB" ] && command -v dkms >/dev/null 2>&1; then
    dpkg -i "$DKMS_DEB" >/dev/null 2>&1
    SRC=$(ls -d /usr/src/cix-gpu-kmd-* 2>/dev/null | head -1)
    if [ -n "$SRC" ] && [ -f "$RL_PATCH" ]; then
        MALI_C="$SRC/drivers/gpu/arm/midgard/backend/gpu/mali_kbase_devfreq.c"
        if [ -f "$MALI_C" ] && ! grep -q KBASE_SCMI_RATE_LIMIT_US "$MALI_C" 2>/dev/null; then
            ( cd "$SRC" && patch -p1 < "$RL_PATCH" >/dev/null 2>&1 ) \
                && echo "[82] applied SCMI rate-limit patch to cix-gpu-dkms source" \
                || echo "[82] WARN: rate-limit patch did not apply cleanly (overlay still covers boot)"
        fi
    fi
    # build now only if headers are present; otherwise DKMS rebuilds on next
    # apt kernel upgrade. The pre-built overlay already covers the shipped kernel.
    if [ -f "$KDIR/build/Makefile" ]; then
        VER=$(echo "$SRC" | sed 's#.*/cix-gpu-kmd-##')
        dkms install -m cix-gpu-kmd -v "$VER" -k "$KVER_NEXT" --force >/dev/null 2>&1 \
            && echo "[82] dkms built cix-gpu-kmd for $KVER_NEXT" \
            || echo "[82] dkms build skipped/failed (overlay covers boot)"
    else
        echo "[82] no kernel headers ($KDIR/build) — DKMS will build on next kernel upgrade; overlay covers now"
    fi
else
    echo "[82] cix-gpu-dkms deb or dkms absent — relying on pre-built overlay"
fi

# --- 3. auto-load mali_kbase only on a kernel that actually provides it -----
# A global modules-load.d entry is evaluated by BOTH installed kernels. It
# therefore makes the stable 7.0 fallback log a false module-load error even
# though mali_kbase intentionally exists only for edge 7.2. Use a conditional
# oneshot: modinfo is evaluated against the running kernel and exit 1 from an
# ExecCondition is a clean skip, while a real modprobe failure on edge remains
# visible as a failed unit.
if [ "$installed" -gt 0 ] || [ -e "$KDIR/updates/mali_kbase.ko" ] || [ -e "$KDIR/updates/mali_kbase.ko.xz" ]; then
    rm -f /etc/modules-load.d/cix-mali.conf
    cat > /etc/systemd/system/ncz-mali-kbase-load.service <<'EOF'
[Unit]
Description=Load NCZ mali_kbase when the running kernel provides it
After=systemd-modules-load.service
Before=greetd.service display-manager.service graphical.target

[Service]
Type=oneshot
ExecCondition=/usr/sbin/modinfo mali_kbase
ExecStart=/usr/sbin/modprobe mali_kbase
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    systemctl enable ncz-mali-kbase-load.service >/dev/null 2>&1 || \
        echo "[82] WARN: could not enable ncz-mali-kbase-load.service" >&2
    echo "[82] mali_kbase conditional loader enabled (edge loads; stable skips cleanly)"
else
    rm -f /etc/modules-load.d/cix-mali.conf \
          /etc/systemd/system/ncz-mali-kbase-load.service \
          /etc/systemd/system/multi-user.target.wants/ncz-mali-kbase-load.service
    echo "[82] mali_kbase not installed — NOT adding modules-load (avoids a load failure loop)"
fi

echo "[82] mali GPU driver stage done for $KVER_NEXT"
exit 0
