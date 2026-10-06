#!/bin/bash
# test-dkms-btf-toolchain.sh -- a base manifest that ships dkms must also ship
# dwarves (pahole) while the pinned kernels are built with
# CONFIG_DEBUG_INFO_BTF_MODULES=y.
#
# The kernels are built by a different compiler than the target gcc, so
# modules_prepare re-runs Kconfig on the installed header tree. Without pahole
# that silently drops DEBUG_INFO_BTF_MODULES, struct module shrinks, and every
# DKMS-built module is refused at load ("Exec format error"; 2026-10-06 Sky1
# r284: aipu this_module 0x4c0 vs the kernel's 0x500).
#
# Usage: build/test-dkms-btf-toolchain.sh [REPO_ROOT]   (fixture cases run first)
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="${1:-$HERE/..}"
pass=0; fail=0

pkgs() { sed 's/#.*//' "$1" | awk 'NF {print $1}'; }

check_manifest() {   # $1 manifest -> 0 ok, 1 dkms without dwarves
    pkgs "$1" | grep -qx dkms || return 0
    pkgs "$1" | grep -qx dwarves
}

expect() {   # $1 name  $2 wanted rc  $3 manifest
    local rc=0
    check_manifest "$3" || rc=1
    if [ "$rc" = "$2" ]; then
        pass=$((pass+1)); echo "PASS: $1"
    else
        fail=$((fail+1)); echo "FAIL: $1 (rc=$rc, want $2)"
    fi
}

W="$(mktemp -d -t dkms-btf.XXXXXX)"
trap 'rm -rf "$W"' EXIT
printf 'dkms\ngcc\n' > "$W/bad.pkgs"
printf 'dkms\ngcc\ndwarves   # pahole\n' > "$W/good.pkgs"
printf 'gcc\n# dwarves\n' > "$W/nodkms.pkgs"
printf 'dkms\n# dwarves\n' > "$W/commented.pkgs"
expect "fixture: dkms without dwarves is refused" 1 "$W/bad.pkgs"
expect "fixture: dkms with dwarves is accepted" 0 "$W/good.pkgs"
expect "fixture: no dkms needs no dwarves" 0 "$W/nodkms.pkgs"
expect "fixture: a commented-out dwarves does not count" 1 "$W/commented.pkgs"

for m in "$ROOT/manifests/installer-base.pkgs" "$ROOT/manifests/installer-base-amd64.pkgs"; do
    [ -f "$m" ] || continue
    expect "repo: $(basename "$m")" 0 "$m"
done

echo "test-dkms-btf-toolchain: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
