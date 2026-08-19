#!/bin/bash
# dkms-abi-gate.sh — refuse to ship a kernel whose STAGED HEADERS do not come
# from the SAME BUILD as the kernel image.
#
# WHY THIS EXISTS (measured on O6N, 2026-08-19). r245 shipped a Panthor boot
# entry that Oopses on probe and reboot-loops the board:
#
#   panthor CIXH5000:00: entity with out-of-bounds priority:0 num_user_rqs:0
#   Unable to handle kernel NULL pointer dereference at virtual address 0000000000000010
#   Internal error: Oops: 0000000096000004 [#1] SMP
#
# Panthor probed correctly right up to that line -- clock, SMC power domain 21,
# ACPI _PR0 un-secure, core harvesting, Mali-G720 ID, ACE-Lite coherency all
# fine. It died at the LAST step, drm_sched entity init.
#
# ROOT CAUSE was not the driver. It was provenance:
#
#   /boot/vmlinuz-7.2.0-sky1-ncz      built Aug 16 21:32  (uname -v agrees)
#   .../scheduler/gpu-sched.ko.xz     built Aug 16 21:32  (ships WITH the kernel)
#   .../build/include/drm/...h        staged Aug 18 04:09 (a NEWER source tree)
#   .../updates/dkms/panthor.ko.xz    built  Aug 18 04:10 (against those headers)
#
# The staged headers described a newer struct drm_gpu_scheduler (the one with
# the FAIR policy and num_rqs/num_user_rqs) than the gpu-sched.ko actually
# running. DKMS compiled panthor against the wrong layout, so it read
# num_user_rqs from the wrong offset, got 0, and drm_sched_entity_init()
# rejected it into a NULL deref.
#
# CONFIG_MODVERSIONS is not set on this kernel, so there was NO symbol-CRC check
# to refuse the load. The module loaded happily and corrupted instead.
#
# WHY A BOOT GATE CANNOT CATCH THIS: build/kvm-kernel-gate.sh boots the Image
# under qemu -M virt, which does not model Sky1's CIXH5000 GPU. panthor never
# probes there, so the crash never happens in the gate -- the same reason that
# gate needed a static PCI-ID lint for the r236 cdns3 collision. Structurally
# identical problem, so: static check, not a boot test.
#
# WHAT THIS CHECKS: the kernel image and the staged headers must report the SAME
# UTS_VERSION -- the "#N SMP PREEMPT <date>" build stamp, which changes on every
# kernel build. Equal stamps mean one build produced both. Different stamps mean
# DKMS is about to compile against a kernel that is not the one that boots.
#
# Usage:
#   build/dkms-abi-gate.sh <kernel-image> <staged-headers-dir> [--config <.config>]
set -euo pipefail

die()  { echo "dkms-abi-gate: FAIL: $*" >&2; exit 1; }
warn() { echo "dkms-abi-gate: WARN: $*" >&2; }
ok()   { echo "dkms-abi-gate: ok: $*"; }

IMAGE="${1:-}"
HDRS="${2:-}"
CONFIG=""
shift 2 2>/dev/null || true
while [ $# -gt 0 ]; do
    case "$1" in
        --config) CONFIG="${2:-}"; shift 2 ;;
        *) shift ;;
    esac
done

[ -n "$IMAGE" ] && [ -f "$IMAGE" ] || die "kernel image not found: ${IMAGE:-<unset>}"
[ -n "$HDRS" ]  && [ -d "$HDRS" ]  || die "staged headers dir not found: ${HDRS:-<unset>}"

# --- 1. build identity from the staged headers ----------------------------
# NOT UTS_VERSION: this kernel's include/generated/compile.h does not carry it
# (newer trees emit UTS_VERSION into vmlinux, not compile.h). What compile.h
# DOES carry is who built it and with what, and that is enough -- two different
# build environments cannot produce the same triple by accident.
CH="$HDRS/include/generated/compile.h"
[ -f "$CH" ] || die "no include/generated/compile.h under $HDRS -- cannot establish header provenance"

hdr_field() { sed -n "s/^#define $1[[:space:]]*\"\(.*\)\"$/\1/p" "$CH" | head -1; }
H_BY="$(hdr_field LINUX_COMPILE_BY)"
H_HOST="$(hdr_field LINUX_COMPILE_HOST)"
H_CC="$(hdr_field LINUX_COMPILER)"
[ -n "$H_CC" ] || die "could not read LINUX_COMPILER from $CH"

# --- 2. the same identity out of the kernel image -------------------------
# The banner is: Linux version <rel> (<by>@<host>) (<compiler>) #N SMP ...
extract_banner() {
    strings -a "$1" 2>/dev/null | grep -m1 -E '^Linux version [0-9]' || true
}
BANNER="$(extract_banner "$IMAGE")"
if [ -z "$BANNER" ]; then
    TMP="$(mktemp)"; trap 'rm -f "$TMP"' EXIT
    if gzip -dc "$IMAGE" > "$TMP" 2>/dev/null || zstd -dc "$IMAGE" > "$TMP" 2>/dev/null; then
        BANNER="$(extract_banner "$TMP")"
    fi
fi
[ -n "$BANNER" ] || die "could not find a 'Linux version' banner in $IMAGE"

# --- 3. compare -----------------------------------------------------------
echo "  image banner  : $BANNER"
echo "  header built by: ${H_BY}@${H_HOST}"
echo "  header compiler: $H_CC"

MISMATCH=0

# 3a. builder identity. The banner spells it "(by@host)".
if [ -n "$H_BY" ] && [ -n "$H_HOST" ]; then
    case "$BANNER" in
        *"(${H_BY}@${H_HOST})"*) ok "builder identity matches (${H_BY}@${H_HOST})" ;;
        *) echo "dkms-abi-gate: MISMATCH builder: headers say ${H_BY}@${H_HOST}, image says otherwise" >&2
           MISMATCH=1 ;;
    esac
fi

# 3b. toolchain. Compare the binutils version, which is the part that differs
# between an OE cross-build and a native Debian rebuild and is present in both
# strings verbatim.
H_LD="$(printf '%s' "$H_CC" | grep -oE 'GNU Binutils[^)]*\) [0-9][0-9.]*' | grep -oE '[0-9][0-9.]*$' || true)"
I_LD="$(printf '%s' "$BANNER" | grep -oE 'GNU Binutils[^)]*\) [0-9][0-9.]*' | grep -oE '[0-9][0-9.]*$' || true)"
if [ -n "$H_LD" ] && [ -n "$I_LD" ]; then
    if [ "$H_LD" = "$I_LD" ]; then
        ok "binutils matches ($H_LD)"
    else
        echo "dkms-abi-gate: MISMATCH binutils: headers=$H_LD image=$I_LD" >&2
        MISMATCH=1
    fi
fi

if [ "$MISMATCH" != 0 ]; then
    echo "" >&2
    echo "dkms-abi-gate: the staged kernel headers were NOT produced by the build" >&2
    echo "that made this kernel image. Every DKMS module (panthor, cix-gpu-kmd," >&2
    echo "cix-vpu-driver, aipu) would compile against the wrong struct layouts." >&2
    echo "" >&2
    echo "This is exactly how r245 shipped a Panthor entry that Oopses in" >&2
    echo "drm_sched_entity_init with num_user_rqs:0 and reboot-loops the board:" >&2
    echo "the image was an OE cross-build (oe-user@oe-host, binutils 2.46.1)" >&2
    echo "while the staged headers came from a native Debian rebuild" >&2
    echo "(root@ncz-setup, binutils 2.47)." >&2
    echo "" >&2
    echo "Fix: stage include/ from the SAME tree that built this image, then" >&2
    echo "rebuild every DKMS module against it." >&2
    die "header/image build mismatch"
fi

# --- 4. runtime backstop: CONFIG_MODVERSIONS ------------------------------
# Provenance matching is the primary defence. MODVERSIONS is the net under it:
# with symbol CRCs on, a mismatched module REFUSES to load with an explicit
# "disagrees about version of symbol" instead of loading and corrupting. On
# r245 it was off, which is why a wrong-layout panthor loaded at all.
if [ -n "$CONFIG" ] && [ -f "$CONFIG" ]; then
    if grep -q '^CONFIG_MODVERSIONS=y' "$CONFIG"; then
        ok "CONFIG_MODVERSIONS=y (mismatched modules will refuse to load)"
    else
        warn "CONFIG_MODVERSIONS is NOT set in $CONFIG."
        warn "Without it there is no symbol-CRC check, so a module built against"
        warn "different headers LOADS SILENTLY and corrupts -- the r245 panthor"
        warn "NULL deref. This gate catches the staging mistake, but MODVERSIONS"
        warn "is what catches everything it cannot see."
    fi
fi

echo "dkms-abi-gate: PASS"
