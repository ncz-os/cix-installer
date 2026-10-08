#!/bin/bash
# test-usb2-rescan-greetd.sh -- item RS: greetd must survive ncz-usb2-rescan
# being absent or condition-skipped.
#
# post-install/55-greeter.sh writes
# /etc/systemd/system/greetd.service.d/10-ncz-drm.conf with
# After=/Wants=ncz-usb2-rescan.service. That is required on Sky1 (the unit must
# finish before the greeter) and is compiled in on every platform by the COMMON
# greeter hook. On amd64 the unit is no longer installed and, even if it lands,
# its ConditionArchitecture=arm64 makes it a no-op. A Wants=/After= on a unit
# that does not exist (or is skipped) must be harmless -- systemd enqueues the
# job, the condition check fails, and the unit goes inactive without running
# ExecStart. This test fixture-verifies that with systemd-analyze and proves the
# bounded ncz-wait-input-ready probe is untouched.
#
# Run: bash build/test-usb2-rescan-greetd.sh
# Exit 0 = all cases passed; 1 = a case failed; 2 = a source file missing.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK="$REPO/post-install/41-usb2-rescan.sh"
GREETER="$REPO/post-install/55-greeter.sh"
for f in "$HOOK" "$GREETER"; do [ -r "$f" ] || { echo "FATAL: cannot read $f" >&2; exit 2; }; done

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/      /'; }

extract_greetd_dropin() {
    awk '
        $0 ~ /^cat > \/etc\/systemd\/system\/greetd\.service\.d\/10-ncz-drm\.conf <<.GREETDDRM.$/ { f=1; next }
        f && $0 == "GREETDDRM" { exit }
        f { print }
    ' "$1"
}
extract_unit() {
    awk '
        $0 ~ /^cat > \/etc\/systemd\/system\/ncz-usb2-rescan\.service <<.EOF.$/ { f=1; next }
        f && $0 == "EOF" { exit }
        f { print }
    ' "$1"
}

TMP="$(mktemp -d -t usb2-rescan-greetd.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

echo "== greetd drop-in + bounded input probe =="
DRM="$(extract_greetd_dropin "$GREETER")"
if printf '%s\n' "$DRM" | grep -qE '^After=.*ncz-usb2-rescan\.service' \
   && printf '%s\n' "$DRM" | grep -qE '^Wants=.*ncz-usb2-rescan\.service'; then
    ok "greetd drop-in still orders After=/Wants= ncz-usb2-rescan.service (harmless when skipped)"
else
    bad "greetd drop-in no longer orders After=/Wants= ncz-usb2-rescan.service" "$DRM"
fi
if grep -q 'ncz-wait-input-ready' "$GREETER"; then
    ok "bounded ncz-wait-input-ready probe survives in 55-greeter.sh"
else
    bad "bounded ncz-wait-input-ready probe is missing from 55-greeter.sh"
fi

if command -v systemd-analyze >/dev/null 2>&1; then
    UNIT_BODY="$(extract_unit "$HOOK")"
    [ -n "$UNIT_BODY" ] || bad "ncz-usb2-rescan.service extracted for the fixture" "EOF heredoc not extracted"
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
        # Only the install-time ExecStart binaries are absent on a dev host.
        # systemd-analyze also lints every unit already installed on the host
        # (e.g. /etc/systemd/system/fleet-net-tune.service on the build hosts),
        # which says nothing about the fixture; judge only diagnostics that name
        # the fixture units or its directory.
        nonbenign="$(grep -E "greetd\\.service|ncz-usb2-rescan\\.service|$TMP/greetd" "$TMP/greetd/out" \
            | grep -vE ': Command /.* is not executable: No such file or directory$' | sed '/^[[:space:]]*$/d')"
        [ -z "$nonbenign" ] \
            && ok "greetd verifies with ncz-usb2-rescan.service $1 (Wants/After harmless)" \
            || bad "greetd verifies with ncz-usb2-rescan.service $1" "$(cat "$TMP/greetd/out")"
    }
    rm -f "$TMP/greetd/ncz-usb2-rescan.service"
    check_greetd_verify "absent"
    printf '%s\n' "$UNIT_BODY" > "$TMP/greetd/ncz-usb2-rescan.service"
    check_greetd_verify "present but condition-skipped"
else
    echo "SKIP: systemd-analyze not installed; drop-in semantics not fixture-verified"
fi

echo
echo "usb2-rescan greetd tests: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
