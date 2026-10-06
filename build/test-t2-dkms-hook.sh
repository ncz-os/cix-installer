#!/bin/bash
# test-t2-dkms-hook.sh -- post-install/56-t2-dkms.sh builds t2smc/t2gmux/t2smp only; t2thunderbolt
# is opt-in (NCZ_T2_DKMS_EXTRA=t2thunderbolt), blacklisted otherwise, and a stale registration is removed.
# Runs the real hook against a sandbox with a fake dkms that records its calls.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="${NCZ_HOOK_UNDER_TEST:-$ROOT/post-install/56-t2-dkms.sh}"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

mkbox() { # $1 = dir, $2 = vendor
    local b="$1"; rm -rf "$b"; mkdir -p "$b/assets" "$b/dmi" "$b/usrsrc" "$b/modprobe.d" "$b/libmodules/7.2.9-test" "$b/bin"
    printf '%s\n' "$2" > "$b/dmi/sys_vendor"
    for m in t2smc t2gmux t2smp t2thunderbolt; do
        mkdir -p "$b/assets/$m/src"
        printf 'PACKAGE_NAME="%s"\nPACKAGE_VERSION="0.1"\n' "$m" > "$b/assets/$m/dkms.conf"
        echo "/* $m */" > "$b/assets/$m/src/$m.c"
    done
    : > "$b/dkms.calls"; : > "$b/dkms.status"
    cat > "$b/bin/dkms" <<SH
#!/bin/bash
echo "\$*" >> "$b/dkms.calls"
case "\$1" in
    status) cat "$b/dkms.status" ;;
    remove) m=""; while [ \$# -gt 0 ]; do [ "\$1" = -m ] && m="\$2"; shift; done; grep -v "^\$m" "$b/dkms.status" > "$b/dkms.status.n"; mv "$b/dkms.status.n" "$b/dkms.status" ;;
esac
exit 0
SH
    chmod +x "$b/bin/dkms"
}
run_hook() { # $1 = box ; extra env via caller
    local b="$1"
    NCZ_TARGET_ARCH=amd64 NCZ_ASSETS_KERNEL="$b/assets" NCZ_DMI_ROOT="$b/dmi" NCZ_USRSRC="$b/usrsrc" \
    NCZ_MODPROBE_D="$b/modprobe.d" NCZ_LIB_MODULES="$b/libmodules" PATH="$b/bin:$PATH" bash "$HOOK" >"$b/out" 2>&1
}
built() { grep -c -E "^build -m $2 " "$1/dkms.calls"; }

# 1. default on Apple hardware
B="$T/a"; mkbox "$B" "Apple Inc."; run_hook "$B"
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
B="$T/b"; mkbox "$B" "Apple Inc."; echo "t2thunderbolt/0.1, 7.2.9-test: installed" > "$B/dkms.status"; mkdir -p "$B/usrsrc/t2thunderbolt-0.1"; run_hook "$B"
grep -q -E "^remove -m t2thunderbolt " "$B/dkms.calls" && ok "stale: dkms remove t2thunderbolt called" || bad "stale: dkms remove not called"
[ ! -d "$B/usrsrc/t2thunderbolt-0.1" ] && ok "stale: old source tree removed" || bad "stale: old source tree left"

# 4. explicit opt-in
B="$T/c"; mkbox "$B" "Apple Inc."; NCZ_T2_DKMS_EXTRA=t2thunderbolt run_hook "$B"
[ "$(built "$B" t2thunderbolt)" = 1 ] && ok "opt-in: t2thunderbolt built" || bad "opt-in: t2thunderbolt not built"
[ ! -e "$B/modprobe.d/ncz-t2thunderbolt.conf" ] && ok "opt-in: no blacklist file" || bad "opt-in: blacklist file present"

# 5. unknown extra names are ignored with a warning
B="$T/d"; mkbox "$B" "Apple Inc."; NCZ_T2_DKMS_EXTRA="t2evil" run_hook "$B"
if grep -q "not a known optional module" "$B/out" && [ "$(built "$B" t2evil)" = 0 ]; then ok "unknown extra module ignored with a warning"; else bad "unknown extra module not handled"; fi

# 6. non-Apple hardware: nothing built, nothing written
B="$T/e"; mkbox "$B" "ASUSTeK COMPUTER INC."; run_hook "$B"
if [ ! -s "$B/dkms.calls" ] && [ ! -e "$B/modprobe.d/ncz-t2thunderbolt.conf" ]; then ok "non-Apple: hook is inert (no dkms calls, no modprobe.d file)"; else bad "non-Apple: hook acted"; fi

echo "t2-dkms-hook tests: $pass passed, $fail failed"
[ "$fail" = 0 ]
