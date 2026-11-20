#!/bin/bash
# test-wpa-cfg80211-order.sh -- regression test for the O6N .3 boot failure
# (2026-11-14, 7.3.4-sky1-ncz): wpa_supplicant.service started ~6 s before
# cfg80211 loaded and died with "nl80211 generic netlink not found" because
# the nl80211 generic netlink socket does not exist until cfg80211 is up.
# Second regression (kvm-gate first boot, 2026-11-15): with no WiFi PHY at
# all (KVM guest), the unit went "loaded failed failed" -- it must be
# SKIPPED (inactive, never failed) on hardware-less machines (r287
# ncz-gpu-switcher precedent).
#
# The fix (post-install/33-network.sh, drop-in
# /etc/systemd/system/wpa_supplicant.service.d/ncz-ordering.conf):
#   [Unit]
#     After=systemd-modules-load.service   <- wait for module loading to finish
#     Wants=systemd-modules-load.service   <- pull it in if nothing else does
#   [Service]
#     ExecStartPre=/bin/sh -c '/usr/bin/udevadm settle --timeout=10 \
#                              --type=net || true'
#                                            <- bounded settle, net only,
#                                               non-fatal (never fail the unit)
#     ExecCondition=/bin/sh -c 'for i in $(seq 1 50); do \
#                                  test -d /sys/class/ieee80211 && exit 0; \
#                                  sleep 0.2; done; exit 1'
#                                            <- NOTE: ExecCondition= runs
#                                               BEFORE ExecStartPre=
#                                               (systemd.service(5)), so the
#                                               bounded wait for a late-binding
#                                               driver is INSIDE the condition;
#                                               no WiFi PHY -> exit 1 skips the
#                                               unit (inactive), never failed
#
# This checks the heredoc that the hook writes, not a live boot.
#   bash build/test-wpa-cfg80211-order.sh
#   NCZ_WPA_ROOT=<tree> bash build/test-wpa-cfg80211-order.sh
set -u
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="${NCZ_WPA_ROOT:-$(cd "$HERE/.." && pwd)}"
NET="$ROOT/post-install/33-network.sh"
W="$(mktemp -d "${TMPDIR:-/tmp}/wpa-cfg80211.XXXXXX")"
trap 'rm -rf "$W"' EXIT
PASS=0; FAILS=0
ok()  { echo "ok   $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL $1"; FAILS=$((FAILS+1)); }

[ -f "$NET" ] || { echo "FAIL hook missing: $NET"; exit 1; }

# Extract the ncz-ordering.conf heredoc written by 33-network.sh.
awk "/ncz-ordering.conf <<'WPADROPIN'/{f=1;next} /^WPADROPIN\$/{f=0} f" "$NET" > "$W/ordering.conf"

# 1. The drop-in directory is created and the file is written with sane perms.
grep -q 'install -d -m0755 /etc/systemd/system/wpa_supplicant.service.d' "$NET" \
    && ok "drop-in directory /etc/systemd/system/wpa_supplicant.service.d is created" \
    || bad "drop-in directory is not created by the hook"
grep -q 'cat > /etc/systemd/system/wpa_supplicant.service.d/ncz-ordering.conf' "$NET" \
    && ok "drop-in file ncz-ordering.conf is written" \
    || bad "ncz-ordering.conf is not written"
grep -q 'chmod 0644 /etc/systemd/system/wpa_supplicant.service.d/ncz-ordering.conf' "$NET" \
    && ok "drop-in is chmod 0644" \
    || bad "drop-in chmod missing"

[ -s "$W/ordering.conf" ] \
    && ok "heredoc ncz-ordering.conf is non-empty" \
    || bad "heredoc ncz-ordering.conf is empty or missing (fix not applied?)"

# 2. [Unit] ordering: start AFTER module loading, and WANT it pulled in.
grep -qx '\[Unit\]' "$W/ordering.conf" \
    && ok "drop-in has [Unit]" \
    || bad "drop-in missing [Unit]"
grep -q '^After=.*systemd-modules-load\.service' "$W/ordering.conf" \
    && ok "After= includes systemd-modules-load.service (cfg80211 loads via modules-load)" \
    || bad "After= does not include systemd-modules-load.service"
grep -q '^Wants=.*systemd-modules-load\.service' "$W/ordering.conf" \
    && ok "Wants= includes systemd-modules-load.service" \
    || bad "Wants= does not include systemd-modules-load.service"

# 3. [Service] ExecStartPre: bounded udev settle LIMITED TO net devices only.
grep -qx '\[Service\]' "$W/ordering.conf" \
    && ok "drop-in has [Service]" \
    || bad "drop-in missing [Service]"
grep -q '^ExecStartPre=.*udevadm settle.*--type=net' "$W/ordering.conf" \
    && ok "ExecStartPre runs 'udevadm settle ... --type=net' (net-only settle)" \
    || bad "ExecStartPre does not run a net-limited udevadm settle"
t=$(sed -n 's/.*--timeout=\([0-9][0-9]*\).*/\1/p' "$W/ordering.conf" | head -1)
[ -n "$t" ] && [ "$t" -le 30 ] \
    && ok "udevadm settle is bounded (--timeout=$t s, <=30; not an open-ended boot stall)" \
    || bad "udevadm settle timeout missing or >30 s (got '$t')"

# 4. The settle must NOT be unbounded / must stay in the drop-in (not replace
# the stock ExecStart). The stock unit is left intact: only [Unit]/[Service]
# additions are legal here; replacing ExecStart in a drop-in is not supported
# without overriding it, and we do not do that.
grep -q '^ExecStart=' "$W/ordering.conf" \
    && bad "drop-in replaces the stock ExecStart (not allowed)" \
    || ok "stock wpa_supplicant ExecStart is untouched"

# 5. (d5) hardware-less machines must SKIP the unit, never fail it
# (kvm-gate first boot 2026-11-15; r287 ncz-gpu-switcher precedent).
grep -q '^ExecCondition=.*test -d /sys/class/ieee80211' "$W/ordering.conf" \
    && ok "ExecCondition= gates on /sys/class/ieee80211 (no WiFi PHY -> skip)" \
    || bad "ExecCondition= missing: hardware-less guests would FAIL the unit instead of skipping"
grep -q '^ExecCondition=.*for i in .*sleep' "$W/ordering.conf" \
    && ok "the bounded wait lives INSIDE ExecCondition (runs before ExecStartPre)" \
    || bad "ExecCondition has no wait: late-binding WiFi drivers would be skipped on real hardware"
grep -q '^ExecCondition=.*exit 1' "$W/ordering.conf" \
    && ok "condition exits 1 after the bound: unit is SKIPPED (inactive), not failed" \
    || bad "condition does not exit 1: no-PHY machines would fall through to ExecStart and fail"
grep -q '^ExecStartPre=.*udevadm settle.*|| true' "$W/ordering.conf" \
    && ok "settle is non-fatal (|| true): a udevadm timeout cannot fail the unit" \
    || bad "settle is fatal: udevadm timeout would fail wpa_supplicant.service"

echo "wpa-cfg80211-order tests: $PASS passed, $FAILS failed"
exit "$([ "$FAILS" = 0 ] && echo 0 || echo 1)"
