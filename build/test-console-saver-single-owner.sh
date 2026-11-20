#!/bin/bash
# test-console-saver-single-owner.sh -- exactly one install step may write ncz-console-saver.service.
# 2026-11-14: hook 48 (server variant) overwrote hook 61 unit with an older one that Requires/After
# ncz-console-blank.service; blank is After=multi-user.target, so systemd dropped the saver from boot
# (ordering cycle) and the black-hole console saver never ran on two test machines or CIXMINI.
set -u
cd "$(dirname "$0")/.."
fail=0; bad() { echo "FAIL: $*"; fail=1; }; ok() { echo "ok:   $*"; }
writers=$(grep -l -E "(cat|tee|install|cp).*ncz-console-saver\.service" post-install/*.sh | tr "\n" " ")
case "$writers" in "post-install/61-ncz-console-saver.sh ") ok "only hook 61 writes ncz-console-saver.service";; *) bad "unit writers: ${writers:-none}";; esac
grep -q "/usr/local/sbin/ncz-console-saver <<" post-install/48-server-variant.sh && bad "hook 48 still writes the old sbin saver" || ok "hook 48 does not write an sbin saver"
grep -q "ExecStart=/usr/local/bin/ncz-console-saver" assets/console-saver/ncz-console-saver.service && ok "asset unit points at the installed daemon" || bad "asset unit ExecStart is not /usr/local/bin/ncz-console-saver"
! grep -q -E "^(Requires|After)=.*ncz-console-blank" assets/console-saver/ncz-console-saver.service && ok "asset unit has no ordering dependency on ncz-console-blank" || bad "asset unit orders against ncz-console-blank (cycle)"
# the unit set must have no ordering cycle: blank After=multi-user.target, saver must not require blank
exit $fail
