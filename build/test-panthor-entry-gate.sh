#!/bin/bash
# test-panthor-entry-gate.sh -- the installed Sky1 rEFInd menu offers
# "7.3 Panthor (Experimental)" only when a panthor module exists (r201).
#
# O6N booted that entry (sky1.gpu=mesa) on a 7.3 kernel with no panthor.ko
# (panthor-cix-dkms 7.2.0 does not build on 7.3; updates/dkms had only
# mali_kbase.ko): no GPU driver bound, software rendering. This runs the real
# NCZ-PANTHOR-ENTRY block and the menu emission from
# assets/refind/ncz-refind-refresh.sh, and checks the entry no longer
# hard-blocks the kbase trio on its cmdline (which made ncz-gpu-switcher's Mali
# fallback impossible; see build/test-gpu-switcher-fallback.sh).
#
# Run: bash build/test-panthor-entry-gate.sh     Exit 0 = pass, 1 = fail.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${NCZ_TEST_ROOT:-$(cd "$HERE/.." && pwd)}"
GEN="$ROOT/assets/refind/ncz-refind-refresh.sh"
W="$(mktemp -d -t panthor-entry.XXXXXX)"; trap 'rm -rf "$W"' EXIT
PASS=0; FAIL=0
ok()  { echo "  PASS  $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'; }
K=7.3.0-sky1-ncz
echo "=== generator: Panthor entry only with a panthor module ==="
awk 'index($0,"NCZ-PANTHOR-ENTRY-BEGIN"){f=1;next} index($0,"NCZ-PANTHOR-ENTRY-END"){f=0} f' "$GEN" > "$W/gate.sh"
[ -s "$W/gate.sh" ] || { echo "FATAL: NCZ-PANTHOR-ENTRY block missing from $GEN" >&2; exit 2; }
gate() {   # gate <files...> -> PANTHOR_ENTRY value
    rm -rf "$W/mods"; mkdir -p "$W/mods/$K/updates/dkms"
    for f in "$@"; do mkdir -p "$(dirname "$W/mods/$K/$f")"; : > "$W/mods/$K/$f"; done
    ( set -euo pipefail; NCZ_MODULES_ROOT="$W/mods" NEXT_AVAILABLE=1 KVER_NEXT=$K; . "$W/gate.sh" >/dev/null; echo "$PANTHOR_ENTRY" )
}
[ "$(gate updates/dkms/mali_kbase.ko)" = 0 ] && ok "O6N state (only mali_kbase.ko): no Panthor entry" || bad "Panthor entry offered without panthor.ko"
[ "$(gate updates/dkms/mali_kbase.ko updates/dkms/panthor.ko)" = 1 ] && ok "updates/dkms/panthor.ko: entry offered" || bad "DKMS panthor.ko not detected"
[ "$(gate kernel/drivers/gpu/drm/panthor/panthor.ko.xz)" = 1 ] && ok "in-tree panthor.ko.xz: entry offered" || bad "compressed in-tree panthor not detected"
[ "$(gate kernel/drivers/gpu/drm/panthor/panthor_other.ko)" = 0 ] && ok "a different module name does not count" || bad "matched a non-panthor module"
r=$( set -euo pipefail; NCZ_MODULES_ROOT="$W/none" NEXT_AVAILABLE=1 KVER_NEXT=$K; . "$W/gate.sh" >/dev/null; echo "$PANTHOR_ENTRY" )
[ "$r" = 0 ] && ok "no module tree for the kernel: no entry (and no set -e abort)" || bad "missing module tree mishandled: '$r'"

# the menu emission itself, extracted and run with both values
emit=$(awk '/^        if \[ "\$PANTHOR_ENTRY" = "1" \]; then$/{f=1} f{print} f && /^        fi$/{exit}' "$GEN")
if [ -z "$emit" ]; then
    bad "Panthor menuentry is not wrapped in if [ \"\$PANTHOR_ENTRY\" = \"1\" ]"
else
    for v in 0 1; do
        n=$(PANTHOR_ENTRY=$v NCZ_RELEASE_SHORT=NCZ KVER_NEXT=$K REFIND_ICON= NEXT_INITRD_AVAILABLE=1 PANTHOR_OPTIONS=x bash -c "$emit" | grep -c 'Panthor (Experimental)')
        [ "$n" = "$v" ] && ok "PANTHOR_ENTRY=$v writes $v Panthor menuentry" || bad "PANTHOR_ENTRY=$v wrote $n entries"
    done
fi
[ "$(grep -c 'Panthor (Experimental)\\" {"' "$GEN")" = 1 ] && ok "exactly one Panthor menuentry writer in the generator" || bad "unguarded Panthor menuentry writer"
po=$(grep '^    PANTHOR_OPTIONS=' "$GEN")
case "$po" in *mali_kbase*|*PANTHOR_GPU_BLACKLIST*) bad "Panthor entry still hard-blocks mali_kbase on the cmdline (fallback impossible)" "$po" ;;
              *sky1.gpu=mesa*) ok "Panthor entry: sky1.gpu=mesa, no cmdline kbase blacklist" ;;
              *) bad "PANTHOR_OPTIONS lost sky1.gpu=mesa" "$po" ;; esac
grep -q '^    MALI_OPTIONS=.*merge_module_blacklist "\$NEXT_OPTIONS" "\$MALI_GPU_BLACKLIST").*sky1.gpu=vendor' "$GEN" && ok "Mali entry unchanged (panthor blacklisted, sky1.gpu=vendor)" || bad "Mali entry changed"

# The whole menu emission block, every variant x Panthor combination: each
# options line must sit inside a menuentry { ... } and braces must balance.
# 2026-10-17: the Magnetar server guard closed its if/fi before the entry
# bodies, so the server menu (and a desktop with no panthor module) carried
# headerless "options ..." / "}" lines; the snippet check above stopped at
# the first "        fi" and could not see it.
block=$(awk '/^    if \[ "\$NEXT_AVAILABLE" = "1" \]; then$/{f=1} f{print} f && /^    fi$/{exit}' "$GEN")
menu_shape() {   # stdin: refind.conf fragment -> "ok" or the first problem
    awk '
        /^menuentry .*\{$/ { if (open) { print "nested menuentry at line " NR; bad=1; exit } open=1; n++; next }
        /^}$/              { if (!open) { print "stray } at line " NR; bad=1; exit } open=0; next }
        /^    (options|loader|initrd|icon) / { if (!open) { print "orphan " $1 " at line " NR; bad=1; exit } }
        END { if (!bad && open) print "unclosed menuentry"; else if (!bad) print "ok " n }'
}
if [ -z "$block" ]; then
    bad "menu emission block (if NEXT_AVAILABLE ... fi) not found"
else
    for variant in desktop server; do
        for v in 0 1; do
            out=$(NCZ_VARIANT=$variant PANTHOR_ENTRY=$v NEXT_AVAILABLE=1 NCZ_RELEASE_SHORT=NCZ KVER_NEXT=$K \
                REFIND_ICON=i NEXT_INITRD_AVAILABLE=1 MALI_OPTIONS=m PANTHOR_OPTIONS=p \
                NEXT_CONSOLE_OPTIONS=c NEXT_RESCUE_OPTIONS=r bash -c "$block" 2>&1)
            shape=$(printf '%s\n' "$out" | menu_shape)
            case "$shape" in
                ok\ *) ok "variant=$variant PANTHOR_ENTRY=$v: well-formed menu (${shape#ok } entries)" ;;
                *) bad "variant=$variant PANTHOR_ENTRY=$v: $shape" "$out" ;;
            esac
        done
    done
fi

echo "panthor entry gate tests: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
