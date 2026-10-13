#!/bin/bash
# test-ncz-cli-install-zeroclaw.sh -- assert the `ncz install zeroclaw`
# convenience alias is wired correctly. It's a thin wrapper over
# `ncz agent install zeroclaw`, so the only requirement is that the case
# arm is present and the function delegates to the agent helper rather
# than re-implementing the install path (which would break the agent-env
# + manifest closure the agent helper provides).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$ROOT/post-install/46-ncz-cli.sh"
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

[ -f "$HOOK" ] && ok "post-install/46-ncz-cli.sh exists" || bad "post-install/46-ncz-cli.sh missing"

# Function defined with the standard function-body shape.
grep -qE 'ncz_install_zeroclaw\(\) \{' "$HOOK" \
    && ok "ncz_install_zeroclaw function defined" \
    || bad "ncz_install_zeroclaw function missing"

# Delegates to the agent helper (not re-implementing install). The agent
# helper is the one place that knows about /etc/containers/systemd,
# /etc/nclawzero/agent-env, and the agent-images manifest; we want one
# canonical installer.
grep -q 'ncz agent install zeroclaw' "$HOOK" \
    && ok "ncz_install_zeroclaw delegates to 'ncz agent install zeroclaw'" \
    || bad "ncz_install_zeroclaw does NOT delegate to the agent installer"

# Dispatch wiring: `ncz install zeroclaw` case arm + help text.
grep -q 'zeroclaw)' "$HOOK" && ok "ncz_install case arm 'zeroclaw' present" \
    || bad "ncz_install case arm 'zeroclaw' missing"
grep -q 'ncz_install_zeroclaw' "$HOOK" \
    && grep -q 'install zeroclaw' "$HOOK" \
    && ok "ncz help documents 'install zeroclaw'" \
    || bad "ncz help does NOT document 'install zeroclaw'"

# Root guard: like every other ncz_install_* path, it requires root. The
# alias delegates to ncz agent install which has the same guard, but the
# outer wrapper should fail-fast too in case the inner helper is renamed.
grep -qE 'ncz_install_zeroclaw\(\) \{' "$HOOK" \
    && grep -A3 'ncz_install_zeroclaw() {' "$HOOK" | grep -q 'id -u' \
    && ok "ncz_install_zeroclaw requires root (no privilege bypass)" \
    || bad "ncz_install_zeroclaw does NOT guard on root"

echo "--- $pass passed, $fail failed"
[ "$fail" = "0" ]