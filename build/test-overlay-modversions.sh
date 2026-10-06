#!/usr/bin/env bash
# test-overlay-modversions.sh -- hermetic fixture test for
# build/verify-overlay-modversions.py (overlay .ko MODVERSIONS CRCs vs the
# pinned kernel's Module.symvers). Builds tiny synthetic ELF64 .ko files and a
# fake staging dir under a temp dir; needs only bash and python3.
#
# Cases: matching CRCs pass; one changed CRC (the r282-vs-r284 class) fails;
# an unknown symbol fails unless a sibling overlay exports it; a module with no
# __versions fails; a vermagic for another KVER fails; a missing overlay set
# fails; a manifest KVER that disagrees fails; a missing Module.symvers is an
# input error (2); the staging dir is found through the assets/kernel/mainline
# symlink.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$SCRIPT_DIR/verify-overlay-modversions.py"
T="$(mktemp -d "${TMPDIR:-/tmp}/test-overlay-modversions.XXXXXX")"
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
KVER=7.3.0-rc6-sky1-ncz

# mkko <out.ko> <vermagic|-> <versions "sym=0xcrc,..."|-> [exports "sym,..."]
mkko() {
    python3 - "$@" <<'PY'
import struct, sys
out, vm, vers = sys.argv[1], sys.argv[2], sys.argv[3]
exports = sys.argv[4].split(",") if len(sys.argv) > 4 and sys.argv[4] else []
secs = []  # (name, type, body, link, entsize)
if vm != "-":
    secs.append((".modinfo", 1, b"license=GPL\0vermagic=" + vm.encode() + b"\0", 0, 0))
if vers != "-":
    body = b""
    for item in filter(None, vers.split(",")):
        sym, crc = item.split("=")
        body += struct.pack("<Q", int(crc, 16)) + sym.encode().ljust(56, b"\0")
    secs.append(("__versions", 1, body, 0, 0))
strtab = b"\0"
symtab = b"\0" * 24
for e in exports:
    off = len(strtab); strtab += ("__ksymtab_" + e).encode() + b"\0"
    symtab += struct.pack("<IBBHQQ", off, 0x11, 0, 1, 0, 0)
secs.append((".symtab", 2, symtab, len(secs) + 2, 24))
secs.append((".strtab", 3, strtab, 0, 0))
shstr = b"\0"; names = []
for s in secs:
    names.append(len(shstr)); shstr += s[0].encode() + b"\0"
shname = len(shstr); shstr += b".shstrtab\0"
secs.append((".shstrtab", 3, shstr, 0, 0)); names.append(shname)
data = bytearray(64); offs = []
for s in secs:
    offs.append(len(data)); data += s[2]
    while len(data) % 8: data += b"\0"
shoff = len(data)
data += b"\0" * 64
for i, s in enumerate(secs):
    data += struct.pack("<IIQQQQIIQQ", names[i], s[1], 0, 0, offs[i], len(s[2]), s[3], 0, 8, s[4])
hdr = b"\x7fELF" + bytes([2, 1, 1, 0]) + b"\0" * 8
hdr += struct.pack("<HHIQQQIHHHHHH", 1, 183, 1, 0, 0, shoff, 0, 64, 0, 0, 64, len(secs) + 1, len(secs))
data[:64] = hdr
open(out, "wb").write(bytes(data))
PY
}

# fixture <root>: a passing tree (staging + symlink + 4 overlay dirs + manifest)
fixture() {
    local r=$1 st=$1/staging
    mkdir -p "$st/headers-dir/lib/modules/$KVER/build" "$r/repo/assets/kernel"
    printf '%s' "$KVER" > "$st/KVER"
    printf '0x11111111\tfoo\tvmlinux\tEXPORT_SYMBOL\t\n0x22222222\tbar\tvmlinux\tEXPORT_SYMBOL_GPL\t\n0x00000033\tmodule_layout\tvmlinux\tEXPORT_SYMBOL\t\n' \
        > "$st/headers-dir/lib/modules/$KVER/build/Module.symvers"
    ln -s "$st" "$r/repo/assets/kernel/mainline"
    printf '{"variants":{"mainline":{"kver":"%s"}}}\n' "$KVER" > "$r/repo/assets/kernel-manifest.json"
    local d
    for d in mali vpu npu panthor; do
        mkdir -p "$r/repo/assets/kernel/$d/$KVER"
        mkko "$r/repo/assets/kernel/$d/$KVER/$d.ko" "$KVER SMP preempt mod_unload modversions aarch64" \
            "module_layout=0x33,foo=0x11111111,bar=0x22222222"
    done
}

# expect <name> <want-rc> <want-regex> <root> [gate args...]
expect() {
    local name=$1 want=$2 re=$3 root=$4; shift 4
    local out rc
    out=$(python3 "$GATE" --root "$root" "$@" 2>&1); rc=$?
    if [ "$rc" = "$want" ] && printf '%s\n' "$out" | grep -qE "$re"; then
        echo "PASS: $name (rc=$rc)"; PASS=$((PASS + 1))
    else
        echo "FAIL: $name (rc=$rc want $want, /$re/)"; printf '%s\n' "$out" | sed 's/^/    /'; FAIL=$((FAIL + 1))
    fi
}

R=$T/ok; fixture "$R"
expect "matching CRCs pass (staging via mainline symlink)" 0 'verify-overlay-modversions: PASS' "$R/repo"

R=$T/crc; fixture "$R"
mkko "$R/repo/assets/kernel/vpu/$KVER/vpu.ko" "$KVER SMP preempt mod_unload modversions aarch64" \
    "module_layout=0x33,foo=0x11111111,bar=0xdeadbeef"
expect "one stale CRC fails (same KVER, other build)" 1 'CRC MISMATCH assets/kernel/vpu/.*/vpu.ko bar module=0xdeadbeef kernel=0x22222222' "$R/repo"

R=$T/unres; fixture "$R"
mkko "$R/repo/assets/kernel/mali/$KVER/mali.ko" "$KVER SMP preempt mod_unload modversions aarch64" \
    "module_layout=0x33,foo=0x11111111,mgm_get=0x44444444"
expect "unknown symbol fails" 1 'UNRESOLVED assets/kernel/mali/.*/mali.ko mgm_get' "$R/repo"
mkko "$R/repo/assets/kernel/mali/$KVER/mgm.ko" "$KVER SMP preempt mod_unload modversions aarch64" \
    "module_layout=0x33" "mgm_get"
expect "symbol exported by a sibling overlay passes" 0 'mali.ko: versions=3 crc_mismatch=0 sibling_overlay=1' "$R/repo"

R=$T/nover; fixture "$R"
mkko "$R/repo/assets/kernel/npu/$KVER/npu.ko" "$KVER SMP preempt mod_unload modversions aarch64" "-"
expect "module without __versions fails" 1 'npu.ko: no __versions entries' "$R/repo"

R=$T/vm; fixture "$R"
mkko "$R/repo/assets/kernel/panthor/$KVER/panthor.ko" "7.3.0-rc6-sky1-nczX SMP preempt mod_unload modversions aarch64" \
    "module_layout=0x33,foo=0x11111111"
expect "vermagic of another KVER fails" 1 'panthor.ko: vermagic .* does not start with' "$R/repo"

R=$T/noset; fixture "$R"; rm -rf "$R/repo/assets/kernel/npu/$KVER"
expect "missing overlay set fails" 1 "MISSING overlay set: assets/kernel/npu/$KVER" "$R/repo"

R=$T/man; fixture "$R"
printf '{"variants":{"mainline":{"kver":"7.3.0-rc5-sky1-ncz"}}}\n' > "$R/repo/assets/kernel-manifest.json"
expect "manifest KVER disagreeing with the staging KVER fails" 1 'variants.mainline.kver 7.3.0-rc5-sky1-ncz' "$R/repo"

R=$T/nosym; fixture "$R"; rm -f "$R/staging/headers-dir/lib/modules/$KVER/build/Module.symvers"
expect "missing Module.symvers is an input error" 2 'Module.symvers not found' "$R/repo"

R=$T/dang; fixture "$R"; rm -rf "$R/staging"
expect "dangling mainline symlink is an input error" 2 'staging dir not found' "$R/repo"

R=$T/expl; fixture "$R"; rm -f "$R/repo/assets/kernel/mainline"
expect "--staging and --symvers override the symlink" 0 'PASS' "$R/repo" \
    --staging "$R/staging" --symvers "$R/staging/headers-dir/lib/modules/$KVER/build/Module.symvers"

echo "test-overlay-modversions: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
