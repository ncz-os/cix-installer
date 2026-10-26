#!/usr/bin/env bash
# test-mali-overlay-abi-guard.sh -- post-install/82-mali-gpu.sh must not
# install a Mali overlay the kernel will refuse, and must let a DKMS build
# that dkms declined to install take over.
#
# O6N 2026-10-26 (r292): the overlays had this_module 0x4c0 against the
# kernel's 0x500 (vermagic matched), were installed to updates/, and were
# refused at load ("section size must match"). DKMS had built correct
# modules, but dkms would not install them over the overlay copies because
# both carry the same MODULE_VERSION ("already installed at version
# r53p0-00eac0, override by specifying --force"), so dkms status stayed
# "built" and the overlay stayed the loaded driver.
#
# Needs readelf (binutils); exits 77 (skip) without it.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/../post-install/82-mali-gpu.sh"
command -v readelf >/dev/null 2>&1 || { echo "test-mali-overlay-abi-guard: SKIP (no readelf)"; exit 77; }
T="$(mktemp -d "${TMPDIR:-/tmp}/test-mali-abi.XXXXXX")"
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS: $1"; PASS=$((PASS + 1)); }
no() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
K=7.3.0-sky1-ncz

mkko() {  # mkko <out> <this_module size hex>
    python3 - "$1" "$2" <<'PY'
import struct, sys
out, tm = sys.argv[1], int(sys.argv[2], 16)
secs = [(".gnu.linkonce.this_module", 1, b"\0" * tm), (".modinfo", 1, b"vermagic=7.3.0-sky1-ncz SMP preempt mod_unload modversions aarch64\0")]
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
    data += struct.pack("<IIQQQQIIQQ", names[i], s[1], 2 if i == 0 else 0, 0, offs[i], len(s[2]), 0, 0, 8, 0)
hdr = b"\x7fELF" + bytes([2, 1, 1, 0]) + b"\0" * 8
hdr += struct.pack("<HHIQQQIHHHHHH", 1, 183, 1, 0, 0, shoff, 0, 64, 0, 0, 64, len(secs) + 1, len(secs))
data[:64] = hdr
open(out, "wb").write(bytes(data))
PY
}

# the overlay stage, from this_module_size() to the DKMS registration step
sed -n '/^this_module_size() {/,/^# --- 2\. register cix-gpu-kmd/p' "$HOOK" | sed '$d' > "$T/overlay.sh"
grep -q 'REFUSE $m: this_module size' "$T/overlay.sh" && ok "overlay stage extracted with the struct module guard" || no "no struct module guard in 82-mali-gpu.sh"
mkdir -p "$T/bin"
printf '#!/bin/sh\necho "%s SMP preempt mod_unload modversions aarch64"\n' "$K" > "$T/bin/modinfo"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/depmod"
chmod +x "$T/bin/"*

stage() {  # stage <case dir> <overlay size> -> runs the overlay stage
    local d=$1
    mkdir -p "$d/k/kernel/drivers/gpu" "$d/a/$K"
    mkko "$d/k/kernel/drivers/gpu/linlon-dp.ko" 0x500
    for m in mali_kbase memory_group_manager protected_memory_allocator; do mkko "$d/a/$K/$m.ko" "$2"; done
    PATH="$T/bin:$PATH" KDIR="$d/k" ASSET_DIR="$d/a" KVER_NEXT="$K" bash -c \
        'MODS=(mali_kbase memory_group_manager protected_memory_allocator); . "$0"' "$T/overlay.sh" > "$d/out" 2>&1
}
stage "$T/bad" 0x4c0
[ -z "$(ls "$T/bad/k/updates" 2>/dev/null)" ] && ok "0x4c0 overlays (kernel 0x500) are not installed" || no "a refused-size overlay was installed: $(ls "$T/bad/k/updates")"
[ "$(grep -c "REFUSE .*this_module size '0004c0' != kernel '000500'" "$T/bad/out")" = 3 ] && ok "each refusal is reported with both sizes" || { no "refusal lines missing"; sed 's/^/    /' "$T/bad/out"; }
stage "$T/good" 0x500
[ "$(ls "$T/good/k/updates" | wc -l)" = 3 ] && ok "0x500 overlays are installed" || { no "matching overlays not installed"; sed 's/^/    /' "$T/good/out"; }

# the force-install step
sed -n '/^# --- DKMS WINS: install a DKMS build that dkms refused/,/^# --- DKMS WINS: retire the overlay/p' "$HOOK" | sed '$d' > "$T/force.sh"
grep -q -- '--force' "$T/force.sh" && ok "force-install step extracted" || no "no force-install step in 82-mali-gpu.sh"
dkms_stub() {  # dkms_stub <status line>
    printf '#!/bin/sh\ncase "$1" in status) echo "%s" ;; install) echo "$*" >> "%s/dkms.log" ;; esac\nexit 0\n' "$1" "$T" > "$T/bin/dkms"
    chmod +x "$T/bin/dkms"; rm -f "$T/dkms.log"
}
dkms_stub "cix-gpu-kmd/1.0, $K, aarch64: built"
PATH="$T/bin:$PATH" KVER_NEXT=$K DKMS_VER=1.0 REF_TM= bash "$T/force.sh" > "$T/force.out" 2>&1
grep -q -- "install -m cix-gpu-kmd -v 1.0 -k $K --force" "$T/dkms.log" 2>/dev/null && ok "status 'built' -> dkms install --force" || { no "built module not force-installed"; cat "$T/force.out"; }
# a DKMS build with the wrong struct module is not forced in (the dkms tree is
# read from its absolute path, so this case uses a rewritten copy of the step)
mkdir -p "$T/dk/cix-gpu-kmd/1.0/$K/aarch64/module"; mkko "$T/dk/cix-gpu-kmd/1.0/$K/aarch64/module/mali_kbase.ko" 0x4c0
sed "s|/var/lib/dkms/|$T/dk/|" "$T/force.sh" > "$T/force-dk.sh"
dkms_stub "cix-gpu-kmd/1.0, $K, aarch64: built"
PATH="$T/bin:$PATH" KVER_NEXT=$K DKMS_VER=1.0 bash -c 'this_module_size() { readelf -S -W "$1" | sed -n "s/.*\.gnu\.linkonce\.this_module[[:space:]]*PROGBITS[[:space:]]*[0-9a-f]*[[:space:]]*[0-9a-f]*[[:space:]]*\([0-9a-f]*\).*/\1/p"; }; REF_TM=000500; . "$0"' "$T/force-dk.sh" > "$T/force.out" 2>&1
[ ! -s "$T/dkms.log" ] && grep -q "dkms-built mali_kbase has this_module '0004c0'" "$T/force.out" && ok "a DKMS build with the wrong struct module is not force-installed" || { no "wrong-ABI DKMS build was forced"; cat "$T/force.out"; }
mkko "$T/dk/cix-gpu-kmd/1.0/$K/aarch64/module/mali_kbase.ko" 0x500; rm -f "$T/dkms.log"
PATH="$T/bin:$PATH" KVER_NEXT=$K DKMS_VER=1.0 bash -c 'this_module_size() { readelf -S -W "$1" | sed -n "s/.*\.gnu\.linkonce\.this_module[[:space:]]*PROGBITS[[:space:]]*[0-9a-f]*[[:space:]]*[0-9a-f]*[[:space:]]*\([0-9a-f]*\).*/\1/p"; }; REF_TM=000500; . "$0"' "$T/force-dk.sh" > "$T/force.out" 2>&1
grep -q -- "--force" "$T/dkms.log" 2>/dev/null && ok "a DKMS build with the kernel's struct module is force-installed" || { no "matching DKMS build not forced"; cat "$T/force.out"; }
dkms_stub "cix-gpu-kmd/1.0, $K, aarch64: installed"
PATH="$T/bin:$PATH" KVER_NEXT=$K DKMS_VER=1.0 bash "$T/force.sh" > "$T/force.out" 2>&1
[ ! -s "$T/dkms.log" ] && ok "status 'installed' -> no reinstall" || no "installed module was reinstalled"

echo "test-mali-overlay-abi-guard: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
