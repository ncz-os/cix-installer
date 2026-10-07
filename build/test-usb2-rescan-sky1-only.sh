#!/bin/bash
# test-usb2-rescan-sky1-only.sh -- item RS: ncz-usb2-rescan is a Sky1 workaround
# and must not be installed or run on an amd64/T2 Mac.
#
# Provenance (MEDUSA MacBookPro16,1, amd64 T2, 7.2.9-2, 2026-10-04): the unit ran
# every boot, 4.87 s start, "O6N USB-A chain not present (not an O6N?); widening
# search", a full root-hub unbind/rebind including the T2 t2bce_vhci root hub,
# keyboard only at ~12.5 s. Its fast path (CIXH2030:06/CIXH2031:06) and its
# rebind target (/sys/bus/platform/drivers/xhci-hcd/xhci-hcd.*.auto) do not
# exist on Intel PCI xhci, so on amd64 it could only fall through to the hub
# rebind. The greetd drop-in and its systemd semantics are tested separately in
# test-usb2-rescan-greetd.sh.
#
# Proves: (1) the amd64 hook list omits 41-usb2-rescan.sh and sky1-arm64 keeps
# it, both current with docs/platform-inventory.tsv; (2) no amd64 package
# manifest/SBOM names it; (3) the built unit carries ConditionArchitecture=arm64
# + ConditionPathExistsGlob on the Sky1 xhci nodes, and systemd parses it;
# (4) the deb is Architecture: arm64 and no _all.deb glob remains. Fail-before
# self-checks are included.
#
# Run: bash build/test-usb2-rescan-sky1-only.sh
# Exit 0 = all cases passed; 1 = a case failed; 2 = a source file missing.
set -uo pipefail
# Hermetic: the version gate must read a fixture index, never the live Buildkite one.
export NCZ_PUBLISHED_INDEX="${NCZ_PUBLISHED_INDEX:-/dev/null}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK="$REPO/post-install/41-usb2-rescan.sh"
PKGBUILD="$REPO/build/build-usb-recovery-deb.sh"
INV="$REPO/docs/platform-inventory.tsv"
for f in "$HOOK" "$PKGBUILD" "$INV"; do
    [ -r "$f" ] || { echo "FATAL: cannot read $f" >&2; exit 2; }
done

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/      /'; }

COND_ARCH='ConditionArchitecture=arm64'
COND_GLOB='ConditionPathExistsGlob=/sys/bus/platform/drivers/xhci-hcd/xhci-hcd.*.auto'

extract_unit() {
    awk '
        $0 ~ /^cat > \/etc\/systemd\/system\/ncz-usb2-rescan\.service <<.EOF.$/ { f=1; next }
        f && $0 == "EOF" { exit }
        f { print }
    ' "$1"
}
unit_sky1_only() {
    local body="$1"
    printf '%s\n' "$body" | grep -qxF -- "$COND_ARCH" || return 1
    printf '%s\n' "$body" | grep -qxF -- "$COND_GLOB" || return 1
}
inv_class() { awk -F'\t' -v p="$1" '$1==p {print $2; exit}' "$INV"; }

TMP="$(mktemp -d -t usb2-rescan-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

echo "== 1. platform-split hook lists =="
AMD="$REPO/post-install/hooks.list.amd64"
SKY="$REPO/post-install/hooks.list.sky1-arm64"
for f in "$AMD" "$SKY"; do [ -r "$f" ] || { echo "FATAL: cannot read $f" >&2; exit 2; }; done
grep -qxF '41-usb2-rescan.sh' "$AMD" \
    && bad "amd64 hook list does not run 41-usb2-rescan.sh" "$(grep -n '41-usb2' "$AMD")" \
    || ok "amd64 hook list does not run 41-usb2-rescan.sh"
grep -qxF '41-usb2-rescan.sh' "$SKY" \
    && ok "sky1-arm64 hook list still runs 41-usb2-rescan.sh" \
    || bad "sky1-arm64 hook list still runs 41-usb2-rescan.sh" "$(cat "$SKY")"
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
# Fail-before proof: the exact grep that guards the amd64 list detects the hook.
printf '41-usb2-rescan.sh\n' | grep -qxF '41-usb2-rescan.sh' \
    && ok "self-check: a bad amd64 list naming the hook is detected" \
    || bad "self-check: a bad amd64 list naming the hook is detected"

echo "== 2. amd64 package manifests / SBOM =="
amd64_files=(
    "$REPO/manifests/desktop-amd64.pkgs"
    "$REPO/manifests/installer-base-amd64.pkgs"
    "$REPO/manifests/rescue-amd64.pkgs"
    "$REPO/manifests/install-extra.pkgs"
    "$REPO/sbom/expected-packages-amd64.txt"
)
if hit="$(grep -lF -e ncz-usb-recovery -e 41-usb2-rescan "${amd64_files[@]}" 2>/dev/null)" && [ -n "$hit" ]; then
    bad "no amd64 manifest/SBOM names ncz-usb-recovery or 41-usb2-rescan" "$(printf '%s\n' "$hit" | sed "s#^$REPO/##")"
else
    ok "no amd64 manifest/SBOM names ncz-usb-recovery or 41-usb2-rescan"
fi
if grep -qxF 'cixmini-boot' "$REPO/manifests/installer-base.pkgs" \
   && grep -q 'ncz-usb-recovery' "$REPO/build/build-kernel-debs.sh"; then
    ok "sky1 still reaches ncz-usb-recovery (cixmini-boot depends on it)"
else
    bad "sky1 still reaches ncz-usb-recovery (cixmini-boot depends on it)"
fi

echo "== 3. unit Conditions and package arch =="
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
# Fail-before proof: without the Conditions the same checker rejects the unit.
if unit_sky1_only "$(printf '%s\n' "$UNIT_BODY" | grep -vE '^ConditionArchitecture=|^ConditionPathExistsGlob=')"; then
    bad "self-check: pre-fix unit without Conditions is rejected"
else
    ok "self-check: pre-fix unit without Conditions is rejected"
fi
if command -v systemd-analyze >/dev/null 2>&1; then
    mkdir -p "$TMP/verify"
    printf '%s\n' "$UNIT_BODY" > "$TMP/verify/ncz-usb2-rescan.service"
    SYSTEMD_LOG_LEVEL=warning systemd-analyze verify \
        "$TMP/verify/ncz-usb2-rescan.service" >"$TMP/verify/out" 2>&1 || true
    # ExecStart is created at install time; accept only that benign line.
    # verify also reports on unrelated units installed on the test host
    # (/etc/systemd/system/*), so judge only lines about OUR unit.
    nonbenign="$(grep -F 'ncz-usb2-rescan.service' "$TMP/verify/out" | grep -vE ': Command /.* is not executable: No such file or directory$' | sed '/^[[:space:]]*$/d')"
    [ -z "$nonbenign" ] \
        && ok "systemd-analyze verify parses the generated ncz-usb2-rescan.service" \
        || bad "systemd-analyze verify parses the generated ncz-usb2-rescan.service" "$(cat "$TMP/verify/out")"
else
    echo "SKIP: systemd-analyze not installed"
fi

if NCZ_USB_RECOVERY_OUT="$TMP/out" bash "$PKGBUILD" >"$TMP/build.log" 2>&1; then
    deb="$(ls -1 "$TMP/out"/ncz-usb-recovery_*.deb 2>/dev/null | head -1)"
    if [ -n "$deb" ]; then
        arch="$(dpkg-deb -f "$deb" Architecture)"
        [ "$arch" = arm64 ] \
            && ok "ncz-usb-recovery deb is Architecture: arm64" \
            || bad "ncz-usb-recovery deb is Architecture: arm64" "got '$arch' from $(basename "$deb")"
        case "$(basename "$deb")" in
            *_arm64.deb) ok "ncz-usb-recovery deb filename ends _arm64.deb" ;;
            *)           bad "ncz-usb-recovery deb filename ends _arm64.deb" "$(basename "$deb")" ;;
        esac
        dpkg-deb -x "$deb" "$TMP/x" 2>/dev/null
        PKG_UNIT="$TMP/x/etc/systemd/system/ncz-usb2-rescan.service"
        [ -r "$PKG_UNIT" ] && unit_sky1_only "$(cat "$PKG_UNIT")" \
            && ok "packaged unit carries both Conditions" \
            || bad "packaged unit carries both Conditions" "$(cat "$PKG_UNIT" 2>/dev/null)"
    else
        bad "build-usb-recovery-deb.sh produces a .deb" "$(cat "$TMP/build.log")"
    fi
else
    bad "build-usb-recovery-deb.sh builds the package" "$(cat "$TMP/build.log")"
fi
if grep -rn 'ncz-usb-recovery_[^ ]*_all\.deb' "$REPO/build" "$REPO/Makefile" >"$TMP/glob.out" 2>/dev/null; then
    bad "no ncz-usb-recovery _all.deb glob remains" "$(cat "$TMP/glob.out")"
else
    ok "no ncz-usb-recovery _all.deb glob remains"
fi

echo
echo "usb2-rescan sky1-only tests: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
