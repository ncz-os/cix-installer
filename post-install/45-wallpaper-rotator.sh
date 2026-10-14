#!/bin/bash
# 45-wallpaper-rotator.sh - install 7 NCZ wallpapers + auto-rotate
# every 10 minutes. r55: instant apply on login (was 30s) + xrandr-driven monitor
# discovery so wallpaper sticks across xfconf monitor-name shifts.
set -euo pipefail
_pm="$(dirname "$0")/lib/progress-msg.sh"; [ -r "$_pm" ] || _pm=/usr/local/lib/cix-installer/post-install/lib/progress-msg.sh
[ -r "$_pm" ] && . "$_pm"
command -v ncz_msg >/dev/null 2>&1 && ncz_msg "Wallpapers: installing the wallpaper packs and the 10-minute autoswitcher (about a minute)"

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


# ---------------------------------------------------------------------------
# COLLECTIONS: art paks, time-of-day sets and providers.
#
# A collection is a .collection file (INI-shaped, like a .desktop entry) under
# /opt/singularity/share/singularity/wallpaper-collections/ -- the same
# directory WallpaperCollections.default_search_roots() (libsingularity)
# scans for the Settings UI's own Wallpaper Source picker, so a collection
# dropped here is visible to both that picker and this rotator instead of
# two divergent copies. A pak such as ncz-wallpapers-brandon-perlow ships
# its images under /usr/share/backgrounds/ncz/<id>/ plus one .collection
# file, and appears in the rotator with no edit to any script -- which is
# the whole point: art is data, not code.
#
# Types:
#   static     one directory, pick at random
#   timeofday  named sub-directories keyed by a start time (dawn/day/dusk/night)
#   provider   fetched, currently `bing` (image of the day)
# ---------------------------------------------------------------------------
install -d /opt/singularity/share/singularity/wallpaper-collections
install -d /usr/share/ncz-wallpapers/collections
install -d /var/cache/ncz-wallpapers/bing
# The rotator runs as the logged-in user, so the Bing cache must be writable by
# them; the fetch is otherwise a guaranteed EPERM and the collection renders
# nothing.
chmod 1777 /var/cache/ncz-wallpapers/bing

OCS_ASSETS=/usr/local/lib/cix-installer/assets/wallpaper
# 2026-09-16 real fix: renamed from ncz-wallpaper-pack-{install,inventory} to
# match singularity-shell's ArtistPackManager.vala, which expects
# /usr/local/bin/singularity-artist-pack-{install,inventory} -- the generic,
# distro-neutral naming its own contribution guidelines require (no
# NCZ-specific leakage into upstream code). This side had drifted out of
# sync with that rename: the helpers, and the polkit policy's internal
# exec.path, were still staged under the old ncz-wallpaper-pack-* names,
# so ArtistPackManager.is_available() always returned false and Artist
# Pack install silently could never work regardless of which desktop
# build was running -- confirmed live on O6N (2026-09-16): the apt
# packages themselves installed fine by hand, only the UI's own trigger
# path was broken.
for helper in singularity-artist-pack-inventory singularity-artist-pack-install; do
    if [ -x "$OCS_ASSETS/$helper" ]; then
        install -m 0755 "$OCS_ASSETS/$helper" "/usr/local/bin/$helper"
        echo "[45]   installed Artist Pack backend: $helper"
    else
        echo "[45]   WARN: Artist Pack backend asset missing: $helper" >&2
    fi
done
ARTIST_PACK_POLICY="$OCS_ASSETS/dev.sinty.desktop.artist-pack-install.policy"
if [ -f "$ARTIST_PACK_POLICY" ]; then
    install -d /usr/share/polkit-1/actions
    install -m 0644 "$ARTIST_PACK_POLICY" \
        /usr/share/polkit-1/actions/dev.sinty.desktop.artist-pack-install.policy
    echo "[45]   installed Artist Pack polkit policy"
else
    echo "[45]   WARN: Artist Pack polkit policy asset missing" >&2
fi
if [ -x "$OCS_ASSETS/ncz-wallpaper-ocs" ]; then
    install -m 0755 "$OCS_ASSETS/ncz-wallpaper-ocs" /usr/local/bin/ncz-wallpaper-ocs
    # The plugin looks its helper up as singularity-wallpaper-ocs in PATH.
    ln -sf ncz-wallpaper-ocs /usr/local/bin/singularity-wallpaper-ocs
    echo "[45]   installed OCS wallpaper backend"
else
    echo "[45]   WARN: OCS wallpaper backend asset missing" >&2
fi
# Aspect-ratio variants (docs/WALLPAPER-SAFE-AREA.md): ncz-wallpaper-rotate asks
# this helper which file of a wallpaper fits the primary output -- the 16:9
# original or a pre-composed 16:10 variant a pack declares under [Variants].
# Optional: without it the rotator applies the original exactly as before.
if [ -x "$OCS_ASSETS/ncz-wallpaper-fit" ]; then
    install -m 0755 "$OCS_ASSETS/ncz-wallpaper-fit" /usr/local/bin/ncz-wallpaper-fit
    echo "[45]   installed aspect-variant chooser: ncz-wallpaper-fit"
else
    echo "[45]   WARN: aspect-variant chooser asset missing: ncz-wallpaper-fit" >&2
fi
if [ -f "$OCS_ASSETS/ocs-category-index.json" ]; then
    install -m 0644 "$OCS_ASSETS/ocs-category-index.json" /usr/share/ncz-wallpapers/ocs-category-index.json
    echo "[45]   installed OCS wallpaper category index"
else
    echo "[45]   WARN: OCS wallpaper category index asset missing" >&2
fi

install -m 0755 /dev/stdin /usr/local/bin/ncz-wallpaper-collections <<'COLLECTIONS_EOF'
#!/bin/bash
# ncz-wallpaper-collections — enumerate and resolve wallpaper collections.
#
# A collection is a .collection file (INI-style, the same shape as a .desktop
# entry so it is familiar and parseable with the tools already here). They live
# in, in ascending priority:
#
#     /opt/singularity/share/singularity/wallpaper-collections/  shipped + packaged art paks
#     /usr/share/singularity/wallpaper-collections/               site overrides
#     ~/.local/share/singularity/wallpaper-collections/           per-user
#
# Same directory WallpaperCollections.default_search_roots() (libsingularity)
# scans for the Settings UI's own Wallpaper Source picker -- one canonical
# location, not two divergent copies. The old ncz-wallpapers/collections/
# paths are still read (lowest priority) for any not-yet-repackaged pack.
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

# Canonical location is Singularity's own collection search path
# (WallpaperCollections.default_search_roots() in libsingularity), so a
# collection dropped here is visible both to the Settings UI's Wallpaper
# Source picker and to this rotator -- one location, not two divergent
# copies. The old ncz-wallpapers/ paths stay as a read-only fallback for
# any not-yet-repackaged pack.
SYS_DIRS="/opt/singularity/share/singularity/wallpaper-collections /usr/share/singularity/wallpaper-collections /etc/singularity/wallpaper-collections /usr/share/ncz-wallpapers/collections /etc/ncz-wallpapers/collections"
USER_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/singularity/wallpaper-collections"
USER_DIR_LEGACY="${XDG_DATA_HOME:-$HOME/.local/share}/ncz-wallpapers/collections"

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
    # -L: consolidate() (45-wallpaper-rotator.sh) exposes deduplicated bing
    # images as symlinks, not real files -- plain `find -type f` reports
    # type "l" for a symlink regardless of what it points to and silently
    # matches nothing, which is exactly how this returned a false "0 images"
    # count against a real, populated consolidated/ directory (2026-09-12).
    find -L "$1" -maxdepth 1 -type f \
        \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' \) 2>/dev/null | sort
}

# Resolve a collection id to its .collection file (user dir wins).
collection_path() {
    local id="$1" d
    for d in "$USER_DIR" "$USER_DIR_LEGACY" $SYS_DIRS; do
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
    { for d in $SYS_DIRS "$USER_DIR" "$USER_DIR_LEGACY"; do
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
            provider)
                case "$(_ini_get "$f" Collection Provider)" in
                    bing) cnt=$(find -L "${dir:-/var/cache/ncz-wallpapers/bing}" -mindepth 2 -maxdepth 2 -type f -iname '*.jpg' 2>/dev/null | wc -l) ;;
                    *) cnt=$(_files_in "${dir:-/var/cache/ncz-wallpapers/$(_ini_get "$f" Collection Provider)}" | wc -l) ;;
                esac
                ;;
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
                    # Fetching belongs to ncz-wallpaper-bing.timer.  Doing a full
                    # 14-market refresh here made every 10-minute rotation depend
                    # on the network and allowed it to overlap the daily fetch's
                    # destructive consolidated-view rebuild.  `pick` already
                    # falls back from a missing/stale consolidated manifest to
                    # the real per-market archive, including older cached days.
                    if [ -x /usr/local/bin/ncz-wallpaper-bing ]; then
                        /usr/local/bin/ncz-wallpaper-bing pick
                        return $?
                    fi
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

# The Bing backend lives in assets/wallpaper/ncz-wallpaper-bing (staged with the
# other wallpaper backends); the Bing plugin and the timers below both run it.
if [ ! -x "$OCS_ASSETS/ncz-wallpaper-bing" ]; then
    echo "[45] ERROR: Bing wallpaper backend asset missing: $OCS_ASSETS/ncz-wallpaper-bing" >&2
    exit 1
fi
install -m 0755 "$OCS_ASSETS/ncz-wallpaper-bing" /usr/local/bin/ncz-wallpaper-bing
# The plugin looks its helper up as singularity-wallpaper-bing in PATH.
ln -sf ncz-wallpaper-bing /usr/local/bin/singularity-wallpaper-bing

cat > /opt/singularity/share/singularity/wallpaper-collections/bing.collection <<'EOF'
[Collection]
Id=bing
Name=Bing (Combined, All Markets)
Comment=Bing's daily photographs across all regional markets, de-duplicated
Type=provider
Provider=bing
Dir=/var/cache/ncz-wallpapers/bing/consolidated
EOF

# The Singularity Desktop project's own default wallpaper set ships inside
# the /opt/singularity payload (subprojects/singularity-wallpapers,
# installed to share/backgrounds/singularity by the desktop's own meson
# build) -- not a separate NCZ .deb, since it is already installed the
# moment ncz-singularity-desktop is. Just describe it as its own source,
# distinct from NCZ's own cosmic art, in the Wallpaper Source selector.
cat > /opt/singularity/share/singularity/wallpaper-collections/singularity-default.collection <<'EOF'
[Collection]
Id=singularity-default
Name=Singularity Default
Comment=The default wallpaper set that ships with Singularity Desktop
Artist=Singularity
Type=static
Dir=/opt/singularity/share/backgrounds/singularity
EOF

# Artist Packs, packaged as .debs by build/build-wallpaper-contrib-deb.sh and
# staged at build time into assets/wallpaper-debs/ (gitignored blobs, like
# assets/cix-debs -- rebuild with that script, do not commit the .deb
# itself). Each pack's own postinst is a no-op (dpkg-deb --build with no
# maintainer scripts): it only drops images + one .collection file.
WALLPAPER_DEBS=/usr/local/lib/cix-installer/assets/wallpaper-debs

# The NCZ pack is REQUIRED, not optional like a contributed pack: it is the
# baseline default background (rotator.sh's own WP_DIR fallback and
# ncz-wallpaper-rotate's COLLECTION default both assume /usr/share/
# backgrounds/ncz has images in it), so a build that forgot to stage it
# would otherwise silently ship a desktop with no default wallpaper -- the
# exact silent-absence failure this rotator's own comments elsewhere warn
# about. Fail loudly instead.
NCZ_DEB=$(compgen -G "$WALLPAPER_DEBS/ncz-wallpapers-ncz_*.deb" 2>/dev/null | sort -V | tail -1 || true)
if [ -z "$NCZ_DEB" ]; then
    echo "[45] ERROR: ncz-wallpapers-ncz_*.deb not staged in $WALLPAPER_DEBS -- the desktop would have no default wallpaper" >&2
    echo "[45]        rebuild it: build/build-wallpaper-contrib-deb.sh ncz" >&2
    exit 1
fi
echo "[45] installing required NCZ wallpaper pack: $(basename "$NCZ_DEB")"
dpkg -i "$NCZ_DEB"
CONTRIB_DEBS=$(compgen -G "$WALLPAPER_DEBS/*.deb" | grep -v "^$WALLPAPER_DEBS/ncz-wallpapers-ncz_" || true)
if [ -n "$CONTRIB_DEBS" ]; then
    echo "[45] installing contributed Artist Pack(s):"
    printf '%s\n' "$CONTRIB_DEBS" | while read -r _deb; do
        echo "[45]   $(basename "$_deb")"
    done
    printf '%s\n' "$CONTRIB_DEBS" | xargs dpkg -i
else
    echo "[45] no contributed Artist Pack debs staged in $WALLPAPER_DEBS -- shipping NCZ + Bing + Singularity Default only"
fi

# Default = the Cygnus 26.10 hero (edge-on), from the Cygnus Artist Pack. The
# pointer is set after the packs install the image it names, and a missing
# image fails loudly: a 26.10 desktop without its release wallpaper is a defect.
CYGNUS_DEFAULT=cygnus-2610/cygnus-hero-edge-on.jpg
if [ ! -f "/usr/share/backgrounds/ncz/$CYGNUS_DEFAULT" ]; then
    echo "[45] ERROR: Cygnus default wallpaper /usr/share/backgrounds/ncz/$CYGNUS_DEFAULT missing -- ncz-wallpapers-cygnus-2610_*.deb not staged/installed" >&2
    echo "[45]        rebuild it: build/build-wallpaper-contrib-deb.sh cygnus-2610" >&2
    exit 1
fi
ln -sfn "$CYGNUS_DEFAULT" /usr/share/backgrounds/ncz/default.jpg
echo "[45] default wallpaper -> $CYGNUS_DEFAULT"

# Bing refresh. `fetch --if-stale` is cheap when the cache is fresh, so it runs
# at every login and daily. It exits 75 while the network is down; the service
# then retries with growing delay (30s up to 1h) instead of waiting a day. Other
# failures do not retry. System accounts (the greeter) never fetch: they would
# create the shared cache with the wrong owner.
# Two timers because RandomizedDelaySec applies to every trigger of a timer: the
# login run must not be delayed, the daily run is spread out.
cat > /usr/lib/systemd/user/ncz-wallpaper-bing.service <<'EOF'
[Unit]
Description=Fetch Bing wallpapers
ConditionUser=!@system
StartLimitIntervalSec=0

[Service]
Type=oneshot
ExecStart=/usr/local/bin/ncz-wallpaper-bing fetch --if-stale
Restart=no
RestartForceExitStatus=75
RestartSec=30
RestartSteps=6
RestartMaxDelaySec=1h
Nice=10
EOF
cat > /usr/lib/systemd/user/ncz-wallpaper-bing.timer <<'EOF'
[Unit]
Description=Fetch Bing wallpapers at login

[Timer]
OnStartupSec=15s
Unit=ncz-wallpaper-bing.service

[Install]
WantedBy=timers.target
EOF
cat > /usr/lib/systemd/user/ncz-wallpaper-bing-daily.timer <<'EOF'
[Unit]
Description=Fetch Bing wallpapers (daily)

[Timer]
OnCalendar=daily
RandomizedDelaySec=30m
Persistent=true
Unit=ncz-wallpaper-bing.service

[Install]
WantedBy=timers.target
EOF
chmod 0644 /usr/lib/systemd/user/ncz-wallpaper-bing.service /usr/lib/systemd/user/ncz-wallpaper-bing.timer \
    /usr/lib/systemd/user/ncz-wallpaper-bing-daily.timer
for _t in ncz-wallpaper-bing.timer ncz-wallpaper-bing-daily.timer; do
    systemctl --global enable "$_t" >/dev/null 2>&1 \
        && echo "[45]   enabled $_t" \
        || echo "[45]   WARN: could not enable $_t"
done

# Rotator: pick + apply. 26.7 default DE = Singularity (Wayland, GTK4): set the
# backdrop via `dev.sinty.desktop background-picture-uri` (gsettings), with the
# native shell owning the visible wallpaper.
cat > /usr/local/bin/ncz-wallpaper-rotate <<'ROT'
#!/bin/sh
WP_DIR=/usr/share/backgrounds/ncz

# A systemd --user service may have been started before the compositor session
# imported WAYLAND_DISPLAY and the /opt/singularity environment. Refresh the
# values at rotate time so an old daemon writes GSettings in the live desktop
# session and the native shell receives the change.
if command -v systemctl >/dev/null 2>&1; then
    _ncz_env=$(systemctl --user show-environment 2>/dev/null || true)
    for _ncz_name in DISPLAY WAYLAND_DISPLAY XDG_SESSION_TYPE XDG_CURRENT_DESKTOP DESKTOP_SESSION \
        DBUS_SESSION_BUS_ADDRESS GSETTINGS_SCHEMA_DIR XDG_DATA_DIRS GI_TYPELIB_PATH PATH LD_LIBRARY_PATH; do
        _ncz_line=$(printf '%s\n' "$_ncz_env" | grep "^$_ncz_name=" | tail -n1)
        [ -n "$_ncz_line" ] && export "$_ncz_line"
    done
    unset _ncz_env _ncz_name _ncz_line
fi

# The NCZ_* overrides exist for build/test_wallpaper_fit.py only.
SSD=${NCZ_SINGULARITY_SCHEMA_DIR:-/opt/singularity/share/glib-2.0/schemas}
FIT=${NCZ_WALLPAPER_FIT:-/usr/local/bin/ncz-wallpaper-fit}
COLLECTIONS=${NCZ_WALLPAPER_COLLECTIONS:-/usr/local/bin/ncz-wallpaper-collections}

detect_de() {
    case "${XDG_CURRENT_DESKTOP:-}${DESKTOP_SESSION:-}" in
        *Singularity*|*singularity*) echo singularity; return ;;
        *GNOME*|*gnome*)      echo gnome; return ;;
    esac
    if   pgrep -u "$USER" -x singularity-desktop >/dev/null 2>&1; then echo singularity
    elif pgrep -u "$USER" -x gnome-shell >/dev/null 2>&1; then echo gnome
    fi
}

# Apply a file:// URI the way each desktop reads it.
apply_uri() {  # <de> <uri>
    case "$1" in
        singularity)
            # Singularity reads dev.sinty.desktop; its schema lives in the isolated
            # /opt/singularity prefix, so point gsettings at that schema dir.
            if command -v gsettings >/dev/null 2>&1 && [ -d "$SSD" ]; then
                GSETTINGS_SCHEMA_DIR="$SSD" gsettings set dev.sinty.desktop background-picture-uri "$2" 2>/dev/null || true
            fi
            # The native shell observes this setting. A second background layer
            # would hide changes made through the desktop wallpaper chooser.
            ;;
        gnome)
            gsettings set org.gnome.desktop.background picture-uri "$2" 2>/dev/null || true
            gsettings set org.gnome.desktop.background picture-uri-dark "$2" 2>/dev/null || true
            gsettings set org.gnome.desktop.background picture-options zoom 2>/dev/null || true
            ;;
    esac
}

current_uri() {  # <de>
    _cur=""
    case "$1" in
        singularity)
            [ -d "$SSD" ] && _cur=$(GSETTINGS_SCHEMA_DIR="$SSD" gsettings get dev.sinty.desktop background-picture-uri 2>/dev/null) ;;
        gnome)
            _cur=$(gsettings get org.gnome.desktop.background picture-uri-dark 2>/dev/null) ;;
    esac
    # gsettings prints a GVariant string: 'file:///...'
    _cur=${_cur#\'}; _cur=${_cur%\'}
    printf '%s\n' "$_cur"
}

# --refit: keep the CURRENT wallpaper but swap it for the aspect variant that
# fits the primary output now (docs/WALLPAPER-SAFE-AREA.md). The desktop draws
# with cover/zoom, so a 16:9 image on a 16:10 panel loses 5% per side. The
# daemon runs this every tick, so a panel or mode change, or an image picked
# by the shell's own rotator or the Settings chooser, is re-fitted within one
# tick. It never picks a new image, never touches the rotation state, and
# writes GSettings only when the fitted URI differs.
if [ "${1:-}" = --refit ]; then
    [ -x "$FIT" ] || exit 0
    DE=$(detect_de)
    [ -n "$DE" ] || exit 0
    CUR=$(current_uri "$DE")
    [ -n "$CUR" ] || exit 0
    NEW=$("$FIT" choose-uri "$CUR" 2>/dev/null)
    if [ -n "$NEW" ] && [ "$NEW" != "$CUR" ]; then
        apply_uri "$DE" "$NEW"
        printf '%s\n' "ncz-wallpaper-rotate: refit $CUR -> $NEW" >&2
    fi
    exit 0
fi

# WHICH COLLECTION. Singularity Desktop writes the user's choice directly to
# its wallpaper-rotation state directory. Keep reading the old NCZ-owned path
# as a fallback for upgrades from builds that exposed it independently.
CONFIG_HOME=${XDG_CONFIG_HOME:-$HOME/.config}
CONF="$CONFIG_HOME/singularity/wallpaper-rotation/collection"
LEGACY_CONF="$CONFIG_HOME/ncz-wallpaper/collection"
[ ! -r "$CONF" ] && CONF=$LEGACY_CONF
COLLECTION=""
[ -r "$CONF" ] && COLLECTION=$(tr -d " \t\r\n" < "$CONF" 2>/dev/null)
# Default collection: the Cygnus Artist Pack (falls back to ncz if absent).
if [ -z "$COLLECTION" ]; then
    COLLECTION=ncz
    "$COLLECTIONS" path cygnus-2610 >/dev/null 2>&1 && COLLECTION=cygnus-2610
fi

PIC=""
PICK_STATUS=127
PICK_ERROR="collection helper is not installed or executable"
STATE_DIR=${XDG_RUNTIME_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/ncz-wallpaper}
STATE_FILE="$STATE_DIR/ncz-wallpaper-state"
STATE_COLLECTION_FILE="$STATE_DIR/ncz-wallpaper-state.collection"
mkdir -p "$STATE_DIR" 2>/dev/null || true

wallpaper_log() {
    # stderr is captured by ncz-wallpaper-rotator.service and is therefore
    # inspectable with `journalctl --user -u ncz-wallpaper-rotator.service`.
    printf '%s\n' "ncz-wallpaper-rotate: $*" >&2
}

if [ -x "$COLLECTIONS" ]; then
    PICK_ERROR_FILE="$STATE_DIR/ncz-wallpaper-pick-error.$$"
    PIC=$("$COLLECTIONS" pick "$COLLECTION" 2>"$PICK_ERROR_FILE")
    PICK_STATUS=$?
    PICK_ERROR=$(tr '\n' ' ' < "$PICK_ERROR_FILE" 2>/dev/null)
    rm -f "$PICK_ERROR_FILE"
fi
if [ "$PICK_STATUS" -ne 0 ] || [ -z "$PIC" ] || [ ! -f "$PIC" ]; then
    REASON="status=$PICK_STATUS returned=${PIC:-<empty>}"
    [ -n "$PIC" ] && [ ! -f "$PIC" ] && REASON="$REASON (file does not exist)"
    [ -n "$PICK_ERROR" ] && REASON="$REASON error=$PICK_ERROR"

    # Never make a transient provider/cache failure look like the user chose
    # the built-in NCZ collection.  Reapply the last successful image only
    # when it was picked for this same collection; otherwise leave the current
    # desktop untouched and let the next timer cycle retry.
    LAST_COLLECTION=""
    [ -r "$STATE_COLLECTION_FILE" ] && LAST_COLLECTION=$(tr -d " \t\r\n" < "$STATE_COLLECTION_FILE" 2>/dev/null)
    LAST_PIC=""
    [ -r "$STATE_FILE" ] && LAST_PIC=$(sed -n '1p' "$STATE_FILE" 2>/dev/null)
    if [ "$LAST_COLLECTION" = "$COLLECTION" ] && [ -n "$LAST_PIC" ] && [ -f "$LAST_PIC" ]; then
        PIC=$LAST_PIC
        wallpaper_log "collection '$COLLECTION' pick failed ($REASON); keeping last valid image '$PIC'"
    elif [ "$COLLECTION" = ncz ]; then
        PIC=$(find "$WP_DIR" -maxdepth 1 -type f -name 'ncz-wallpaper-*.jpg' 2>/dev/null | shuf -n1)
        [ -n "$PIC" ] && wallpaper_log "default collection '$COLLECTION' pick failed ($REASON); using built-in image '$PIC'"
    else
        wallpaper_log "collection '$COLLECTION' pick failed ($REASON); leaving the current wallpaper unchanged"
        exit 1
    fi
fi
[ -z "$PIC" ] && { wallpaper_log "collection '$COLLECTION' has no usable image"; exit 1; }
# Show the aspect variant of the picked image that fits the primary output
# (16:10 panels get the 16:10 composition). The helper prints its input on any
# doubt, and a missing helper or file keeps the original.
if [ -x "$FIT" ]; then
    FIT_PIC=$("$FIT" choose "$PIC" 2>/dev/null)
    [ -n "$FIT_PIC" ] && [ -f "$FIT_PIC" ] && PIC=$FIT_PIC
fi
# default.jpg is a convenience pointer, not the mechanism -- the wallpaper is
# applied through GSettings below. The rotator runs as the logged-in
# user and $WP_DIR is root-owned 0755, so this ln FAILS with EPERM every time.
# It was already suppressed with "|| true", which turned a guaranteed failure
# into silence. Only attempt it when the directory is actually writable.
if [ -w "$WP_DIR" ]; then
    ln -sfn "$(basename "$PIC")" "$WP_DIR/default.jpg" 2>/dev/null || true
fi

apply_uri "$(detect_de)" "file://$PIC"
printf '%s\n' "$PIC" > "$STATE_FILE" 2>/dev/null
printf '%s\n' "$COLLECTION" > "$STATE_COLLECTION_FILE" 2>/dev/null
ROT
chmod 0755 /usr/local/bin/ncz-wallpaper-rotate

# Daemon: 2s warm-up, then rotate only when the configured interval has elapsed.
#
# RESTART MUST NOT ROTATE (fix 2026-10-11). This daemon is restarted on EVERY
# login: ncz-wallpaper-session-ready restarts the user unit once the live
# session environment is exported (post-install/20-desktop.sh), and both the
# systemd --user unit and the XDG autostart fallback start it. The old daemon
# ran `ncz-wallpaper-rotate` as its very first action, so a login, a session
# restart, or a crash loop (e.g. the O6N shell crash loop) changed the
# wallpaper every single time. Rotation is now gated on a persisted timestamp:
#
#   $XDG_STATE_HOME/ncz-wallpaper/last-rotate   (default ~/.local/state/...)
#
# On start the daemon rotates only when there is no recorded rotation (a
# brand-new user, who gets one wallpaper) or the configured interval has
# genuinely elapsed. A recorded timestamp in the future (clock stepped back) or
# otherwise unreadable state is treated as elapsed so rotation is never blocked
# forever. rotate-enabled=0 suppresses the start-up rotation. The aspect re-fit
# still runs on start and every tick (below): it keeps the CURRENT image fitted
# to the panel and is a no-op when nothing changed.
cat > /usr/local/bin/ncz-wallpaper-daemon <<'DAEMON'
#!/bin/sh
# r110: single-instance guard so session restarts don't stack daemons
LOCK="${XDG_RUNTIME_DIR:-/tmp}/ncz-wallpaper-daemon.lock"
if [ -e "$LOCK" ] && kill -0 "$(cat "$LOCK" 2>/dev/null)" 2>/dev/null; then exit 0; fi
echo $$ > "$LOCK"
trap 'rm -f "$LOCK"' EXIT

# The rotate binary is overridable for build/test-wallpaper-rotator-interval.sh
# only; the default is the shipped path.
ROTATE=${NCZ_WALLPAPER_ROTATE:-/usr/local/bin/ncz-wallpaper-rotate}

# ROTATION IS CONFIGURABLE, and can be switched off.
#
# Read every iteration, not once: the desktop UI writes these files, and a user
# who changes the interval or turns rotation off should not have to log out for
# it to take effect.
#
#   ~/.config/singularity/wallpaper-rotation/rotate-enabled
#   ~/.config/singularity/wallpaper-rotation/rotate-interval
#
# Defaults preserve the previous behaviour exactly: enabled, 600s.
CONFIG_HOME=${XDG_CONFIG_HOME:-$HOME/.config}
CONF_DIR="$CONFIG_HOME/singularity/wallpaper-rotation"
LEGACY_CONF_DIR="$CONFIG_HOME/ncz-wallpaper"

# PERSISTED ROTATION CLOCK. The daemon's rotation schedule must survive a
# restart, so the time of the last rotation is written to disk (atomically:
# write a sibling temp file, then rename) instead of living only in a shell
# variable that a restart forgets. XDG_STATE_HOME is the right home for
# machine state; the old runtime-dir state file (ncz-wallpaper-state) is the
# PIC record and is unrelated.
STATE_HOME=${XDG_STATE_HOME:-$HOME/.local/state}
STATE_DIR="$STATE_HOME/ncz-wallpaper"
LAST_FILE="$STATE_DIR/last-rotate"

read_conf() {  # <basename> [default when absent or empty]
    _f="$CONF_DIR/$1"
    [ ! -r "$_f" ] && _f="$LEGACY_CONF_DIR/$1"
    _v=""
    [ -r "$_f" ] && _v=$(tr -d " \t\r\n" < "$_f" 2>/dev/null)
    printf '%s\n' "${_v:-${2:-}}"
}

read_interval() {
    interval=$(read_conf rotate-interval 600)
    case "$interval" in
        ''|*[!0-9]*) interval=600 ;;
    esac
    # Refuse a pathological interval rather than spinning: a 0 or 1 second
    # rotation would hammer gsettings and, for the Bing collection, the network.
    [ "$interval" -lt 30 ] && interval=30
    printf '%s\n' "$interval"
}

# Seconds since the last recorded rotation, or empty when none is recorded or
# the record is unusable. A future timestamp is reported empty too, so the
# caller rotates instead of waiting for the clock to catch up (clamp).
seconds_since_rotate() {
    [ -r "$LAST_FILE" ] || return 0
    _last=$(tr -d " \t\r\n" < "$LAST_FILE" 2>/dev/null)
    # Reject empty, non-numeric, and any leading-zero value: a real epoch is 10
    # digits and never starts with 0, and this also avoids octal arithmetic.
    case "$_last" in
        ''|0*|*[!0-9]*) return 0 ;;
    esac
    _now=$(date +%s)
    [ "$_last" -gt "$_now" ] && return 0
    printf '%s\n' "$((_now - _last))"
}

record_rotate() {  # persist the rotation time, atomically
    mkdir -p "$STATE_DIR" 2>/dev/null || true
    _tmp="$LAST_FILE.$$"
    if printf '%s\n' "$(date +%s)" > "$_tmp" 2>/dev/null; then
        mv -f "$_tmp" "$LAST_FILE" 2>/dev/null || rm -f "$_tmp"
    else
        rm -f "$_tmp"
    fi
}

rotate_now() {
    "$ROTATE"
    record_rotate
}

# ---- start-up decision -----------------------------------------------------
# Rotate on start only when nothing is recorded (a brand-new user, who gets a
# wallpaper) or when the interval has genuinely elapsed. A restart inside the
# interval leaves the current wallpaper alone -- this is the whole fix.
sleep 2
"$ROTATE" --refit
if [ "$(read_conf rotate-enabled 1)" != "0" ]; then
    elapsed=$(seconds_since_rotate)
    if [ -z "$elapsed" ] || [ "$elapsed" -ge "$(read_interval)" ]; then
        rotate_now
    fi
fi

# ASPECT RE-FIT (docs/WALLPAPER-SAFE-AREA.md). The loop wakes every TICK
# seconds and runs `ncz-wallpaper-rotate --refit`, which swaps the current
# wallpaper for the aspect variant that fits the primary output and is a no-op
# when nothing changed. That re-evaluates within one tick after a panel, mode
# or rotation change, and also re-fits an image chosen by the Singularity
# shell's own rotator or the Settings wallpaper chooser (both write the
# original 16:9 file). Rotation itself still happens once per interval.
# Cost per tick: one gsettings read, one wlr-randr call and one short python3
# run; GSettings is written only when the fitted file differs. A rotation
# interval lowered below the time already elapsed rotates on the next tick,
# the same as the old loop picking up a new interval after its sleep.
TICK=15
while true; do
    interval=$(read_interval)
    sleep "$TICK"
    "$ROTATE" --refit
    # Wall-clock time since the last rotation, so the refit's own run time
    # does not stretch the interval. Empty means "no usable record" -> rotate.
    elapsed=$(seconds_since_rotate)
    [ -n "$elapsed" ] && [ "$elapsed" -lt "$interval" ] && continue
    [ "$(read_conf rotate-enabled 1)" = "0" ] && continue
    rotate_now
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
# default, paths, sockets and timers. The .desktop file is still written: it
# costs nothing and is the correct mechanism on desktops that DO honour it. It
# is a fallback here, not the mechanism.
#
# RE-LOGIN BUG (item RRH, fixed 2026-10-04). The unit used to be
# WantedBy=default.target with PartOf=graphical-session.target. A systemd --user
# manager outlives a logout (lingering sessions keep it up), so default.target
# stays active and its Wants are never re-pulled, while PartOf= only propagates
# a STOP. Live on O6N: the unit was SIGTERMed at 16:08 when the first desktop
# session ended and was NEVER started again -- the rotator was dead for 7h.
# The session launcher
# (/opt/singularity/bin/singularity-desktop-session; subprojects/
# singularity-session) starts singularity-session.target on EVERY login and
# stops it on logout, so that target is the anchor that actually fires per
# login. 20-desktop.sh bridges /etc/systemd/user/singularity-session.target in
# from the /opt payload (systemd --user does not search /opt). The unit is now
# PartOf=/WantedBy= both singularity-session.target (the per-login caller) and
# graphical-session.target (the standard anchor, so the unit still works under
# other compositors whose session managers start that target themselves).
# No polling, no ExecStartPre: the daemon's single-instance lock is unchanged.

install -d /usr/lib/systemd/user
cat > /usr/lib/systemd/user/ncz-wallpaper-rotator.service <<'UNIT'
[Unit]
Description=NCZ wallpaper rotator
PartOf=singularity-session.target graphical-session.target
After=singularity-session.target graphical-session.target

[Service]
Type=simple
ExecStart=/usr/local/bin/ncz-wallpaper-daemon
Restart=on-failure
RestartSec=10

[Install]
WantedBy=singularity-session.target
WantedBy=graphical-session.target
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

echo "[45] Singularity wallpaper rotator + autostart written (default = Cygnus 26.10)"

# Greeter background = the Cygnus greeter backdrop installed by 55-greeter
# at the native greeter's fallback path /usr/share/backgrounds/singularity/
# default.png. The greeter is greetd + native singularity-greeter (Wayland/Mali,
# Cairo/loginui), which reads that fallback file — no lightdm conf.d, no regreet.
