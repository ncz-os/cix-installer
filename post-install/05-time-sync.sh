#!/bin/bash
# 05-time-sync.sh — best-effort clock correction before ANY hook touches
# HTTPS (apt, curl, pip). Phase 0 (diag-affordance, non-blocking by design):
# runs before 10-our-kernel.sh, the first hook that needs a working apt.
#
# WHY THIS EXISTS
# ----------------
# Measured live 2026-08-27 on a KVM-gate install: the guest's clock was
# still near-epoch (dpkg.log briefly shows 1970-01-01 timestamps) when
# 10-our-kernel.sh ran, so EVERY HTTPS apt source failed TLS certificate
# verification -- including deb.debian.org itself, not just NCZ-specific
# mirrors. systemd-timesyncd is present and enabled, but its first sync
# had not landed yet: it needs the network up AND a round-trip, and
# nothing before this point waits for it. The failure was systemic (hit
# CORE_DESKTOP, Chrome, Buildkite packages, and GOA identically), not
# specific to any one package.
#
# This hook does not replace timesyncd -- it gives it a head start via a
# cert-free HTTP time source (no chicken-and-egg: you cannot validate a
# TLS certificate's validity period with a clock that might be the reason
# it looks invalid), then nudges timesyncd to sync properly over NTP for
# the long term.
#
# BEST-EFFORT, ALWAYS EXITS 0: an offline or air-gapped install must not
# be blocked or failed by this. If nothing here works, HTTPS-dependent
# hooks downstream still have their own existing non-fatal WARN handling
# (they degrade gracefully) -- this hook only widens the common case
# where a network exists but the clock has not caught up yet.
set -uo pipefail

echo "[05-time-sync] checking clock before any HTTPS-dependent hook runs"

now_year=$(date -u +%Y)
if [ "$now_year" -ge 2020 ] 2>/dev/null; then
    echo "[05-time-sync] clock already looks sane ($(date -u -Iseconds)); skipping correction"
    exit 0
fi

echo "[05-time-sync] clock looks wrong ($(date -u -Iseconds)) — attempting correction"

# Step 1: a plain-HTTP HEAD request needs no certificate at all, so it works
# regardless of how wrong the clock is. deb.debian.org serves both http and
# https; the http path answers with a valid Date: header either way.
corrected=0
for host in http://deb.debian.org http://ftp.debian.org http://http.us.debian.org; do
    date_hdr=$(timeout 8 curl -fsSI "$host" 2>/dev/null | grep -i '^date:' | head -1 | cut -d' ' -f2- | tr -d '\r')
    if [ -n "$date_hdr" ]; then
        if date -u -s "$date_hdr" >/dev/null 2>&1; then
            echo "[05-time-sync] clock set from $host Date: header -> $(date -u -Iseconds)"
            corrected=1
            break
        fi
    fi
done

if [ "$corrected" = 0 ]; then
    echo "[05-time-sync] WARN: no HTTP time source reachable — clock left as-is (offline install, or network not up yet); downstream HTTPS hooks will WARN and degrade gracefully"
    exit 0
fi

# Step 2: write the corrected time to the RTC if one exists, so it survives
# a reboot mid-install, and nudge timesyncd to take over for the long term
# now that it has a sane starting point to validate NTP responses against.
hwclock -w >/dev/null 2>&1 || true
if command -v timedatectl >/dev/null 2>&1; then
    timedatectl set-ntp true >/dev/null 2>&1 || true
fi
systemctl restart systemd-timesyncd >/dev/null 2>&1 || true

echo "[05-time-sync] done"
exit 0
