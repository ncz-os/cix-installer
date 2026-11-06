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
#      The hooks must pass their verb POSITIONALLY (--add / --promote "<title>"):
#      the tool derives NCZ_VERB from $1 and ignores the environment, so a hook
#      that set NCZ_VERB and called the tool bare would run the GENERATE path
#      and wipe the ESP on every kernel install. A6/A7 pin that contract.
#   C. zz1, run as a postinst.d hook against a fixture ESP, is ADD-ONLY:
#      it appends one entry, stages the pair, and leaves default_selection
#      byte-identical. C4 pins that the appended entry's reused options still
#      carry a valid root= (--add never probes the root filesystem itself);
#      C5/C6 pin that zz1 REFUSES, leaving the menu byte-identical, when the
#      live options hold no usable root= to reuse.
#   D. zz2 with no operator pin does NOT touch default_selection.
#   E. zz2 WITH a pin calls --promote and moves only default_selection.
#
# Entries are counted with `grep '^menuentry ' | grep -cF -- "$kver"`: a kver
# contains dots, so an unescaped regex would match a look-alike kernel id.
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
   | grep -E  '"\$SHARED_DST"[[:space:]]*$' >/dev/null; then
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
    head -1 "$_h" | grep  '^#!/bin/bash' >/dev/null || _a3_bad="$_a3_bad $(basename "$_h"):no-shebang"
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
# A5b: the hook SOURCES must be executable in git too (mode 100755), not only
# at install time. A 100644 source still works when install(1) stamps 0755,
# but it cannot be run straight from a checkout -- which is how these hooks
# are exercised and debugged -- and a bare `grep install` cannot tell the
# difference. Check the recorded mode in the index.
_mode_bad=""
for _h in "$ZZ1" "$ZZ2"; do
    _m=$(cd "$REPO" && git ls-files -s -- "$_h" 2>/dev/null | awk '{ print $1 }')
    [ "$_m" = "100755" ] || _mode_bad="$_mode_bad $(basename "$_h"):${_m:-untracked}"
done
if [ -z "$_mode_bad" ]; then
    ok "A5b) both hook sources are mode 100755 in git"
else
    bad "A5b) both hook sources are mode 100755 in git" "$_mode_bad"
fi

# A8: write-usb-image.py's required_refind is a FLAT tuple of bare filenames,
# not (filename, script) pairs. A review reported that adding zz2 "breaks the
# two-element structure used later when the tuple is unpacked"; there is no
# such unpacking -- its only consumers are an existence scan and list(). Pin
# the real shape: evaluate the expression for both arches and assert every
# element is a str and that no element is itself a tuple.
USB_PY="$REPO/build/iso/write-usb-image.py"
_utup=$(python3 - "$USB_PY" <<'PYEOF' 2>&1
import ast, sys
src = open(sys.argv[1]).read()
node = None
for n in ast.walk(ast.parse(src)):
    if isinstance(n, ast.Assign) and any(getattr(t, "id", "") == "required_refind"
                                         for t in n.targets):
        node = n.value
        break
if node is None:
    print("required_refind not found"); raise SystemExit(1)
# Walk the IfExp and literal tuples: every element must be a literal str.
bad = []
for n in ast.walk(node):
    if isinstance(n, ast.Tuple):
        for el in n.elts:
            if isinstance(el, ast.Tuple):
                bad.append("nested-tuple")
            elif isinstance(el, ast.Constant) and not isinstance(el.value, str):
                bad.append(f"non-str:{el.value!r}")
            elif not isinstance(el, ast.Constant):
                bad.append(eval(compile(ast.Expression(el), "<el>", "eval"), {}))
print(",".join(bad) if bad else "OK")
PYEOF
)
if [ "$_utup" = "OK" ]; then
    ok "A8) required_refind is a flat tuple of filenames (no (name, script) pairs)"
else
    bad "A8) required_refind is a flat tuple of filenames (no (name, script) pairs)" "$_utup"
fi
# A8b: and the names it demands must exist, so staging cannot fail at build
# time -- this is what makes "add the hook to the tuple" sufficient.
_miss=""
for _n in refind_x64.efi ncz-refind-refresh-amd64.sh \
          zz1-ncz-refind-refresh-amd64 zz2-ncz-refind-promote-guard; do
    [ -f "$REPO/assets/refind/$_n" ] || _miss="$_miss $_n"
done
if [ -z "$_miss" ]; then
    ok "A8b) every amd64 name in required_refind exists under assets/refind"
else
    bad "A8b) every amd64 name in required_refind exists under assets/refind" "$_miss"
fi

# A9: no `\s` inside a `grep -E` pattern in these suites. `\s` is a GNU/PCRE
# extension, not POSIX ERE: a strict ERE engine reads it as a literal 's', so
# an anchored pattern would silently stop matching (a false NEGATIVE that looks
# like a real regression) or match the wrong line. Use [[:space:]]. This suite
# lives on the validation path, so it must not depend on GNU grep.
_sbad=""
for _t in "$SCRIPT_DIR/test-refind-image-install.sh" \
          "$SCRIPT_DIR/test-refind-addonly.sh"; do
    # Only real command lines: start of line (optional indent) with `grep`,
    # and skip this check's own source line.
    _hit=$(grep -nE '^[[:space:]]*(if[[:space:]]+|!?[[:space:]]*)?grep[[:space:]]+-[a-zA-Z]*E[[:space:]]' "$_t" 2>/dev/null \
           | grep -F -- '\s' | grep -vF '_hit=' | head -3)
    [ -z "$_hit" ] || _sbad="$_sbad $(basename "$_t"):${_hit}"
done
if [ -z "$_sbad" ]; then
    ok "A9) no \\s in grep -E (POSIX ERE uses [[:space:]])"
else
    bad "A9) no \\s in grep -E (POSIX ERE uses [[:space:]])" "$_sbad"
fi
if ! grep -qE '"\$SHARED_DST" +--(add|promote)' "$BOOTLOADER"; then
    ok "A3) the first-install path never uses --add/--promote"
else
    bad "A3) the first-install path never uses --add/--promote" \
        "$(grep -nE '\$SHARED_DST .*--' "$BOOTLOADER")"
fi

# A6/A7: the hooks must pass their verb to the tool POSITIONALLY ("$REFRESH"
# --add / --promote "<title>"). The tool parses $1 (NCZ_VERB is derived from
# it, not read from the environment), so a hook that set NCZ_VERB=<verb> and
# called the tool bare would silently run the GENERATE path instead -- wiping
# the ESP and rebuilding the menu on every kernel install, which is the exact
# defect the add-only design exists to prevent. Pin the call shape here so a
# future edit cannot regress it, and pin that no hook relies on the env var.
_verb_bad=""
grep -qE '^[[:space:]]*"\$REFRESH" --add[[:space:]]*$' "$ZZ1" || _verb_bad="$_verb_bad zz1:no-positional---add"
grep -qE '^[[:space:]]*"\$REFRESH" --promote "\$TOKEN"[[:space:]]*$' "$ZZ2" || _verb_bad="$_verb_bad zz2:no-positional---promote"
# A hook must never export NCZ_VERB: the tool ignores it, so setting it would
# only create the illusion of selecting a verb.
if grep -qE '^[[:space:]]*(export[[:space:]]+)?NCZ_VERB=' "$ZZ1" "$ZZ2"; then
    _verb_bad="$_verb_bad hook-sets-NCZ_VERB"
fi
if [ -z "$_verb_bad" ]; then
    ok "A6) zz1/zz2 pass --add/--promote positionally (not via NCZ_VERB)"
else
    bad "A6) zz1/zz2 pass --add/--promote positionally (not via NCZ_VERB)" "$_verb_bad"
fi
# A7: the tool derives its verb from $1, so the contract above is the only
# thing that makes the hooks work. Assert the parse exists rather than assume.
if grep -qE '^[[:space:]]*--add\)[[:space:]]*NCZ_VERB=add' "$TOOL_SRC" \
   && grep -qE '^[[:space:]]*--promote\)[[:space:]]*NCZ_VERB=promote' "$TOOL_SRC"; then
    ok "A7) the tool parses --add/--promote from \$1 into NCZ_VERB"
else
    bad "A7) the tool parses --add/--promote from \$1 into NCZ_VERB" \
        "$(grep -n 'NCZ_VERB=' "$TOOL_SRC" | head -6)"
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
new_entries="$(grep '^menuentry ' "$w/esp/EFI/BOOT/refind.conf" 2>/dev/null | grep -cF -- "$NEW_KVER" || true)"
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
still="$(grep '^menuentry ' "$w/esp/EFI/BOOT/refind.conf" 2>/dev/null | grep -cF -- "$NEW_KVER" || true)"
if [ "$still" = 1 ]; then
    ok "C3) a repeated kernel install (zz1 re-run) does not duplicate the entry"
else
    bad "C3) a repeated kernel install (zz1 re-run) does not duplicate the entry" \
        "$(printf 'entries=%s\n' "$still"; cat "$w/zz1b.log")"
fi

# C4: the entry zz1 appended must carry a usable root=. --add does NOT probe
# the root filesystem (that is generate-only, and probing it from a kernel
# postinst is slow and wrong); it reuses the live menu's options verbatim. If
# that reuse were dropped the entry would have no root= and the kernel could
# never mount the root filesystem -- a boot entry that looks fine and is dead.
_added_opts="$(awk -v k="$NEW_KVER" '
        /^menuentry / { inentry = 0 }
        /^menuentry .*7\.3 Kernel / && index($0, k) > 0 { inentry = 1 }
        inentry && /^[[:space:]]*options[[:space:]]+"/ {
            line = $0
            sub(/^[[:space:]]*options[[:space:]]+"/, "", line)
            sub(/"[[:space:]]*$/, "", line)
            print line; exit
        }' "$w/esp/EFI/BOOT/refind.conf")"
if [ -n "$_added_opts" ] \
   && printf '%s\n' "$_added_opts" | grep -E  '(^|[[:space:]])root=PARTUUID=[^[:space:]]+' >/dev/null; then
    ok "C4) the appended entry carries a valid root=PARTUUID= (no probe needed)"
else
    bad "C4) the appended entry carries a valid root=PARTUUID= (no probe needed)" \
        "$(printf 'options=<%s>\n' "$_added_opts"; grep -A5 "^menuentry .*$NEW_KVER" "$w/esp/EFI/BOOT/refind.conf"; cat "$w/zz1.log")"
fi

# C5: ...and when the live menu has NO usable root= to reuse, zz1 must REFUSE
# rather than append an entry that cannot boot. The ESP must be untouched.
mkesp "$w/esp-c5" "$OLD_KVER"
sed -i 's#options "root=PARTUUID=x"#options "quiet splash"#' "$w/esp-c5/EFI/BOOT/refind.conf"
cp -f "$w/esp-c5/EFI/BOOT/refind.conf" "$w/conf.c5"
NCZ_ESP_DIR="$w/esp-c5" BOOTDIR="$w/boot" NCZ_SERIAL_CONSOLE=off \
    bash "$w/zz1.sh" "$NEW_KVER" "$w/boot/vmlinuz-$NEW_KVER" > "$w/zz1c5.log" 2>&1
rc=$?
if grep -q 'names no usable root=' "$w/zz1.log" 2>/dev/null || \
   grep -q 'names no usable root=' "$w/zz1c5.log"; then
    ok "C5) zz1 refuses to append an entry whose reused options have no root="
else
    bad "C5) zz1 refuses to append an entry whose reused options have no root=" \
        "$(cat "$w/zz1c5.log")"
fi
if cmp -s "$w/conf.c5" "$w/esp-c5/EFI/BOOT/refind.conf"; then
    ok "C6) ...and leaves that menu byte-identical when it refuses"
else
    bad "C6) ...and leaves that menu byte-identical when it refuses" \
        "$(diff "$w/conf.c5" "$w/esp-c5/EFI/BOOT/refind.conf")"
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
# E3: ...and the refusal must NOT fail the kernel install. zz2 runs from
# /etc/kernel/postinst.d, so a non-zero exit fails the linux-image package's
# dpkg configuration. A stale operator pin is not a broken system: the
# machine is bootable and the menu is untouched, so zz2 must exit 0 while
# reporting the refusal loudly. (zz1 does the same for a failed --add.)
rc_stale=0
NCZ_ESP_DIR="$w/esp" NCZ_SERIAL_CONSOLE=off \
    bash "$w/zz2.sh" "$NEW_KVER" "$w/boot/vmlinuz-$NEW_KVER" > "$w/zz2s2.log" 2>&1 || rc_stale=$?
if [ "$rc_stale" = 0 ] && cmp -s "$w/conf.stale" "$w/esp/EFI/BOOT/refind.conf"; then
    ok "E3) a stale pin exits 0 (a kernel install is never failed by the guard)"
else
    bad "E3) a stale pin exits 0 (a kernel install is never failed by the guard)" \
        "$(printf 'rc=%s\n' "$rc_stale"; cat "$w/zz2s2.log")"
fi
# E4: the refusal must still be LOUD -- silently swallowing it would leave
# the operator believing the pin is honoured when it is not.
if grep -q -- '--promote failed' "$w/zz2s2.log"; then
    ok "E4) a refused promote is reported loudly (the operator is told)"
else
    bad "E4) a refused promote is reported loudly (the operator is told)" \
        "$(cat "$w/zz2s2.log")"
fi

echo
echo "refind image-install tests: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
