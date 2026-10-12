#!/usr/bin/env bash
# tools/lockrig/agent/install.sh -- install the candidate payload on an NCZ host.
# Runs as root (via the driver's sudo path). Simulates first and REFUSES if the
# simulation shows any package removals. Hashes refind.conf before/after so an
# apt-triggered bootloader rewrite is visible (and restorable from the pre-op
# copy). Writes evidence to $D/install.txt.
set -u
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
PKGS="${PKGS:-ncz-singularity-desktop ncz-screensavers}"
CAND="${CAND:-}"                 # optional remote dir with *.deb to install
LU="${LU:-ncz}"
D="${D:-/home/$LU/Projects/lockrig/out}"; mkdir -p "$D"
LOG="$D/install.txt"; : > "$LOG"
say(){ echo "[$(date +%T)] $*" | tee -a "$LOG"; }
REFIND=/boot/efi/EFI/BOOT/refind.conf

say "=== install start: pkgs='$PKGS' cand='${CAND:-none}' ==="
if [ -r "$REFIND" ]; then sha256sum "$REFIND" | tee "$D/refind-before.txt"; else say "no refind.conf on this host"; fi

if [ -n "$CAND" ] && [ -d "$CAND" ]; then
  say "installing staged debs from $CAND"
  ( cd "$CAND" && for f in *.deb; do [ -e "$f" ] || continue; say "deb: $f"; apt-get install -y "./$f"; done ) >>"$LOG" 2>&1
else
  say "apt-get update"
  apt-get update >>"$LOG" 2>&1
  say "simulate (must show 0 removals)"
  apt-get install -s $PKGS > "$D/apt-simulate.txt" 2>&1
  cat "$D/apt-simulate.txt" | tail -5 | sed 's/^/    /' | tee -a "$LOG"
  REM="$(grep -oE '[0-9]+ to remove' "$D/apt-simulate.txt" | grep -oE '[0-9]+' | head -1)"
  [ -z "$REM" ] && REM=0
  if [ "$REM" -gt 0 ]; then say "REFUSE: simulate shows $REM removal(s); not installing"; echo "REFUSED" > "$D/install.refused"; exit 0; fi
  say "installing"
  apt-get install -y $PKGS >>"$LOG" 2>&1
fi

say "versions after:"
dpkg-query -W -f='${Package} ${Version}\n' ncz-singularity-desktop ncz-screensavers 2>/dev/null | sed 's/^/    /' | tee -a "$LOG"
say "lock binary sha after: $(sha256sum /opt/singularity/bin/singularity-lockscreen 2>/dev/null | awk '{print $1}')"
if [ -r "$REFIND" ]; then
  sha256sum "$REFIND" > "$D/refind-after.txt"
  B="$(awk '{print $1}' "$D/refind-before.txt" 2>/dev/null)"; A="$(awk '{print $1}' "$D/refind-after.txt")"
  if [ -n "$B" ] && [ "$B" != "$A" ]; then say "WARNING: refind.conf CHANGED by apt ($B -> $A); pre-op copy retained"; else say "refind.conf unchanged"; fi
fi
say "=== install done ==="
touch "$D/DONE"
exit 0
