#!/bin/bash
# 57-qotd.sh — Quote Of The Day. Surfaces a daily rotating quote (cosmic +
# The Black Hole (1979) lines) on the screen: the terminal MOTD (console/SSH)
# and a desktop login notification. Deterministic per calendar day so it is a
# true "quote of the day", not a random-every-shell flicker.
#
# Source list: assets/branding/cosmic-quotes (195 curated lines). Installed to
# /usr/share/ncz/cosmic-quotes; picked by /usr/local/bin/ncz-qotd.
# RUNS INSIDE CHROOT via run-all.sh (best-effort; never fatal).
set +e

echo "[57] QOTD: daily quote on MOTD + desktop login"

INSTALLER_META=/usr/local/lib/cix-installer
SRC=""
for c in "$INSTALLER_META/assets/branding/cosmic-quotes" \
         "$INSTALLER_META/assets/cosmic-quotes"; do
    [ -f "$c" ] && { SRC="$c"; break; }
done
if [ -z "$SRC" ]; then
    echo "[57] cosmic-quotes asset not found — skipping QOTD"
    exit 0
fi

install -d -m0755 /usr/share/ncz
install -m0644 "$SRC" /usr/share/ncz/cosmic-quotes
echo "[57] installed $(grep -cvE '^\s*(#|$)' /usr/share/ncz/cosmic-quotes) quotes -> /usr/share/ncz/cosmic-quotes"

# --- picker: deterministic per-day quote ------------------------------------
cat > /usr/local/bin/ncz-qotd <<'QOTD'
#!/bin/sh
# ncz-qotd — print the Quote Of The Day (stable per calendar day).
# Non-blank, non-comment lines from /usr/share/ncz/cosmic-quotes; index =
# days-since-epoch mod count, so it advances once per day and is identical
# across every shell/screen that day.
Q=/usr/share/ncz/cosmic-quotes
[ -r "$Q" ] || exit 0
N=$(grep -cvE '^[[:space:]]*(#|$)' "$Q")
[ "$N" -gt 0 ] 2>/dev/null || exit 0
DAY=$(( $(date -u +%s) / 86400 ))
IDX=$(( DAY % N + 1 ))
grep -vE '^[[:space:]]*(#|$)' "$Q" | sed -n "${IDX}p"
QOTD
chmod 0755 /usr/local/bin/ncz-qotd

# --- MOTD (terminal login screen) -------------------------------------------
# update-motd.d runs in sort order; 00-ncz-banner (50-brand.sh) prints the box,
# then this prints the QOTD beneath it. Dynamic = fresh quote each new day.
install -d -m0755 /etc/update-motd.d
cat > /etc/update-motd.d/50-ncz-qotd <<'MOTD'
#!/bin/sh
Q=$(/usr/local/bin/ncz-qotd 2>/dev/null)
[ -n "$Q" ] || exit 0
printf '\n  \033[2;3m%s\033[0m\n\n' "$Q"
MOTD
chmod 0755 /etc/update-motd.d/50-ncz-qotd

# --- desktop login notification (GUI screen) --------------------------------
# XDG autostart: on desktop login, pop the QOTD via notify-send (persists ~20s,
# NCZ avatar icon). Skips cleanly on headless/server (no notify-send / no DBus).
cat > /usr/local/bin/ncz-qotd-notify <<'NOTIFY'
#!/bin/sh
command -v notify-send >/dev/null 2>&1 || exit 0
Q=$(/usr/local/bin/ncz-qotd 2>/dev/null)
[ -n "$Q" ] || exit 0
ICON=/usr/share/pixmaps/ncz-avatar-magenta.png
[ -f "$ICON" ] || ICON=dialog-information
# wait for the notification daemon to be up after session start
sleep 8
notify-send -a "NCZ" -u low -t 20000 -i "$ICON" "Quote of the Day" "$Q"
NOTIFY
chmod 0755 /usr/local/bin/ncz-qotd-notify

install -d -m0755 /etc/xdg/autostart
cat > /etc/xdg/autostart/ncz-qotd.desktop <<'DESK'
[Desktop Entry]
Type=Application
Name=NCZ Quote of the Day
Comment=Show the daily quote on login
Exec=/usr/local/bin/ncz-qotd-notify
Icon=/usr/share/pixmaps/ncz-avatar-magenta.png
Terminal=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
OnlyShowIn=XFCE;
DESK
chmod 0644 /etc/xdg/autostart/ncz-qotd.desktop

echo "[57] QOTD wired: /usr/local/bin/ncz-qotd + MOTD + desktop autostart"
echo "[57] today: $(/usr/local/bin/ncz-qotd 2>/dev/null)"
exit 0
