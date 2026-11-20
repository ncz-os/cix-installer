#!/bin/bash
# check-t2-dkms-modules.sh -- KVM-gate assertion (operator ORDER #27(2),
# 2026-11-14): on amd64 the gate forces post-install/56-t2-dkms.sh's build
# (ncz_t2_dkms_force=1 on the rEFInd Install entry options -> preseed/late.sh
# exports NCZ_T2_DKMS_FORCE=1 -> the hook builds t2smc/t2gmux inside the VM
# against the shipped kernel), and this check asserts the gate evidence
# proves both modules exist for the shipped kernel:
#
#   * kvm-gate/target-logs/cix-install/56-t2-dkms.log -- the forced build
#     ran and reported BOTH modules "installed for <kver>", and neither was
#     ever "NOT installed"/FAILED. A DMI "skipping" line here means the
#     force flag never reached the hook.
#   * kvm-gate/first-boot-report.txt -- the in-guest ncz-module-abi-probe
#     (which modprobes every updates/extra module under the real booted
#     kernel) recorded a line for each of t2gmux and t2smc and neither is
#     a FAIL verdict. The gate itself (verify-module-abi.py --probe-report)
#     already fails the run on any FAIL or kernel-log reject; this check
#     adds the NAME PRESENCE the probe would otherwise not notice missing.
#
# WHY this exists (root-cause record, 2026-11-14): the amd64 desktop gate
# passed with module-abi-probe=modules:0 because 56-t2-dkms is DMI-gated to
# real T2 hardware and skipped on QEMU -- so no gate ever proved the image
# can build its T2 modules for its shipped kernel (the test machine 7.3.4 black
# screen class: t2gmux/t2smc absent, i915 deferred, amdgpu never probed).
#
# arm64: the T2 DKMS pair is amd64-only, but the arm64 images ship their own
# 5-module out-of-tree set (ORDER #30(3): "keep them asserted too"): aipu,
# amvx, mali_kbase, memory_group_manager, protected_memory_allocator (panthor is not shipped, 2026-11-14).
# Evidence = the same in-guest first-boot probe (56-t2-dkms is expected to
# platform-skip on arm64 and is NOT read there). Each of the 5 names must
# have a probe record; a SKIP (panthor blacklisted on the boot entry) is a
# skip, not a failure; any FAIL verdict or a probe summary with failures
# fails the check.
#
# Usage:
#   build/check-t2-dkms-modules.sh --arch <amd64|arm64> --run-dir <RUN_DIR>
#   build/check-t2-dkms-modules.sh --self-test
set -u

ARCH=""
RUN_DIR=""
while [ $# -gt 0 ]; do
    case "$1" in
        --arch)     ARCH="${2:-}"; shift 2 ;;
        --run-dir)  RUN_DIR="${2:-}"; shift 2 ;;
        --self-test) SELF_TEST=1; shift ;;
        -h|--help)  sed -n '2,30p' "$0"; exit 0 ;;
        *) echo "check-t2-dkms-modules: ERROR: unknown argument: $1" >&2; exit 2 ;;
    esac
done

say() { echo "check-t2-dkms-modules: $*"; }

# check_run ARCH RUN_DIR -- the real assertion. Returns 0/1, reports on stdout.
check_run() {
    local arch="$1" run="$2"
    # Gate evidence dir: the single-set layout is <run>/kvm-gate/; server-variant
    # matrix runs write each install option's work under
    # <run>/kvm-gate-options/<opt>/ (2026-11-14 real-data: the arm64 server run's
    # first-boot report + probe live there, and the check could not see them).
    # Fall back to the first kvm-gate-options/*/ dir that carries a first-boot
    # report; keep the classic path as the primary.
    local gatedir="$run/kvm-gate"
    if [ ! -f "$gatedir/first-boot-report.txt" ]; then
        local _d
        for _d in "$run"/kvm-gate-options/*/; do
            [ -d "$_d" ] || continue
            if [ -f "$_d/first-boot-report.txt" ]; then gatedir="${_d%/}"; break; fi
        done
    fi
    local fbr="$gatedir/first-boot-report.txt"
    local bad=0 m
    if [ "$arch" = arm64 ]; then
        if [ ! -f "$fbr" ]; then
            say "FAIL: no $fbr -- no first-boot report to read the module probe from"
            return 1
        fi
        # ORDER #30(3): assert the 6 out-of-tree modules the arm64 images ship.
        for m in aipu amvx mali_kbase memory_group_manager protected_memory_allocator; do
            if ! grep -q "^# module-abi: $m " "$fbr"; then
                say "FAIL: first-boot module-abi probe never saw $m -- one of the 6 arm64 out-of-tree modules is missing from the installed system"
                bad=1
            elif grep "^# module-abi: $m " "$fbr" | grep -q 'FAIL'; then
                say "FAIL: first-boot module-abi probe rejected $m:"
                grep "^# module-abi: $m " "$fbr" | grep 'FAIL' | sed 's/^/      /'
                bad=1
            fi
        done
        [ "$bad" = 0 ] || return 1
        local summary
        summary=$(grep '^# module-abi-probe=modules:' "$fbr" | tail -1)
        if [ -z "$summary" ]; then
            say "FAIL: first-boot report has no '# module-abi-probe=modules:' summary line"
            return 1
        fi
        case "$summary" in
            *' failed:0'*|*' failed:0 '*) : ;;
            *) say "FAIL: module-abi probe summary reports failures: $summary"; return 1 ;;
        esac
        say "OK -- arm64 5-module set present and probe-verified (aipu amvx mali_kbase memory_group_manager protected_memory_allocator; panthor is not shipped, operator 2026-11-14)"
        return 0
    fi
    if [ "$arch" != amd64 ]; then
        say "ERROR: --arch must be amd64 or arm64 (got '$arch')"
        return 2
    fi
    local log="$gatedir/target-logs/cix-install/56-t2-dkms.log"
    if [ ! -f "$log" ]; then
        say "FAIL: no $log -- the install hook chain did not log 56-t2-dkms"
        return 1
    fi
    if [ ! -f "$fbr" ]; then
        say "FAIL: no $fbr -- no first-boot report to read the module probe from"
        return 1
    fi

    # The hook must have taken the BUILD path, not the DMI skip.
    if grep -q '; skipping' "$log"; then
        say "FAIL: 56-t2-dkms skipped on DMI -- ncz_t2_dkms_force=1 never reached the hook (gate cmdline/late.sh wiring broken)"
        say "      $(grep -m1 '; skipping' "$log")"
        return 1
    fi
    if ! grep -q '\[56\] installing T2 DKMS modules against ' "$log"; then
        say "FAIL: 56-t2-dkms.log has no build attempt ('[56] installing T2 DKMS modules against')"
        return 1
    fi

    for m in t2smc t2gmux; do
        # Success line: "[56] installed for <kver>: t2smc/ver t2gmux/ver"
        if ! grep '^\[56\] installed for ' "$log" | grep -q "$m/"; then
            say "FAIL: 56-t2-dkms did not install $m for the shipped kernel (no '[56] installed for ... $m/' line)"
            bad=1
        fi
        if grep 'NOT installed' "$log" | grep -q "$m/"; then
            say "FAIL: 56-t2-dkms reported $m NOT installed/FAILED to build"
            bad=1
        fi
    done
    [ "$bad" = 0 ] || return 1

    # In-guest probe saw both names, with no FAIL verdict on either.
    for m in t2smc t2gmux; do
        if ! grep -q "^# module-abi: $m " "$fbr"; then
            say "FAIL: first-boot module-abi probe never saw $m -- the module is not on the installed system (updates/extra of the shipped kernel)"
            bad=1
        elif grep "^# module-abi: $m " "$fbr" | grep -q 'FAIL'; then
            say "FAIL: first-boot module-abi probe rejected $m:"
            grep "^# module-abi: $m " "$fbr" | grep 'FAIL' | sed 's/^/      /'
            bad=1
        fi
    done
    [ "$bad" = 0 ] || return 1

    local summary
    summary=$(grep '^# module-abi-probe=modules:' "$fbr" | tail -1)
    if [ -z "$summary" ]; then
        say "FAIL: first-boot report has no '# module-abi-probe=modules:' summary line"
        return 1
    fi
    case "$summary" in
        *' failed:0'*|*' failed:0 '*) : ;;
        *) say "FAIL: module-abi probe summary reports failures: $summary"; return 1 ;;
    esac

    say "OK -- t2smc + t2gmux built and probe-verified for the shipped kernel ($summary)"
    return 0
}

# --- self-test -------------------------------------------------------------
if [ "${SELF_TEST:-0}" = 1 ]; then
    T="$(mktemp -d -t t2dkms-check.XXXXXX)"; trap 'rm -rf "$T"' EXIT
    r=0
    # mkrun NAME -- creates the evidence skeleton
    mkrun() {
        mkdir -p "$T/$1/kvm-gate/target-logs/cix-install"
    }
    LOGW='[56] DMI: sys_vendor=QEMU product_name=Standard PC (Q35 + ICH9, 2009) (not a known T2 model); NCZ_T2_DKMS_FORCE=1 -- forcing T2 DKMS build (KVM gate)
[56] building t2smc/t2gmux against 1 KVER(s) from /usr/local/lib/cix-installer/KVER_LIST_AMD64
[56] installing T2 DKMS modules against 7.3.4-t2-ncz
[56] installed for 7.3.4-t2-ncz: t2smc/0.2 t2gmux/0.9
[56] installed total: [7.3.4-t2-ncz:  t2smc/0.2 t2gmux/0.9]
[56] DONE'
    FBRW='# first boot report 2026-11-14T00:00:00Z
# module-abi: t2smc OK (loaded)
# module-abi: t2gmux INFO accepted, init failed: ERROR: could not insert t2gmux: No such device
# module-abi-probe=modules:2 failed:0 skipped:0'

    # 1. good run passes
    mkrun good; printf '%s\n' "$LOGW" > "$T/good/kvm-gate/target-logs/cix-install/56-t2-dkms.log"
    printf '%s\n' "$FBRW" > "$T/good/kvm-gate/first-boot-report.txt"
    check_run amd64 "$T/good" >/dev/null && say "self-test PASS: good run accepted" || { say "self-test FAIL: good run rejected"; r=1; }

    # 2. DMI skip (force never reached the hook) fails
    mkrun skipped
    printf '%s\n' '[56] DMI: sys_vendor=QEMU product_name=Standard PC (Q35 + ICH9, 2009) (not a known T2 model); skipping' \
        > "$T/skipped/kvm-gate/target-logs/cix-install/56-t2-dkms.log"
    printf '%s\n' '# module-abi-probe=modules:0 failed:0 skipped:0' > "$T/skipped/kvm-gate/first-boot-report.txt"
    check_run amd64 "$T/skipped" >/dev/null && { say "self-test FAIL: DMI-skip run accepted"; r=1; } || say "self-test PASS: DMI-skip (force wiring broken) caught"

    # 3. build failure (gmux FAILED) fails
    mkrun buildfail
    printf '%s\n' "$LOGW" '[56]   t2gmux/0.9 FAILED to build against 7.3.4-t2-ncz' '[56] WARN: NOT installed for 7.3.4-t2-ncz: t2gmux/0.9' \
        > "$T/buildfail/kvm-gate/target-logs/cix-install/56-t2-dkms.log"
    printf '%s\n' "$FBRW" > "$T/buildfail/kvm-gate/first-boot-report.txt"
    check_run amd64 "$T/buildfail" >/dev/null && { say "self-test FAIL: build failure accepted"; r=1; } || say "self-test PASS: FAILED build caught"

    # 4. probe never saw the module (not on the installed system) fails
    mkrun nolist
    printf '%s\n' "$LOGW" > "$T/nolist/kvm-gate/target-logs/cix-install/56-t2-dkms.log"
    printf '%s\n' '# module-abi: t2smc OK (loaded)' '# module-abi-probe=modules:1 failed:0 skipped:0' \
        > "$T/nolist/kvm-gate/first-boot-report.txt"
    check_run amd64 "$T/nolist" >/dev/null && { say "self-test FAIL: missing probe line accepted"; r=1; } || say "self-test PASS: probe name absence caught"

    # 5. probe FAIL verdict fails
    mkrun probefail
    printf '%s\n' "$LOGW" > "$T/probefail/kvm-gate/target-logs/cix-install/56-t2-dkms.log"
    printf '%s\n' "$FBRW" '# module-abi: t2gmux FAIL rc=1 Exec format error' '# module-abi-probe=modules:2 failed:1 skipped:0' \
        > "$T/probefail/kvm-gate/first-boot-report.txt"
    check_run amd64 "$T/probefail" >/dev/null && { say "self-test FAIL: probe FAIL verdict accepted"; r=1; } || say "self-test PASS: probe FAIL verdict caught"

    # 6. arm64 good run passes (6 out-of-tree modules asserted via the probe;
    #    panthor SKIP blacklisted is a skip, not a failure)
    FBR64='# first boot report 2026-11-14T00:00:00Z
# module-abi: aipu OK (already loaded)
# module-abi: amvx OK (loaded)
# module-abi: mali_kbase OK (loaded)
# module-abi: memory_group_manager OK (loaded)
# module-abi: panthor SKIP blacklisted on this boot entry
# module-abi: protected_memory_allocator OK (loaded)
# module-abi-probe=modules:6 failed:0 skipped:1'
    mkrun a64good
    printf '%s\n' "$FBR64" > "$T/a64good/kvm-gate/first-boot-report.txt"
    check_run arm64 "$T/a64good" >/dev/null && say "self-test PASS: arm64 5-module run accepted" || { say "self-test FAIL: arm64 6-module run rejected"; r=1; }

    # 7. missing evidence files fail
    mkrun nolog
    check_run amd64 "$T/nolog" >/dev/null && { say "self-test FAIL: missing hook log accepted"; r=1; } || say "self-test PASS: missing evidence caught"

    # 8. arm64 with one of the 5 names absent from the probe fails
    mkrun a64missing
    printf '%s\n' "$FBR64" | grep -v 'aipu ' > "$T/a64missing/kvm-gate/first-boot-report.txt"
    check_run arm64 "$T/a64missing" >/dev/null && { say "self-test FAIL: arm64 missing-name accepted"; r=1; } || say "self-test PASS: arm64 missing-name caught"

    # 9. arm64 probe FAIL verdict fails
    mkrun a64fail
    printf '%s\n' "$FBR64" '# module-abi: mali_kbase FAIL rc=1 Exec format error' '# module-abi-probe=modules:6 failed:1 skipped:1' \
        > "$T/a64fail/kvm-gate/first-boot-report.txt"
    check_run arm64 "$T/a64fail" >/dev/null && { say "self-test FAIL: arm64 probe FAIL accepted"; r=1; } || say "self-test PASS: arm64 probe FAIL caught"

    # 10. arm64 without a first-boot report fails
    mkrun a64nolog
    check_run arm64 "$T/a64nolog" >/dev/null && { say "self-test FAIL: arm64 missing report accepted"; r=1; } || say "self-test PASS: arm64 missing report caught"

    # 11. server-variant layout: evidence under kvm-gate-options/<opt>/ (not
    #     kvm-gate/) is found (2026-11-14 real-data: the arm64 server run).
    mkdir -p "$T/opt64/kvm-gate-options/server-medium/target-logs/cix-install"
    printf '%s\n' "$LOGW" > "$T/opt64/kvm-gate-options/server-medium/target-logs/cix-install/56-t2-dkms.log"
    printf '%s\n' "$FBRW" > "$T/opt64/kvm-gate-options/server-medium/first-boot-report.txt"
    check_run amd64 "$T/opt64" >/dev/null && say "self-test PASS: kvm-gate-options layout accepted (amd64)" \
        || { say "self-test FAIL: kvm-gate-options layout rejected (amd64)"; r=1; }
    mkdir -p "$T/opt64a/kvm-gate-options/server-medium"
    printf '%s\n' "$FBR64" > "$T/opt64a/kvm-gate-options/server-medium/first-boot-report.txt"
    check_run arm64 "$T/opt64a" >/dev/null && say "self-test PASS: kvm-gate-options layout accepted (arm64)" \
        || { say "self-test FAIL: kvm-gate-options layout rejected (arm64)"; r=1; }

    # 12. kvm-gate/ preferred when both layouts carry evidence (classic wins)
    mkdir -p "$T/both/kvm-gate/target-logs/cix-install" "$T/both/kvm-gate-options/server-medium"
    printf '%s\n' "$LOGW" > "$T/both/kvm-gate/target-logs/cix-install/56-t2-dkms.log"
    printf '%s\n' "$FBRW" > "$T/both/kvm-gate/first-boot-report.txt"
    printf '%s\n' '# module-abi-probe=modules:0 failed:0 skipped:0' > "$T/both/kvm-gate-options/server-medium/first-boot-report.txt"
    check_run amd64 "$T/both" >/dev/null && say "self-test PASS: classic kvm-gate/ preferred when both present" \
        || { say "self-test FAIL: classic kvm-gate/ not preferred"; r=1; }

    # 13. options dirs present but carrying no evidence still fail
    mkdir -p "$T/optnone/kvm-gate-options/server-medium"
    check_run arm64 "$T/optnone" >/dev/null && { say "self-test FAIL: empty options dir accepted"; r=1; } \
        || say "self-test PASS: empty options dir caught"

    exit $r
fi

# --- real assertion --------------------------------------------------------
[ -n "$ARCH" ] && [ -n "$RUN_DIR" ] || { say "ERROR: need --arch and --run-dir (or --self-test)" >&2; exit 2; }
[ -d "$RUN_DIR" ] || { say "ERROR: run dir not found: $RUN_DIR" >&2; exit 2; }
check_run "$ARCH" "$RUN_DIR"
