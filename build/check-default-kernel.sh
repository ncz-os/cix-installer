#!/usr/bin/env bash
# check-default-kernel.sh -- FAIL unless the default kernel proven for a built
# image is the 7.4-line kernel named in assets/kernel/default-kernel.json.
#
# Operator 2026-11-12 01:35Z: "(3) A gate in the image build that FAILS if the
# default kernel in the built image is not 7.3.3 (prove it fires: absent before
# the change, present after, on real data)".
# Operator 2026-11-16 (26.10 Cygnus PR4: "release will use 7.4 kernel, no edge
# and 7.3 will be retired"): the policy line is 7.4 and the gate FAILS any
# other line even when every pin agrees with it. 7.4 is the ONLY kernel line:
# 7.3.x is retired (no default, no rescue, no installer, no previous-kernel
# entry, no apt component for the image).
#
# Evidence checked (all real, from the run-dir / tree):
#   1. tree pins (assets/kernel/default-kernel.json vs the per-arch pin files)
#   2. every "Linux version <kver>" boot line in the kvm-gate serial/install
#      logs of the run-dir (installer medium AND the installed system)
#   3. the installer-kernel record the kvm-gate writes ("installer kernel /linux
#      is the pinned ... build (<kver>...)")
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARCH=""
RUN_DIR=""
while [ $# -gt 0 ]; do
    case "$1" in
        --arch) ARCH="$2"; shift 2 ;;
        --run-dir) RUN_DIR="$2"; shift 2 ;;
        --self-test) SELF_TEST=1; shift ;;
        *) echo "usage: $0 --arch <amd64|arm64> [--run-dir DIR] | --self-test" >&2; exit 2 ;;
    esac
done
[ -n "${SELF_TEST:-}" ] && exec bash "$ROOT/build/test-default-kernel-gate.sh"
[ -n "$ARCH" ] || { echo "check-default-kernel: FAIL: --arch required" >&2; exit 2; }

DK="$ROOT/assets/kernel/default-kernel.json"
[ -s "$DK" ] || { echo "check-default-kernel: FAIL: $DK missing" >&2; exit 1; }
EXPECT="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]]['kver'])" "$DK" "$ARCH")"
# Policy line, operator 2026-11-16: the default kernel must be 7.4 (the 7.4.0-rc3
# base is accepted for this release and moves to the final 7.4 kernel in a later
# PATCH release). Fail closed before any pin comparison -- a consistently-pinned
# 7.3.x (or any other) tree is still the wrong kernel (NG2-NC-004: a mismatch
# FAILS the build, it is never a stderr note).
case "$EXPECT" in
    7.4.*) : ;;
    *) echo "check-default-kernel: FAIL: default kernel '$EXPECT' is not 7.4 (operator 2026-11-16: release uses 7.4, 7.3 is retired)" >&2; exit 1 ;;
esac
case "$EXPECT" in
    7.3.*|7.3-*) echo "check-default-kernel: FAIL: default kernel '$EXPECT' is from the retired 7.3.x series (operator 2026-11-16)" >&2; exit 1 ;;
esac
MANIFEST="$ROOT/assets/kernel/amd64-stable-manifest.json"; [ "$ARCH" = arm64 ] && MANIFEST="$ROOT/assets/kernel/sky1-manifest.json"
[ -s "$MANIFEST" ] || { echo "check-default-kernel: FAIL: $MANIFEST missing" >&2; exit 1; }
VMLINUZ_READY=1
EXPECT_VMLINUZ="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['identity'].get('vmlinuz_sha256',''))" "$MANIFEST" 2>/dev/null || true)"
if [ -z "$EXPECT_VMLINUZ" ]; then
    # The manifest may legitimately be mid-transition: the pinned release build
    # is not staged yet, so its deb sha256s / vmlinuz identity CANNOT be
    # recorded without inventing them. That is a BLOCKED build, not a policy
    # violation -- say so and stop, instead of crashing on a missing key. A
    # real build host with the pool staged still fails closed below.
    if python3 -c "import json,sys;d=json.load(open(sys.argv[1]));sys.exit(0 if not (d.get('artifacts') or {}) else 1)" "$MANIFEST" 2>/dev/null; then
        echo "check-default-kernel: BLOCKED: $MANIFEST records no identity.vmlinuz_sha256 and no artifacts{} -- the pinned release build is not staged yet." >&2
        echo "check-default-kernel:          stage it (build/stage-amd64-kernel.sh) and record the -2 hashes before any image build." >&2
        exit 2
    fi
    echo "check-default-kernel: FAIL: $MANIFEST has no identity.vmlinuz_sha256" >&2
    exit 1
fi
# The record proves vmlinuz byte identity; the manifest's kernel_release binds
# those bytes to the policy kver, so a sha match is a kver match too (review
# finding 2). Fail closed if the manifest cannot state the binding.
MAN_KVER="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['identity']['kernel_release'])" "$MANIFEST" 2>/dev/null || true)"
[ -n "$MAN_KVER" ] || { echo "check-default-kernel: FAIL: manifest $MANIFEST has no identity.kernel_release" >&2; exit 1; }
[ "$MAN_KVER" = "$EXPECT" ] || { echo "check-default-kernel: FAIL: manifest kernel_release '$MAN_KVER' != default-kernel.json '$EXPECT'" >&2; exit 1; }
FAILS=0
note() { echo "check-default-kernel: $*"; }
fail() { echo "check-default-kernel: FAIL: $*"; FAILS=$((FAILS+1)); }

# 1. tree pins agree with the single source of truth
EXPECT_PKG="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]]['pkgversion'])" "$DK" "$ARCH" 2>/dev/null || true)"
[ -n "$EXPECT_PKG" ] || { echo "check-default-kernel: FAIL: default-kernel.json has no pkgversion for $ARCH" >&2; exit 1; }
if [ "$ARCH" = amd64 ]; then
    got="$(tr -d '[:space:]' < "$ROOT/assets/kernel/amd64-stable/KVER" 2>/dev/null || true)"
    [ "$got" = "$EXPECT" ] || fail "assets/kernel/amd64-stable/KVER '$got' != default-kernel.json '$EXPECT'"
    gotpkg="$(tr -d '[:space:]' < "$ROOT/assets/kernel/amd64-stable/PKGVERSION" 2>/dev/null || true)"
    [ "$gotpkg" = "$EXPECT_PKG" ] || fail "assets/kernel/amd64-stable/PKGVERSION '$gotpkg' != default-kernel.json '$EXPECT_PKG'"
else
    got="$(tr -d '[:space:]' < "$ROOT/assets/kernel/mainline.release" 2>/dev/null || true)"
    case "$got" in
        r*-"$EXPECT"-*) : ;;
        *) fail "assets/kernel/mainline.release '$got' does not name $EXPECT" ;;
    esac
    # The arm64 package version is <kver>+<rev>; the release name's rNNN is the rev.
    relrev=""
    case "$got" in r[0-9]*-*) relrev="${got%%-*}" ;; esac
    [ "$EXPECT_PKG" = "$EXPECT+$relrev" ] \
        || fail "default-kernel.json arm64 pkgversion '$EXPECT_PKG' != '$EXPECT+$relrev' (the staged release $got)"
fi
note "tree pins agree: default $ARCH kernel is $EXPECT (pkg $EXPECT_PKG)"

# 1b. item (2) coverage: "nothing older may be a default or an auto-selected
# boot entry in a new image" is enforced by build/verify-kernel-default-policy.sh
# (pre-existing policy gate: default kernel, RC_DEFAULT_ALLOWED=0, RETIRED never
# pinned); chain it here so the default-kernel gate cannot pass while the policy
# gate would fail.
if [ -x "$ROOT/build/verify-kernel-default-policy.sh" ]; then
    if bash "$ROOT/build/verify-kernel-default-policy.sh" --arch "$ARCH" >/dev/null 2>&1; then
        note "item(2) covered: verify-kernel-default-policy.sh OK ($ARCH)"
    else
        fail "verify-kernel-default-policy.sh failed for $ARCH (older kernel as default/auto-select?)"
    fi
fi

# 2+3. boot evidence from the run-dir
if [ -n "$RUN_DIR" ]; then
    [ -d "$RUN_DIR" ] || { fail "run-dir $RUN_DIR not found"; }
    bad=0; seen=0
    # logs/*.log, not just *kvm-gate*: the installer-kernel record the real
    # gate writes lives in logs/09-image.log (2026-11-12 real-data proof).
    # kvm-gate/target-logs/*/*.log: the install dmesg the real gate writes as
    # target-logs/cix-install/dmesg-install.log is boot evidence too (it is
    # the ONLY place the arm64 desktop gate's kernel banner appears,
    # 2026-11-14 -- the gate wrongly reported "no boot evidence" without it).
    # kvm-gate-options/*/: server-variant matrix runs write each install
    # option's evidence under kvm-gate-options/<opt>/ instead of kvm-gate/
    # (2026-11-14 real-data: the arm64 server run; "no boot evidence" was a
    # scope gap, not missing evidence). The option work dirs carry the boot
    # logs under several names (boot.log, serial0.log, install.log,
    # installer-probe.log), so scan all of them.
    for log in "$RUN_DIR"/kvm-gate/serial*.log "$RUN_DIR"/kvm-gate/install.log "$RUN_DIR"/kvm-gate/target-logs/*/*.log \
               "$RUN_DIR"/kvm-gate-options/*/*.log "$RUN_DIR"/kvm-gate-options/*/target-logs/*/*.log \
               "$RUN_DIR"/logs/*.log; do
        [ -s "$log" ] || continue
        while IFS= read -r line; do
            kv="$(printf '%s\n' "$line" | sed -n 's/.*Linux version \([0-9A-Za-z._+-]*\).*/\1/p')"
            [ -n "$kv" ] || continue
            seen=$((seen+1))
            if [ "$kv" != "$EXPECT" ]; then
                fail "$(basename "$log"): booted kernel '$kv' != expected '$EXPECT'"
                bad=1
            fi
        done < <(grep -h "Linux version " "$log" 2>/dev/null)
        # The real record is '<path>/linux is the pinned r2 vmlinuz (<label>):
        # <vmlinuz-sha256>' (logs/09-image.log) -- byte identity, not a kver
        # text. Match the trailing 64-hex sha against the tree manifest's
        # pinned vmlinuz identity; fall back to a 'build (<kver>)' tail if a
        # future gate emits one.
        while IFS= read -r line; do
            recsha="$(printf '%s\n' "$line" | sed -n 's/.*: \([0-9a-f]\{64\}\)[[:space:]]*$/\1/p')"
            if [ -n "$recsha" ]; then
                seen=$((seen+1))
                [ "$recsha" = "$EXPECT_VMLINUZ" ] || {
                    fail "$(basename "$log"): installer kernel vmlinuz sha '$recsha' != pinned '$EXPECT_VMLINUZ'"
                    bad=1; }
                continue
            fi
            kv="$(printf '%s\n' "$line" | sed -n 's/.*installer kernel .*\/linux is the pinned .* build (\([^,)]*\).*/\1/p')"
            [ -n "$kv" ] || continue
            seen=$((seen+1))
            if [ "$kv" != "$EXPECT" ]; then
                fail "$(basename "$log"): installer kernel record '$kv' != expected '$EXPECT'"
                bad=1
            fi
        done < <(grep -h "installer kernel .*\/linux is the pinned" "$log" 2>/dev/null)
    done
    if [ "$seen" = 0 ]; then
        fail "no boot evidence found in $RUN_DIR (no 'Linux version ' lines, no installer-kernel record) -- cannot prove the default kernel"
    elif [ "$bad" = 0 ]; then
        note "boot evidence clean: $seen kernel record(s) all match ($EXPECT / vmlinuz sha pinned)"
    fi
fi

if [ "$FAILS" = 0 ]; then
    note "OK -- default kernel $EXPECT ($ARCH) proven"
    exit 0
fi
note "$FAILS finding(s)"
exit 1
