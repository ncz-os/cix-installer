#!/bin/bash
# Contract tests for the T2 boot-noise / console-loglevel policy (2026-10-11).
#
# Pins the decisions behind docs/T2-CONSOLE-NOISE.md so a later edit cannot
# silently (a) drop the two root-cause modprobe.d fixes, (b) lower the console
# loglevel below the safe floor of 3 (which would hide KERN_CRIT, i.e. real
# MCE "[Hardware Error]" records), or (c) lose the chip-class-aware Bluetooth
# firmware check. These are content contracts; behaviour is exercised by the
# live-host triage recorded in the mission report.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FW="$ROOT/post-install/55-t2-firmware.sh"
BH="$ROOT/post-install/58-boot-hygiene.sh"
DOC="$ROOT/docs/T2-CONSOLE-NOISE.md"
fail=0
ok()   { echo "ok   $1"; }
bad()  { echo "FAIL $1"; fail=$((fail+1)); }
has()  { grep -qF -- "$2" "$1"; }

# --- syntax -----------------------------------------------------------------
bash -n "$FW" && ok "55-t2-firmware.sh parses" || bad "55-t2-firmware.sh syntax"
bash -n "$BH" && ok "58-boot-hygiene.sh parses" || bad "58-boot-hygiene.sh syntax"

# --- (1) brcmfmac P2P disabled (bit 4 = BRCMF_FEAT_P2P = 0x10) --------------
has "$FW" "feature_disable=0x10" \
  && ok "55: brcmfmac feature_disable=0x10 present" \
  || bad "55: brcmfmac P2P disable missing"
grep -q "ncz-t2-brcmfmac-p2p.conf" "$FW" \
  && ok "55: writes /etc/modprobe.d/ncz-t2-brcmfmac-p2p.conf" \
  || bad "55: brcmfmac p2p modprobe.d file not written"

# --- (2) pcspkr duplicate-registration fix ----------------------------------
grep -q "ncz-t2-pcspkr.conf" "$FW" \
  && ok "55: writes /etc/modprobe.d/ncz-t2-pcspkr.conf" \
  || bad "55: pcspkr modprobe.d file not written"
has "$FW" "blacklist snd_pcsp" \
  && ok "55: blacklists snd_pcsp (the losing duplicate)" \
  || bad "55: snd_pcsp blacklist missing"

# --- (3) Bluetooth verification is chip-class aware --------------------------
has "$FW" "T2_BT_FW_MODELS" \
  && ok "55: chip-class BT firmware verification present" \
  || bad "55: chip-class BT firmware verification missing"
has "$FW" "BCM4377-class" \
  && ok "55: distinguishes BCM4377 models from UART/ROM models" \
  || bad "55: BCM4377 branch missing"
has "$FW" "brcm/BCM.hcd is intentionally absent" \
  && ok "55: reports absent BCM.hcd as expected (not a failure) on UART T2" \
  || bad "55: expected-absent BCM.hcd reporting missing"

# --- (4) console loglevel floor must stay at 3, never 2 ---------------------
has "$BH" "kernel.printk = 3 4 1 3" \
  && ok "58: kernel.printk floor is 3" \
  || bad "58: kernel.printk 3 4 1 3 missing"
if grep -qE "kernel\.printk = 2( |$)" "$BH"; then
  bad "58: console loglevel lowered to 2 (would hide KERN_CRIT/MCE)"
else
  ok "58: console loglevel not lowered to 2"
fi
has "$BH" "never hide" \
  && ok "58: documents the never-hide-MCE/AER/EDAC rationale" \
  || bad "58: MCE rationale missing"

# --- (5) the policy doc exists ----------------------------------------------
[ -s "$DOC" ] && ok "docs/T2-CONSOLE-NOISE.md present" || bad "policy doc missing"

echo "---"
if [ "$fail" -eq 0 ]; then
  echo "t2-console-noise contract tests: PASS"
else
  echo "t2-console-noise contract tests: $fail FAILED"
fi
exit "$fail"
