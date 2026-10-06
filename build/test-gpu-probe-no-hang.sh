#!/bin/bash
# test-gpu-probe-no-hang.sh -- install-time GPU probing never blocks on a
# wedged device (PEGASUS install hang, 2026-10-06).
#
# PEGASUS (ASUS GU502LV, RTX 2060 Mobile TU106 10de:1f15, Optimus) hung for
# 30+ minutes in post-install/54-gpu-accel.sh: after nouveau's runtime
# suspend oopsed, `lspci -nn` blocked in D state reading the GPU's config
# space. Contract, each checked against the SHIPPED code:
#
#   1. lib/pci-sysfs.sh enumerates PCI devices from sysfs in lspci -nn shape;
#   2. 54-gpu-accel.sh with an lspci that HANGS: completes, never calls lspci,
#      detects NVIDIA + Intel from sysfs; a hanging rocminfo is timed out; the
#      AMD NPU is found by ID; no sysfs PCI list is a clean skip;
#   3. lib/hw-detect.sh T2 detection with a hanging lspci answers from sysfs
#      (55-t2-firmware.sh runs right after 54 and would hang the same way).
#
# Without the fix, check 2 and 3 run into their outer time limits.
# Linux only; run on a build host. NCZ_TEST_ROOT=<tree> tests another
# checkout. Exit 0 = pass, 1 = fail.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="${NCZ_TEST_ROOT:-$(cd "$HERE/.." && pwd)}"
W="$(mktemp -d)" && [ -d "$W" ] || { echo "cannot create a scratch dir"; exit 2; }
trap 'rm -rf "$W"' EXIT
PASS=0; FAIL=0
ok()  { echo "  PASS  $1"; PASS=$((PASS + 1)); }
nok() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); }
extract_between() { awk -v b="$2" -v e="$3" '$0 ~ b {f=1; next} $0 ~ e {f=0} f' "$1"; }

# fake sysfs PCI device: mkdev <root> <bdf> <class> <vendor> <device>
mkdev() {
    mkdir -p "$1/$2"
    printf '0x%s\n' "$3" > "$1/$2/class"
    printf '0x%s\n' "$4" > "$1/$2/vendor"
    printf '0x%s\n' "$5" > "$1/$2/device"
}
# a `lspci` that hangs like the D-state one did, and records that it ran
mkhang() { # mkhang <bindir> <name>
    mkdir -p "$1"
    printf '#!/bin/bash\necho called >> "%s/%s.called"\nexec sleep 3601\n' "$1" "$2" > "$1/$2"
    chmod +x "$1/$2"
}

echo "=== 1. lib/pci-sysfs.sh ==="
P="$W/pci"
mkdev "$P" 0000:00:02.0 030000 8086 3e9b
mkdev "$P" 0000:01:00.0 030000 10de 1f15
mkdev "$P" 0000:01:00.1 040300 10de 10f9
out=$(NCZ_PCI_DEVICES_ROOT="$P" bash -c ". '$ROOT/post-install/lib/pci-sysfs.sh'; ncz_pci_lspci_nn")
printf '%s\n' "$out" | grep -qx '0000:01:00.0 Class \[0300\]: Device \[10de:1f15\]' \
    && ok "RTX 2060 line in lspci -nn shape" || nok "unexpected pci-sysfs output: $out"
[ "$(printf '%s\n' "$out" | grep -cE '\[03(00|02|80)\]:')" = 2 ] && ok "two display-class devices found" || nok "display-class count wrong"
mkdir -p "$W/nopci"
NCZ_PCI_DEVICES_ROOT="$W/nopci" bash -c ". '$ROOT/post-install/lib/pci-sysfs.sh'; ncz_pci_available" \
    && nok "empty sysfs root reported as available" || ok "empty sysfs root -> not available"

echo "=== 2. 54-gpu-accel.sh with a hanging lspci ==="
SB="$W/sb54"; mkdir -p "$SB/post-install/lib" "$SB/bin" "$SB/log"
cp "$ROOT/post-install/lib/"*.sh "$SB/post-install/lib/"
sed -e "s#/var/lib/ncz#$SB/var/lib/ncz#g" -e "s#/etc/#$SB/etc/#g" -e "s#/var/log#$SB/log#g" \
    -e "s#/usr/local/lib/cix-installer#$SB/meta#g" -e "s#/usr/local/sbin#$SB/sbin#g" \
    -e "s#/usr/share/keyrings#$SB/keyrings#g" \
    "$ROOT/post-install/54-gpu-accel.sh" > "$SB/post-install/54-gpu-accel.sh"
mkhang "$SB/bin" lspci
printf '#!/bin/bash\n[ "$1" = --print-architecture ] && echo amd64\nexit 0\n' > "$SB/bin/dpkg"
for c in apt-get gpg; do printf '#!/bin/bash\nexit 0\n' > "$SB/bin/$c"; done
printf '#!/bin/bash\nexit 7\n' > "$SB/bin/curl"
chmod +x "$SB/bin/"*
run54() { # run54 <sysfs root> [env...] -> rc in $RC54, output in $SB/out
    local p="$1"; shift
    rm -f "$SB/bin/"*.called
    env PATH="$SB/bin:$PATH" NCZ_TARGET_ARCH=amd64 NCZ_SKIP_CUDA=1 NCZ_PCI_DEVICES_ROOT="$p" "$@" \
        timeout -k 5 60 bash "$SB/post-install/54-gpu-accel.sh" > "$SB/out" 2>&1
    RC54=$?
}
P54="$W/pci54"
mkdev "$P54" 0000:00:02.0 030000 8086 3e9b
mkdev "$P54" 0000:01:00.0 030000 10de 1f15
t0=$(date +%s); run54 "$P54"; dt=$(( $(date +%s) - t0 ))
[ "$RC54" = 0 ] && ok "hook completed rc 0 in ${dt}s (PEGASUS GPU set)" || { nok "hook rc=$RC54 after ${dt}s (124 = hung on lspci)"; tail -5 "$SB/out" | sed 's/^/        /'; }
[ ! -e "$SB/bin/lspci.called" ] && ok "lspci was never invoked" || nok "lspci was invoked"
grep -q 'GPU/accelerator wiring done (NVIDIA=1 AMD=0 Intel=1)' "$SB/out" && ok "NVIDIA + Intel detected from sysfs" || nok "wrong detection: $(grep 'wiring done' "$SB/out")"
mkhang "$SB/bin" rocminfo
P54A="$W/pci54a"; mkdev "$P54A" 0000:0d:00.0 030000 1002 15bf; mkdev "$P54A" 0000:0e:00.1 118000 1022 1502
t0=$(date +%s); run54 "$P54A" NCZ_GPU_PROBE_TIMEOUT=2; dt=$(( $(date +%s) - t0 ))
[ "$RC54" = 0 ] && [ "$dt" -lt 30 ] && ok "hanging rocminfo: hook completed in ${dt}s" || nok "hanging rocminfo: rc=$RC54 after ${dt}s"
grep -q 'rocminfo.*timed out after 2s' "$SB/out" && ok "rocminfo timeout logged" || nok "rocminfo timeout not logged"
grep -q 'AMD XDNA/Ryzen-AI NPU detected' "$SB/out" && ok "AMD NPU (1022:1502) detected by ID from sysfs" || nok "AMD NPU not detected"
rm -f "$SB/bin/rocminfo"
run54 "$W/nopci"
grep -q 'skipped:no-pci-sysfs' "$SB/var/lib/ncz/cuda-toolkit.status" 2>/dev/null && [ "$RC54" = 0 ] \
    && ok "no sysfs PCI list -> clean skip recorded" || nok "no-sysfs case: rc=$RC54 status=$(cat "$SB/var/lib/ncz/cuda-toolkit.status" 2>/dev/null)"
if grep -vE '^\s*#' "$ROOT/post-install/54-gpu-accel.sh" "$ROOT/post-install/lib/cuda-select.sh" "$ROOT/post-install/lib/hw-detect.sh" \
   | grep -E '(^|[^_a-z])lspci([^_a-z]|$)' | grep -v 'ncz_pci_lspci_nn' | grep -q .; then
    nok "a hook/lib still calls lspci outside comments"
else
    ok "54-gpu-accel.sh, cuda-select.sh and hw-detect.sh contain no lspci call"
fi

echo "=== 3. hw-detect.sh T2 detection with a hanging lspci ==="
PT="$W/pcit2"; mkdev "$PT" 0000:04:00.1 000000 106b 1801
for case_ in t2 not; do
    root="$P54"; want=1; [ "$case_" = t2 ] && { root="$PT"; want=0; }
    rm -f "$SB/bin/lspci.called"
    env PATH="$SB/bin:$PATH" NCZ_PCI_DEVICES_ROOT="$root" timeout -k 5 20 \
        bash -c ". '$ROOT/post-install/lib/hw-detect.sh'; is_t2_hardware" >/dev/null 2>&1
    rc=$?
    [ "$rc" = "$want" ] && [ ! -e "$SB/bin/lspci.called" ] && ok "is_t2_hardware ($case_) = $rc from sysfs, no lspci" \
        || nok "is_t2_hardware ($case_) rc=$rc want $want, lspci called: $([ -e "$SB/bin/lspci.called" ] && echo yes || echo no)"
done


echo
echo "test-gpu-probe-no-hang: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
