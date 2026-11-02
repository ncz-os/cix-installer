#!/bin/bash
# shellcheck disable=SC2016,SC1090,SC1091,SC2329  # literal $ in generated code; non-constant source
# test-refind-addonly.sh -- regression tests for the add-only rEFInd kernel
# hook (2026-11-02).
#
# WHY THIS EXISTS
# Until 2026-11-02 the amd64 image shipped a refresh tool with NO modes: every
# run WIPED the ESP and regenerated the whole menu, and /etc/kernel/postinst.d/
# zz1 ran it on every kernel install. Installing any newer kernel therefore
# made that kernel the DEFAULT on the next reboot. Proven live on CHIMERA and
# PEGASUS on 2026-11-02 (see the INSTALL-REPORT.md in each host's ESP backup).
#
# The tool now has three verbs:
#   (none)     install-time generation -- UNCHANGED, still wipes and writes the
#              first-install menu. Only post-install/70-bootloader.sh calls it.
#   --add      the hook path: STAGES the new /boot pair onto the ESP (never
#              overwriting a file already there) and APPENDS one menuentry.
#   --promote  rewrite ONLY default_selection; the zz2 guard calls it.
#
# These cases run the REAL shipped script against a fixture ESP tree under
# mktemp -d in $TMPDIR (NCZ_ESP_DIR points the tool at the fixture):
#   1. install-time generate still writes the menu (Default entry present);
#   2. --add appends exactly one entry, stages both files, and leaves
#      default_selection byte-identical;
#   3. --add never wipes: a pre-existing kernel pair and its entry survive;
#   4. --add refuses when the new pair is not in /boot (ESP left untouched);
#   5. --add refuses a Debian-archive kernel name (7.3 policy);
#   6. --promote changes only the default_selection line;
#   7. --promote refuses a title that matches no entry;
#   8. an unknown verb is misuse (rc=2), not a wipe.
#
# Usage:
#   bash build/test-refind-addonly.sh                 # the shipped amd64 script
#   bash build/test-refind-addonly.sh <script> [...]  # explicit script(s)
# The explicit form accepts the PRE-FIX script, where cases 2-8 must FAIL
# (the pre-fix tool has no --add and wipes the ESP on every run), proving the
# tests are meaningful:
#   git show <base>:assets/refind/ncz-refind-refresh-amd64.sh > /tmp/old.sh
#   bash build/test-refind-addonly.sh /tmp/old.sh
#
# Exit 0 = all cases passed; 1 = at least one failed; 2 = a source file is
# missing.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ "$#" -gt 0 ]; then
    SOURCES=("$@")
else
    SOURCES=("$REPO/assets/refind/ncz-refind-refresh-amd64.sh")
fi

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  PASS  $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL  $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'; }

OLD_KVER="7.3.0-rc7-t2-ncz"     # kernel already on the ESP
NEW_KVER="7.3.0-rc8-t2-ncz"     # kernel being installed

# A complete /boot + ESP pair for one kver. $boot is the fake /boot the tool's
# KVER_STABLE_SRC/KVER_STABLE_INITRD point at; $esp is the fixture ESP.
mkboot() { printf 'vmlinuz-payload-%s\n' "$2" > "$1/vmlinuz-$2"; printf 'initrd-payload-%s\n' "$2" > "$1/initrd.img-$2"; }
mkesp()  # mkesp <esp-dir> <kver>...  (each gets a kernel pair + menu entry)
{
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

run_for_source() {
    local src="$1"
    echo "=== $(basename "$src") ==="
    if [ ! -r "$src" ]; then
        bad "$(basename "$src") is readable" "cannot read $src"
        return
    fi
    local w
    w="$(mktemp -d "${TMPDIR:-/var/tmp}/ncz-addonly.XXXXXX")" || { bad "mktemp"; return; }
    # The tool hardcodes INSTALLER_META; point it at the fixture so the rescue
    # / COMPONENTS preflight reads the test tree and nothing on the host.
    mkdir -p "$w/lib"
    # The tool reads the release identity from $INSTALLER_META/RELEASE; use the
    # repo's real release.conf so the fixture is branded exactly like a build.
    cp -f "$REPO/release.conf" "$w/lib/RELEASE"
    sed "s#^INSTALLER_META=.*#INSTALLER_META=$w/lib#" "$src" > "$w/tool.sh"
    chmod +x "$w/tool.sh"
    bash -n "$w/tool.sh" || { bad "$(basename "$src") parses" "$(bash -n "$w/tool.sh" 2>&1)"; rm -rf "$w"; return; }

    mkdir -p "$w/boot"
    mkboot "$w/boot" "$NEW_KVER"
    # The tool always needs KVER_STABLE for the install path; --add reads the
    # pair from KVER_STABLE_SRC/INITRD.
    TOOL=(env NCZ_SERIAL_CONSOLE=off bash "$w/tool.sh")

    # ---- 1: install-time generate still writes a menu -----------------------
    # NCZ_ESP_DIR points the tool at the fixture. generate writes
    # /etc/kernel/install.conf and requires /boot/efi to be a mounted vfat, so
    # this case can only run as root; otherwise it is SKIPped (the generate
    # path is exercised end-to-end by the image tests and by every install).
    mkesp "$w/esp1"
    if [ "$(id -u)" = "0" ] && findmnt -no FSTYPE /boot/efi >/dev/null 2>&1; then
        NCZ_ESP_DIR="$w/esp1" KVER_STABLE="$NEW_KVER" NCZ_SERIAL_CONSOLE=off bash "$w/tool.sh" \
            >"$w/s1.log" 2>&1
        if grep -q '^menuentry ' "$w/esp1/EFI/BOOT/refind.conf" 2>/dev/null; then
            ok "1) install-time generate still writes a menu"
        else
            bad "1) install-time generate still writes a menu" "$(cat "$w/s1.log")"
        fi
    else
        echo "  SKIP  1) install-time generate still writes a menu (needs root + a mounted /boot/efi)"
    fi

    # ---- 2 + 3: --add appends one entry, stages, never wipes ----------------
    mkesp "$w/esp" "$OLD_KVER"
    cp -f "$w/esp/EFI/BOOT/refind.conf" "$w/conf.before"
    old_v_sha="$(sha "$w/esp/vmlinuz-$OLD_KVER")"
    old_default="$(sed -n 's/^default_selection //p' "$w/conf.before" | head -1)"
    NCZ_ESP_DIR="$w/esp" KVER_STABLE="$NEW_KVER" \
        KVER_STABLE_SRC="$w/boot/vmlinuz-$NEW_KVER" \
        KVER_STABLE_INITRD="$w/boot/initrd.img-$NEW_KVER" \
        NCZ_SERIAL_CONSOLE=off bash "$w/tool.sh" --add >"$w/s2.log" 2>&1
    rc=$?
    new_default="$(sed -n 's/^default_selection //p' "$w/esp/EFI/BOOT/refind.conf" | head -1)"
    added="$(grep -c "^menuentry .*$NEW_KVER" "$w/esp/EFI/BOOT/refind.conf" 2>/dev/null || echo 0)"
    if [ "$rc" = 0 ] && [ "$added" = 1 ] \
       && [ -s "$w/esp/vmlinuz-$NEW_KVER" ] && [ -s "$w/esp/initrd.img-$NEW_KVER" ]; then
        ok "2) --add stages the new pair and appends exactly one entry (rc=0)"
    else
        bad "2) --add stages the new pair and appends exactly one entry (rc=0)" \
            "$(printf 'rc=%s added=%s\n' "$rc" "$added"; ls -1 "$w/esp"; cat "$w/s2.log")"
    fi
    if [ "$rc" = 0 ] && [ -n "$old_default" ] && [ "$new_default" = "$old_default" ] \
       && [ "$(sha "$w/esp/vmlinuz-$OLD_KVER")" = "$old_v_sha" ]; then
        ok "3) --add leaves default_selection and the old kernel untouched (no wipe)"
    else
        bad "3) --add leaves default_selection and the old kernel untouched (no wipe)" \
            "$(printf 'default: %s -> %s\n' "$old_default" "$new_default"; ls -1 "$w/esp"; cat "$w/s2.log")"
    fi

    # ---- 4: missing /boot pair is a refusal, ESP untouched ------------------
    mkesp "$w/esp4" "$OLD_KVER"
    cp -f "$w/esp4/EFI/BOOT/refind.conf" "$w/conf4.before"
    MISSING="7.3.0-rc9-absent"
    NCZ_ESP_DIR="$w/esp4" KVER_STABLE="$MISSING" NCZ_SERIAL_CONSOLE=off bash "$w/tool.sh" --add \
        >"$w/s4.log" 2>&1
    rc=$?
    if [ "$rc" = 1 ] && grep -q 'no complete kernel pair' "$w/s4.log" \
       && cmp -s "$w/conf4.before" "$w/esp4/EFI/BOOT/refind.conf" \
       && [ ! -e "$w/esp4/vmlinuz-$MISSING" ]; then
        ok "4) --add refuses a kernel with no /boot pair; ESP left byte-identical"
    else
        bad "4) --add refuses a kernel with no /boot pair; ESP left byte-identical" \
            "$(printf 'rc=%s\n' "$rc"; ls -1 "$w/esp4"; cat "$w/s4.log")"
    fi

    # ---- 5: Debian-archive kernel name is refused --------------------------
    mkesp "$w/esp5" "$OLD_KVER"
    cp -f "$w/esp5/EFI/BOOT/refind.conf" "$w/conf5.before"
    NCZ_ESP_DIR="$w/esp5" KVER_STABLE="6.1.0-13-amd64" NCZ_SERIAL_CONSOLE=off bash "$w/tool.sh" --add \
        >"$w/s5.log" 2>&1
    rc=$?
    if [ "$rc" = 1 ] && grep -q 'Debian-archive kernel' "$w/s5.log" \
       && cmp -s "$w/conf5.before" "$w/esp5/EFI/BOOT/refind.conf"; then
        ok "5) --add refuses a Debian-archive kernel (7.3 policy); ESP untouched"
    else
        bad "5) --add refuses a Debian-archive kernel (7.3 policy); ESP untouched" \
            "$(printf 'rc=%s\n' "$rc"; cat "$w/s5.log")"
    fi

    # ---- 5b: a pair THIS tool staged is recognised and refreshed ------------
    # The staging record written by --add must be readable by the tool itself.
    # Regression: the record is "<kver>/<vmlinuz-sha>/<initrd-sha>", so the
    # reader must compare all three fields; comparing only "<sha_v>/<sha_i>"
    # makes every staged kernel look foreign, and the add-only path then
    # REFUSES to refresh it (and reports it as not staged). Sequence: stage,
    # then change the /boot payload for the same kver, then re-add: the ESP
    # copy must be refreshed to the new /boot bytes, rc=0, and no second
    # menuentry may be appended.
    mkesp "$w/esp5b" "$OLD_KVER"
    run5b() {
        NCZ_ESP_DIR="$w/esp5b" KVER_STABLE="$NEW_KVER" \
            KVER_STABLE_SRC="$w/boot/vmlinuz-$NEW_KVER" \
            KVER_STABLE_INITRD="$w/boot/initrd.img-$NEW_KVER" \
            NCZ_SERIAL_CONSOLE=off bash "$w/tool.sh" --add
    }
    run5b >"$w/s5b-a.log" 2>&1; rc_a=$?
    # Change ONLY the vmlinuz payload in /boot, same kver: the tool staged the
    # old bytes, so it owns the ESP copy and may refresh it.
    printf 'vmlinuz-payload-%s-v2\n' "$NEW_KVER" > "$w/boot/vmlinuz-$NEW_KVER"
    run5b >"$w/s5b-b.log" 2>&1; rc_b=$?
    if [ "$rc_a" = 0 ] && [ "$rc_b" = 0 ] \
       && cmp -s "$w/boot/vmlinuz-$NEW_KVER" "$w/esp5b/vmlinuz-$NEW_KVER" \
       && grep -q 'refreshing vmlinuz-.*staged by this tool' "$w/s5b-b.log" \
       && [ "$(grep -c "^menuentry .*$NEW_KVER" "$w/esp5b/EFI/BOOT/refind.conf")" = 1 ]; then
        ok "5b) a pair this tool staged is recognised and refreshed in place"
    else
        bad "5b) a pair this tool staged is recognised and refreshed in place" \
            "$(printf 'rc_a=%s rc_b=%s\n--- first ---\n' "$rc_a" "$rc_b"; cat "$w/s5b-a.log"; printf -- '--- second ---\n'; cat "$w/s5b-b.log"; ls -1 "$w/esp5b")"
    fi
    # The record format itself is the contract: kver/vmlinuz-sha/initrd-sha.
    rec="$(cat "$w/esp5b/ncz-staged-$NEW_KVER" 2>/dev/null)"
    if [ "$rec" = "$NEW_KVER/$(sha "$w/boot/vmlinuz-$NEW_KVER")/$(sha "$w/boot/initrd.img-$NEW_KVER")" ]; then
        ok "5c) the staging record carries kver/vmlinuz-sha/initrd-sha"
    else
        bad "5c) the staging record carries kver/vmlinuz-sha/initrd-sha" \
            "$(printf 'record=<%s>\nwant=<%s>\n' "$rec" "$NEW_KVER/$(sha "$w/boot/vmlinuz-$NEW_KVER")/$(sha "$w/boot/initrd.img-$NEW_KVER")")"
    fi
    # Restore the pristine /boot payload so later cases are unaffected.
    mkboot "$w/boot" "$NEW_KVER"

    # ---- 5d: a foreign ESP copy is still refused (add-only is unchanged) ----
    # Refreshing must stay limited to bytes THIS tool staged: a differing ESP
    # file with no matching record is an operator/foreign file.
    mkesp "$w/esp5d" "$OLD_KVER"
    printf 'foreign-bytes\n' > "$w/esp5d/vmlinuz-$NEW_KVER"
    printf 'foreign-bytes\n' > "$w/esp5d/initrd.img-$NEW_KVER"
    cp -f "$w/esp5d/EFI/BOOT/refind.conf" "$w/conf5d.before"
    NCZ_ESP_DIR="$w/esp5d" KVER_STABLE="$NEW_KVER" \
        KVER_STABLE_SRC="$w/boot/vmlinuz-$NEW_KVER" \
        KVER_STABLE_INITRD="$w/boot/initrd.img-$NEW_KVER" \
        NCZ_SERIAL_CONSOLE=off bash "$w/tool.sh" --add >"$w/s5d.log" 2>&1
    rc=$?
    if [ "$rc" = 1 ] && grep -q 'was not staged by this tool\|already exists on the ESP with DIFFERENT content' "$w/s5d.log" \
       && cmp -s "$w/conf5d.before" "$w/esp5d/EFI/BOOT/refind.conf" \
       && [ "$(cat "$w/esp5d/vmlinuz-$NEW_KVER")" = "foreign-bytes" ]; then
        ok "5d) a foreign ESP copy is still refused and left untouched"
    else
        bad "5d) a foreign ESP copy is still refused and left untouched" \
            "$(printf 'rc=%s\n' "$rc"; cat "$w/s5d.log")"
    fi

    # ---- 6: --promote rewrites only default_selection ----------------------
    mkesp "$w/esp6" "$OLD_KVER" "$NEW_KVER"
    cp -f "$w/esp6/EFI/BOOT/refind.conf" "$w/conf6.before"
    NCZ_ESP_DIR="$w/esp6" NCZ_SERIAL_CONSOLE=off bash "$w/tool.sh" \
        --promote "$NEW_KVER" >"$w/s6.log" 2>&1
    rc=$?
    # Everything except the default_selection line must be byte-identical.
    diff <(grep -v '^default_selection' "$w/conf6.before") \
         <(grep -v '^default_selection' "$w/esp6/EFI/BOOT/refind.conf") >/dev/null 2>&1
    same_rest=$?
    if [ "$rc" = 0 ] && [ "$same_rest" = 0 ] \
       && grep -q "^default_selection .*$NEW_KVER" "$w/esp6/EFI/BOOT/refind.conf"; then
        ok "6) --promote changes only the default_selection line"
    else
        bad "6) --promote changes only the default_selection line" \
            "$(printf 'rc=%s rest_diff=%s\n' "$rc" "$same_rest"; grep default_selection "$w/esp6/EFI/BOOT/refind.conf"; cat "$w/s6.log")"
    fi

    # ---- 7: --promote refuses an unknown title ----------------------------
    mkesp "$w/esp7" "$OLD_KVER"
    cp -f "$w/esp7/EFI/BOOT/refind.conf" "$w/conf7.before"
    NCZ_ESP_DIR="$w/esp7" NCZ_SERIAL_CONSOLE=off bash "$w/tool.sh" \
        --promote "no-such-entry-title" >"$w/s7.log" 2>&1
    rc=$?
    if [ "$rc" = 1 ] && grep -q 'matches no menuentry' "$w/s7.log" \
       && cmp -s "$w/conf7.before" "$w/esp7/EFI/BOOT/refind.conf"; then
        ok "7) --promote refuses a title matching no entry; menu unchanged"
    else
        bad "7) --promote refuses a title matching no entry; menu unchanged" \
            "$(printf 'rc=%s\n' "$rc"; cat "$w/s7.log")"
    fi

    # ---- 8: unknown verb is misuse (rc=2) and touches nothing -------------
    mkesp "$w/esp8" "$OLD_KVER"
    cp -f "$w/esp8/EFI/BOOT/refind.conf" "$w/conf8.before"
    NCZ_ESP_DIR="$w/esp8" NCZ_SERIAL_CONSOLE=off bash "$w/tool.sh" --bogus >"$w/s8.log" 2>&1
    rc=$?
    if [ "$rc" = 2 ] && cmp -s "$w/conf8.before" "$w/esp8/EFI/BOOT/refind.conf"; then
        ok "8) an unknown verb is misuse (rc=2) and writes nothing"
    else
        bad "8) an unknown verb is misuse (rc=2) and writes nothing" \
            "$(printf 'rc=%s\n' "$rc"; cat "$w/s8.log")"
    fi

    rm -rf "$w"
}

for s in "${SOURCES[@]}"; do
    run_for_source "$s"
done

echo
echo "refind add-only tests: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
