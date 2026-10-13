#!/bin/bash
# test-ncz-cli-install-zoder.sh -- assert the `ncz install zoder` path is
# statically intact: arch dispatch, pinned sha256, smoke test, idempotency,
# offline-safe error message, public-safe config template. Does NOT need
# a live host; pure source assertions on post-install/46-ncz-cli.sh.
#
# What this catches:
#  - regression on the arch dispatch table (drop a target triple = operators
#    on that arch can't install)
#  - regression on the pinned sha256 (a rotated upstream stops matching
#    and the install refuses, surfacing the value to the operator)
#  - regression on the smoke test (binary installs but doesn't run = exit
#    code contract broken)
#  - regression on the config template wording (a leaked fleet model route,
#    an internal endpoint, or an Anthropic reference all fail the public
#    docs gate)
#  - regression on the offline diagnostic (operators on a closed LAN need
#    a clear message, not the bare curl 7 they get from --connect-timeout)
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$ROOT/post-install/46-ncz-cli.sh"
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

[ -f "$HOOK" ] && ok "post-install/46-ncz-cli.sh exists" || bad "post-install/46-ncz-cli.sh missing"

# Arch dispatch table: both arches present, with pinned sha256 + tarball
# URL that points at the public ncz-os/zoder nightly release.
grep -q "x86_64)" "$HOOK" && ok "arch dispatch covers x86_64" || bad "arch dispatch missing x86_64"
grep -q "aarch64)" "$HOOK" && ok "arch dispatch covers aarch64" || bad "arch dispatch missing aarch64"
grep -q 'arch_url=.https://github.com/ncz-os/zoder/releases/download/nightly/zoder-x86_64-unknown-linux-gnu.tar.gz.' "$HOOK" \
    && ok "x86_64 tarball URL pinned to ncz-os/zoder nightly" \
    || bad "x86_64 tarball URL is not pinned to ncz-os/zoder nightly"
grep -q 'arch_url=.https://github.com/ncz-os/zoder/releases/download/nightly/zoder-aarch64-unknown-linux-gnu.tar.gz.' "$HOOK" \
    && ok "aarch64 tarball URL pinned to ncz-os/zoder nightly" \
    || bad "aarch64 tarball URL is not pinned to ncz-os/zoder nightly"

# Pinned sha256 for each arch. These are the sha256 of the OUTER TARBALL
# (per GitHub release asset digest). If upstream re-rolls the nightly, the
# install refuses and surfaces the mismatch — the operator bumps the pin
# and re-rolls ncz.
grep -qE 'arch_sha256=.b2ce794b0ee2dbd163672a4dfafc63582df48f41a288f1189ac26ccd6971e577' "$HOOK" \
    && ok "x86_64 tarball sha256 is set" \
    || bad "x86_64 tarball sha256 is missing or has drifted"
grep -qE 'arch_sha256=.bcec547fe1f29447fd71284cae4b14ae8b92459b5a5988692f38a53277decfd0' "$HOOK" \
    && ok "aarch64 tarball sha256 is set" \
    || bad "aarch64 tarball sha256 is missing or has drifted"

# Smoke test: zoder --version must run after install; an install that
# silently leaves a non-runnable binary fails the contract.
grep -q 'zoder --version' "$HOOK" && ok "install runs zoder --version smoke test" \
    || bad "install does NOT run zoder --version smoke test"

# Idempotency: an over-write re-run should not fail just because the
# destination exists. The pattern is install -D which overwrites — no
# "refusing to overwrite" branch.
grep -qE 'install -D -m 0755 "[$]extract_dir/[$]arch_dir/zoder" "[$]install_path"' "$HOOK" \
    && ok "install path uses install -D (overwrite-safe)" \
    || bad "install path does NOT use install -D"

# Offline diagnostic: when the network is down, the operator needs a clear
# "this system is offline / github.com unreachable" + retry command. The
# curl default error alone is unhelpful on a closed LAN.
grep -q 'this system is offline' "$HOOK" && ok "install prints offline diagnostic on download failure" \
    || bad "install does NOT print offline diagnostic"
grep -q 'sudo ncz install zoder' "$HOOK" && ok "install offline diagnostic mentions the retry command" \
    || bad "install offline diagnostic does NOT mention retry command"

# Defense against tampered tarball: outer sha256 + inner zoder sha256
# (manifest.json's `binaries.zoder` field). Both must be checked.
grep -q 'actual_tarball_sha' "$HOOK" && ok "install verifies outer tarball sha256" \
    || bad "install does NOT verify outer tarball sha256"
grep -q 'manifest.json' "$HOOK" && ok "install verifies inner zoder sha256 from manifest.json" \
    || bad "install does NOT verify inner zoder sha256"
grep -q 'expected_zoder_sha' "$HOOK" && ok "install surfaces the inner sha256 mismatch" \
    || bad "install does NOT surface inner sha256 mismatch"

# Config template at /etc/nclawzero/zoder.conf must be PUBLIC-SAFE: no
# secrets, no internal endpoints, no fleet model routes, no Anthropic.
# We assert the wording explicitly so a regression to a populated token /
# a fleet host / an Anthropic reference fails the docs gate.
grep -q '/etc/nclawzero/zoder.conf' "$HOOK" && ok "install stages /etc/nclawzero/zoder.conf" \
    || bad "install does NOT stage /etc/nclawzero/zoder.conf"
grep -q 'NO fleet model routes, NO internal endpoints, NO Anthropic' "$HOOK" \
    && ok "zoder.conf template is public-safe (no fleet routes, no Anthropic)" \
    || bad "zoder.conf template is NOT public-safe wording"
grep -q 'MNEMOS_URL + MNEMOS_TOKEN placeholders' "$HOOK" \
    && ok "zoder.conf template documents MNEMOS_URL/MNEMOS_TOKEN as placeholders" \
    || bad "zoder.conf template does NOT document placeholder nature"

# Manifest side-channel — /etc/zoder/manifest.json exposes the engine SHA +
# upstream SHA + run link for auditability. Without it the operator can't
# verify what's actually running.
grep -q '/etc/zoder/manifest.json' "$HOOK" && ok "install stages /etc/zoder/manifest.json" \
    || bad "install does NOT stage /etc/zoder/manifest.json"

# Dispatch wiring: `ncz install zoder` and `ncz install` help must both
# mention zoder, and the case arm must route to ncz_install_zoder.
grep -q 'zoder)' "$HOOK" && ok "ncz_install case arm 'zoder' present" \
    || bad "ncz_install case arm 'zoder' missing"
grep -qE 'ncz_install_zoder\(\) \{' "$HOOK" && ok "ncz_install_zoder function defined" \
    || bad "ncz_install_zoder function missing"
grep -q "Usage: ncz install" "$HOOK" && grep -q 'install zoder' "$HOOK" \
    && ok "ncz help documents 'install zoder'" \
    || bad "ncz help does NOT document 'install zoder'"

echo "--- $pass passed, $fail failed"
[ "$fail" = "0" ]
