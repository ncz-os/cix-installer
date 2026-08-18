#!/bin/bash
# 45-wallpaper-rotator.sh - install 7 NCZ wallpapers + auto-rotate
# every 10 minutes. r55: instant apply on login (was 30s) + xrandr-driven monitor
# discovery so wallpaper sticks across xfconf monitor-name shifts.
set -euo pipefail

echo "[45] installing 7 NCZ wallpapers + 10-minute autoswitcher"

VARIANT=desktop
if [ -f /usr/local/lib/cix-installer/BUILD_VARIANT ]; then
    VARIANT=$(tr -d ' \t\r\n' < /usr/local/lib/cix-installer/BUILD_VARIANT)
fi
case "$VARIANT" in
    server|headless)
        echo "[45] BUILD_VARIANT=server - Server headless SKU; skipping wallpaper rotator"
        exit 0
        ;;
esac

ASSETS=/usr/local/lib/cix-installer/assets/branding/wallpaper
DEST=/usr/share/backgrounds/ncz
mkdir -p "$DEST"
for f in "$ASSETS"/ncz-wallpaper-*-2k.jpg; do
    [ -f "$f" ] && install -m 0644 "$f" "$DEST/"
done
# Default = the Maximilian backdrop (26.7 release wallpaper).
ln -sfn ncz-wallpaper-07-maximilian-blackhole-2k.jpg "$DEST/default.jpg"

# ---------------------------------------------------------------------------
# COLLECTIONS: art paks, time-of-day sets and providers.
#
# A collection is a .collection file (INI-shaped, like a .desktop entry) under
# /usr/share/ncz-wallpapers/collections/. A pak such as
# ncz-wallpapers-brandon-perlow ships its images under
# /usr/share/backgrounds/ncz/<id>/ plus one .collection file, and appears in the
# rotator with no edit to any script -- which is the whole point: art is data,
# not code.
#
# Types:
#   static     one directory, pick at random
#   timeofday  named sub-directories keyed by a start time (dawn/day/dusk/night)
#   provider   fetched, currently `bing` (image of the day)
# ---------------------------------------------------------------------------
install -d /usr/share/ncz-wallpapers/collections
install -d /var/cache/ncz-wallpapers/bing
# The rotator runs as the logged-in user, so the Bing cache must be writable by
# them; the fetch is otherwise a guaranteed EPERM and the collection renders
# nothing.
chmod 1777 /var/cache/ncz-wallpapers/bing

install -m 0755 /dev/stdin /usr/local/bin/ncz-wallpaper-collections <<'COLLECTIONS_EOF'
#!/bin/bash
# ncz-wallpaper-collections — enumerate and resolve wallpaper collections.
#
# A collection is a .collection file (INI-style, the same shape as a .desktop
# entry so it is familiar and parseable with the tools already here). They live
# in, in ascending priority:
#
#     /usr/share/ncz-wallpapers/collections/     shipped + packaged art paks
#     /etc/ncz-wallpapers/collections/           site overrides
#     ~/.local/share/ncz-wallpapers/collections/ per-user
#
# A pak (e.g. ncz-wallpapers-brandon-perlow) drops its images under
# /usr/share/backgrounds/ncz/<id>/ and one .collection file. Nothing else is
# needed to make it appear: no script edits, no rebuild of the rotator.
#
#   [Collection]
#   Id=brandon-perlow
#   Name=Brandon Perlow
#   Artist=Brandon Perlow
#   Type=static | timeofday | provider
#   Dir=/usr/share/backgrounds/ncz/brandon-perlow    (static)
#   Provider=bing                                    (provider)
#
#   [TimeOfDay]                                      (timeofday only)
#   05:00=dawn
#   08:00=day
#   18:00=dusk
#   21:00=night
#
# Usage:
#   ncz-wallpaper-collections list          -> "id<TAB>name<TAB>type<TAB>count"
#   ncz-wallpaper-collections pick <id>     -> absolute path of one image
#   ncz-wallpaper-collections path <id>     -> the .collection file
set -u

SYS_DIRS="/usr/share/ncz-wallpapers/collections /etc/ncz-wallpapers/collections"
USER_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/ncz-wallpapers/collections"

_ini_get() {  # <file> <section> <key>
    awk -v sect="$2" -v key="$3" '
        /^[[:space:]]*[#;]/ { next }
        /^[[:space:]]*\[/ {
            gsub(/^[[:space:]]*\[|\][[:space:]]*$/, "")
            cur = $0; next
        }
        cur == sect {
            eq = index($0, "=")
            if (eq == 0) next
            k = substr($0, 1, eq-1); v = substr($0, eq+1)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", k)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
            if (k == key) { print v; exit }
        }
    ' "$1" 2>/dev/null
}

_files_in() {  # <dir> -> image paths, one per line
    [ -d "$1" ] || return 0
    find "$1" -maxdepth 1 -type f \
        \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' \) 2>/dev/null | sort
}

# Resolve a collection id to its .collection file (user dir wins).
collection_path() {
    local id="$1" d
    for d in "$USER_DIR" $SYS_DIRS; do
        [ -f "$d/$id.collection" ] && { printf '%s\n' "$d/$id.collection"; return 0; }
    done
    return 1
}

# The directory a timeofday collection should draw from right now.
_timeofday_dir() {  # <file> <base>
    local f="$1" base="$2" now slot best_t="" best_s=""
    now=$(date +%H:%M)
    # Pick the latest window whose start time is <= now; if none (before the
    # first window today) fall back to the LAST window of the day, which is the
    # one still in effect from last night. Without that wrap-around, every hour
    # before dawn has no slot and the collection renders nothing.
    while IFS='=' read -r t s; do
        t=$(printf '%s' "$t" | tr -d ' '); s=$(printf '%s' "$s" | tr -d ' ')
        case "$t" in ''|'#'*|'['*) continue ;; esac
        [ -z "$s" ] && continue
        if [ -z "$best_s" ] || [ "$t" \> "$best_s" ]; then :; fi
        if [ "$t" \< "$now" ] || [ "$t" = "$now" ]; then
            if [ -z "$best_t" ] || [ "$t" \> "$best_t" ]; then best_t="$t"; best_s="$s"; fi
        fi
        last_s="$s"
    done < <(sed -n '/^[[:space:]]*\[TimeOfDay\]/,/^[[:space:]]*\[/p' "$f" | grep -E '^[0-9]{2}:[0-9]{2}[[:space:]]*=')
    [ -z "$best_s" ] && best_s="${last_s:-}"
    [ -z "$best_s" ] && return 1
    printf '%s/%s\n' "$base" "$best_s"
}

cmd_list() {
    local d f id name type dir cnt
    { for d in $SYS_DIRS "$USER_DIR"; do
        [ -d "$d" ] || continue
        for f in "$d"/*.collection; do
            [ -f "$f" ] || continue
            id=$(_ini_get "$f" Collection Id); [ -z "$id" ] && id=$(basename "$f" .collection)
            printf '%s\n' "$id"
        done
      done; } | sort -u | while read -r id; do
        f=$(collection_path "$id") || continue
        name=$(_ini_get "$f" Collection Name); [ -z "$name" ] && name="$id"
        type=$(_ini_get "$f" Collection Type); [ -z "$type" ] && type=static
        dir=$(_ini_get "$f" Collection Dir)
        case "$type" in
            provider) cnt=$(_files_in "${dir:-/var/cache/ncz-wallpapers/$(_ini_get "$f" Collection Provider)}" | wc -l) ;;
            timeofday) cnt=$(find "${dir:-/dev/null}" -type f \( -iname '*.jpg' -o -iname '*.png' -o -iname '*.jpeg' -o -iname '*.webp' \) 2>/dev/null | wc -l) ;;
            *) cnt=$(_files_in "$dir" | wc -l) ;;
        esac
        printf '%s\t%s\t%s\t%s\n' "$id" "$name" "$type" "$cnt"
    done
}

cmd_pick() {
    local id="$1" f type dir provider sub
    f=$(collection_path "$id") || { echo "no such collection: $id" >&2; return 1; }
    type=$(_ini_get "$f" Collection Type); [ -z "$type" ] && type=static
    dir=$(_ini_get "$f" Collection Dir)

    case "$type" in
        provider)
            provider=$(_ini_get "$f" Collection Provider)
            case "$provider" in
                bing)
                    # Refresh is best-effort: a failed or offline fetch must still
                    # yield yesterday's cached image rather than no wallpaper.
                    [ -x /usr/local/bin/ncz-wallpaper-bing ] && \
                        /usr/local/bin/ncz-wallpaper-bing fetch >/dev/null 2>&1
                    dir="${dir:-/var/cache/ncz-wallpapers/bing}"
                    ;;
                *) echo "unknown provider: $provider" >&2; return 1 ;;
            esac
            _files_in "$dir" | tail -n1        # newest by sortable YYYYMMDD name
            ;;
        timeofday)
            sub=$(_timeofday_dir "$f" "$dir") || return 1
            _files_in "$sub" | shuf -n1
            ;;
        *)
            _files_in "$dir" | shuf -n1
            ;;
    esac
}

case "${1:-list}" in
    list) cmd_list ;;
    pick) shift; cmd_pick "${1:?usage: pick <id>}" ;;
    path) shift; collection_path "${1:?usage: path <id>}" ;;
    *) echo "usage: ncz-wallpaper-collections {list|pick <id>|path <id>}" >&2; exit 2 ;;
esac
COLLECTIONS_EOF

install -m 0755 /dev/stdin /usr/local/bin/ncz-wallpaper-bing <<'BING_EOF'
#!/bin/bash
# ncz-wallpaper-bing — fetch Bing's image of the day into a local cache.
#
# Endpoint (verified 2026-08-18):
#   https://www.bing.com/HPImageArchive.aspx?format=js&idx=0&n=1&mkt=<market>
# The JSON gives `urlbase` like "/th?id=OHR.Palmanova_EN-US0340289339". Appending
# "_UHD.jpg" yields the highest resolution; the `url` field is only 1920x1080,
# which is short of the 3840x2160 panel on an O6.
#
# Images are cached as <cache>/<startdate>.jpg so they sort chronologically and
# the newest is simply the last one. Attribution is written alongside as .txt --
# these are © their photographers and the copyright string must not be dropped.
#
#   fetch    download today's image if not already cached, prune old ones
#   latest   print the path of the newest cached image
#   info     print attribution for the newest cached image
set -u

CACHE="${NCZ_BING_CACHE:-/var/cache/ncz-wallpapers/bing}"
MARKET="${NCZ_BING_MARKET:-en-US}"
KEEP="${NCZ_BING_KEEP:-14}"
API="https://www.bing.com/HPImageArchive.aspx?format=js&idx=0&n=1&mkt=${MARKET}"

log() { [ -n "${NCZ_BING_QUIET:-}" ] || printf '[bing] %s\n' "$*"; }

cmd_fetch() {
    mkdir -p "$CACHE" 2>/dev/null || { echo "cannot create $CACHE" >&2; return 1; }
    [ -w "$CACHE" ] || { echo "cache not writable: $CACHE" >&2; return 1; }

    local json
    json=$(curl -sf --max-time 30 "$API" 2>/dev/null) || { log "fetch failed (offline?)"; return 1; }

    # Parse with python3 rather than grep/sed: the copyright field contains
    # commas, parentheses and non-ASCII, and a regex over it silently truncates.
    local parsed date urlbase copyright title
    parsed=$(printf '%s' "$json" | python3 -c '
import sys, json
try:
    im = json.load(sys.stdin)["images"][0]
except Exception:
    sys.exit(1)
print(im.get("startdate",""))
print(im.get("urlbase",""))
print(im.get("copyright","").replace("\n"," "))
print(im.get("title","").replace("\n"," "))
' 2>/dev/null) || { log "unexpected API response"; return 1; }

    date=$(printf '%s\n' "$parsed" | sed -n 1p)
    urlbase=$(printf '%s\n' "$parsed" | sed -n 2p)
    copyright=$(printf '%s\n' "$parsed" | sed -n 3p)
    title=$(printf '%s\n' "$parsed" | sed -n 4p)
    [ -n "$date" ] && [ -n "$urlbase" ] || { log "incomplete API response"; return 1; }

    local out="$CACHE/$date.jpg"
    if [ -s "$out" ]; then log "already have $date"; else
        local tmp="$out.part"
        # UHD first; fall back to 1920x1080 if the UHD asset is absent.
        if ! curl -sf --max-time 90 -o "$tmp" "https://www.bing.com${urlbase}_UHD.jpg" 2>/dev/null \
           || [ ! -s "$tmp" ]; then
            rm -f "$tmp"
            curl -sf --max-time 90 -o "$tmp" "https://www.bing.com${urlbase}_1920x1080.jpg" 2>/dev/null \
                || { rm -f "$tmp"; log "image download failed"; return 1; }
        fi
        # Only publish once fully written, so a half-downloaded file is never
        # picked up as the wallpaper.
        mv -f "$tmp" "$out"
        printf '%s\n%s\n' "$title" "$copyright" > "$CACHE/$date.txt"
        log "cached $date ($(du -h "$out" | cut -f1))"
    fi

    # Prune, keeping the most recent $KEEP.
    local n
    n=$(ls -1 "$CACHE"/*.jpg 2>/dev/null | wc -l)
    if [ "$n" -gt "$KEEP" ]; then
        ls -1 "$CACHE"/*.jpg | head -n "$((n - KEEP))" | while read -r old; do
            rm -f "$old" "${old%.jpg}.txt"
        done
        log "pruned $((n - KEEP)) old image(s)"
    fi
}

cmd_latest() { ls -1 "$CACHE"/*.jpg 2>/dev/null | tail -n1; }

cmd_info() {
    local l; l=$(cmd_latest) || return 1
    [ -n "$l" ] || return 1
    cat "${l%.jpg}.txt" 2>/dev/null
}

case "${1:-fetch}" in
    fetch)  cmd_fetch ;;
    latest) cmd_latest ;;
    info)   cmd_info ;;
    *) echo "usage: ncz-wallpaper-bing {fetch|latest|info}" >&2; exit 2 ;;
esac
BING_EOF

# The shipped NCZ art, expressed as a collection so the built-in set and any
# add-on pak go through exactly one code path.
cat > /usr/share/ncz-wallpapers/collections/ncz.collection <<'EOF'
[Collection]
Id=ncz
Name=NCZ-OS
Comment=The wallpapers shipped with NCZ-OS
Artist=NCZ
Type=static
Dir=/usr/share/backgrounds/ncz
EOF

cat > /usr/share/ncz-wallpapers/collections/bing.collection <<'EOF'
[Collection]
Id=bing
Name=Bing Image of the Day
Comment=Bing's daily photograph, refreshed each day
Type=provider
Provider=bing
Dir=/var/cache/ncz-wallpapers/bing
EOF

# Daily refresh. A timer, not a loop inside the rotator: the image changes once
# a day, and tying the fetch to the 10-minute rotation would hit Bing 144x/day
# per user for no benefit.
cat > /usr/lib/systemd/user/ncz-wallpaper-bing.service <<'EOF'
[Unit]
Description=Fetch Bing image of the day
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/ncz-wallpaper-bing fetch
EOF
cat > /usr/lib/systemd/user/ncz-wallpaper-bing.timer <<'EOF'
[Unit]
Description=Fetch Bing image of the day (daily)

[Timer]
OnCalendar=daily
# The image rolls over at 00:00 UTC and a fleet of machines asking at once is
# rude; spread the requests out.
RandomizedDelaySec=30m
Persistent=true

[Install]
WantedBy=timers.target
EOF
chmod 0644 /usr/lib/systemd/user/ncz-wallpaper-bing.service /usr/lib/systemd/user/ncz-wallpaper-bing.timer
systemctl --global enable ncz-wallpaper-bing.timer >/dev/null 2>&1 \
    && echo "[45]   enabled ncz-wallpaper-bing.timer (daily)" \
    || echo "[45]   WARN: could not enable ncz-wallpaper-bing.timer"

# Rotator: pick + apply. 26.7 default DE = Singularity (Wayland, GTK4): set the
# backdrop via `dev.sinty.desktop background-picture-uri` (gsettings) and swaybg.
cat > /usr/local/bin/ncz-wallpaper-rotate <<'ROT'
#!/bin/sh
WP_DIR=/usr/share/backgrounds/ncz

# WHICH COLLECTION. The user's choice lives in a plain file so it can be set
# without a settings daemon and read identically from a timer, a shell or the
# desktop. Unset = "ncz", the shipped art, which is the pre-collections
# behaviour.
CONF="${XDG_CONFIG_HOME:-$HOME/.config}/ncz-wallpaper/collection"
COLLECTION=$(tr -d " \t\r\n" < "$CONF" 2>/dev/null)
[ -z "$COLLECTION" ] && COLLECTION=ncz

PIC=""
if [ -x /usr/local/bin/ncz-wallpaper-collections ]; then
    PIC=$(/usr/local/bin/ncz-wallpaper-collections pick "$COLLECTION" 2>/dev/null)
fi
# Fall back to the flat directory if the collection yielded nothing -- an empty
# pak, a provider that could not reach the network, or a mistyped id must not
# leave the desktop with no wallpaper at all.
[ -n "$PIC" ] && [ -f "$PIC" ] || PIC=$(ls $WP_DIR/ncz-wallpaper-*.jpg 2>/dev/null | shuf -n1)
[ -z "$PIC" ] && exit 0
# default.jpg is a convenience pointer, not the mechanism -- the wallpaper is
# applied through gsettings/swaybg below. The rotator runs as the logged-in
# user and $WP_DIR is root-owned 0755, so this ln FAILS with EPERM every time.
# It was already suppressed with "|| true", which turned a guaranteed failure
# into silence. Only attempt it when the directory is actually writable.
if [ -w "$WP_DIR" ]; then
    ln -sfn "$(basename "$PIC")" "$WP_DIR/default.jpg" 2>/dev/null || true
fi

DE=""
case "${XDG_CURRENT_DESKTOP:-}${DESKTOP_SESSION:-}" in
    *Singularity*|*singularity*) DE=singularity ;;
    *GNOME*|*gnome*)      DE=gnome ;;
esac
if [ -z "$DE" ]; then
    if   pgrep -u "$USER" -x singularity-desktop >/dev/null 2>&1; then DE=singularity
    elif pgrep -u "$USER" -x gnome-shell >/dev/null 2>&1; then DE=gnome
    fi
fi

case "$DE" in
    singularity)
        URI="file://$PIC"
        # Singularity reads dev.sinty.desktop; its schema lives in the isolated
        # /opt/singularity prefix, so point gsettings at that schema dir.
        SSD=/opt/singularity/share/glib-2.0/schemas
        if command -v gsettings >/dev/null 2>&1 && [ -d "$SSD" ]; then
            GSETTINGS_SCHEMA_DIR="$SSD" gsettings set dev.sinty.desktop background-picture-uri "$URI" 2>/dev/null || true
        fi
        # Belt: repaint the live wallpaper layer via swaybg (single instance).
        if command -v swaybg >/dev/null 2>&1 && [ -n "${WAYLAND_DISPLAY:-}" ]; then
            pkill -x swaybg 2>/dev/null || true
            swaybg -m fill -i "$PIC" >/dev/null 2>&1 &
        fi
        ;;
    gnome)
        URI="file://$PIC"
        gsettings set org.gnome.desktop.background picture-uri "$URI" 2>/dev/null || true
        gsettings set org.gnome.desktop.background picture-uri-dark "$URI" 2>/dev/null || true
        gsettings set org.gnome.desktop.background picture-options zoom 2>/dev/null || true
        ;;
esac
echo "$PIC" > ${XDG_RUNTIME_DIR:-/tmp}/ncz-wallpaper-state 2>/dev/null
ROT
chmod 0755 /usr/local/bin/ncz-wallpaper-rotate

# Daemon: 2s warm-up (was 30s), then rotate every 10 min
cat > /usr/local/bin/ncz-wallpaper-daemon <<'DAEMON'
#!/bin/sh
# r110: single-instance guard so session restarts don't stack daemons
LOCK="${XDG_RUNTIME_DIR:-/tmp}/ncz-wallpaper-daemon.lock"
if [ -e "$LOCK" ] && kill -0 "$(cat "$LOCK" 2>/dev/null)" 2>/dev/null; then exit 0; fi
echo $$ > "$LOCK"
trap 'rm -f "$LOCK"' EXIT
sleep 2
/usr/local/bin/ncz-wallpaper-rotate
while true; do
    sleep 600
    /usr/local/bin/ncz-wallpaper-rotate
done
DAEMON
chmod 0755 /usr/local/bin/ncz-wallpaper-daemon

# HOW THINGS ACTUALLY START IN THIS SESSION.
#
# MEASURED on an O6N running the shipped image, 2026-08-18: NOTHING processes
# /etc/xdg/autostart here. There is no dex, no xdg-autostart-generator, no
# gnome-session or lxsession, and no xdg-desktop-autostart.target among the
# user units. An autostart .desktop is therefore inert -- which is why the
# wallpaper rotator was installed, correct, and had never once run.
#
# The session is systemd --user driven. The active user targets are basic,
# default, paths, sockets and timers. graphical-session.target is NOT active,
# and singularity-session.target -- which the session script tries to start --
# does not exist as a unit at all. So default.target is the only reliable
# anchor, and `systemctl --global enable` is what applies a user unit to every
# account without needing a per-user enable at first login.
#
# The .desktop file is still written: it costs nothing and is the correct
# mechanism on desktops that DO honour it. It is a fallback here, not the
# mechanism.

install -d /usr/lib/systemd/user
cat > /usr/lib/systemd/user/ncz-wallpaper-rotator.service <<'UNIT'
[Unit]
Description=NCZ wallpaper rotator
PartOf=graphical-session.target
After=graphical-session.target

[Service]
Type=simple
ExecStart=/usr/local/bin/ncz-wallpaper-daemon
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target
UNIT
chmod 0644 /usr/lib/systemd/user/ncz-wallpaper-rotator.service

if systemctl --global enable ncz-wallpaper-rotator.service >/dev/null 2>&1; then
    echo "[45]   enabled ncz-wallpaper-rotator.service for all users (systemd --global)"
else
    echo "[45]   WARN: could not globally enable ncz-wallpaper-rotator.service"
fi

# Fallback for desktops that honour XDG autostart. Inert on Singularity.
mkdir -p /etc/xdg/autostart
cat > /etc/xdg/autostart/ncz-wallpaper-rotator.desktop <<'AUTO'
[Desktop Entry]
Type=Application
Name=NCZ Wallpaper Rotator
Exec=/usr/local/bin/ncz-wallpaper-daemon
NoDisplay=true
StartupNotify=false
Terminal=false
AUTO

echo "[45] Singularity wallpaper rotator + autostart written (default = Maximilian)"

# Greeter background = the static NCZ Maximilian wallpaper installed by 55-greeter
# at the native greeter's fallback path /usr/share/backgrounds/singularity/
# default.png. The greeter is greetd + native singularity-greeter (Wayland/Mali,
# Cairo/loginui), which reads that fallback file — no lightdm conf.d, no regreet.
