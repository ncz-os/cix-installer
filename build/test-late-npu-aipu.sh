#!/bin/bash
# test-late-npu-aipu.sh -- regression test for preseed/late.sh ncz_npu_install_time():
# the Sky1 NPU driver is the vendor aipu.ko, and /etc/modules-load.d/ncz-npu.conf
# (written by post-install/80-npu.sh with "aipu") must not be overwritten with the
# in-tree name armchina_npu, which the Sky1 kernels do not build.
#
# Extracts the function from late.sh, points its /target at a fixture root, stubs
# in-target, and runs it under sh. A control run of the pre-fix function (from
# git, when available) must clobber the conf, so the test proves it can detect
# the defect.
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
LATE="$HERE/../preseed/late.sh"
SH="${TEST_SH:-sh}"
KV=7.3.0-rc6-sky1-ncz
W="$(mktemp -d -t late-npu.XXXXXX)"
trap 'rm -rf "$W"' EXIT
pass=0; fail=0

extract() {   # $1 late.sh path, $2 fixture root -> function text on stdout
    python3 - "$1" "$2" <<'EOF'
import sys
s = open(sys.argv[1]).read()
a = s.index("ncz_npu_install_time() {")
b = s.index("\n}\n", a) + 3
print(s[a:b].replace("/target", sys.argv[2]))
EOF
}

fixture() {   # $1 root  $2 conf content ('' = absent)  $3 dkms aipu (1/0)  $4 overlay in SRC (1/0)
    local r="$1"
    mkdir -p "$r/etc/cix-installer" "$r/usr/lib/modules/$KV" "$r/src/assets/kernel/npu/$KV"
    echo "$KV" > "$r/etc/cix-installer/KVER_NEXT"
    if [ -n "$2" ]; then mkdir -p "$r/etc/modules-load.d"; printf '%s\n' "$2" > "$r/etc/modules-load.d/ncz-npu.conf"; fi
    if [ "$3" = 1 ]; then mkdir -p "$r/usr/lib/modules/$KV/updates/dkms"; echo dkms > "$r/usr/lib/modules/$KV/updates/dkms/aipu.ko"; fi
    if [ "$4" = 1 ]; then echo overlay > "$r/src/assets/kernel/npu/$KV/aipu.ko"; fi
}

run() {   # $1 late.sh  $2 root
    local fn; fn="$(extract "$1" "$2")"
    # in-target is an external d-i command, so stub it as an executable on PATH:
    # dash (/bin/sh on Debian/Ubuntu) rejects a hyphenated function name, which
    # made every case that reached the stub fail on dash hosts.
    mkdir -p "$2/stubbin"
    printf '#!/bin/sh\nexit 0\n' > "$2/stubbin/in-target"; chmod +x "$2/stubbin/in-target"
    PATH="$2/stubbin:$PATH" SRC="$2/src" "$SH" -c "$fn
ncz_npu_install_time" > "$2/out.log" 2>&1
}

check() {   # $1 name  $2 condition (evaluated)
    if eval "$2"; then pass=$((pass+1)); echo "PASS: $1"; else fail=$((fail+1)); echo "FAIL: $1"; fi
}

# A: 80-npu already wrote "aipu" and DKMS built aipu.ko -> conf kept, nothing copied.
r="$W/a"; fixture "$r" "aipu" 1 1; run "$LATE" "$r"
check "A conf keeps aipu" "grep -qx aipu '$r/etc/modules-load.d/ncz-npu.conf'"
check "A conf has no armchina_npu" "! grep -q armchina_npu '$r/etc/modules-load.d/ncz-npu.conf'"
check "A no overlay copied over DKMS build" "[ ! -e '$r/usr/lib/modules/$KV/updates/aipu.ko' ]"

# B: no conf, no DKMS build, r284 overlay staged -> overlay installed, conf lists aipu.
r="$W/b"; fixture "$r" "" 0 1; run "$LATE" "$r"
check "B overlay aipu.ko installed to updates/" "[ \"\$(cat '$r/usr/lib/modules/$KV/updates/aipu.ko' 2>/dev/null)\" = overlay ]"
check "B conf written with aipu" "grep -qx aipu '$r/etc/modules-load.d/ncz-npu.conf'"

# C: nothing staged at all -> reported, no crash, conf written with aipu.
r="$W/c"; fixture "$r" "" 0 0; run "$LATE" "$r"
check "C missing overlay reported" "grep -q 'no aipu.ko or armchina_npu.ko overlay' '$r/out.log'"

# Control: the pre-fix function clobbers 80-npu's conf with armchina_npu.
if [ -z "${NO_CONTROL:-}" ] && git -C "$HERE/.." cat-file -e b80606fb:preseed/late.sh 2>/dev/null; then
    git -C "$HERE/.." show b80606fb:preseed/late.sh > "$W/late-prefix.sh"
    r="$W/ctl"; fixture "$r" "aipu" 1 1; run "$W/late-prefix.sh" "$r"
    check "control: pre-fix late.sh overwrites conf with armchina_npu" "grep -qx armchina_npu '$r/etc/modules-load.d/ncz-npu.conf'"
fi

echo "test-late-npu-aipu: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
