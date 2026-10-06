#!/bin/bash
# test-t2-dkms-hook.sh -- post-install/56-t2-dkms.sh builds t2smc/t2gmux/t2smp only; t2thunderbolt
# is opt-in (NCZ_T2_DKMS_EXTRA=t2thunderbolt), blacklisted otherwise, and a stale registration is removed.
# Runs the real hook against a sandbox with a fake dkms that records its calls.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="${NCZ_HOOK_UNDER_TEST:-$ROOT/post-install/56-t2-dkms.sh}"
# NCZ_T2_DETECT_REAL lets the test point at a stale-copy of the helper; the
# default is the worktree's assets/refind/ncz-t2-detect.sh.
T2_DETECT="${NCZ_T2_DETECT_REAL:-$ROOT/assets/refind/ncz-t2-detect.sh}"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

# mkbox $box $vendor $product
# Creates a sandbox with assets for t2smc, t2gmux, t2smp, t2thunderbolt;
# a DMI fixture (sys_vendor + product_name); an empty NCZ_KVER_LIST file
# (callers use set_kver_list to populate it); and a fake dkms binary that
# records every call.
mkbox() {
    local b="$1" vendor="$2" product="$3"
    rm -rf "$b"; mkdir -p "$b/assets" "$b/dmi" "$b/usrsrc" "$b/modprobe.d" "$b/libmodules" "$b/bin" "$b/meta"
    printf '%s\n' "$vendor" > "$b/dmi/sys_vendor"
    printf '%s\n' "$product" > "$b/dmi/product_name"
    for m in t2smc t2gmux t2smp t2thunderbolt; do
        mkdir -p "$b/assets/$m/src"
        printf 'PACKAGE_NAME="%s"\nPACKAGE_VERSION="0.1"\n' "$m" > "$b/assets/$m/dkms.conf"
        echo "/* $m */" > "$b/assets/$m/src/$m.c"
    done
    : > "$b/dkms.calls"; : > "$b/dkms.status"
    cat > "$b/bin/dkms" <<SH
#!/bin/sh
echo "\$*" >> "$b/dkms.calls"
case "\$1" in
    status) cat "$b/dkms.status" ;;
    remove) m=""; while [ \$\# -gt 0 ]; do [ "\$1" = -m ] && m="\$2"; shift; done; grep -v "^\$m" "$b/dkms.status" > "$b/dkms.status.n"; mv "$b/dkms.status.n" "$b/dkms.status" ;;
esac
exit 0
SH
    chmod +x "$b/bin/dkms"
}

# set_kver_list $box $kver1 $kver2 ...
# Populate the KVER_LIST_AMD64 sidecar and create matching libmodules/<kver> dirs.
set_kver_list() {
    local b="$1"; shift
    : >"$b/meta/KVER_LIST_AMD64"
    for k in "$@"; do
        mkdir -p "$b/libmodules/$k"
        echo "$k" >> "$b/meta/KVER_LIST_AMD64"
    done
}

# Run the hook with the sandbox as the source of truth. Extra env via $@.
# NOTE: callers that set NCZ_T2_DKMS_EXTRA on the run_hook call must also
# pass it explicitly in the args ("$@") -- env -i clears the function-level
# env, so the right-hand side of the VAR=value run_hook \$B assignment is
# not visible to env. Mirroring NCZ_T2_DKMS_EXTRA here covers the
# 'NCZ_T2_DKMS_EXTRA=t2evil' call pattern below.
run_hook() {
    local b="$1"; shift
    env -i \
        PATH="$b/bin:$PATH" \
        NCZ_TARGET_ARCH=amd64 \
        NCZ_ASSETS_KERNEL="$b/assets" \
        NCZ_DMI_ROOT="$b/dmi" \
        NCZ_USRSRC="$b/usrsrc" \
        NCZ_MODPROBE_D="$b/modprobe.d" \
        NCZ_LIB_MODULES="$b/libmodules" \
        NCZ_KVER_LIST="$b/meta/KVER_LIST_AMD64" \
        NCZ_INSTALLER_META="$b/meta" \
        NCZ_T2_DETECT="$T2_DETECT" \
        NCZ_T2_DKMS_EXTRA="${NCZ_T2_DKMS_EXTRA:-}" \
        "$@" \
        bash "$HOOK" >"$b/out" 2>&1
}

built() { grep -c -E "^build -m $2 " "$1/dkms.calls"; }

# 1. default on T2 hardware: t2smc + t2gmux + t2smp each built once, t2thunderbolt NOT built, blacklist file written.
B="$T/a"; mkbox "$B" "Apple Inc." "MacBookPro16,1"; set_kver_list "$B" "7.2.9-test"
run_hook "$B"
for m in t2smc t2gmux t2smp; do
    [ "$(built "$B" $m)" = 1 ] && ok "default: $m built" || bad "default: $m not built exactly once"
done
[ "$(built "$B" t2thunderbolt)" = 0 ] && ok "default: t2thunderbolt NOT built" || bad "default: t2thunderbolt was built"
[ ! -d "$B/usrsrc/t2thunderbolt-0.1" ] && ok "default: no t2thunderbolt source tree installed" || bad "default: t2thunderbolt source installed"
if grep -qx 'blacklist t2thunderbolt' "$B/modprobe.d/ncz-t2thunderbolt.conf" 2>/dev/null && grep -qx 'install t2thunderbolt /bin/false' "$B/modprobe.d/ncz-t2thunderbolt.conf"; then ok "default: modprobe.d blacklist + install-false written"; else bad "default: blacklist file missing/incomplete"; fi

# 2. idempotent: second run leaves the same file and no extra t2thunderbolt work
cp "$B/modprobe.d/ncz-t2thunderbolt.conf" "$T/conf.1"; run_hook "$B"
cmp -s "$T/conf.1" "$B/modprobe.d/ncz-t2thunderbolt.conf" && ok "idempotent: blacklist file unchanged on re-run" || bad "idempotent: file changed"
[ "$(built "$B" t2thunderbolt)" = 0 ] && ok "idempotent: still no t2thunderbolt build" || bad "idempotent: t2thunderbolt built on re-run"

# 3. stale registration from an earlier install is removed
B="$T/b"; mkbox "$B" "Apple Inc." "MacBookPro16,1"; set_kver_list "$B" "7.2.9-test"; echo "t2thunderbolt/0.1, 7.2.9-test: installed" > "$B/dkms.status"; mkdir -p "$B/usrsrc/t2thunderbolt-0.1"; run_hook "$B"
grep -q -E "^remove -m t2thunderbolt " "$B/dkms.calls" && ok "stale: dkms remove t2thunderbolt called" || bad "stale: dkms remove not called"
[ ! -d "$B/usrsrc/t2thunderbolt-0.1" ] && ok "stale: old source tree removed" || bad "stale: old source tree left"

# 4. explicit opt-in
B="$T/c"; mkbox "$B" "Apple Inc." "MacBookPro16,1"; set_kver_list "$B" "7.2.9-test"; NCZ_T2_DKMS_EXTRA=t2thunderbolt run_hook "$B"
[ "$(built "$B" t2thunderbolt)" = 1 ] && ok "opt-in: t2thunderbolt built" || bad "opt-in: t2thunderbolt not built"
[ ! -e "$B/modprobe.d/ncz-t2thunderbolt.conf" ] && ok "opt-in: no blacklist file" || bad "opt-in: blacklist file present"

# 5. unknown extra names are ignored with a warning
B="$T/d"; mkbox "$B" "Apple Inc." "MacBookPro16,1"; set_kver_list "$B" "7.2.9-test"; NCZ_T2_DKMS_EXTRA="t2evil" run_hook "$B"
if grep -q "not a known optional module" "$B/out" && [ "$(built "$B" t2evil)" = 0 ]; then ok "unknown extra module ignored with a warning"; else bad "unknown extra module not handled"; fi

# 6. non-Apple hardware: nothing built, nothing written
B="$T/e"; mkbox "$B" "ASUSTeK COMPUTER INC." "ROG STRIX X670E-A GAMING WIFI"; set_kver_list "$B" "6.6.0-debian"
run_hook "$B"
if [ ! -s "$B/dkms.calls" ] && [ ! -e "$B/modprobe.d/ncz-t2thunderbolt.conf" ]; then ok "non-Apple: hook is inert (no dkms calls, no modprobe.d file)"; else bad "non-Apple: hook acted"; fi

echo "t2-dkms-hook tests: $pass passed, $fail failed"
[ "$fail" = 0 ]