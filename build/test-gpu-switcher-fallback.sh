#!/bin/bash
# test-gpu-switcher-fallback.sh -- a Panthor boot never ends on software
# rendering when a Mali driver exists (r201).
#
# assets/gpu/ncz-gpu-switcher.sh falls back to Mali when Panthor was selected
# (sky1.gpu=mesa) but is not bound and mali_kbase is available, records why in
# /run/ncz-gpu-fallback, and fails loudly when a cmdline module_blacklist=
# makes the fallback impossible. The switcher runs in a sandbox: absolute
# paths are rewritten into a fixture root, and modprobe/lsmod/uname/id/modinfo
# are stubs that model the kernel.
#
# Run: bash build/test-gpu-switcher-fallback.sh     Exit 0 = pass, 1 = fail.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${NCZ_TEST_ROOT:-$(cd "$HERE/.." && pwd)}"
SW="$ROOT/assets/gpu/ncz-gpu-switcher.sh"
W="$(mktemp -d -t switcher-fallback.XXXXXX)"; trap 'rm -rf "$W"' EXIT
PASS=0; FAIL=0
ok()  { echo "  PASS  $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'; }
K=7.3.0-sky1-ncz
echo "=== switcher: Panthor selected but not bound -> Mali ==="
SB="$W/sb"
mksb() {   # mksb CMDLINE MODULE-FILES...
    rm -rf "$SB"; mkdir -p "$SB/bin" "$SB/etc/modprobe.d" "$SB/etc/default" "$SB/etc/ld.so.conf.d" "$SB/etc/vulkan/icd.d" \
        "$SB/etc/vulkan/implicit_layer.d" "$SB/usr/share/vulkan/implicit_layer.d" "$SB/run" "$SB/dev" "$SB/proc" \
        "$SB/sys/bus/platform/drivers/panthor" "$SB/sys/class/drm" "$SB/lib/modules/$K/updates/dkms" "$SB/etc/glvnd/egl_vendor.d"
    echo "$1" > "$SB/proc/cmdline"; shift
    for f in "$@"; do : > "$SB/lib/modules/$K/updates/dkms/$f"; done
    : > "$SB/lsmod"
    printf '#!/bin/sh\n[ "$1" = -u ] && echo 0 || echo root\n' > "$SB/bin/id"
    printf '#!/bin/sh\necho %s\n' "$K" > "$SB/bin/uname"
    printf '#!/bin/sh\necho "Module Size Used by"; cat "%s/lsmod"\n' "$SB" > "$SB/bin/lsmod"
    printf '#!/bin/sh\nexit 1\n' > "$SB/bin/modinfo"
    printf '#!/bin/sh\nexit 0\n' > "$SB/bin/ldconfig"
    printf '#!/bin/sh\nexit 0\n' > "$SB/bin/fuser"
    cat > "$SB/bin/modprobe" <<EOF
#!/bin/sh
# kernel model: a module loads if its .ko exists and the cmdline does not blacklist it;
# mali_kbase binds (/dev/mali0); panthor loads but never binds (no CIXH5000 link).
SB="$SB"; K="$K"
if [ "\$1" = -r ]; then shift; grep -v "^\$1 " "\$SB/lsmod" > "\$SB/lsmod.n"; mv "\$SB/lsmod.n" "\$SB/lsmod"; [ "\$1" = mali_kbase ] && rm -f "\$SB/dev/mali0"; exit 0; fi
m=\$1
bl=\$(sed -n 's/.*module_blacklist=\\([^ ]*\\).*/\\1/p' "\$SB/proc/cmdline" | tr ',' '\\n')
printf '%s\\n' "\$bl" | grep >/dev/null -x "\$m" && { echo "modprobe: Module \$m is blacklisted" >&2; exit 1; }
[ -e "\$SB/lib/modules/\$K/updates/dkms/\$m.ko" ] || { echo "modprobe: FATAL: Module \$m not found" >&2; exit 1; }
grep -q "^\$m " "\$SB/lsmod" || echo "\$m 1 0" >> "\$SB/lsmod"
[ "\$m" = mali_kbase ] && [ ! -e "\$SB/mali-nobind" ] && : > "\$SB/dev/mali0"
exit 0
EOF
    chmod +x "$SB/bin/"*
    sed -e "s#/proc/cmdline#$SB/proc/cmdline#g" -e "s#/dev/mali0#$SB/dev/mali0#g" -e "s#/sys/#$SB/sys/#g" \
        -e "s#/lib/modules/#$SB/lib/modules/#g" -e "s#/run/#$SB/run/#g" -e "s#/usr/share/vulkan/#$SB/usr/share/vulkan/#g" \
        -e "s#=/etc/#=$SB/etc/#g" -e "s# /etc/# $SB/etc/#g" -e "s#\"/etc/#\"$SB/etc/#g" -e "s#:-/etc/#:-$SB/etc/#g" -e "s#/opt/cixgpu-compat#$SB/opt/cixgpu-compat#g" \
        "$SW" > "$SB/switcher.sh"
}
runsw() { PATH="$SB/bin:/usr/bin:/bin" sh "$SB/switcher.sh" > "$SB/out" 2> "$SB/err"; echo $?; }
mksb "root=x module_blacklist=typec_rts5453,rts5453 sky1.gpu=mesa" mali_kbase.ko memory_group_manager.ko protected_memory_allocator.ko
left=$(grep -v '^[[:space:]]*#' "$SB/switcher.sh" | sed 's#/dev/null##g' | grep -nE '[ ="(:-]/(etc|run|sys|dev|proc|lib/modules)/' || true)
[ -z "$left" ] && ok "switcher sandboxed (no host paths left)" || bad "sandbox rewrite left host paths" "$left"
rc=$(runsw)
[ "$rc" = 0 ] && [ -e "$SB/dev/mali0" ] && ok "O6N state: no panthor.ko -> Mali bound, exit 0" || bad "no fallback (rc=$rc)" "$(cat "$SB/out" "$SB/err")"
[ "$(cat "$SB/etc/ncz-gpu-profile" 2>/dev/null)" = mali ] && ok "state file says mali" || bad "state file: $(cat "$SB/etc/ncz-gpu-profile" 2>/dev/null)"
grep -q 'no panthor module' "$SB/run/ncz-gpu-fallback" 2>/dev/null && ok "fallback note records why (for ncz-gpu-status)" || bad "no fallback note"
grep -q 'WARN: Panthor selected but no panthor module' "$SB/err" && ok "fallback is announced on stderr (journal+console)" || bad "fallback not announced" "$(cat "$SB/err")"

mksb "root=x sky1.gpu=mesa" mali_kbase.ko memory_group_manager.ko protected_memory_allocator.ko panthor.ko
rc=$(runsw)
[ "$rc" = 0 ] && [ -e "$SB/dev/mali0" ] && grep -q 'did not bind' "$SB/run/ncz-gpu-fallback" && ! grep -q '^panthor ' "$SB/lsmod" \
    && ok "panthor.ko present but unbound -> panthor unloaded, Mali bound" || bad "unbound panthor not handled (rc=$rc)" "$(cat "$SB/out" "$SB/err" "$SB/lsmod")"

mksb "root=x module_blacklist=typec_rts5453,mali_kbase,memory_group_manager,protected_memory_allocator sky1.gpu=mesa" mali_kbase.ko memory_group_manager.ko protected_memory_allocator.ko
rc=$(runsw)
[ "$rc" = 1 ] && grep -q 'blocks mali_kbase' "$SB/err" && [ ! -e "$SB/dev/mali0" ] \
    && ok "old entry with a cmdline kbase blacklist: fails loudly (exit 1), names the fix" || bad "cmdline-blocked fallback (rc=$rc)" "$(cat "$SB/err")"

mksb "root=x sky1.gpu=mesa" mali_kbase.ko memory_group_manager.ko protected_memory_allocator.ko
: > "$SB/mali-nobind"
rc=$(runsw)
[ "$rc" = 1 ] && grep -q 'none is bound' "$SB/err" && ok "Mali fallback that does not bind either: exit 1, loud" || bad "double failure not loud (rc=$rc)" "$(cat "$SB/out" "$SB/err")"

mksb "root=x sky1.gpu=vendor" mali_kbase.ko memory_group_manager.ko protected_memory_allocator.ko
rc=$(runsw)
[ "$rc" = 0 ] && [ -e "$SB/dev/mali0" ] && [ ! -e "$SB/run/ncz-gpu-fallback" ] && ok "Mali entry: Mali, no fallback note" || bad "Mali entry regressed (rc=$rc)" "$(cat "$SB/err")"

mksb "root=x sky1.gpu=none" mali_kbase.ko
rc=$(runsw)
[ "$rc" = 0 ] && [ ! -e "$SB/dev/mali0" ] && ok "rescue entry (sky1.gpu=none): loads nothing" || bad "sky1.gpu=none regressed (rc=$rc)"

mksb "root=x sky1.gpu=mesa"
rc=$(runsw)
[ "$rc" = 0 ] && grep -q 'nothing loaded' "$SB/out" && ok "no GPU module at all: unchanged (nothing to load, exit 0)" || bad "no-module case changed (rc=$rc)" "$(cat "$SB/out" "$SB/err")"

grep -q 'fallback      :' "$ROOT/assets/gpu/ncz-gpu-status" && grep -q '/run/ncz-gpu-fallback' "$ROOT/assets/gpu/ncz-gpu-status" \
    && ok "ncz-gpu-status shows the fallback note" || bad "ncz-gpu-status does not show the fallback"

echo "gpu switcher fallback tests: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
