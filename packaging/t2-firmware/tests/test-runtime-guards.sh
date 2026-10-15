#!/usr/bin/env bash
# Offline tests of the actual helper functions; no network, devices, or sudo.
set -euo pipefail
: "${TMPDIR:?Set TMPDIR to the owned task directory}"
SCRIPT=$(cd "$(dirname "$0")/.." && pwd)/get-apple-firmware
WORK=$(mktemp -d "$TMPDIR/runtime-guards.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
python3 - "$SCRIPT" "$WORK/functions.sh" <<'PY'
import pathlib,sys
s=pathlib.Path(sys.argv[1]).read_text()
parts=[s.split('verify_sha256 () {',1)[1].split('rename_firmware () {',1)[0],s.split('apt_install_zero_removals () {',1)[1].split('create_firmware_archive() {',1)[0]]
pathlib.Path(sys.argv[2]).write_text('verify_sha256 () {'+parts[0]+'\napt_install_zero_removals () {'+parts[1])
PY
. "$WORK/functions.sh"
curl() {
  local out=''
  while [ "$#" -gt 0 ]; do
    if [ "$1" = -o ]; then out=$2; shift 2; else shift; fi
  done
  [ "$CURL_RC" = 0 ] || return "$CURL_RC"
  printf '%s' "$BODY" > "$out"
}
mv() { [ "$MV_RC" = 0 ] || return "$MV_RC"; command mv "$@"; }
sudo() { "$@"; }
apt-get() {
  printf '%s\n' "$*" >> "$LOG"
  case " $* " in
    *' update '*) return 0;;
    *' --simulate '*) printf '%s\n' "$SIM_TEXT"; return "$SIM_RC";;
    *) return "$REAL_RC";;
  esac
}
modprobe() { printf 'modprobe:%s\n' "$*" >> "$LOG"; }
detect_package_manager() { echo apt; }
read() { return 0; }
BODY=GOOD; CURL_RC=0; MV_RC=0
HASH=$(printf %s "$BODY" | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())')
PASS=0
ok() { PASS=$((PASS+1)); echo "PASS $1"; }
for mode in good hash curl move; do
  d="$WORK/$mode"; mkdir "$d"; printf OLD > "$d/out"
  CURL_RC=0; MV_RC=0; wanted=$HASH
  case "$mode" in hash) wanted=invalid;; curl) CURL_RC=22;; move) MV_RC=1;; esac
  if fetch_verified mock-url "$wanted" "$d/out"; then rc=0; else rc=$?; fi
  if [ "$mode" = good ]; then [ "$rc" = 0 ] && [ "$(cat "$d/out")" = GOOD ]; else [ "$rc" != 0 ] && [ "$(cat "$d/out")" = OLD ]; fi
  [ -z "$(find "$d" -name '*.partial.*' -print)" ]
  ok "fetch $mode"
done
for mode in simfail remove clean realfail apfs; do
  LOG="$WORK/$mode.log"; : > "$LOG"
  SIM_RC=0; REAL_RC=0; SIM_TEXT='Inst expected'; interactive=true; verbose=''
  case "$mode" in simfail) SIM_RC=2;; remove) SIM_TEXT='Remv existing [1.0]';; realfail) REAL_RC=7;; esac
  package=somepkg; [ "$mode" != apfs ] || package=linux-apfs-rw
  if install_package "$package"; then rc=0; else rc=$?; fi
  args='-y somepkg'; [ "$mode" != apfs ] || args='--reinstall -y apfs-dkms'
  grep -Fx -- "install --simulate $args" "$LOG" >/dev/null
  case "$mode" in
    simfail|remove) [ "$rc" != 0 ]; ! grep -Fx -- "install $args" "$LOG" >/dev/null;;
    realfail) [ "$rc" = 7 ]; grep -Fx -- "install $args" "$LOG" >/dev/null;;
    *) [ "$rc" = 0 ]; grep -Fx -- "install $args" "$LOG" >/dev/null;;
  esac
  [ "$mode" != apfs ] || grep -Fx 'modprobe:apfs' "$LOG" >/dev/null
  ok "APT $mode"
done
echo "$PASS passed, 0 failed"
