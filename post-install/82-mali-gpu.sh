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
ASSET_DIR="$INSTALLER_META/assets/kernel/mali"     # overlay + DKMS source + patch
RL_PATCH="$ASSET_DIR/mali-kbase-scmi-ratelimit.patch"
DKMS_SRC="$ASSET_DIR/src"                          # DKMS source tree + dkms.conf
DKMS_VER="1.0"
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

# --- 2. register cix-gpu-kmd with DKMS for future kernel rebuilds ----------
# Ship the SOURCE tree, mirroring 83-panthor-gpu.sh, rather than a
# cix-gpu-dkms_*.deb. Nothing in this repo ever built that deb, so this branch
# silently took its else-path on every install since it was written and the
# DKMS half of the GPU story never existed -- the prebuilt overlay was carrying
# it alone, which is why an rc5-stamped overlay against an rc6 kernel produced a
# no-GPU boot with nothing to fall back on.
#
# post-install/79-dkms-prep.sh must have run first: the shipped kernel headers
# are a Yocto build-host artifact and cannot build anything until it repairs
# them (foreign fixdep/modpost, missing localversion). See that script.
if [ -d "$DKMS_SRC" ] && [ -f "$ASSET_DIR/dkms.conf" ]; then
    SRC=/usr/src/cix-gpu-kmd-$DKMS_VER
    rm -rf "$SRC"; mkdir -p "$SRC"
    cp -a "$DKMS_SRC/." "$SRC/"
    cp -a "$ASSET_DIR/dkms.conf" "$SRC/dkms.conf"

    if [ -f "$RL_PATCH" ]; then
        MALI_C="$SRC/drivers/gpu/arm/midgard/backend/gpu/mali_kbase_devfreq.c"
        if [ -f "$MALI_C" ] && ! grep -q KBASE_SCMI_RATE_LIMIT_US "$MALI_C" 2>/dev/null; then
            ( cd "$SRC" && patch -p1 < "$RL_PATCH" >/dev/null 2>&1 ) \
                && echo "[82] applied SCMI rate-limit patch to the DKMS source" \
                || echo "[82] WARN: rate-limit patch did not apply cleanly (overlay still covers boot)"
        fi
    fi

    if command -v dkms >/dev/null 2>&1; then
        dkms add -m cix-gpu-kmd -v "$DKMS_VER" >/dev/null 2>&1 \
            && echo "[82] dkms add cix-gpu-kmd/$DKMS_VER" \
            || echo "[82] dkms add skipped (already registered?)"
        # Build now only if the headers are usable; otherwise DKMS autoinstalls
        # on the next kernel upgrade and the prebuilt overlay covers this boot.
        if [ -f "$KDIR/build/Makefile" ]; then
            dkms build   -m cix-gpu-kmd -v "$DKMS_VER" -k "$KVER_NEXT" >/dev/null 2>&1 \
              && dkms install -m cix-gpu-kmd -v "$DKMS_VER" -k "$KVER_NEXT" --force >/dev/null 2>&1 \
              && echo "[82] dkms built+installed cix-gpu-kmd for $KVER_NEXT (-> updates/dkms/)" \
              || echo "[82] dkms build deferred (overlay covers boot; will autoinstall on kernel upgrade)"
        else
            echo "[82] no kernel headers ($KDIR/build) — DKMS will build on next kernel upgrade; overlay covers now"
        fi
    else
        echo "[82] dkms absent — source staged to $SRC, overlay covers boot"
    fi
else
    echo "[82] no DKMS source at $DKMS_SRC — relying on pre-built overlay"
fi

# --- 3. auto-load mali_kbase only on a kernel that actually provides it -----
# ExecCondition helper: the Panthor and SAFE entries deliberately blacklist
# the kbase trio. Keep that selection a clean skip rather than a failed unit.
cat > /usr/local/sbin/ncz-mali-kbase-allowed <<'EOF'
#!/bin/sh
for arg in $(cat /proc/cmdline); do
    case "$arg" in
        module_blacklist=*)
            list=${arg#module_blacklist=}
            old_ifs=$IFS
            IFS=,
            for module in $list; do
                case "$module" in
                    mali_kbase|memory_group_manager|protected_memory_allocator) IFS=$old_ifs; exit 1 ;;
                esac
            done
            IFS=$old_ifs
            ;;
    esac
done
exit 0
EOF
chmod 0755 /usr/local/sbin/ncz-mali-kbase-allowed

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
# Panthor and SAFE entries blacklist the kbase trio on the kernel cmdline.
# Treat that deliberate selection as a clean skip, not a failed boot unit.
ExecCondition=/usr/local/sbin/ncz-mali-kbase-allowed
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
