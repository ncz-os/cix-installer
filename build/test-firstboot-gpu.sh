#!/bin/bash
# test-firstboot-gpu.sh -- first boot and the end of the install must explain
# an outstanding DKMS (GPU driver) build truthfully (docs/GPU-INSTALL-PROGRESS.md,
# "First boot").
#
#   1. lib/dkms-pending.sh classifies pending *-dkms packages from a fake
#      dpkg status: needed (no build yet) vs failed (make.log for that kernel
#      holds a compiler error), and the install-end notice says so in ASCII,
#      with the first error line, and only when something is outstanding
#   2. lib/firstboot-gpu.sh, needed case: a long fake DKMS build (driven by a
#      fake dpkg) runs to completion -- never cut -- while a live status from
#      lib/gpu-progress.sh's monitor reaches the console (or plymouth when
#      plymouthd answers), then "GPU drivers ready"
#   3. failed case: the known-failing build is NOT rerun before the login
#      screen; every other pending package is still configured; the failure
#      line with the reason and the retry note is shown
#   4. nothing pending: bare `dpkg --configure -a`, no message
#   5. wiring: both ncz-firstboot twins call the helper (with the bare
#      fallback), the unit has TimeoutStartSec=infinity, late.sh shows the
#      GPU variant of the last dialog only when there is a notice, templates
#      stay ASCII, no bare db_go
#
# Scratch lives under $TMPDIR (set it to local disk, never a tmpfs).
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LIBDIR="$ROOT/post-install/lib"
DP="$LIBDIR/dkms-pending.sh"
FBG="$LIBDIR/firstboot-gpu.sh"
LATE="$ROOT/preseed/late.sh"
EXT="$ROOT/preseed/extract-rootfs.sh"
STUB="$ROOT/build/iso/patch-debootstrap-stub.py"
SH="${TEST_SH:-sh}"
KV=7.3.0-rc7-t2-ncz

W="$(mktemp -d "${TMPDIR:-/var/tmp}/firstboot-gpu-test.XXXXXX")"
cleanup() { rm -rf "$W"; }
trap cleanup EXIT

PASS=0; FAILS=0
ok()  { echo "PASS  $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL  $1"; FAILS=$((FAILS + 1)); }
check() { local name="$1"; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }

for f in "$DP" "$FBG"; do [ -f "$f" ] || { echo "FAIL  $f is missing"; exit 1; }; done

# ------------------------------------------------------------ fixtures
# mk_root <dir> <nvidia-status> : dpkg status with falkon unpacked, the NVIDIA
# DKMS package in <nvidia-status> (or "none" = not installed), its dependent
# nvidia-driver unpacked, and an unrelated installed package.
mk_root() {
    local r="$1" st="$2"
    mkdir -p "$r/var/lib/dpkg/info" "$r/var/lib/dkms" "$r/etc/systemd/system/timers.target.wants" \
             "$r/etc/ncz" "$r/var/lib/ncz"
    {
        printf 'Package: bash\nStatus: install ok installed\nArchitecture: amd64\nVersion: 5.3\n\n'
        printf 'Package: falkon\nStatus: install ok unpacked\nArchitecture: amd64\nVersion: 25.08\n\n'
        if [ "$st" != none ]; then
            printf 'Package: nvidia-kernel-open-dkms\nStatus: install ok %s\nArchitecture: amd64\nVersion: 615.71.09-2\n\n' "$st"
            printf 'Package: nvidia-driver\nStatus: install ok unpacked\nArchitecture: amd64\nVersion: 615.71.09-2\n\n'
        fi
        printf 'Package: libnvidia-egl-gbm1\nStatus: install ok installed\nMulti-Arch: same\nArchitecture: amd64\nVersion: 1.1\n'
    } > "$r/var/lib/dpkg/status"
    printf '#!/bin/sh\nset -e\n# Automatically added by dh_dkms/3.2.2-1~deb13u1\nDKMS_NAME=nvidia\nDKMS_PACKAGE_NAME=$DKMS_NAME-dkms\nDKMS_VERSION=615.71.09\n' \
        > "$r/var/lib/dpkg/info/nvidia-kernel-open-dkms.postinst"
}
mk_retry() {  # ncz-cuda-setup timer enabled + selection, not done
    : > "$1/etc/systemd/system/timers.target.wants/ncz-cuda-setup.timer"
    echo FAMILY=turing-plus > "$1/etc/ncz/cuda-selection.conf"
}
mk_failed_log() {  # the real GU502LV failure, incl. gcc's UTF-8 quotes
    local b="$1/var/lib/dkms/nvidia/615.71.09/build"
    mkdir -p "$b"
    {
        echo "DKMS (dkms-3.2.2) make.log for nvidia/615.71.09 for kernel ${2:-$KV} (x86_64)"
        echo "Tue Oct  6 11:36:55 EDT 2026"
        echo "  CC [M]  nvidia/nv-report-err.o"
        printf 'nvidia/os-interface.c:3031:48: error: passing argument 1 of \342\200\230dmem_cgroup_register_region\342\200\231 makes pointer from integer without a cast [-Wint-conversion]\n'
        echo "make: *** [Makefile:59: modules] Error 2"
    } > "$b/make.log"
}
is_ascii() { ! printf '%s' "$1" | LC_ALL=C grep -q '[^ -~]'; }

notice() { env -i PATH="$PATH" "$SH" -c '. "$1"; ncz_firstboot_gpu_notice "$2"' _ "$DP" "$1"; }
classify() { env -i PATH="$PATH" "$SH" -c '. "$1"; ncz_dkms_classify "$2" "$3"' _ "$DP" "$1" "${2:-}"; }

# ------------------------------------------------------------ 1. classification + install-end notice
mk_root "$W/r-none" none
mk_root "$W/r-ok" installed
mk_root "$W/r-needed" half-configured
mk_root "$W/r-failed" half-configured; mk_failed_log "$W/r-failed"; mk_retry "$W/r-failed"
mk_root "$W/r-failed-noretry" half-configured; mk_failed_log "$W/r-failed-noretry"
mk_root "$W/r-otherkernel" half-configured; mk_failed_log "$W/r-otherkernel" 7.2.8-ncz

check "nothing pending (no DKMS package): no notice at all" test -z "$(notice "$W/r-none")"
check "DKMS package fully installed (built at install): no notice at all" test -z "$(notice "$W/r-ok")"
c=$(classify "$W/r-needed")
check "half-configured DKMS package without a build log is 'needed'" \
    test "$c" = "needed|nvidia-kernel-open-dkms|nvidia|615.71.09|-|-"
n=$(notice "$W/r-needed")
check "needed: the notice says first boot builds it, login may take several minutes, do not power off" \
    sh -c 'case "$1" in "First boot will finish setting up your GPU drivers (a DKMS build of nvidia 615.71.09). The login screen may take several minutes to appear. Do not power off.") exit 0;; esac; echo "  got: $1"; exit 1' _ "$n"
c=$(classify "$W/r-failed" "$KV")
check "a compiler error in make.log for this kernel makes it 'failed', with the ASCII reason line" \
    test "$c" = "failed|nvidia-kernel-open-dkms|nvidia|615.71.09|$KV|os-interface.c:3031: error: passing argument 1 of 'dmem_cgroup_register_region' makes pointer from integer without a cast [-Wint-conversion]"
n=$(notice "$W/r-failed")
check "failed: the notice names the driver, the first error line, the open-source fallback and who retries it" \
    sh -c 'case "$1" in "GPU driver build failed for this kernel (nvidia 615.71.09): os-interface.c:3031: error: passing argument 1 of '"'"'dmem_cgroup_register_region'"'"' makes pointer"*"The desktop uses the open-source driver for now; ncz-cuda-setup retries it automatically once the kernel or the driver changes"*) exit 0;; esac; echo "  got: $1"; exit 1' _ "$n"
check "failed: notice is ASCII (gcc's UTF-8 quotes converted)" is_ascii "$n"
n=$(notice "$W/r-failed-noretry")
check "failed without the NVIDIA retry timer: says how to retry instead of naming ncz-cuda-setup" \
    sh -c 'case "$1" in *"sudo dpkg --configure -a"*) case "$1" in *ncz-cuda-setup*) exit 1;; esac; exit 0;; esac; echo "  got: $1"; exit 1' _ "$n"
c=$(classify "$W/r-otherkernel" "$KV")
check "a compiler error recorded for ANOTHER kernel does not count as failed for this one" \
    sh -c 'case "$1" in needed\|*) exit 0;; esac; echo "  got: $1"; exit 1' _ "$c"
mk_root "$W/r-net" none; mk_retry "$W/r-net"; echo pending:network > "$W/r-net/var/lib/ncz/cuda-toolkit.status"
n=$(notice "$W/r-net")
check "NVIDIA driver not downloaded at install (no network): background download+build note" \
    sh -c 'case "$1" in "The NVIDIA driver could not be downloaded during the install."*"restart once it has finished"*) exit 0;; esac; echo "  got: $1"; exit 1' _ "$n"
cfg=$(env -i PATH="$PATH" "$SH" -c '. "$1"; ncz_pkgs_needing_configure "$2"' _ "$DP" "$W/r-failed" | tr '\n' ' ')
check "configure list = every unconfigured package, arch-qualified (falkon, the dkms package, its dependent)" \
    test "$cfg" = "falkon:amd64 nvidia-kernel-open-dkms:amd64 nvidia-driver:amd64 "
if command -v busybox >/dev/null 2>&1; then
    nb=$(env -i PATH="$PATH" busybox sh -c '. "$1"; ncz_firstboot_gpu_notice "$2"' _ "$DP" "$W/r-failed")
    check "the notice is identical under busybox sh (late.sh runs in the d-i busybox)" test "$nb" = "$(notice "$W/r-failed")"
fi

# ------------------------------------------------------------ 2. first boot, build needed: long build, never cut
# fake dpkg: logs its arguments; when asked to configure the DKMS package it
# runs a DKMS-like build whose make.log grows for $FAKE_BUILD_SECS seconds,
# then installs the module and marks the package configured.
cat > "$W/fake-dpkg" <<'FAKE'
#!/bin/bash
R="$FAKE_ROOT"; K="$FAKE_KVER"
echo "dpkg $*" >> "$R/dpkg.calls"
case " $* " in
    *" -a "*|*" nvidia-kernel-open-dkms"*) ;;
    *) exit 0 ;;
esac
grep -q '^Status: install ok half-configured' "$R/var/lib/dpkg/status" || exit 0
b="$R/var/lib/dkms/nvidia/615.71.09/build"; rm -rf "$b"; mkdir -p "$b/src"
for i in $(seq 1 30); do : > "$b/src/f$i.c"; done
echo "DKMS (dkms-3.2.2) make.log for nvidia/615.71.09 for kernel $K (x86_64)" > "$b/make.log"
date >> "$b/make.log"
t0=$(date +%s); i=0
while [ $(( $(date +%s) - t0 )) -lt "$FAKE_BUILD_SECS" ]; do
    i=$((i + 1)); [ "$i" -le 29 ] && echo "  CC [M]  nvidia/f$i.o" >> "$b/make.log"; sleep 0.5
done
echo "  LD [M]  nvidia.ko" >> "$b/make.log"
mkdir -p "$R/var/lib/dkms/nvidia/615.71.09/$K/x86_64/module" "$R/var/lib/dkms/nvidia/615.71.09/$K/x86_64/log"
: > "$R/var/lib/dkms/nvidia/615.71.09/$K/x86_64/module/nvidia.ko"
mv "$b/make.log" "$R/var/lib/dkms/nvidia/615.71.09/$K/x86_64/log/make.log"; rm -rf "$b"
sed -i 's/^Status: install ok half-configured/Status: install ok installed/' "$R/var/lib/dpkg/status"
echo BUILD-COMPLETE >> "$R/dpkg.calls"
FAKE
chmod +x "$W/fake-dpkg"
cat > "$W/fake-modprobe" <<'FAKE'
#!/bin/sh
echo "modprobe $*" >> "$FAKE_ROOT/modprobe.calls"
FAKE
chmod +x "$W/fake-modprobe"
mk_pci() {  # NVIDIA display device, unclaimed unless $2=claimed
    mkdir -p "$1/0000:01:00.0"; echo 0x030000 > "$1/0000:01:00.0/class"; echo 0x10de > "$1/0000:01:00.0/vendor"
    [ "${2:-}" = claimed ] && ln -s /nonexistent/nouveau "$1/0000:01:00.0/driver"
    return 0
}

run_fbg() {  # run_fbg <root> <build-secs> [extra env...]
    local r="$1" secs="$2"; shift 2
    env -i PATH="$PATH" FAKE_ROOT="$r" FAKE_KVER="$KV" FAKE_BUILD_SECS="$secs" \
        NCZ_FBG_ROOT="$r" NCZ_FBG_KVER="$KV" NCZ_FBG_DPKG="$W/fake-dpkg" \
        NCZ_FBG_MODPROBE="$W/fake-modprobe" NCZ_FBG_SYSFS_PCI="$r/pci" \
        NCZ_FBG_LOG="$r/fbg.log" NCZ_FBG_RUN="$r/run" NCZ_FBG_CONSOLE="$r/console" \
        NCZ_FBG_PLYMOUTH="$r/no-plymouth" NCZ_FBG_POLL=1 \
        NCZ_GPU_POLL=0.5 NCZ_GPU_HOLD=0 NCZ_GPU_STALE=3 NCZ_GPU_ETA_MIN_S=1 \
        "$@" bash "$FBG" configure > "$r/stdout" 2>&1
}

R2="$W/fb-needed"; mk_root "$R2" half-configured; mk_retry "$R2"; mk_pci "$R2/pci"
t0=$(date +%s); run_fbg "$R2" 12; rc=$?; el=$(( $(date +%s) - t0 ))
check "needed: helper exits 0" test "$rc" = 0
check "needed: the long fake DKMS build ran to completion (not cut short)" grep -q BUILD-COMPLETE "$R2/dpkg.calls"
check "needed: the helper waited for the whole build (${el}s >= 12s)" test "$el" -ge 12
check "needed: it ran the normal 'dpkg --configure -a'" grep -qx 'dpkg --configure -a' "$R2/dpkg.calls"
check "needed: the module exists for the running kernel" test -e "$R2/var/lib/dkms/nvidia/615.71.09/$KV/x86_64/module/nvidia.ko"
check "needed: the console got the start notice (DKMS build, several minutes, do not power off)" \
    grep -q 'NCZ-OS: Finishing GPU driver setup: DKMS build of nvidia 615.71.09. The login screen appears when it is done (several minutes). Do not power off.' "$R2/console"
check "needed: the console got live build status from lib/gpu-progress.sh (module, kernel, file count)" \
    grep -q "NCZ-OS: GPU drivers: building nvidia 615.71.09 for kernel $KV - compiling [0-9]*/30 files" "$R2/console"
check "needed: relayed status carries no stray length argument (gpu-progress _g_clean took \$* not \$1)" \
    sh -c '! grep -q " 130.\{0,1\}$" "$1"' _ "$R2/console"
check "needed: the status line changed while the build ran (more than one distinct count)" \
    test "$(grep -o 'compiling [0-9]*/30' "$R2/console" | sort -u | wc -l)" -ge 2
check "needed: final 'GPU drivers ready' line, module loaded for the unclaimed NVIDIA GPU" \
    grep -q 'NCZ-OS: GPU drivers ready (nvidia 615.71.09 built and loaded).' "$R2/console"
check "needed: nvidia-drm was modprobed (device had no driver)" grep -qx 'modprobe nvidia-drm' "$R2/modprobe.calls"
check "needed: every console line is ASCII" sh -c '! LC_ALL=C grep -q "[^ -~[:cntrl:]]" "$1"' _ "$R2/console"
check "needed: status lines also went to the journal (stdout)" grep -q '^ncz-firstboot: GPU drivers ready' "$R2/stdout"
left_running() {  # processes still carrying this run's progress file in their environment
    local e
    for e in /proc/[0-9]*/environ; do
        grep -qaF "NCZ_PROGRESS_FILE=$1" "$e" 2>/dev/null && { echo "  still running: ${e%/environ}"; return 0; }
    done
    return 1
}
no_left_running() { ! left_running "$1"; }
check "needed: no monitor left running afterwards" no_left_running "$R2/run/progress.state"

# interrupted helper: TERM mid-build; once the build returns, neither the
# monitor nor the status relay may be left running
fbg_procs() {  # helper/monitor/relay processes of run <root> still alive
    local d c
    for d in /proc/[0-9]*; do
        c=$(tr '\0' ' ' < "$d/cmdline" 2>/dev/null) || continue
        case "$c" in *firstboot-gpu.sh*|*gpu-progress.sh*) ;; *) continue ;; esac
        grep -qaF "NCZ_FBG_RUN=$1/run" "$d/environ" 2>/dev/null && echo "${d#/proc/}"
    done
}
R8="$W/fb-interrupted"; mk_root "$R8" half-configured; mk_retry "$R8"; mk_pci "$R8/pci"
run_fbg "$R8" 8 & FBGPID=$!
sleep 3
find_helper() {  # the helper's own PID (not its relay subshell: the oldest match)
    local d c
    for d in /proc/[0-9]*; do
        c=$(tr '\0' ' ' < "$d/cmdline" 2>/dev/null) || continue
        [ "${c#bash "$FBG" configure}" != "$c" ] || continue
        grep -qaF "NCZ_FBG_RUN=$1/run" "$d/environ" 2>/dev/null && echo "${d#/proc/}"
    done | sort -n | head -n 1
}
HPID=$(find_helper "$R8")
[ -n "$HPID" ] && kill -TERM "$HPID"
wait "$FBGPID" 2>/dev/null
sleep 2
check "interrupted: the helper was found and signalled" test -n "$HPID"
check "interrupted: the build itself still ran to completion" grep -q BUILD-COMPLETE "$R8/dpkg.calls"
check "interrupted: no helper, monitor or relay process left behind" test -z "$(fbg_procs "$R8")"

# plymouth path + a GPU already claimed by another driver (restart needed)
R3="$W/fb-plymouth"; mk_root "$R3" half-configured; mk_retry "$R3"; mk_pci "$R3/pci" claimed
cat > "$W/fake-plymouth" <<'FAKE'
#!/bin/sh
case "$1" in --ping) exit 0 ;; display-message) echo "$2" >> "$FAKE_ROOT/plymouth.msgs" ;; esac
FAKE
chmod +x "$W/fake-plymouth"
run_fbg "$R3" 4 NCZ_FBG_PLYMOUTH="$W/fake-plymouth"
check "plymouth up: messages go through 'plymouth display-message'" \
    grep -q -- '--text=Finishing GPU driver setup: DKMS build of nvidia 615.71.09' "$R3/plymouth.msgs"
check "plymouth up: final line via plymouth, restart needed because another driver holds the GPU" \
    grep -q -- '--text=GPU drivers ready (nvidia 615.71.09 built). It is used after the next restart.' "$R3/plymouth.msgs"
check "plymouth up: nothing written to the plain console" test ! -s "$R3/console"
check "claimed GPU: no modprobe attempted" test ! -e "$R3/modprobe.calls"

# needed, but the first-boot build fails too: truthful failure line
cat > "$W/fake-dpkg-fail" <<'FAKE'
#!/bin/bash
R="$FAKE_ROOT"; echo "dpkg $*" >> "$R/dpkg.calls"
b="$R/var/lib/dkms/nvidia/615.71.09/build"; mkdir -p "$b"
echo "DKMS (dkms-3.2.2) make.log for nvidia/615.71.09 for kernel $FAKE_KVER (x86_64)" > "$b/make.log"
echo "nvidia/nv.c:10:2: error: unknown type name 'foo_t'" >> "$b/make.log"
exit 1
FAKE
chmod +x "$W/fake-dpkg-fail"
R4="$W/fb-needed-fails"; mk_root "$R4" unpacked; mk_retry "$R4"; mk_pci "$R4/pci"
run_fbg "$R4" 1 NCZ_FBG_DPKG="$W/fake-dpkg-fail"; rc=$?
check "needed but the build fails: helper still exits 0 (first boot continues to the login screen)" test "$rc" = 0
check "needed but the build fails: failure line with the compiler error and who retries it" \
    grep -q "NCZ-OS: GPU driver build failed for this kernel (nvidia 615.71.09): nv.c:10: error: unknown type name 'foo_t'. The desktop uses the open-source driver for now; ncz-cuda-setup retries it automatically once the kernel or the driver changes (status: ncz-cuda-setup status)." "$R4/console"
check "needed but the build fails: never claims 'ready'" sh -c '! grep -q "GPU drivers ready" "$1"' _ "$R4/console"

# ------------------------------------------------------------ 3. first boot, build already failed at install: not rerun
R5="$W/fb-failed"; mk_root "$R5" half-configured; mk_failed_log "$R5"; mk_retry "$R5"; mk_pci "$R5/pci"
t0=$(date +%s); run_fbg "$R5" 30; el=$(( $(date +%s) - t0 ))
check "failed at install: the doomed build is NOT rerun before the login screen (${el}s)" \
    sh -c '! grep -q BUILD-COMPLETE "$1" && [ "$2" -lt 10 ]' _ "$R5/dpkg.calls" "$el"
check "failed at install: dpkg configures the other packages but not the failed DKMS package" \
    grep -qx 'dpkg --configure falkon:amd64 nvidia-driver:amd64' "$R5/dpkg.calls"
check "failed at install: no 'dpkg --configure -a' (it would rerun the failing build)" \
    sh -c '! grep -q -- "--configure -a" "$1"' _ "$R5/dpkg.calls"
check "failed at install: console explains it with the make.log reason and the background retry" \
    grep -q "NCZ-OS: GPU driver build failed for this kernel (nvidia 615.71.09): os-interface.c:3031: error: passing argument 1 of 'dmem_cgroup_register_region' makes pointer from integer without a cast \[-Wint-conversion\]. The desktop uses the open-source driver for now; ncz-cuda-setup retries it automatically once the kernel or the driver changes (status: ncz-cuda-setup status)." "$R5/console"
check "failed at install: no 'Finishing GPU driver setup' (nothing is being built)" \
    sh -c '! grep -q "Finishing GPU driver setup" "$1"' _ "$R5/console"

# a non-GPU DKMS module (e.g. an Apple T2 or NPU driver) is not called a GPU driver
R7="$W/fb-nongpu"; mk_root "$R7" none
printf 'Package: applesmc-t2-dkms\nStatus: install ok half-configured\nArchitecture: amd64\nVersion: 1.0\n\n' >> "$R7/var/lib/dpkg/status"
printf 'DKMS_NAME=applesmc-t2\nDKMS_VERSION=1.0\n' > "$R7/var/lib/dpkg/info/applesmc-t2-dkms.postinst"
n=$(notice "$R7")
check "non-GPU module, needed: 'setting up your drivers', not 'GPU drivers'" \
    sh -c 'case "$1" in "First boot will finish setting up your drivers (a DKMS build of applesmc-t2 1.0)."*) exit 0;; esac; echo "  got: $1"; exit 1' _ "$n"
b="$R7/var/lib/dkms/applesmc-t2/1.0/build"; mkdir -p "$b"
printf 'DKMS (dkms-3.2.2) make.log for applesmc-t2/1.0 for kernel %s (x86_64)\napplesmc.c:5:1: error: expected declaration\n' "$KV" > "$b/make.log"
n=$(notice "$R7")
check "non-GPU module, failed: 'Driver build failed', no open-source GPU fallback claim" \
    sh -c 'case "$1" in "Driver build failed for this kernel (applesmc-t2 1.0): applesmc.c:5: error: expected declaration. The module is unavailable for now; it is retried"*) exit 0;; esac; echo "  got: $1"; exit 1' _ "$n"

# ------------------------------------------------------------ 4. nothing pending
R6="$W/fb-none"; mk_root "$R6" installed; mk_pci "$R6/pci"
run_fbg "$R6" 1
check "nothing pending: plain 'dpkg --configure -a'" grep -qx 'dpkg --configure -a' "$R6/dpkg.calls"
check "nothing pending: no screen output at all" sh -c 'test ! -s "$1" && test ! -s "$2"' _ "$R6/console" "$R6/stdout"

# ------------------------------------------------------------ 5. wiring
fb_body() { awk '/<<.FBS.$/{f=1;next} /^FBS$/{f=0} f' "$1"; }
unit_body() { awk '/<<.FBU.$/{f=1;next} /^FBU$/{f=0} f' "$1"; }
helper_block() { fb_body "$1" | awk '/^_fbg=/{f=1} f{print} f && /^fi$/{exit}'; }
for t in "$EXT" "$STUB"; do
    b=$(basename "$t")
    check "$b: ncz-firstboot runs lib/firstboot-gpu.sh configure, bare dpkg --configure -a as fallback" \
        sh -c 'printf "%s\n" "$1" | grep -q "bash \"\$_fbg\" configure || dpkg --configure -a" && printf "%s\n" "$1" | grep -q "^    dpkg --configure -a 2>/dev/null || true$"' _ "$(helper_block "$t")"
    check "$b: ncz-firstboot.service has TimeoutStartSec=infinity" sh -c 'printf "%s\n" "$1" | grep -qx "TimeoutStartSec=infinity"' _ "$(unit_body "$t")"
    check "$b: ncz-firstboot still ordered before the display manager" sh -c 'printf "%s\n" "$1" | grep -q "^Before=display-manager.service"' _ "$(unit_body "$t")"
    check "$b: the generated ncz-firstboot is valid sh" sh -c 'printf "%s\n" "$1" | sh -n' _ "$(fb_body "$t")"
done
check "both twins carry the identical helper block" test "$(helper_block "$EXT")" = "$(helper_block "$STUB")"
check "both twins carry the identical unit" test "$(unit_body "$EXT")" = "$(unit_body "$STUB")"
check "the helper never wraps the build in a timeout" sh -c '! grep -nE "(^|[^_a-z])timeout " "$1"' _ "$FBG"

tpl() { awk -v t="$2" '/^Template: /{f=($2==t)} /^NCZTPL$/{f=0} f' "$1"; }
check "late.sh: the GPU variant of the last dialog carries the \${GPUNOTE} paragraph" \
    sh -c 'printf "%s\n" "$1" | grep -qx " \\\\\${GPUNOTE}"' _ "$(tpl "$LATE" nclawzero/remove-media-gpu)"
check "late.sh: the plain remove-media dialog is unchanged (no GPU text)" \
    sh -c '! printf "%s\n" "$1" | grep -qi "gpu"' _ "$(tpl "$LATE" nclawzero/remove-media)"
check "late.sh: the GPU dialog is chosen only when there is a notice" \
    grep -A3 'if \[ -n "\$NCZ_GPU_NOTE" \]; then' "$LATE" | grep -q '_ncz_rm_tpl=nclawzero/remove-media-gpu'
check "late.sh: the notice comes from lib/dkms-pending.sh against /target" \
    grep -q 'ncz_firstboot_gpu_notice /target' "$LATE"
check "late.sh: GPUNOTE is substituted before the dialog is shown" \
    sh -c 'a=$(grep -n "db_subst \"\$_ncz_rm_tpl\" GPUNOTE" "$1" | cut -d: -f1); b=$(grep -n "db_input critical \"\$_ncz_rm_tpl\"" "$1" | cut -d: -f1); [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]' _ "$LATE"
tpl_ascii() {
    awk '!r && match($0, /<<-?[\047"]?[A-Z]*TPL/) { w=substr($0, RSTART, RLENGTH); gsub(/[<\047"-]/, "", w); r=1; next }
         r && $0 == w { r=0; next }
         r && /[^\001-\177]/ { print FILENAME ": non-ASCII: " $0; bad=1 } END { exit bad }' "$LATE"
}
check "late.sh templates stay ASCII" tpl_ascii
check "late.sh has no bare db_go" sh -c '! grep -nE "^db_go[[:space:]]*$" "$1"' _ "$LATE"
check "new libs are ASCII" sh -c '! LC_ALL=C grep -nq "[^ -~[:space:]]" "$1" "$2"' _ "$DP" "$FBG"
check "dkms-pending.sh parses under sh -n" "$SH" -n "$DP"
check "firstboot-gpu.sh parses under bash -n" bash -n "$FBG"
check "late.sh parses under sh -n" "$SH" -n "$LATE"

echo
echo "test-firstboot-gpu: $PASS passed, $FAILS failed"
[ "$FAILS" = 0 ]
