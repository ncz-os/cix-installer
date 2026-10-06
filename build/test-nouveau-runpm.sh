#!/bin/bash
# test-nouveau-runpm.sh -- amd64 boots with nouveau.runpm=0, arm64 does not
# (PEGASUS install hang, 2026-10-06).
#
# PEGASUS (ASUS GU502LV, RTX 2060 Mobile TU106 10de:1f15, Optimus): on
# 7.3-rc5+ nouveau's runtime suspend oopses in nvkm_gsp_gcx_ready() (NULL
# gsp->rm, no GSP-RM firmware), the GPU stays in runtime_status "suspending"
# and every later PCI config read hangs (it hung the installer for 30+ min).
# Contract, each checked against the SHIPPED code:
#
#   1. installer: every amd64 rEFInd entry carries nouveau.runpm=0, no arm64
#      entry does (build/iso/tests/test_refind_nouveau_runpm.py);
#   2. installed system: the amd64 default + console entries carry it exactly
#      once, idempotently; the rescue entries blacklist nouveau; the arm64
#      refresh script never carries it;
#   3. preseed/late.sh writes /etc/modprobe.d/ncz-nouveau-runpm.conf on amd64
#      only, before run-all.sh starts the hooks.
#
# NCZ_TEST_ROOT=<tree> runs the checks against another checkout (used to show
# they fail on the pre-fix tree). Exit 0 = pass, 1 = fail.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="${NCZ_TEST_ROOT:-$(cd "$HERE/.." && pwd)}"
W="$(mktemp -d)" && [ -d "$W" ] || { echo "cannot create a scratch dir"; exit 2; }
trap 'rm -rf "$W"' EXIT
PASS=0; FAIL=0
ok()  { echo "  PASS  $1"; PASS=$((PASS + 1)); }
nok() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); }
extract_between() { awk -v b="$2" -v e="$3" '$0 ~ b {f=1; next} $0 ~ e {f=0} f' "$1"; }

echo "=== 1. installer rEFInd entries (amd64 has nouveau.runpm=0, arm64 not) ==="
if (cd "$ROOT/build/iso/tests" && python3 test_refind_nouveau_runpm.py > "$W/py.log" 2>&1); then
    ok "build-refind-esp.py: amd64 entries carry the token once, arm64 entries never"
else
    nok "build-refind-esp.py entry test failed:"; sed 's/^/        /' "$W/py.log"
fi

echo "=== 2. installed system rEFInd cmdline ==="
SRC="$ROOT/assets/refind/ncz-refind-refresh-amd64.sh"
extract_between "$SRC" 'NCZ-NOUVEAU-RUNPM-BEGIN' 'NCZ-NOUVEAU-RUNPM-END' > "$W/nv.sh"
extract_between "$SRC" 'NCZ-DEFAULT-OPTIONS-BEGIN' 'NCZ-DEFAULT-OPTIONS-END' > "$W/region.sh"
if [ -s "$W/nv.sh" ] && [ -s "$W/region.sh" ]; then
    # shellcheck disable=SC2034  # inputs of the sourced option-assembly region
    out=$(
        STABLE_AVAILABLE=1 ROOT_OPTS="root=PARTUUID=x rw" SPLASH="quiet" RESCUEPART_PARTUUID=y
        NCZ_T2_DEFAULT_EXTRA_CMDLINE=""
        ncz_is_t2_hardware() { return 1; }
        STABLE_CMDLINE_BASE="console=ttyS0,115200 console=tty0 systemd.condition_first_boot=false audit_backlog_limit=8192"
        . "$W/nv.sh"; . "$W/nv.sh"; . "$W/nv.sh"   # idempotent
        . "$W/region.sh"
        printf 'S=%s\nC=%s\nR=%s\n' "$STABLE_OPTIONS" "$STABLE_CONSOLE_OPTIONS" "$RESCUE_OPTIONS"
    )
    s=$(printf '%s\n' "$out" | sed -n 's/^S=//p'); c=$(printf '%s\n' "$out" | sed -n 's/^C=//p')
    r=$(printf '%s\n' "$out" | sed -n 's/^R=//p')
    n=$(printf '%s\n' "$s" | tr ' ' '\n' | grep -cx 'nouveau.runpm=0')
    [ "$n" = 1 ] && ok "default entry carries nouveau.runpm=0 exactly once after 3 refreshes" || nok "default entry has it $n times: $s"
    n=$(printf '%s\n' "$c" | tr ' ' '\n' | grep -cx 'nouveau.runpm=0')
    [ "$n" = 1 ] && ok "console entry carries nouveau.runpm=0 exactly once" || nok "console entry has it $n times: $c"
    case " $r " in *" module_blacklist="*nouveau*) ok "rescue entry blacklists nouveau outright" ;; *) nok "rescue entry lost its nouveau blacklist: $r" ;; esac
    # the block runs before any entry is assembled
    nl=$(grep -n 'NCZ-NOUVEAU-RUNPM-BEGIN' "$SRC" | head -1 | cut -d: -f1)
    ol=$(grep -n 'NCZ-DEFAULT-OPTIONS-BEGIN' "$SRC" | head -1 | cut -d: -f1)
    [ "$nl" -lt "$ol" ] && ok "cmdline block precedes option assembly" || nok "cmdline block after option assembly ($nl >= $ol)"
else
    nok "ncz-refind-refresh-amd64.sh: NCZ-NOUVEAU-RUNPM or NCZ-DEFAULT-OPTIONS markers missing"
fi
if grep -q 'nouveau' "$ROOT/assets/refind/ncz-refind-refresh.sh"; then
    nok "arm64 refresh script mentions nouveau"
else
    ok "arm64 refresh script (ncz-refind-refresh.sh) never carries nouveau options"
fi

echo "=== 3. late.sh writes the modprobe.d file on amd64 only, before run-all ==="
LATE="$ROOT/preseed/late.sh"
extract_between "$LATE" 'NCZ-NOUVEAU-RUNPM-BEGIN' 'NCZ-NOUVEAU-RUNPM-END' > "$W/late-nv.sh"
if [ -s "$W/late-nv.sh" ]; then
    sed "s#/target#$W/target#g" "$W/late-nv.sh" > "$W/late-nv-sb.sh"
    run_late() { # run_late <BUILD_ARCH or ""> -> leaves $W/target
        rm -rf "$W/target" "$W/src"; mkdir -p "$W/target/etc" "$W/src"
        [ -n "$1" ] && printf '%s\n' "$1" > "$W/src/BUILD_ARCH"
        # late.sh is #!/bin/sh with set -e (busybox ash in d-i): run it the same way
        SRC="$W/src" sh -ec ". '$W/late-nv-sb.sh'" > "$W/late.out" 2>&1
    }
    F="$W/target/etc/modprobe.d/ncz-nouveau-runpm.conf"
    if run_late amd64 && grep -qx 'options nouveau runpm=0' "$F" 2>/dev/null; then
        ok "amd64: /etc/modprobe.d/ncz-nouveau-runpm.conf carries 'options nouveau runpm=0'"
    else
        nok "amd64: modprobe.d file missing or wrong"; sed 's/^/        /' "$W/late.out"
    fi
    if run_late arm64 && [ ! -e "$F" ]; then
        ok "arm64: no modprobe.d file written"
    else
        nok "arm64: modprobe.d file was written (or the block failed)"
    fi
    nl=$(grep -n 'NCZ-NOUVEAU-RUNPM-BEGIN' "$LATE" | head -1 | cut -d: -f1)
    rl=$(grep -n 'chroot /target /usr/local/lib/cix-installer/post-install/run-all.sh' "$LATE" | head -1 | cut -d: -f1)
    [ -n "$rl" ] && [ "$nl" -lt "$rl" ] && ok "written before run-all.sh is invoked (line $nl < $rl)" || nok "not written before run-all.sh ($nl vs $rl)"
else
    nok "late.sh: NCZ-NOUVEAU-RUNPM markers missing"
fi


echo
echo "test-nouveau-runpm: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
