#!/bin/bash
# 82-mali-gpu.sh — install the CIX mali_kbase GPU kernel driver. Since 26.7
# NCZ-OS ships mali (not panthor) as the default GPU driver on Sky1: the
# default (Mali) boot entry blacklists panthor, so mali_kbase must be
# present + loaded for /dev/mali0 → the CIX
# hardware GL/GLES/OpenCL stack (26-gpu-default-mali.sh). Metal-validated on
# O6N + MS-R1 test boards 2026-07-23: DDK r54p1, /dev/mali0, devfreq + rate-limit fix,
# HW glamor on Mali-G720, no wedge.
#
# Two layers (belt + suspenders, doctrine "CIX drivers = DKMS"):
#   1. PRE-BUILT overlay .ko for the shipped kernel → updates/ (works
#      out-of-box, no build/headers/toolchain needed at install; vermagic-guarded).
#   2. Register the cix-gpu-dkms SOURCE (+ the SCMI rate-limit patch) with DKMS
#      so a FUTURE kernel upgrade rebuilds mali_kbase automatically. Best-effort:
#      needs the cix-gpu-dkms deb + linux-headers; skipped cleanly if absent.
#
# mali_kbase is out-of-tree (no in-tree ACPI auto-load like amvx); loading it
# is ncz-gpu-switcher's job (see below). RUNS INSIDE CHROOT via run-all.sh, after 81-vpu.sh.
# NCZ-PLATFORM-GUARD: sky1-arm64 only (docs/PLATFORM-SPLIT-DESIGN.md). Arch order matches
# run-all.sh: NCZ_TARGET_ARCH, then the late.sh BUILD_ARCH stamp, then dpkg. An
# undetectable arch does NOT skip (legacy behavior).
_ncz_pg_arch="${NCZ_TARGET_ARCH:-}"
[ -n "$_ncz_pg_arch" ] || _ncz_pg_arch=$(cat /usr/local/lib/cix-installer/BUILD_ARCH 2>/dev/null | tr -d '[:space:]')
[ -n "$_ncz_pg_arch" ] || _ncz_pg_arch=$(dpkg --print-architecture 2>/dev/null || true)
case "$_ncz_pg_arch" in
    arm64|aarch64|"") ;;
    *) echo "[${0##*/}] platform guard: arch=$_ncz_pg_arch is not sky1-arm64; skipping"; exit 0 ;;
esac
unset _ncz_pg_arch
set +e

# Mali-G720 (Sky1) is arm64-only hardware. Without this guard, run-all.sh runs
# this hook unconditionally on every image including amd64 T2 builds -- same
# class of bug fixed 2026-09-22 in 83-panthor-gpu.sh, where the analogous
# unconditional `dkms add` broke real amd64 T2 kernel installs (dkms then
# force-rebuilds every registered package, trying to compile Sky1 GPU source
# against x86_64 headers). Match the arch-guard convention from
# 54-gpu-accel.sh / 55-t2-firmware.sh / 83-panthor-gpu.sh.
if [ "$(dpkg --print-architecture 2>/dev/null)" != "arm64" ]; then
    echo "[82] not arm64 (Sky1 Mali-G720 hardware only) -- skipping"
    exit 0
fi

INSTALLER_META=/usr/local/lib/cix-installer
ASSET_DIR="$INSTALLER_META/assets/kernel/mali"     # overlay + DKMS source + patch
RL_PATCH="$ASSET_DIR/mali-kbase-scmi-ratelimit.patch"
DKMS_SRC="$ASSET_DIR/src"                          # DKMS source tree + dkms.conf
DKMS_VER="1.0"
MODS=(mali_kbase memory_group_manager protected_memory_allocator)

# --- mali is built for the one shipping kernel (KVER_NEXT sidecar) ---
KVER_NEXT=""
[ -f "$INSTALLER_META/KVER_NEXT" ] && KVER_NEXT=$(tr -d ' \t\r\n' < "$INSTALLER_META/KVER_NEXT")
if [ -z "$KVER_NEXT" ]; then
    echo "[82] no KVER_NEXT — skipping mali (no shipping kernel recorded)"; exit 0
fi
KDIR="/usr/lib/modules/$KVER_NEXT"
if [ ! -d "$KDIR" ]; then
    echo "[82] $KDIR absent — mali skipped"; exit 0
fi

# Size of a module's .gnu.linkonce.this_module section (= the struct module it
# was compiled against). The kernel refuses a module whose size differs from
# its own: "section size must match the kernel's built struct module size".
this_module_size() {
    readelf -S -W "$1" 2>/dev/null \
        | sed -n 's/.*\.gnu\.linkonce\.this_module[[:space:]]*PROGBITS[[:space:]]*[0-9a-f]*[[:space:]]*[0-9a-f]*[[:space:]]*\([0-9a-f]*\).*/\1/p' \
        | head -1
}
# An in-tree module of the shipping kernel: same build, so same struct module.
REF_KO=$(find "$KDIR/kernel" -name '*.ko' 2>/dev/null | LC_ALL=C sort | head -1)
REF_TM=""
[ -n "$REF_KO" ] && REF_TM=$(this_module_size "$REF_KO")

# --- 1. pre-built overlay -> updates/ (vermagic + struct-module guarded) ----
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
        # struct module guard (2026-10-26, O6N r292: overlays with this_module
        # 0x4c0 against the kernel's 0x500 passed the vermagic guard and were
        # refused at load -> no GPU). Needs readelf (binutils, pulled in by
        # dkms); without it, or without an in-tree reference, warn and keep the
        # old behavior. The project ships uncompressed overlays.
        if [ -z "$REF_TM" ]; then
            echo "[82] WARN: cannot verify $m struct module size (no readelf or no in-tree reference module)"
        else
            tm=$(this_module_size "$ko")
            if [ "$tm" != "$REF_TM" ]; then
                echo "[82] REFUSE $m: this_module size '${tm:-unreadable}' != kernel '$REF_TM' (struct module layout differs; the kernel would refuse it)"
                continue
            fi
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
# build/build-dkms-debs.sh now produces a real cix-gpu-kmd-dkms_*.deb from
# this same $DKMS_SRC + dkms.conf (its postinst does dkms add + autoinstall +
# the dracut initramfs refresh, matching the 2026-09-13 VPU lesson that a
# bare `dkms build` without a boot-image refresh leaves the OLD module loading
# from the initramfs regardless of what DKMS just built). Prefer that real,
# dpkg-tracked package -- it is what gives apt an update path at all (the
# raw source-copy this hook used before never registered with dpkg, so apt
# could not see or upgrade cix-gpu-kmd; this is the gap build-dkms-debs.sh's
# own header comment describes). Fall back to the raw source-copy method
# ONLY if no staged .deb is present, so an older or partial build tree still
# gets a working (if dpkg-blind) DKMS registration rather than nothing.
#
# post-install/79-dkms-prep.sh must have run first: the shipped kernel headers
# are a Yocto build-host artifact and cannot build anything until it repairs
# them (foreign fixdep/modpost, missing localversion). See that script.
MALI_DEB=$(ls /usr/local/lib/cix-installer/assets/cix-debs/cix-gpu-kmd-dkms_*.deb 2>/dev/null | head -1)
if [ -n "$MALI_DEB" ]; then
    if dpkg -i "$MALI_DEB" >/dev/null 2>&1; then
        echo "[82] installed $(basename "$MALI_DEB") via dpkg — cix-gpu-kmd now apt-tracked"
    else
        echo "[82] WARN: dpkg -i $(basename "$MALI_DEB") failed — falling back to raw DKMS source registration"
        # A postinst failure can leave dpkg's record for this package
        # half-configured, which would make a LATER real 'apt install
        # cix-gpu-kmd-dkms' refuse to proceed until 'dpkg --configure -a' is
        # run manually. Clear that now so the fallback path (and any future
        # real install attempt) starts from a clean dpkg state.
        dpkg --purge cix-gpu-kmd-dkms >/dev/null 2>&1 || true
        MALI_DEB=""
    fi
fi

if [ -z "$MALI_DEB" ] && [ -d "$DKMS_SRC" ] && [ -f "$ASSET_DIR/dkms.conf" ]; then
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
            && echo "[82] dkms add cix-gpu-kmd/$DKMS_VER (dpkg-blind fallback — no staged .deb)" \
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
elif [ -z "$MALI_DEB" ]; then
    echo "[82] no staged .deb and no DKMS source at $DKMS_SRC — relying on pre-built overlay"
fi

# The ncz-mali-kbase-allowed ExecCondition helper that used to be written here
# is gone with the unit it guarded: it decided whether to load kbase by reading
# module_blacklist= off the cmdline, a rule the sky1.gpu= entries no longer use.
# ncz-gpu-switcher makes that decision now.


# History: a global modules-load.d entry was evaluated by every installed
# kernel and logged a false module-load error on kernels without mali_kbase;
# it was replaced by a conditional oneshot, itself now retired (below).
# The mali_kbase autoloader that used to live here is retired: ncz-gpu-switcher
# (83-panthor-gpu.sh) now loads the GPU driver, because loading it is not a
# standalone decision -- it has to happen together with the matching userspace
# and only when sky1.gpu= selects mali.
#
# The old unit was also wrong on its own terms: it ran `modprobe mali_kbase`
# alone, without memory_group_manager and protected_memory_allocator, and kbase
# probe returns -517 (-EPROBE_DEFER) when those two are not already present.
# Measured on O6N 2026-08-15.
rm -f /etc/modules-load.d/cix-mali.conf \
      /etc/systemd/system/ncz-mali-kbase-load.service \
      /etc/systemd/system/multi-user.target.wants/ncz-mali-kbase-load.service
echo "[82] mali_kbase loading delegated to ncz-gpu-switcher (see 83-panthor-gpu.sh)"


# --- DKMS WINS: install a DKMS build that dkms refused to install ---------
# The overlay above and the DKMS build come from the same source, so they carry
# the same MODULE_VERSION/srcversion. dkms then declines to install over the
# overlay ("already installed at version r53p0-00eac0, override by specifying
# --force") and leaves the package "built", not "installed": the DKMS module
# never reaches updates/dkms/, the retirement below never fires, and the
# overlay stays the loaded driver. Measured on O6N 2026-10-26 (r292): DKMS had
# built correct modules (this_module 0x500) while the refused 0x4c0 overlay
# stayed in updates/. A module built here, against this machine's headers, is
# the one to keep, so force the install when dkms built it.
if [ -n "${KVER_NEXT:-}" ] && command -v dkms >/dev/null 2>&1; then
    _st=$(dkms status -m cix-gpu-kmd -v "$DKMS_VER" -k "$KVER_NEXT" 2>/dev/null)
    case "$_st" in
        *": built"*)
            if dkms install -m cix-gpu-kmd -v "$DKMS_VER" -k "$KVER_NEXT" --force >/dev/null 2>&1; then
                echo "[82] dkms install --force cix-gpu-kmd/$DKMS_VER for $KVER_NEXT (dkms had built it but declined to replace the overlay)"
            else
                echo "[82] WARN: dkms install --force cix-gpu-kmd/$DKMS_VER for $KVER_NEXT failed"
            fi ;;
    esac
    unset _st
fi

# --- DKMS WINS: retire the overlay once DKMS has produced modules -----------
# The overlay installs into updates/ and DKMS into updates/dkms/; depmod prefers
# updates/, so the prebuilt silently beat the DKMS build on every boot and the
# DKMS half was dead weight. A vermagic-locked prebuilt is the worst option we
# have -- it is exactly what dropped the board to software rendering between rc5
# and rc6 -- so it is now a FALLBACK only: if DKMS produced a module for this
# kernel, remove the overlay copies and let DKMS own the driver.
if [ -n "${KVER_NEXT:-}" ] && [ -d "/usr/lib/modules/$KVER_NEXT/updates/dkms" ]; then
    _retired=0
    for _m in "${MODS[@]}"; do
        if ls "/usr/lib/modules/$KVER_NEXT/updates/dkms/$_m.ko"* >/dev/null 2>&1; then
            rm -f "/usr/lib/modules/$KVER_NEXT/updates/$_m.ko" \
                  "/usr/lib/modules/$KVER_NEXT/updates/$_m.ko.xz" 2>/dev/null && _retired=$((_retired+1))
        fi
    done
    if [ "$_retired" -gt 0 ]; then
        depmod -a "$KVER_NEXT" 2>/dev/null
        echo "[82] DKMS owns mali: retired $_retired prebuilt overlay module(s) from updates/"
    else
        echo "[82] WARN: no DKMS modules found — prebuilt overlay still carrying the GPU"
    fi
fi

echo "[82] mali GPU driver stage done for $KVER_NEXT"
exit 0
