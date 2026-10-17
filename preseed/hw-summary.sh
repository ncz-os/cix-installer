#!/bin/sh
# hw-summary.sh -- NCZ HARDWARE SUMMARY: the one plain-English d-i dialog that
# shows what the installer found before anything is written.
#
#     hw-summary.sh --collect   probe, print the dialog body, no dialog
#     hw-summary.sh --dialog    probe, show it in ONE note dialog
#
# WHERE: partman/early_command (preseed.cfg), with the disk chooser -- after
# d-i's hw-detect has loaded the drivers and before the first write.
# ONCE PER BOOT: $NCZ_TMP/.ncz-hwsummary-shown (same pattern as .ncz-disk-done).
#
# WHAT IT SHOWS -- every line is produced by an EXISTING detector or table,
# never by a second copy of one:
#   System        DMI vendor + model, firmware version
#   CPU           /proc/cpuinfo model string + the generation that string
#                 states + threads
#   Memory        /proc/meminfo MemTotal
#   Storage       fixed disks: size, model (the disks the chooser will offer)
#   GPU           PCI class 0x03xx: curated name from
#                 assets/gpu/ncz-gpu-names.tsv (else the numeric
#                 vendor:device), plus the screensaver strength for the class
#                 post-install/lib/gpu-progress.sh's ncz_gpu_saver_class()
#                 computes, worded from assets/gpu/ncz-screensaver-strength.tsv
#   Accelerators  PCI class 0x0b40 (Intel NPU, CIX NPU/VPU device), NVIDIA
#                 compute by the family test post-install/lib/cuda-select.sh
#                 uses, CIX Sky1 NPU + VPU (SoC devices)
#   Other         Apple T2 (post-install/lib/hw-detect.sh is_t2_hardware),
#                 Thunderbolt / USB4 (PCI class 0x0c0340)
#
# IT NEVER FAILS OR BLOCKS. It runs inside partman/early_command, where a
# non-zero exit stops d-i before partitioning: --dialog always exits 0, a probe
# that errors only drops its own line, and a dialog that cannot be shown is
# logged and skipped. Probes are shell reads of cached /proc and /sys
# attributes only -- nothing reads PCI config space (that read never returns on
# a runtime-suspended GPU; see post-install/lib/pci-sysfs.sh).
#
# SKIP RULES (silent, exit 0; the reason is logged in --dialog mode):
#   ncz_hwsummary=0 on the kernel cmdline            operator opt-out
#   ncz_unattended=1 or ncz_components= on the cmdline
#                                                    automated installs (the KVM
#                                                    install gate passes these;
#                                                    same rule as every other
#                                                    informational dialog)
#   $NCZ_TMP/.ncz-hwsummary-shown exists             already shown this boot
#   no debconf frontend                              nothing could show it
#
# ASCII ONLY: newt renders non-ASCII bytes in the C locale as <ERR>
# (preseed/ncz-ui.sh records an em dash truncating a dialog title).
#
# TEST SEAMS: NCZ_HW_PROC, NCZ_HW_SYS, NCZ_HW_DMI, NCZ_HW_CMDLINE,
# NCZ_HW_NAME_TABLE, NCZ_HW_STRENGTH_TABLE, NCZ_HW_STATE, NCZ_TMP, NCZ_UI_SH,
# NCZ_UI_RELEASE, NCZ_UI_PAYLOAD, NCZ_GPU_LIB, NCZ_CONFMODULE.

set +e

case "${1:-}" in
    --collect|--dialog|--render) ;;
    *) echo "usage: $0 --collect|--dialog|--render" >&2; exit 2 ;;
esac
MODE=$1

NCZ_TMP="${NCZ_TMP:-/tmp}"
PROC="${NCZ_HW_PROC:-/proc}"
SYS="${NCZ_HW_SYS:-/sys}"
DMI="${NCZ_HW_DMI:-$SYS/class/dmi/id}"
STATE="${NCZ_HW_STATE:-$NCZ_TMP/.ncz-hwsummary-shown}"   # honours NCZ_HW_STATE, else the per-boot file
CMDLINE="${NCZ_HW_CMDLINE:-$PROC/cmdline}"
DIR=$(cd "$(dirname "$0")" && pwd)
NAME_TABLE="${NCZ_HW_NAME_TABLE:-$DIR/../assets/gpu/ncz-gpu-names.tsv}"
STRENGTH_TABLE="${NCZ_HW_STRENGTH_TABLE:-$DIR/../assets/gpu/ncz-screensaver-strength.tsv}"

# shared NCZ dialog look (brand in the frame title, arch + build on the last
# body line); optional, never fatal -- the same loop every chooser uses
for _u in "${NCZ_UI_SH:-}" /ncz/ncz-ui.sh "$DIR/ncz-ui.sh"; do
    [ -n "$_u" ] && [ -r "$_u" ] && . "$_u" && break
done
command -v ncz_ui_brand >/dev/null 2>&1 || ncz_ui_brand() { echo "NCZ-OS"; }
command -v ncz_ui_id >/dev/null 2>&1 || ncz_ui_id() { echo ""; }

_log() { echo "[ncz hwsummary] $*" >&2; }

# --------------------------------------------------------------- skip rules
# Evaluated in BOTH modes, so an automated install pays no probe cost at all.
_skip_reason() {
    for _t in $(cat "$CMDLINE" 2>/dev/null); do
        case "$_t" in
            ncz_hwsummary=0|ncz_hwsummary=no|ncz_hwsummary=off|ncz_hwsummary=false|ncz_hwsummary=disable)
                echo "ncz_hwsummary=0 on the kernel cmdline"; return 0 ;;
            ncz_unattended=1|ncz_components=*)
                echo "automated install (ncz_unattended=1 / ncz_components=)"; return 0 ;;
        esac
    done
    return 1
}
if _why=$(_skip_reason); then
    [ "$MODE" = --dialog ] && _log "skipped: $_why"
    exit 0
fi

# ------------------------------------------------------------------- probes
# _rfile FILE... : first readable, non-empty FILE, CR/LF stripped
_rfile() {
    for _f in "$@"; do
        [ -r "$_f" ] || continue
        _v=$(tr -d '\r\n' < "$_f" 2>/dev/null)
        [ -n "$_v" ] && { printf '%s\n' "$_v"; return 0; }
    done
    return 1
}

# PCI devices from the sysfs attributes the PCI core cached at enumeration
# ("<class> <vendor>:<device>", hex, no 0x). Never lspci (see header).
_pci_devices() {
    for _d in "$SYS"/bus/pci/devices/*; do
        [ -d "$_d" ] || continue
        _c=$(_rfile "$_d/class") || continue
        _v=$(_rfile "$_d/vendor") || continue
        _p=$(_rfile "$_d/device") || continue
        printf '%s %s:%s\n' "${_c#0x}" "${_v#0x}" "${_p#0x}"
    done
}

_attr() {   # FILE... -> value with 0x/0X stripped
    _rfile "$@" | sed 's/^0[xX]//'
}

p_system() {
    _sv=$(_attr "$DMI/sys_vendor" "$DMI/board_vendor")
    _pn=$(_attr "$DMI/product_name" "$DMI/board_name")
    # Firmware placeholders are not a model: drop them, keep what is real.
    case "$_sv" in "System manufacturer"|"To Be Filled By"*|OEM|*"Not Specified"*) _sv="" ;; esac
    case "$_pn" in "System Product Name"|"To Be Filled By"*|OEM|*"Not Specified"*|*"Default string"*) _pn="" ;; esac
    [ -n "$_sv$_pn" ] || return 0
    _line=$(printf '%s %s' "$_sv" "$_pn" | sed 's/  */ /g; s/^ //; s/ $//')
    _bv=$(_attr "$DMI/bios_version")
    case "$_bv" in "To Be Filled By"*|*"Default string"*|*"Not Specified"*) _bv="" ;; esac
    [ -n "$_bv" ] && _line="$_line (firmware $_bv)"
    printf 'System: %s\n' "$_line"
}

p_cpu() {
    _m=""
    for _k in "model name" "Model" "Hardware" "Processor"; do
        _m=$(sed -n "s/^$_k[[:space:]]*:[[:space:]]*//p" "$PROC/cpuinfo" 2>/dev/null | head -1 \
             | sed 's/  */ /g; s/^ //; s/ $//')
        [ -n "$_m" ] && break
    done
    [ -n "$_m" ] || return 0
    _n=$(grep -c '^processor' "$PROC/cpuinfo" 2>/dev/null)
    case "$_n" in ''|0|*[!0-9]*) _n="" ;; esac
    printf 'CPU: %s | %s%s\n' "$_m" "$(cpu_generation "$_m")" "${_n:+ | $_n threads}"
}

# cpu_generation MODEL -> the generation the brand string STATES. A reading of
# the string, not a CPU catalogue; a string that states nothing says so.
# _ordinal N -> 1st, 2nd, 3rd, 4th ... (never "3th").
_ordinal() {
    case "$1" in
        1?) _o=th ;;
        *1) _o=st ;; *2) _o=nd ;; *3) _o=rd ;; *) _o=th ;;
    esac
    case "$1" in 11|12|13) _o=th ;; esac
    printf '%s%s' "$1" "$_o"
}
cpu_generation() {
    _c=$1
    case "$_c" in
        *Sky1*|*CP8180*|*"CIX "*) echo "CIX Sky1 (CP8180)"; return 0 ;;
    esac
    case "$_c" in
        *"Core(TM) Ultra"*|*"Core Ultra"*)
            case "$_c" in
                *"Ultra 9"*) echo "Core Ultra 9 (Arrow Lake / Lunar Lake class)" ;;
                *"Ultra 7"*) echo "Core Ultra 7 (Meteor / Arrow / Lunar Lake class)" ;;
                *"Ultra 5"*) echo "Core Ultra 5 (Meteor / Arrow / Lunar Lake class)" ;;
                *)           echo "Core Ultra class" ;;
            esac; return 0 ;;
        *"Ryzen AI"*) echo "Ryzen AI (Strix Point, Zen 5)"; return 0 ;;
        Apple*|*"Apple M"*)
            case "$_c" in
                *M1*) echo "Apple M1, arm64" ;;
                *M2*) echo "Apple M2, arm64" ;;
                *M3*) echo "Apple M3, arm64" ;;
                *M4*) echo "Apple M4, arm64" ;;
                *)    echo "Apple silicon, arm64" ;;
            esac; return 0 ;;
        *Xeon*) echo "Xeon, server"; return 0 ;;
        *"Core(TM) i"[0-9]-*|*"Core i"[0-9]-*|*"Core(TM) i"[0-9]" "*|*"Core i"[0-9]" "*)
            _num=$(printf '%s' "$_c" | sed -n 's/.*[[:space:]]i[0-9]-\([0-9][0-9]*\).*/\1/p')
            case "$_num" in
                [0-9][0-9][0-9][0-9]) echo "Core i, $(_ordinal "${_num%???}") generation" ;;
                [0-9][0-9][0-9][0-9][0-9]) echo "Core i, $(_ordinal "${_num%"${_num#??}"}") generation" ;;
                [0-9][0-9][0-9]) echo "Core i, 1st or 2nd generation" ;;
                *) echo "Core i, generation not stated" ;;
            esac; return 0 ;;
        *Ryzen*|*EPYC*|*Threadripper*)
            _num=$(printf '%s' "$_c" | sed -n 's/.*Ryzen [0-9][[:space:]]\([0-9][0-9]*\).*/\1/p')
            case "$_num" in
                [0-9][0-9][0-9][0-9])       echo "Ryzen, ${_num%"${_num#?}"}xx series" ;;
                [0-9][0-9][0-9][0-9][0-9])  echo "Ryzen, ${_num%"${_num#??}"}xx series" ;;
                *)                          echo "AMD, generation not stated" ;;
            esac; return 0 ;;
        *) echo "generation not stated" ;;
    esac
}

p_memory() {
    _kb=$(sed -n 's/^MemTotal:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$PROC/meminfo" 2>/dev/null | head -1)
    case "$_kb" in ''|*[!0-9]*) return 0 ;; esac
    _gb=$(awk -v k="$_kb" 'BEGIN { g = k / 1048576; if (g >= 10) printf "%.0f", g; else printf "%.1f", g }')
    printf 'Memory: %s GB\n' "$_gb"
}

# Fixed disks only: whole disks (not partitions), sized, not removable, and a
# name that carries a device number so a fixture's marker directory is never
# read as a disk. The size rule is disk-fs-chooser.sh's: a size file that is
# not a number is not a disk.
p_storage() {
    _any=0
    for _b in "$SYS"/block/*; do
        [ -d "$_b/device" ] || continue
        [ -e "$_b/partition" ] && continue
        case "${_b##*/}" in *[0-9]*) ;; *) continue ;; esac
        [ "$(_rfile "$_b/removable")" = 1 ] && continue
        _sz=$(_rfile "$_b/size")
        case "$_sz" in ''|*[!0-9]*) continue ;; esac
        _gb=$((_sz / 1953125))              # 512-byte sectors -> GB
        [ "$_gb" -gt 0 ] || continue
        _model=$(_rfile "$_b/device/model" "$_b/device/name") || _model="model not reported"
        _model=$(printf '%s' "$_model" | sed 's/  */ /g; s/^ //; s/ $//')
        if [ "$_any" = 0 ]; then printf 'Storage:\n'; _any=1; fi
        printf '  %s GB (%s): %s\n' "$_gb" "${_b##*/}" "$_model"
    done
    return 0
}

# Curated name for vendor:device, else the honest numeric form. Same table the
# post-install GPU code reads (assets/gpu/ncz-gpu-names.tsv); no pci.ids ships
# in the installer, so no name is invented.
gpu_name() {
    _nm=""
    [ -r "$NAME_TABLE" ] && _nm=$(awk -F'\t' -v k="$1" '$1 == k { print $2; exit }' "$NAME_TABLE")
    [ -n "$_nm" ] && { printf '%s\n' "$_nm"; return 0; }
    case "${1%%:*}" in
        10de) _v=NVIDIA ;; 1002) _v=AMD ;; 8086) _v=Intel ;; 106b) _v=Apple ;;
        1af4) _v=Virtio ;; 1234) _v=QEMU ;; 1b36) _v=Red Hat ;; 15ad) _v=VMware ;;
        *) _v="Device" ;;
    esac
    printf '%s [%s]\n' "$_v" "$1"
}

# The screensaver class, from the classifier the screensaver / GPU clock code
# uses (post-install/lib/gpu-progress.sh ncz_gpu_saver_class -- the GPU-class
# reading ncz-screensaver's class_from_topology / class_from_renderer work
# from, see docs/MINOR-005-panfrost-screensaver-class.md). At install time the
# saver engine is not present, so the classifier's PCI-only arm answers; the
# answer only words the expectation below, nothing is decided from it.
#
# It is NEVER sourced into this shell. lib/gpu-progress.sh is bash and uses
# bash-only redirections in the middle of the file (a sourced function body
# ends a dash/ash parse at that point), and d-i runs this script in an
# ash-family shell. Sourcing it worked under bash and silently stopped the
# dialog under dash -- the exact class-dependency a test must never have. The
# class is therefore asked for in a bash CHILD, every time. When bash is not on
# the medium (it usually is not in d-i) the class is unknowable and the GPU
# line is printed without the expectation -- never a guessed class.
GPU_LIB="${NCZ_GPU_LIB:-$DIR/../post-install/lib/gpu-progress.sh}"
saver_class() {
    [ -n "$1" ] || return 0
    [ -r "$GPU_LIB" ] || return 0
    command -v bash >/dev/null 2>&1 || return 0
    bash -c '. "$1" >/dev/null 2>&1; ncz_gpu_saver_class "$2"' _ "$GPU_LIB" "$1" 2>/dev/null
    return 0
}

# <class> -> one plain-English sentence, worded from the same table the saver
# policy reads (assets/gpu/ncz-screensaver-strength.tsv).
saver_expectation() {
    [ -n "$1" ] || return 0
    [ -r "$STRENGTH_TABLE" ] || return 0
    _w=$(awk -F'\t' -v k="$1" '$1 == k { print $2; exit }' "$STRENGTH_TABLE")
    [ -n "$_w" ] && printf 'screensavers expect %s' "$_w"
    return 0
}

p_gpu() {
    _any=0
    _pci=$(_pci_devices)
    [ -n "$_pci" ] || return 0
    while read -r _cls _key; do
        case "$_cls" in 0300*|0301*|0302*|0380*) ;; *) continue ;; esac
        if [ "$_any" = 0 ]; then printf 'GPU:\n'; _any=1; fi
        # A secondary display controller inside the same silicon repeats the
        # primary's name; say which one this is instead of printing it twice.
        _base=$(gpu_name "$_key")
        _name=$_base
        case "$_base" in "$_last_name") _name="$_name, secondary display function" ;; esac
        _last_name=$_base
        _cls_v=$(saver_class "$_key" 2>/dev/null)
        _exp=$(saver_expectation "$_cls_v")
        printf '  %s%s\n' "$_name" "${_exp:+ - $_exp}"
    done <<EOF
$_pci
EOF
    return 0
}

p_accelerators() {
    _pci=$(_pci_devices)
    [ -n "$_pci" ] || return 0
    _any=0
    while read -r _cls _key; do
        case "$_cls" in 0b40*) ;; *) continue ;; esac
        if [ "$_any" = 0 ]; then printf 'Accelerators:\n'; _any=1; fi
        case "${_key%%:*}" in
            8086) _what="Intel NPU (AI accelerator)" ;;
            10de) _what="NVIDIA accelerator" ;;
            *)    _what="AI / processing accelerator" ;;
        esac
        printf '  %s: %s\n' "$(gpu_name "$_key")" "$_what"
    done <<EOF
$_pci
EOF
    # NVIDIA compute support, by the same arithmetic family test
    # post-install/lib/cuda-select.sh uses (thresholds on the device id).
    _nv=$(printf '%s\n' "$_pci" | awk '$2 ~ /^10de:/ { print $2; exit }')
    if [ -n "$_nv" ]; then
        _id=0x${_nv#*:}
        if [ "$((_id))" -ge $((0x1e00)) ]; then _cu="Turing or newer, CUDA supported"
        elif [ "$((_id))" -ge $((0x1340)) ]; then _cu="Maxwell to Volta, legacy CUDA only"
        else _cu="Kepler or older, no CUDA driver on Debian forky"; fi
        [ "$_any" = 0 ] && { printf 'Accelerators:\n'; _any=1; }
        printf '  NVIDIA compute: %s\n' "$_cu"
    fi
    # CIX Sky1's NPU (Zhouyi/aipu) and VPU (amvx) are SoC platform devices,
    # not PCI: identified from DMI / the device tree, the same identity
    # ncz_ui_id() uses for the Sky1 label.
    case "$(_rfile "$DMI/sys_vendor")$(_rfile "$DMI/product_name")$(_rfile "$SYS/firmware/devicetree/base/compatible" | tr -d '\000')" in
        *CIX*|*Cix*|*cix*|*Sky1*|*CP8180*)
            [ "$_any" = 0 ] && { printf 'Accelerators:\n'; _any=1; }
            printf '  CIX Sky1 NPU and VPU (on-SoC AI and video engines)\n' ;;
    esac
    return 0
}

p_other() {
    _pci=$(_pci_devices)
    _any=0
    _t2=0
    # Apple T2: PCI [106b:1801] (the T2 bridge) -- the primary signal
    # post-install/lib/hw-detect.sh is_t2_hardware() uses -- or, as there,
    # the DMI fallback narrowed to the T2-era model list.
    if printf '%s\n' "$_pci" | grep -qx '.* 106b:1801'; then _t2=1; fi
    if [ "$_t2" = 0 ]; then
        case "$(_rfile "$DMI/sys_vendor")" in
            "Apple Inc."|"Apple Computer, Inc.")
                case "$(_rfile "$DMI/product_name")" in
                    MacBookPro15,[1-4]|MacBookPro16,[1-4]|MacBookAir8,[12]|MacBookAir9,1|Macmini8,1|MacPro7,1|iMac19,[12]|iMac20,[12]|iMacPro1,1)
                        _t2=1 ;;
                esac ;;
        esac
    fi
    if [ "$_t2" = 1 ]; then
        printf 'Other:\n'; _any=1
        printf '  Apple T2 security chip: T2 firmware and drivers are installed\n'
    fi
    if printf '%s\n' "$_pci" | grep -q '^0c0340 '; then
        [ "$_any" = 0 ] && { printf 'Other:\n'; _any=1; }
        printf '  Thunderbolt / USB4 controller\n'
    fi
    [ "$_any" = 1 ] && printf '.\n'
    return 0
}

render_body() {
    p_system
    p_cpu
    p_memory
    p_storage
    p_gpu
    p_accelerators
    p_other
}

# ASCII only: newt's C locale shows anything else as <ERR>.
_ascii() { LC_ALL=C tr -c '[:print:]\n' '?'; }

if [ "$MODE" = --collect ]; then
    render_body 2>/dev/null | _ascii
    exit 0
fi

# ------------------------------------------------------------------- dialog
if [ -e "$STATE" ]; then
    _log "skip: already shown this boot ($STATE)"
    exit 0
fi

_template() {
    printf 'Template: ncz/hw-summary\n'
    printf 'Type: note\n'
    printf 'Description: %s - HARDWARE SUMMARY\n' "$(ncz_ui_brand)"
    printf ' This is the machine NCZ-OS is being installed on.\n'
    printf ' .\n'
    # Every body line becomes a continuation line; a blank one becomes ".",
    # debconf's spelling of an empty line in a Description body.
    printf '%s\n' "$BODY" | sed 's/^$/./; s/^/ /'
    printf ' .\n'
    printf ' The install continues on the next screen.\n'
    _id=$(ncz_ui_id 2>/dev/null)
    [ -n "$_id" ] && printf ' %s\n' "$_id"
    return 0
}

BODY=$(render_body 2>/dev/null | _ascii | sed 's/^[[:space:]]*$//')
[ -n "$BODY" ] || BODY="No hardware could be identified on this machine."

# --render: the exact debconf template, on stdout, shown to nobody. It is what
# the tests assert against and what an operator can paste into a bug report.
if [ "$MODE" = --render ]; then
    _template
    exit 0
fi

_TPL="$NCZ_TMP/ncz-hwsummary.templates.$$"
_template > "$_TPL" 2>/dev/null

_shown=0
if [ -r "$_TPL" ]; then
    # The real d-i frontend (partman/early_command) provides the confmodule
    # functions AND the environment db_* needs (DEBCONF_REDIR, the $0 it opens
    # template/communicate channels on). The tests provide the same names as
    # shell functions. Under busybox ash every helper sits in one subshell, so
    # the frontend reaches its own caller and db_go returns the operator's
    # answer; the `&&` chain below is the same shape partman/early_command uses
    # for the choosers -- db_input failing means the operator saw nothing, so
    # the marker must not be written (the next boot retries).
    if loadtemplate "$_TPL" 2>/dev/null \
       && db_fset ncz/hw-summary seen false 2>/dev/null \
       && db_settitle ncz/hw-summary 2>/dev/null \
       && db_input critical ncz/hw-summary 2>/dev/null \
       && db_go 2>/dev/null; then
        _shown=1
    fi
fi
rm -f "$_TPL"

if [ "$_shown" = 1 ]; then
    : > "$STATE" 2>/dev/null
    _log "shown"
else
    _log "could not show the dialog (no frontend/failed template); continuing the install"
fi
exit 0
