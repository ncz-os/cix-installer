#!/bin/bash
# test-fwupd-i2c-mask.sh -- regression test for the fwupd-i2c.conf mask in
# post-install/25-cix-proprietary.sh: mask fwupd's i2c_dev modules-load request
# only while no installed kernel provides i2c-dev (the Sky1 kernel has no
# CONFIG_I2C_CHARDEV; systemd-modules-load failed on every boot).
#
# Extracts the marked block from the hook, points its absolute paths at a
# fixture root, and runs it under bash.
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
HOOK="$HERE/../post-install/25-cix-proprietary.sh"
W="$(mktemp -d -t fwupd-i2c.XXXXXX)"
trap 'rm -rf "$W"' EXIT
pass=0; fail=0

block() {   # $1 fixture root
    python3 - "$HOOK" "$1" <<'EOF'
import sys
s = open(sys.argv[1]).read()
a = s.index("# --- ncz:fwupd-i2c-mask begin ---")
b = s.index("# --- ncz:fwupd-i2c-mask end ---")
r = sys.argv[2]
blk = s[a:b]
for p in ("/usr/lib/modules-load.d", "/usr/lib/modules/", "/etc/modules-load.d"):
    blk = blk.replace(p, r + p)
print(blk)
EOF
}

fixture() {   # $1 root  $2 i2c-dev provider: none|module|builtin  $3 fwupd conf present (1/0)
    local r="$1" k="$1/usr/lib/modules/7.3.0-rc6-sky1-ncz"
    mkdir -p "$k" "$r/usr/lib/modules-load.d"
    : > "$k/modules.dep"; : > "$k/modules.builtin"
    case "$2" in
        module)  echo "kernel/drivers/i2c/i2c-dev.ko: " > "$k/modules.dep" ;;
        builtin) echo "kernel/drivers/i2c/i2c-dev.ko" > "$k/modules.builtin" ;;
    esac
    [ "$3" = 1 ] && echo i2c_dev > "$r/usr/lib/modules-load.d/fwupd-i2c.conf"
    return 0
}

check() {   # $1 name  $2 condition
    if eval "$2"; then pass=$((pass+1)); echo "PASS: $1"; else fail=$((fail+1)); echo "FAIL: $1"; fi
}

for c in none module builtin; do
    r="$W/$c"; fixture "$r" "$c" 1
    bash -c "$(block "$r")" >"$r/out.log" 2>&1
    if [ "$c" = none ]; then
        check "no i2c-dev in any kernel: request masked" "[ \"\$(readlink '$r/etc/modules-load.d/fwupd-i2c.conf')\" = /dev/null ]"
    else
        check "i2c-dev as $c: request left alone" "[ ! -e '$r/etc/modules-load.d/fwupd-i2c.conf' ] && [ ! -L '$r/etc/modules-load.d/fwupd-i2c.conf' ]"
    fi
done
r="$W/nofwupd"; fixture "$r" none 0
bash -c "$(block "$r")" >"$r/out.log" 2>&1
check "fwupd not installed: nothing written" "[ ! -e '$r/etc/modules-load.d/fwupd-i2c.conf' ] && [ ! -L '$r/etc/modules-load.d/fwupd-i2c.conf' ]"

echo "test-fwupd-i2c-mask: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
