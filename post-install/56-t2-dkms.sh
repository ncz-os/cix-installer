#!/bin/bash
# 56-t2-dkms.sh — build+install the Apple T2 DKMS modules on T2 Mac hardware.
#
# WHY THIS EXISTS. We retired the in-tree applesmc driver in favour of t2smc
# (operator directive 2026-09-28, "for starters I would remove applesmc in
# favour of t2smc"), and built t2smc/t2gmux/t2smp/t2thunderbolt as DKMS
# modules. t2thunderbolt is NO LONGER built or loaded by default (operator
# 2026-10-05: "don't load t2thunderbolt"): it is a suspend/resume ordering
# quirk, and the T2 community considers the Thunderbolt-on-T2 area unsafe.
# Opt in with NCZ_T2_DKMS_EXTRA=t2thunderbolt (and remove the modprobe.d file). The DKMS sources were committed to assets/kernel/<name>/ and the
# bulk asset copy in build-squashfs-layers.sh does carry them into
# base.squashfs -- but NOTHING EVER INSTALLED THEM, so every install shipped
# with no SMC driver at all.
#
# MEASURED on CHIMERA (MacBookPro16,1, i9-9980HK) 2026-09-29, installed from
# 2026.09.29-a5eb3f3:
#
#     lsmod | grep -E 't2smc|applesmc'        -> nothing
#     dkms status                             -> empty
#     hwmon devices                           -> ADP1 BAT0 coretemp amdgpu
#     /sys/class/hwmon/hwmon5/fan1_input      -> 0 RPM   (amdgpu's own node)
#
# A MacBookPro16,1 has TWO chassis fans and the T2/SMC owns both. With no SMC
# driver Linux cannot see or drive either one, so they never spin no matter
# how hot the machine gets. The operator measured 100C (the coretemp crit
# threshold) playing YouTube; at idle it sat at 70C with the fans at 0 RPM.
#
# The same machine WITH these modules (MEDUSA, identical MacBookPro16,1):
#     hwmon1 name=t2smc fans=2  ->  fan1 1885 RPM, fan2 1733 RPM
#
# So this is a thermal-safety hook, not a nicety.
#
# Gated on real Apple hardware: these modules poke Apple SMC/gmux registers
# and have no meaning anywhere else. dkms itself is already in the image
# (3.2.2-1, confirmed on CHIMERA) and the matching linux-headers package
# ships in assets/kernel/amd64-stable, so the build has what it needs.
# NCZ-PLATFORM-GUARD: amd64 only (docs/PLATFORM-SPLIT-DESIGN.md). Arch order matches
# run-all.sh: NCZ_TARGET_ARCH, then the late.sh BUILD_ARCH stamp, then dpkg. An
# undetectable arch does NOT skip (legacy behavior).
_ncz_pg_arch="${NCZ_TARGET_ARCH:-}"
[ -n "$_ncz_pg_arch" ] || _ncz_pg_arch=$(cat /usr/local/lib/cix-installer/BUILD_ARCH 2>/dev/null | tr -d '[:space:]')
[ -n "$_ncz_pg_arch" ] || _ncz_pg_arch=$(dpkg --print-architecture 2>/dev/null || true)
case "$_ncz_pg_arch" in
    amd64|x86_64|"") ;;
    *) echo "[${0##*/}] platform guard: arch=$_ncz_pg_arch is not amd64; skipping"; exit 0 ;;
esac
unset _ncz_pg_arch
set -uo pipefail

ASSETS="${NCZ_ASSETS_KERNEL:-/usr/local/lib/cix-installer/assets/kernel}"
DMI_ROOT="${NCZ_DMI_ROOT:-/sys/class/dmi/id}"
USRSRC="${NCZ_USRSRC:-/usr/src}"
MODPROBE_D="${NCZ_MODPROBE_D:-/etc/modprobe.d}"
LIBMODULES="${NCZ_LIB_MODULES:-/lib/modules}"
INSTALLER_META="${NCZ_INSTALLER_META:-/usr/local/lib/cix-installer}"
# Source the shared DMI helper. NCZ_T2_DETECT lets the test override the
# path without copying the file (operator 2026-10-05: do not duplicate the
# model list).
T2_DETECT="${NCZ_T2_DETECT:-$INSTALLER_META/assets/refind/ncz-t2-detect.sh}"
if [ -r "$T2_DETECT" ]; then
    # shellcheck disable=SC1090
    . "$T2_DETECT"
else
    echo "[56] WARN: T2 detection helper $T2_DETECT not readable; the hook is inert" >&2
    exit 0
fi
# Default set. t2thunderbolt is opt-in only (see header). t2smp is
# permanently DROPPED: in-kernel patch 9001 owns Apple T2 CPU-hotplug
# ordering on amd64 (operator 2026-10-05; the vendored t2smp DKMS is a
# byte-for-byte duplicate of 9001 -- same notifier priority, same
# 106b:1801 gate, same uninitialised-mask defect under
# CONFIG_CPUMASK_OFFSTACK=y). The vendored source stays under assets/kernel/t2smp/
# for review but is never built here.
MODULES="t2smc t2gmux"
_optin=0
for _x in ${NCZ_T2_DKMS_EXTRA:-}; do
    case "$_x" in
        t2thunderbolt) MODULES="$MODULES $_x"; _optin=1 ;;
        *) echo "[56] WARN: NCZ_T2_DKMS_EXTRA entry '$_x' is not a known optional module -- ignored" >&2 ;;
    esac
done

# T2 hardware gate (DMI: Apple vendor AND known T2 product_name). Non-T2
# Macs and every PC/VM exit 0 here -- the hook never builds, never writes
# a modprobe.d file, never touches dkms.
if ! ncz_is_t2_hardware; then
    echo "[56] $(ncz_t2_detect_detail 2>/dev/null || echo 'not a T2 Mac'); skipping"
    exit 0
fi

if ! command -v dkms >/dev/null 2>&1 && [ ! -x /usr/sbin/dkms ]; then
    echo "[56] WARN: dkms not present -- cannot install T2 modules; fans will not be controllable" >&2
    exit 0
fi
PATH="$PATH:/usr/sbin"   # dkms lives in /usr/sbin and is absent from some PATHs

# KVER selection: read KVER_LIST_AMD64 (the kernels the image actually
# shipped via post-install/10-amd64-kernel.sh). Never read /lib/modules
# (could include a Debian default kernel) and never exclude an -rc KVER
# (the 7.3.0-rc6-1-t2-edge-aerfix amd64 edge is the canonical example).
# Missing or empty KVER_LIST on T2 hardware is fatal (exit 1): no
# fallback to uname -r or to /lib/modules scan.
KVER_LIST="${NCZ_KVER_LIST:-/usr/local/lib/cix-installer/KVER_LIST_AMD64}"
TARGET_KVERS=()
if [ -s "$KVER_LIST" ]; then
    while IFS= read -r kver; do
        case "$kver" in
            ""|\#*) continue ;;
        esac
        if [ -d "$LIBMODULES/$kver" ]; then
            TARGET_KVERS+=("$kver")
        else
            echo "[56] WARN: KVER $kver from $KVER_LIST has no $LIBMODULES/$kver; skipping" >&2
        fi
    done < "$KVER_LIST"
fi
if [ "${#TARGET_KVERS[@]}" -eq 0 ]; then
    echo "[56] ERROR: T2 hardware detected but no usable KVER found in $KVER_LIST (each entry must have $LIBMODULES/<kver>). Refusing to fall back to /lib/modules or uname -r (operator 2026-10-05)." >&2
    exit 1
fi
echo "[56] building t2smc/t2gmux against ${#TARGET_KVERS[@]} KVER(s) from $KVER_LIST"

# t2smp: ALWAYS blacklisted. In-kernel patch 9001 is the canonical owner.
# Run BEFORE the t2thunderbolt block so a single hook pass cleans both stale
# registrations. /usr/src/t2smp-* is also cleared so a future kernel does
# not see a stale dkms.conf.
mkdir -p "$MODPROBE_D"
cat > "$MODPROBE_D/ncz-t2smp.conf" <<'EOC'
# NCZ-OS: t2smp is not loaded. In-kernel patch 9001 (CPU offline) is the
# canonical owner of Apple T2 CPU-hotplug ordering on amd64 (operator
# 2026-10-05). The vendored t2smp DKMS duplicates 9001 (same notifier
# priority, same 106b:1801 gate, uninitialised-cpumask bug under
# CONFIG_CPUMASK_OFFSTACK=y). To re-enable t2smp (NOT supported), remove
# this file, revert 9001 in the running kernel, and re-run this hook
# without the implicit blacklist.
blacklist t2smp
install t2smp /bin/false
EOC
if dkms status 2>/dev/null | grep -q '^t2smp'; then
    dkms remove -m t2smp --all >/dev/null 2>&1 || true
    echo "[56] removed stale DKMS registration of t2smp"
fi
rm -rf "$USRSRC"/t2smp-* 2>/dev/null || true

# t2thunderbolt: never loaded unless explicitly opted in. Keep a modprobe.d file so it cannot
# autoload even if some earlier install or a manual dkms build left the module on disk, and
# drop a stale DKMS registration so new kernels do not rebuild it.
if [ "$_optin" = 1 ]; then
    rm -f "$MODPROBE_D/ncz-t2thunderbolt.conf"
else
    cat > "$MODPROBE_D/ncz-t2thunderbolt.conf" <<'EOC'
# NCZ-OS: t2thunderbolt is not loaded by default (suspend/resume ordering quirk for Thunderbolt
# controllers on T2 Macs; the T2 community treats Thunderbolt on T2 as unsafe for now).
# To opt in: remove this file and install with NCZ_T2_DKMS_EXTRA=t2thunderbolt (post-install/56).
blacklist t2thunderbolt
install t2thunderbolt /bin/false
EOC
    if dkms status 2>/dev/null | grep -q '^t2thunderbolt'; then
        dkms remove -m t2thunderbolt --all >/dev/null 2>&1 || true
        echo "[56] removed stale DKMS registration of t2thunderbolt"
    fi
    rm -rf "$USRSRC"/t2thunderbolt-* 2>/dev/null || true
fi

# t2gmux owns APP000B on T2 hardware (operator 2026-10-05). Blacklist the
# in-kernel apple_gmux so the DKMS t2gmux is the sole owner. This file is
# only ever written on T2 hardware (we already gated above); non-T2 Macs
# and PCs are NEVER touched.
cat > "$MODPROBE_D/ncz-t2-gmux.conf" <<'EOC'
# NCZ-OS: apple_gmux (in-kernel) is not loaded on Apple T2 hardware.
# t2gmux (DKMS) is the canonical owner of APP000B on T2 Macs (operator
# 2026-10-05). The in-kernel driver does not handle the T2 gmux. This
# file is written by post-install/56-t2-dkms.sh on T2 hardware only --
# it is NEVER installed on non-T2 Macs or non-Apple machines.
blacklist apple_gmux
install apple_gmux /bin/false
EOC

_ok=""; _fail=""
for KVER in "${TARGET_KVERS[@]}"; do
    echo "[56] installing T2 DKMS modules against $KVER"
    _okk=""
    _failk=""
    for m in $MODULES; do
        src="$ASSETS/$m"
        if [ ! -f "$src/dkms.conf" ]; then
            echo "[56]   $m: no dkms.conf in $src -- skipping"; _failk="$_failk $m"; continue
        fi
        ver=$(sed -n 's/^PACKAGE_VERSION="\(.*\)"/\1/p' "$src/dkms.conf" | head -1)
        [ -n "$ver" ] || ver=0
        rm -rf "$USRSRC/$m-$ver"
        mkdir -p "$USRSRC/$m-$ver"
        cp -a "$src/dkms.conf" "$USRSRC/$m-$ver/"
        [ -d "$src/src" ] && cp -a "$src/src/." "$USRSRC/$m-$ver/"
        # dkms applies PATCH[0] relative to the source root; carry the patches dir.
        if [ -d "$src/patches" ]; then
            mkdir -p "$USRSRC/$m-$ver/patches"
            cp -a "$src/patches/." "$USRSRC/$m-$ver/patches/"
        fi
        if dkms add -m "$m" -v "$ver" >/dev/null 2>&1 || true; then :; fi
        if dkms build -m "$m" -v "$ver" -k "$KVER" >/dev/null 2>&1 \
           && dkms install -m "$m" -v "$ver" -k "$KVER" --force >/dev/null 2>&1; then
            _okk="$_okk $m/$ver"
        else
            echo "[56]   $m/$ver FAILED to build against $KVER" >&2
            _failk="$_failk $m"
        fi
    done
    _ok="$_ok [$_KVER: $_okk]"
    _fail="$_fail [$_KVER: $_failk]"

    [ -n "$_okk" ]   && echo "[56] installed for $KVER:$_okk"
    [ -n "$_failk" ] && echo "[56] WARN: NOT installed for $KVER:$_failk" >&2

    # t2smc is the one that matters for thermal safety -- say so loudly if absent.
    case " $_failk " in
        *" t2smc "*)
            echo "[56] WARN: t2smc is MISSING for $KVER -- the two chassis fans cannot be driven" >&2
            echo "[56]       and the machine will heat until it thermal-throttles." >&2 ;;
    esac
done

[ -n "$_ok" ]   && echo "[56] installed total:$_ok"
[ -n "$_fail" ] && echo "[56] WARN: NOT installed total:$_fail" >&2
echo "[56] DONE"
