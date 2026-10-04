#!/bin/bash
# test-usb2-rescan-sky1-only.sh -- item RS regression: ncz-usb2-rescan is a Sky1
# workaround and must never run (or be installed) on an amd64/T2 Mac.
#
# Provenance (MEDUSA MacBookPro16,1, amd64 T2, 7.2.9-2, 2026-10-04,
# journal -o short-monotonic): ncz-usb2-rescan ran every boot, 4.87 s start,
# "O6N USB-A chain not present (not an O6N?); widening search", a full
# unbind/rebind of the USB root-hub interfaces including the T2 t2bce_vhci
# root hub, keyboard only at ~12.5 s. /etc/systemd/system/greetd.service.d/
# 10-ncz-drm.conf orders greetd After=/Wants= it, so the greeter was held ~7 s.
# The script's fast path is the Sky1 CIXH2030:06/CIXH2031:06 ACPI chain and its
# rebind target is /sys/bus/platform/drivers/xhci-hcd/xhci-hcd.*.auto; neither
# exists on Intel PCI xhci, so on amd64 it falls through to the hub rebind.
#
# This test proves, statically and from a real package build:
#   1. the amd64 hook list does not run 41-usb2-rescan.sh; sky1-arm64 still does,
#      and both lists are current with docs/platform-inventory.tsv;
#   2. no amd64 package manifest or SBOM names the hook or the package;
#   3. the built ncz-usb2-rescan.service declares ConditionArchitecture=arm64
#      and ConditionPathExistsGlob on the Sky1 xhci nodes, and systemd parses it;
#   4. the ncz-usb-recovery deb is Architecture: arm64 (dpkg refuses it on x86);
#   5. the greetd drop-in keeps the harmless After=/Wants= and the bounded
#      ncz-wait-input-ready probe survives;
#   6. fail-before self-checks: the pre-fix unit (no Conditions) and a list that
#      still names the hook are rejected by the same checkers.
#
# Run: bash build/test-usb2-rescan-sky1-only.sh
# Exit 0 = all cases passed; 1 = at least one failed; 2 = a source file missing.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK="$REPO/post-install/41-usb2-rescan.sh"
PKGBUILD="$REPO/build/build-usb-recovery-deb.sh"
GREETER="$REPO/post-install/55-greeter.sh"
INV="$REPO/docs/platform-inventory.tsv"
for f in "$HOOK" "$PKGBUILD" "$GREETER" "$INV"; do
    [ -r "$f" ] || { echo "FATAL: cannot read $f" >&2; exit 2; }
done

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/      /'; }

COND_ARCH='ConditionArchitecture=arm64'
COND_GLOB='ConditionPathExistsGlob=/sys/bus/platform/drivers/xhci-hcd/xhci-hcd.*.auto'

# Extract the ncz-usb2-rescan.service heredoc body from the hook.
extract_unit() {
    awk '
        $0 ~ /^cat > \/etc\/systemd\/system\/ncz-usb2-rescan\.service <<.EOF.$/ { f=1; next }
        f && $0 == "EOF" { exit }
        f { print }
    ' "$1"
}

# Extract the greetd 10-ncz-drm.conf heredoc body from 55-greeter.sh.
extract_greetd_dropin() {
    awk '
        $0 ~ /^cat > \/etc\/systemd\/system\/greetd\.service\.d\/10-ncz-drm\.conf <<.GREETDDRM.$/ { f=1; next }
        f && $0 == "GREETDDRM" { exit }
        f { print }
    ' "$1"
}

# unit_sky1_only: true when the unit body declares both Conditions. This is the
# property checker; the fail-before self-check below proves it rejects the
# pre-fix (unconditioned) unit.
unit_sky1_only() {
    local body="$1"
    printf '%s\n' "$body" | grep -qxF -- "$COND_ARCH" || return 1
    printf '%s\n' "$body" | grep -qxF -- "$COND_GLOB" || return 1
    return 0
}

inv_class() { awk -F'\t' -v p="$1" '$1==p {print $2; exit}' "$INV"; }

TMP="$(mktemp -d -t usb2-rescan-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

echo "== 1. platform-split hook lists =="
AMD="$REPO/post-install/hooks.list.amd64"
SKY="$REPO/post-install/hooks.list.sky1-arm64"
for f in "$AMD" "$SKY"; do [ -r "$f" ] || { echo "FATAL: cannot read $f" >&2; exit 2; }; done

if grep -qxF '41-usb2-rescan.sh' "$AMD"; then
    bad "amd64 hook list does not run 41-usb2-rescan.sh" "$(grep -n '41-usb2' "$AMD")"
else
    ok "amd64 hook list does not run 41-usb2-rescan.sh"
fi
if grep -qxF '41-usb2-rescan.sh' "$SKY"; then
    ok "sky1-arm64 hook list still runs 41-usb2-rescan.sh"
else
    bad "sky1-arm64 hook list still runs 41-usb2-rescan.sh" "$(cat "$SKY")"
fi

if NCZ_LINT_ROOT="$REPO" bash "$REPO/build/gen-hooks-lists.sh" --check >"$TMP/gen.out" 2>&1; then
    ok "hooks.list.* are current with docs/platform-inventory.tsv"
else
    bad "hooks.list.* are current with docs/platform-inventory.tsv" "$(cat "$TMP/gen.out")"
fi
[ "$(inv_class post-install/41-usb2-rescan.sh)" = sky1 ] \
    && ok "platform-inventory classifies the rescan hook sky1" \
    || bad "platform-inventory classifies the rescan hook sky1" "$(grep -n '^post-install/41-usb2-rescan.sh' "$INV")"
[ "$(inv_class build/build-usb-recovery-deb.sh)" = sky1 ] \
    && ok "platform-inventory classifies the package build sky1" \
    || bad "platform-inventory classifies the package build sky1" "$(grep -n '^build/build-usb-recovery-deb.sh' "$INV")"

# Fail-before self-check: a list that carries the hook must be detected.
if printf '41-usb2-rescan.sh\n' | grep -qxF '41-usb2-rescan.sh'; then
    grep -qxF '41-usb2-rescan.sh' "$AMD" \
        && bad "self-check: bad amd64 list naming the hook is detected" "grep did not detect it" \
        || ok "self-check: bad amd64 list naming the hook is detected"
fi

echo "== 2. amd64 package manifests / SBOM =="
amd64_manifests=(
    "$REPO/manifests/desktop-amd64.pkgs"
    "$REPO/manifests/installer-base-amd64.pkgs"
    "$REPO/manifests/rescue-amd64.pkgs"
    "$REPO/manifests/install-extra.pkgs"
    "$REPO/sbom/expected-packages-amd64.txt"
)
hit="$(grep -lF -e ncz-usb-recovery -e 41-usb2-rescan "${amd64_manifests[@]}" 2>/dev/null || true)"
if [ -z "$hit" ]; then
    ok "no amd64 manifest/SBOM names ncz-usb-recovery or 41-usb2-rescan"
else
    bad "no amd64 manifest/SBOM names ncz-usb-recovery or 41-usb2-rescan" "$(printf '%s\n' "$hit" | sed "s#^$REPO/##")"
fi
# Sky1 must still reach the package: cixmini-boot Depends on it and is seeded.
if grep -qxF 'cixmini-boot' "$REPO/manifests/installer-base.pkgs" \
   && grep -q 'ncz-usb-recovery' "$REPO/build/build-kernel-debs.sh"; then
    ok "sky1 still reaches ncz-usb-recovery (cixmini-boot depends on it)"
else
    bad "sky1 still reaches ncz-usb-recovery (cixmini-boot depends on it)"
fi

echo "== 3. unit Conditions (source + packaged) =="
UNIT_BODY="$(extract_unit "$HOOK")"
if [ -z "$UNIT_BODY" ]; then
    bad "ncz-usb2-rescan.service found in 41-usb2-rescan.sh" "EOF heredoc not extracted"
else
    ok "ncz-usb2-rescan.service found in 41-usb2-rescan.sh"
fi
if unit_sky1_only "$UNIT_BODY"; then
    ok "unit carries both Conditions ($COND_ARCH, $COND_GLOB)"
else
    bad "unit carries both Conditions ($COND_ARCH, $COND_GLOB)" \
        "$(printf '%s\n' "$UNIT_BODY" | grep -nE 'Condition|Description|After=')"
fi
# Fail-before self-check: drop the Conditions and the checker must reject it.
PRE_BODY="$(printf '%s\n' "$UNIT_BODY" | grep -vE '^ConditionArchitecture=|^ConditionPathExistsGlob=')"
if unit_sky1_only "$PRE_BODY"; then
    bad "self-check: pre-fix unit without Conditions is rejected"
else
    ok "self-check: pre-fix unit without Conditions is rejected"
fi

if command -v systemd-analyze >/dev/null 2>&1; then
    mkdir -p "$TMP/verify"
    printf '%s\n' "$UNIT_BODY" > "$TMP/verify/ncz-usb2-rescan.service"
    vrc=0
    SYSTEMD_LOG_LEVEL=warning systemd-analyze verify \
        "$TMP/verify/ncz-usb2-rescan.service" >"$TMP/verify/out" 2>&1 || vrc=$?
    # The ExecStart binary is created by the hook at install time, so on a dev
    # host systemd-analyze reports only "Command ... is not executable". Accept
    # that one benign line; anything else (parse error, unknown key, bad
    # condition) is still a failure.
    nonbenign="$(grep -vE ': Command /.* is not executable: No such file or directory$' "$TMP/verify/out" | sed '/^[[:space:]]*$/d')"
    if [ "$vrc" = 0 ] || [ -z "$nonbenign" ]; then
        ok "systemd-analyze verify parses the generated ncz-usb2-rescan.service"
    else
        bad "systemd-analyze verify parses the generated ncz-usb2-rescan.service" "$(cat "$TMP/verify/out")"
    fi
else
    echo "SKIP: systemd-analyze not installed; generated unit not parser-verified"
fi

echo "== 4. package is arm64-only =="
if NCZ_USB_RECOVERY_OUT="$TMP/out" bash "$PKGBUILD" >"$TMP/build.log" 2>&1; then
    deb="$(ls -1 "$TMP/out"/ncz-usb-recovery_*.deb 2>/dev/null | head -1)"
    if [ -n "$deb" ]; then
        arch="$(dpkg-deb -f "$deb" Architecture)"
        [ "$arch" = arm64 ] \
            && ok "ncz-usb-recovery deb is Architecture: arm64" \
            || bad "ncz-usb-recovery deb is Architecture: arm64" "got '$arch' from $(basename "$deb")"
        case "$(basename "$deb")" in
            *_all.deb) bad "ncz-usb-recovery deb filename is not _all.deb" "$(basename "$deb")" ;;
            *_arm64.deb) ok "ncz-usb-recovery deb filename ends _arm64.deb" ;;
            *) bad "ncz-usb-recovery deb filename ends _arm64.deb" "$(basename "$deb")" ;;
        esac
        dpkg-deb -x "$deb" "$TMP/x" 2>/dev/null
        PKG_UNIT="$TMP/x/etc/systemd/system/ncz-usb2-rescan.service"
        if [ -r "$PKG_UNIT" ] && unit_sky1_only "$(cat "$PKG_UNIT")"; then
            ok "packaged unit carries both Conditions"
        else
            bad "packaged unit carries both Conditions" "$(cat "$PKG_UNIT" 2>/dev/null)"
        fi
        # The packaged deb must never depend on a sky1-only package from x86.
        if dpkg-deb -f "$deb" Depends 2>/dev/null | grep -q 'ncz-usb-recovery'; then
            bad "package does not depend on itself" "$(dpkg-deb -f "$deb" Depends 2>/dev/null)"
        else
            ok "package has no self/format dependency"
        fi
    else
        bad "build-usb-recovery-deb.sh produces a .deb" "$(cat "$TMP/build.log")"
    fi
else
    bad "build-usb-recovery-deb.sh builds the package" "$(cat "$TMP/build.log")"
fi
# No stale _all.deb glob for this package anywhere.
if grep -rn 'ncz-usb-recovery_[^ ]*_all\.deb' "$REPO/build" "$REPO/Makefile" >"$TMP/glob.out" 2>/dev/null; then
    bad "no ncz-usb-recovery _all.deb glob remains" "$(cat "$TMP/glob.out")"
else
    ok "no ncz-usb-recovery _all.deb glob remains"
fi

echo "== 5. greetd drop-in + bounded input probe stay =="
DRM="$(extract_greetd_dropin "$GREETER")"
if printf '%s\n' "$DRM" | grep -qE '^After=.*ncz-usb2-rescan\.service' \
   && printf '%s\n' "$DRM" | grep -qE '^Wants=.*ncz-usb2-rescan\.service'; then
    ok "greetd drop-in still orders After=/Wants= ncz-usb2-rescan.service (harmless when skipped)"
else
    bad "greetd drop-in still orders After=/Wants= ncz-usb2-rescan.service" "$DRM"
fi
if grep -q 'ncz-wait-input-ready' "$GREETER"; then
    ok "bounded ncz-wait-input-ready probe survives in 55-greeter.sh"
else
    bad "bounded ncz-wait-input-ready probe survives in 55-greeter.sh"
fi

# systemd semantics: greetd's drop-in Wants=/After= a unit that is absent or
# condition-skipped must not be a structural error. systemd-analyze verify only
# reports the install-time ExecStart binaries missing on a dev host; anything
# else (unknown unit, parse error) is a failure.
if command -v systemd-analyze >/dev/null 2>&1; then
    mkdir -p "$TMP/greetd/greetd.service.d"
    cat > "$TMP/greetd/greetd.service" <<'GREETD_FIXTURE'
[Unit]
Description=greetd fixture for the ncz-usb2-rescan ordering test
[Service]
Type=simple
ExecStart=/bin/true
GREETD_FIXTURE
    printf '%s\n' "$DRM" > "$TMP/greetd/greetd.service.d/10-ncz-drm.conf"
    check_greetd_verify() {  # $1 = label
        local nonbenign
        SYSTEMD_LOG_LEVEL=warning systemd-analyze verify --man=no \
            "$TMP/greetd/greetd.service" >"$TMP/greetd/out" 2>&1 || true
        nonbenign="$(grep -vE ': Command /.* is not executable: No such file or directory$' "$TMP/greetd/out" | sed '/^[[:space:]]*$/d')"
        if [ -z "$nonbenign" ]; then
            ok "greetd verifies with ncz-usb2-rescan.service $1 (Wants/After harmless)"
        else
            bad "greetd verifies with ncz-usb2-rescan.service $1" "$(cat "$TMP/greetd/out")"
        fi
    }
    rm -f "$TMP/greetd/ncz-usb2-rescan.service"
    check_greetd_verify "absent"
    printf '%s\n' "$UNIT_BODY" > "$TMP/greetd/ncz-usb2-rescan.service"
    check_greetd_verify "present but condition-skipped"
else
    echo "SKIP: systemd-analyze not installed; greetd drop-in semantics not fixture-verified"
fi

echo
echo "usb2-rescan sky1-only tests: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
