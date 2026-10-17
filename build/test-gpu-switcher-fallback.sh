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
#
# Sandbox files live under $TMPDIR (default $TMPDIR, then /tmp). The fleet
# orchestrator pins TMPDIR to ~/Projects/<item>/ so the stub's mktemp -d also
# runs there; honour that explicitly here so a deleted-or-readonly /tmp can't
# push the test onto tmpfs against the delivery policy.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${NCZ_TEST_ROOT:-$(cd "$HERE/.." && pwd)}"
SW="$ROOT/assets/gpu/ncz-gpu-switcher.sh"
W="$(mktemp -d -t switcher-fallback.XXXXXX)" || { echo "test-gpu-switcher-fallback: mktemp -d failed (is TMPDIR set and writable?)" >&2; exit 2; }
trap 'rm -rf "$W"' EXIT
PASS=0; FAIL=0
ok()  { echo "  PASS  $1"; PASS=$((PASS + 1)); }
# bad() must ALWAYS return 0. Under `set -o pipefail` (and even without it, as the
# last command of a function) the previous form ended on
# `[ -n "${2:-}" ] && printf ...`, so reporting a failure with no detail returned
# 1 -- and any caller chaining `... || bad ...` or leaving it as the last command
# of a subshell would then inherit a spurious non-zero status. The tally in $FAIL
# is the only thing that decides the result; the return status of a reporter is
# not a result.
bad() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'; return 0; }
K=7.3.0-sky1-ncz
echo "=== switcher: Panthor selected but not bound -> Mali ==="
SB="$W/sb"
mksb() {   # mksb CMDLINE MODULE-FILES...
    rm -rf "$SB"; mkdir -p "$SB/bin" "$SB/etc/modprobe.d" "$SB/etc/default" "$SB/etc/ld.so.conf.d" "$SB/etc/vulkan/icd.d" \
        "$SB/etc/vulkan/implicit_layer.d" "$SB/usr/share/vulkan/implicit_layer.d" "$SB/run" "$SB/dev" "$SB/proc" \
        "$SB/sys/bus/platform/drivers/panthor" "$SB/sys/class/drm" "$SB/lib/modules/$K/updates/dkms" "$SB/etc/glvnd/egl_vendor.d"
    # Sky1 is identified by the CIX GPU ACPI platform device; the switcher exits 0
    # early without it (the unit also gates on ConditionPathExists for the same
    # path). Cases are Sky1 unless they say otherwise (mksb-nosky1).
    [ -z "${NOSKY1:-}" ] && mkdir -p "$SB/sys/bus/platform/devices/CIXH5000:00"
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
# mksb-nosky1: same sandbox, no CIXH5000 platform device (generic arm64 / a KVM guest).
mksb-nosky1() { local a=("$@"); NOSKY1=1 mksb "${a[@]}"; }
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

# --- not Sky1 (generic arm64, e.g. the KVM gate): switch nothing, exit 0 ------
# The unit is gated by ConditionPathExists; a direct run (ncz-gpu-select shim,
# a boot hook) must also be a no-op success. Before this, the script ran, found
# no CIXH5000 and exited 1, and the KVM guest reported
# "ncz-gpu-switcher.service loaded failed failed".
echo "=== switcher: not Sky1 -> no-op, exit 0 ==="
mksb-nosky1 "root=x sky1.gpu=vendor" mali_kbase.ko memory_group_manager.ko protected_memory_allocator.ko
rc=$(runsw)
[ "$rc" = 0 ] && [ ! -e "$SB/dev/mali0" ] && grep -q 'not Sky1 hardware, nothing to switch' "$SB/out" \
    && ok "no CIXH5000: mali entry exits 0, loads nothing, logs why (no failed unit)" \
    || bad "off-Sky1 run is not a clean no-op (rc=$rc)" "$(cat "$SB/out" "$SB/err" "$SB/lsmod")"
# ...and it must not touch the machine's configuration on the way out: the
# blacklists and the legacy removals are Sky1 concerns only.
[ ! -e "$SB/etc/modprobe.d/ncz-gpu-drivers.conf" ] && ok "off-Sky1 run writes no modprobe.d blacklist" \
    || bad "off-Sky1 run wrote ncz-gpu-drivers.conf"
mksb-nosky1 "root=x sky1.gpu=mesa" panthor.ko
rc=$(runsw)
[ "$rc" = 0 ] && ok "off-Sky1 panthor entry also exits 0 (no fail-loud about a GPU it does not have)" \
    || bad "off-Sky1 panthor entry exited $rc" "$(cat "$SB/out" "$SB/err")"

# --- the unit itself must be gated, not made to fail --------------------------
# ConditionFirmware=device-tree-compatible() is NOT usable: Sky1 is ACPI, so it
# would skip the unit on Sky1 too. The condition must name the ACPI platform
# device the same way the script and ncz-gpu-status do.
echo "=== unit: ConditionPathExists on the Sky1 ACPI device ==="
UNIT="$ROOT/assets/gpu/ncz-gpu-switcher.service"
grep -q '^ConditionPathExists=/sys/bus/platform/devices/CIXH5000:00$' "$UNIT" \
    && ok "unit gates on /sys/bus/platform/devices/CIXH5000:00" || bad "unit has no Sky1 ConditionPathExists" "$(grep -n '^Condition' "$UNIT")"
grep -q '^ConditionFirmware=' "$UNIT" && bad "unit uses ConditionFirmware=device-tree-compatible (never true on ACPI Sky1)" || ok "no device-tree ConditionFirmware on the unit"
grep -q '^ExecStart=.*/usr/lib/ncz/gpu-switcher.sh$' "$UNIT" && ok "unit still runs the switcher on Sky1" || bad "unit lost its ExecStart"

# 01-cixgpu-compat.conf (LD_COMPAT) must NEVER be toggled by the switcher.
# /opt/cixgpu-compat is a complete second GL stack (cix-libglvnd 1.7.0 +
# cix-mesa 24.0.4) that collides with the system glvnd/Mesa 26.x: two loaded
# copies of libEGL_mesa.so.0 corrupt __eglLoadVendors' pthread_once-guarded
# vendor list, crashing labwc/greetd with SIGSEGV. post-install/26-gpu-
# default-mali.sh leaves it disabled at install time (commit 43f7d21); the
# switcher used to enable_file() it on every mali-mode boot, silently undoing
# that. Fixed by 60a39a23 ("ncz-gpu-switcher must never re-enable
# 01-cixgpu-compat.conf"). This guard keeps it fixed.
echo "=== switcher: never re-enables 01-cixgpu-compat.conf ==="
touched=$(grep -nE '^[[:space:]]*(enable_file|disable_file)[[:space:]]+"?\$LD_COMPAT' "$SW" || true)
[ -z "$touched" ] && ok "no enable_file/disable_file of \$LD_COMPAT in the switcher" \
    || bad "switcher toggles LD_COMPAT" "$touched"
# Behavioral: a .disabled compat conf must stay disabled across a mali boot.
mksb "root=x sky1.gpu=vendor" mali_kbase.ko memory_group_manager.ko protected_memory_allocator.ko
: > "$SB/etc/ld.so.conf.d/00-cixgpu-pro.conf.disabled"
: > "$SB/etc/ld.so.conf.d/01-cixgpu-compat.conf.disabled"
runsw > /dev/null
if [ ! -e "$SB/etc/ld.so.conf.d/01-cixgpu-compat.conf" ] && [ -e "$SB/etc/ld.so.conf.d/01-cixgpu-compat.conf.disabled" ]; then
    ok "mali boot leaves the disabled 01-cixgpu-compat.conf disabled"
else
    bad "mali boot re-enabled 01-cixgpu-compat.conf" "$(ls "$SB/etc/ld.so.conf.d/")"
fi
# sanity: LD_PRO IS still enabled by the same boot, so the guard above is not
# passing merely because the switcher stopped touching ld.so.conf.d at all.
[ -e "$SB/etc/ld.so.conf.d/00-cixgpu-pro.conf" ] && ok "mali boot still enables 00-cixgpu-pro.conf (guard is not vacuous)" \
    || bad "guard is vacuous: LD_PRO was not enabled either" "$(ls "$SB/etc/ld.so.conf.d/")"
echo "=== switcher: the modprobe.d file records the selection (MINOR-003) ==="
# The selection must be on disk, not only in the bootloader's sky1.gpu= token:
# on the Panthor entry the cmdline no longer blacklists mali_kbase, so a
# post-install hook or a stray autoload would otherwise find no statement of
# which stack won. It must also stay a `blacklist` and never an `install ...
# /bin/true` line, or the explicit modprobe the switcher and the Mali fallback
# depend on would stop working.
BL="$SB/etc/modprobe.d/ncz-gpu-drivers.conf"

mksb "root=x sky1.gpu=mesa" mali_kbase.ko memory_group_manager.ko protected_memory_allocator.ko panthor.ko
rc=$(runsw)
[ "$rc" = 0 ] && grep -qx 'blacklist mali_kbase' "$BL" && grep -q '^# Selected: panthor' "$BL" \
    && ok "Panthor selection: blacklisted mali_kbase recorded in $BL" || bad "Panthor selection not recorded (rc=$rc)" "$(cat "$BL" 2>/dev/null; cat "$SB/err")"
[ "$(grep -c '^blacklist mali_kbase$' "$BL")" = 1 ] \
    && ok "Panthor selection: mali_kbase named exactly once (modprobe.d is a set)" || bad "mali_kbase blacklist lines: $(grep -c '^blacklist mali_kbase$' "$BL")"
grep -qE '^install[[:space:]]+mali_kbase' "$BL" \
    && bad "mali_kbase held with an install line (would block the explicit modprobe and the Mali fallback)" "$(cat "$BL")" \
    || ok "Panthor selection: no install line, so an explicit modprobe still loads mali_kbase"
! grep -qE '^suggests[[:space:]]' "$BL" \
    && ok "Panthor selection: nothing downgraded to 'suggests' (would let autoload win)" || bad "weak blacklist written" "$(cat "$BL")"

mksb "root=x sky1.gpu=vendor" mali_kbase.ko memory_group_manager.ko protected_memory_allocator.ko
rc=$(runsw)
[ "$rc" = 0 ] && grep -qx 'blacklist panthor' "$BL" && [ "$(grep -c '^blacklist mali_kbase$' "$BL")" = 1 ] \
    && grep -q '^# Selected: mali' "$BL" && ! grep -q '^# Selected: panthor' "$BL" \
    && ok "Mali selection: panthor held, selection names mali" || bad "Mali selection file (rc=$rc)" "$(cat "$BL" 2>/dev/null)"

mksb "root=x sky1.gpu=none" mali_kbase.ko
rc=$(runsw)
[ "$rc" = 0 ] && [ -s "$BL" ] && ! grep -q '^# Selected:' "$BL" \
    && ok "rescue entry (sky1.gpu=none): file written, no stack claimed" || bad "sky1.gpu=none blacklist (rc=$rc)" "$(cat "$BL" 2>/dev/null)"

mksb "root=x sky1.gpu=mesa" mali_kbase.ko memory_group_manager.ko protected_memory_allocator.ko panthor.ko
: > "$SB/mali-nobind"
rc=$(runsw)
[ "$rc" = 1 ] && ok "double failure still exit 1 with the selection recorded" || bad "double failure changed (rc=$rc)" "$(cat "$SB/err")"

echo "=== switcher: the blacklist file is published atomically (single write) ==="
# The file must never be observable half-written: modprobe.d is read by udev
# coldplug (which can run concurrently with this unit) and by any `modprobe` on
# the box. The switcher builds it in a sibling temp file and renames it over the
# target, so the fix here is: exactly one write, no stray temp files, and the
# final file is a complete document.
mksb "root=x sky1.gpu=mesa" mali_kbase.ko memory_group_manager.ko protected_memory_allocator.ko panthor.ko
MD="$SB/etc/modprobe.d"
# mksb starts from a clean sandbox, so plant a PREVIOUS boot's file first: the
# inode must change, which is how we prove the new content arrived by rename()
# rather than by truncating the file in place.
printf '# stale file from an earlier boot\nblacklist panthor\n' > "$BL"
inode_before=$(ls -i "$BL" 2>/dev/null | awk '{print $1}')
rc=$(runsw)
inode_after=$(ls -i "$BL" 2>/dev/null | awk '{print $1}')
[ "$rc" = 0 ] && [ -n "$inode_before" ] && [ "$inode_before" != "$inode_after" ] \
    && ok "file is replaced by rename (inode changes), not edited in place" || bad "file not atomically replaced (before=$inode_before after=$inode_after rc=$rc)"
leftovers=$(ls "$MD" 2>/dev/null | grep -c 'ncz-gpu-drivers\.conf\.' || true)
[ "$leftovers" = 0 ] && ok "no temp file left behind in modprobe.d" || bad "$leftovers temp file(s) left in $MD" "$(ls -a "$MD")"
perms=$(stat -c '%a' "$BL" 2>/dev/null)
[ "$perms" = 644 ] && ok "installed file is mode 0644 (still world-readable for modprobe)" || bad "installed mode is $perms, expected 644"
# A complete document: header, the four holds, and the selection, with no
# duplicated header from a half-applied rewrite.
[ "$(grep -c '^# Written by ncz-gpu-switcher' "$BL")" = 1 ] \
    && ok "exactly one header line (a torn rewrite would duplicate or drop it)" || bad "header lines: $(grep -c '^# Written by ncz-gpu-switcher' "$BL")"
[ "$(grep -c '^blacklist ' "$BL")" = 4 ] \
    && ok "exactly the four hold lines, written once" || bad "blacklist lines: $(grep -c '^blacklist ' "$BL")" "$(cat "$BL")"
# $(...) strips trailing newlines, so a command substitution cannot see the
# ending. Compare the last BYTE instead: od on the final byte must be \n (012).
[ "$(tail -c 1 "$BL" | od -An -c | tr -d ' \n')" = '\n' ] \
    && ok "file ends with a newline" || bad "file does not end with a newline" "$(tail -c 1 "$BL" | od -c)"

# The temp-file path must degrade safely, and the test must PROVE which path was
# taken rather than merely that the file came out right (the direct write also
# produces a correct file, so content alone cannot tell them apart -- the
# switcher logs which one it used).
#
# Two distinct unusable-mktemp conditions, because they fail differently:
#   A. mktemp missing from PATH entirely (command not found)
#   B. mktemp present but failing: exit 1, no path on stdout (a broken/EROFS
#      /usr, a read-only /etc, etc.) -- the case where a naive
#      `_bl=$(mktemp ...) || _bl=$BLACKLIST` would be fine but
#      `> "$_bl"` with an empty value would not be.
for variant in absent failing; do
    mksb "root=x sky1.gpu=mesa" mali_kbase.ko memory_group_manager.ko protected_memory_allocator.ko panthor.ko
    printf '# stale file from an earlier boot\nblacklist panthor\n' > "$BL"
    case "$variant" in
        absent)
            # A stub that fails the way a missing command does: exit 127, nothing
            # on stdout. A dangling symlink does NOT do this -- the shell falls
            # through to the next PATH entry and finds the real /usr/bin/mktemp
            # (verified), so it would silently test the wrong thing. A stub that
            # merely exits 1 is the separate "failing" variant below.
            printf '#!/bin/sh\necho "mktemp: command not found" >&2\nexit 127\n' > "$SB/bin/mktemp"
            chmod +x "$SB/bin/mktemp"
            runsw_nomkt() { runsw; }
            ;;
        failing)
            printf '#!/bin/sh\nexit 1\n' > "$SB/bin/mktemp"; chmod +x "$SB/bin/mktemp"
            runsw_nomkt() { runsw; }
            ;;
    esac
    rc=$(runsw_nomkt)
    # Either stack may win in this sandbox (panthor never binds without a real
    # GPU, so the Mali fallback runs); what matters is that SOME selection is
    # recorded and the file is whole. grep -E, not -q: (a|b) is BRE with \( \).
    [ "$rc" = 0 ] && grep -qx 'blacklist mali_kbase' "$BL" && grep -qE '^# Selected: (panthor|mali)' "$BL" \
        && ok "mktemp $variant: file still written completely" || bad "mktemp $variant: fallback broken (rc=$rc)" "$(cat "$BL" 2>/dev/null; cat "$SB/err")"
    grep -q 'no usable mktemp' "$SB/out" \
        && ok "mktemp $variant: the direct (non-atomic) path was taken and announced" \
        || bad "mktemp $variant: switcher did not report taking the direct path" "$(cat "$SB/out" "$SB/err")"
    left=$(ls "$MD" 2>/dev/null | grep -c 'ncz-gpu-drivers\.conf\.' || true)
    [ "$left" = 0 ] && ok "mktemp $variant: no stray temp files" || bad "mktemp $variant: $left temp file(s) left" "$(ls -a "$MD")"
done
# And the healthy path must NOT claim to be degraded: the warning is absent and
# the file was published by rename. Check each stream individually: grep -q
# with multiple files returns 0 if the pattern is in ANY of them, so a single
# shared call would mask a warning that surfaced only on stderr (review finding,
# 2026-10-17). Either stream carrying the warning fails the assertion.
# When the pattern is found in _both_ streams, prefer stderr over stdout so the
# "where did it go" diagnostic is the right place (the warning line is emitted
# with err() -> stderr in the switcher).
mksb "root=x sky1.gpu=mesa" mali_kbase.ko memory_group_manager.ko protected_memory_allocator.ko panthor.ko
printf '# stale\n' > "$BL"
before=$(ls -i "$BL" | awk '{print $1}'); rc=$(runsw); after=$(ls -i "$BL" | awk '{print $1}')
_degraded=0
_degraded_stream=""
[ -s "$SB/out" ] && grep -q 'no usable mktemp' "$SB/out" && { _degraded=1; _degraded_stream=stdout; }
[ -s "$SB/err" ] && grep -q 'no usable mktemp' "$SB/err" && { _degraded=1; _degraded_stream=stderr; }
[ "$rc" = 0 ] && [ "$before" != "$after" ] && [ "$_degraded" = 0 ] \
    && ok "healthy mktemp: rename path taken, no degradation warning" || bad "healthy path regressed (rc=$rc _degraded=$_degraded via $_degraded_stream)" "$(cat "$SB/out" "$SB/err")"

echo "gpu switcher fallback tests: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
