#!/bin/bash
# test-verify-drivers.sh -- tools/verify-drivers.sh expects the kernel this
# install was built with, per arch, and checks the shipped driver names.
#
# Expected-kernel resolution (tools/verify-drivers.sh --expected-kernel):
# NCZ_EXPECTED_KVER, then the KVER_NEXT sidecar (/etc/cix-installer, then
# /usr/local/lib/cix-installer), then the repository's kernel KVER file for the
# arch, then the manifests/components.tsv kernel row. Each step is exercised
# with fixture roots; the repository answer must equal the components.tsv row
# for both arches. A full run with stubbed lsmod/uname/modinfo checks that the
# NPU, GPU and VPU checks look for aipu, mali_kbase/panthor and amvx.
#
# Usage: bash build/test-verify-drivers.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
TOOL="$ROOT/tools/verify-drivers.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1" >&2; }
W="$(mktemp -d "${TMPDIR:-/tmp}/ncz-vd-test.XXXXXX")"
trap 'rm -rf "$W"' EXIT

bash -n "$TOOL" && ok "tool parses" || bad "tool does not parse"
grep -q '7\.0\.12' "$TOOL" && bad "tool still names the retired 7.0.12 kernel" || ok "tool names no fixed kernel version"

ek() { env -u NCZ_EXPECTED_KVER "$@" bash "$TOOL" --expected-kernel 2>/dev/null; }
row() { awk -F'\t' -v r="$1" '$1==r {print $7; exit}' "$ROOT/manifests/components.tsv"; }
SKY1_ROW="$(row sky1-mainline-kernel)"; AMD_ROW="$(row amd64-stable-kernel)"
[ -n "$SKY1_ROW" ] && [ -n "$AMD_ROW" ] && ok "components.tsv kernel rows: arm64 $SKY1_ROW, amd64 $AMD_ROW" \
    || bad "components.tsv kernel rows missing"

E="$W/empty-root"; mkdir -p "$E"
got="$(ek NCZ_VD_ROOT="$E" NCZ_VD_ARCH=arm64)"
[ "$got" = "$SKY1_ROW" ] && ok "arm64 from the repository = $got" || bad "arm64 from the repository: got '$got' want '$SKY1_ROW'"
got="$(ek NCZ_VD_ROOT="$E" NCZ_VD_ARCH=amd64)"
[ "$got" = "$AMD_ROW" ] && ok "amd64 from the repository = $got" || bad "amd64 from the repository: got '$got' want '$AMD_ROW'"

# components.tsv alone (no KVER files in the repository)
FR="$W/repo"; mkdir -p "$FR/manifests"
printf 'sky1-mainline-kernel\tkernel\tx\tarm64\tx\tyes\t9.9.9-rc1-sky1-ncz\n' > "$FR/manifests/components.tsv"
got="$(ek NCZ_VD_ROOT="$E" NCZ_VD_REPO="$FR" NCZ_VD_ARCH=arm64)"
[ "$got" = 9.9.9-rc1-sky1-ncz ] && ok "falls back to the components.tsv row" || bad "components.tsv fallback: got '$got'"
got="$(ek NCZ_VD_ROOT="$E" NCZ_VD_REPO="$FR" NCZ_VD_ARCH=amd64)"; rc=$?
[ -z "$got" ] && [ "$rc" != 0 ] && ok "no amd64 row -> unknown (rc=$rc)" || bad "missing amd64 row: got '$got' rc=$rc"

# sidecars win over the repository, /etc first
S="$W/root"; mkdir -p "$S/etc/cix-installer" "$S/usr/local/lib/cix-installer"
echo 8.8.8-sky1-ncz > "$S/usr/local/lib/cix-installer/KVER_NEXT"
got="$(ek NCZ_VD_ROOT="$S" NCZ_VD_ARCH=arm64)"
[ "$got" = 8.8.8-sky1-ncz ] && ok "installer sidecar wins over the repository" || bad "lib sidecar: got '$got'"
printf ' 7.7.7-sky1-ncz \n' > "$S/etc/cix-installer/KVER_NEXT"
got="$(ek NCZ_VD_ROOT="$S" NCZ_VD_ARCH=arm64)"
[ "$got" = 7.7.7-sky1-ncz ] && ok "/etc sidecar first, whitespace stripped" || bad "/etc sidecar: got '$got'"
got="$(env NCZ_EXPECTED_KVER=6.6.6-x NCZ_VD_ROOT="$S" NCZ_VD_ARCH=arm64 bash "$TOOL" --expected-kernel)"
[ "$got" = 6.6.6-x ] && ok "NCZ_EXPECTED_KVER overrides everything" || bad "override: got '$got'"

# --- full run with stubbed system tools ------------------------------------------------------
B="$W/bin"; mkdir -p "$B"
stub() { printf '#!/bin/sh\n%s\n' "$2" > "$B/$1"; chmod +x "$B/$1"; }
stub uname 'case "$1" in -r) echo "$NCZ_T_UNAME_R";; -m) echo aarch64;; *) echo Linux;; esac'
stub lsmod 'printf "Module Size Used\naipu 1 0\nmali_kbase 1 0\namvx 1 0\nmt7921e 1 0\n"'
stub modinfo 'echo "filename:       /lib/modules/k/updates/dkms/aipu.ko"'
for t in dmesg ip aplay hciconfig; do stub "$t" 'exit 0'; done
run_full() { env -u NCZ_EXPECTED_KVER PATH="$B:$PATH" NCZ_VD_ROOT="$E" NCZ_VD_ARCH=arm64 NCZ_T_UNAME_R="$1" bash "$TOOL" 2>&1 | sed 's/\x1b\[[0-9;]*m//g'; }
out="$(run_full "$SKY1_ROW")"
case "$out" in *"PASS running the installed NCZ kernel $SKY1_ROW"*) ok "full run: running the expected kernel passes" ;; *) bad "full run: no kernel PASS line" ;; esac
for want in "PASS aipu loaded" "PASS loaded from updates/" "PASS mali_kbase loaded (default GPU stack)" "PASS amvx loaded" "PASS mt79xx wifi module loaded"; do
    case "$out" in *"$want"*) ok "full run: $want" ;; *) bad "full run: missing '$want'" ;; esac
done
case "$out" in *armchina_npu*) bad "full run still checks armchina_npu" ;; *) ok "full run does not check the disabled in-tree armchina_npu" ;; esac
out="$(run_full 7.0.12-cix-sky1-next)"
case "$out" in *"WARN running 7.0.12-cix-sky1-next (expected $SKY1_ROW as default)"*) ok "full run: another kernel warns with the expected one" ;; *) bad "full run: wrong-kernel warning missing" ;; esac
out="$(env -u NCZ_EXPECTED_KVER PATH="$B:$PATH" NCZ_VD_ROOT="$E" NCZ_VD_ARCH=amd64 NCZ_T_UNAME_R="$AMD_ROW" bash "$TOOL" 2>&1 | sed 's/\x1b\[[0-9;]*m//g')"
case "$out" in *"PASS running the installed NCZ kernel $AMD_ROW"*"Sky1 subsystem checks skipped (arch amd64)"*) ok "full run on amd64: kernel checked, Sky1 checks skipped" ;; *) bad "full run on amd64: unexpected output" ;; esac

echo "# test-verify-drivers: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
