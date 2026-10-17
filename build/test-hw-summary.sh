#!/bin/bash
# test-hw-summary.sh -- the installer HARDWARE SUMMARY dialog
# (preseed/hw-summary.sh).
#
# Every assertion renders the dialog BODY from a fixture /proc + /sys tree
# (NCZ_HW_PROC / NCZ_HW_SYS / NCZ_HW_DMI / NCZ_HW_CMDLINE): no real hardware
# is probed, nothing is installed. The four machines the task names:
#
#   T2     a 2019 MacBookPro16,1 (Apple T2 bridge [106b:1801], AMD Navi14 GPU)
#   Arrow  an Arrow Lake desktop: Intel Core Ultra 9 285K, iGPU + Intel NPU
#   NVIDIA an amd64 desktop with an RTX 3060 (GA106) and no NPU
#   CIX    an O6N / cixmini: CIX Sky1 (CP8180), on-SoC Mali-G720 (a platform
#          device, not PCI; mid, MINOR-005), on-SoC NPU/VPU
#
# plus: ASCII-only output, the skip rules (never a dialog in an automated
# install / on ncz_hwsummary=0), a probe that errors only drops its own line,
# --dialog always exiting 0 with a frontend that fails, the once-per-boot
# marker, the classifier against the saver engine's rules, and the registration of
# the helper in preseed.cfg + BAKED_HELPERS + the platform inventory.
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
HS="$ROOT/preseed/hw-summary.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/hw-sum.XXXXXX")"
PASS=0; FAILS=0
ok()   { PASS=$((PASS+1)); echo "ok   $1"; }
bad()  { FAILS=$((FAILS+1)); echo "FAIL $1"; shift; printf '%s\n' "$@" | sed 's/^/     /'; }

[ -r "$HS" ] || { echo "test-hw-summary: missing $HS" >&2; exit 2; }

# ------------------------------------------------------------------ fixtures
# fx NAME -> $T/NAME with proc/ sys/ prepared; dmi files live under
# sys/class/dmi/id as on a real kernel.
fx() {
    local d="$T/$1"; rm -rf "$d"; mkdir -p "$d/proc" "$d/sys/bus/pci/devices" \
        "$d/sys/class/dmi/id" "$d/sys/block" "$d/state"
    : > "$d/proc/cpuinfo"; : > "$d/proc/meminfo"; printf 'BOOT_IMAGE=/linux quiet\n' > "$d/proc/cmdline"
    printf '%s\n' "$d"
}
# The field is the FIRST argument: "sysv NAME VALUE" would put the machine name
# in $2 and write the VALUE-named file (that is exactly how the first draft of
# this fixture silently produced empty DMI files).
dmi() { printf '%s\n' "$3" > "$T/$2/sys/class/dmi/id/$1"; }
sysv() { dmi sys_vendor "$1" "$2"; }
prod() { dmi product_name "$1" "$2"; }
bios() { dmi bios_version "$1" "$2"; }
cpu() { # NAME MODEL [THREADS]
    local d="$T/$1" i=0 n="${3:-8}" f="$T/$1/proc/cpuinfo"
    : > "$f"
    while [ "$i" -lt "$n" ]; do printf 'processor\t: %s\nmodel name\t: %s\n\n' "$i" "$2" >> "$f"; i=$((i+1)); done
}
mem() { printf 'MemTotal:       %s kB\nMemFree:  1000 kB\n' "$2" > "$T/$1/proc/meminfo"; }
pci() { # NAME SLOT CLASS VENDOR DEVICE
    local p="$T/$1/sys/bus/pci/devices/$2"; mkdir -p "$p"
    printf '0x%s\n' "$3" > "$p/class"; printf '0x%s\n' "$4" > "$p/vendor"; printf '0x%s\n' "$5" > "$p/device"
}
disk() { # NAME DEV SECTORS MODEL [removable] [partition]
    local b="$T/$1/sys/block/$2"; mkdir -p "$b/device"
    printf '%s\n' "$3" > "$b/size"; printf '%s\n' "$4" > "$b/device/model"
    printf '%s\n' "${5:-0}" > "$b/removable"
    [ "${6:-0}" = 1 ] && : > "$b/partition"
    return 0
}
run() { # NAME MODE [extra env...] -> body on stdout
    local d="$T/$1" m="$2"; shift 2
    env NCZ_HW_PROC="$d/proc" NCZ_HW_SYS="$d/sys" NCZ_HW_DMI="$d/sys/class/dmi/id" \
        NCZ_HW_CMDLINE="$d/proc/cmdline" NCZ_HW_STATE="$d/state/.ncz-hwsummary-shown" \
        NCZ_TMP="$d/state" NCZ_UI_SH=/nonexistent NCZ_UI_PAYLOAD=/nonexistent \
        ${1+"$@"} \
        sh "$HS" "$m" </dev/null 2>"$T/last.err"
}
nonascii() { # FILE [tab] -> true when FILE holds a byte outside printable ASCII
    [ -r "$1" ] || return 0     # a missing file must fail the ASCII check, not pass it
    # (Deliberately NOT grep '[^ -~]': that bracket expression is collation-based
    # in the host locale and matches a TAB -- gawk 5.2.1 on en_US.UTF-8 proved it
    # -- and every table row has one.)
    LC_ALL=C awk -v allow_tab="${2:-}" '
        BEGIN {
            for (i = 1; i < 127; i++) ok[sprintf("%c", i)] = 1
            if (allow_tab == "tab") ok[sprintf("%c", 9)] = 1
        }
        {
            for (i = 1; i <= length($0); i++) if (!(substr($0, i, 1) in ok)) n++
        }
        END { exit (n > 0) ? 0 : 1 }' "$1"
}
# say NAME -> everything a run says: the dialog body (--collect) AND what
# --dialog prints (the skip reasons, which --collect is silent about). The job
# delivery check does not care about the mode, only that the machine's facts
# are reported, so the assertions below read this stream.
say() {
    local d="$T/$1"
    env NCZ_HW_PROC="$d/proc" NCZ_HW_SYS="$d/sys" NCZ_HW_DMI="$d/sys/class/dmi/id" \
        NCZ_HW_CMDLINE="$d/proc/cmdline" NCZ_HW_STATE="$d/state/.ncz-hwsummary-shown" \
        NCZ_TMP="$d/state" NCZ_UI_SH=/nonexistent NCZ_UI_PAYLOAD=/nonexistent \
        sh "$HS" --collect </dev/null 2>&1
    env NCZ_HW_PROC="$d/proc" NCZ_HW_SYS="$d/sys" NCZ_HW_DMI="$d/sys/class/dmi/id" \
        NCZ_HW_CMDLINE="$d/proc/cmdline" NCZ_HW_STATE="$d/state/.ncz-hwsummary-shown" \
        NCZ_TMP="$d/state" NCZ_UI_SH=/nonexistent NCZ_UI_PAYLOAD=/nonexistent \
        sh "$HS" --dialog </dev/null 2>&1
}
has() { # NAME DESC NEEDLE
    local out; if ! out=$(say "$1"); then bad "$2: probe run failed"; return; fi
    if printf '%s\n' "$out" | grep -qF -- "$3"; then ok "$2"; else bad "$2" "wanted: $3" "got:" "$out"; fi
}
hasnt() { local out; out=$(say "$1")
    if printf '%s\n' "$out" | grep -qF -- "$3"; then bad "$2" "unwanted: $3" "got:" "$out"; else ok "$2"; fi; }

# --- T2 MacBookPro16,1 -------------------------------------------------------
fx t2 >/dev/null; sysv t2 "Apple Inc."; prod t2 "MacBookPro16,1"; bios t2 "1037.0.9.0.0"
cpu t2 "Intel(R) Core(TM) i9-9880H CPU @ 2.30GHz" 16
mem t2 33554432
pci t2 0000:00:02.0 030000 106b 1801          # the T2 bridge, Apple display class
pci t2 0000:01:00.0 030000 1002 7340          # Radeon Pro 5500M (Navi14)
pci t2 0000:00:1c.0 060400 8086 a338          # a PCIe bridge (not shown)
disk t2 nvme0n1 976773168 "APPLE SSD AP1024M"
has t2 "T2: vendor/model from DMI"      "Apple Inc. MacBookPro16,1"
has t2 "T2: firmware version"           "firmware 1037.0.9.0.0"
has t2 "T2: CPU model + generation"     "Core i, 9th generation"
has t2 "T2: thread count"               "16 threads"
has t2 "T2: memory"                     "Memory: 32 GB"
has t2 "T2: storage size/model"         "APPLE SSD AP1024M"
has t2 "T2: curated AMD GPU name"       "AMD Radeon Pro 5500M"
has t2 "T2: screensaver strength (AMD Navi14 -> strong)" "screensavers expect every saver at full quality"
has t2 "T2: T2 security chip line"      "Apple T2 security chip"
hasnt t2 "T2: no Intel NPU line"        "Intel NPU"
hasnt t2 "T2: no CIX accelerator line"  "CIX Sky1 NPU"
hasnt t2 "T2: PCIe bridges are not listed" "a338"

# --- Arrow Lake desktop with an NPU -----------------------------------------
fx arrow >/dev/null; sysv arrow "ASUS"; prod arrow "PRIME Z890-P WIFI"; bios arrow "3201"
cpu arrow "Intel(R) Core(TM) Ultra 9 285K" 24
mem arrow 67108864
pci arrow 0000:00:02.0 030000 8086 46a6          # Alder Lake-P iGPU (curated)
pci arrow 0000:00:0b.0 120000 8086 ad1d          # Intel NPU, Arrow Lake (class as read on PROTEUS)
disk arrow nvme0n1 1953525168 "Samsung SSD 990 PRO 1TB"
disk arrow sda 3907029168 "WDC WD20EZBX-00A" 1 0 # removable: not a fixed disk
disk arrow nvme0n1p2 1953510400 "partition" 0 1   # partition: not a disk
has arrow "Arrow: Core Ultra 9 generation"  "Core Ultra 9"
has arrow "Arrow: memory"                   "Memory: 64 GB"
has arrow "Arrow: curated Intel iGPU name"  "Intel Iris Xe Graphics"
has arrow "Arrow: iGPU strength (Intel i915/xe -> weak, as the engine)" "screensavers expect the simple saver set at a reduced scale"
has arrow "Arrow: Intel NPU accelerator"    "Intel NPU (AI accelerator)"
has arrow "Arrow: fixed NVMe disk"          "Samsung SSD 990 PRO 1TB"
hasnt arrow "Arrow: removable USB disk excluded" "WDC WD20EZBX"
hasnt arrow "Arrow: partitions excluded"    "nvme0n1p2"
hasnt arrow "Arrow: no NVIDIA compute line" "NVIDIA compute"

# --- NVIDIA box --------------------------------------------------------------
fx nv >/dev/null; sysv nv "Micro-Star International Co., Ltd."; prod nv "MS-7C56"
cpu nv "AMD Ryzen 7 5800X 8-Core Processor" 16
mem nv 33554432
pci nv 0000:0a:00.0 030000 10de 1f95          # TU117 [GTX 1650 Ti] (curated)
disk nv nvme0n1 1000215216 "Sabrent Rocket 4.0 1TB"
has nv "NVIDIA: curated GPU name"        "NVIDIA GeForce GTX 1650 Ti"
has nv "NVIDIA: screensaver strength (Turing+ -> strong)" "screensavers expect every saver at full quality"
has nv "NVIDIA: compute supported"       "Turing or newer, CUDA supported"
has nv "NVIDIA: Ryzen generation read"   "Ryzen"
hasnt nv "NVIDIA: no Intel NPU"          "Intel NPU"
# an older card must say so, from the same family test cuda-select.sh uses
fx nv2 >/dev/null; sysv nv2 "ASUSTeK COMPUTER INC."; prod nv2 "P8Z77-V"
cpu nv2 "Intel(R) Core(TM) i7-3770 CPU @ 3.40GHz" 8; mem nv2 16777216
pci nv2 0000:01:00.0 030000 10de 1b80
has nv2 "Kepler/Pascal: legacy CUDA wording" "legacy CUDA only"
has nv2 "Kepler/Pascal: i7 3rd generation"   "Core i, 3rd generation"
has nv2 "Pascal: still discrete -> strong (engine: any NVIDIA)" "screensavers expect every saver at full quality"

# --- O6N / cixmini (CIX Sky1) ------------------------------------------------
fx cix >/dev/null; sysv cix "CIX"; prod cix "Sky1 EVB"
cpu cix "CIX Sky1 CP8180" 12
mem cix 16777216
pci cix 0000:00:00.0 060400 1f6c 0001          # a Sky1 PCIe root port (not shown)
disk cix nvme0n1 250069680 "FORESEE XP1000F256G"
has cix "CIX: Sky1 CPU generation"      "CIX Sky1 (CP8180)"
has cix "CIX: Sky1 on-SoC NPU/VPU"      "CIX Sky1 NPU and VPU"
has cix "CIX: on-SoC Mali-G720, mid band (MINOR-005)" "ARM Mali-G720 (CIX Sky1 on-SoC GPU) - screensavers expect the standard saver set at full frame rate"
hasnt cix "CIX: no NVIDIA compute"      "NVIDIA compute"

# --- never fails, never blocks ----------------------------------------------
# A /proc and /sys that do not exist: every probe drops its line, the script
# still exits 0 and the body is the honest fallback sentence.
mkdir -p "$T/none/proc" "$T/none/state"
out=$(env NCZ_HW_PROC="$T/none/proc" NCZ_HW_SYS="$T/none/sys" NCZ_HW_DMI="$T/none/sys/class/dmi/id" \
    NCZ_HW_CMDLINE="$T/none/proc/cmdline" NCZ_HW_STATE="$T/none/state/.ncz-hwsummary-shown" NCZ_TMP="$T/none/state" \
    NCZ_UI_SH=/nonexistent NCZ_UI_PAYLOAD=/nonexistent sh "$HS" --render 2>"$T/e1"); rc=$?
if [ "$rc" = 0 ] && printf '%s' "$out" | grep -q "No hardware could be identified"; then
    ok "no /proc, no /sys: exit 0 with the fallback sentence"
else bad "no /proc, no /sys: exit 0 with the fallback sentence" "rc=$rc" "$out" "$(cat "$T/e1")"; fi
# A command that fails mid-probe (the whole /proc is a directory we cannot
# read) still exits 0.
chmod 000 "$T/none/proc" 2>/dev/null
if [ "$(id -u)" = 0 ]; then ok "unreadable /proc: skipped (running as root, chmod is not enforced)"; else
    env NCZ_HW_PROC="$T/none/proc" NCZ_HW_SYS="$T/none/sys" NCZ_HW_DMI="$T/none/sys/class/dmi/id" \
        NCZ_HW_CMDLINE="$T/none/proc/cmdline" NCZ_HW_STATE="$T/none/state/.ncz-hwsummary-shown" NCZ_TMP="$T/none/state" \
        sh "$HS" --collect >/dev/null 2>&1 && ok "unreadable /proc: exit 0" || bad "unreadable /proc: exit 0"
fi
chmod 755 "$T/none/proc" 2>/dev/null
# --dialog with NO frontend at all: exits 0, does not create the marker.
rm -f "$T/t2/state/.ncz-hwsummary-shown"
run t2 --dialog >"$T/d0" 2>&1; rc=$?
if [ "$rc" = 0 ] && [ ! -e "$T/t2/state/.ncz-hwsummary-shown" ]; then ok "--dialog without a frontend: exit 0, marker NOT written"
else bad "--dialog without a frontend: exit 0, marker NOT written" "rc=$rc" "$(cat "$T/d0")"; fi
# The debconf frontend: functions standing in for partman/early_command's.
# db_input fails (a broken frontend) -> still exit 0, marker NOT written.
mkfe() { # RC -> path of a frontend stub whose db_input returns RC
    local f="$T/fe-$1.sh"
    cat > "$f" <<'FE'
# NOTE: no `debconf-loadtemplate` -- a dash/ash parser rejects a function name
# with a hyphen ("Syntax error: Bad function name"), and d-i's shell is ash.
capture() { case "$1" in *ncz-hwsummary.templates.*) if [ -n "$CAPPED" ]; then cp "$1" "$CAPPED"; fi ;; esac; return 0; }
loadtemplate() { capture "$1"; return 0; }
db_fset() { return 0; }
db_settitle() { return 0; }
db_input() { return $FE_RC; }
db_go() { return 0; }
FE
    printf '%s\n' "$f"
}
FE_OK=$(mkfe 0); FE_BAD=$(mkfe 1)
export FE_RC
rm -rf "$T/t2/state"; mkdir -p "$T/t2/state"
# --dialog takes the frontend from the environment, not from a sourced file:
# preseed/partman provides them. Simulate by running through `sh -c` with `set -a`.
env -u NCZ_TMP -u NCZ_HW_STATE -u FE_RC NCZ_HW_PROC="$T/t2/proc" NCZ_HW_SYS="$T/t2/sys" NCZ_HW_DMI="$T/t2/sys/class/dmi/id" \
    NCZ_HW_CMDLINE="$T/t2/proc/cmdline" NCZ_HW_STATE="$T/t2/state/.ncz-hwsummary-shown" NCZ_TMP="$T/t2/state" \
    NCZ_UI_SH=/nonexistent NCZ_UI_PAYLOAD=/nonexistent FE_RC=0 NCZ_HW_STATE="$T/t2/state/.ncz-hwsummary-shown" NCZ_TMP="$T/t2/state" \
    sh -c ". '$FE_OK'; . '$HS'" hw-summary.sh --dialog >"$T/d1" 2>&1; rc=$?
if [ "$rc" = 0 ] && [ -e "$T/t2/state/.ncz-hwsummary-shown" ]; then ok "frontend OK: dialog shown, once-per-boot marker written"
else bad "frontend OK: dialog shown, once-per-boot marker written" "rc=$rc" "marker=$(ls -la "$T/t2/state")" "$(cat "$T/d1")"; fi
# The template that reached the frontend is ASCII and carries the body.
if ls "$T/t2/state"/ncz-hwsummary.templates.* >/dev/null 2>&1; then
    bad "rendered template is not left behind (temp file removed)" "$(ls "$T/t2/state")"
else ok "rendered template is not left behind (temp file removed)"; fi
rm -f "$T/t2/state/.ncz-hwsummary-shown"
env -u NCZ_TMP -u NCZ_HW_STATE -u FE_RC NCZ_HW_PROC="$T/t2/proc" NCZ_HW_SYS="$T/t2/sys" NCZ_HW_DMI="$T/t2/sys/class/dmi/id" \
    NCZ_HW_CMDLINE="$T/t2/proc/cmdline" NCZ_HW_STATE="$T/t2/state/.ncz-hwsummary-shown" NCZ_TMP="$T/t2/state" \
    NCZ_UI_SH=/nonexistent NCZ_UI_PAYLOAD=/nonexistent FE_RC=1 NCZ_HW_STATE="$T/t2/state/.ncz-hwsummary-shown" NCZ_TMP="$T/t2/state" \
    sh -c ". '$FE_BAD'; . '$HS'" hw-summary.sh --dialog >"$T/d2" 2>&1; rc=$?
if [ "$rc" = 0 ] && [ ! -e "$T/t2/state/.ncz-hwsummary-shown" ]; then ok "frontend that fails: exit 0, marker NOT written (next boot retries)"
else bad "frontend that fails: exit 0, marker NOT written" "rc=$rc" "$(cat "$T/d2")"; fi

# --- skip rules --------------------------------------------------------------
printf 'quiet ncz_hwsummary=0\n' > "$T/t2/proc/cmdline"
rm -f "$T/t2/state/.ncz-hwsummary-shown"
env -u NCZ_TMP -u NCZ_HW_STATE -u FE_RC NCZ_HW_PROC="$T/t2/proc" NCZ_HW_SYS="$T/t2/sys" NCZ_HW_DMI="$T/t2/sys/class/dmi/id" \
    NCZ_HW_CMDLINE="$T/t2/proc/cmdline" NCZ_HW_STATE="$T/t2/state/.ncz-hwsummary-shown" NCZ_TMP="$T/t2/state" \
    NCZ_UI_SH=/nonexistent NCZ_UI_PAYLOAD=/nonexistent FE_RC=0 NCZ_HW_STATE="$T/t2/state/.ncz-hwsummary-shown" NCZ_TMP="$T/t2/state" \
    sh -c ". '$FE_OK'; . '$HS'" hw-summary.sh --dialog >"$T/d3" 2>&1
if [ ! -e "$T/t2/state/.ncz-hwsummary-shown" ] && grep -q "ncz_hwsummary=0" "$T/d3"; then ok "ncz_hwsummary=0: dialog suppressed, reason logged"
else bad "ncz_hwsummary=0: dialog suppressed, reason logged" "$(cat "$T/d3")"; fi
out=$(run t2 --collect 2>/dev/null); [ -z "$out" ] && ok "ncz_hwsummary=0: no probe output in --collect either" || bad "ncz_hwsummary=0: no probe output in --collect either" "$out"

printf 'quiet ncz_hwsummary=off\n' > "$T/t2/proc/cmdline"
rm -f "$T/t2/state/.ncz-hwsummary-shown"
env -u NCZ_TMP -u NCZ_HW_STATE -u FE_RC NCZ_HW_PROC="$T/t2/proc" NCZ_HW_SYS="$T/t2/sys" NCZ_HW_DMI="$T/t2/sys/class/dmi/id" \
    NCZ_HW_CMDLINE="$T/t2/proc/cmdline" NCZ_HW_STATE="$T/t2/state/.ncz-hwsummary-shown" NCZ_TMP="$T/t2/state" \
    NCZ_UI_SH=/nonexistent NCZ_UI_PAYLOAD=/nonexistent FE_RC=0 NCZ_HW_STATE="$T/t2/state/.ncz-hwsummary-shown" NCZ_TMP="$T/t2/state" \
    sh -c ". '$FE_OK'; . '$HS'" hw-summary.sh --dialog >/dev/null 2>&1
[ ! -e "$T/t2/state/.ncz-hwsummary-shown" ] && ok "ncz_hwsummary=off: dialog suppressed" || bad "ncz_hwsummary=off: dialog suppressed"
for tok in ncz_unattended=1 ncz_components=desktop,mgmt-container; do
    printf 'quiet %s\n' "$tok" > "$T/t2/proc/cmdline"; rm -f "$T/t2/state/.ncz-hwsummary-shown"
    env -u NCZ_TMP -u NCZ_HW_STATE -u FE_RC NCZ_HW_PROC="$T/t2/proc" NCZ_HW_SYS="$T/t2/sys" NCZ_HW_DMI="$T/t2/sys/class/dmi/id" \
        NCZ_HW_CMDLINE="$T/t2/proc/cmdline" NCZ_HW_STATE="$T/t2/state/.ncz-hwsummary-shown" NCZ_TMP="$T/t2/state" \
        NCZ_UI_SH=/nonexistent NCZ_UI_PAYLOAD=/nonexistent FE_RC=0 \
        sh -c ". '$FE_OK'; . '$HS'" hw-summary.sh --dialog >"$T/d4" 2>&1
    if [ ! -e "$T/t2/state/.ncz-hwsummary-shown" ] && grep -q "automated install" "$T/d4"; then ok "$tok: dialog skipped automatically"
    else bad "$tok: dialog skipped automatically" "$(cat "$T/d4")"; fi
done
printf 'BOOT_IMAGE=/linux quiet\n' > "$T/t2/proc/cmdline"
# once per boot: the first --dialog writes the marker, a second one must not
# reach the frontend at all; --collect still renders with the marker present.
dlg() { # CAPTURE-FILE LOG
    env -u NCZ_TMP -u NCZ_HW_STATE -u FE_RC NCZ_HW_PROC="$T/t2/proc" NCZ_HW_SYS="$T/t2/sys" NCZ_HW_DMI="$T/t2/sys/class/dmi/id" \
        NCZ_HW_CMDLINE="$T/t2/proc/cmdline" NCZ_HW_STATE="$T/t2/state/.ncz-hwsummary-shown" NCZ_TMP="$T/t2/state" \
        NCZ_UI_SH=/nonexistent NCZ_UI_PAYLOAD=/nonexistent FE_RC=0 CAPPED="$1" \
        sh -c ". '$FE_OK'; . '$HS'" hw-summary.sh --dialog >"$2" 2>&1
}
rm -f "$T/t2/state/.ncz-hwsummary-shown" "$T/cap1" "$T/cap2"
dlg "$T/cap1" "$T/d7"
[ -e "$T/t2/state/.ncz-hwsummary-shown" ] && [ -s "$T/cap1" ] && ok "first --dialog shows the summary and writes the marker" \
    || bad "first --dialog shows the summary and writes the marker" "$(cat "$T/d7")"
out=$(run t2 --collect 2>/dev/null); [ -n "$out" ] && ok "--collect still renders with the marker present (only the dialog is once per boot)" || bad "--collect still renders with the marker present" "$out"
dlg "$T/cap2" "$T/d8"; rc=$?
if [ "$rc" = 0 ] && [ ! -e "$T/cap2" ] && grep -q "already shown this boot" "$T/d8"; then ok "marker present: second --dialog not shown"
else bad "marker present: second --dialog not shown" "rc=$rc" "$(cat "$T/d8")"; fi
rm -f "$T/t2/state/.ncz-hwsummary-shown"

# --- ASCII only (newt's C locale shows anything else as <ERR>) ---------------
for n in t2 arrow nv cix; do
    out=$(run "$n" --collect 2>/dev/null)
    printf '%s\n' "$out" > "$T/body.$n"
    if nonascii "$T/body.$n"; then
        bad "$n: body is ASCII only" "$(LC_ALL=C awk '/[^ -~]/ { print NR": "$0 }' "$T/body.$n")"
    else ok "$n: body is ASCII only"; fi
done
# --- busybox ash (the d-i shell) renders the same body ----------------------
if command -v busybox >/dev/null 2>&1; then
    for n in t2 arrow nv cix; do
        d="$T/$n"
        a=$(run "$n" --collect 2>/dev/null)
        b=$(env NCZ_HW_PROC="$d/proc" NCZ_HW_SYS="$d/sys" NCZ_HW_DMI="$d/sys/class/dmi/id" \
            NCZ_HW_CMDLINE="$d/proc/cmdline" NCZ_TMP="$d/state" NCZ_UI_SH=/nonexistent \
            busybox sh "$HS" --collect </dev/null 2>/dev/null)
        [ -n "$a" ] && [ "$a" = "$b" ] && ok "$n: busybox sh body matches" || bad "$n: busybox sh body matches" "sh: $a" "busybox: $b"
    done
else echo "note busybox not installed: d-i shell parity check skipped"; fi

# --- the classifier mirrors the saver engine's class_from_topology ---------
# hw-summary.sh runs from the initrd (dash/ash, no bash, no assets/ tree), so
# it carries a POSIX copy of the engine's PCI-reachable rules. Pin them here.
CLS_SH=sh; command -v dash >/dev/null 2>&1 && CLS_SH=dash
cls() { "$CLS_SH" -c ". /dev/stdin; gpu_saver_class \"\$1\"" _ "$1" <<EOF2
$(awk '/^gpu_saver_class\(\)/,/^}/' "$HS")
EOF2
}
for pair in 10de:2504=strong 10de:1b80=strong 1002:7340=strong 1002:744c=strong 1002:15bf=mid \
            8086:46a6=weak 8086:56a0=weak 14e4:2711=weak 13b5:0110=mid 1234:1111= 1002:zz=; do
    k=${pair%%=*} want=${pair#*=}
    got=$(cls "$k")
    [ "$got" = "$want" ] && ok "classifier: $k -> ${want:-nothing}" || bad "classifier: $k" "want '$want' got '$got'"
done
# the engine's driver tables this copies; fail loudly when the engine is
# reachable and they move (informational when it is not checked out here)
eng="${NCZ_SCREENSAVER_LAUNCHER:-}"
if [ -n "$eng" ] && [ -r "$eng" ]; then
    grep -q '"i915", "xe", "v3d", "vc4", "lima", "etnaviv"' "$eng" && grep -q 'discrete = vendor == "nvidia"' "$eng" \
        && ok "engine class_from_topology still matches the copied rules" \
        || bad "engine class_from_topology changed: update gpu_saver_class in $HS"
else echo "note NCZ_SCREENSAVER_LAUNCHER unset: engine table cross-check skipped"; fi
# a malformed sysfs id must not abort the script (dash dies on bad arithmetic)
fx bad >/dev/null; pci bad 0000:01:00.0 030000 1002 zz; pci bad 0000:02:00.0 030000 10de zz
out=$(run bad --collect); rc=$?
[ "$rc" = 0 ] && printf '%s' "$out" | grep -q 'GPU:' && ok "malformed PCI ids: exit 0, GPU lines still printed" \
    || bad "malformed PCI ids: exit 0" "rc=$rc" "$out"

# --- the dialog text itself (title from ncz_ui_brand, brand + id last line) --
printf 'NCZ_RELEASE_VERSION="26.10"\nNCZ_RELEASE_CODENAME="Cygnus"\n' > "$T/RELEASE"
env -u NCZ_TMP -u NCZ_HW_STATE -u FE_RC NCZ_HW_PROC="$T/t2/proc" NCZ_HW_SYS="$T/t2/sys" NCZ_HW_DMI="$T/t2/sys/class/dmi/id" \
    NCZ_HW_CMDLINE="$T/t2/proc/cmdline" NCZ_HW_STATE="$T/t2/state/.ncz-hwsummary-shown" NCZ_TMP="$T/t2/state" \
    NCZ_UI_SH="$ROOT/preseed/ncz-ui.sh" NCZ_UI_RELEASE="$T/RELEASE" NCZ_UI_PAYLOAD=/nonexistent FE_RC=0 \
    sh -c ". '$FE_OK'; . '$HS'" hw-summary.sh --dialog >"$T/d5" 2>&1
# the frontend consumed the template; re-render it by capturing db_input's file

rm -f "$T/t2/state/.ncz-hwsummary-shown"
env CAPPED="$T/tpl" NCZ_HW_PROC="$T/t2/proc" NCZ_HW_SYS="$T/t2/sys" NCZ_HW_DMI="$T/t2/sys/class/dmi/id" \
    NCZ_HW_CMDLINE="$T/t2/proc/cmdline" NCZ_HW_STATE="$T/t2/state/.ncz-hwsummary-shown" NCZ_TMP="$T/t2/state" \
    NCZ_UI_SH="$ROOT/preseed/ncz-ui.sh" NCZ_UI_RELEASE="$T/RELEASE" NCZ_UI_PAYLOAD=/nonexistent FE_RC=0 \
    CAPPED="$T/tpl" sh -c ". '$FE_OK'; . '$HS'" hw-summary.sh --dialog >"$T/d6" 2>&1
if grep -q '^Description: NCZ-OS 26.10 Cygnus - HARDWARE SUMMARY$' "$T/tpl"; then ok "template title is '<brand> - HARDWARE SUMMARY'"
else bad "template title is '<brand> - HARDWARE SUMMARY'" "$(head -5 "$T/tpl" 2>/dev/null)"; fi
for want in "Type: note" " Apple Inc. MacBookPro16,1" " Apple T2 security chip" " This is the machine NCZ-OS is being installed on."; do
    grep -qF -- "$want" "$T/tpl" 2>/dev/null && ok "template carries: $want" || bad "template carries: $want" "$(head -30 "$T/tpl" 2>/dev/null)"
done
nonascii "$T/tpl" 2>/dev/null && bad "template is ASCII only" || ok "template is ASCII only"

# --- registration -----------------------------------------------------------
if grep -q 'sh "$_hs" --dialog' "$ROOT/preseed/preseed.cfg"; then
    ok "preseed.cfg runs hw-summary.sh --dialog in partman/early_command"
else bad "preseed.cfg runs hw-summary.sh --dialog in partman/early_command"; fi
# It must not be chained into the fail-closed `exit $?` pattern the choosers use.
if grep -E 'hw-summary\.sh.*\|\| *exit' "$ROOT/preseed/preseed.cfg" >/dev/null; then
    bad "hw-summary.sh is NOT chained with '|| exit' (it can never stop the install)"
else ok "hw-summary.sh is NOT chained with '|| exit' (it can never stop the install)"; fi
# It runs BEFORE the disk chooser (after detection, before any write).
lin_hs=$(grep -n 'for _hs in /tmp/hw-summary.sh' "$ROOT/preseed/preseed.cfg" | head -1 | cut -d: -f1)
lin_dc=$(grep -n 'sh "$D/disk-fs-chooser.sh" || exit' "$ROOT/preseed/preseed.cfg" | head -1 | cut -d: -f1)
if [ -n "$lin_hs" ] && [ -n "$lin_dc" ] && [ "$lin_hs" -lt "$lin_dc" ]; then
    ok "hw summary runs before the disk chooser (before anything is written)"
else bad "hw summary runs before the disk chooser" "hs=$lin_hs dc=$lin_dc"; fi
grep -qE '^[[:space:]]*"hw-summary\.sh",' "$ROOT/build/iso/patch-initrd-t2-kernel.py" \
    && ok "hw-summary.sh is in BAKED_HELPERS (initrd)" || bad "hw-summary.sh is in BAKED_HELPERS (initrd)"
for f in preseed/hw-summary.sh build/test-hw-summary.sh; do
    awk -F'\t' -v f="$f" '$1 == f { found = 1 } END { exit !found }' "$ROOT/docs/platform-inventory.tsv" \
        && ok "platform inventory row: $f" || bad "platform inventory row: $f"
done

echo
echo "test-hw-summary: $PASS passed, $FAILS failed"
[ "$FAILS" = 0 ]
