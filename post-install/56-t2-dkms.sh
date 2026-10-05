#!/bin/bash
# 56-t2-dkms.sh — build+install the Apple T2 DKMS modules on T2 Mac hardware.
#
# WHY THIS EXISTS. We retired the in-tree applesmc driver in favour of t2smc
# (operator directive 2026-09-28, "for starters I would remove applesmc in
# favour of t2smc"), and built t2smc/t2gmux/t2smp/t2thunderbolt as DKMS
# modules. The DKMS sources were committed to assets/kernel/<name>/ and the
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

ASSETS=/usr/local/lib/cix-installer/assets/kernel
MODULES="t2smc t2gmux t2smp t2thunderbolt"

_vendor=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || true)
case "$_vendor" in
    *Apple*) ;;
    *) echo "[56] sys_vendor='$_vendor' is not Apple -- skipping T2 DKMS modules"; exit 0 ;;
esac

if ! command -v dkms >/dev/null 2>&1 && [ ! -x /usr/sbin/dkms ]; then
    echo "[56] WARN: dkms not present -- cannot install T2 modules; fans will not be controllable" >&2
    exit 0
fi
PATH="$PATH:/usr/sbin"   # dkms lives in /usr/sbin and is absent from some PATHs

KVER=$(ls -1 /lib/modules 2>/dev/null | grep -v -- '-rc' | sort -V | tail -1)
[ -n "$KVER" ] || KVER=$(uname -r)
echo "[56] installing T2 DKMS modules against $KVER"

_ok=""; _fail=""
for m in $MODULES; do
    src="$ASSETS/$m"
    if [ ! -f "$src/dkms.conf" ]; then
        echo "[56]   $m: no dkms.conf in $src -- skipping"; _fail="$_fail $m"; continue
    fi
    ver=$(sed -n 's/^PACKAGE_VERSION="\(.*\)"/\1/p' "$src/dkms.conf" | head -1)
    [ -n "$ver" ] || ver=0
    rm -rf "/usr/src/$m-$ver"
    mkdir -p "/usr/src/$m-$ver"
    cp -a "$src/dkms.conf" "/usr/src/$m-$ver/"
    [ -d "$src/src" ] && cp -a "$src/src/." "/usr/src/$m-$ver/"
    # dkms applies PATCH[0] relative to the source root; carry the patches dir.
    if [ -d "$src/patches" ]; then
        mkdir -p "/usr/src/$m-$ver/patches"
        cp -a "$src/patches/." "/usr/src/$m-$ver/patches/"
    fi
    if dkms add -m "$m" -v "$ver" >/dev/null 2>&1 || true; then :; fi
    if dkms build -m "$m" -v "$ver" -k "$KVER" >/dev/null 2>&1 \
       && dkms install -m "$m" -v "$ver" -k "$KVER" --force >/dev/null 2>&1; then
        _ok="$_ok $m/$ver"
    else
        echo "[56]   $m/$ver FAILED to build against $KVER" >&2
        _fail="$_fail $m"
    fi
done

[ -n "$_ok" ]   && echo "[56] installed:$_ok"
[ -n "$_fail" ] && echo "[56] WARN: NOT installed:$_fail" >&2

# t2smc is the one that matters for thermal safety -- say so loudly if absent.
case " $_fail " in
    *" t2smc "*)
        echo "[56] WARN: t2smc is MISSING -- the two chassis fans cannot be driven" >&2
        echo "[56]       and the machine will heat until it thermal-throttles." >&2 ;;
esac
echo "[56] DONE"
