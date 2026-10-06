#!/bin/bash
# test-sky1-audio-policy.sh -- prove the ncz-sky1-audio-autoswitch default-output
# policy in BOTH directions against fixture /proc/asound layouts (no PipeWire
# needed; uses the daemon's --decide dry run), then drive the real daemon loop
# against a stateful fake pactl/aplay (build/testdata/sky1-audio/) to prove the
# DP/HDMI hw_params guard: a PCM that answers EINVAL (MS-R1 on 7.3-rc6, I2S MCLK
# 0 Hz) is never turned into a sink, analog is chosen, and nothing loops.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
D="$HERE/../assets/audio/ncz-sky1-audio-autoswitch.py"
STUBS="$HERE/testdata/sky1-audio"
W="$(mktemp -d -t sky1-audio-policy.XXXXXX)"; trap 'rm -rf "$W"' EXIT
PASS=0; FAILS=0
# aplay/pactl/amixer on PATH are the fakes: the --decide probe must never touch real ALSA here
mkdir -p "$W/bin"; for t in pactl aplay amixer pw-dump; do ln -s "$STUBS/fake-$t" "$W/bin/$t"; done
export PATH="$W/bin:$PATH"
export FAKE_APLAY_FAIL="" FAKE_APLAY_BUSY=""

eld() {  # $1 dir $2 idx $3 sad_count $4 monitor
    printf 'monitor_name\t%s\nconnection_type\tDisplayPort\nsad_count\t%s\n' "$4" "$3" > "$1/eld#$2"
}
sky1_card() {  # $1 root $2 card index
    mkdir -p "$1/card$2"; for i in 0 1 2; do eld "$1/card$2" $i 0 ""; done
}
hda_card() {  # $1 root $2 card index
    mkdir -p "$1/card$2/pcm0p" "$1/card$2/pcm1p"
    echo "name: ALC269VC Analog" > "$1/card$2/pcm0p/info"
    echo "name: ALC269VC Digital" > "$1/card$2/pcm1p/info"
}
CARDS_SKY1=' 1 [cixsky1        ]: cix_sky1 - cix,sky1
                      Board-X'

check() {  # name want root
    local got; got="$(NCZ_SKY1_PROC_ROOT="$3" python3 "$D" --decide 2>&1)"
    if [ "$got" = "$2" ]; then echo "PASS  $1 -> $got"; PASS=$((PASS+1));
    else echo "FAIL  $1: got '$got' want '$2'"; FAILS=$((FAILS+1)); fi
}

# O6N-like: only the sky1 card (card 0), 3 DP, monitor on eld#1
r="$W/o6n"; mkdir -p "$r"; sky1_card "$r" 0; eld "$r/card0" 1 1 VP2488-4K
printf ' 0 [cixsky1        ]: cix_sky1 - cix,sky1\n                      Radxa\n' > "$r/cards"
check "O6N-like, monitor with audio -> DP sink" "hdmi ncz_sky1_hdmi_0_1 hw:0,1" "$r"
eld "$r/card0" 1 0 ""
check "O6N-like, no monitor -> nothing" "none" "$r"

# MS-R1-like: HDA card 0 (analog+digital) + sky1 card 1
r="$W/msr1"; mkdir -p "$r"; hda_card "$r" 0; sky1_card "$r" 1
printf ' 0 [cixipbloqhda   ]: cix-ipbloq-hda - cix-ipbloq-hda\n                      cix-ipbloq-hda at 0x70c0000 irq 41\n%s\n' "$CARDS_SKY1" > "$r/cards"
check "MS-R1-like, no monitor -> analog out" "analog ncz_sky1_analog_0_0 hw:0,0" "$r"
eld "$r/card1" 2 1 VP2488-4K
check "MS-R1-like, monitor with audio -> DP wins over analog" "hdmi ncz_sky1_hdmi_1_2 hw:1,2" "$r"
eld "$r/card1" 2 0 ""
check "MS-R1-like, monitor unplugged again -> back to analog" "analog ncz_sky1_analog_0_0 hw:0,0" "$r"

# no card at all
r="$W/none"; mkdir -p "$r"; : > "$r/cards"
check "no Sky1 audio card -> nothing" "none" "$r"
r="$W/nocards"; mkdir -p "$r"
check "no /proc/asound/cards -> nothing" "none" "$r"

# HDA card without any playback PCM -> nothing
r="$W/hdaempty"; mkdir -p "$r/card0"
printf ' 0 [cixipbloqhda   ]: cix-ipbloq-hda - cix-ipbloq-hda\n                      x\n' > "$r/cards"
check "HDA card without playback PCM -> nothing" "none" "$r"

# HDA card whose only playback PCM is not analog -> nothing (never route to digital)
r="$W/hdadig"; mkdir -p "$r/card0/pcm0p"; echo "name: ALC269VC Digital" > "$r/card0/pcm0p/info"
printf ' 0 [cixipbloqhda   ]: cix-ipbloq-hda - cix-ipbloq-hda\n                      x\n' > "$r/cards"
check "HDA card with only a digital PCM -> nothing" "none" "$r"
NCZ_SKY1_PROC_ROOT="$r" python3 "$D" --decide --proc-root >/dev/null 2>&1; rc=$?
if [ "$rc" = 2 ]; then echo "PASS  --proc-root without argument exits 2"; PASS=$((PASS+1)); else echo "FAIL  --proc-root without argument rc=$rc"; FAILS=$((FAILS+1)); fi

ok()  { echo "PASS  $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL  $1"; FAILS=$((FAILS+1)); }

# --- hw_params guard in the --decide path --------------------------------------
r="$W/msr1g"; mkdir -p "$r"; hda_card "$r" 0; sky1_card "$r" 1; eld "$r/card1" 2 1 VP2488-4K
printf ' 0 [cixipbloqhda   ]: cix-ipbloq-hda - cix-ipbloq-hda\n                      x\n%s\n' "$CARDS_SKY1" > "$r/cards"
FAKE_APLAY_FAIL="hw:1,2" check "MS-R1, monitor with audio but hw:1,2 hw_params EINVAL -> analog" "analog ncz_sky1_analog_0_0 hw:0,0" "$r"
FAKE_APLAY_BUSY="hw:1,2" check "MS-R1, hw:1,2 busy (already open) still counts as usable -> DP" "hdmi ncz_sky1_hdmi_1_2 hw:1,2" "$r"
eld "$r/card1" 0 1 OTHER
FAKE_APLAY_FAIL="hw:1,0" check "two monitors, lower PCM broken -> the working higher one" "hdmi ncz_sky1_hdmi_1_2 hw:1,2" "$r"
r="$W/o6ng"; mkdir -p "$r"; sky1_card "$r" 0; eld "$r/card0" 1 1 VP2488-4K
printf ' 0 [cixsky1        ]: cix_sky1 - cix,sky1\n                      Radxa\n' > "$r/cards"
FAKE_APLAY_FAIL="hw:0,1" check "O6N-like, DP PCM broken and no analog -> nothing (no broken default)" "none" "$r"
mkdir -p "$W/noaplay"; for t in pactl amixer pw-dump; do ln -s "$STUBS/fake-$t" "$W/noaplay/$t"; done
got="$(PATH="$W/noaplay:/usr/bin:/bin" NCZ_SKY1_PROC_ROOT="$r" python3 "$D" --decide 2>&1)"
if [ -x /usr/bin/aplay ] || [ -x /bin/aplay ]; then echo "SKIP  aplay missing -> probe skipped (host has a real aplay)";
elif [ "$got" = "hdmi ncz_sky1_hdmi_0_1 hw:0,1" ]; then ok "aplay missing -> probe skipped, DP still chosen"; else bad "aplay missing: got '$got'"; fi

# --- daemon loop against the stateful fake pactl --------------------------------
run_daemon() {  # $1 proc root, $2 iterations; env FAKE_* set by caller. 20 s watchdog: a daemon
    # that ignores NCZ_SKY1_AUDIO_ITERATIONS (a regression) must fail the test, not hang it.
    NCZ_SKY1_PROC_ROOT="$1" NCZ_SKY1_AUDIO_POLL_SECONDS=0 NCZ_SKY1_AUDIO_ITERATIONS="$2" \
        python3 "$D" 2>"$W/daemon.err" &
    local pid=$! i=0
    while kill -0 "$pid" 2>/dev/null && [ $i -lt 200 ]; do sleep 0.1; i=$((i+1)); done
    kill -0 "$pid" 2>/dev/null && { kill "$pid"; echo "watchdog: daemon still running after 20 s" >> "$W/daemon.err"; }
    wait "$pid" 2>/dev/null; echo "rc=$?" >> "$W/daemon.err"
}
pa_init() {  # $1 = JSON list of native sinks
    printf '{"native": %s, "modules": [], "default": "auto_null"}' "$1" > "$W/pa.json"
    : > "$W/aplay.log"
}
export FAKE_PA_STATE="$W/pa.json" FAKE_APLAY_LOG="$W/aplay.log"
st() { python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$W/pa.json" "$1"; }
r="$W/msr1g"; eld "$r/card1" 0 0 ""   # back to: one monitor (hw:1,2) with audio

# (a) MS-R1 as found on 2026-10-06: DP PCM refuses hw_params -> analog default, DP never loaded, probed once
pa_init '[]'
FAKE_APLAY_FAIL="hw:1,2" run_daemon "$r" 10
[ "$(st 's["default"]')" = ncz_sky1_analog_0_0 ] && ok "daemon: EINVAL DP -> default is the analog sink" || bad "daemon: default=$(st 's["default"]') ($(tail -3 "$W/daemon.err" | tr '\n' ' '))"
n=$(st 'sum("device=hw:1,2" in c for c in s["calls"])')
[ "$n" = 0 ] && ok "daemon: no module-alsa-sink is ever loaded for the broken hw:1,2" || bad "daemon: hw:1,2 loaded $n times"
n=$(grep -c 'hw:1,2' "$W/aplay.log")
[ "$n" = 1 ] && ok "daemon: broken PCM probed once in 10 polls (back-off holds)" || bad "daemon: hw:1,2 probed $n times in 10 polls"
n=$(grep -c 'is not usable' "$W/daemon.err")
[ "$n" = 1 ] && ok "daemon: failure logged once, no per-poll spam" || bad "daemon: 'not usable' logged $n times"
grep -q 'No such entity' "$W/daemon.err" && bad "daemon: set-default-sink hit a vanished sink" || ok "daemon: no 'No such entity' set-default failures"

# (a2) as found live: a DP sink loaded by an earlier instance already exists and is the default,
# but its PCM refuses hw_params -> probe anyway, switch to analog, unload the stale DP sink
pa_init '[]'
python3 - "$W/pa.json" <<'J'
import json,sys; p=sys.argv[1]; s=json.load(open(p))
s["modules"]=[{"id":400,"sink":"ncz_sky1_hdmi_1_2","device":"hw:1,2"}]; s["default"]="ncz_sky1_hdmi_1_2"; json.dump(s,open(p,"w"))
J
FAKE_APLAY_FAIL="hw:1,2" run_daemon "$r" 5
[ "$(st 's["default"]')" = ncz_sky1_analog_0_0 ] && ok "daemon: pre-existing default DP sink on an EINVAL PCM is not trusted -> analog" || bad "daemon (a2): default=$(st 's["default"]')"
[ "$(st 'sum(m["sink"]=="ncz_sky1_hdmi_1_2" for m in s["modules"])')" = 0 ] && ok "daemon: stale DP sink on the broken PCM unloaded" || bad "daemon (a2): stale DP sink still loaded"

# (b) probe passes but the sink dies at start (pipewire-pulse drops the module): park it, fall back to analog
pa_init '[]'
python3 - "$W/pa.json" <<'J'
import json,sys; p=sys.argv[1]; s=json.load(open(p)); s["start_fail"]=["hw:1,2"]; json.dump(s,open(p,"w"))
J
run_daemon "$r" 10
n=$(st 'sum("device=hw:1,2" in c for c in s["calls"])')
[ "$n" = 1 ] && ok "daemon: sink that vanishes after start is loaded once, not every poll" || bad "daemon: vanishing hw:1,2 sink loaded $n times"
[ "$(st 's["default"]')" = ncz_sky1_analog_0_0 ] && ok "daemon: after the DP sink died the analog sink is default" || bad "daemon: default=$(st 's["default"]')"

# (c) healthy DP: selected, kept, not re-probed while it is the working default
pa_init '[]'
run_daemon "$r" 10
[ "$(st 's["default"]')" = ncz_sky1_hdmi_1_2 ] && ok "daemon: healthy DP with audio -> DP sink is default" || bad "daemon: default=$(st 's["default"]')"
n=$(grep -c 'hw:1,2' "$W/aplay.log")
[ "$n" = 1 ] && ok "daemon: working default DP sink is not re-opened every poll" || bad "daemon: healthy hw:1,2 probed $n times"

# (d) WirePlumber's own ACP sink appears for hw:0,0 (jack plugged): use it, drop our duplicate
r2="$W/msr1n"; mkdir -p "$r2"; hda_card "$r2" 0; sky1_card "$r2" 1; cp "$r/cards" "$r2/cards"
pa_init '[]'
run_daemon "$r2" 2
[ "$(st 's["default"]')" = ncz_sky1_analog_0_0 ] || bad "daemon (d) setup: default=$(st 's["default"]')"
python3 - "$W/pa.json" <<'J'
import json,sys; p=sys.argv[1]; s=json.load(open(p))
s["native"]=[{"name":"alsa_output.platform-CIXH6020_00.stereo-fallback","card":"0","dev":"0"}]; json.dump(s,open(p,"w"))
J
run_daemon "$r2" 3
[ "$(st 's["default"]')" = alsa_output.platform-CIXH6020_00.stereo-fallback ] && ok "daemon: native ACP sink for hw:0,0 preferred over our module sink" || bad "daemon: default=$(st 's["default"]')"
[ "$(st 'len(s["modules"])')" = 0 ] && ok "daemon: our duplicate hw:0,0 module-alsa-sink unloaded" || bad "daemon: modules left: $(st 's["modules"]')"

# (e) O6N as found on 2026-10-06: the DP sink is selected, then its node sits in the "error" state
# (still listed). Streams to it never run (pw-play hangs, Chromium video stalls on its audio clock).
# The only other sink (WirePlumber's stereo-fallback on DP0) is in error too -> park the DP PCM,
# drop our broken sink, and default to a silent null sink so players keep running.
r3="$W/o6ne"; mkdir -p "$r3"; sky1_card "$r3" 0; eld "$r3/card0" 1 1 QiSi-AUGRA
printf ' 0 [cixsky1        ]: cix_sky1 - cix,sky1\n                      Radxa\n' > "$r3/cards"
pa_init '[{"name":"alsa_output.platform-CIXH6070_00.stereo-fallback","card":"0","dev":"0"}]'
python3 - "$W/pa.json" <<'J'
import json,sys; p=sys.argv[1]; s=json.load(open(p))
s["persist_fail"]=["hw:0,1"]; s["errored"]=["alsa_output.platform-CIXH6070_00.stereo-fallback"]; s["garbage"]=True; json.dump(s,open(p,"w"))
J
run_daemon "$r3" 6
grep -q 'UnicodeDecodeError\|codec can.t decode' "$W/daemon.err" && bad "daemon: non-UTF-8 pactl output killed iterations" || ok "daemon: non-UTF-8 bytes in pactl output tolerated"
[ "$(st 's["default"]')" = ncz_sky1_silent ] && ok "daemon: DP sink in error state + broken fallback -> silent null sink default" || bad "daemon (e): default=$(st 's["default"]') ($(tail -4 "$W/daemon.err" | tr '\n' ' '))"
[ "$(st 'sum(m["sink"]=="ncz_sky1_hdmi_0_1" for m in s["modules"])')" = 0 ] && ok "daemon: errored DP sink unloaded" || bad "daemon (e): errored DP sink still loaded"
n=$(st 'sum("device=hw:0,1" in c for c in s["calls"])')
[ "$n" = 1 ] && ok "daemon: errored DP sink not reloaded inside the back-off" || bad "daemon (e): hw:0,1 loaded $n times"

echo "audio policy tests: $PASS passed, $FAILS failed"
[ "$FAILS" = 0 ]
