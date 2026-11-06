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
#   0. the tool and both hooks parse with `bash -n`; 0b proves that BOTH
#      consecutive `fi`s after the rescue-partition preflight are required
#      (deleting either breaks the parse) and 0c proves the "remove the
#      stray fi" review suggestion is exactly that deletion -- a repeated
#      false positive, settled here by a test result instead of by reading a
#      diff hunk without its context;
#   1. install-time generate still writes the menu (Default entry present);
#   2. --add appends exactly one entry, stages both files, and leaves
#      default_selection byte-identical;
#   3. --add never wipes: a pre-existing kernel pair and its entry survive;
#   4. --add refuses when the new pair is not in /boot (ESP left untouched);
#   5. --add refuses a Debian-archive kernel name (7.3 policy);
#   6. --promote changes only the default_selection line;
#   7. --promote refuses a title that matches no entry;
#   8. an unknown verb is misuse (rc=2), not a wipe;
#   9. --stage is an alias for --add (stages, appends, never wipes);
#  10. --promote needs no KVER_STABLE and rewrites only the default;
#  11. --promote uses the parsed title and honours --force;
#  12. appended-entry uniqueness is literal (a look-alike title is not a
#      duplicate), a real duplicate is refused with the menu byte-identical,
#      and a repeated --add stays idempotent. 12d covers the POST-replace
#      verification: the backup stays alive until it passes, so a failure
#      there (torn/concurrent write) restores the previous menu instead of
#      leaving a mutated ESP -- the add-only guarantee on the error path.
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

    # ---- 0: the script parses ----------------------------------------------
    # `bash -n` above only gates the run; make the parse a reported case, and
    # cover every shipped script. A stray or missing `fi` makes bash refuse the
    # whole file, so this is the first thing that must hold. Both `fi`s that
    # close the rescue-partition preflight and the generate-only block around
    # it are required: removing either yields "unexpected end of file".
    _parse_bad=""
    for _s in "$src" "$REPO/assets/refind/zz1-ncz-refind-refresh-amd64" \
              "$REPO/assets/refind/zz2-ncz-refind-promote-guard"; do
        _msg=$(bash -n "$_s" 2>&1) || _parse_bad="$_parse_bad $(basename "$_s"):$(printf '%s' "$_msg" | head -1)"
    done
    if [ -z "$_parse_bad" ]; then
        ok "0) the tool and both hooks parse (bash -n)"
    else
        bad "0) the tool and both hooks parse (bash -n)" "$_parse_bad"
        rm -rf "$w"; return
    fi

    # ---- 0b: the two consecutive `fi`s are BOTH required -------------------
    # A review has twice reported "unbalanced if/fi: an extra `fi` after the
    # rescue-partition elif block". It is a false positive read from a diff
    # hunk: the first `fi` ends the rescue-partition if/elif chain and the
    # second closes the `if [ "$NCZ_VERB" = generate ]` opened above the
    # rEFInd-binary check. Rather than argue it, prove it -- delete each and
    # require that the file STOPS parsing. If anyone ever "fixes" the reported
    # stray `fi` by removing one, this case fails and names the line.
    # The pair is: the `fi` that ends the rescue if/elif chain (bare), and the
    # next `fi` (which carries the "end of the GENERATE-only preconditions"
    # comment). Locate the commented one, then take the nearest `fi` above it.
    _gen_fi=$(grep -n '^fi[[:space:]]*#.*GENERATE-only preconditions' "$w/tool.sh" | head -1 | cut -d: -f1)
    _rescue_fi=$(awk -v m="${_gen_fi:-0}" 'NR < m && /^fi([[:space:]]|$)/ { n = NR } END { print n }' "$w/tool.sh")
    if [ -z "$_gen_fi" ] || [ -z "$_rescue_fi" ] || [ $((_gen_fi - _rescue_fi)) -gt 12 ]; then
        bad "0b) both consecutive fi's are required (a removed fi breaks the parse)" \
            "could not locate the pair (rescue=${_rescue_fi:-none} generate=${_gen_fi:-none})"
    else
        _pair_bad=""
        for _dl in "$_rescue_fi" "$_gen_fi"; do
            sed "${_dl}d" "$w/tool.sh" > "$w/pair-check.sh" 2>/dev/null
            if bash -n "$w/pair-check.sh" 2>/dev/null; then
                _pair_bad="$_pair_bad line${_dl}:removable"
            fi
        done
        rm -f "$w/pair-check.sh"
        if [ -z "$_pair_bad" ]; then
            ok "0b) both consecutive fi's are required (a removed fi breaks the parse)"
        else
            bad "0b) both consecutive fi's are required (a removed fi breaks the parse)" \
                "$_pair_bad"
        fi
    fi
    # ...and the reviewer's proposed edit (delete the `fi` after the rescue
    # chain) must be exactly the one this case rejects.
    if [ -n "${_gen_fi:-}" ]; then
        sed "${_gen_fi}d" "$w/tool.sh" > "$w/reviewer-edit.sh" 2>/dev/null
        if bash -n "$w/reviewer-edit.sh" 2>/dev/null; then
            bad "0c) the reviewer's suggested edit (drop the stray fi) does not parse" "line ${_gen_fi} was removable"
        else
            ok "0c) the reviewer's suggested edit (drop the stray fi) does not parse"
        fi
        rm -f "$w/reviewer-edit.sh"
    fi

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

    # ---- 1b: the tool's internal constants are defined before first use -----
    # Static contract check. These five names drive the staging record
    # (NCZ_STAGE_TAG), the FAT32 size guard (NCZ_ESP_MAX_FILE_BYTES), the ESP
    # root entry budget (NCZ_ESP_MAX_FILES_IN_ROOT), the hook-entry marker
    # (NCZ_HOOK_TAG) and the menu title (NCZ_RELEASE_SHORT). If any of them
    # lost its definition the add-only path would silently build names like
    # "$ESP_DIR/-$kver" and "$$ESP_DIR/.vmlinuz-x..1234" rather than failing
    # loudly, so assert each is assigned BEFORE its first use and is non-empty.
    missing=""
    for _v in NCZ_STAGE_TAG NCZ_HOOK_TAG NCZ_ESP_MAX_FILE_BYTES \
              NCZ_ESP_MAX_FILES_IN_ROOT NCZ_RELEASE_SHORT; do
        _def=$(grep -n "^[[:space:]]*$_v=" "$w/tool.sh" | head -1 | cut -d: -f1)
        _use=$(grep -n "\"\?\\\$$_v\|\\\${$_v" "$w/tool.sh" | head -1 | cut -d: -f1)
        _val=$(sed -n "s/^[[:space:]]*$_v=//p" "$w/tool.sh" | head -1)
        if [ -z "$_def" ] || [ -z "$_use" ] || [ "$_def" -ge "$_use" ] || [ -z "$_val" ]; then
            missing="$missing $_v(def=${_def:-none},use=${_use:-none})"
        fi
    done
    # Resolve the names through a real shell under `set -u`: a definition that
    # expands empty (e.g. NCZ_RELEASE_SHORT built from unset RELEASE fields)
    # is just as broken as a missing one. The constants come from the tool's
    # NCZ-STAGING-MARKERS block; NCZ_RELEASE_SHORT is computed from the RELEASE
    # identity sourced just above it, so supply that file the same way.
    {
        sed -n '/NCZ-STAGING-MARKERS-BEGIN/,/NCZ-STAGING-MARKERS-END/p' "$w/tool.sh"
        printf 'RELEASE_FILE=%s\n' "$w/lib/RELEASE"
        sed -n '/^\. "\$RELEASE_FILE"$/p;/^NCZ_RELEASE_SHORT=/p' "$w/tool.sh"
        cat <<'CONSTS'
printf '%s|%s|%s|%s\n' "$NCZ_STAGE_TAG" "$NCZ_HOOK_TAG" \
    "$NCZ_ESP_MAX_FILES_IN_ROOT" "$NCZ_RELEASE_SHORT"
CONSTS
    } > "$w/consts.sh"
    _expanded=$(env -u NCZ_STAGE_TAG -u NCZ_HOOK_TAG -u NCZ_RELEASE_SHORT \
        bash -c 'set -u; . "$1"' _ "$w/consts.sh" 2>&1)
    _expanded_ok=0
    case "$_expanded" in
        *\|*\|*\|*)
            # Every field must be non-empty; split and test each.
            case "$_expanded" in
                ''\|*|*\|''\|*|*\|*\|''\|*|*\|*\|*\|'') ;;
                *) _expanded_ok=1 ;;
            esac
            ;;
    esac
    if [ -z "$missing" ] && [ "$_expanded_ok" = 1 ]; then
        ok "1b) NCZ_STAGE_TAG/HOOK_TAG/MAX_*/RELEASE_SHORT are defined before use"
    else
        bad "1b) NCZ_STAGE_TAG/HOOK_TAG/MAX_*/RELEASE_SHORT are defined before use" \
            "missing:$missing expanded=<$_expanded>"
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
    added="$(grep '^menuentry ' "$w/esp/EFI/BOOT/refind.conf" 2>/dev/null | grep -cF -- "$NEW_KVER" || true)"
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
       && [ "$(grep '^menuentry ' "$w/esp5b/EFI/BOOT/refind.conf" | grep -cF -- "$NEW_KVER" || true)" = 1 ]; then
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

    # ---- 9: --stage is an alias for --add, NOT a path to the wipe ----------
    # --stage must dispatch to the same add-only code as --add: stage the pair,
    # append one entry, leave the pre-existing kernel and default_selection
    # alone. If it fell through to generate it would WIPE the ESP.
    mkesp "$w/esp9" "$OLD_KVER"
    cp -f "$w/esp9/EFI/BOOT/refind.conf" "$w/conf9.before"
    stage_default="$(sed -n 's/^default_selection //p' "$w/conf9.before" | head -1)"
    NCZ_ESP_DIR="$w/esp9" KVER_STABLE="$NEW_KVER" \
        KVER_STABLE_SRC="$w/boot/vmlinuz-$NEW_KVER" \
        KVER_STABLE_INITRD="$w/boot/initrd.img-$NEW_KVER" \
        NCZ_SERIAL_CONSOLE=off bash "$w/tool.sh" --stage >"$w/s9.log" 2>&1
    rc=$?
    if [ "$rc" = 0 ] \
       && grep -q 'verb=stage' "$w/s9.log" \
       && ! grep -q 'wiping stale ESP entries' "$w/s9.log" \
       && [ -s "$w/esp9/vmlinuz-$OLD_KVER" ] \
       && [ -s "$w/esp9/vmlinuz-$NEW_KVER" ] \
       && [ "$(grep '^menuentry ' "$w/esp9/EFI/BOOT/refind.conf" | grep -cF -- "$NEW_KVER" || true)" = 1 ] \
       && [ "$(sed -n 's/^default_selection //p' "$w/esp9/EFI/BOOT/refind.conf" | head -1)" = "$stage_default" ]; then
        ok "9) --stage behaves exactly like --add (stages, appends, never wipes)"
    else
        bad "9) --stage behaves exactly like --add (stages, appends, never wipes)" \
            "$(printf 'rc=%s\n' "$rc"; cat "$w/s9.log"; ls -1 "$w/esp9")"
    fi

    # ---- 10: --promote needs NO KVER_STABLE -------------------------------
    # The promote path rewrites default_selection only, so it must work with the
    # kernel identity absent. If it fell through to menu generation it would
    # abort (no KVER_STABLE) or, worse, regenerate the menu.
    mkesp "$w/esp10" "$OLD_KVER" "$NEW_KVER"
    cp -f "$w/esp10/EFI/BOOT/refind.conf" "$w/conf10.before"
    sel10="$(grep '^menuentry .*' "$w/conf10.before" | grep -F "$NEW_KVER" | head -1 \
             | sed 's/^menuentry "\(.*\)" {.*/\1/')"
    NCZ_ESP_DIR="$w/esp10" KVER_EDGE= NCZ_SERIAL_CONSOLE=off \
        env -u KVER_STABLE bash "$w/tool.sh" --promote "$sel10" >"$w/s10.log" 2>&1
    rc=$?
    diff <(grep -v '^default_selection' "$w/conf10.before") \
         <(grep -v '^default_selection' "$w/esp10/EFI/BOOT/refind.conf") >/dev/null 2>&1
    same_rest=$?
    if [ "$rc" = 0 ] && [ "$same_rest" = 0 ] \
       && grep -qF "default_selection \"$sel10\"" "$w/esp10/EFI/BOOT/refind.conf" \
       && ! grep -q 'wiping stale ESP entries' "$w/s10.log"; then
        ok "10) --promote works with no KVER_STABLE and rewrites only the default"
    else
        bad "10) --promote works with no KVER_STABLE and rewrites only the default" \
            "$(printf 'rc=%s rest_diff=%s sel=<%s>\n' "$rc" "$same_rest" "$sel10"; cat "$w/s10.log"; grep default_selection "$w/esp10/EFI/BOOT/refind.conf")"
    fi

    # ---- 13: the promote-path guard must be set -u safe -------------------
    # A review reported that the KVER_STABLE guard on the promote path
    # expanded a bare $KVER_STABLE, so with the variable unset the file
    # aborted with "unbound variable" and --promote never reached
    # ncz_promote. The guard is reached BEFORE the verb dispatch, and the
    # promote path legitimately runs with no kernel identity in the
    # environment (zz2 calls the tool with only a pin token), so the
    # expansion must not depend on the variable being set. Pin the SOURCE
    # form: every KVER_STABLE expansion in that guard must be a defaulted
    # one (${KVER_STABLE:-} / ${KVER_STABLE:=}), exactly like the sibling
    # expansion in the kernel-purity case below it.
    _guard_bad=""
    _guard_line=$(grep -n 'no KVER_STABLE provided' "$w/tool.sh" | head -1 | cut -d: -f1)
    if [ -z "$_guard_line" ]; then
        _guard_bad="the KVER_STABLE guard is missing from the tool"
    else
        _guard_src=$(sed -n "$((_guard_line - 2)),${_guard_line}p" "$w/tool.sh")
        printf '%s\n' "$_guard_src" | grep -q 'KVER_STABLE:-' \
            || _guard_bad="the guard does not use a defaulted KVER_STABLE expansion: $_guard_src"
    fi
    if [ -z "$_guard_bad" ]; then
        ok "13) the promote-path KVER_STABLE guard is set -u safe (defaulted expansion)"
    else
        bad "13) the promote-path KVER_STABLE guard is set -u safe (defaulted expansion)" "$_guard_bad"
    fi

    # ---- 11: --promote uses the parsed title, and honours --force ----------
    # The parsed title is what selects the entry; --force is what permits
    # rewriting a default_selection line that already names that entry. The
    # rewrite's own message is "default_selection '<old>' -> '<new>'", anchored
    # here so an unrelated "->" in a log line cannot satisfy the check.
    mkesp "$w/esp11" "$OLD_KVER"
    cp -f "$w/esp11/EFI/BOOT/refind.conf" "$w/conf11.before"
    # 11a: a title matching no entry is refused and writes nothing.
    NCZ_ESP_DIR="$w/esp11" NCZ_SERIAL_CONSOLE=off bash "$w/tool.sh" \
        --promote "no-such-title" >"$w/s11a.log" 2>&1
    rc_a=$?
    unchanged=$([ "$(grep -c '^menuentry ' "$w/esp11/EFI/BOOT/refind.conf")" = 1 ] && echo 1 || echo 0)
    # Promote the old kernel's real title so it becomes the default, then
    # promote the SAME title again: no-op without --force, rewrite with it.
    cur11="$(grep '^menuentry .*' "$w/conf11.before" | head -1 | sed 's/^menuentry "\(.*\)" {.*/\1/')"
    NCZ_ESP_DIR="$w/esp11" NCZ_SERIAL_CONSOLE=off bash "$w/tool.sh" \
        --promote "$cur11" >"$w/s11pre.log" 2>&1
    NCZ_ESP_DIR="$w/esp11" NCZ_SERIAL_CONSOLE=off bash "$w/tool.sh" \
        --promote "$cur11" >"$w/s11b.log" 2>&1
    rc_b=$?
    f11b="$(sed -n 's/^default_selection "\(.*\)"/\1/p' "$w/esp11/EFI/BOOT/refind.conf" | head -1)"
    NCZ_ESP_DIR="$w/esp11" NCZ_SERIAL_CONSOLE=off bash "$w/tool.sh" \
        --promote "$cur11" --force >"$w/s11c.log" 2>&1
    rc_c=$?
    if [ "$rc_a" = 1 ] && [ "$unchanged" = 1 ] \
       && [ "$rc_b" = 0 ] && grep -q "default_selection is already" "$w/s11b.log" \
       && [ "$f11b" = "$cur11" ] \
       && [ "$rc_c" = 0 ] && grep -q "^  default_selection '.*' -> '" "$w/s11c.log"; then
        ok "11) --promote uses the parsed title and honours --force"
    else
        bad "11) --promote uses the parsed title and honours --force" \
            "$(printf 'a=%s unchanged=%s b=%s c=%s cur=<%s> f11b=<%s>\n' "$rc_a" "$unchanged" "$rc_b" "$rc_c" "$cur11" "$f11b"; grep -hE 'ERROR|already|->' "$w/s11a.log" "$w/s11b.log" "$w/s11c.log")"
    fi

    # ---- 12: the appended-entry uniqueness check is LITERAL, not a regex ---
    # A kver is a grep PATTERN unless -F is used: "7.3.0-rc8-t2-ncz" has dots,
    # so `grep -c "^menuentry .*$token"` also matches an unrelated entry whose
    # title merely FITS the pattern ("7x3y0-rc8-t2-ncz"). That false positive
    # made a perfectly good append report failure. 12a: such a look-alike entry
    # must not stop the add (rc=0, both entries present).
    mkesp "$w/esp12a" "$OLD_KVER"
    LOOKALIKE="7x3y0-rc8-t2-ncz"
    {
        printf 'menuentry "NCZ-OS 26.10 Cygnus  -  7.3 Kernel %s" {\n' "$LOOKALIKE"
        printf '    loader  /vmlinuz-%s\n' "$LOOKALIKE"
        printf '    options "root=PARTUUID=x"\n}\n\n'
    } >> "$w/esp12a/EFI/BOOT/refind.conf"
    NCZ_ESP_DIR="$w/esp12a" KVER_STABLE="$NEW_KVER" \
        KVER_STABLE_SRC="$w/boot/vmlinuz-$NEW_KVER" \
        KVER_STABLE_INITRD="$w/boot/initrd.img-$NEW_KVER" \
        NCZ_SERIAL_CONSOLE=off bash "$w/tool.sh" --add >"$w/s12a.log" 2>&1
    rc=$?
    if [ "$rc" = 0 ] \
       && [ "$(grep -c '^menuentry ' "$w/esp12a/EFI/BOOT/refind.conf")" = 3 ] \
       && grep -qF "7.3 Kernel $NEW_KVER" "$w/esp12a/EFI/BOOT/refind.conf" \
       && grep -qF "7.3 Kernel $LOOKALIKE" "$w/esp12a/EFI/BOOT/refind.conf"; then
        ok "12a) a look-alike title is not treated as a duplicate (literal match)"
    else
        bad "12a) a look-alike title is not treated as a duplicate (literal match)" \
            "$(printf 'rc=%s\n' "$rc"; grep '^menuentry ' "$w/esp12a/EFI/BOOT/refind.conf"; cat "$w/s12a.log")"
    fi

    # 12b: the append's own uniqueness check, exercised where the upstream
    # guard cannot see it. ncz_entry_append is the last thing standing between
    # a duplicate and the ESP, so call it directly on a menu that ALREADY
    # carries the token in another title. It must refuse and leave refind.conf
    # byte-identical: the check runs on the candidate before the replace,
    # because the backup is unlinked once `mv` succeeds and a post-replace
    # failure would leave the duplicate on the ESP while reporting failure.
    mkesp "$w/esp12b" "$OLD_KVER" "$NEW_KVER"
    cp -f "$w/esp12b/EFI/BOOT/refind.conf" "$w/conf12b.before"
    # Source only the helper block, with ESP_DIR/ESP_CONF bound to the fixture.
    {
        sed -n '/^# NCZ-ADDONLY-FUNCS-BEGIN/,/^# NCZ-ADDONLY-FUNCS-END/p' "$w/tool.sh" \
            | sed "s#^ESP_DIR=.*#ESP_DIR=$w/esp12b#; s#^ESP_CONF=.*#ESP_CONF=$w/esp12b/EFI/BOOT/refind.conf#"
        cat <<'APPEND'
ncz_entry_append "$NEW_KVER" "vmlinuz-$NEW_KVER" "initrd.img-$NEW_KVER" "root=PARTUUID=x" "$NEW_KVER"
APPEND
    } > "$w/harness12b.sh"
    ( cd "$w" && NEW_KVER="$NEW_KVER" REFIND_ICON="" NCZ_HOOK_TAG="# ncz-hook-entry:" \
          bash "$w/harness12b.sh" ) >"$w/s12b.log" 2>&1
    rc=$?
    if [ "$rc" = 1 ] \
       && grep -q 'would not leave exactly one match' "$w/s12b.log" \
       && cmp -s "$w/conf12b.before" "$w/esp12b/EFI/BOOT/refind.conf" \
       && [ "$(grep -c '^menuentry ' "$w/esp12b/EFI/BOOT/refind.conf")" = 2 ]; then
        ok "12b) ncz_entry_append refuses a second match, menu byte-identical"
    else
        bad "12b) ncz_entry_append refuses a second match, menu byte-identical" \
            "$(printf 'rc=%s\n' "$rc"; diff "$w/conf12b.before" "$w/esp12b/EFI/BOOT/refind.conf"; cat "$w/s12b.log")"
    fi

    # 12d: the POST-REPLACE verification must also roll back. The decision is
    # made on the candidate before mv, so this path only fires on a torn or
    # concurrently-mutated file -- but the backup must still be alive when it
    # runs, or a failure there would leave a mutated ESP behind. Simulate a
    # concurrent writer by shadowing `mv`: the candidate lands, then a second
    # stanza carrying the token appears, so the check must fail AND restore.
    mkesp "$w/esp12d" "$OLD_KVER"
    cp -f "$w/esp12d/EFI/BOOT/refind.conf" "$w/conf12d.before"
    {
        sed -n '/^# NCZ-ADDONLY-FUNCS-BEGIN/,/^# NCZ-ADDONLY-FUNCS-END/p' "$w/tool.sh" \
            | sed "s#^ESP_DIR=.*#ESP_DIR=$w/esp12d#; s#^ESP_CONF=.*#ESP_CONF=$w/esp12d/EFI/BOOT/refind.conf#"
        cat <<'ROLLBACK'
# Withstand the post-replace check: after mv, append a second match.
mv() { command mv "$@"; printf '\nmenuentry "7.3 Kernel %s" {\n    loader /v\n}\n' "$NEW_KVER" >> "$ESP_CONF"; }
ncz_entry_append "$NEW_KVER" "vmlinuz-$NEW_KVER" "initrd.img-$NEW_KVER" "root=PARTUUID=x" "$NEW_KVER"
ROLLBACK
    } > "$w/harness12d.sh"
    ( cd "$w" && NEW_KVER="$NEW_KVER" REFIND_ICON="" NCZ_HOOK_TAG="# ncz-hook-entry:" \
          bash "$w/harness12d.sh" ) >"$w/s12d.log" 2>&1
    rc=$?
    if [ "$rc" = 1 ] \
       && grep -q 'restored the previous menu' "$w/s12d.log" \
       && cmp -s "$w/conf12d.before" "$w/esp12d/EFI/BOOT/refind.conf"; then
        ok "12d) a post-replace failure restores the previous menu"
    else
        bad "12d) a post-replace failure restores the previous menu" \
            "$(printf 'rc=%s\n' "$rc"; diff "$w/conf12d.before" "$w/esp12d/EFI/BOOT/refind.conf"; cat "$w/s12d.log")"
    fi

    # 12c: a second --add of the SAME kernel is a no-op, not a duplicate: the
    # hook path must stay idempotent (the guard refuses it, the menu is
    # unchanged, and the ESP never accumulates two entries for one kernel).
    mkesp "$w/esp12c" "$OLD_KVER"
    run12c() {
        NCZ_ESP_DIR="$w/esp12c" KVER_STABLE="$NEW_KVER" \
            KVER_STABLE_SRC="$w/boot/vmlinuz-$NEW_KVER" \
            KVER_STABLE_INITRD="$w/boot/initrd.img-$NEW_KVER" \
            NCZ_SERIAL_CONSOLE=off bash "$w/tool.sh" --add
    }
    run12c >"$w/s12c-a.log" 2>&1; rc_a=$?
    cp -f "$w/esp12c/EFI/BOOT/refind.conf" "$w/conf12c.after-first"
    run12c >"$w/s12c-b.log" 2>&1; rc_b=$?
    if [ "$rc_a" = 0 ] && [ "$rc_b" = 0 ] \
       && cmp -s "$w/conf12c.after-first" "$w/esp12c/EFI/BOOT/refind.conf" \
       && [ "$(grep -cF "7.3 Kernel $NEW_KVER" "$w/esp12c/EFI/BOOT/refind.conf")" = 1 ]; then
        ok "12c) a repeated --add leaves exactly one entry (idempotent, no rollback)"
    else
        bad "12c) a repeated --add leaves exactly one entry (idempotent, no rollback)" \
            "$(printf 'rc_a=%s rc_b=%s\n--- first ---\n' "$rc_a" "$rc_b"; cat "$w/s12c-a.log"; printf -- '--- second ---\n'; cat "$w/s12c-b.log"; grep '^menuentry ' "$w/esp12c/EFI/BOOT/refind.conf")"
    fi

    rm -rf "$w"
}

for s in "${SOURCES[@]}"; do
    run_for_source "$s"
done

echo
echo "refind add-only tests: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
