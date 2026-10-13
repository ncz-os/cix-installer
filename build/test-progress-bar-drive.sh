#!/bin/bash
# test-progress-bar-drive.sh -- late.sh must move finish-install's progress
# bar through the whole post-install phase on the raw-image path, where no
# patched finish-install exports NCZ_PROGRESS_UNITS
# (docs/GPU-INSTALL-PROGRESS.md "Progress bar").
#
# A stub debconf records every PROGRESS command; an awk model of cdebconf's
# progress state (START resets min/max/cur, SET/STEP move cur, no clamping)
# replays them and checks what the operator would see. The scenario wraps the
# extracted late.sh code in an emulation of finish-install.postinst
# (START 0 N, STEP 1 per finish-install.d entry, 07preseed = late_command).
#
#   1. geometry from a real finish-install.d listing (r199 image, GU502LV)
#   2. rescale path: START with finish-install's title, SET to where it was,
#      a weighted GPU step (weight 12) with real pct plus long flat stretches;
#      the bar never settles lower, keeps moving in flat stretches without
#      leaving the step, and finish-install's remaining STEPs end at 100%
#   3. legacy owned path (patched finish-install, NCZ_PROGRESS_UNITS=100)
#   4. text-only paths: no debconf channel, not under 07preseed, START refused
#   5. NCZ_PROGRESS_UNITS unset never prints "bad number" (late.sh:918 on r199)
#
# Runs every scenario under sh, busybox sh (when installed) and bash.
# Scratch lives under $TMPDIR (set it to local disk, never a tmpfs).
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LATE="$ROOT/preseed/late.sh"

W="$(mktemp -d "${TMPDIR:-/var/tmp}/progress-bar-test.XXXXXX")"
trap '[ -n "${KEEP_TEST_DIR:-}" ] || rm -rf "$W"' EXIT

PASS=0; FAILS=0
ok()  { echo "PASS  $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL  $1"; FAILS=$((FAILS + 1)); }
check() { local name="$1"; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }

SHELLS="sh"
command -v busybox >/dev/null 2>&1 && busybox sh -c ':' 2>/dev/null && SHELLS="$SHELLS busybox-sh"
SHELLS="$SHELLS bash"
# The busybox runs use busybox applets for the tools late.sh calls too (as
# in d-i), not the host's GNU ones.
BB="$W/bb"
if case " $SHELLS " in *" busybox-sh "*) true ;; *) false ;; esac; then
    mkdir -p "$BB"
    for a in sed tr cut date awk grep ls wc cat mkdir printf sleep; do
        busybox "$a" --help >/dev/null 2>&1 && ln -sf "$(command -v busybox)" "$BB/$a"
    done
fi
run_sh() {  # run_sh <shell-tag> <args...>
    local s="$1"; shift
    case "$s" in busybox-sh) PATH="$BB:$PATH" busybox sh "$@" ;; *) "$s" "$@" ;; esac
}

# ------------------------------------------------------------ extraction
L="$W/late-fns.sh"
{
    awk '/NCZ-HB-UNITS-BEGIN/,/NCZ-HB-UNITS-END/' "$LATE"
    awk '/NCZ-BAR-BEGIN/,/NCZ-BAR-END/' "$LATE"
} > "$L"
check "late.sh carries the extractable NCZ-BAR block" \
    grep -q '^ncz_bar_begin()' "$L"
check "late.sh calls ncz_bar_begin, hb_tick and ncz_bar_finish" \
    sh -c 'grep -q "^ncz_bar_begin$" "$1" && grep -qE "^[[:space:]]+hb_tick \"\\\$hb_iter\"$" "$1" && grep -q "^ncz_bar_finish$" "$1"' _ "$LATE"
for s in $SHELLS; do
    check "late.sh parses under $s" run_sh "$s" -n "$LATE"
done
# Every arithmetic test on NCZ_PROGRESS_UNITS must use the default form.
check "no bare [ \"\$NCZ_PROGRESS_UNITS\" -gt ... ] left in late.sh" \
    sh -c '! grep -nE "\"\\\$NCZ_PROGRESS_UNITS\" -(gt|ge|lt|le|eq)" "$1" | grep -vE "^[0-9]+:[[:space:]]*#"' _ "$LATE"

# ------------------------------------------------------------ fixtures
# finish-install.d as listed on the r199 image (GU502LV, 2026-10-06).
PARTS="$W/finish-install.d"; mkdir -p "$PARTS"
for f in 01kickseed 05localechooser 06user-setup 07brltty 07preseed 07rootskel \
         07speakup 08hw-detect 10clock-setup 10open-iscsi 10update-initramfs \
         15cdrom-detect 20final-message 30hw-detect 50config-target-network \
         55netcfg-copy-config 60cleanup 65partman-md 70mtab 80hvcgetty \
         90base-installer 90console 94random-seed 94save-logs 95umount \
         97release-dhcp-lease 99reboot; do
    printf '#!/bin/sh\n' > "$PARTS/$f"; chmod +x "$PARTS/$f"
done
mkdir -p "$W/nopreseed.d"; cp "$PARTS/01kickseed" "$PARTS/99reboot" "$W/nopreseed.d/"

# 58-step plan; step 40 is the NVIDIA GPU step (weight 12, gpu-progress.sh).
PLAN="$W/progress.plan"
{ for i in $(seq 1 58); do w=1; [ "$i" = 40 ] && w=12; echo "$i|h$i.sh|$w"; done; } > "$PLAN"

# Record sequence fed to the heartbeat: "event idx pct ticks". Step 40 has
# flat stretches (same pct for many heartbeats: a big file, modpost, an
# initramfs rebuild) and an apt record whose pct is LOWER than the build's.
FEED="$W/feed"
{
    for i in $(seq 1 39); do echo "START $i 0 1"; echo "DONE $i 0 1"; done
    echo "START 40 0 2"
    echo "APT 40 10 1"; echo "APT 40 25 1"
    echo "GPU 40 25 12"              # dkms preparing: flat
    echo "GPU 40 40 1"; echo "GPU 40 41 15"   # one large file: flat
    echo "GPU 40 70 1"; echo "GPU 40 89 1"
    echo "GPU 40 90 20"              # modpost + initramfs: flat
    echo "APT 40 5 3"                # CUDA apt transaction restarts at 5%
    echo "DONE 40 0 1"
    for i in $(seq 41 58); do echo "START $i 0 1"; echo "DONE $i 0 1"; done
    echo "COMPLETE 58 0 1"
} > "$FEED"

# Fake /proc chain: <pid> -> 07preseed -> finish-install.postinst.
mkproc() {  # mkproc <root> <with-07preseed 0|1>   (the driver adds its own $$)
    local r="$1"; mkdir -p "$r/900" "$r/901" "$r/902"
    printf 'sh\0-c\0for D in /cdrom/ncz-payload\0' > "$r/900/cmdline"; printf 'Name:\tsh\nPPid:\t901\n' > "$r/900/status"
    if [ "$2" = 1 ]; then
        printf '/bin/sh\0-e\0/usr/lib/finish-install.d/07preseed\0' > "$r/901/cmdline"
    else
        printf '/bin/sh\0/some/other/runner\0' > "$r/901/cmdline"
    fi
    printf 'Name:\tsh\nPPid:\t902\n' > "$r/901/status"
    printf '/bin/sh\0/var/lib/dpkg/info/finish-install.postinst\0configure\0' > "$r/902/cmdline"
    printf 'Name:\tsh\nPPid:\t1\n' > "$r/902/status"
}

# The driver: stub debconf + finish-install.postinst emulation around the
# extracted late.sh functions. Env: LIB PARTS FEED PLAN REC STATE PROC
# DEBCONF_OK REJECT (space-separated START titles the stub refuses) and, for
# the legacy case, NCZ_PROGRESS_UNITS / NCZ_PROGRESS_CONSUMED_FILE.
DRIVER="$W/driver.sh"
cat > "$DRIVER" <<'EOF'
REC_OUT="$REC"
db_progress() {
    if [ "$1" = START ]; then
        for _r in ${REJECT:-}; do
            [ "$4" = "$_r" ] && { echo "REFUSED $*" >> "$REC_OUT"; return 10; }
        done
    fi
    echo "PROGRESS $*" >> "$REC_OUT"
    return 0
}
db_subst() { echo "SUBST $*" >> "$REC_OUT"; return 0; }
ttymsg() { :; }
# this shell is the late.sh process; its parent is the fake 900 chain
mkdir -p "$PROC/$$"
printf 'sh\0/cdrom/ncz-payload/late.sh\0' > "$PROC/$$/cmdline"
printf 'Name:\tsh\nPPid:\t900\n' > "$PROC/$$/status"
NCZ_FINISH_PARTSDIR="$PARTS"; NCZ_PROC_ROOT="$PROC"
PROGRESS_STATE="$STATE"; PROGRESS_PLAN="$PLAN"
. "$LIB"

# finish-install.postinst up to 07preseed (not for the no-channel case: the
# KVM gate's unattended run has no debconf to record)
_fi_n=$(ls "$PARTS"/* | wc -l)
if [ "${DEBCONF_OK:-0}" = 1 ]; then
    # finish-install's own START: never refused (REJECT is for late.sh's)
    echo "PROGRESS START 0 $_fi_n finish-install/progress/title" >> "$REC_OUT"
fi
for _fi_s in "$PARTS"/*; do
    [ "$_fi_s" = "$PARTS/07preseed" ] && break
    [ "${DEBCONF_OK:-0}" = 1 ] && db_progress STEP 1
done

# ---- late_command (late.sh) ----
ncz_bar_begin
echo "MODE $BAR_MODE $BAR_SCALE $BAR_BASE $BAR_END ${NCZ_PROGRESS_UNITS:-unset}" >> "$REC_OUT"
hb_iter=0
while read -r _ev _idx _pct _ticks; do
    _n=0
    while [ "$_n" -lt "$_ticks" ]; do
        printf '%s|%s|%s|optional|%s|58|h%s.sh|%s||detail\n' \
            1000 1000 "$_ev" "$_idx" "$_idx" "$_pct" > "$STATE"
        hb_iter=$((hb_iter + 1))
        echo "TICK $_ev $_idx $_pct" >> "$REC_OUT"
        hb_tick "$hb_iter"
        _n=$((_n + 1))
    done
done < "$FEED"
ncz_bar_finish
echo "LATE-END" >> "$REC_OUT"

# ---- finish-install.postinst after 07preseed ----
_fi_after=0
for _fi_s in "$PARTS"/*; do
    if [ "$_fi_after" = 1 ] || [ "$_fi_s" = "$PARTS/07preseed" ]; then
        _fi_after=1
        [ "${DEBCONF_OK:-0}" = 1 ] && db_progress STEP 1
    fi
done
[ "${DEBCONF_OK:-0}" = 1 ] && db_progress STOP
exit 0
EOF

# awk model of cdebconf's progress state. Prints one line per settled value
# ("V <tick-tag> <fraction*100000>") plus ERR lines; a START must be followed
# by a SET before anything else, and that SET may not land below where the
# bar was before the START.
MODEL="$W/model.awk"
cat > "$MODEL" <<'EOF'
BEGIN { settled = 0; pend = 0; active = 0; tick = "pre" }
$1 == "TICK" { tick = $2 "-" $3 "-" $4; next }
$1 == "LATE-END" { tick = "post"; next }
$1 != "PROGRESS" { next }
{
    c = $2
    if (c == "START") {
        if (pend) print "ERR START while a START awaits its SET"
        min = $3 + 0; max = $4 + 0; cur = min; active = 1
        if (started++) pend = 1     # the first START is finish-install's own
        next
    }
    if (c == "INFO") { if (pend) print "ERR INFO before the SET that follows START"; next }
    if (c == "STOP") { if (pend) print "ERR STOP after START"; active = 0; next }
    if (c == "SET") cur = $3 + 0
    else if (c == "STEP") cur += $3 + 0
    else { print "ERR unknown " c; next }
    if (!active) { print "ERR " c " with no bar"; next }
    if (cur > max) print "ERR overflow cur=" cur " max=" max
    if (max <= min) { print "ERR empty range " min ".." max; next }
    f = int((cur - min) * 100000 / (max - min))
    if (f < settled) print "ERR regressed " settled " -> " f " at " tick
    pend = 0; settled = f
    print "V " tick " " f
}
EOF

# ------------------------------------------------------------ 1. geometry
geo_refuses() { ! run_sh "$1" -c '. "$1"; ncz_bar_geometry "$2"' _ "$L" "$W/nopreseed.d" >/dev/null; }
for s in $SHELLS; do
    g=$(run_sh "$s" -c '. "$1"; ncz_bar_geometry "$2"' _ "$L" "$PARTS")
    check "[$s] r199 finish-install.d (N=27, 07preseed 5th): scale 920, base 137, end 897" test "$g" = "920 137 897"
    check "[$s] no 07preseed entry: geometry refuses" geo_refuses "$s"
done
check "base is the ceiling of where finish-install left the bar (4/27 of 920 = 136.3 -> 137)" \
    sh -c '[ $((4 * 920)) -le $((137 * 27)) ] && [ $((4 * 920)) -gt $((136 * 27)) ]'

# ------------------------------------------------------------ 2-5. scenarios
scenario() {  # scenario <shell> <name> <with-07preseed> [ENV=VALUE...]
    local s="$1" name="$2" pre="$3"; shift 3
    local d="$W/run-$s-$name"; mkdir -p "$d"
    mkproc "$d/proc" "$pre"
    local path="$PATH"; [ "$s" = busybox-sh ] && path="$BB:$PATH"
    env -i PATH="$path" LIB="$L" PARTS="$PARTS" FEED="$FEED" PLAN="$PLAN" \
        REC="$d/rec" STATE="$d/state" PROC="$d/proc" "$@" \
        bash -c 'case "$0" in busybox-sh) exec busybox sh "$1" ;; *) exec "$0" "$1" ;; esac' "$s" "$DRIVER" \
        > "$d/out" 2> "$d/err"
    echo "$?" > "$d/rc"
    touch "$d/rec"
    awk -f "$MODEL" "$d/rec" > "$d/model"
    echo "$d"
}
no_shell_errors() {  # stderr of the run: no bad number / illegal number / not found
    if grep -qiE 'bad number|illegal number|not found|syntax error|unexpected' "$1/err"; then
        echo "  stderr:"; sed 's/^/    /' "$1/err" | head -5; return 1
    fi
    [ "$(cat "$1/rc")" = 0 ] || { echo "  rc=$(cat "$1/rc")"; return 1; }
}
model_clean() { if grep -q '^ERR' "$1/model"; then grep '^ERR' "$1/model" | head -5 | sed 's/^/  /'; return 1; fi; }

for s in $SHELLS; do
    # ---- 2. rescale (the raw-image path) ----
    d=$(scenario "$s" rescale 1 DEBCONF_OK=1)
    check "[$s] rescale: runs clean (no 'bad number' with NCZ_PROGRESS_UNITS unset)" no_shell_errors "$d"
    check "[$s] rescale: mode chosen at runtime, 760 units owned" \
        grep -q '^MODE rescale 920 137 897 760$' "$d/rec"
    check "[$s] rescale: START 0 920 keeps finish-install's own title, then SET 137 at once" \
        sh -c 'grep "^PROGRESS" "$1" | sed -n "6,7p" | tr "\n" " " | grep -q "^PROGRESS START 0 920 finish-install/progress/title PROGRESS SET 137 $"' _ "$d/rec"
    check "[$s] rescale: never STOPs inside late.sh" \
        sh -c '! sed "/^LATE-END/q" "$1" | grep -q "^PROGRESS STOP"' _ "$d/rec"
    check "[$s] rescale: the bar never settles lower, never overflows" model_clean "$d"
    check "[$s] rescale: finish-install's remaining STEPs end at exactly 100%" \
        test "$(awk '/^V /{v=$3} END{print v}' "$d/model")" = 100000
    check "[$s] rescale: late.sh ends at its range end (897/920) before finish-install resumes" \
        sh -c 'sed "/^LATE-END/q" "$1" | grep "^PROGRESS SET" | tail -n 1 | grep -q "^PROGRESS SET 897$"' _ "$d/rec"
    # GPU step weight: the step-40 span is 12x an ordinary step's span
    gpu_weight() {
        local f="$1/rec" s39 s40 e40 one
        s39=$(awk '/^TICK DONE 38 /{t=1;next} /^TICK/{t=0} t&&/^PROGRESS SET/{v=$3} END{print v}' "$f")
        e39=$(awk '/^TICK DONE 39 /{t=1;next} /^TICK/{t=0} t&&/^PROGRESS SET/{v=$3} END{print v}' "$f")
        e40=$(awk '/^TICK DONE 40 /{t=1;next} /^TICK/{t=0} t&&/^PROGRESS SET/{v=$3} END{print v}' "$f")
        one=$((e39 - s39)); span=$((e40 - e39))
        [ "$one" -gt 0 ] && [ "$span" -ge $((one * 12 - 6)) ] && [ "$span" -le $((one * 12 + 6)) ] \
            || { echo "  ordinary step $one units, GPU step $span units (want ~12x)"; return 1; }
    }
    check "[$s] rescale: the GPU step (weight 12) gets ~12x an ordinary step's bar span" gpu_weight "$d"
    # flat stretches inside the GPU step still move the bar, and stay inside it
    gpu_never_stalls() {
        local f="$1/rec" end40 flat moved
        end40=$(awk '/^TICK DONE 40 /{t=1;next} /^TICK/{t=0} t&&/^PROGRESS SET/{v=$3} END{print v}' "$f")
        for tag in "GPU 40 25" "GPU 40 41" "GPU 40 90"; do
            # every one of the first 3 heartbeats of the stretch moves the bar,
            # and the stretch as a whole moves it at least 4 times
            first=$(awk -v tag="TICK $tag" '$0==tag{n++; t=(n<=3); next} /^TICK/{t=0} t&&/^PROGRESS SET/{m++} END{print m+0}' "$f")
            moved=$(awk -v tag="TICK $tag" '$0==tag{t=1;next} /^TICK/{t=0} t&&/^PROGRESS SET/{m++} END{print m+0}' "$f")
            [ "$first" = 3 ] && [ "$moved" -ge 4 ] \
                || { echo "  flat '$tag': $first of the first 3 heartbeats moved, $moved moves in all"; return 1; }
        done
        awk -v e="$end40" '/^TICK (START|APT|GPU) 40 /{t=1;next} /^TICK/{t=0} t&&/^PROGRESS SET/&&$3>=e{bad=1} END{exit bad}' "$f" \
            || { echo "  a creep reached the next step's share ($end40)"; return 1; }
    }
    check "[$s] rescale: flat GPU stretches keep moving and never leave the GPU step" gpu_never_stalls "$d"
    check "[$s] rescale: a lower apt percent in the GPU step does not rewind the bar" \
        sh -c '! grep -q "ERR regressed" "$1"' _ "$d/model"

    # ---- 3. legacy owned (patched finish-install) ----
    d=$(scenario "$s" owned 1 DEBCONF_OK=1 NCZ_PROGRESS_UNITS=100 NCZ_PROGRESS_CONSUMED_FILE="$W/consumed-$s")
    check "[$s] owned: runs clean" no_shell_errors "$d"
    check "[$s] owned: no extra START, STEP deltas sum to the 100 allocated units" \
        sh -c 'sed "/^LATE-END/q" "$1" | awk "/^PROGRESS START/{s++} /^MODE/{m=1;next} m&&/^PROGRESS STEP/{t+=\$3} END{exit !(s==1 && t==100)}"' _ "$d/rec"
    check "[$s] owned: consumed file reports 100" test "$(cat "$W/consumed-$s" 2>/dev/null)" = 100

    # ---- 4. text-only paths ----
    d=$(scenario "$s" nochannel 1 DEBCONF_OK=0)
    check "[$s] no debconf channel: runs clean, text-only" no_shell_errors "$d"
    check "[$s] no debconf channel: no PROGRESS command at all" \
        sh -c '! grep -q "^PROGRESS" "$1" && grep -q "^MODE text" "$1"' _ "$d/rec"
    d=$(scenario "$s" notfinish 0 DEBCONF_OK=1)
    check "[$s] not under 07preseed: text-only, finish-install's bar untouched" \
        sh -c 'grep -q "^MODE text" "$1" && [ "$(sed "/^LATE-END/q" "$1" | grep -c "^PROGRESS \(START\|SET\)")" = 1 ]' _ "$d/rec"
    check "[$s] not under 07preseed: runs clean" no_shell_errors "$d"
    d=$(scenario "$s" fallbacktitle 1 DEBCONF_OK=1 REJECT=finish-install/progress/title)
    check "[$s] finish-install title refused: falls back to the NCZ title and still drives the bar" \
        sh -c 'grep -q "^MODE rescale" "$1" && grep -q "^PROGRESS START 0 920 nclawzero/install-progress" "$1"' _ "$d/rec"
    check "[$s] finish-install title refused: model clean, ends at 100%" \
        sh -c '! grep -q "^ERR" "$1" && [ "$(awk "/^V /{v=\$3} END{print v}" "$1")" = 100000 ]' _ "$d/model"
    d=$(scenario "$s" norestart 1 DEBCONF_OK=1 "REJECT=finish-install/progress/title nclawzero/install-progress")
    check "[$s] every START refused: text-only, no SET/STEP from late.sh" \
        sh -c 'grep -q "^MODE text" "$1" && ! sed -n "/^MODE/,/^LATE-END/p" "$1" | grep -q "^PROGRESS \(SET\|STEP\)"' _ "$d/rec"
done

# ------------------------------------------------------------ proc check direct
for s in $SHELLS; do
    mkproc "$W/p-$s" 1
    check "[$s] 07preseed ancestor found through PPid links" \
        run_sh "$s" -c '. "$1"; NCZ_PROC_ROOT="$2"; ncz_bar_in_finish_install 900' _ "$L" "$W/p-$s"
    check "[$s] a pid with no 07preseed ancestor is rejected" \
        run_sh "$s" -c '. "$1"; NCZ_PROC_ROOT="$2"; ! ncz_bar_in_finish_install 902' _ "$L" "$W/p-$s"
done

echo
echo "test-progress-bar-drive: $PASS passed, $FAILS failed (shells: $SHELLS)"
[ "$FAILS" = 0 ]
