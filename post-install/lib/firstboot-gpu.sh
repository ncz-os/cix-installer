#!/bin/bash
# post-install/lib/firstboot-gpu.sh -- the package-configure step of
# ncz-firstboot, with an on-screen explanation whenever a DKMS kernel-module
# build is involved (docs/GPU-INSTALL-PROGRESS.md, "First boot").
#
#   bash firstboot-gpu.sh configure
#
# ncz-firstboot (preseed/extract-rootfs.sh and its live twin in
# build/iso/patch-debootstrap-stub.py) calls this instead of a bare
# `dpkg --configure -a` when the file exists, and falls back to the bare
# command when it does not (older payloads).
#
# What it does, from lib/dkms-pending.sh's classification of the DKMS
# packages dpkg left unconfigured at install time:
#
#   nothing pending  plain `dpkg --configure -a`, no message (most machines).
#
#   failed           the install-time build for THIS kernel stopped on a
#                    compiler error. A rebuild from the same driver source,
#                    kernel headers and compiler fails the same way (the GU502LV laptop
#                    2026-10-06: ~60 s each time, identical error), so first
#                    boot does NOT run it in front of the login screen: those
#                    packages are left to their owner (NVIDIA: ncz-cuda-setup,
#                    which rebuilds once the kernel or the driver changes) and
#                    everything else is configured.
#                    One console line says why the GPU driver is missing.
#
#   needed           a build that never ran or stopped without a compiler
#                    error, and so may well succeed: it runs here, before the
#                    login screen (ncz-firstboot is ordered before
#                    display-manager.service), with a live status line on the
#                    console / splash fed by lib/gpu-progress.sh's DKMS
#                    monitor, and nothing ever cuts it short (the unit has
#                    TimeoutStartSec=infinity). Blocking is deliberate: on a
#                    machine whose only display GPU is the NVIDIA one the
#                    greeter would otherwise come up without its driver.
#                    After a successful build an NVIDIA display device that
#                    no driver has claimed yet gets the module loaded now
#                    (what udev would have done at boot had the module
#                    existed); one already claimed by another driver switches
#                    at the next restart. Nothing reboots on its own.
#
# On-screen channel: `plymouth display-message` when plymouthd answers
# `plymouth --ping`; otherwise a plain line on /dev/console. (amd64 images
# replace Plymouth with the native singularity-boot-splash, which has no
# message API and exits after at most ~22 s; the console lines then show on
# the otherwise black screen.) Every line also goes to stdout (the journal)
# and to $NCZ_FBG_LOG.

set -u
export LC_ALL=C DEBIAN_FRONTEND=noninteractive

NCZ_FBG_ROOT="${NCZ_FBG_ROOT:-}"                 # test hook: dpkg/dkms root
NCZ_FBG_LIBDIR="${NCZ_FBG_LIBDIR:-$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")}"
NCZ_FBG_LOG="${NCZ_FBG_LOG:-/var/log/ncz-firstboot-gpu.log}"
NCZ_FBG_RUN="${NCZ_FBG_RUN:-/run/ncz-firstboot-gpu}"
NCZ_FBG_CONSOLE="${NCZ_FBG_CONSOLE:-/dev/console}"
NCZ_FBG_POLL="${NCZ_FBG_POLL:-3}"
NCZ_FBG_KVER="${NCZ_FBG_KVER:-$(uname -r)}"
NCZ_FBG_DPKG="${NCZ_FBG_DPKG:-dpkg}"
NCZ_FBG_PLYMOUTH="${NCZ_FBG_PLYMOUTH:-plymouth}"
NCZ_FBG_MODPROBE="${NCZ_FBG_MODPROBE:-modprobe}"
NCZ_FBG_SYSFS_PCI="${NCZ_FBG_SYSFS_PCI:-/sys/bus/pci/devices}"
FBG_BG_PIDS=""

# shellcheck source=dkms-pending.sh
. "$NCZ_FBG_LIBDIR/dkms-pending.sh"

_fbg_plymouth_up() { command -v "$NCZ_FBG_PLYMOUTH" >/dev/null 2>&1 && "$NCZ_FBG_PLYMOUTH" --ping >/dev/null 2>&1; }

# fbg_say <text>: one status line to the screen, the journal and the log.
fbg_say() {
    local t
    t=$(ncz_ascii "$*" | cut -c1-400)
    printf 'ncz-firstboot: %s\n' "$t"
    printf '%s %s\n' "$(date -u +%FT%TZ)" "$t" >> "$NCZ_FBG_LOG" 2>/dev/null || true
    if _fbg_plymouth_up; then
        "$NCZ_FBG_PLYMOUTH" display-message --text="$t" >/dev/null 2>&1 || true
    else
        printf '\r\n  NCZ-OS: %s\r\n' "$t" >> "$NCZ_FBG_CONSOLE" 2>/dev/null || true
    fi
}

# NVIDIA display-class PCI devices with no bound driver.
_fbg_unclaimed_nvidia() {
    local d
    for d in "$NCZ_FBG_SYSFS_PCI"/*; do
        [ "$(cat "$d/vendor" 2>/dev/null)" = 0x10de ] || continue
        case "$(cat "$d/class" 2>/dev/null)" in 0x0300*|0x0302*|0x0380*) ;; *) continue ;; esac
        { [ -e "$d/driver" ] || [ -L "$d/driver" ]; } && continue
        printf '%s\n' "${d##*/}"
    done
}

_fbg_module_built() {   # <name> <version>: dkms installed a module for this kernel
    ls "$NCZ_FBG_ROOT/$NCZ_DKMS_TREE_REL/$1/$2/$NCZ_FBG_KVER"/*/module/*.ko* >/dev/null 2>&1
}

# Relay lib/gpu-progress.sh's live status (field 10 of its progress record)
# to the screen while the build runs. Runs in the background; exact-PID kill.
_fbg_relay() {
    local state="$1" parent="$2" last="" now t lastt=0 s=""
    # sleep in the background + wait, so TERM stops the relay at once and the
    # pending sleep is reaped by exact PID (nothing left in the unit's cgroup)
    trap '[ -n "$s" ] && kill "$s" 2>/dev/null; exit 0' TERM
    while :; do
        sleep "$NCZ_FBG_POLL" & s=$!
        wait "$s" 2>/dev/null
        kill -0 "$parent" 2>/dev/null || exit 0   # helper gone: stop too
        [ -r "$state" ] || continue
        t=$(awk -F'|' '{ print $10 }' "$state" 2>/dev/null)
        now=$(date +%s)
        # repeat the line every 15 s too: the native splash can paint over it
        if [ -n "$t" ] && { [ "$t" != "$last" ] || [ $((now - lastt)) -ge 15 ]; }; then
            fbg_say "$t"
            last="$t"; lastt=$now
        fi
    done
}

fbg_configure() {
    local cls failed needed keep pkgs p mon="" relay="" rc=0 st n v k why pci what noun="GPU drivers"
    mkdir -p "$(dirname "$NCZ_FBG_LOG")" "$NCZ_FBG_RUN" 2>/dev/null || true
    cls=$(ncz_dkms_classify "$NCZ_FBG_ROOT" "$NCZ_FBG_KVER")
    if [ -z "$cls" ]; then
        "$NCZ_FBG_DPKG" --configure -a 2>/dev/null || true
        return 0
    fi
    printf '%s\n' "$cls" >> "$NCZ_FBG_LOG" 2>/dev/null || true
    failed=$(printf '%s\n' "$cls" | awk -F'|' '$1 == "failed" { print $2 }')
    needed=$(printf '%s\n' "$cls" | awk -F'|' '$1 == "needed" { printf "%s%s %s", (c++ ? ", " : ""), $3, $4 }')

    # Known-failed builds first: say so, and keep them out of this run.
    while IFS='|' read -r st p n v k why; do
        [ "$st" = failed ] || continue
        fbg_say "$(ncz_dkms_failed_line "$NCZ_FBG_ROOT" "$p" "$n" "$v" "$why")"
    done <<< "$cls"

    if [ -n "$needed" ]; then
        noun=$(ncz_dkms_noun "$cls" needed)
        fbg_say "Finishing ${noun%s} setup: DKMS build of $needed. The login screen appears when it is done (several minutes). Do not power off."
        if [ -r "$NCZ_FBG_LIBDIR/gpu-progress.sh" ]; then
            : > "$NCZ_FBG_RUN/progress.state"
            NCZ_PROGRESS_FILE="$NCZ_FBG_RUN/progress.state" NCZ_PROGRESS_LOG="" \
            NCZ_PROGRESS_HOOK=ncz-firstboot NCZ_PROGRESS_INDEX=1 NCZ_PROGRESS_TOTAL=1 \
            NCZ_GPU_DKMS_ROOT="$NCZ_FBG_ROOT/$NCZ_DKMS_TREE_REL" NCZ_TTY=/dev/null \
            NCZ_GPU_LOG="$NCZ_FBG_LOG" NCZ_GPU_RESULTS="$NCZ_FBG_RUN/results" \
            NCZ_GPU_PARENT="$$" NCZ_GPU_EXPECT_BUILD=1 NCZ_GPU_SHORT="${noun^}" \
            NCZ_GPU_LABEL="Finishing ${noun%s} setup (DKMS build)" \
                bash "$NCZ_FBG_LIBDIR/gpu-progress.sh" watch </dev/null >/dev/null 2>&1 &
            mon=$!
            _fbg_relay "$NCZ_FBG_RUN/progress.state" "$$" </dev/null &
            relay=$!
            # an interrupted helper must not leave either one behind
            FBG_BG_PIDS="$mon $relay"
            # (bash runs a TERM/INT trap once the foreground dpkg returns; the
            # status keeps flowing until then, which is what the screen needs)
            trap 'for _b in $FBG_BG_PIDS; do kill -TERM "$_b" 2>/dev/null; done' EXIT
            trap 'exit 143' TERM INT
        fi
    fi

    # Configure everything except the known-failed DKMS packages (their
    # dependents then stop at once on "dependency problems", which is fine:
    # the background retry configures them together later).
    if [ -z "$failed" ]; then
        "$NCZ_FBG_DPKG" --configure -a >> "$NCZ_FBG_LOG" 2>&1 || rc=$?
    else
        pkgs=""
        for p in $(ncz_pkgs_needing_configure "$NCZ_FBG_ROOT"); do
            keep=1
            for k in $failed; do [ "${p%%:*}" = "$k" ] && keep=0; done
            [ "$keep" = 1 ] && pkgs="$pkgs $p"
        done
        if [ -n "$pkgs" ]; then
            # shellcheck disable=SC2086
            "$NCZ_FBG_DPKG" --configure $pkgs >> "$NCZ_FBG_LOG" 2>&1 || rc=$?
        fi
    fi

    if [ -n "$mon" ]; then kill -TERM "$mon" 2>/dev/null; wait "$mon" 2>/dev/null; fi
    if [ -n "$relay" ]; then kill -TERM "$relay" 2>/dev/null; wait "$relay" 2>/dev/null; fi
    FBG_BG_PIDS=""; trap - EXIT TERM INT

    [ -n "$needed" ] || return 0
    while IFS='|' read -r st p n v k why; do
        [ "$st" = needed ] || continue
        if _fbg_module_built "$n" "$v"; then
            pci=""
            if ncz_is_nvidia_pkg "$p"; then pci=$(_fbg_unclaimed_nvidia); fi
            what="Drivers"; ncz_dkms_is_gpu "$p" "$n" && what="GPU drivers"
            if [ -n "$pci" ] && "$NCZ_FBG_MODPROBE" nvidia-drm >> "$NCZ_FBG_LOG" 2>&1; then
                fbg_say "$what ready ($n $v built and loaded)."
            elif ncz_is_nvidia_pkg "$p"; then
                fbg_say "$what ready ($n $v built). It is used after the next restart."
            else
                fbg_say "$what ready ($n $v built)."
            fi
        else
            why=$(ncz_dkms_fail_reason "$NCZ_FBG_ROOT" "$n" "$v" "$NCZ_FBG_KVER") || why="see /var/lib/dkms/$n/$v/build/make.log"
            fbg_say "$(ncz_dkms_failed_line "$NCZ_FBG_ROOT" "$p" "$n" "$v" "$why")"
        fi
    done <<< "$cls"
    return 0
}

case "${1:-}" in
    configure) fbg_configure ;;
    *) echo "usage: firstboot-gpu.sh configure" >&2; exit 2 ;;
esac
