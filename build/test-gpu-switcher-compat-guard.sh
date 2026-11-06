#!/bin/bash
# test-gpu-switcher-compat-guard.sh -- the ncz-gpu-switcher must NEVER touch
# /etc/ld.so.conf.d/01-cixgpu-compat.conf (r26.10, preview3).
#
# Background: 01-cixgpu-compat.conf puts /opt/cixgpu-compat -- a COMPLETE
# second GL stack (cix-libglnvnd 1.7.0 + cix-mesa 24.0.4) -- on the loader
# path, where it shadows system glvnd + Mesa 26. Enabling it crashes every
# labwc/greetd start (labwc SIGSEGV in libEGL's __eglLoadVendors, heap
# corruption; metal-verified on the Radxa Orion O6N 2026-09-14/16).
# post-install/26-gpu-default-mali.sh therefore DISABLES the file at install
# time, and the boot-time switcher must never undo that decision.
#
# History: assets/gpu/ncz-gpu-switcher.sh used to
#     enable_file "$LD_COMPAT"   # in userspace_mali(), every mali boot
#     disable_file "$LD_COMPAT"  # in userspace_panthor(), every panthor boot
# The mali-mode re-enable silently reverted the install-time fix on every
# single boot (branch fix/gpu-switcher-stop-reenabling-compat, 5776efd6,
# was the first attempt; 60a39a23 is the committed fix that removed the
# toggle from BOTH functions and is an ancestor of release/preview3-20261017).
#
# This test guards the invariant against regression by RUNNING the actual
# switcher (not just grepping it):
#   1. static: no enable_file/disable_file call may reference $LD_COMPAT;
#      the install-time hook must still disable the file.
#   2. behavioral: the file exists in the sandbox; the switcher runs to
#      completion for each GPU selection, and the file must end up EXACTLY
#      as the switcher's userspace path would only ever leave it -- i.e.
#      untouched. Two directions are exercised:
#        a) mali mode, file pre-ENABLED in the fixture: the file must STILL
#           be enabled afterward (no disable_file regression).
#        b) mali mode, file pre-DISABLED in the fixture (the shipped state):
#           the file must STAY disabled -- this is the case a regression
#           that re-introduces enable_file "$LD_COMPAT" in userspace_mali()
#           flips back, i.e. exactly the 5776efd6 bug.
#        c) panthor mode: the file is left as found either way.
#
# Run: bash build/test-gpu-switcher-compat-guard.sh    Exit 0 = pass, 1 = fail.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${NCZ_TEST_ROOT:-$(cd "$HERE/.." && pwd)}"
SW="$ROOT/assets/gpu/ncz-gpu-switcher.sh"
HOOK="$ROOT/post-install/26-gpu-default-mali.sh"
W="$(mktemp -d -t switcher-compat-guard.XXXXXX)"; trap 'rm -rf "$W"' EXIT
PASS=0; FAIL=0
ok()  { echo "  PASS  $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'; }
K=7.3.0-sky1-ncz

echo "=== static: no switcher code path may touch 01-cixgpu-compat.conf ==="
hits=$(grep -nE 'enable_file|disable_file' "$SW" | grep 'LD_COMPAT' || true)
[ -z "$hits" ] && ok "switcher never enable/disable_file's \$LD_COMPAT" \
    || bad "switcher still toggles the compat file" "$hits"
grep -q 'disable_file /etc/ld.so.conf.d/01-cixgpu-compat.conf' "$HOOK" \
    && ok "install-time hook still disables 01-cixgpu-compat.conf (the decision the guard protects)" \
    || bad "install-time hook no longer disables the compat file (guard's premise changed)"

echo "=== behavioral: run the real switcher; it must leave the compat file untouched ==="
SB="$W/sb"
mksb() {   # mksb CMDLINE
    rm -rf "$SB"; mkdir -p "$SB/bin" "$SB/etc/modprobe.d" "$SB/etc/default" "$SB/etc/ld.so.conf.d" \
        "$SB/etc/vulkan/icd.d" "$SB/etc/vulkan/implicit_layer.d" "$SB/usr/share/vulkan/implicit_layer.d" \
        "$SB/run" "$SB/dev" "$SB/proc" \
        "$SB/sys/bus/platform/drivers/panthor" "$SB/sys/class/drm" "$SB/etc/glvnd/egl_vendor.d" \
        "$SB/lib/modules/$K/updates/dkms"
    echo "$1" > "$SB/proc/cmdline"
    # Sky1 is identified by the CIX GPU ACPI platform device: without it the
    # switcher exits 0 before doing anything (24af35f9), and this guard would
    # pass vacuously. Same fixture as test-gpu-switcher-fallback.sh.
    mkdir -p "$SB/sys/bus/platform/devices/CIXH5000:00"
    for f in mali_kbase.ko memory_group_manager.ko protected_memory_allocator.ko panthor.ko; do
        : > "$SB/lib/modules/$K/updates/dkms/$f"
    done
    : > "$SB/lsmod"
    printf '#!/bin/sh\n[ "$1" = -u ] && echo 0 || echo root\n' > "$SB/bin/id"
    printf '#!/bin/sh\necho %s\n' "$K" > "$SB/bin/uname"
    printf '#!/bin/sh\necho "Module Size Used by"; cat "%s/lsmod"\n' "$SB" > "$SB/bin/lsmod"
    printf '#!/bin/sh\nexit 1\n' > "$SB/bin/modinfo"
    printf '#!/bin/sh\nexit 0\n' > "$SB/bin/ldconfig"
    printf '#!/bin/sh\nexit 0\n' > "$SB/bin/fuser"
    cat > "$SB/bin/modprobe" <<EOF
#!/bin/sh
# kernel model: a module loads if its .ko exists; -r unloads (no blacklist here).
SB="$SB"; K="$K"
if [ "\$1" = -r ]; then shift; grep -v "^\$1 " "\$SB/lsmod" > "\$SB/lsmod.n"; mv "\$SB/lsmod.n" "\$SB/lsmod"; [ "\$1" = mali_kbase ] && rm -f "\$SB/dev/mali0"; exit 0; fi
[ -e "\$SB/lib/modules/\$K/updates/dkms/\$1.ko" ] || { echo "modprobe: FATAL: Module \$1 not found" >&2; exit 1; }
grep -q "^\$1 " "\$SB/lsmod" || echo "\$1 1 0" >> "\$SB/lsmod"
[ "\$1" = mali_kbase ] && : > "\$SB/dev/mali0"
exit 0
EOF
    chmod +x "$SB/bin/"*
    # Sandbox the switcher the same way test-gpu-switcher-fallback.sh does
    # (plus /opt/ for the EGL vendor src), so every absolute path lands in $SB.
    sed -e "s#/proc/cmdline#$SB/proc/cmdline#g" -e "s#/dev/mali0#$SB/dev/mali0#g" -e "s#/sys/#$SB/sys/#g" -e "s#/opt/#$SB/opt/#g" \
        -e "s#/lib/modules/#$SB/lib/modules/#g" -e "s#/run/#$SB/run/#g" -e "s#/usr/share/vulkan/#$SB/usr/share/vulkan/#g" \
        -e "s#=/etc/#=$SB/etc/#g" -e "s# /etc/# $SB/etc/#g" -e "s#\"/etc/#\"$SB/etc/#g" -e "s#:-/etc/#:-$SB/etc/#g" \
        "$SW" > "$SB/switcher.sh"
}
runsw() { PATH="$SB/bin:/usr/bin:/bin" sh "$SB/switcher.sh" > "$SB/out" 2> "$SB/err"; echo $?; }

# --- Mali mode, compat file ENABLED in the fixture: the switcher must leave it enabled.
mksb "root=x sky1.gpu=vendor"
echo "path to the cix compat stack" > "$SB/etc/ld.so.conf.d/01-cixgpu-compat.conf"
rc=$(runsw)
[ "$rc" = 0 ] && ok "mali-mode run completes (exit 0)" || bad "mali-mode run failed (rc=$rc)" "$(cat "$SB/out" "$SB/err")"
[ -f "$SB/etc/ld.so.conf.d/01-cixgpu-compat.conf" ] && [ ! -f "$SB/etc/ld.so.conf.d/01-cixgpu-compat.conf.disabled" ] \
    && ok "mali-mode leaves 01-cixgpu-compat.conf exactly as found (enabled)" \
    || { ls -1 "$SB/etc/ld.so.conf.d/" | sed 's/^/        /'; bad "mali-mode toggled the compat file (renamed to .disabled?)"; }
[ "$(cat "$SB/etc/ncz-gpu-profile" 2>/dev/null)" = mali ] && ok "mali-mode state file says mali (run was real)" \
    || bad "state file: $(cat "$SB/etc/ncz-gpu-profile" 2>/dev/null)"

# --- Mali mode, compat file pre-DISABLED (the shipped state): it must STAY disabled.
#     A regression that re-introduces enable_file "$LD_COMPAT" in
#     userspace_mali() is a no-op against the fixture above but flips this
#     one back enabled -- this case catches exactly the 5776efd6 bug.
mksb "root=x sky1.gpu=vendor"
: > "$SB/etc/ld.so.conf.d/01-cixgpu-compat.conf.disabled"
: > "$SB/etc/ld.so.conf.d/00-cixgpu-pro.conf"
rc=$(runsw)
[ "$rc" = 0 ] && ok "mali-mode (compat pre-disabled) run completes (exit 0)" || bad "mali-mode pre-disabled run failed (rc=$rc)" "$(cat "$SB/out" "$SB/err")"
[ -f "$SB/etc/ld.so.conf.d/01-cixgpu-compat.conf.disabled" ] && [ ! -f "$SB/etc/ld.so.conf.d/01-cixgpu-compat.conf" ] \
    && ok "mali-mode keeps 01-cixgpu-compat.conf DISABLED (does not re-enable it -- the 5776efd6 bug)" \
    || { ls -1 "$SB/etc/ld.so.conf.d/" | sed 's/^/        /'; bad "mali-mode RE-ENABLED 01-cixgpu-compat.conf (regression of the Mesa-24/26 collision)"; }

# --- Panthor mode, compat file ENABLED in the fixture: the switcher must leave it enabled too.
mksb "root=x sky1.gpu=mesa"
echo "path to the cix compat stack" > "$SB/etc/ld.so.conf.d/01-cixgpu-compat.conf"
rc=$(runsw)
# rc 0 = panthor bound; rc 1 = the switcher failed loudly with no driver bound
# (the fixture has the Sky1 device but nothing binds). Both are legitimate here: the invariant under
# test is that the compat file is untouched either way, and the "selected
# panthor" log line proves userspace_panthor() ran in both.
{ [ "$rc" = 0 ] || [ "$rc" = 1 ]; } && grep -q "selected panthor" "$SB/out" \
    && ok "panthor-mode run reaches userspace_panthor (rc=$rc, selection recorded)" \
    || bad "panthor-mode run failed before applying userspace (rc=$rc)" "$(cat "$SB/out" "$SB/err")"
[ -f "$SB/etc/ld.so.conf.d/01-cixgpu-compat.conf" ] && [ ! -f "$SB/etc/ld.so.conf.d/01-cixgpu-compat.conf.disabled" ] \
    && ok "panthor-mode leaves 01-cixgpu-compat.conf exactly as found (enabled)" \
    || { ls -1 "$SB/etc/ld.so.conf.d/" | sed 's/^/        /'; bad "panthor-mode toggled the compat file"; }

echo "gpu switcher compat guard tests: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
