#!/bin/bash
# test-amd64-boot-noise.sh -- post-install/lib/amd64-boot-noise.sh on fixture
# trees: the pcspkr/snd_pcsp blacklist is written on EVERY amd64 host whose
# kernel ships both drivers (not only T2 Macs), and the ucsi_ccg blacklist only
# on operator opt-in. No root, no hardware: /lib/modules, /etc, the installer
# meta dir and /sys/bus/pci/devices are all fixture directories.
#
# Evidence: PEGASUS (ASUS GU502LV, non-T2) 2026-11-02 boot log
#   "Error: Driver 'pcspkr' is already registered, aborting..."
#   "ucsi_ccg 5-0008: probe with driver ucsi_ccg failed with error -110"
set -uo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
LIB="$ROOT/post-install/lib/amd64-boot-noise.sh"
HOOK="$ROOT/post-install/55-t2-firmware.sh"
W="$(mktemp -d "${TMPDIR:-/tmp}/boot-noise-test.XXXXXX")"
trap 'rm -rf "$W"' EXIT
pass=0; fail=0
ok() { printf '  [PASS] %s\n' "$*"; pass=$((pass+1)); }
no() { printf '  [FAIL] %s\n' "$*" >&2; fail=$((fail+1)); }

[ -f "$LIB" ] || { echo "FATAL: missing $LIB" >&2; exit 1; }
bash -n "$LIB" && ok "lib parses" || no "lib syntax"
bash -n "$HOOK" && ok "55-t2-firmware.sh parses" || no "55 syntax"

# kmod <root> <kver> <relpath>  -- a fake module file in a kernel tree
kmod() { mkdir -p "$1/$2/kernel/$(dirname "$3")"; : > "$1/$2/kernel/$3"; }

# run_apply <case-dir> -> apply output; trees under <case-dir>/{mods,etc,meta,pci}
run_apply() {
    local c="$1"
    mkdir -p "$c/mods" "$c/etc" "$c/meta" "$c/pci"
    ( NCZ_MODULES_ROOT="$c/mods" NCZ_ETC_ROOT="$c/etc" \
      NCZ_INSTALLER_META="$c/meta" NCZ_PCI_DEVICES_ROOT="$c/pci"
      export NCZ_MODULES_ROOT NCZ_ETC_ROOT NCZ_INSTALLER_META NCZ_PCI_DEVICES_ROOT
      # shellcheck source=post-install/lib/amd64-boot-noise.sh
      . "$LIB"; ncz_amd64_boot_noise_apply )
}
conf() { printf '%s' "$1/etc/modprobe.d/$2"; }

echo "P1 both drivers as modules (Debian/NCZ amd64 kernel) -> ncz-pcspkr.conf"
C="$W/p1"
kmod "$C/mods" 7.3.0-ncz drivers/input/misc/pcspkr.ko.xz
kmod "$C/mods" 7.3.0-ncz sound/drivers/pcsp/snd-pcsp.ko.xz
out=$(run_apply "$C")
f=$(conf "$C" ncz-pcspkr.conf)
[ -f "$f" ] && ok "ncz-pcspkr.conf written" || no "ncz-pcspkr.conf not written ($out)"
grep -qx 'blacklist snd_pcsp' "$f" 2>/dev/null && ok "blacklists snd_pcsp" || no "no 'blacklist snd_pcsp'"
grep -qx 'install snd_pcsp /bin/true' "$f" 2>/dev/null && ok "install snd_pcsp /bin/true" || no "snd_pcsp install override missing"
grep -Eq '^(blacklist|install) pcspkr' "$f" 2>/dev/null && no "the input beeper pcspkr is blocked" || ok "the input beeper (pcspkr) stays loadable"
grep -q '7.3.0-ncz' <<<"$out" && ok "log names the kernel that ships both" || no "log: $out"

echo "P2 idempotent: a second run leaves the same bytes and mtime"
m1=$(stat -c %Y "$f"); h1=$(sha256sum < "$f")
sleep 1
out=$(run_apply "$C")
m2=$(stat -c %Y "$f"); h2=$(sha256sum < "$f")
[ "$h1" = "$h2" ] && [ "$m1" = "$m2" ] && ok "unchanged on re-run ($out)" || no "re-run rewrote the file"
[ -z "$(find "$C/etc/modprobe.d" -name '.*' 2>/dev/null)" ] && ok "no temp file left behind" || no "temp file left in modprobe.d"

echo "P3 only one driver -> no file"
C="$W/p3"
kmod "$C/mods" 7.3.0-ncz drivers/input/misc/pcspkr.ko
out=$(run_apply "$C")
[ ! -e "$(conf "$C" ncz-pcspkr.conf)" ] && ok "pcspkr only: nothing written" || no "pcspkr only: file written"
grep -q 'nothing to do' <<<"$out" && ok "logs why it did nothing" || no "log: $out"

echo "P4 pcspkr built in + snd-pcsp module, zstd, '_' spelling -> written"
C="$W/p4"
mkdir -p "$C/mods/7.4.0-t2"
echo 'kernel/drivers/input/misc/pcspkr.ko' > "$C/mods/7.4.0-t2/modules.builtin"
kmod "$C/mods" 7.4.0-t2 sound/drivers/pcsp/snd_pcsp.ko.zst
run_apply "$C" >/dev/null
[ -f "$(conf "$C" ncz-pcspkr.conf)" ] && ok "builtin + module: written" || no "builtin + module: not written"

echo "P5 two kernels, only the newer ships both -> written"
C="$W/p5"
kmod "$C/mods" 7.2.8-ncz drivers/input/misc/pcspkr.ko
kmod "$C/mods" 7.3.0-ncz drivers/input/misc/pcspkr.ko
kmod "$C/mods" 7.3.0-ncz sound/drivers/pcsp/snd-pcsp.ko
out=$(run_apply "$C")
[ -f "$(conf "$C" ncz-pcspkr.conf)" ] && ok "written for 7.3.0-ncz" || no "not written: $out"
grep -q '7.2.8' <<<"$out" && no "7.2.8 (one driver) reported as shipping both" || ok "7.2.8 not reported"

echo "U1 ucsi_ccg: NVIDIA UCSI present, no opt-in -> no blacklist, hint logged"
C="$W/u1"
mkpci() { mkdir -p "$1/$2"; echo "0x$3" > "$1/$2/class"; echo "0x$4" > "$1/$2/vendor"; echo "0x$5" > "$1/$2/device"; }
mkpci "$C/pci" 0000:01:00.0 030000 10de 1f15
mkpci "$C/pci" 0000:01:00.3 0c8000 10de 1adb
mkpci "$C/pci" 0000:00:1f.4 0c0500 8086 06a3
out=$(run_apply "$C")
[ ! -e "$(conf "$C" ncz-nvidia-ucsi-ccg.conf)" ] && ok "no opt-in: no ucsi_ccg blacklist" || no "ucsi_ccg blacklisted without opt-in"
grep -q '0000:01:00.3' <<<"$out" && grep -q 'opt-in only' <<<"$out" \
    && ok "logs the NVIDIA UCSI function and the opt-in" || no "no hint: $out"
grep -q '0000:00:1f.4' <<<"$out" && no "an Intel SMBus device was reported as NVIDIA UCSI" || ok "only the NVIDIA 0c80 function is reported"

echo "U2 ucsi_ccg opt-in -> ncz-nvidia-ucsi-ccg.conf"
echo yes > "$C/meta/UCSI_CCG_BLACKLIST"
out=$(run_apply "$C")
f=$(conf "$C" ncz-nvidia-ucsi-ccg.conf)
grep -qx 'blacklist ucsi_ccg' "$f" 2>/dev/null && ok "opt-in: blacklist ucsi_ccg written" || no "opt-in: not written ($out)"
grep -Eq '^blacklist (i2c_nvidia_gpu|nvidia)' "$f" 2>/dev/null && no "blocks i2c_nvidia_gpu (dGPU loses runtime PM)" || ok "i2c_nvidia_gpu stays bound"

echo "U3 opt-in file with another value -> not opted in"
C="$W/u3"; mkdir -p "$C/meta"; echo no > "$C/meta/UCSI_CCG_BLACKLIST"
run_apply "$C" >/dev/null
[ ! -e "$(conf "$C" ncz-nvidia-ucsi-ccg.conf)" ] && ok "'no' is not an opt-in" || no "'no' wrote the blacklist"

echo "H1 hook 55 applies it on every amd64 host, before its T2/variant gates"
ln_lib=$(grep -n 'ncz_amd64_boot_noise_apply' "$HOOK" | head -1 | cut -d: -f1)
ln_var=$(grep -n 'case "\$VARIANT" in' "$HOOK" | head -1 | cut -d: -f1)
ln_t2=$(grep -n '^if ! is_t2_hardware; then' "$HOOK" | head -1 | cut -d: -f1)
if [ -n "$ln_lib" ] && [ -n "$ln_var" ] && [ -n "$ln_t2" ] \
   && [ "$ln_lib" -lt "$ln_var" ] && [ "$ln_lib" -lt "$ln_t2" ]; then
    ok "55 calls ncz_amd64_boot_noise_apply (line $ln_lib) before the variant ($ln_var) and T2 ($ln_t2) exits"
else
    no "55 does not apply the generic fix before its early exits (lib=$ln_lib variant=$ln_var t2=$ln_t2)"
fi

echo "H2 the hook block runs and never fails the install"
C="$W/h2"
kmod "$C/mods" 7.3.0-ncz drivers/input/misc/pcspkr.ko
kmod "$C/mods" 7.3.0-ncz sound/drivers/pcsp/snd-pcsp.ko
mkdir -p "$C/etc" && chmod 0555 "$C/etc"
rc=0; run_apply "$C" >/dev/null 2>&1 || rc=$?
chmod 0755 "$C/etc"
[ "$rc" = 0 ] && ok "an unwritable /etc is reported, not fatal (rc=0)" || no "apply exited $rc on an unwritable /etc"

echo
echo "test-amd64-boot-noise: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
