#!/bin/sh
# ncz-gpu-switcher.sh — select the CIX Sky1 GPU stack at boot, kernel + userspace.
#
# Design adopted from amazingfate's Sky1-Linux sky1-gpu-switcher (2026-08-15),
# because it fixes the failure mode our own two-tool arrangement kept producing.
#
# WHY THIS EXISTS
#   NCZ-OS ships both GPU stacks and exactly one may bind CIXH5000:
#     mali    : mali_kbase + memory_group_manager + protected_memory_allocator,
#               /dev/mali0, CIX proprietary GLES/OpenCL from /opt/cixgpu-*
#     panthor : mainline panthor DRM, /dev/dri/renderD*, Mesa panfrost + PanVK
#
#   Previously the choice lived in TWO places that could disagree: the rEFInd
#   kernel cmdline (module_blacklist=) and /etc/modprobe.d/ (written by
#   ncz-gpu-profile). Measured on O6N 2026-08-15, booted state was
#
#       cmdline               : module_blacklist=...,panthor    -> no panthor
#       ncz-gpu-profile.conf  : blacklist mali_kbase, mgm, pma  -> no kbase
#
#   so NEITHER driver loaded, /dev/mali0 was absent, kbase probe returned -517
#   and the session fell back to llvmpipe (glmark2 35). Both halves individually
#   looked correct; only their combination was fatal, which is precisely the
#   class of bug a single source of truth removes.
#
#   So: the kernel cmdline is the ONLY input. BOTH drivers are permanently
#   The two blacklist mechanisms are NOT equivalent, and the difference is what
#   makes this design work. Measured on O6N 2026-08-15 with panthor named in the
#   cmdline's module_blacklist=:
#
#       # modprobe panthor   -> exit 1, "Module panthor is blacklisted" (dmesg)
#
#   A kernel-cmdline module_blacklist= refuses the load outright, even an
#   explicit one. A modprobe.d `blacklist` only suppresses modalias autoload and
#   still permits an explicit modprobe. So the GPU drivers MUST be held in
#   modprobe.d rather than on the cmdline -- on the cmdline this script could
#   not load the winner at all.
#
#   blacklisted so udev can never autoload the loser, and this script loads the
#   winner explicitly. `blacklist` suppresses modalias autoload but does not
#   block an explicit modprobe, which is what makes that work -- do NOT add
#   `install <mod> /bin/true` lines, they would break the explicit load too.
#
# SELECTION (first match wins)
#   1. sky1.gpu=vendor|mesa   on the kernel cmdline  (Sky1-Linux compatible)
#   2. ncz.gpu=mali|panthor   on the kernel cmdline  (NCZ spelling, same thing)
#   3. GPU_MODE= in /etc/default/ncz-gpu
#   4. mali  -- the 26.7 shipped default
set -u

BLACKLIST=/etc/modprobe.d/ncz-gpu-drivers.conf
DEFAULTS=/etc/default/ncz-gpu
STATE=/etc/ncz-gpu-profile

# Userspace halves. These are toggled by .disabled rename rather than recreated,
# because 26-gpu-default-mali.sh bakes their content at build time and this
# script has no way to regenerate it faithfully.
LD_PRO=/etc/ld.so.conf.d/00-cixgpu-pro.conf
LD_COMPAT=/etc/ld.so.conf.d/01-cixgpu-compat.conf
ICD_MALI=/etc/vulkan/icd.d/mali.json
# CIX Vulkan WSI implicit layer. Implicit layers load regardless of which ICD is
# active, and this one aborts vkCreateInstance with ERROR_INCOMPATIBLE_DRIVER
# ("CIX driver check failed") once the blob is off the library path -- measured
# on O6N 2026-08-15, where disabling mali.json alone did not let PanVK start.
WSI_LAYER=/etc/vulkan/implicit_layer.d/VkLayer_window_system_integration.json
MESA_DEVSEL=/usr/share/vulkan/implicit_layer.d/VkLayer_MESA_device_select.json

# Obsolete selectors this script replaces. They must be REMOVED, not merely
# ignored: modprobe.d is additive and there is no un-blacklist, so a stale
# `blacklist mali_kbase` left by the retired ncz-gpu-profile silently wins over
# anything written here.
LEGACY="/etc/modprobe.d/ncz-gpu-profile.conf /etc/modprobe.d/ncz-gpu.conf"

LDCONFIG=$(command -v ldconfig 2>/dev/null || echo /sbin/ldconfig)

log() { echo "ncz-gpu-switcher: $*"; }

# --mode <m> overrides everything, for the runtime switch performed by the
# ncz-gpu-select shim. It does NOT persist: the next boot re-reads the cmdline.
OVERRIDE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --mode) OVERRIDE="${2:-}"; shift 2 ;;
        *)      shift ;;
    esac
done

get_mode() {
    mode="$OVERRIDE"
    [ -n "$mode" ] || mode=$(sed -n 's/.*\bsky1\.gpu=\([a-z]*\).*/\1/p' /proc/cmdline 2>/dev/null)
    [ -n "$mode" ] || mode=$(sed -n 's/.*\bncz\.gpu=\([a-z]*\).*/\1/p' /proc/cmdline 2>/dev/null)
    if [ -z "$mode" ] && [ -r "$DEFAULTS" ]; then
        mode=$(sed -n 's/^[[:space:]]*GPU_MODE=["'"'"']*\([a-z]*\).*/\1/p' "$DEFAULTS" | head -1)
    fi
    case "$mode" in
        vendor|mali)  echo mali ;;
        mesa|panthor) echo panthor ;;
        *)            echo mali ;;   # shipped default
    esac
}

ensure_blacklist() {
    cat > "$BLACKLIST" <<'BL'
# Written by ncz-gpu-switcher. Do not hand-edit -- set sky1.gpu= on the kernel
# cmdline (or GPU_MODE= in /etc/default/ncz-gpu) instead.
#
# BOTH GPU drivers are blacklisted on purpose: mali_kbase and panthor both claim
# ACPI CIXH5000, so whichever udev happened to autoload first would win the race
# and silently decide the machine's GPU stack. ncz-gpu-switcher.service loads the
# selected one explicitly at boot -- `blacklist` stops modalias autoload but does
# NOT block an explicit modprobe, which is what makes this work.
blacklist panthor
blacklist mali_kbase
blacklist memory_group_manager
blacklist protected_memory_allocator
BL
}

drop_legacy() {
    for f in $LEGACY; do
        [ -e "$f" ] || continue
        rm -f "$f"
        log "removed obsolete $f (stale blacklists there would override this switcher)"
        log "an initramfs rebuild is advisable: update-initramfs -u -k all"
    done
}

enable_file()  { [ -e "$1.disabled" ] && mv "$1.disabled" "$1"; return 0; }
disable_file() { [ -e "$1" ] && mv "$1" "$1.disabled"; return 0; }

activate_mali() {
    log "activating vendor Mali stack (mali_kbase + CIX proprietary userspace)"
    enable_file "$LD_PRO"
    enable_file "$LD_COMPAT"
    enable_file "$ICD_MALI"
    # WSI implicit layer stays disabled: unverified against our blob revision,
    # and VK_DRIVER_FILES already handles ICD discovery explicitly.
    disable_file "$WSI_LAYER"
    # Mesa's device-select layer is loaded implicitly even with the Mesa ICDs
    # unused, and picks a device the blob does not own.
    disable_file "$MESA_DEVSEL"
    "$LDCONFIG" 2>/dev/null || true

    modprobe -r panthor 2>/dev/null || true
    # Order matters: kbase probe returns -517 (-EPROBE_DEFER) and never retries
    # to completion if its two helpers are not already present. Measured on O6N.
    for m in memory_group_manager protected_memory_allocator mali_kbase; do
        modprobe "$m" 2>/dev/null || log "WARN: modprobe $m failed"
    done
}

activate_panthor() {
    log "activating open-source Panthor/Mesa stack"
    # The blob must leave the global library path entirely -- it sorts ahead of
    # Mesa in ld.so.conf order, so leaving it enabled means libEGL.so.1 still
    # resolves into /opt/cixgpu-* and abort()s hunting for /dev/mali0.
    disable_file "$LD_PRO"
    disable_file "$LD_COMPAT"
    disable_file "$ICD_MALI"
    disable_file "$WSI_LAYER"
    enable_file "$MESA_DEVSEL"
    "$LDCONFIG" 2>/dev/null || true

    for m in mali_kbase protected_memory_allocator memory_group_manager; do
        modprobe -r "$m" 2>/dev/null || true
    done
    modprobe panthor 2>/dev/null || log "WARN: modprobe panthor failed"
}

[ "$(id -u)" = 0 ] || { echo "ncz-gpu-switcher: must run as root" >&2; exit 1; }

drop_legacy
ensure_blacklist

mode=$(get_mode)
case "$mode" in
    mali)    activate_mali    ;;
    panthor) activate_panthor ;;
esac

echo "$mode" > "$STATE" 2>/dev/null || true
log "GPU stack set to $mode"
