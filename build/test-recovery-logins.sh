#!/bin/bash
# test-recovery-logins.sh -- the installer diagnostics login is the documented rescue-partition
# login (root / rescue), it is shown while the installer runs (boot banner, every NCZ dialog, the
# post-install progress screen, Alt+F3, the Sky1 diagnostics UART), and docs/RECOVERY-LOGINS.md
# names only paths and commands that exist.
#
# Run: bash build/test-recovery-logins.sh     Exit 0 = pass, 1 = a case failed.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${NCZ_TEST_ROOT:-$(cd "$HERE/.." && pwd)}"
DOC="$ROOT/docs/RECOVERY-LOGINS.md"
PRE="$ROOT/preseed/preseed.cfg"
DC="$ROOT/preseed/diag-console.sh"
UI="$ROOT/preseed/ncz-ui.sh"
PASS=0; FAIL=0
ok()  { echo "  PASS  $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'; }

echo "== one documented login"
rescue=$(sed -n 's/^RESCUE_ROOT_PW="\${RESCUE_ROOT_PW:-\([^}]*\)}"$/\1/p' "$ROOT/build/build-rescue-rootfs.sh")
[ -n "$rescue" ] && ok "rescue partition default login read from build-rescue-rootfs.sh" || bad "no RESCUE_ROOT_PW default in build-rescue-rootfs.sh"
diag=$(sed -n 's/^PW=\$(kv ncz_diag_pw);.*PW=\${PW:-\([^}]*\)}$/\1/p' "$DC")
[ -n "$rescue" ] && [ "$diag" = "$rescue" ] && ok "diag-console.sh default login = the rescue login" || bad "diag-console.sh default '$diag' != rescue '$rescue'"
nc1=$(sed -n 's/^d-i network-console\/password password //p' "$PRE")
nc2=$(sed -n 's/^d-i network-console\/password-again password //p' "$PRE")
[ "$nc1" = "$rescue" ] && [ "$nc2" = "$rescue" ] && ok "network-console login = the rescue login" || bad "network-console login '$nc1'/'$nc2' != '$rescue'"
uid=$(sed -n 's/^NCZ_DIAG_LOGIN_DEFAULT=//p' "$UI")
[ "$uid" = "$rescue" ] && ok "the banner text names the same login" || bad "ncz-ui.sh NCZ_DIAG_LOGIN_DEFAULT '$uid' != '$rescue'"
if grep -rnE '\bdiags\b' "$ROOT/preseed" "$ROOT/README.md" "$ROOT/docs/REMOTE-ACCESS.md" "$DOC" | grep -v 'diagsh'; then
    bad "the retired installer login is still referenced"
else ok "the retired installer login is gone from preseed/ and the docs"; fi

echo "== shown while the installer runs"
ec="$(sed -n '/^d-i preseed\/early_command string/,/^d-i preseed\/early_command seen/p' "$PRE")"
printf '%s\n' "$ec" | grep -q 'NCZDL=$(ncz_ui_diag_login' && printf '%s\n' "$ec" | grep -q 'INSTALLER ${NCZREV:-unknown} ====${NCZDL:+ $NCZDL}' \
    && ok "early_command boot banner carries the login line" || bad "boot banner lacks the login line"
printf '%s\n' "$ec" | grep -q 'for V in /dev/tty1 /dev/tty3 /dev/console' && ok "banner goes to tty1, tty3 and the console" || bad "banner TTY list changed"
grep -qE '^[[:space:]]*"ncz-ui\.sh",' "$ROOT/build/iso/patch-initrd-t2-kernel.py" && ok "ncz-ui.sh is baked into the initrd" || bad "ncz-ui.sh not baked"
grep -q 'ncz_ui_diag_login' "$ROOT/preseed/late.sh" && grep -q 'NCZ_DIAG_LOGIN_LINE:+ Remote' "$ROOT/preseed/late.sh" \
    && ok "post-install progress screen repeats it" || bad "progress screen lacks it"
grep -q 'diagnostics login: root / \$PW' "$DC" && ok "Alt+F3 / serial summary repeats it" || bad "diag-console summary lacks it"
out=$(NCZ_UI_CMDLINE=/dev/null sh -c ". '$UI'; ncz_ui_diag_login")
[ "$out" = "diagnostics login: root / $rescue" ] && ok "banner text: '$out'" || bad "banner text '$out'"
grep -q -- '--require-login-line' "$ROOT/build/kvm-installer-ui-check.sh" && grep -q 'require_login_line' "$ROOT/build/check-installer-screens.py" \
    && ok "UI check asserts the login line on captured screens" || bad "UI check has no login-line assertion"
grep -q 'diagnostics login: root / \[\^ \]{4,}' "$ROOT/build/kvm-install-gate-gpt.sh" && ok "KVM gate asserts the banner login line" || bad "KVM gate has no banner assertion"
line="[NCZ 12:00:00] ==== NCZ-OS INSTALLER x ==== diagnostics login: root / $rescue"
if printf '%s\n' "$line" | python3 -c '
import re, sys
bad = [r"\[diag\]", r"\[ncz[^\]]*\]", r"(?i)password\s*[:=]|\(password", r"<ERR>"]
t = sys.stdin.read()
sys.exit(1 if any(re.search(b, t) for b in bad) else 0)'; then
    ok "the banner line passes the primary-console chatter rules"
else bad "the banner line trips check-installer-screens.py"; fi

echo "== docs/RECOVERY-LOGINS.md names what exists"
[ -f "$DOC" ] || { bad "docs/RECOVERY-LOGINS.md missing"; echo "recovery login tests: $PASS passed, $FAIL failed"; exit 1; }
missing=""
for p in $(grep -oE '`(build|preseed|post-install|docs)/[A-Za-z0-9._/-]+`' "$DOC" | tr -d '`' | sort -u); do
    [ -e "$ROOT/$p" ] || missing="$missing $p"
done
[ -z "$missing" ] && ok "every repo path the doc names exists" || bad "doc names missing paths:$missing"
for f in ncz_ui_diag_login RESCUE_ROOT_PW ncz_diag_pw ncz_diag=0 network-console/password ncz-rescue-net NCZRESCUE --require-login-line; do
    grep -rqF -- "$f" "$ROOT/preseed" "$ROOT/build" "$ROOT/post-install" && ok "doc term $f exists in the code" || bad "doc term $f not found in the code"
done
grep -q 'Rescue Partition (Console)' "$ROOT/README.md" && ok "rescue boot entry name matches the README" || bad "rescue entry name"
for port in 23 2222; do grep -q ":$port\|$port " "$ROOT/build/build-rescue-rootfs.sh" && ok "rescue port $port is configured" || bad "rescue port $port not in build-rescue-rootfs.sh"; done
grep -q 'dropbear' "$ROOT/build/build-rescue-rootfs.sh" && ok "dropbear is configured in the rescue rootfs" || bad "dropbear missing"
for l in README.md README.zh-CN.md docs/INDEX.md docs/REMOTE-ACCESS.md; do
    grep -q 'RECOVERY-LOGINS.md' "$ROOT/$l" && ok "$l links the doc" || bad "$l does not link docs/RECOVERY-LOGINS.md"
done
if grep -nE '192\.168\.|10\.[0-9]+\.[0-9]+\.[0-9]+' "$DOC"; then bad "doc carries an address"; else ok "doc carries no LAN addresses"; fi

echo "recovery login tests: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
