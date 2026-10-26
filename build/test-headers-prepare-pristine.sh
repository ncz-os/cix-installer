#!/usr/bin/env bash
# test-headers-prepare-pristine.sh -- ncz_prepare_pristine: `make
# modules_prepare` on an installed kernel header tree must rebuild the host
# tools without changing the kernel configuration the tree describes.
#
# 2026-10-26 (r292): modules_prepare re-ran Kconfig for a different compiler;
# on a host without pahole that dropped CONFIG_DEBUG_INFO_BTF_MODULES, struct
# module shrank 0x500 -> 0x4c0 and the kernel refused the Mali modules built
# against the tree. On O6N the same step prompted for new symbols on the
# terminal and dropped CONFIG_GCC_PLUGINS.
#
# Cases, run against each of the three copies of the function (headers .deb
# postinst in build/build-kernel-debs.sh, post-install/79-dkms-prep.sh,
# post-install/10-our-kernel.sh):
#   - Kconfig output rewritten by make is restored byte-for-byte; make's
#     non-zero status is passed through;
#   - make gets no stdin (a Kconfig prompt cannot wait on a terminal);
#   - a clean make leaves everything as it was and returns 0;
#   - a configuration that cannot be restored returns 3;
#   - a resolve_btfids failure is explained in the log.
# Plus: the three copies are identical and every caller treats 3 as fatal.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/test-prepare-pristine.XXXXXX")"
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok() { echo "PASS: $1"; PASS=$((PASS + 1)); }
no() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

extract() {  # extract <file> -> the function block between the markers
    sed -n '/^# >>> ncz_prepare_pristine/,/^# <<< ncz_prepare_pristine/p' "$1"
}
COPIES="build/build-kernel-debs.sh post-install/79-dkms-prep.sh post-install/10-our-kernel.sh"
for f in $COPIES; do
    extract "$ROOT/$f" > "$T/$(basename "$f").fn"
    [ -s "$T/$(basename "$f").fn" ] && ok "$f carries ncz_prepare_pristine" || no "$f has no ncz_prepare_pristine block"
done
if cmp -s "$T/build-kernel-debs.sh.fn" "$T/79-dkms-prep.sh.fn" && cmp -s "$T/79-dkms-prep.sh.fn" "$T/10-our-kernel.sh.fn"; then
    ok "the three copies are identical"
else
    no "the three copies of ncz_prepare_pristine differ"; diff "$T/build-kernel-debs.sh.fn" "$T/79-dkms-prep.sh.fn" | head; diff "$T/79-dkms-prep.sh.fn" "$T/10-our-kernel.sh.fn" | head
fi

# tree <dir> <mode>: a fake header tree whose modules_prepare
#   drift   rewrites .config/auto.conf/autoconf.h, fails like resolve_btfids, exit 2
#   clean   touches nothing, exit 0
#   stuck   replaces .config with a directory (cannot be restored)
tree() {
    local d=$1
    mkdir -p "$d/include/config" "$d/include/generated"
    printf 'CONFIG_DEBUG_INFO_BTF_MODULES=y\nCONFIG_PAHOLE_VERSION=131\n' > "$d/.config"
    printf 'CONFIG_DEBUG_INFO_BTF_MODULES=y\n' > "$d/include/config/auto.conf"
    printf '#define CONFIG_DEBUG_INFO_BTF_MODULES 1\n' > "$d/include/generated/autoconf.h"
    printf '7.3.0-sky1-ncz\n' > "$d/include/config/kernel.release"
    case "$2" in
        drift) printf 'modules_prepare:\n\t@cat > stdin-seen.txt\n\t@printf "CONFIG_PAHOLE_VERSION=0\\n" > .config\n\t@printf "\\n" > include/config/auto.conf\n\t@printf "/* no BTF */\\n" > include/generated/autoconf.h\n\t@echo "fatal error: linux/kasan-checks.h: No such file or directory"\n\t@echo "make[3]: *** [Makefile:83: tools/bpf/resolve_btfids] Error 2"\n\t@exit 2\n' > "$d/Makefile" ;;
        clean) printf 'modules_prepare:\n\t@cat > stdin-seen.txt\n' > "$d/Makefile" ;;
        stuck) printf 'modules_prepare:\n\t@rm -f .config\n\t@mkdir .config\n' > "$d/Makefile" ;;
    esac
    cp -p "$d/.config" "$d/.config.orig"; cp -p "$d/include/generated/autoconf.h" "$d/autoconf.orig"
    cp -p "$d/include/config/auto.conf" "$d/auto.conf.orig"
}

for f in $COPIES; do
    n=$(basename "$f")
    run() {  # run <tree> -> rc in $RC
        RC=0
        printf 'LEAKED-TERMINAL-INPUT\n' | bash -c ". '$T/$n.fn'; ncz_prepare_pristine '$1' '$1/prep.log'" || RC=$?
    }
    D="$T/$n.drift"; tree "$D" drift; run "$D"
    [ "$RC" = 2 ] && ok "$n: make's failure status passes through (rc=$RC)" || no "$n: rc=$RC, want 2"
    if cmp -s "$D/.config" "$D/.config.orig" && cmp -s "$D/include/generated/autoconf.h" "$D/autoconf.orig" \
       && cmp -s "$D/include/config/auto.conf" "$D/auto.conf.orig"; then
        ok "$n: Kconfig drift restored byte-for-byte"
    else
        no "$n: .config/auto.conf/autoconf.h not restored"
    fi
    grep -q 'Kconfig rewrote include/generated/autoconf.h; restored' "$D/prep.log" && ok "$n: the restore is logged" || no "$n: no restore line in the log"
    grep -q 'resolve_btfids not built .* not needed for DKMS' "$D/prep.log" && ok "$n: resolve_btfids failure explained" || no "$n: resolve_btfids failure not explained"
    [ -f "$D/stdin-seen.txt" ] && [ ! -s "$D/stdin-seen.txt" ] && ok "$n: make got no stdin" || no "$n: make read stdin ($(cat "$D/stdin-seen.txt" 2>/dev/null))"
    D="$T/$n.clean"; tree "$D" clean; run "$D"
    [ "$RC" = 0 ] && cmp -s "$D/.config" "$D/.config.orig" && ok "$n: clean make returns 0, config untouched" || no "$n: clean case rc=$RC"
    D="$T/$n.stuck"; tree "$D" stuck; run "$D"
    [ "$RC" = 3 ] && ok "$n: unrestorable configuration returns 3" || no "$n: unrestorable case rc=$RC, want 3"
done

# callers: 3 is fatal, never "expected non-zero"
grep -A4 'ncz_prepare_pristine "$B" "$LOG" || _prep_rc=$?' "$ROOT/build/build-kernel-debs.sh" | grep -q '3)' \
    && grep -q 'Refusing to run dkms autoinstall: modules built against it would not load' "$ROOT/build/build-kernel-debs.sh" \
    && ok "headers postinst stops on rc 3" || no "headers postinst does not stop on rc 3"
grep -A3 'ncz_prepare_pristine "$B" "$LOG" || _prep_rc=$?' "$ROOT/post-install/79-dkms-prep.sh" | grep -q '"$_prep_rc" = 3' \
    && ok "79-dkms-prep stops on rc 3" || no "79-dkms-prep does not stop on rc 3"
grep -A2 'ncz_prepare_pristine "$b" /var/log/ncz-kernel-host-tools.log || prep_rc=$?' "$ROOT/post-install/10-our-kernel.sh" | grep -q '"$prep_rc" = 3' \
    && ok "10-our-kernel stops on rc 3" || no "10-our-kernel does not stop on rc 3"
if grep -nE 'make[^|]*modules_prepare' "$ROOT/build/build-kernel-debs.sh" "$ROOT/post-install/79-dkms-prep.sh" "$ROOT/post-install/10-our-kernel.sh" \
        | grep -v 'ncz_prepare_pristine\|make -k -C "$_np_b"' | grep -v ':[[:space:]]*#' | grep -q .; then
    no "a bare 'make modules_prepare' is still run outside ncz_prepare_pristine"
    grep -nE 'make[^|]*modules_prepare' "$ROOT/build/build-kernel-debs.sh" "$ROOT/post-install/79-dkms-prep.sh" "$ROOT/post-install/10-our-kernel.sh" | grep -v ':[[:space:]]*#' | sed 's/^/    /'
else
    ok "no bare 'make modules_prepare' outside ncz_prepare_pristine"
fi

echo "test-headers-prepare-pristine: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
