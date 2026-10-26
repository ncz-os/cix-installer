#!/usr/bin/env bash
# test-module-abi-gate.sh -- the out-of-tree module ABI gate (2026-10-26, O6N
# r292: mali_kbase, memory_group_manager and protected_memory_allocator had
# struct module 0x4c0 against the kernel's 0x500 and were refused at load,
# "section size must match"; no GPU, no desktop).
#
#   1. build/verify-module-abi.py on synthetic ELF64 modules: a matching tree
#      passes; this_module size drift fails; vermagic drift fails; .ko.xz is
#      read; no reference is an input error; an empty tree fails unless
#      --allow-empty.
#   2. ncz-module-abi-probe (post-install/97-firstboot-report.sh) with stub
#      modprobe/journalctl/systemd-detect-virt: a loader rejection fails, a
#      clean load passes, a blacklisted module is a skip, real hardware is
#      left untouched.
#   3. verify-module-abi.py --probe-report (the KVM gate's verdict on the
#      probe lines): clean passes; FAIL, kernel-log rejection, skipped probe,
#      missing summary and failed>0 fail.
#   4. wiring: kernel .deb packaging and the KVM gate call the checks.
#
# Real modules: NCZ_MODULE_ABI_BAD_TREE / NCZ_MODULE_ABI_GOOD_TREE, when set,
# are lib/modules/<kver> trees that must FAIL / PASS (proof runs, not CI).
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TOOL="$SCRIPT_DIR/verify-module-abi.py"
T="$(mktemp -d "${TMPDIR:-/tmp}/test-module-abi.XXXXXX")"
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
VM="7.3.0-sky1-ncz SMP preempt mod_unload modversions aarch64"

ok() { echo "PASS: $1"; PASS=$((PASS + 1)); }
no() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# mkko <out> <this_module size hex|-> <vermagic|->
mkko() {
    python3 - "$@" <<'PY'
import struct, sys
out, tm, vm = sys.argv[1:4]
secs = []
if tm != "-":
    secs.append((".gnu.linkonce.this_module", 1, b"\0" * int(tm, 16)))
if vm != "-":
    secs.append((".modinfo", 1, b"license=GPL\0vermagic=" + vm.encode() + b"\0"))
shstr = b"\0"; names = []
for s in secs:
    names.append(len(shstr)); shstr += s[0].encode() + b"\0"
names.append(len(shstr)); shstr += b".shstrtab\0"
secs.append((".shstrtab", 3, shstr))
data = bytearray(64); offs = []
for s in secs:
    offs.append(len(data)); data += s[2]
    while len(data) % 8: data += b"\0"
shoff = len(data); data += b"\0" * 64
for i, s in enumerate(secs):
    data += struct.pack("<IIQQQQIIQQ", names[i], s[1], 0, 0, offs[i], len(s[2]), 0, 0, 8, 0)
hdr = b"\x7fELF" + bytes([2, 1, 1, 0]) + b"\0" * 8
hdr += struct.pack("<HHIQQQIHHHHHH", 1, 183, 1, 0, 0, shoff, 0, 64, 0, 0, 64, len(secs) + 1, len(secs))
data[:64] = hdr
if out.endswith(".xz"):
    import lzma
    data = lzma.compress(bytes(data))
open(out, "wb").write(bytes(data))
PY
}

tree() {   # tree <dir>: in-tree reference + a good updates/ and updates/dkms/ module
    mkdir -p "$1/kernel/drivers/gpu" "$1/updates/dkms"
    mkko "$1/kernel/drivers/gpu/ref.ko" 0x500 "$VM"
    mkko "$1/updates/mali_kbase.ko" 0x500 "$VM"
    mkko "$1/updates/dkms/panthor.ko" 0x500 "$VM"
}

# expect <name> <want-rc> <regex> <args...>
expect() {
    local name=$1 want=$2 re=$3 out rc; shift 3
    out=$(python3 "$TOOL" "$@" 2>&1); rc=$?
    if [ "$rc" = "$want" ] && printf '%s\n' "$out" | grep -qE "$re"; then ok "$name (rc=$rc)"
    else no "$name (rc=$rc want $want, /$re/)"; printf '%s\n' "$out" | sed 's/^/    /'; fi
}

# --- 1. static checker ----------------------------------------------------
tree "$T/good"
expect "matching out-of-tree modules pass" 0 'PASS \(2 module' "$T/good"
tree "$T/size"; mkko "$T/size/updates/mali_kbase.ko" 0x4c0 "$VM"
expect "struct module size drift fails (0x4c0 vs 0x500)" 1 'FAIL updates/mali_kbase.ko: this_module 0x4c0 != kernel 0x500' "$T/size"
tree "$T/vm"; mkko "$T/vm/updates/dkms/panthor.ko" 0x500 "7.3.0-rc7-sky1-ncz SMP preempt mod_unload modversions aarch64"
expect "vermagic drift fails" 1 'FAIL updates/dkms/panthor.ko: vermagic' "$T/vm"
tree "$T/xz"; rm -f "$T/xz/updates/mali_kbase.ko"; mkko "$T/xz/updates/mali_kbase.ko.xz" 0x4c0 "$VM"
expect ".ko.xz is decompressed and checked" 1 'FAIL updates/mali_kbase.ko.xz: this_module 0x4c0' "$T/xz"
tree "$T/noref"; rm -rf "$T/noref/kernel"
expect "no in-tree reference is an input error" 2 'no reference module' "$T/noref"
expect "--ref overrides the in-tree reference" 0 'PASS' "$T/noref" --ref "$T/good/kernel/drivers/gpu/ref.ko"
mkdir -p "$T/empty/kernel"; mkko "$T/empty/kernel/ref.ko" 0x500 "$VM"
expect "empty tree fails" 1 'no out-of-tree modules' "$T/empty"
expect "empty tree passes with --allow-empty" 0 'PASS \(no out-of-tree' "$T/empty" --allow-empty
tree "$T/junk"; printf 'not elf' > "$T/junk/updates/aipu.ko"
expect "unreadable module fails" 1 'FAIL updates/aipu.ko: unreadable' "$T/junk"
tree "$T/notmod"; mkko "$T/notmod/updates/amvx.ko" - "$VM"
expect "ELF without this_module fails" 1 'amvx.ko: unreadable: no .gnu.linkonce.this_module' "$T/notmod"

if [ -n "${NCZ_MODULE_ABI_BAD_TREE:-}" ]; then
    expect "REAL: bad tree fails" 1 'section size must match' "$NCZ_MODULE_ABI_BAD_TREE"
fi
if [ -n "${NCZ_MODULE_ABI_GOOD_TREE:-}" ]; then
    expect "REAL: good tree passes" 0 'PASS' "$NCZ_MODULE_ABI_GOOD_TREE"
fi

# --- 2. runtime probe (extracted from 97-firstboot-report.sh) -------------
PROBE="$T/ncz-module-abi-probe"
sed -n "/^cat > \/usr\/local\/sbin\/ncz-module-abi-probe <<'PROBE'$/,/^PROBE$/p" \
    "$ROOT/post-install/97-firstboot-report.sh" | sed '1d;$d' > "$PROBE"
[ -s "$PROBE" ] && ok "probe script extracted" || no "probe script extracted from 97-firstboot-report.sh"
# stubs <dir> <virt rc> <modprobe body>
stubs() {
    mkdir -p "$1"
    printf '#!/bin/sh\nexit %s\n' "$2" > "$1/systemd-detect-virt"
    printf '#!/bin/sh\n[ "$1" = -r ] && exit 0\n%s\n' "$3" > "$1/modprobe"
    printf '#!/bin/sh\ncat "%s/kmsg" 2>/dev/null\n' "$1" > "$1/journalctl"
    chmod +x "$1"/*
}
probe() {   # probe <stubdir> <moddir>
    PATH="$1:$PATH" NCZ_MODULE_ABI_MODDIR="$2" sh "$PROBE" 2>&1
}
pexpect() {  # pexpect <name> <regex> <output>
    if printf '%s\n' "$3" | grep -qE "$2"; then ok "$1"; else no "$1 (/$2/)"; printf '%s\n' "$3" | sed 's/^/    /'; fi
}
tree "$T/rt"
stubs "$T/s1" 0 'echo "modprobe: ERROR: could not insert '"'"'$1'"'"': Exec format error" >&2; exit 1'
printf '%s\n' "module mali_kbase: .gnu.linkonce.this_module section size must match the kernel's built struct module size at run time" > "$T/s1/kmsg"
out=$(probe "$T/s1" "$T/rt")
pexpect "probe: loader rejection is a FAIL line" '^# module-abi: mali_kbase FAIL rc=1 .*Exec format error' "$out"
pexpect "probe: kernel log rejection is reported" '^# module-abi-reject: module mali_kbase: .gnu.linkonce.this_module section size must match' "$out"
pexpect "probe: summary counts failures" '^# module-abi-probe=modules:2 failed:2 skipped:0' "$out"
stubs "$T/s2" 0 'exit 0'
out=$(probe "$T/s2" "$T/rt")
pexpect "probe: clean loads pass" '^# module-abi-probe=modules:2 failed:0 skipped:0' "$out"
stubs "$T/s3" 0 '[ "$1" = panthor ] && { echo "modprobe: ERROR: could not insert '"'"'panthor'"'"': Operation not permitted" >&2; exit 1; }; exit 0'
out=$(probe "$T/s3" "$T/rt")
pexpect "probe: module_blacklist= is a skip, not a failure" '^# module-abi: panthor SKIP blacklisted.*' "$out"
pexpect "probe: blacklisted summary" '^# module-abi-probe=modules:2 failed:0 skipped:1' "$out"
stubs "$T/s5" 0 'echo "modprobe: ERROR: could not insert '"'"'$1'"'"': Invalid argument" >&2; exit 1'
out=$(probe "$T/s5" "$T/rt")
pexpect "probe: an init failure that is not a rejection is INFO, not FAIL" '^# module-abi: mali_kbase INFO accepted, init failed' "$out"
pexpect "probe: init failures do not count as failed" '^# module-abi-probe=modules:2 failed:0 skipped:0' "$out"
stubs "$T/s4" 1 'echo LOADED >> "'"$T"'/s4/loaded"; exit 0'
out=$(probe "$T/s4" "$T/rt")
pexpect "probe: real hardware is left alone" '^# module-abi-probe=skipped \(not a VM guest\)' "$out"
[ ! -e "$T/s4/loaded" ] && ok "probe: nothing was loaded outside a VM" || no "probe loaded a module outside a VM"

# --- 3. judging the probe report (what the KVM gate runs) -----------------
judge() {  # judge <name> <want-rc> <regex> <report lines...>
    local name=$1 want=$2 re=$3; shift 3
    printf '%s\n' "# first boot report" "$@" "# end" > "$T/fbr"
    expect "$name" "$want" "$re" --probe-report "$T/fbr"
}
judge "report: clean summary passes" 0 'PASS \(probe: modules:3 failed:0 skipped:1\)' \
    "# module-abi: mali_kbase OK (loaded)" "# module-abi: panthor SKIP blacklisted on this boot entry" "# module-abi-probe=modules:3 failed:0 skipped:1"
judge "report: a FAIL line fails" 1 'refused out-of-tree modules' \
    "# module-abi: mali_kbase FAIL rc=1 Exec format error" "# module-abi-probe=modules:3 failed:1 skipped:0"
judge "report: a kernel-log rejection alone fails" 1 'refused out-of-tree modules' \
    "# module-abi: mali_kbase INFO accepted, init failed" "# module-abi-reject: module mali_kbase: .gnu.linkonce.this_module section size must match" "# module-abi-probe=modules:1 failed:0 skipped:0"
judge "report: a skipped probe fails (the gate guest is a VM)" 1 'probe skipped' "# module-abi-probe=skipped (not a VM guest)"
judge "report: no summary fails" 1 'no probe summary' "# module-abi: mali_kbase OK (loaded)"
judge "report: failed>0 in the summary fails" 1 "probe summary 'modules:2 failed:1" "# module-abi-probe=modules:2 failed:1 skipped:0"

# --- 4. wiring ------------------------------------------------------------
grep -q 'verify-module-abi.py" "$root/usr/lib/modules/$kver"' "$ROOT/build/build-kernel-debs.sh" \
    && ok "kernel .deb packaging runs verify-module-abi.py" || no "build-kernel-debs.sh does not run verify-module-abi.py"
grep -q 'verify-module-abi.py" --allow-empty "$WORK/installed-modules/$DEFAULT_KVER"' "$ROOT/build/kvm-install-gate-gpt.sh" \
    && ok "KVM gate runs the static check on the installed root" || no "KVM gate does not run verify-module-abi.py"
grep -q 'verify-module-abi.py" --probe-report "$FBR"' "$ROOT/build/kvm-install-gate-gpt.sh" \
    && ok "KVM gate judges the probe report with --probe-report" || no "KVM gate does not judge the probe report"

echo "test-module-abi-gate: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
