#!/bin/bash
# test-stage-accel-overlays-pahole.sh: the overlay build container must find
# the kernel's own pahole.
#
# Why (2026-11-07, r298): with CONFIG_DEBUG_INFO_BTF_MODULES=y every module link
# runs pahole (scripts/gen-btf.sh). stage-accel-overlays.sh put only the OE
# cross toolchain dir on PATH and the ncz-yocto-y6 image has no pahole, so the
# mali build died with "pahole: not found". The kernel recipe builds
# pahole-native into <kernel-work-dir>/recipe-sysroot-native/usr/bin; that is
# the pahole the kernel's own modules were linked with, so overlays use it.
#
# Checks, with a stub podman that records its arguments:
#   1. the container PATH carries the native sysroot bin dir, after /usr/bin
#   2. BTF_MODULES=y and no pahole in the native sysroot: refused before podman
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/test-accel-pahole.XXXXXX")"
trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { echo "PASS  $1"; pass=$((pass+1)); }
bad() { echo "FAIL  $1"; fail=$((fail+1)); }

KVER=7.3.3-sky1-ncz
YB="$T/yb"; K="$YB/tmp/work/cixmini-nclawzero-linux/linux-cix-sky1-ncz/7.3.3+ncz"
mkdir -p "$K/build/include/config" "$K/recipe-sysroot-native/usr/bin/aarch64-nclawzero-linux" "$T/bin"
echo "$KVER" > "$K/build/include/config/kernel.release"
: > "$K/build/Module.symvers"
echo CONFIG_DEBUG_INFO_BTF_MODULES=y > "$K/build/.config"
printf '#!/bin/sh\n' > "$K/recipe-sysroot-native/usr/bin/aarch64-nclawzero-linux/aarch64-nclawzero-linux-gcc"
chmod +x "$K/recipe-sysroot-native/usr/bin/aarch64-nclawzero-linux/aarch64-nclawzero-linux-gcc"
# stub podman: record argv, fail so the script stops right after the call
cat > "$T/bin/podman" <<STUB
#!/bin/bash
printf '%s\n' "\$@" > "$T/podman.args"
exit 1
STUB
chmod +x "$T/bin/podman"

# a scratch copy: the script derives its repo root from its own path and
# clears <root>/build/accel-overlays/<kver>, which must not be this tree's
mkdir -p "$T/repo/build"; cp "$HERE/stage-accel-overlays.sh" "$T/repo/build/"
run() { PATH="$T/bin:$PATH" NCZ_YBUILD_DIR="$YB" bash "$T/repo/build/stage-accel-overlays.sh" "$K" "$KVER" > "$T/run.log" 2>&1; }

# 2. no pahole in the native sysroot
rm -f "$T/podman.args"; run
if [ ! -e "$T/podman.args" ] && grep -q pahole "$T/run.log"; then
    ok "BTF_MODULES=y without native pahole is refused before the container runs"
else
    bad "missing native pahole was not refused up front"; tail -3 "$T/run.log"
fi

# 1. with pahole: the container PATH has the native bin dir after /usr/bin
printf '#!/bin/sh\n' > "$K/recipe-sysroot-native/usr/bin/pahole"; chmod +x "$K/recipe-sysroot-native/usr/bin/pahole"
rm -f "$T/podman.args"; run
CN="/ybuild/tmp/work/cixmini-nclawzero-linux/linux-cix-sky1-ncz/7.3.3+ncz/recipe-sysroot-native/usr/bin"
if [ -e "$T/podman.args" ] && grep -q "PATH=[^ ]*:/usr/bin:/bin:${CN}[: ]" "$T/podman.args"; then
    ok "container PATH ends with the kernel's native sysroot bin dir"
else
    bad "container PATH lacks $CN after /usr/bin:/bin"; grep -o "PATH=[^ ]*" "$T/podman.args" 2>/dev/null
fi

echo "=== $pass passed, $fail failed"
[ "$fail" -eq 0 ]
