#!/bin/bash
# test-stage-kernel-skip-packaging.sh: stage-kernel.sh with NCZ_SKIP_PACKAGING=1
# (how release-kernel.sh calls it) must succeed in a tree that has never
# packaged a kernel, i.e. with no build/kernel-debs/ yet, and must still fail
# when a gate fails.
#
# Why (2026-11-07, r298): in a fresh clone every gate passed, then the final
# `ls -la build/kernel-debs/ | tail -4` failed under pipefail and
# release-kernel.sh stopped with "staging or gates failed". Long-lived build
# trees always had a build/kernel-debs/ from an earlier run, so it never showed.
#
# Runs the real build/stage-kernel.sh against a scratch repo whose gate and
# header-extraction scripts are stubs, and a fake kernel work dir.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
command -v zstd >/dev/null || { echo "SKIP: zstd not installed"; exit 0; }
T="$(mktemp -d "${TMPDIR:-/tmp}/test-stage-kernel.XXXXXX")"
trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { echo "PASS  $1"; pass=$((pass+1)); }
bad() { echo "FAIL  $1"; fail=$((fail+1)); }

KVER=7.3.3-sky1-ncz
mkrepo() {   # mkrepo <dir> <gate-rc>
    local r="$1"
    mkdir -p "$r/build" "$r/assets/kernel"
    cp "$HERE/stage-kernel.sh" "$r/build/"
    cat > "$r/build/extract-kernel-headers.sh" <<'STUB'
#!/bin/bash
while [ $# -gt 0 ]; do case "$1" in --kver) k="$2"; shift 2 ;; --output) o="$2"; shift 2 ;; *) shift ;; esac; done
d="$(mktemp -d)"; mkdir -p "$d/lib/modules/$k/build"; echo stub > "$d/lib/modules/$k/build/Makefile"
tar -C "$d" -cf - lib | zstd -q -o "$o"; rm -rf "$d"
STUB
    printf '#!/bin/bash\nexit %s\n' "$2" > "$r/build/kvm-kernel-gate.sh"
    printf '#!/bin/bash\nexit 0\n' > "$r/build/dkms-abi-gate.sh"
    chmod +x "$r/build/"*.sh
}
W="$T/work/linux-cix-sky1-ncz/7.3.3+ncz"
mkdir -p "$W/image/usr/lib/modules/$KVER/kernel" "$W/build/arch/arm64/boot" "$W/kernel-source"
echo ko > "$W/image/usr/lib/modules/$KVER/kernel/a.ko"
head -c 4096 /dev/urandom > "$W/build/arch/arm64/boot/Image"
echo CONFIG_MODVERSIONS=y > "$W/build/.config"

run() {   # run <repo>
    NCZ_INSTALLER_DIR="$1" NCZ_KERNEL_WORKDIR="$W" BUILD_REV=r999 \
        NCZ_SKIP_PACKAGING=1 NCZ_KERNEL_STAGING_ROOT='' TMPDIR="$T" \
        bash "$1/build/stage-kernel.sh" > "$1.log" 2>&1
}

R="$T/fresh"; mkrepo "$R" 0
run "$R"; rc=$?
[ "$rc" -eq 0 ] && ok "fresh tree, no build/kernel-debs: stage-kernel exits 0" \
    || { bad "fresh tree, no build/kernel-debs: stage-kernel exited $rc"; tail -5 "$R.log"; }
d=$(ls -d "$R"/assets/kernel/r999-$KVER-* 2>/dev/null | head -1)
[ -n "$d" ] && [ -s "$d/Image-cixmini.bin" ] && [ -s "$d/modules-cixmini.tgz" ] \
    && ok "release dir staged (Image, modules)" || bad "release dir not staged"
[ ! -e "$R/build/kernel-debs" ] && ok "skip-packaging leaves build/kernel-debs alone" \
    || bad "skip-packaging created build/kernel-debs"

R="$T/gatefail"; mkrepo "$R" 1
run "$R"; rc=$?
[ "$rc" -ne 0 ] && ok "a failing gate still fails stage-kernel (rc=$rc)" \
    || bad "a failing gate was ignored"

echo "=== $pass passed, $fail failed"
[ "$fail" -eq 0 ]
