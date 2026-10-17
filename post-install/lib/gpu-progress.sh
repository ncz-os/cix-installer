#!/bin/bash
# post-install/lib/gpu-progress.sh -- live installer feedback for the GPU /
# DKMS driver steps (docs/GPU-INSTALL-PROGRESS.md).
#
# Operator report 2026-10-06: the GPU driver step on amd64 (NVIDIA driver
# download + DKMS kernel-module compile, ROCm packages) and the Sky1 DKMS
# builds run for many minutes inside d-i's "Finishing the installation" phase
# with no visible change, so the install looks hung. This file gives those
# steps a named label, a live sub-status fed from real build signals, an
# honest ETA, per-module success/failure lines, and a reserved progress-bar
# weight with real ticks inside it.
#
# Two ways in:
#   . lib/gpu-progress.sh          run-all.sh sources it for the profile,
#                                  plan-weight and monitor start/stop helpers
#   bash lib/gpu-progress.sh watch the background monitor run-all.sh starts
#                                  for a GPU step; it writes GPU records into
#                                  the progress.state protocol that
#                                  preseed/late.sh renders on the d-i screen
#
# Signals the monitor reads (never a timer pretending to be progress):
#   - the DKMS build log  $NCZ_GPU_DKMS_ROOT/<module>/<version>/build/make.log
#     (module, version and kernel come from the dkms header line; progress is
#     the count of kbuild "CC"/"AS" lines against the number of C/asm sources
#     in that build tree, or against the previous build's line count for the
#     same module when one exists)
#   - the result DKMS leaves behind: <module>/<version>/<kernel>/<arch>/module
#     on success, build/make.log with the error on failure
#   - running processes in $NCZ_GPU_PROC_ROOT (dkms, make modules_prepare,
#     update-initramfs/dracut, dpkg, apt) for the stage name between builds
#   - the apt progress shim's own records (left alone while they are fresh)
#
# Record protocol (same as run-all.sh / apt-progress-shim):
#   started|updated|event|phase|index|total|hook|percent|rc|detail
# The monitor only ever writes event GPU. It never writes FAIL or WARN: a
# module build failure inside an optional hook is reported in the detail
# text and in gpu-progress.log, and the gate (build/kvm-install-gate-gpt.sh)
# keeps reading FAIL/WARN only from run-all.sh's own step records.
#
# Text that reaches the d-i screen is ASCII only (newt renders anything else
# as <ERR>).

NCZ_GPU_DKMS_ROOT="${NCZ_GPU_DKMS_ROOT:-/var/lib/dkms}"
NCZ_GPU_PROC_ROOT="${NCZ_GPU_PROC_ROOT:-/proc}"
NCZ_GPU_SYSFS_PCI="${NCZ_GPU_SYSFS_PCI:-/sys/bus/pci/devices}"
NCZ_GPU_DMI_DIR="${NCZ_GPU_DMI_DIR:-/sys/class/dmi/id}"
NCZ_GPU_META_DIR="${NCZ_GPU_META_DIR:-/usr/local/lib/cix-installer}"

# Bar windows inside a GPU step, in percent of the step's own weight.
#   packages before the first module build   0 .. NCZ_GPU_PKG_HI
#   module builds                            .. NCZ_GPU_BUILD_HI
#   packages after the builds (CUDA toolkit) .. 99
# Without a build expected, packages get 0..95.
NCZ_GPU_PKG_HI="${NCZ_GPU_PKG_HI:-25}"
NCZ_GPU_BUILD_HI="${NCZ_GPU_BUILD_HI:-90}"

# ---------------------------------------------------------------- detection
# Display-class PCI vendors from sysfs (no lspci dependency); falls back to
# lspci -nn when sysfs shows no PCI devices at all.
ncz_gpu_pci_vendors() {
    local d c v found=0
    for d in "$NCZ_GPU_SYSFS_PCI"/*; do
        [ -r "$d/class" ] && [ -r "$d/vendor" ] || continue
        found=1
        c=$(cat "$d/class" 2>/dev/null)
        case "$c" in 0x0300*|0x0302*|0x0380*) ;; *) continue ;; esac
        v=$(cat "$d/vendor" 2>/dev/null)
        printf '%s\n' "${v#0x}"
    done
    if [ "$found" = 0 ] && command -v lspci >/dev/null 2>&1; then
        lspci -nn 2>/dev/null | grep -E '\[03(00|02|80)\]:' \
            | sed -n 's/.*\[\([0-9a-fA-F]\{4\}\):[0-9a-fA-F]\{4\}\].*/\1/p'
    fi
}

# --- device identity for user feedback ---------------------------------------
# The installer ships no pci.ids, so ncz_gpu_name() names only the GPUs in the
# curated assets/gpu/ncz-gpu-names.tsv and otherwise prints the always-truthful
# "<Vendor> [vvvv:dddd]". It never invents a product name.
NCZ_GPU_NAMES="${NCZ_GPU_NAMES:-$NCZ_GPU_META_DIR/assets/gpu/ncz-gpu-names.tsv}"

ncz_gpu_vendor_name() {
    case "$1" in
        10de) printf 'NVIDIA' ;;
        1002|1022) printf 'AMD' ;;
        8086) printf 'Intel' ;;
        *) printf '%s' "$1" ;;
    esac
}

# ncz_gpu_name <vendor:device-hex>
ncz_gpu_name() {
    local id="$1" v="${1%%:*}" line
    if [ -r "$NCZ_GPU_NAMES" ]; then
        line=$(awk -F'\t' -v id="$id" '$1==id { print $2; exit }' "$NCZ_GPU_NAMES" 2>/dev/null)
        [ -n "$line" ] && { printf '%s' "$line"; return 0; }
    fi
    printf '%s [%s]' "$(ncz_gpu_vendor_name "$v")" "$id"
}

# Print "vendor:device" (lowercase hex) for each display-class PCI device.
ncz_gpu_pci_ids() {
    local d c v dev
    for d in "$NCZ_GPU_SYSFS_PCI"/*; do
        [ -r "$d/class" ] && [ -r "$d/vendor" ] && [ -r "$d/device" ] || continue
        c=$(cat "$d/class" 2>/dev/null)
        case "$c" in 0x0300*|0x0302*|0x0380*) ;; *) continue ;; esac
        v=$(cat "$d/vendor" 2>/dev/null); dev=$(cat "$d/device" 2>/dev/null)
        printf '%s:%s\n' "${v#0x}" "${dev#0x}"
    done | tr 'A-F' 'a-f'
}

# Sets NCZ_GPU_HAS_NVIDIA / _AMD / _INTEL, NCZ_GPU_VENDORS ("NVIDIA",
# "AMD + NVIDIA", "none", ...) and NCZ_GPU_DETECTED (a human-readable list, e.g.
# "AMD Radeon Pro 5500M (Navi14, ...) [1002:7340]"). Cached for the life of the shell.
ncz_gpu_detect() {
    [ -n "${NCZ_GPU_VENDORS:-}" ] && return 0
    local ids id
    ids=$(ncz_gpu_pci_vendors | tr 'A-F' 'a-f')
    NCZ_GPU_HAS_NVIDIA=0; NCZ_GPU_HAS_AMD=0; NCZ_GPU_HAS_INTEL=0
    # case, not `printf | grep -q`: run-all.sh sources this under pipefail,
    # where grep -q closing the pipe early can SIGPIPE printf and turn a
    # match into a failure.
    for id in $ids; do
        case "$id" in
            10de) NCZ_GPU_HAS_NVIDIA=1 ;;
            1002) NCZ_GPU_HAS_AMD=1 ;;
            8086) NCZ_GPU_HAS_INTEL=1 ;;
        esac
    done
    local v=""
    [ "$NCZ_GPU_HAS_AMD" = 1 ]    && v="AMD"
    [ "$NCZ_GPU_HAS_NVIDIA" = 1 ] && v="${v:+$v + }NVIDIA"
    [ "$NCZ_GPU_HAS_INTEL" = 1 ]  && v="${v:+$v + }Intel"
    NCZ_GPU_VENDORS="${v:-none}"
    # Human-readable device list for the "Detected GPU(s)" feedback line.
    local d sum=""
    while IFS= read -r d; do
        [ -n "$d" ] || continue
        sum="${sum:+$sum; }$(ncz_gpu_name "$d")"
    done < <(ncz_gpu_pci_ids)
    NCZ_GPU_DETECTED="${sum:-none}"
    export NCZ_GPU_HAS_NVIDIA NCZ_GPU_HAS_AMD NCZ_GPU_HAS_INTEL NCZ_GPU_VENDORS NCZ_GPU_DETECTED
}

# Mirrors 54-gpu-accel.sh's ncz_cuda_component_wanted: the NVIDIA driver is
# only installed when the cuda component is selected (or no record exists).
ncz_gpu_nvidia_wanted() {
    [ "${NCZ_SKIP_CUDA:-0}" = 1 ] && return 1
    local f list
    for f in "$NCZ_GPU_META_DIR/COMPONENTS" /etc/cix-installer/COMPONENTS /var/lib/cix-components/COMPONENTS; do
        if [ -r "$f" ]; then
            list=$(tr -d ' \t\r\n' < "$f")
            case ",$list," in *,cuda,*) return 0 ;; *) return 1 ;; esac
        fi
    done
    for f in /etc/cix-installer/COMPONENTS_cuda "$NCZ_GPU_META_DIR/COMPONENTS_cuda"; do
        if [ -r "$f" ]; then
            [ "$(tr -d ' \t\r\n' < "$f")" = 1 ] && return 0
            return 1
        fi
    done
    return 0
}

ncz_gpu_variant() {
    local v=desktop
    [ -r "$NCZ_GPU_META_DIR/BUILD_VARIANT" ] && v=$(tr -d ' \t\r\n' < "$NCZ_GPU_META_DIR/BUILD_VARIANT")
    printf '%s\n' "${v:-desktop}"
}

# ncz_gpu_step_profile <hook>
# Returns 0 for a GPU / driver-build step and sets:
#   NCZ_GPU_LABEL         the named step shown when it starts
#   NCZ_GPU_SHORT         prefix for the live sub-status lines
#   NCZ_GPU_WEIGHT        progress-bar weight in hook slots (1 = ordinary)
#   NCZ_GPU_WATCH         1 = start the live monitor for this step
#   NCZ_GPU_EXPECT_BUILD  1 = a kernel-module compile is expected
# Returns 1 (and touches nothing) for every other hook.
ncz_gpu_step_profile() {
    local hook="$1" arch="${NCZ_GPU_ARCH:-${_NCZ_SYSTEM_ARCH:-}}"
    [ -n "$arch" ] || arch=$(dpkg --print-architecture 2>/dev/null || true)
    NCZ_GPU_WATCH=1; NCZ_GPU_EXPECT_BUILD=0; NCZ_GPU_WEIGHT=1
    case "$hook:$arch" in
        54-gpu-accel.sh:amd64|54-gpu-accel.sh:x86_64)
            case "$(ncz_gpu_variant)" in
                server|headless)
                    NCZ_GPU_LABEL="GPU drivers: server/headless install - no GPU driver needed, skipping"
                    NCZ_GPU_SHORT="GPU drivers"; NCZ_GPU_WATCH=0; return 0 ;;
            esac
            ncz_gpu_detect
            NCZ_GPU_SHORT="GPU drivers ($NCZ_GPU_VENDORS)"
            if [ "$NCZ_GPU_HAS_NVIDIA" = 1 ] && ncz_gpu_nvidia_wanted; then
                NCZ_GPU_WEIGHT=12; NCZ_GPU_EXPECT_BUILD=1
                NCZ_GPU_DECISION="installing the NVIDIA driver via DKMS (this takes a few minutes)"
                NCZ_GPU_LABEL="Installing GPU drivers: $NCZ_GPU_VENDORS - driver download + kernel module build (can take 10-20 min)"
            elif [ "$NCZ_GPU_HAS_AMD" = 1 ]; then
                NCZ_GPU_WEIGHT=4
                NCZ_GPU_DECISION="amdgpu is in the kernel, no extra driver needed; installing ROCm compute packages"
                NCZ_GPU_LABEL="Installing GPU drivers: $NCZ_GPU_VENDORS - ROCm compute packages (amdgpu is in the kernel; a few min)"
            elif [ "$NCZ_GPU_HAS_INTEL" = 1 ]; then
                NCZ_GPU_WEIGHT=2
                NCZ_GPU_DECISION="i915/Xe is in the kernel, no extra driver needed; installing compute and media packages"
                NCZ_GPU_LABEL="Installing GPU drivers: $NCZ_GPU_VENDORS - compute and media packages (no kernel module build)"
            elif [ "$NCZ_GPU_HAS_NVIDIA" = 1 ]; then
                NCZ_GPU_WATCH=0
                NCZ_GPU_DECISION="NVIDIA driver/CUDA component not selected; nothing installed"
                NCZ_GPU_LABEL="GPU drivers: NVIDIA GPU found, driver/CUDA component not selected - skipping"
            else
                NCZ_GPU_WATCH=0
                NCZ_GPU_DECISION="no AMD, NVIDIA or Intel GPU found; nothing to install"
                NCZ_GPU_LABEL="GPU drivers: no AMD, NVIDIA or Intel GPU found - nothing to install, skipping"
            fi
            return 0 ;;
        56-t2-dkms.sh:amd64|56-t2-dkms.sh:x86_64)
            local vendor=""
            [ -r "$NCZ_GPU_DMI_DIR/sys_vendor" ] && vendor=$(cat "$NCZ_GPU_DMI_DIR/sys_vendor" 2>/dev/null)
            case "$vendor" in "Apple Inc."|"Apple Computer, Inc.") ;; *) return 1 ;; esac
            NCZ_GPU_WEIGHT=4; NCZ_GPU_EXPECT_BUILD=1
            NCZ_GPU_SHORT="Apple T2 drivers"
            NCZ_GPU_LABEL="Building Apple T2 drivers: fan + GPU-mux kernel modules (several min)"
            return 0 ;;
        79-dkms-prep.sh:arm64|79-dkms-prep.sh:aarch64)
            NCZ_GPU_WEIGHT=2
            NCZ_GPU_SHORT="Driver build prep"
            NCZ_GPU_LABEL="Preparing kernel headers for the GPU, NPU and VPU driver builds (several min)"
            return 0 ;;
        80-npu.sh:arm64|80-npu.sh:aarch64)
            NCZ_GPU_WEIGHT=2; NCZ_GPU_EXPECT_BUILD=1
            NCZ_GPU_SHORT="NPU driver"
            NCZ_GPU_DETECTED="CIX Sky1 NPU [SoC platform device]"
            NCZ_GPU_DECISION="installing armchina_npu.ko (kernel module build)"
            NCZ_GPU_LABEL="Installing the NPU driver: kernel module build (a few min)"
            return 0 ;;
        82-mali-gpu.sh:arm64|82-mali-gpu.sh:aarch64)
            NCZ_GPU_WEIGHT=3; NCZ_GPU_EXPECT_BUILD=1
            NCZ_GPU_SHORT="GPU driver (Mali)"
            NCZ_GPU_DETECTED="Mali GPU (CIX Sky1 SoC) [SoC platform device]"
            NCZ_GPU_DECISION="building the Mali kernel module (Mesa/panfrost userspace)"
            NCZ_GPU_LABEL="Installing GPU drivers: Mali - kernel module build (several min)"
            return 0 ;;
        83-panthor-gpu.sh:arm64|83-panthor-gpu.sh:aarch64)
            NCZ_GPU_WEIGHT=3; NCZ_GPU_EXPECT_BUILD=1
            NCZ_GPU_SHORT="GPU driver (Panthor)"
            NCZ_GPU_DETECTED="Mali GPU (CIX Sky1 SoC) [SoC platform device]"
            NCZ_GPU_DECISION="building panthor.ko + Mesa panfrost userspace"
            NCZ_GPU_LABEL="Installing GPU drivers: Panthor - kernel module build (several min)"
            return 0 ;;
        86-cix-dkms-register.sh:arm64|86-cix-dkms-register.sh:aarch64)
            NCZ_GPU_WEIGHT=3; NCZ_GPU_EXPECT_BUILD=1
            NCZ_GPU_SHORT="VPU/NPU drivers"
            NCZ_GPU_DETECTED="CIX Sky1 VPU + NPU [SoC platform devices]"
            NCZ_GPU_DECISION="registering the mali/panthor/aipu/amvx kernel modules with DKMS"
            NCZ_GPU_LABEL="Building VPU and NPU drivers: kernel module builds (several min)"
            return 0 ;;
    esac
    return 1
}

# Plan weight for one hook (1 for every non-GPU hook).
ncz_gpu_hook_weight() {
    if ncz_gpu_step_profile "$1" >/dev/null 2>&1; then
        printf '%s\n' "${NCZ_GPU_WEIGHT:-1}"
    else
        printf '1\n'
    fi
}

# ------------------------------------------------------- run-all.sh helpers
# ncz_gpu_watch_begin <hook> <logdir>: start the monitor for a GPU step.
# Sets NCZ_GPU_MON_PID (empty when no monitor was started).
ncz_gpu_watch_begin() {
    local hook="$1" logdir="$2" self
    NCZ_GPU_MON_PID=""
    [ "${NCZ_GPU_PROGRESS:-1}" = 0 ] && return 0
    ncz_gpu_step_profile "$hook" >/dev/null 2>&1 || return 0
    [ "${NCZ_GPU_WATCH:-0}" = 1 ] || return 0
    self="${BASH_SOURCE[0]}"
    [ -r "$self" ] || return 0
    NCZ_PROGRESS_WINDOW="${NCZ_PROGRESS_FILE:-$logdir/progress.state}.window"
    export NCZ_PROGRESS_WINDOW
    NCZ_GPU_LOG="${NCZ_GPU_LOG:-$logdir/gpu-progress.log}" \
    NCZ_GPU_RESULTS="${NCZ_GPU_RESULTS:-$logdir/gpu-progress.results}" \
    NCZ_GPU_PARENT="$$" NCZ_GPU_LABEL="$NCZ_GPU_LABEL" NCZ_GPU_SHORT="$NCZ_GPU_SHORT" \
    NCZ_GPU_EXPECT_BUILD="$NCZ_GPU_EXPECT_BUILD" \
    NCZ_GPU_DETECTED="${NCZ_GPU_DETECTED:-}" NCZ_GPU_DECISION="${NCZ_GPU_DECISION:-}" \
        bash "$self" watch </dev/null >/dev/null 2>&1 &
    NCZ_GPU_MON_PID=$!
}

# ncz_gpu_watch_end <hook> <logdir>: stop the monitor (exact PID) and print
# the one-line step summary ("2 kernel modules built, 0 failed") to stdout.
ncz_gpu_watch_end() {
    local hook="$1" logdir="$2" res ok=0 bad=0
    if [ -n "${NCZ_GPU_MON_PID:-}" ]; then
        kill -TERM "$NCZ_GPU_MON_PID" 2>/dev/null || true
        wait "$NCZ_GPU_MON_PID" 2>/dev/null || true
    fi
    NCZ_GPU_MON_PID=""
    rm -f "${NCZ_PROGRESS_WINDOW:-/nonexistent}" 2>/dev/null || true
    unset NCZ_PROGRESS_WINDOW
    res="${NCZ_GPU_RESULTS:-$logdir/gpu-progress.results}"
    if [ -r "$res" ]; then
        ok=$(awk -F'|' -v h="$hook" '$1 == h && $5 == "ok" { n++ } END { print n + 0 }' "$res")
        bad=$(awk -F'|' -v h="$hook" '$1 == h && $5 == "failed" { n++ } END { print n + 0 }' "$res")
    fi
    if [ "$ok" -gt 0 ] || [ "$bad" -gt 0 ]; then
        printf '%s kernel module build(s) OK, %s failed\n' "$ok" "$bad"
    fi
}

# ---------------------------------------------------------------- monitor
_g_fmt_dur() { local s="${1:-0}"; [ "$s" -ge 0 ] 2>/dev/null || s=0; printf '%dm%02ds' $((s / 60)) $((s % 60)); }
_g_mtime() { stat -c %Y "$1" 2>/dev/null || echo 0; }
# _g_clean <text> [max-columns]: ONE text argument; the second is the column
# limit for cut and must never end up in the text ("$*" appended it).
_g_clean() { printf '%s' "$1" | tr '|\t\r\n' '    ' | tr -cd '\040-\176' | cut -c1-"${2:-150}"; }

_g_log() {   # timestamped line into gpu-progress.log (+ tty3)
    local line
    line="[$(date -u +%H:%M:%S)] [${NCZ_PROGRESS_HOOK:-gpu}] $*"
    printf '%s\n' "$line" >> "$G_LOG" 2>/dev/null || true
    printf '%s\n' "$line" > "${NCZ_TTY:-/dev/tty3}" 2>/dev/null || true
}

_g_emit() {  # _g_emit <percent> <detail>
    local pct="$1" detail now tmp record
    [ -n "${NCZ_PROGRESS_FILE:-}" ] || return 0
    now=$(date +%s)
    detail=$(_g_clean "$2" 130)
    record="${NCZ_PROGRESS_STARTED:-$now}|$now|GPU|${NCZ_PROGRESS_PHASE:-optional}|${NCZ_PROGRESS_INDEX:-0}|${NCZ_PROGRESS_TOTAL:-0}|${NCZ_PROGRESS_HOOK:-gpu}|$pct||$detail"
    tmp="${NCZ_PROGRESS_FILE}.gpu.$$"
    printf '%s\n' "$record" > "$tmp" 2>/dev/null && mv -f "$tmp" "$NCZ_PROGRESS_FILE" 2>/dev/null
    [ -n "${NCZ_PROGRESS_LOG:-}" ] && printf '%s\n' "$record" >> "$NCZ_PROGRESS_LOG" 2>/dev/null
    G_LAST_EMIT=$now
    return 0
}

_g_window() { [ -n "${NCZ_PROGRESS_WINDOW:-}" ] && printf '%s %s\n' "$1" "$2" > "$NCZ_PROGRESS_WINDOW" 2>/dev/null; return 0; }

# Running processes worth naming. Sets G_P_DKMS G_P_INITRD G_P_PREP G_P_DPKG G_P_APT.
_g_scan_procs() {
    local p a c
    G_P_DKMS=""; G_P_INITRD=""; G_P_PREP=""; G_P_DPKG=""; G_P_APT=""
    for p in "$NCZ_GPU_PROC_ROOT"/[0-9]*; do
        [ -r "$p/cmdline" ] || continue
        a=()
        mapfile -d '' -t a < "$p/cmdline" 2>/dev/null || continue
        [ "${#a[@]}" -gt 0 ] || continue
        c="${a[*]}"
        case "$c" in
            *dkms\ build*|*dkms\ install*|*dkms\ autoinstall*|*dkms\ -m\ *)
                G_P_DKMS="$c" ;;
            *update-initramfs*|*mkinitramfs*|*dracut\ *|*/dracut) G_P_INITRD="$c" ;;
            *modules_prepare*) G_P_PREP="$c" ;;
            dpkg\ *|/usr/bin/dpkg\ *) G_P_DPKG="$c" ;;
            /usr/lib/apt/methods/http*|/usr/lib/apt/methods/https*) G_P_APT="$c" ;;
        esac
    done
}

# Newest DKMS build log touched since the monitor started.
_g_active_log() {
    local f m best="" bestm=0
    for f in "$NCZ_GPU_DKMS_ROOT"/*/*/build/make.log; do
        [ -f "$f" ] || continue
        m=$(_g_mtime "$f")
        [ "$m" -ge $((G_T0 - 2)) ] || continue
        if [ "$m" -ge "$bestm" ]; then best="$f"; bestm="$m"; fi
    done
    printf '%s\n' "$best"
}

_g_count_compiles() {  # kbuild compile lines in a make.log
    local n
    n=$(grep -cE '^[[:space:]]*(CC|AS|CXX)( \[M\])?[[:space:]]' "$1" 2>/dev/null)
    printf '%s\n' "${n:-0}"
}

# Identity of one build log: dkms recreates build/ at the same path for the
# next kernel, so the path alone cannot tell two builds apart; the inode plus
# the header line (module, version, kernel) can.
_g_log_id() { printf '%s|%s|%s' "$1" "$(stat -c %i "$1" 2>/dev/null)" "$(head -n 1 "$1" 2>/dev/null)"; }

_g_build_begin() {  # sets G_B_* for the new build at log $1
    local log="$1" dir prev hdr k
    dir=$(dirname "$log")
    G_B_LOG="$log"; G_B_START=$(date +%s)
    G_B_VER=$(basename "$(dirname "$dir")")
    G_B_MOD=$(basename "$(dirname "$(dirname "$dir")")")
    hdr=$(head -n 1 "$log" 2>/dev/null)
    k=$(printf '%s\n' "$hdr" | sed -n 's/.* for kernel \([^ ]*\).*/\1/p')
    if [ -z "$k" ] && [ -n "$G_P_DKMS" ]; then
        k=$(printf '%s\n' "$G_P_DKMS" | sed -n 's/.* -k \([^ ]*\).*/\1/p')
    fi
    G_B_KVER="${k:-unknown}"
    G_B_KEY="$G_B_MOD|$G_B_VER|$G_B_KVER"
    # Expected compile count: the previous build of this module (another
    # kernel, earlier in this install) is the best measurement; otherwise the
    # number of C/asm sources DKMS copied into the build tree.
    G_B_EXP=0; G_B_EXP_SRC="source files"
    prev=$(ls -t "$NCZ_GPU_DKMS_ROOT/$G_B_MOD/$G_B_VER"/*/*/log/make.log 2>/dev/null | head -n 1)
    if [ -n "$prev" ]; then
        G_B_EXP=$(_g_count_compiles "$prev")
        G_B_EXP_SRC="previous build"
    fi
    if [ "${G_B_EXP:-0}" -le 0 ]; then
        G_B_EXP=$(find "$dir" \( -name '*.c' -o -name '*.S' \) -type f 2>/dev/null | wc -l | tr -d ' ')
        G_B_EXP_SRC="source files"
    fi
    # Bar window for this build: from where the step is now, toward BUILD_HI.
    # The first build of a step that expects one starts no lower than PKG_HI.
    G_B_LO=$G_PCT
    if [ "$G_EXPECT" = 1 ] && [ "$G_BUILDS" = 0 ] && [ "$G_B_LO" -lt "$NCZ_GPU_PKG_HI" ]; then
        G_B_LO=$NCZ_GPU_PKG_HI
    fi
    [ "$G_B_LO" -gt "$NCZ_GPU_BUILD_HI" ] && G_B_LO=$NCZ_GPU_BUILD_HI
    G_B_HI=$((G_B_LO + (NCZ_GPU_BUILD_HI - G_B_LO) * 2 / 3))
    [ "$G_B_HI" -lt "$G_B_LO" ] && G_B_HI=$G_B_LO
    [ "$G_PCT" -lt "$G_B_LO" ] && G_PCT=$G_B_LO
    _g_window "$G_PCT" "$G_PCT"     # apt records during the build keep the bar where it is
    _g_log "BEGIN build $G_B_MOD $G_B_VER for kernel $G_B_KVER (expect ~$G_B_EXP compiles, from $G_B_EXP_SRC)"
}

_g_build_finish() {  # report the build that just ended
    local dur res err detail mods
    [ -n "${G_B_KEY:-}" ] || return 0
    dur=$(( $(date +%s) - G_B_START ))
    mods=$(ls "$NCZ_GPU_DKMS_ROOT/$G_B_MOD/$G_B_VER/$G_B_KVER"/*/module/ 2>/dev/null | grep -c '\.ko' || true)
    if [ "${mods:-0}" -gt 0 ]; then
        res=ok
        detail="$G_SHORT: $G_B_MOD $G_B_VER for kernel $G_B_KVER - built OK in $(_g_fmt_dur "$dur")"
    else
        res=failed
        # first compiler/make error, from "error:" on (the source path in front
        # of it would eat the whole line on screen)
        err=$(grep -m1 -E 'error:|Error [0-9]+' "$G_B_LOG" 2>/dev/null \
              | sed 's/^.*\(error:\)/\1/; s/^[[:space:]]*//' | cut -c1-60)
        detail="$G_SHORT: $G_B_MOD $G_B_VER for kernel $G_B_KVER - BUILD FAILED after $(_g_fmt_dur "$dur")${err:+: $err}"
    fi
    G_PCT=$(( G_PCT > G_B_HI ? G_PCT : G_B_HI ))
    _g_emit "$G_PCT" "$detail"
    # On failure, a second, dedicated line with the hook log path (the operator
    # asked for it 2026-10-10); kept separate so the compiler error above is not
    # truncated by the 130-column emit cap.
    if [ "${res:-}" = failed ]; then
        _g_emit "$G_PCT" "GPU driver build failed - see /var/log/cix-install/${NCZ_PROGRESS_HOOK:-gpu}.log"
    fi
    _g_log "RESULT $res $G_B_MOD $G_B_VER kernel $G_B_KVER in ${dur}s${err:+ -- $err}"
    printf '%s|%s|%s|%s|%s|%s\n' "${NCZ_PROGRESS_HOOK:-gpu}" "$G_B_MOD" "$G_B_VER" "$G_B_KVER" "$res" "$dur" \
        >> "$G_RESULTS" 2>/dev/null || true
    G_BUILDS=$((G_BUILDS + 1))
    G_HOLD_UNTIL=$(( $(date +%s) + G_HOLD ))
    G_B_KEY=""; G_B_LOG=""
    _g_window "$G_PCT" 99           # later package transactions fill the rest
}

_g_state_fresh_apt() {  # is the apt shim speaking right now for this step?
    local s
    [ -r "${NCZ_PROGRESS_FILE:-}" ] || return 1
    IFS='|' read -r _s0 s _s2 _s3 _s4 _s5 _s6 _s7 _s8 _s9 < "$NCZ_PROGRESS_FILE" 2>/dev/null || return 1
    [ "$_s2" = APT ] || return 1
    case "$s" in ''|*[!0-9]*) return 1 ;; esac
    [ $(( $(date +%s) - s )) -le 8 ]
}

_g_track_state_pct() {  # ratchet G_PCT with what the shim reported
    local ev pct idx
    [ -r "${NCZ_PROGRESS_FILE:-}" ] || return 0
    IFS='|' read -r _s0 _s1 ev _s3 idx _s5 _s6 pct _s8 _s9 < "$NCZ_PROGRESS_FILE" 2>/dev/null || return 0
    [ "$idx" = "${NCZ_PROGRESS_INDEX:-}" ] || return 0
    case "$ev" in APT|GPU) ;; *) return 0 ;; esac
    case "$pct" in ''|*[!0-9]*) return 0 ;; esac
    [ "$pct" -gt "$G_PCT" ] && G_PCT=$pct
    return 0
}

# ------------------------------------------------- screensaver GPU class
# ncz_gpu_saver_class <vendor:device> -> strong|mid|weak, or nothing when the
# answer is not knowable here.
#
# This is the GPU CLASS the screensaver engine (ncz-screensaver
# class_from_renderer / class_from_topology, docs/MINOR-005-panfrost-screensaver-class.md)
# works from: the same wording the saver policy uses ("weak" = the cheap tier,
# "mid" = the Mali/Panfrost band, "strong" = a discrete card that never
# calibrates down). It reads the PCI identity only -- no renderer probe, no
# calibration run -- so it answers in the installer, hours before the engine
# exists. Consumers: preseed/hw-summary.sh (the worded expectation in the
# install-time HARDWARE SUMMARY).
#
# The table is a reading of the measured class bands, not a product catalogue:
#   NVIDIA Turing (device id >= 0x1e00, the same arithmetic family cut
#   lib/cuda-select.sh uses) and newer -> strong; older discrete NVIDIA -> mid
#   AMD discrete (Navi+, 0x73xx and up) -> strong, older discrete AMD -> mid
#   Intel integrated (8086, display class) -> mid; Intel Arc (0x56xx/0xe2xx) -> strong
#   Mali-G7xx / Panfrost / Panthor -> mid (MINOR-005: measured 9.88-11.76 ms)
#   Mali-G5x/G6x and earlier -> weak
#   Apple T2-era integrated -> mid
# A vendor:device this does not recognise prints nothing: the caller then says
# nothing about the screensavers rather than inventing a class.
ncz_gpu_saver_class() {
    local id v dev idd
    id=$(printf '%s' "$1" | tr 'A-F' 'a-f')
    v="${id%%:*}"; dev="${id#*:}"
    [ "$v" != "$id" ] || return 0
    idd=$((0x$dev)) 2>/dev/null || return 0
    case "$v" in
        10de)   # NVIDIA
            if [ "$idd" -ge $((0x1e00)) ]; then printf 'strong'
            else printf 'mid'; fi ;;
        1002)   # AMD
            if [ "$idd" -ge $((0x7300)) ]; then printf 'strong'
            else printf 'mid'; fi ;;
        8086)   # Intel
            case "$dev" in
                56*|e2*) printf 'strong' ;;      # Arc / Battlemage discrete
                *)       printf 'mid' ;;
            esac ;;
        106b)   # Apple
            printf 'mid' ;;
        13b5|14e4)   # ARM Mali (Foundation/display) / Broadcom V3D
            printf 'mid' ;;
        *) return 0 ;;
    esac
    return 0
}

_g_stop=0
ncz_gpu_watch() {
    G_T0=$(date +%s)
    G_LOG="${NCZ_GPU_LOG:-/var/log/cix-install/gpu-progress.log}"
    G_RESULTS="${NCZ_GPU_RESULTS:-/var/log/cix-install/gpu-progress.results}"
    G_SHORT="${NCZ_GPU_SHORT:-GPU drivers}"
    G_EXPECT="${NCZ_GPU_EXPECT_BUILD:-0}"
    G_POLL="${NCZ_GPU_POLL:-3}"
    G_HOLD="${NCZ_GPU_HOLD:-6}"
    G_STALE="${NCZ_GPU_STALE:-10}"      # s without log writes or dkms = build over
    G_ETA_MIN="${NCZ_GPU_ETA_MIN_S:-30}" # s of measured build before an ETA is shown
    G_PCT=0; G_BUILDS=0; G_B_KEY=""; G_B_LOG=""; G_HOLD_UNTIL=0; G_LAST_EMIT=0
    local pkg_hi=95 log m now done stage eta rem detail last_logged="" last_log_t=0 tail3 el
    [ "$G_EXPECT" = 1 ] && pkg_hi=$NCZ_GPU_PKG_HI
    _g_window 0 "$pkg_hi"
    trap '_g_stop=1' TERM INT
    _g_log "STEP ${NCZ_GPU_LABEL:-$G_SHORT} (gpu=${NCZ_GPU_VENDORS:-n/a})"
    # "Detected GPU: <device> -> <driver decision>" first, then the step label.
    # The detection line was a requirement (2026-10-10); it stays
    # in progress.tsv + gpu-progress.log so the gate can assert it in order,
    # while the label remains the persistent on-screen status.
    if [ -n "${NCZ_GPU_DETECTED:-}" ] && [ "${NCZ_GPU_DETECTED}" != none ]; then
        _g_log "DETECTED ${NCZ_GPU_DETECTED}${NCZ_GPU_DECISION:+ -> $NCZ_GPU_DECISION}"
        # Two short lines, not one long one: the emit field is capped at 130
        # columns (same as every other status line), and name+decision together
        # overflow it on real devices.
        _g_emit 0 "Detected GPU: ${NCZ_GPU_DETECTED}"
        [ -n "${NCZ_GPU_DECISION:-}" ] && _g_emit 0 "GPU driver: ${NCZ_GPU_DECISION}"
    fi
    _g_emit 0 "${NCZ_GPU_LABEL:-$G_SHORT}"
    G_HOLD_UNTIL=$(( G_T0 + G_HOLD ))
    while :; do
        # sleep in the background + wait: bash interrupts `wait` (not a
        # foreground sleep) as soon as the TERM trap fires, so stop is prompt;
        # the leftover sleep is then killed by exact PID.
        sleep "$G_POLL" & G_SLEEP=$!
        wait "$G_SLEEP" 2>/dev/null
        if [ "$_g_stop" = 1 ] || { [ -n "${NCZ_GPU_PARENT:-}" ] && ! kill -0 "$NCZ_GPU_PARENT" 2>/dev/null; }; then
            kill "$G_SLEEP" 2>/dev/null
            break
        fi
        now=$(date +%s)
        _g_scan_procs
        _g_track_state_pct
        log=$(_g_active_log)
        if [ -n "$G_B_KEY" ]; then
            # The current build ended: DKMS moved/removed build/make.log
            # (success) or stopped writing it with no dkms process left.
            m=$(_g_mtime "$G_B_LOG")
            if [ ! -f "$G_B_LOG" ] || [ "$log" != "$G_B_LOG" ] \
               || [ "$(_g_log_id "$G_B_LOG")" != "$G_B_ID" ] \
               || { [ -z "$G_P_DKMS" ] && [ $((now - m)) -ge "$G_STALE" ]; }; then
                G_DONE_ID="$G_B_ID"
                _g_build_finish
            fi
        fi
        # A failed build leaves its make.log behind; it must not restart as a
        # "new" build on the next tick. $log was sampled before the finish check
        # above; DKMS moves make.log away at the end of a successful build, so
        # require it to still exist or the build that just finished is reported
        # a second time (extra "ok" row, inflated module-build count).
        if [ -n "$log" ] && [ -f "$log" ] && [ -z "$G_B_KEY" ] && [ "$(_g_log_id "$log")" != "${G_DONE_ID:-}" ]; then
            _g_build_begin "$log"
            G_B_ID=$(_g_log_id "$log")
        fi
        if [ -n "$G_B_KEY" ]; then
            done=$(_g_count_compiles "$G_B_LOG")
            tail3=$(tail -n 3 "$G_B_LOG" 2>/dev/null)
            case "$tail3" in
                *MODPOST*)            stage="linking (modpost)" ;;
                *"LD [M]"*|*" LD "*)  stage="linking" ;;
                *" CC"*|*" AS"*)      stage="compiling" ;;
                *"Applying patch"*|*patching\ file*) stage="patching sources" ;;
                *)                    [ "$done" -gt 0 ] && stage="compiling" || stage="preparing the build" ;;
            esac
            el=$((now - G_B_START))
            eta=""
            # done >= 10 also keeps the divisor below non-zero
            if [ "$G_B_EXP" -gt 0 ] && [ "$done" -lt "$G_B_EXP" ] && [ "$done" -ge 10 ] && [ "$el" -ge "$G_ETA_MIN" ]; then
                rem=$(( (G_B_EXP - done) * el / done ))
                if [ "$rem" -lt 60 ]; then eta=", under a minute left"
                else eta=", about $(( (rem + 59) / 60 )) min left"; fi
            fi
            if [ "$G_B_EXP" -gt 0 ] && [ "$done" -le "$G_B_EXP" ]; then
                detail="$G_SHORT: building $G_B_MOD $G_B_VER for kernel $G_B_KVER - $stage $done/$G_B_EXP files$eta"
                m=$done; [ "$m" -ge "$G_B_EXP" ] && m=$((G_B_EXP - 1))
                m=$(( G_B_LO + (G_B_HI - G_B_LO) * m / G_B_EXP ))
            else
                detail="$G_SHORT: building $G_B_MOD $G_B_VER for kernel $G_B_KVER - $stage, $done files so far"
                m=$G_PCT
            fi
            [ "$m" -gt "$G_PCT" ] && G_PCT=$m
            _g_emit "$G_PCT" "$detail"
        elif [ "$now" -lt "$G_HOLD_UNTIL" ]; then
            :   # keep the last result / step line on screen for one heartbeat
        elif [ -n "$G_P_INITRD" ]; then
            detail="$G_SHORT: refreshing the boot image (initramfs)"
            m=$(printf '%s\n' "$G_P_INITRD" | grep -oE '[0-9]+\.[0-9]+[^ ]*' | head -n 1)
            [ -n "$m" ] && detail="$detail for kernel $m"
            _g_emit "$G_PCT" "$detail"
        elif [ -n "$G_P_PREP" ]; then
            _g_emit "$G_PCT" "$G_SHORT: preparing kernel headers (make modules_prepare)"
        elif [ -n "$G_P_DKMS" ]; then
            _g_emit "$G_PCT" "$G_SHORT: dkms is preparing the next module build"
        elif _g_state_fresh_apt; then
            :   # the apt shim's per-package line is the better status
        elif [ -n "$G_P_APT" ]; then
            _g_emit "$G_PCT" "$G_SHORT: downloading driver packages"
        elif [ -n "$G_P_DPKG" ]; then
            _g_emit "$G_PCT" "$G_SHORT: installing driver packages"
        elif [ $((now - G_LAST_EMIT)) -ge 9 ]; then
            _g_emit "$G_PCT" "$G_SHORT: working (step running $(_g_fmt_dur $((now - G_T0))))"
        fi
        # gpu-progress.log: each new status kind, and a sample every 30s.
        detail=$(_g_clean "${detail:-}" 130)
        if [ -n "$detail" ] && { [ "${detail%% - *}" != "${last_logged%% - *}" ] || [ $((now - last_log_t)) -ge 30 ]; }; then
            printf '[%s] [%s] %s\n' "$(date -u +%H:%M:%S)" "${NCZ_PROGRESS_HOOK:-gpu}" "$detail" >> "$G_LOG" 2>/dev/null || true
            last_logged="$detail"; last_log_t=$now
        fi
        detail=""
    done
    # Step over: report a build still open (its result is on disk by now).
    [ -n "$G_B_KEY" ] && _g_build_finish
    _g_log "END ${G_SHORT} after $(_g_fmt_dur $(( $(date +%s) - G_T0 ))) ($G_BUILDS module build(s) observed)"
    [ -n "${NCZ_PROGRESS_WINDOW:-}" ] && rm -f "$NCZ_PROGRESS_WINDOW" 2>/dev/null
    return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    case "${1:-}" in
        watch)   ncz_gpu_watch ;;
        profile) ncz_gpu_step_profile "${2:-}" && printf '%s|%s|%s|%s\n' "$NCZ_GPU_WEIGHT" "$NCZ_GPU_WATCH" "$NCZ_GPU_EXPECT_BUILD" "$NCZ_GPU_LABEL" ;;
        detect)  ncz_gpu_detect; printf '%s\n' "$NCZ_GPU_VENDORS" ;;
        *) echo "usage: gpu-progress.sh watch | profile <hook> | detect" >&2; exit 2 ;;
    esac
fi
