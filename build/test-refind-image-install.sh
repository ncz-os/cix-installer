#!/bin/bash
# shellcheck disable=SC2016,SC1090,SC1091,SC2329
# test-refind-image-install.sh -- image-level regression tests for the rEFInd
# kernel-install path (2026-11-02).
#
# The NCZ-OS amd64 image used to install a refresh tool with no --add mode and
# a zz1 hook that ran it bare, so every kernel install WIPED the ESP and
# rebuilt the menu -- which made the newly installed kernel the DEFAULT on the
# next reboot (proven on CHIMERA and PEGASUS, 2026-11-02). This test asserts
# the IMAGE-LEVEL contract that replaces it:
#
#   A. 70-bootloader.sh installs BOTH hooks (zz1 add-only, zz2 promote guard)
#      and still runs the generator once, with NO verb, for the first install.
#   C. zz1, run as a postinst.d hook against a fixture ESP, is ADD-ONLY:
#      it appends one entry, stages the pair, and leaves default_selection
#      byte-identical.
#   D. zz2 with no operator pin does NOT touch default_selection.
#   E. zz2 WITH a pin calls --promote and moves only default_selection.
#
# Every ESP is a fixture tree under mktemp -d in $TMPDIR. Nothing is built,
# installed or booted.
#
# Usage:  bash build/test-refind-image-install.sh
# Exit 0 = all cases passed; 1 = at least one failed.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  PASS  $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL  $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'; }

BOOTLOADER="$REPO/post-install/70-bootloader.sh"
ZZ1="$REPO/assets/refind/zz1-ncz-refind-refresh-amd64"
ZZ2="$REPO/assets/refind/zz2-ncz-refind-promote-guard"
TOOL_SRC="$REPO/assets/refind/ncz-refind-refresh-amd64.sh"

for f in "$BOOTLOADER" "$ZZ1" "$ZZ2" "$TOOL_SRC"; do
    [ -r "$f" ] || { echo "  FAIL  required image asset missing: $f"; echo; echo "refind image-install tests: 0 passed, 1 failed"; exit 1; }
done

OLD_KVER="7.3.0-rc7-t2-ncz"
NEW_KVER="7.3.0-rc8-t2-ncz"

echo "=== post-install/70-bootloader.sh ==="
if grep -q 'zz1-ncz-refind-refresh-amd64' "$BOOTLOADER" \
   && grep -q 'zz2-ncz-refind-promote-guard' "$BOOTLOADER"; then
    ok "A1) 70-bootloader.sh installs zz1 (add-only) and zz2 (promote guard)"
else
    bad "A1) 70-bootloader.sh installs zz1 (add-only) and zz2 (promote guard)" \
        "$(grep -n 'zz[12]-' "$BOOTLOADER")"
fi
if awk '/export KVER_STABLE/ { inblock=1 } inblock && /"\$SHARED_DST"/ { print; exit }' "$BOOTLOADER" \
   | grep -qE '"\$SHARED_DST"[[:space:]]*$'; then
    ok "A2) the install-time generator is still called without a verb (first install)"
else
    bad "A2) the install-time generator is still called without a verb (first install)" \
        "$(grep -n 'SHARED_DST' "$BOOTLOADER")"
fi

# A3: the hooks are self-contained. dpkg runs /etc/kernel/postinst.d/* directly,
# so each needs its own shebang, and zz1 must not depend on BOOTDIR being
# exported to it -- it defaults it. A missing default would make the
# KVER_STABLE_SRC/INITRD paths "/vmlinuz-..." and every add would fail.
_a3_bad=""
for _h in "$ZZ1" "$ZZ2"; do
    head -1 "$_h" | grep -q '^#!/bin/bash' || _a3_bad="$_a3_bad $(basename "$_h"):no-shebang"
done
grep -qE '^BOOTDIR="\$\{BOOTDIR:-/boot\}"' "$ZZ1" || _a3_bad="$_a3_bad zz1:no-BOOTDIR-default"
grep -qE '\$BOOTDIR/vmlinuz-' "$ZZ1" || _a3_bad="$_a3_bad zz1:BOOTDIR-unused"
if [ -z "$_a3_bad" ]; then
    ok "A4) both hooks have a shebang and zz1 defaults BOOTDIR to /boot"
else
    bad "A4) both hooks have a shebang and zz1 defaults BOOTDIR to /boot" "$_a3_bad"
fi

# A4: 70-bootloader.sh installs the hooks 0755, so a hook that is not a program
# cannot slip through by source mode alone.
if grep -qE 'install -D -m 0755 "\$HOOK_SRC"' "$BOOTLOADER"; then
    ok "A5) 70-bootloader.sh installs each hook mode 0755"
else
    bad "A5) 70-bootloader.sh installs each hook mode 0755" \
        "$(grep -n 'HOOK_SRC' "$BOOTLOADER")"
fi
if ! grep -qE '"\$SHARED_DST" +--(add|promote)' "$BOOTLOADER"; then
    ok "A3) the first-install path never uses --add/--promote"
else
    bad "A3) the first-install path never uses --add/--promote" \
        "$(grep -nE '\$SHARED_DST .*--' "$BOOTLOADER")"
fi

echo "=== hooks against a fixture ESP ==="
w="$(mktemp -d "${TMPDIR:-/var/tmp}/ncz-img-install.XXXXXX")" || { echo "FATAL: mktemp" >&2; exit 1; }
trap 'rm -rf "$w"' EXIT

mkdir -p "$w/lib" "$w/sbin" "$w/boot"
cp -f "$REPO/release.conf" "$w/lib/RELEASE"
sed "s#^INSTALLER_META=.*#INSTALLER_META=$w/lib#" "$TOOL_SRC" > "$w/sbin/tool.sh"
chmod +x "$w/sbin/tool.sh"
printf 'vmlinuz-%s\n' "$NEW_KVER" > "$w/boot/vmlinuz-$NEW_KVER"
printf 'initrd-%s\n' "$NEW_KVER"  > "$w/boot/initrd.img-$NEW_KVER"

mkesp() {
    local d="$1"; shift; local k
    rm -rf "$d"; mkdir -p "$d/EFI/BOOT"
    {
        printf 'timeout 10\n'
        printf 'default_selection "NCZ-OS 26.10 Cygnus  -  7.3 (Default)"\n\n'
        for k in "$@"; do
            printf 'menuentry "NCZ-OS 26.10 Cygnus  -  7.3 Kernel %s" {\n' "$k"
            printf '    loader  /vmlinuz-%s\n' "$k"
            printf '    initrd  /initrd.img-%s\n' "$k"
            printf '    options "root=PARTUUID=x"\n}\n\n'
            printf 'payload-%s\n' "$k" > "$d/vmlinuz-$k"
            printf 'payload-%s\n' "$k" > "$d/initrd.img-$k"
        done
    } > "$d/EFI/BOOT/refind.conf"
}
sha() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }
reroot_hook() { sed -e "s#^REFRESH=.*#REFRESH=$w/sbin/tool.sh#" -e "s#/etc/ncz/#$w/etc/ncz/#g" "$1"; }

mkesp "$w/esp" "$OLD_KVER"
cp -f "$w/esp/EFI/BOOT/refind.conf" "$w/conf.before"
old_v_sha="$(sha "$w/esp/vmlinuz-$OLD_KVER")"
before_default="$(sed -n 's/^default_selection //p' "$w/conf.before" | head -1)"
reroot_hook "$ZZ1" > "$w/zz1.sh"
NCZ_ESP_DIR="$w/esp" BOOTDIR="$w/boot" NCZ_SERIAL_CONSOLE=off \
    bash "$w/zz1.sh" "$NEW_KVER" "$w/boot/vmlinuz-$NEW_KVER" > "$w/zz1.log" 2>&1
rc=$?
after_default="$(sed -n 's/^default_selection //p' "$w/esp/EFI/BOOT/refind.conf" | head -1)"
new_entries="$(grep -c "^menuentry .*$NEW_KVER" "$w/esp/EFI/BOOT/refind.conf" 2>/dev/null || echo 0)"
if [ "$rc" = 0 ] && [ "$new_entries" = 1 ] && [ -s "$w/esp/vmlinuz-$NEW_KVER" ] \
   && [ -s "$w/esp/initrd.img-$NEW_KVER" ]; then
    ok "C1) zz1 stages the new pair and appends exactly one entry"
else
    bad "C1) zz1 stages the new pair and appends exactly one entry" \
        "$(printf 'rc=%s entries=%s\n' "$rc" "$new_entries"; ls -1 "$w/esp"; cat "$w/zz1.log")"
fi
if [ "$before_default" = "$after_default" ] \
   && [ "$(sha "$w/esp/vmlinuz-$OLD_KVER")" = "$old_v_sha" ]; then
    ok "C2) zz1 leaves default_selection byte-identical and the old kernel intact"
else
    bad "C2) zz1 leaves default_selection byte-identical and the old kernel intact" \
        "$(printf 'default: %s -> %s\n' "$before_default" "$after_default"; cat "$w/zz1.log")"
fi
NCZ_ESP_DIR="$w/esp" BOOTDIR="$w/boot" NCZ_SERIAL_CONSOLE=off \
    bash "$w/zz1.sh" "$NEW_KVER" "$w/boot/vmlinuz-$NEW_KVER" > "$w/zz1b.log" 2>&1
still="$(grep -c "^menuentry .*$NEW_KVER" "$w/esp/EFI/BOOT/refind.conf" 2>/dev/null || echo 0)"
if [ "$still" = 1 ]; then
    ok "C3) a repeated kernel install (zz1 re-run) does not duplicate the entry"
else
    bad "C3) a repeated kernel install (zz1 re-run) does not duplicate the entry" \
        "$(printf 'entries=%s\n' "$still"; cat "$w/zz1b.log")"
fi

reroot_hook "$ZZ2" > "$w/zz2.sh"
cp -f "$w/esp/EFI/BOOT/refind.conf" "$w/conf.nopin"
NCZ_ESP_DIR="$w/esp" NCZ_SERIAL_CONSOLE=off \
    bash "$w/zz2.sh" "$NEW_KVER" "$w/boot/vmlinuz-$NEW_KVER" > "$w/zz2.log" 2>&1
rc=$?
if [ "$rc" = 0 ] && cmp -s "$w/conf.nopin" "$w/esp/EFI/BOOT/refind.conf"; then
    ok "D1) zz2 without an operator pin does not touch default_selection"
else
    bad "D1) zz2 without an operator pin does not touch default_selection" \
        "$(printf 'rc=%s\n' "$rc"; diff "$w/conf.nopin" "$w/esp/EFI/BOOT/refind.conf"; cat "$w/zz2.log")"
fi

mkdir -p "$w/etc/ncz"
printf '%s\n' "$NEW_KVER" > "$w/etc/ncz/refind-default-token"
cp -f "$w/esp/EFI/BOOT/refind.conf" "$w/conf.pinned"
NCZ_ESP_DIR="$w/esp" NCZ_SERIAL_CONSOLE=off \
    bash "$w/zz2.sh" "$NEW_KVER" "$w/boot/vmlinuz-$NEW_KVER" > "$w/zz2p.log" 2>&1
rc=$?
diff <(grep -v '^default_selection' "$w/conf.pinned") \
     <(grep -v '^default_selection' "$w/esp/EFI/BOOT/refind.conf") >/dev/null 2>&1
rest_same=$?
if [ "$rc" = 0 ] && [ "$rest_same" = 0 ] \
   && grep -q "^default_selection .*$NEW_KVER" "$w/esp/EFI/BOOT/refind.conf"; then
    ok "E1) zz2 with a pin changes only the default_selection line"
else
    bad "E1) zz2 with a pin changes only the default_selection line" \
        "$(printf 'rc=%s rest=%s\n' "$rc" "$rest_same"; grep default_selection "$w/esp/EFI/BOOT/refind.conf"; cat "$w/zz2p.log")"
fi
printf 'no-such-title\n' > "$w/etc/ncz/refind-default-token"
cp -f "$w/esp/EFI/BOOT/refind.conf" "$w/conf.stale"
NCZ_ESP_DIR="$w/esp" NCZ_SERIAL_CONSOLE=off \
    bash "$w/zz2.sh" "$NEW_KVER" "$w/boot/vmlinuz-$NEW_KVER" > "$w/zz2s.log" 2>&1
if cmp -s "$w/conf.stale" "$w/esp/EFI/BOOT/refind.conf"; then
    ok "E2) a stale pin is refused and the menu is unchanged"
else
    bad "E2) a stale pin is refused and the menu is unchanged" \
        "$(diff "$w/conf.stale" "$w/esp/EFI/BOOT/refind.conf"; cat "$w/zz2s.log")"
fi

echo
echo "refind image-install tests: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
