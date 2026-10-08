#!/bin/bash
# test-panthor-fallback-real-overlay.sh -- EXECUTE hook 83's prebuilt-overlay fallback with the REAL
# artifacts of the shipping Sky1 kernel (r201: the fallback was only ever unit-tested against synthetic
# one-line fake .ko files, and the KVM gate never reached it because DKMS built panthor.ko there).
#
# What is real here: post-install/83-panthor-gpu.sh itself, the tracked
# assets/kernel/panthor/<kver>/panthor.ko for the kernel named by assets/kernel/sky1-manifest.json, and the
# vermagic read from the module's own .modinfo (strings, no kmod needed). What is simulated: the target root
# (all /etc /usr /var paths rewritten into a sandbox), dpkg/dkms/depmod, and "DKMS left no module" (the exact
# r200 failure: DRIVER_GEM_GPUVA undeclared on 7.3).
#
# Checks: (1) the shipping kernel has a tracked overlay whose vermagic equals the kernel version;
# (2) with no DKMS module the hook installs that exact file into updates/dkms and runs depmod;
# (3) an overlay built for the PREVIOUS kernel (real rc5 module under the rc6 name) is refused by the vermagic
# guard and nothing is installed; (4) a DKMS-built module is left alone.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="${NCZ_HOOK_UNDER_TEST:-$ROOT/post-install/83-panthor-gpu.sh}"
T="$(mktemp -d "${TMPDIR:-/var/tmp}/panthor83real.XXXXXX")"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }
command -v strings >/dev/null || { echo "SKIP: strings (binutils) not available"; exit 0; }

KV="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["kver"])' "$ROOT/assets/kernel/sky1-manifest.json")"
OVL="$ROOT/assets/kernel/panthor/$KV/panthor.ko"
vermagic_of() { strings -a "$1" | sed -n 's/^vermagic=\([^ ]*\).*/\1/p' | head -1; }

if [ -s "$OVL" ] && [ "$(vermagic_of "$OVL")" = "$KV" ]; then ok "shipping kernel $KV has a tracked overlay with matching vermagic"
else bad "no tracked panthor overlay with vermagic $KV at $OVL (found '$(vermagic_of "$OVL" 2>/dev/null)')"; echo "--- $pass passed, $fail failed"; exit 1; fi
git -C "$ROOT" ls-files --error-unmatch "assets/kernel/panthor/$KV/panthor.ko" >/dev/null 2>&1 \
    && ok "the overlay is tracked in git (a fresh clone has it)" || bad "the overlay is not tracked in git"

# mkbox <name> <module file to place at assets/kernel/panthor/$KV/panthor.ko> <dkms: none|xz>
mkbox() {
    local b="$T/$1" src="$2" mods="$3"
    local meta="$b/usr/local/lib/cix-installer" a
    a="$meta/assets/kernel/panthor"
    mkdir -p "$b/bin" "$a/$KV" "$meta/assets/cix-debs" "$b/usr/lib/modules/$KV/updates/dkms"
    echo "$KV" > "$meta/KVER_NEXT"
    cp "$ROOT/assets/kernel/panthor/dkms.conf" "$a/dkms.conf"
    cp "$src" "$a/$KV/panthor.ko"
    : > "$meta/assets/cix-debs/panthor-cix-dkms_7.2.0+ncz${NCZ_DKMS_DEB_REV:-2}_all.deb"
    [ "$mods" = xz ] && echo dkms-built > "$b/usr/lib/modules/$KV/updates/dkms/panthor.ko.xz"
    printf '#!/bin/sh\ncase "$1" in --print-architecture) echo arm64 ;; *) exit 0 ;; esac\n' > "$b/bin/dpkg"
    printf '#!/bin/sh\nexit 0\n' > "$b/bin/dkms"
    printf '#!/bin/sh\necho "$*" >> "%s/depmod.calls"\nexit 0\n' "$b" > "$b/bin/depmod"
    # modinfo -F vermagic FILE, answered from the module's own .modinfo
    printf '#!/bin/sh\nstrings -a "$3" | sed -n "s/^vermagic=//p" | head -1\n' > "$b/bin/modinfo"
    chmod +x "$b/bin/"*
    sed -E "s#(^|[^A-Za-z0-9_./\$-])/(etc|usr|var)/#\1$b/\2/#g" "$HOOK" > "$b/hook.sh"
}
run() { env -i PATH="$T/$1/bin:/usr/bin:/bin" NCZ_TARGET_ARCH=arm64 bash "$T/$1/hook.sh" >"$T/$1/out" 2>&1; echo $? > "$T/$1/rc"; }
DEST() { echo "$T/$1/usr/lib/modules/$KV/updates/dkms/panthor.ko"; }

# 2. DKMS produced nothing -> the real overlay lands, byte-identical, depmod ran, hook rc 0
mkbox real "$OVL" none; run real
if cmp -s "$OVL" "$(DEST real)" && [ "$(cat "$T/real/rc")" = 0 ] && grep -q "$KV" "$T/real/depmod.calls" \
   && grep -q "installed vermagic-matched prebuilt Panthor for $KV" "$T/real/out"; then
    ok "fallback executed: real $KV overlay installed byte-identical, depmod -a $KV ran"
else bad "fallback did not install the real overlay"; cat "$T/real/out"; fi

# 3. the PREVIOUS kernel's real module under this kernel's name -> vermagic guard refuses
PREV=""
for d in "$ROOT"/assets/kernel/panthor/7.3.0-rc5-sky1-ncz "$ROOT"/assets/kernel/panthor/7.3.0-rc4-sky1-ncz; do
    [ -s "$d/panthor.ko" ] && [ "$(basename "$d")" != "$KV" ] && { PREV="$d/panthor.ko"; break; }
done
if [ -n "$PREV" ]; then
    mkbox stale "$PREV" none; run stale
    if [ ! -s "$(DEST stale)" ] && grep -q "REFUSE" "$T/stale/out" && grep -q "WARN: no DKMS-built and no prebuilt" "$T/stale/out"; then
        ok "real overlay from another kernel ($(vermagic_of "$PREV")) is refused by the vermagic guard"
    else bad "wrong-kernel real overlay was not refused"; cat "$T/stale/out"; fi
else echo "SKIP: no older real panthor overlay to use as the wrong-kernel module"; fi

# 4. DKMS built a module -> the overlay is not added next to it
mkbox dkms "$OVL" xz; run dkms
if [ ! -s "$(DEST dkms)" ] && grep -q "already present" "$T/dkms/out"; then ok "DKMS-built module present: overlay left alone"
else bad "overlay installed next to a DKMS module"; cat "$T/dkms/out"; fi

echo "--- $pass passed, $fail failed"
[ "$fail" -eq 0 ]
