#!/bin/bash
# test-gpu-install-progress.sh -- the GPU / DKMS install step must keep the
# d-i screen informative (docs/GPU-INSTALL-PROGRESS.md).
#
#   1. step profiles: detected GPU -> named step, weight, skip message (ASCII)
#   2. the live monitor against a SIMULATED DKMS build whose make.log grows:
#      status text names module/version/kernel, counts compiles, changes
#      every few seconds, reports built OK / BUILD FAILED per module, and its
#      in-step percent never goes backwards; never emits FAIL/WARN (the KVM
#      gate treats a FAIL row as a failed install)
#   3. apt-progress-shim scales package percent into the window the monitor
#      hands it, so a package transaction cannot fill the build's share
#   4. late.sh's bar math (extracted): a weighted GPU step ticks forward
#      through its whole share, the bar never regresses, a bad plan falls
#      back to equal slots, and the on-screen line changes every heartbeat
#   5. run-all.sh end to end with a fake 54-gpu-accel.sh that drives a DKMS
#      build: START label, live GPU rows, DONE summary, progress.plan weight
#
# Scratch lives under $TMPDIR (set it to local disk, never a tmpfs).
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LIB="$ROOT/post-install/lib/gpu-progress.sh"
SHIM="$ROOT/post-install/apt-progress-shim"
LATE="$ROOT/preseed/late.sh"
RUNALL="$ROOT/post-install/run-all.sh"
SH="${TEST_SH:-sh}"

W="$(mktemp -d "${TMPDIR:-/var/tmp}/gpu-progress-test.XXXXXX")"
BGPIDS=""
# run-all.sh creates /tmp/ncz-apt-shim (an empty dir) even with the shim
# disabled; remove it afterwards only if this test is what created it.
SHIMDIR_PREEXISTED=0; [ -e /tmp/ncz-apt-shim ] && SHIMDIR_PREEXISTED=1
cleanup() {
    for p in $BGPIDS; do kill "$p" 2>/dev/null; done
    rm -rf "$W"
    [ "$SHIMDIR_PREEXISTED" = 1 ] || rmdir /tmp/ncz-apt-shim 2>/dev/null || true
}
trap cleanup EXIT

PASS=0; FAILS=0
ok()  { echo "PASS  $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL  $1"; FAILS=$((FAILS + 1)); }
check() { local name="$1"; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }

[ -f "$LIB" ] || { echo "FAIL  $LIB is missing"; exit 1; }

# ------------------------------------------------------------ fixtures
mk_pci() {  # mk_pci <dir> <vendor-hex>... (display-class devices)
    local d="$1" i=0 v; shift; mkdir -p "$d"
    for v in "$@"; do
        i=$((i + 1)); mkdir -p "$d/0000:0$i:00.0"
        echo 0x030000 > "$d/0000:0$i:00.0/class"; echo "0x$v" > "$d/0000:0$i:00.0/vendor"
    done
    mkdir -p "$d/0000:00:1f.0"; echo 0x060100 > "$d/0000:00:1f.0/class"; echo 0x8086 > "$d/0000:00:1f.0/vendor"
}

profile() {  # profile <sysfs> <meta> <arch> <hook> -> weight|watch|expect|label
    env -i PATH="$PATH" NCZ_GPU_SYSFS_PCI="$1" NCZ_GPU_META_DIR="$2" NCZ_GPU_ARCH="$3" \
        NCZ_GPU_DMI_DIR="$W/nodmi" bash "$LIB" profile "$4"
}

# ------------------------------------------------------------ 1. profiles
mk_pci "$W/pci-nv-amd" 10de 1002
mk_pci "$W/pci-amd" 1002
mk_pci "$W/pci-intel" 8086
mk_pci "$W/pci-none"
mkdir -p "$W/meta" "$W/meta-headless" "$W/meta-nocuda"
echo headless > "$W/meta-headless/BUILD_VARIANT"
echo "desktop,browsers" > "$W/meta-nocuda/COMPONENTS"

p=$(profile "$W/pci-nv-amd" "$W/meta" amd64 54-gpu-accel.sh)
check "NVIDIA+AMD: named step, weight 12, expects a module build" \
    sh -c 'case "$1" in "12|1|1|Installing GPU drivers: AMD + NVIDIA"*"10-20 min"*) exit 0;; esac; echo "  got: $1"; exit 1' _ "$p"
p=$(profile "$W/pci-amd" "$W/meta" amd64 54-gpu-accel.sh)
check "AMD only: ROCm step, weight 4, no build expected" \
    sh -c 'case "$1" in "4|1|0|Installing GPU drivers: AMD - ROCm"*) exit 0;; esac; echo "  got: $1"; exit 1' _ "$p"
p=$(profile "$W/pci-intel" "$W/meta" amd64 54-gpu-accel.sh)
check "Intel only: light step" \
    sh -c 'case "$1" in "2|1|0|Installing GPU drivers: Intel"*) exit 0;; esac; echo "  got: $1"; exit 1' _ "$p"
p=$(profile "$W/pci-none" "$W/meta" amd64 54-gpu-accel.sh)
check "no GPU: short skip message, no monitor" \
    sh -c 'case "$1" in "1|0|0|GPU drivers: no AMD, NVIDIA or Intel GPU found"*skipping*) exit 0;; esac; echo "  got: $1"; exit 1' _ "$p"
p=$(profile "$W/pci-nv-amd" "$W/meta-headless" amd64 54-gpu-accel.sh)
check "headless variant: skip message" \
    sh -c 'case "$1" in "1|0|0|GPU drivers: server/headless"*skipping) exit 0;; esac; echo "  got: $1"; exit 1' _ "$p"
mk_pci "$W/pci-nv" 10de
p=$(profile "$W/pci-nv" "$W/meta-nocuda" amd64 54-gpu-accel.sh)
check "NVIDIA with the driver component declined: skip, no build weight" \
    sh -c 'case "$1" in "1|0|0|GPU drivers: NVIDIA GPU found, driver/CUDA component not selected"*skipping) exit 0;; esac; echo "  got: $1"; exit 1' _ "$p"
p=$(profile "$W/pci-none" "$W/meta" arm64 82-mali-gpu.sh)
check "arm64 Mali DKMS step is a GPU step (weight 3)" \
    sh -c 'case "$1" in "3|1|1|Installing GPU drivers: Mali"*) exit 0;; esac; echo "  got: $1"; exit 1' _ "$p"
check "a Sky1 hook is not a GPU step on amd64" \
    sh -c '! env -i PATH="$PATH" NCZ_GPU_ARCH=amd64 bash "$1" profile 82-mali-gpu.sh >/dev/null' _ "$LIB"
check "an ordinary hook is not a GPU step" \
    sh -c '! env -i PATH="$PATH" NCZ_GPU_ARCH=amd64 bash "$1" profile 20-desktop.sh >/dev/null' _ "$LIB"
labels_ascii() {
    local h a out
    for a in amd64 arm64; do for h in 54-gpu-accel.sh 56-t2-dkms.sh 79-dkms-prep.sh 80-npu.sh 82-mali-gpu.sh 83-panthor-gpu.sh 86-cix-dkms-register.sh; do
        out=$(profile "$W/pci-nv-amd" "$W/meta" "$a" "$h" 2>/dev/null) || continue
        if printf '%s' "$out" | LC_ALL=C grep -q '[^ -~]'; then echo "  non-ASCII label: $h: $out"; return 1; fi
    done; done
    LC_ALL=C grep -nE '_g_emit|LABEL=' "$LIB" | LC_ALL=C grep -q '[^ -~]' && { echo "  non-ASCII in an emitted string"; return 1; }
    return 0
}
check "every step label / emitted string is ASCII (newt draws others as <ERR>)" labels_ascii
labels_fit() {  # START frame is "Installing NCZ-OS: <hook> (NN/NN, NNNs) - <label>", cut at 150
    local out lbl
    for out in "$(profile "$W/pci-nv-amd" "$W/meta" amd64 54-gpu-accel.sh)" "$(profile "$W/pci-amd" "$W/meta" amd64 54-gpu-accel.sh)" \
               "$(profile "$W/pci-nv" "$W/meta-nocuda" amd64 54-gpu-accel.sh)" "$(profile "$W/pci-none" "$W/meta" arm64 86-cix-dkms-register.sh)"; do
        lbl="${out#*|*|*|}"
        [ "${#lbl}" -le 100 ] || { echo "  label too long (${#lbl}): $lbl"; return 1; }
    done
}
check "step labels fit the 150-column info line behind the step prefix (<= 100 chars)" labels_fit

# device identity for the "Detected GPU" feedback line (no pci.ids shipped)
check "a curated GPU id renders its human name (RTX 4060)" \
    sh -c '[ "$(env -i PATH="$PATH" NCZ_GPU_NAMES="$1/assets/gpu/ncz-gpu-names.tsv" bash -c ". \"$2\"; ncz_gpu_name 10de:2882" _)" = "NVIDIA GeForce RTX 4060 (Ada)" ]' _ "$ROOT" "$LIB"
check "an unknown GPU id falls back to the truthful numeric form (no invented name)" \
    sh -c '[ "$(env -i PATH="$PATH" NCZ_GPU_NAMES=/nonexistent bash -c ". \"$1\"; ncz_gpu_name 1234:5678")" = "1234 [1234:5678]" ]' _ "$LIB"

# ------------------------------------------------------------ 2. monitor
# fake_build <dkms-root> <proc-root> <module> <ver> <kernel> <files> <ok|fail> [delay]
fake_build() {
    local D="$1" P="$2" m="$3" v="$4" k="$5" n="$6" res="$7" dly="${8:-0.08}" b i
    b="$D/$m/$v/build"
    mkdir -p "$P/4242"
    printf '/bin/bash\0/usr/sbin/dkms\0build\0-m\0%s\0-v\0%s\0-k\0%s\0' "$m" "$v" "$k" > "$P/4242/cmdline"
    rm -rf "$b"; mkdir -p "$b/src"
    for i in $(seq 1 "$n"); do : > "$b/src/f$i.c"; done
    echo "DKMS (dkms-3.4.3) make.log for $m/$v for kernel $k (x86_64)" >> "$b/make.log"
    date >> "$b/make.log"
    sleep 0.4
    local upto="$n"; [ "$res" = fail ] && upto=$((n / 2))
    for i in $(seq 1 "$upto"); do
        echo "  CC [M]  $b/src/f$i.o" >> "$b/make.log"; sleep "$dly"
    done
    if [ "$res" = ok ]; then
        echo "  MODPOST $b/Module.symvers" >> "$b/make.log"; sleep 0.3
        echo "  LD [M]  $b/$m.ko" >> "$b/make.log"; sleep 0.3
        mkdir -p "$D/$m/$v/$k/x86_64/module" "$D/$m/$v/$k/x86_64/log"
        : > "$D/$m/$v/$k/x86_64/module/$m.ko"
        mv "$b/make.log" "$D/$m/$v/$k/x86_64/log/make.log"
        rm -rf "$b"
    else
        echo "$b/src/f$upto.c:12:5: error: implicit declaration of function 'foo'" >> "$b/make.log"
        echo "make[2]: *** [scripts/Makefile.build:229: f$upto.o] Error 1" >> "$b/make.log"
    fi
    rm -rf "$P/4242"
}

M="$W/mon"; mkdir -p "$M/dkms" "$M/proc" "$M/log"
STATE="$M/log/progress.state"; TSV="$M/log/progress.tsv"
: > "$TSV"
(
    export NCZ_PROGRESS_FILE="$STATE" NCZ_PROGRESS_LOG="$TSV" NCZ_PROGRESS_PHASE=optional
    export NCZ_PROGRESS_INDEX=40 NCZ_PROGRESS_TOTAL=57 NCZ_PROGRESS_HOOK=54-gpu-accel.sh
    export NCZ_PROGRESS_STARTED="$(date +%s)" NCZ_PROGRESS_WINDOW="$STATE.window"
    export NCZ_GPU_DKMS_ROOT="$M/dkms" NCZ_GPU_PROC_ROOT="$M/proc" NCZ_TTY=/dev/null
    export NCZ_GPU_LOG="$M/log/gpu-progress.log" NCZ_GPU_RESULTS="$M/log/gpu-progress.results"
    export NCZ_GPU_POLL=0.2 NCZ_GPU_HOLD=0 NCZ_GPU_STALE=1 NCZ_GPU_ETA_MIN_S=1
    export NCZ_GPU_EXPECT_BUILD=1 NCZ_GPU_SHORT="GPU drivers (NVIDIA)"
    export NCZ_GPU_LABEL="Installing GPU drivers: NVIDIA - test"
    export NCZ_GPU_DETECTED="NVIDIA GeForce RTX 4060 (Ada) [10de:2882]"
    export NCZ_GPU_DECISION="installing the NVIDIA driver via DKMS (this takes a few minutes)"
    exec bash "$LIB" watch
) &
MON=$!; BGPIDS="$BGPIDS $MON"
sleep 0.6
fake_build "$M/dkms" "$M/proc" nvidia 580.95.05 7.3.0-ncz 40 ok
sleep 1
fake_build "$M/dkms" "$M/proc" nvidia 580.95.05 7.3.0-ncz-rescue 40 fail
sleep 2.5
kill -TERM "$MON" 2>/dev/null; wait "$MON" 2>/dev/null
GPU_ROWS="$M/gpu.rows"
awk -F'|' '$3 == "GPU"' "$TSV" > "$GPU_ROWS"

check "monitor wrote GPU status records" test -s "$GPU_ROWS"
check "detection line names the GPU, then the driver decision, before the step label" \
    sh -c 'head -1 "$1" | grep >/dev/null "|GPU|.*|Detected GPU: NVIDIA GeForce RTX 4060 (Ada) \[10de:2882\]" && \
           sed -n 2p "$1" | grep >/dev/null "GPU driver: installing the NVIDIA driver via DKMS" && \
           sed -n 3p "$1" | grep >/dev/null "Installing GPU drivers: NVIDIA - test"' _ "$GPU_ROWS"
check "detection line is recorded in gpu-progress.log as DETECTED" \
    grep -q 'DETECTED NVIDIA GeForce RTX 4060 (Ada) \[10de:2882\] -> installing the NVIDIA driver via DKMS' "$M/log/gpu-progress.log"
check "status names module, version and kernel and counts compiles against the source total" \
    grep -q 'GPU drivers (NVIDIA): building nvidia 580.95.05 for kernel 7.3.0-ncz - compiling [0-9]*/40 files' "$GPU_ROWS"
check "an ETA appears once the build rate is measurable" grep -q 'min left\|under a minute left' "$GPU_ROWS"
check "link stage is named" grep -q 'linking' "$GPU_ROWS"
distinct=$(cut -d'|' -f10 "$GPU_ROWS" | sort -u | wc -l)
check "status text keeps changing while the build runs ($distinct distinct lines >= 8)" test "$distinct" -ge 8
check "success line for the finished module" grep -q 'nvidia 580.95.05 for kernel 7.3.0-ncz - built OK in 0m0[0-9]s' "$GPU_ROWS"
check "failure line for the broken module carries the compiler error" \
    grep -q 'nvidia 580.95.05 for kernel 7.3.0-ncz-rescue - BUILD FAILED after .*error: implicit declaration' "$GPU_ROWS"
check "failure line carries the hook log path for the operator" \
    grep -q 'GPU driver build failed - see /var/log/cix-install/54-gpu-accel.sh.log' "$GPU_ROWS"
check "second build measures against the first build's compile count" \
    grep -q 'BEGIN build nvidia 580.95.05 for kernel 7.3.0-ncz-rescue (expect ~40 compiles, from previous build)' "$M/log/gpu-progress.log"
monotonic() {
    awk -F'|' 'BEGIN { last = -1; bad = 0 } { p = $8 + 0; if (p < last) { print "  regressed " last " -> " p ": " $10; bad = 1 } last = p }
               END { exit bad }' "$GPU_ROWS"
}
check "in-step percent never goes backwards" monotonic
span() {
    local lo hi
    lo=$(awk -F'|' '/compiling/ { print $8; exit }' "$GPU_ROWS"); hi=$(awk -F'|' 'END { print $8 }' "$GPU_ROWS")
    [ "${lo:-0}" -ge 25 ] && [ "${hi:-0}" -gt "$((lo + 20))" ] || { echo "  build window lo=$lo last=$hi"; return 1; }
}
check "the build ticks through its reserved window (starts >= 25%, climbs > 20 points)" span
check "monitor never emits FAIL or WARN rows (the KVM gate fails on FAIL)" \
    sh -c '! awk -F"|" "\$3 == \"FAIL\" || \$3 == \"WARN\"" "$1" | grep >/dev/null .' _ "$TSV"
check "results file records one ok and one failed build" \
    sh -c 'grep -c "|ok|" "$1" | grep >/dev/null -x 1 && grep -c "|failed|" "$1" | grep >/dev/null -x 1' _ "$M/log/gpu-progress.results"
check "install log keeps STEP, BEGIN, RESULT and END records" \
    sh -c 'for k in "STEP Installing GPU drivers" "RESULT ok nvidia" "RESULT failed nvidia" "END GPU drivers"; do grep -q "$k" "$1" || { echo "  missing: $k"; exit 1; }; done' _ "$M/log/gpu-progress.log"
check "apt window file is removed when the step ends" test ! -e "$STATE.window"

# ------------------------------------------------------------ 3. shim window
S="$W/shim"; mkdir -p "$S"
cat > "$S/apt-get" <<'EOF'
#!/bin/bash
for a in "$@"; do [ "$a" = -s ] && { echo "Inst foo (1 x)"; exit 0; }; done
echo "pmstatus:foo:50.0:Installing foo" >&3
EOF
chmod +x "$S/apt-get"
shim_pct() {  # shim_pct <window-or-empty> -> percent the shim recorded
    rm -f "$S/state" "$S/state.window"
    [ -n "$1" ] && echo "$1" > "$S/state.window"
    NCZ_APT_GET_REAL="$S/apt-get" NCZ_APT_LOG="$S/apt.log" NCZ_PROGRESS_FILE="$S/state" \
        NCZ_PROGRESS_LOG="$S/tsv" NCZ_PROGRESS_WINDOW="$S/state.window" bash "$SHIM" install -y foo >/dev/null 2>&1
    awk -F'|' '$3 == "APT" && $10 ~ /^foo/ { p = $8 } END { print p }' "$S/tsv"; : > "$S/tsv"
}
check "shim without a window keeps apt's percent (50)" test "$(shim_pct '')" = 50
check "shim scales into the package window (0..25 -> 12)" test "$(shim_pct '0 25')" = 12
check "shim holds the bar during a build window (40 40 -> 40)" test "$(shim_pct '40 40')" = 40

# ------------------------------------------------------------ 4. late.sh bar math
L="$W/late-fns.sh"
awk '/NCZ-HB-UNITS-BEGIN/,/NCZ-HB-UNITS-END/' "$LATE" > "$L"
check "late.sh carries the extractable hb_units_for / hb_gpu_status block" grep -q 'hb_units_for()' "$L"
PLAN="$W/progress.plan"
{ for i in $(seq 1 20); do w=1; [ "$i" = 12 ] && w=12; echo "$i|h$i.sh|$w"; done; } > "$PLAN"
bar_walk() {  # simulate the heartbeat loop over a GPU step; print units per tick
    $SH -c '. "$1"; last=0
        for ev_pct in START:0 APT:10 APT:25 GPU:25 GPU:31 GPU:38 GPU:44 GPU:51 GPU:57 GPU:64 GPU:70 GPU:77 APT:5 GPU:83 APT:60 GPU:90 DONE:0; do
            u=$(hb_units_for "${ev_pct%%:*}" 12 20 "${ev_pct#*:}" "$2" 100)
            [ "$u" -gt "$last" ] && last=$u
            echo "$last"
        done' _ "$L" "$1"
}
walk=$(bar_walk "$PLAN" | tr '\n' ' ')
strict_through_build() {
    set -- $walk
    [ "$#" = 17 ] || { echo "  expected 17 ticks, got $#: '$walk'"; return 1; }
    local prev=-1 i=0 v
    for v in "$@"; do
        i=$((i + 1))
        [ "$v" -ge "$prev" ] || { echo "  regressed at tick $i: $walk"; return 1; }
        # ticks 5..12 are GPU build records after the first: each must move
        # the bar (strictly). Tick 4 (GPU 25 after APT 25) may hold.
        if [ "$i" -ge 5 ] && [ "$i" -le 12 ] && [ "$v" -le "$prev" ]; then echo "  stalled at tick $i: $walk"; return 1; fi
        prev=$v
    done
}
check "weighted GPU step: the bar moves on every build tick and never regresses ($walk)" strict_through_build
gpu_span() {
    local a b
    a=$($SH -c '. "$1"; hb_units_for GPU 12 20 25 "$2" 100' _ "$L" "$PLAN")
    b=$($SH -c '. "$1"; hb_units_for GPU 12 20 90 "$2" 100' _ "$L" "$PLAN")
    [ $((b - a)) -ge 20 ] || { echo "  weighted GPU build span only $a -> $b units"; return 1; }
}
check "the GPU step's reserved weight gives the build >= 20 of 100 bar units" gpu_span
check "last step DONE fills the owned range (100/100)" \
    test "$($SH -c '. "$1"; hb_units_for DONE 20 20 "" "$2" 100' _ "$L" "$PLAN")" = 100
check "no plan: equal slots exactly as before (DONE 5/20 -> 25)" \
    test "$($SH -c '. "$1"; hb_units_for DONE 5 20 "" "" 100' _ "$L")" = 25
check "no plan: GPU percent still ticks inside the slot (GPU 50% of 5/20 -> 22)" \
    test "$($SH -c '. "$1"; hb_units_for GPU 5 20 50 "" 100' _ "$L")" = 22
head -n 15 "$PLAN" > "$W/short.plan"
check "a plan that does not match the step count falls back to equal slots" \
    test "$($SH -c '. "$1"; hb_units_for DONE 5 20 "" "$2" 100' _ "$L" "$W/short.plan")" = 25
check "no owned units (unpatched finish-install): nothing to advance" \
    test "$($SH -c '. "$1"; hb_units_for DONE 5 20 "" "$2" 0' _ "$L" "$PLAN")" = 0
screen() {
    local a b c
    a=$($SH -c '. "$1"; hb_gpu_status "GPU drivers (NVIDIA): building nvidia" 125 1' _ "$L")
    b=$($SH -c '. "$1"; hb_gpu_status "GPU drivers (NVIDIA): building nvidia" 129 2' _ "$L")
    c=$($SH -c '. "$1"; hb_gpu_status "GPU drivers (NVIDIA): building nvidia" 129 3' _ "$L")
    [ "$a" = "[2:05 .*..] GPU drivers (NVIDIA): building nvidia" ] || { echo "  got: $a"; return 1; }
    [ "$a" != "$b" ] && [ "$b" != "$c" ] || { echo "  identical lines: $a / $b / $c"; return 1; }
    printf '%s%s%s' "$a" "$b" "$c" | LC_ALL=C grep -q '[^ -~]' && { echo "  non-ASCII"; return 1; }
    return 0
}
check "the on-screen GPU line leads with elapsed time and a moving marker, changing every heartbeat" screen
check "late.sh renders GPU records through hb_gpu_status" \
    grep -qE '^[[:space:]]*GPU\)$' "$LATE"
check "late.sh bar uses hb_units_for with the run-all plan" \
    grep -q 'hb_units_for "$hb_event" "$hb_idx" "$hb_total" "$hb_pct"' "$LATE"

# ------------------------------------------------------------ 5. run-all end to end
R="$W/runall"; mkdir -p "$R/hooks/lib" "$R/log" "$R/dkms" "$R/proc" "$R/meta"
cp "$LIB" "$R/hooks/lib/"
cp "$SHIM" "$R/hooks/apt-progress-shim"
cat > "$R/hooks/20-desktop.sh" <<'EOF'
#!/bin/bash
echo desktop
EOF
{
    echo '#!/bin/bash'
    declare -f fake_build
    echo 'echo "[54] simulated NVIDIA driver install"'
    echo 'fake_build "$T_DKMS" "$T_PROC" nvidia 580.95.05 7.3.0-ncz 30 ok 0.15'
    echo 'sleep 1.5'
} > "$R/hooks/54-gpu-accel.sh"
mk_pci "$R/pci" 10de
(
    cd "$R/hooks" || exit 1
    env NCZ_LOGDIR="$R/log" NCZ_HOOK_DIR="$R/hooks" NCZ_TTY=/dev/null NCZ_HOOKS_LIST=none \
        NCZ_TARGET_ARCH=amd64 NCZ_DISABLE_APT_SHIM=1 NCZ_GPU_SYSFS_PCI="$R/pci" NCZ_GPU_META_DIR="$R/meta" \
        NCZ_GPU_DKMS_ROOT="$R/dkms" NCZ_GPU_PROC_ROOT="$R/proc" NCZ_GPU_POLL=0.3 NCZ_GPU_HOLD=0 \
        NCZ_GPU_STALE=1 T_DKMS="$R/dkms" T_PROC="$R/proc" \
        bash "$RUNALL" > "$R/runall.out" 2>&1
)
RT="$R/log/progress.tsv"
check "run-all: GPU step starts with its named label" \
    grep -q '|START|optional|.*|54-gpu-accel.sh|||Installing GPU drivers: NVIDIA - driver download + kernel module build (can take 10-20 min)' "$RT"
check "run-all: live GPU rows during the hook" grep -q '|GPU|optional|.*|54-gpu-accel.sh|.*building nvidia 580.95.05 for kernel 7.3.0-ncz' "$RT"
check "run-all: DONE row carries the module summary" \
    grep -q '|DONE|optional|.*|54-gpu-accel.sh||0|GPU drivers (NVIDIA): done in [0-9]*s - 1 kernel module build(s) OK, 0 failed' "$RT"
check "run-all: ordinary hooks keep their old START/DONE text" \
    grep -q '|DONE|optional|.*|20-desktop.sh||0|Optional component complete' "$RT"
check "run-all: progress.plan reserves weight 12 for the NVIDIA step" grep -qx '2|54-gpu-accel.sh|12' "$R/log/progress.plan"
check "run-all: plan rows match the step count" \
    test "$(wc -l < "$R/log/progress.plan")" = "$(awk -F'|' '$3 == "PLAN" { print $6; exit }' "$RT")"
check "run-all: completes without a FAIL row" \
    sh -c '! awk -F"|" "\$3 == \"FAIL\"" "$1" | grep >/dev/null . && grep -q "|COMPLETE|.*Post-install completed successfully" "$1"' _ "$RT"
check "run-all: no monitor left running" \
    sh -c '! ps -eo args | grep -v grep | grep >/dev/null -F "$1 watch"' _ "$R/hooks/lib/gpu-progress.sh"
[ "$FAILS" = 0 ] || { echo "--- run-all output ---"; tail -n 30 "$R/runall.out"; }

echo
echo "test-gpu-install-progress: $PASS passed, $FAILS failed"
[ "$FAILS" = 0 ]
