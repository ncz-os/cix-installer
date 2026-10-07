#!/bin/bash
# test-panthor-hook-overlay-fallback.sh -- post-install/83-panthor-gpu.sh must
# fall back to the prebuilt overlay assets/kernel/panthor/<kver>/panthor.ko
# when DKMS leaves no panthor module for the target kernel, on EVERY install
# path. It used to `exit 0` straight after `dpkg -i panthor-cix-dkms`, whose
# postinst never fails on a broken DKMS build (r200 O6N: DRIVER_GEM_GPUVA on
# 7.3), so the overlay was never considered and the board had no panthor.ko.
#
# Runs the real hook with every absolute /etc, /usr, /var path rewritten into a
# sandbox and fake dpkg/dkms/modinfo/depmod on PATH. NCZ_HOOK_UNDER_TEST
# points at another copy of the hook (used to prove the test fails on old code).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="${NCZ_HOOK_UNDER_TEST:-$ROOT/post-install/83-panthor-gpu.sh}"
T="$(mktemp -d "${TMPDIR:-/var/tmp}/panthor83.XXXXXX")"; trap 'rm -rf "$T"' EXIT
KV=7.3.0-rc6-sky1-ncz
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

# mkbox <name> <overlay: good|badvermagic|none> <modules: none|xz> <dpkg-rc>
mkbox() {
    local b="$T/$1" ovl="$2" mods="$3" rc="$4"
    local meta="$b/usr/local/lib/cix-installer" a
    a="$meta/assets/kernel/panthor"
    mkdir -p "$b/bin" "$a" "$meta/assets/cix-debs" "$b/usr/lib/modules/$KV/updates/dkms"
    echo "$KV" > "$meta/KVER_NEXT"
    printf 'PACKAGE_NAME="panthor-cix"\nPACKAGE_VERSION="7.2.0"\n' > "$a/dkms.conf"
    echo "/* src */" > "$a/panthor_drv.c"
    : > "$meta/assets/cix-debs/panthor-cix-dkms_7.2.0+ncz1_all.deb"
    case "$ovl" in
        good)       mkdir -p "$a/$KV"; echo "$KV SMP mod_unload" > "$a/$KV/panthor.ko" ;;
        badvermagic) mkdir -p "$a/$KV"; echo "7.2.0-sky1-ncz SMP mod_unload" > "$a/$KV/panthor.ko" ;;
    esac
    [ "$mods" = xz ] && echo dkms-built > "$b/usr/lib/modules/$KV/updates/dkms/panthor.ko.xz"
    cat > "$b/bin/dpkg" <<SH
#!/bin/sh
case "\$1" in
    --print-architecture) echo arm64 ;;
    -i) exit $rc ;;
    *) exit 0 ;;
esac
SH
    printf '#!/bin/sh\nexit 0\n' > "$b/bin/dkms"
    printf '#!/bin/sh\necho "$*" >> "%s/depmod.calls"\nexit 0\n' "$b" > "$b/bin/depmod"
    printf '#!/bin/sh\ncat "$3"\n' > "$b/bin/modinfo"
    chmod +x "$b/bin/"*
    # Rewrite every absolute /etc|/usr|/var path into the sandbox.
    sed -E "s#(^|[^A-Za-z0-9_./\$-])/(etc|usr|var)/#\1$b/\2/#g" "$HOOK" > "$b/hook.sh"
}
run() { env -i PATH="$T/$1/bin:/usr/bin:/bin" NCZ_TARGET_ARCH=arm64 bash "$T/$1/hook.sh" >"$T/$1/out" 2>&1; echo $? > "$T/$1/rc"; }
installed() { [ -s "$T/$1/usr/lib/modules/$KV/updates/dkms/panthor.ko" ]; }

# 1. deb installs fine but DKMS built nothing -> overlay must be installed
mkbox a good none 0; run a
if installed a && cmp -s "$T/a/usr/lib/modules/$KV/updates/dkms/panthor.ko" "$T/a/usr/local/lib/cix-installer/assets/kernel/panthor/$KV/panthor.ko" \
   && [ "$(cat "$T/a/rc")" = 0 ]; then ok "deb path, no DKMS module: prebuilt overlay installed"
else bad "deb path, no DKMS module: prebuilt overlay NOT installed"; fi

# 2. DKMS produced a module -> overlay must not be added beside it
mkbox b good xz 0; run b
if ! installed b; then ok "deb path, DKMS module present: overlay left alone"
else bad "deb path, DKMS module present: overlay installed next to DKMS module"; fi

# 3. overlay built for another kernel -> refused, loud warning, nothing installed
mkbox c badvermagic none 0; run c
if ! installed c && grep -q "REFUSE" "$T/c/out" && grep -q "WARN: no DKMS-built and no prebuilt" "$T/c/out"; then
    ok "deb path, wrong-vermagic overlay: refused with warning"
else bad "deb path, wrong-vermagic overlay: not refused"; fi

# 4. no overlay at all -> warning, still exit 0
mkbox d none none 0; run d
if ! installed d && grep -q "WARN: no DKMS-built and no prebuilt" "$T/d/out" && [ "$(cat "$T/d/rc")" = 0 ]; then
    ok "deb path, no overlay: warns, rc 0"
else bad "deb path, no overlay: wrong behaviour"; fi

# 5. dpkg -i fails -> raw source path still ends with the overlay
mkbox e good none 1; run e
if installed e; then ok "dpkg failure -> raw path: prebuilt overlay installed"
else bad "dpkg failure -> raw path: prebuilt overlay NOT installed"; fi

echo "--- $pass passed, $fail failed"
[ "$fail" -eq 0 ]
