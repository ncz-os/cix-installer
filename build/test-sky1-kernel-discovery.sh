#!/bin/bash
# test-sky1-kernel-discovery.sh -- which kernels the Sky1 NPU/VPU hooks act on.
#
# post-install/lib/sky1-kernels.sh (ncz_sky1_kernel_vers) returns the KVER_NEXT
# sidecar kernel plus every other NCZ Sky1 kernel module tree on disk
# (*-sky1-ncz), once each. post-install/80-npu.sh and 81-vpu.sh build their
# kernel lists from it. This test runs the helper and the hooks' own discovery
# block against fixture module trees (no root, nothing outside the sandbox):
#   * the shipped kernel names (assets/kernel/mainline/KVER and the
#     manifests/components.tsv kernel rows) are matched / not matched as
#     intended: Sky1 yes, amd64 -t2-ncz no;
#   * a hand-installed 7.3 kernel the sidecar does not name is folded in;
#   * /lib -> /usr/lib aliasing does not duplicate a kernel;
#   * a missing or empty sidecar and an absent module tree are handled;
#   * control: the previous *7.2*-ncz glob (NCZ_KDISC_CONTROL_REF) misses the
#     7.3 disk kernel, so the test can see that defect.
#
# Usage: bash build/test-sky1-kernel-discovery.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
LIB="$ROOT/post-install/lib/sky1-kernels.sh"
CONTROL_REF="${NCZ_KDISC_CONTROL_REF:-9b7b060c991c33a0aa6f8df38935c0ca6cb20988}"
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1" >&2; }

W="$(mktemp -d "${TMPDIR:-/tmp}/ncz-kdisc.XXXXXX")"
trap 'rm -rf "$W"' EXIT

[ -r "$LIB" ] || { bad "helper missing: $LIB"; exit 1; }
bash -n "$LIB" && ok "helper parses" || bad "helper does not parse"
# shellcheck source=../post-install/lib/sky1-kernels.sh
. "$LIB"

# expect <name> <want (newline list)> <cmd...>
expect() {
    local name="$1" want="$2" got; shift 2
    got="$("$@" 2>&1)"
    if [ "$got" = "$want" ]; then ok "$name"; else bad "$name: got [$(echo "$got" | tr '\n' '|')] want [$(echo "$want" | tr '\n' '|')]"; fi
}

# --- the shipped kernel names ---------------------------------------------------------------
SKY1_KV="$(tr -d '[:space:]' < "$ROOT/assets/kernel/mainline/KVER" 2>/dev/null || true)"
[ -n "$SKY1_KV" ] || SKY1_KV="$(awk -F'\t' '$1=="sky1-mainline-kernel"{print $7; exit}' "$ROOT/manifests/components.tsv")"
AMD_KV="$(tr -d '[:space:]' < "$ROOT/assets/kernel/amd64-stable/KVER" 2>/dev/null || true)"
[ -n "$AMD_KV" ] || AMD_KV="$(awk -F'\t' '$1=="amd64-stable-kernel"{print $7; exit}' "$ROOT/manifests/components.tsv")"
MAN_SKY1="$(awk -F'\t' '$1=="sky1-mainline-kernel"{print $7; exit}' "$ROOT/manifests/components.tsv")"
[ -n "$SKY1_KV" ] && ok "shipped Sky1 kernel: $SKY1_KV" || bad "cannot determine the shipped Sky1 kernel"
[ -n "$AMD_KV" ] && ok "shipped amd64 kernel: $AMD_KV" || bad "cannot determine the shipped amd64 kernel"
[ "$MAN_SKY1" = "$SKY1_KV" ] && ok "components.tsv sky1-mainline-kernel = $SKY1_KV" \
    || bad "components.tsv sky1-mainline-kernel '$MAN_SKY1' != shipped '$SKY1_KV'"
case "$SKY1_KV" in *-sky1-ncz) ok "shipped Sky1 kernel matches *-sky1-ncz" ;; *) bad "shipped Sky1 kernel '$SKY1_KV' does not match *-sky1-ncz" ;; esac
case "$AMD_KV" in *-sky1-ncz) bad "amd64 kernel '$AMD_KV' would match the Sky1 scan" ;; *) ok "amd64 kernel is not matched by the Sky1 scan" ;; esac

# --- helper cases ---------------------------------------------------------------------------
HAND=7.3.0-sky1-ncz      # a later kernel package installed by hand
OLD=7.2.8-sky1-ncz       # an older NCZ Sky1 kernel still on disk
# HAND must be a kernel the sidecar does NOT already name, or the "folded-in"
# case below degenerates: it expects SKY1_KV and HAND to be two different
# entries and the control to miss HAND. From r291 onward the shipped Sky1 KVER
# IS 7.3.0-sky1-ncz, so pinning HAND to that value made every one of those
# assertions self-contradictory. Derive a synthetic newer kernel from whatever
# ships, so the case stays meaningful as the pin moves forward.
if [ "$HAND" = "$SKY1_KV" ]; then
    HAND=7.3.1-sky1-ncz
fi
fix() {   # fix <dir> <sidecar or -> <kver...>  : meta/KVER_NEXT + usr/lib/modules/<kver>/
    local r="$1" side="$2"; shift 2
    rm -rf "$r"; mkdir -p "$r/meta" "$r/usr/lib/modules"
    [ "$side" = - ] || printf '%s\n' "$side" > "$r/meta/KVER_NEXT"
    for k in "$@"; do mkdir -p "$r/usr/lib/modules/$k/kernel"; done
}
R="$W/a"
fix "$R" "$SKY1_KV" "$SKY1_KV"
expect "sidecar kernel only" "sidecar $SKY1_KV" ncz_sky1_kernel_vers "$R/meta" "$R/usr/lib/modules"

fix "$R" "$SKY1_KV" "$SKY1_KV" "$HAND" "$OLD" "$AMD_KV" 7.1.0-1-arm64
expect "other NCZ Sky1 trees folded in, amd64/Debian trees ignored" \
    "$(printf 'sidecar %s\ndisk %s\ndisk %s' "$SKY1_KV" "$OLD" "$HAND")" \
    ncz_sky1_kernel_vers "$R/meta" "$R/usr/lib/modules"

ln -s usr/lib "$R/lib"
expect "/lib -> /usr/lib aliasing lists each kernel once" \
    "$(printf 'sidecar %s\ndisk %s\ndisk %s' "$SKY1_KV" "$OLD" "$HAND")" \
    ncz_sky1_kernel_vers "$R/meta" "$R/lib/modules" "$R/usr/lib/modules"

fix "$R" - "$HAND"
expect "no sidecar: disk kernels only" "disk $HAND" ncz_sky1_kernel_vers "$R/meta" "$R/usr/lib/modules"

fix "$R" "" "$HAND"
expect "empty sidecar is ignored" "disk $HAND" ncz_sky1_kernel_vers "$R/meta" "$R/usr/lib/modules"

fix "$R" "  $SKY1_KV  " "$SKY1_KV"
expect "sidecar whitespace is stripped (no duplicate)" "sidecar $SKY1_KV" ncz_sky1_kernel_vers "$R/meta" "$R/usr/lib/modules"

fix "$R" -
expect "nothing installed: no output" "" ncz_sky1_kernel_vers "$R/meta" "$R/usr/lib/modules" "$R/no-such-dir"

fix "$R" "$SKY1_KV" "$HAND"; : > "$R/usr/lib/modules/9.9.9-sky1-ncz"
expect "a plain file named like a kernel is not a module tree" \
    "$(printf 'sidecar %s\ndisk %s' "$SKY1_KV" "$HAND")" ncz_sky1_kernel_vers "$R/meta" "$R/usr/lib/modules"

fix "$R" "$SKY1_KV" "$HAND"
expect "NCZ_SKY1_MODULES_DIRS supplies the default module dirs" \
    "$(printf 'sidecar %s\ndisk %s' "$SKY1_KV" "$HAND")" \
    env NCZ_SKY1_MODULES_DIRS="$R/usr/lib/modules" bash -c '. "$1"; ncz_sky1_kernel_vers "$2"' _ "$LIB" "$R/meta"

# --- the hooks' own discovery block ---------------------------------------------------------
# Extract from KERNEL_LABELS=() to the unset line, run it with INSTALLER_META at the fixture and
# HERE at the repo's post-install/, print the resulting KERNEL_VERS.
hook_block() {   # hook_block <hook> <fixture>
    python3 - "$1" "$2" <<'PYX'
import sys
s = open(sys.argv[1]).read()
a = s.index("KERNEL_LABELS=()\n")
b = s.index("unset _kernels _src _kv\n", a) + len("unset _kernels _src _kv\n")
print(s[a:b].replace('HERE="$(dirname "$0")"', 'HERE="$NCZ_T_HERE"'))
PYX
}
run_hook_block() {   # run_hook_block <hook> <fixture> [no-lib]
    local blk here="$ROOT/post-install"
    blk="$(hook_block "$1" "$2")" || { echo "EXTRACT-FAILED"; return; }
    [ "${3:-}" = no-lib ] && here="$W/empty-here"
    mkdir -p "$W/empty-here"
    NCZ_T_HERE="$here" NCZ_SKY1_MODULES_DIRS="$2/usr/lib/modules" INSTALLER_META="$2/meta" \
        bash -c "$blk"'
for i in "${!KERNEL_VERS[@]}"; do echo "${KERNEL_LABELS[$i]} ${KERNEL_VERS[$i]}"; done' 2>&1 | grep -v '^\[8[01]\] NCZ Sky1 kernel'
}
for h in 80-npu 81-vpu; do
    HOOK="$ROOT/post-install/$h.sh"
    if grep -q '\*7\.2\*-ncz' "$HOOK"; then bad "$h.sh still scans *7.2*-ncz"; else ok "$h.sh no longer scans *7.2*-ncz"; fi
    grep -q 'lib/sky1-kernels.sh' "$HOOK" && ok "$h.sh uses lib/sky1-kernels.sh" || bad "$h.sh does not use lib/sky1-kernels.sh"
    fix "$R" "$SKY1_KV" "$SKY1_KV" "$HAND"
    expect "$h.sh: sidecar + hand-installed 7.3 kernel" \
        "$(printf 'mainline %s\nmainline %s' "$SKY1_KV" "$HAND")" run_hook_block "$HOOK" "$R"
    out="$(NCZ_T_HERE="$ROOT/post-install" NCZ_SKY1_MODULES_DIRS="$R/usr/lib/modules" INSTALLER_META="$R/meta" bash -c "$(hook_block "$HOOK" "$R")" 2>&1)"
    case "$out" in *"NCZ Sky1 kernel $HAND present but not in KVER_NEXT sidecar"*) ok "$h.sh: logs the folded-in kernel" ;; *) bad "$h.sh: no log line for the folded-in kernel ($out)" ;; esac
    expect "$h.sh: without the helper only the sidecar is used" "mainline $SKY1_KV" run_hook_block "$HOOK" "$R" no-lib
    fix "$R" -
    expect "$h.sh: nothing installed -> empty list" "" run_hook_block "$HOOK" "$R"
done

# --- VPU: a kernel without any amvx module is reported, not treated as in-tree ------------
grep -q "no amvx module for this kernel; VPU unavailable" "$ROOT/post-install/81-vpu.sh" \
    && ok "81-vpu.sh reports a kernel without any amvx module" \
    || bad "81-vpu.sh does not distinguish a kernel without an amvx module"

# --- control: the previous glob misses the 7.3 disk kernel ----------------------------------
old="$(git -C "$ROOT" show "$CONTROL_REF:post-install/81-vpu.sh" 2>/dev/null || true)"
if [ -z "$old" ]; then
    echo "skip control revision ${CONTROL_REF:0:12} not available in this clone"
else
    loop="$(printf '%s\n' "$old" | sed -n '/^for _mk in \/lib\/modules\/\*7\.2\*-ncz/,/^done$/p')"
    if [ -z "$loop" ]; then
        bad "control: no *7.2*-ncz loop at ${CONTROL_REF:0:12}"
    else
        fix "$R" "$SKY1_KV" "$SKY1_KV" "$HAND"
        loop="${loop//\/lib\/modules\//$R/lib-none/}"
        loop="${loop//\/usr$R\/lib-none\//$R/usr/lib/modules/}"
        got="$(KERNEL_VERS_INIT="$SKY1_KV" bash -c 'KERNEL_LABELS=(mainline); KERNEL_VERS=("$KERNEL_VERS_INIT")
'"$loop"'
printf "%s\n" "${KERNEL_VERS[@]}"' 2>/dev/null)"
        case "$got" in
            *"$HAND"*) bad "control: the old glob found $HAND (test cannot see the defect)" ;;
            *) ok "control: the *7.2*-ncz glob at ${CONTROL_REF:0:12} misses $HAND (defect detected)" ;;
        esac
    fi
fi

echo "# test-sky1-kernel-discovery: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
