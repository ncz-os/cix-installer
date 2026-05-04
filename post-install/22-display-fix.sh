#!/bin/bash
# 22-display-fix.sh — primary DRM card seat tagging for Sky1.
#
# Discovered 2026-05-03 on r8 install: Sky1 SoC exposes 5 linlondp DRM
# cards (CIXH5010_00 .. _04) corresponding to the 5 DPU pipes. udev
# default tags ALL of them as `master-of-seat` for seat0. Mutter
# (Wayland compositor) iterates seat-master cards and picks the lowest-
# numbered one (card0). On MS-R1, card0/1/2/4 are DISCONNECTED and
# only card3-DP-4 has the actual HDMI/DP output.
#
# Result without fix: gnome-shell starts cleanly, framebuffer renders,
# but output goes to a disconnected pipe → no greeter visible on the
# physical monitor.
#
# Fix: udev rule that strips master-of-seat from cards 0/1/2/4 and
# leaves only card3 tagged. Mutter then picks card3 = working display.
#
# IMPORTANT: this assumes card3 is the connected output on every MS-R1
# board. If a future MS-R1 BIOS revision shuffles the pipe-to-physical
# mapping, the rule will need a different selector (e.g., match on
# DRIVERS=="linlondp" + lookup connected child connector via
# /sys/class/drm/card$N-DP-*/status).
set -euo pipefail

echo "[22] writing udev rule to constrain seat-master to card3 only"

cat > /etc/udev/rules.d/73-cixmini-primary-display.rules <<'EOF'
# Sky1 has 5 linlondp DRM cards (CIXH5010_00..04, the 5 DPU pipes).
# Only card3 has the connected DP/HDMI output on MS-R1.
# Default udev tags ALL of them as master-of-seat → mutter picks card0
# which has no output → no greeter appears on screen.
# Strip master-of-seat from cards 0,1,2,4; keep only card3.
ACTION=="add|change", KERNEL=="card[0124]", SUBSYSTEM=="drm", DRIVERS=="linlondp", TAG-="master-of-seat", TAG-="seat"
EOF
chmod 0644 /etc/udev/rules.d/73-cixmini-primary-display.rules
# CRITICAL: filename priority must be > 71 so this rule fires AFTER
# systemd's /usr/lib/udev/rules.d/71-seat.rules (line 34) which adds
# master-of-seat to ALL drm cards unconditionally. A rule at 61 was
# overwritten by 71 — the TAG-= had no effect. Rule at 73 fires after
# 71 and successfully strips the tag.

echo "[22] rule written:"
cat /etc/udev/rules.d/73-cixmini-primary-display.rules

# Reload rules so they take effect on next boot (live-trigger doesn't
# always re-evaluate TAG- removals — reboot is the reliable apply).
udevadm control --reload-rules || true

echo "[22] DONE — applied at next boot"
