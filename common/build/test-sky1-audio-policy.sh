#!/bin/bash
# test-sky1-audio-policy.sh -- prove the ncz-sky1-audio-autoswitch default-output
# policy in BOTH directions against fixture /proc/asound layouts (no PipeWire
# needed; uses the daemon's --decide dry run).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
D="$HERE/../assets/audio/ncz-sky1-audio-autoswitch.py"
W="$(mktemp -d -t sky1-audio-policy.XXXXXX)"; trap 'rm -rf "$W"' EXIT
PASS=0; FAILS=0

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

echo "audio policy tests: $PASS passed, $FAILS failed"
[ "$FAILS" = 0 ]
