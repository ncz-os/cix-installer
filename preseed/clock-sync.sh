#!/bin/sh
# clock-sync.sh -- installer clock correction, in the background, with a hard time bound.
#
# Started once, detached, by the first preseed/early_command run (baked at /ncz/clock-sync.sh, copied to
# /tmp/clock-sync.sh). It replaces two things:
#
#   1. d-i's clock-setup NTP step (preseed.cfg now sets clock-setup/ntp=false). clock-setup runs
#      `rdate -o 123 -nvv 0.debian.pool.ntp.org` IN THE FOREGROUND, between user-setup and disk-detect, and
#      rdate gives every address 15 s. MEASURED 2026-10-06 with the installer's own rdate-udeb binary (copied
#      from the O6N installer) in a network namespace whose default route silently drops packets:
#          one address           15.02 s   "Not enough valid responses received in time"
#          four addresses        60.07 s   (the pool name resolves to four)
#          no route at all        0.001 s  "Network is unreachable"
#      So on any network that filters UDP/123 the menu froze for a minute behind a progress bar. On the
#      measured installs it did not stall: CHIMERA's syslog shows 13:59:41 -> 13:59:55, but that 14 s is the
#      clock being STEPPED by +14.05 s ("rdate: adjust local clock by 14.046549 seconds"); rdate itself returned
#      within the second (PEGASUS +0.40 s, O6N +0.59 s, same second).
#   2. the inline "refine from the mirror Date header" subshell early_command used to carry (moved here
#      unchanged in behaviour: only when the clock is implausible, year < 2020, and SNTP did not answer).
#
# Order: wait (bounded) for a default route; wait (bounded) for rdate-udeb, which anna installs at
# load-cdrom; try SNTP once with a $BOUND s wall-clock limit; if that fails and the clock is still
# implausible, use the HTTP Date header of the pinned mirror. Every path exits 0 and nothing waits on it:
# the installer menu never blocks on time, offline installs simply keep the seeded clock. The installed
# system syncs with systemd-timesyncd on first boot and post-install/44-rtc-sync.sh writes the RTC then.
#
# Test seams: NCZ_CLOCK_LOG, NCZ_CLOCK_TTY, NCZ_CLOCK_TICK, NCZ_CLOCK_ROUTE_WAIT, NCZ_CLOCK_RDATE_WAIT,
# NCZ_CLOCK_BOUND, NCZ_CLOCK_SERVER, NCZ_CLOCK_URL, NCZ_IP, NCZ_RDATE, NCZ_WGET, NCZ_DATE, NCZ_CLOCK_YEAR.
LOG="${NCZ_CLOCK_LOG:-/var/log/early_command.log}"
TTY="${NCZ_CLOCK_TTY:-/dev/tty3}"
TICK="${NCZ_CLOCK_TICK:-2}"
ROUTE_WAIT="${NCZ_CLOCK_ROUTE_WAIT:-60}"
RDATE_WAIT="${NCZ_CLOCK_RDATE_WAIT:-90}"
BOUND="${NCZ_CLOCK_BOUND:-20}"
SERVER="${NCZ_CLOCK_SERVER:-0.debian.pool.ntp.org}"
URL="${NCZ_CLOCK_URL:-http://deb.debian.org/debian/dists/forky/Release}"
IP="${NCZ_IP:-ip}"
RDATE="${NCZ_RDATE:-rdate}"
WGET="${NCZ_WGET:-wget}"
DATE_SET="${NCZ_DATE:-date}"

log() { echo "[ncz-clock] $*" >> "$LOG" 2>/dev/null || true; }
year() { [ -n "${NCZ_CLOCK_YEAR:-}" ] && { echo "$NCZ_CLOCK_YEAR"; return; }; date -u +%Y 2>/dev/null || echo 1970; }

i=0
while [ "$i" -lt "$ROUTE_WAIT" ] ; do
    "$IP" route 2>/dev/null | grep -q "^default" && break
    i=$((i + 1)) ; sleep "$TICK"
done
if ! "$IP" route 2>/dev/null | grep -q "^default" ; then
    log "no default route after $((ROUTE_WAIT * TICK))s; clock left at $(date -u +%FT%TZ) (offline install)"
    exit 0
fi

j=0
while [ "$j" -lt "$RDATE_WAIT" ] && ! command -v "$RDATE" >/dev/null 2>&1 ; do
    j=$((j + 1)) ; sleep "$TICK"
done

synced=0
if command -v "$RDATE" >/dev/null 2>&1 ; then
    "$RDATE" -o 123 -n -s "$SERVER" >> "$LOG" 2>&1 </dev/null &
    pid=$!
    n=0
    while kill -0 "$pid" 2>/dev/null && [ "$n" -lt "$BOUND" ] ; do n=$((n + 1)) ; sleep 1 ; done
    if kill -0 "$pid" 2>/dev/null ; then
        kill "$pid" 2>/dev/null ; sleep 1 ; kill -9 "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null
        log "SNTP $SERVER gave no answer within ${BOUND}s (UDP/123 filtered?); stopped it"
    elif wait "$pid" ; then
        synced=1
        log "SNTP $SERVER set the clock: $(date -u +%FT%TZ)"
        echo "[ncz-clock] synced $(date -u +%FT%TZ)" > "$TTY" 2>/dev/null || true
    else
        log "SNTP $SERVER failed; clock left at $(date -u +%FT%TZ)"
    fi
else
    log "rdate not available after $((RDATE_WAIT * TICK))s; skipping SNTP"
fi

if [ "$synced" = 0 ] && [ "$(year)" -lt 2020 ] ; then
    _hdr=$("$WGET" -S -O /dev/null -T 5 "$URL" 2>&1 | sed -n "s/^[[:space:]]*[Dd][Aa][Tt][Ee]:[[:space:]]*//p" | head -1)
    _conv=$(echo "$_hdr" | awk '{ split("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec", a, " ") ; for (i = 1; i <= 12; i++) m[a[i]] = sprintf("%02d", i) ; if ($3 in m) printf "%s-%s-%s %s", $4, m[$3], $2, $5 }')
    if [ -n "$_conv" ] && "$DATE_SET" -u -s "$_conv" >/dev/null 2>&1 ; then
        log "refined from mirror Date header: $(date -u +%FT%TZ)"
        echo "[ncz-clock] refined $(date -u +%FT%TZ)" > "$TTY" 2>/dev/null || true
    fi
fi
exit 0
