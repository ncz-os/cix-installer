#!/bin/bash
# 58-screensaver-shader.sh — ship the current black-hole shader and the probe
# tooling in the image, so a fresh install renders what we validated instead of
# whatever the ncz-screensavers package shipped.
#
# WHY A SHADER OVERRIDE AND NOT A PACKAGE REBUILD
# -----------------------------------------------
# Every change in this cycle is in the shader (vendor/blackhole/blackhole.frag):
# the aim clamp, the probe-motion epicycle, the one-way flyby that can no longer
# park the camera, the 5-25% shadow-radius band, per-launch disc/ring variance
# and the tidal-disruption debris. The installed 0.8.18 BINARY is unchanged and
# already loads the shader from disk, so installing the file is the whole fix.
#
# WHAT IT INSTALLS
#   /usr/share/ncz-screensavers/shaders/blackhole.frag   (overrides the package)
#   /usr/local/bin/ncz-bh-card, ncz-bh-flightplan-rotate
#   /usr/local/share/ncz/flight-plans.json               (ten real encounters)
#   /usr/share/fonts/truetype/vt323/VT323-Regular.ttf    (SIL OFL, card typeface)
#   /etc/skel/.config/systemd/user/… + .wants symlinks   (card + plan rotation
#                                                         on for new users)
#
# BEST EFFORT: a missing asset must not fail the install; it warns.
set +e

META=/usr/local/lib/cix-installer
SRC=""
for c in "$META/assets/screensaver" /cdrom/ncz-payload/assets/screensaver \
         /run/ncz-payload/assets/screensaver; do
    [ -d "$c" ] && { SRC="$c"; break; }
done
if [ -z "$SRC" ]; then
    echo "[58] screensaver assets not staged — keeping the package's shader"
    exit 0
fi

SHADER=/usr/share/ncz-screensavers/shaders/blackhole.frag
if [ -s "$SRC/blackhole.frag" ]; then
    install -d -m 0755 "$(dirname "$SHADER")"
    if [ -f "$SHADER" ]; then cp -f "$SHADER" "$SHADER.package" 2>/dev/null; fi
    install -m 0644 "$SRC/blackhole.frag" "$SHADER"
    echo "[58] blackhole shader installed ($(sha256sum "$SHADER" | cut -c1-12))"
fi

install -d -m 0755 /usr/local/bin /usr/local/share/ncz
for f in ncz-bh-card ncz-bh-flightplan-rotate; do
    [ -s "$SRC/$f" ] && install -m 0755 "$SRC/$f" "/usr/local/bin/$f"
done
[ -s "$SRC/flight-plans.json" ] && install -m 0644 "$SRC/flight-plans.json" /usr/local/share/ncz/flight-plans.json
if [ -s "$SRC/VT323-Regular.ttf" ]; then
    install -d -m 0755 /usr/share/fonts/truetype/vt323
    install -m 0644 "$SRC/VT323-Regular.ttf" /usr/share/fonts/truetype/vt323/
    [ -s "$SRC/VT323-OFL.txt" ] && install -m 0644 "$SRC/VT323-OFL.txt" /usr/share/fonts/truetype/vt323/OFL.txt
fi

# New users get the card and the flight-plan rotation enabled. The .wants
# symlinks are what `systemctl --user enable` would have created.
for sk in /etc/skel /root; do
    U="$sk/.config/systemd/user"
    install -d -m 0755 "$U/default.target.wants" "$U/timers.target.wants"
    cat > "$U/ncz-bh-card.service" <<'SVC'
[Unit]
Description=Black-hole probe-telemetry intro card
[Service]
Type=simple
ExecStart=/usr/local/bin/ncz-bh-card --watch --seconds 6
Restart=on-failure
RestartSec=5
[Install]
WantedBy=default.target
SVC
    cat > "$U/ncz-bh-flightplan.service" <<'SVC2'
[Unit]
Description=Advance the black-hole saver to the next real probe encounter
[Service]
Type=oneshot
ExecStart=/usr/local/bin/ncz-bh-flightplan-rotate --next --duration 300
SVC2
    cat > "$U/ncz-bh-flightplan.timer" <<'TMR'
[Unit]
Description=Rotate probe flight plans with the five-minute re-roll
[Timer]
OnActiveSec=310s
OnUnitActiveSec=300s
[Install]
WantedBy=timers.target
TMR
    ln -sf ../ncz-bh-card.service "$U/default.target.wants/ncz-bh-card.service"
    ln -sf ../ncz-bh-flightplan.timer "$U/timers.target.wants/ncz-bh-flightplan.timer"
done
echo "[58] probe tooling installed (card, flight plans, VT323)"
exit 0
