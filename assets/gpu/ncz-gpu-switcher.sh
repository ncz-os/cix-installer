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
#
# The 7.3 'Panthor (Experimental)' boot entry selects this stack via
# sky1.gpu=panthor (the older rEFInd entries emitted the Sky1-Linux spelling
# sky1.gpu=mesa for the same entry; get_mode() below still accepts both).
# Do NOT change the mali default here: the Mali (Default) entry and every
# fallback path must keep behaving exactly as they do today.
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

# glvnd EGL vendor for the Mali blob. libglvnd only scans /usr/share/glvnd/egl_vendor.d (Mesa) and /etc/glvnd/
# egl_vendor.d by default; the CIX vendor file lives under /opt and was found only where __EGL_VENDOR_LIBRARY_FILENAMES
# was exported (the compositor session). Every other process (ssh, cron, systemd --user, D-Bus activation, portals,
# flatpak, autostart) therefore got Mesa's llvmpipe on a Mali board. A 10_ entry in /etc sorts ahead of 50_mesa, so
# Mali wins with no environment at all; when the blob cannot load (KVM, no GPU) glvnd falls through to Mesa. The
# entry exists ONLY while Mali is the selected stack, otherwise it would be tried first on a Panthor boot.
EGL_SRC=${NCZ_EGL_VENDOR_SRC:-/opt/cixgpu-compat/share/glvnd/egl_vendor.d/40_cix.json}
EGL_LINK=${NCZ_EGL_VENDOR_LINK:-/etc/glvnd/egl_vendor.d/10_cix.json}
egl_vendor_on() {
    [ -r "$EGL_SRC" ] || { log "WARN: $EGL_SRC missing; Mali EGL vendor NOT registered system-wide"; return 0; }
    mkdir -p "$(dirname "$EGL_LINK")"
    ln -sfn "$EGL_SRC" "$EGL_LINK"
}
egl_vendor_off() { rm -f "$EGL_LINK"; }

log() { echo "ncz-gpu-switcher: $*"; }
# Errors go to stderr so the unit's StandardError=journal+console surfaces them
# on a degraded boot, where the journal is the harder place to look.
err() { echo "ncz-gpu-switcher: $*" >&2; }

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
        # The RESCUE entry disables every accelerator, so there is deliberately
        # nothing to load. Without this the switcher would try the shipped
        # default, fail against the cmdline module_blacklist, and exit non-zero
        # -- a failed unit on the one boot entry that must never look broken.
        none|off)     echo none ;;
        *)            echo mali ;;   # shipped default
    esac
}

ensure_blacklist() {
    # $1 is the mode the switcher is about to apply (mali|panthor|none).
    #
    # MINOR-003: the "Selected:" line at the bottom is the switcher's OWN record
    # of which stack it applied, in the same file that holds the pair. Until now
    # the selection existed only as the bootloader's sky1.gpu= token (or
    # GPU_MODE= in /etc/default/ncz-gpu), so a post-install hook running on a
    # live system, a later `modprobe`, or an operator reading modprobe.d had no
    # on-disk statement of intent: on the Panthor entry the cmdline no longer
    # names mali_kbase (r201 removed it so the Mali fallback stays possible) and
    # nothing reads the sky1.gpu= token back.
    #
    # Both losers stay named by `blacklist` -- mali_kbase on a Panthor boot
    # included, because that line is what stops a udev modalias event from
    # auto-binding CIXH5000 out from under Mesa. `blacklist` only suppresses
    # modalias autoload; it does NOT block an explicit modprobe, so
    # activate_panthor()'s load and the Mali fallback's `modprobe mali_kbase`
    # both still work. Never write `install <mod> /bin/true` here.
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
    case "${1:-}" in
        mali)
            cat >> "$BLACKLIST" <<'BL'

# Selected: mali (vendor Mali stack). ncz-gpu-switcher loaded mali_kbase here.
BL
            ;;
        panthor)
            cat >> "$BLACKLIST" <<'BL'

# Selected: panthor (Mesa). ncz-gpu-switcher loaded this stack on this boot.
# mali_kbase is held by the blacklist above so nothing autoloads it; an
# explicit modprobe still loads it, which is what the Mali fallback relies on.
BL
            ;;
    esac
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

# Unload the kbase trio, youngest first. Reports the busy case loudly instead of
# swallowing it: if something still holds /dev/mali0 (a compositor from the
# previous mode, typically) the unload fails, the incoming driver cannot claim
# CIXH5000, and the only symptom would otherwise be a silently wrong driver.
unload_kbase() {
    if [ -e /dev/mali0 ] && command -v fuser >/dev/null 2>&1; then
        holders=$(fuser /dev/mali0 2>/dev/null)
        [ -n "$holders" ] && log "WARN: /dev/mali0 is held by pid(s):$holders -- unload will likely fail"
    fi
    for m in mali_kbase protected_memory_allocator memory_group_manager; do
        lsmod 2>/dev/null | grep -q "^$m " || continue
        modprobe -r "$m" 2>/dev/null || log "WARN: could not unload $m (in use?)"
    done
}

# Is the selected stack ACTUALLY live? The whole point of this rewrite is that a
# boot must never silently continue on llvmpipe, so the answer is checked rather
# than assumed from a modprobe that returned 0.
# Is a DRM card actually driven by <driver>? linlondp is ALWAYS present on Sky1
# -- it is the display controller, and it owns card0/renderD128 whether or not a
# GPU ever binds. So "a renderD* node exists" proves nothing here; the node has
# to belong to the driver we asked for.
drm_card_driven_by() {
    for _dev in /sys/class/drm/card*/device/driver; do
        [ -e "$_dev" ] || continue
        case "$(basename "$(readlink -f "$_dev")")" in
            "$1") return 0 ;;
        esac
    done
    return 1
}

# Is the selected stack ACTUALLY live? The whole point of this rewrite is that a
# boot must never silently continue on llvmpipe, so the answer is checked rather
# than assumed from a modprobe that returned 0.
#
# BOTH branches must test BINDING, not just loading. The panthor branch used to
# check `lsmod` alone. Measured on O6N 2026-08-19: panthor loaded with refcnt 0
# and never bound to CIXH5000:00, /sys/class/drm showed only linlondp, greetd hit
# its restart limit and the screen stayed black -- while this function returned
# true and the script logged "GPU stack set to panthor" and exited 0. A module
# that is resident but bound to nothing drives no pixels.
driver_live() {
    case "$1" in
        mali)
            lsmod 2>/dev/null | grep -q "^mali_kbase " || return 1
            [ -e /dev/mali0 ] || return 1
            ;;
        panthor)
            lsmod 2>/dev/null | grep -q "^panthor " || return 1
            # Bound to the GPU's ACPI-instantiated platform device...
            [ -e /sys/bus/platform/drivers/panthor/CIXH5000:00 ] || return 1
            # ...and actually presenting a DRM card. Both, because a bind link
            # can exist while probe is still unwinding.
            drm_card_driven_by panthor || return 1
            ;;
        *)  return 1 ;;
    esac
    return 0
}

# Does this kernel even ship the driver? Distinguishes "we failed" from "there
# is nothing to load" -- the CONSOLE and RESCUE entries, and any LTS kernel
# without the kbase DKMS build, legitimately reach the second case and must not
# fail the unit for it.
#
# DO NOT USE modinfo HERE. O6N has no kmod modinfo at all:
#     $ modinfo panthor
#     bash: modinfo: command not found
# The previous implementation called it and therefore answered "not available"
# for every driver on every kernel, which disarmed the loud-failure branch at
# the bottom of this script: a genuinely unbound driver was reported as simply
# absent, and the unit exited 0. Look for the module FILE instead, which needs
# nothing but the shell.
driver_available() {
    case "$1" in
        mali)    _mod=mali_kbase ;;
        panthor) _mod=panthor    ;;
        *)       return 1 ;;
    esac
    # Fast path when kmod IS present (other hosts have it).
    if command -v modinfo >/dev/null 2>&1; then
        modinfo "$_mod" >/dev/null 2>&1 && return 0
    fi
    # A module already resident is available by definition, whatever is on disk.
    lsmod 2>/dev/null | grep -q "^$_mod " && return 0
    # Otherwise: is the .ko on disk for the RUNNING kernel? Covers .ko, .ko.xz,
    # .ko.zst, and both the in-tree path and updates/dkms/.
    _kver=$(uname -r)
    for _ext in "" .xz .zst .gz; do
        for _hit in $(find "/lib/modules/$_kver" -name "$_mod.ko$_ext" -print -quit 2>/dev/null); do
            [ -n "$_hit" ] && return 0
        done
    done
    return 1
}

userspace_mali() {
    enable_file "$LD_PRO"
    # LD_COMPAT (01-cixgpu-compat.conf) is DELIBERATELY NEVER TOUCHED HERE.
    # BUG FIXED 2026-09-16 (real, metal-verified on O6N): this used to
    # enable_file it on every boot, which directly undid
    # post-install/26-gpu-default-mali.sh's own, deliberate, extensively
    # metal-verified (2026-09-04) decision to leave it disabled --
    # /opt/cixgpu-compat is a COMPLETE second GL stack (cix-libglvnd 1.7.0
    # + cix-mesa 24.0.4) that conflicts with the system's real glvnd/Mesa
    # 26.x + GTK 4.22, and that hook's own header documents the exact
    # failure mode re-enabling it causes: "Could not initialize EGL
    # display" / labwc SIGSEGV inside libEGL's __eglLoadVendors, greetd
    # start-limit-hit, black screen. This switcher was reintroducing that
    # exact regression every single boot regardless of what the build
    # baked in. Leave LD_COMPAT in whatever state 26-gpu-default-mali.sh
    # set at install time -- this switcher has no business overriding it.
    enable_file "$ICD_MALI"
    egl_vendor_on
    # WSI implicit layer stays disabled: unverified against our blob revision,
    # and VK_DRIVER_FILES already handles ICD discovery explicitly.
    disable_file "$WSI_LAYER"
    # Mesa's device-select layer is loaded implicitly even with the Mesa ICDs
    # unused, and picks a device the blob does not own.
    disable_file "$MESA_DEVSEL"
    "$LDCONFIG" 2>/dev/null || true
}

activate_mali() {
    log "activating vendor Mali stack (mali_kbase + CIX proprietary userspace)"
    userspace_mali

    modprobe -r panthor 2>/dev/null || true

    # Unload any existing kbase trio before loading it. modprobe is a no-op for
    # an already-loaded module, so without this a kbase left wedged in
    # -EPROBE_DEFER by an earlier run is never re-probed: the loop below would
    # succeed silently and leave nothing bound.
    unload_kbase

    # Order matters: kbase probe returns -517 (-EPROBE_DEFER) and never retries
    # to completion if its two helpers are not already present. Measured on O6N.
    for m in memory_group_manager protected_memory_allocator mali_kbase; do
        modprobe "$m" 2>/dev/null || log "WARN: modprobe $m failed"
    done
}

userspace_panthor() {
    # The blob must leave the global library path entirely -- it sorts ahead of
    # Mesa in ld.so.conf order, so leaving it enabled means libEGL.so.1 still
    # resolves into /opt/cixgpu-* and abort()s hunting for /dev/mali0.
    disable_file "$LD_PRO"
    # LD_COMPAT: not touched here either -- see userspace_mali()'s comment.
    # This was already correctly a no-op in practice (26-gpu-default-mali.sh
    # leaves it disabled at build time), kept out of both functions now for
    # symmetry and so neither GPU mode can ever re-enable it again.
    disable_file "$ICD_MALI"
    egl_vendor_off
    disable_file "$WSI_LAYER"
    enable_file "$MESA_DEVSEL"
    "$LDCONFIG" 2>/dev/null || true
}

activate_panthor() {
    log "activating open-source Panthor/Mesa stack"
    userspace_panthor

    unload_kbase
    modprobe panthor 2>/dev/null || log "WARN: modprobe panthor failed"
}

[ "$(id -u)" = 0 ] || { echo "ncz-gpu-switcher: must run as root" >&2; exit 1; }

# Not a CIX Sky1 board: nothing to switch. The unit carries
# ConditionPathExists=/sys/bus/platform/devices/CIXH5000:00, so systemd never
# even starts this script off Sky1; this guard is for the direct runs
# (`ncz-gpu-select`'s shim, a human, a first-boot hook) that bypass the unit.
# Same probe as ncz-gpu-status / ncz-gpu-hw-present: Sky1 is ACPI (acpi=force),
# so the firmware-instantiated CIX GPU platform device is the identifier --
# a device-tree HID does not exist on this platform. Exit 0, never 1: an
# unsupported machine is not a broken GPU stack, and the old exit 1 is what
# made the generic-arm64 KVM gate report "loaded failed failed".
# Test seam: NCZ_SYSROOT prefixes /sys.
if [ ! -e "${NCZ_SYSROOT:-}/sys/bus/platform/devices/CIXH5000:00" ]; then
    log "no CIX Sky1 GPU (no /sys/bus/platform/devices/CIXH5000:00) -- not Sky1 hardware, nothing to switch"
    exit 0
fi

drop_legacy

mode=$(get_mode)
# AFTER the mode is known: the file records the selection (MINOR-003), so it
# must be written by the branch that actually knows which stack won.
ensure_blacklist "$mode"
# Written only when a Panthor request fell back to Mali (below); read by ncz-gpu-status.
FALLBACK_NOTE=/run/ncz-gpu-fallback
rm -f "$FALLBACK_NOTE" 2>/dev/null
if [ "$mode" = none ]; then
    log "sky1.gpu=none -- accelerators disabled by the boot entry, loading nothing"
    echo none > "$STATE" 2>/dev/null || true
    exit 0
fi

case "$mode" in
    mali)    activate_mali    ;;
    panthor) activate_panthor ;;
esac

# Fail loudly rather than reporting a success the desktop will contradict. An
# activate_* that only logged warnings used to exit 0, so systemd marked the
# unit active, the journal said "GPU stack set to mali", and the user got
# llvmpipe -- the exact silent-fallback class this rewrite exists to remove.
if driver_live "$mode"; then
    echo "$mode" > "$STATE" 2>/dev/null || true
    log "GPU stack set to $mode"
    exit 0
fi

# Panthor was asked for (sky1.gpu=mesa / ncz.gpu=panthor / GPU_MODE=panthor) but
# is not bound, and nothing else is: fall back to Mali when its module exists.
# The standing rule is never to software-render on a machine that has a GPU,
# and measured on O6N 2026-10-07 (r201) the "7.3 Panthor (Experimental)" entry
# booted a 7.3 kernel with no panthor.ko at all (panthor-cix-dkms 7.2.0 does
# not build on 7.3): the old path logged "no panthor driver on this kernel",
# exited 0, and the desktop ran on llvmpipe until greetd hit its start limit.
# Mali can only be loaded if the boot entry did not hard-block it with a
# cmdline module_blacklist= (a modprobe.d blacklist does not stop the explicit
# load below); the generator stopped putting the kbase trio there in r201.
cmdline_blacklists() {
    sed -n 's/.*\bmodule_blacklist=\([^ ]*\).*/\1/p' /proc/cmdline 2>/dev/null | tr ',' '\n' | grep -qx "$1"
}
if [ "$mode" = panthor ] && ! driver_live mali && driver_available mali; then
    if driver_available panthor; then
        why="panthor is installed for $(uname -r) but did not bind to the GPU"
    else
        why="no panthor module for $(uname -r)"
    fi
    if cmdline_blacklists mali_kbase; then
        err "ERROR: Panthor selected but $why, and this boot entry's module_blacklist= blocks mali_kbase,"
        err "ERROR: so there is no GPU driver: boot the Mali (Default) entry. Rendering is in SOFTWARE."
        exit 1
    fi
    err "WARN: Panthor selected but $why -- falling back to the Mali stack (no software rendering with a GPU present)"
    modprobe -r panthor 2>/dev/null || true
    activate_mali
    if driver_live mali; then
        echo mali > "$STATE" 2>/dev/null || true
        echo "selected panthor, fell back to mali: $why" > "$FALLBACK_NOTE" 2>/dev/null || true
        log "GPU stack set to mali (fallback from panthor: $why)"
        exit 0
    fi
    err "ERROR: Mali fallback also failed to bind; see dmesg | grep -iE 'mali|panthor'"
    err "ERROR: a GPU driver is installed but none is bound -- rendering is in SOFTWARE."
    exit 1
fi

# The requested driver is not bound. Leaving the userspace half where it was
# just pointed would strand the machine half-switched -- blob userspace over a
# panthor node, or Mesa over kbase -- which is the failure this whole design
# exists to prevent. So realign userspace to whatever IS actually bound.
if [ "$mode" = panthor ] && driver_live mali; then
    userspace_mali
    echo mali > "$STATE" 2>/dev/null || true
    log "WARN: panthor did not bind; mali is still live, so userspace was put back on the blob"
elif [ "$mode" = mali ] && driver_live panthor; then
    userspace_panthor
    echo panthor > "$STATE" 2>/dev/null || true
    log "WARN: mali did not bind; panthor is still live, so userspace was put back on Mesa"
fi

if driver_available "$mode"; then
    err "ERROR: selected '$mode' but its driver is NOT bound after loading."
    err "ERROR: the desktop would fall back to llvmpipe. Check: ncz-gpu-status,"
    err "ERROR: dmesg | grep -iE 'panthor|mali', and whether /dev/mali0 was held."
    exit 1
fi

log "no $mode driver on this kernel (module not present) -- nothing loaded"
exit 0
