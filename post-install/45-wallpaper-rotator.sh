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

OCS_ASSETS=/usr/local/lib/cix-installer/assets/wallpaper
if [ -x "$OCS_ASSETS/ncz-wallpaper-ocs" ]; then
    install -m 0755 "$OCS_ASSETS/ncz-wallpaper-ocs" /usr/local/bin/ncz-wallpaper-ocs
    echo "[45]   installed OCS wallpaper backend"
else
    echo "[45]   WARN: OCS wallpaper backend asset missing" >&2
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
            provider)
                case "$(_ini_get "$f" Collection Provider)" in
                    bing) cnt=$(find "${dir:-/var/cache/ncz-wallpapers/bing}" -mindepth 2 -maxdepth 2 -type f -iname '*.jpg' 2>/dev/null | wc -l) ;;
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
                    # Refresh is best-effort: a failed or offline fetch must still
                    # yield yesterday's cached image rather than no wallpaper.
                    if [ -x /usr/local/bin/ncz-wallpaper-bing ]; then
                        /usr/local/bin/ncz-wallpaper-bing fetch >/dev/null 2>&1
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

install -m 0755 /dev/stdin /usr/local/bin/ncz-wallpaper-bing <<'BING_EOF'
#!/bin/bash
# ncz-wallpaper-bing -- fetch Bing's image of the day into a local archive.
#
# Endpoint (verified 2026-08-18):
#   https://www.bing.com/HPImageArchive.aspx?format=js&idx=0&n=8&mkt=<market>
# The JSON gives `urlbase` like "/th?id=OHR.Palmanova_EN-US0340289339". Appending
# "_UHD.jpg" yields the highest resolution; the `url` field is only 1920x1080,
# which is short of the 3840x2160 panel on an O6.
#
# Images are archived as <data-root>/<market>/<startdate>.jpg so markets are
# independent feeds, not translations colliding in a shared directory.
# Attribution is still written alongside as .txt for compatibility, and richer
# provider metadata is written as .json for the history browser.
#
#   fetch           backfill Bing's available window for every enabled market
#   pick            print one archived image from the enabled markets
#   latest          print the newest archived image from the enabled markets
#   info            print attribution for the newest archived image
#   list [--all]    print archive entries as JSON for the history browser
#   pin <mkt> <yyyymmdd> | unpin <mkt> <yyyymmdd>
set -u

# Markets are real FEED SELECTORS, not translation settings. Verified
# 2026-08-19: en-US served Palmanova, en-GB/de-DE/zh-CN served Whyte Cliff, and
# ja-JP/en-AU served a Polish wildlife crossing -- different PHOTOGRAPHS, on the
# same day. So the user can enable more than one feed at once.
#
# Config, in priority order:
#   NCZ_BING_MARKETS="en-US ja-JP"       for testing
#   ~/.config/ncz-wallpaper/bing-markets newline/comma/space separated markets
#   ~/.config/ncz-wallpaper/bing-market  legacy single-market file
#   en-US                                default
exec python3 - "$@" <<'PY'
import datetime
import json
import os
import random
import re
import sys
import tempfile
import urllib.parse
import urllib.request
from pathlib import Path

CONFIG_HOME = Path(os.environ.get("XDG_CONFIG_HOME", str(Path.home() / ".config")))
CONFIG_DIR = CONFIG_HOME / "ncz-wallpaper"
DATA_ROOT = Path(os.environ.get("NCZ_BING_DATA_ROOT", os.environ.get("NCZ_BING_CACHE", "/var/cache/ncz-wallpapers/bing")))
THUMB_ROOT = Path(os.environ.get("NCZ_BING_THUMB_ROOT", str(Path(os.environ.get("XDG_CACHE_HOME", str(Path.home() / ".cache"))) / "ncz-wallpapers" / "thumbs" / "bing")))
API = "https://www.bing.com/HPImageArchive.aspx"
BACKFILL = ((0, 8), (7, 8))
MARKET_RE = re.compile(r"^[A-Za-z]{2}-[A-Za-z]{2}$")
DATE_RE = re.compile(r"^[0-9]{8}$")

def quiet():
    return bool(os.environ.get("NCZ_BING_QUIET"))

def log(msg):
    if not quiet():
        print(f"[bing] {msg}", file=sys.stderr)

def split_tokens(text):
    return [tok for tok in re.split(r"[\s,]+", text.strip()) if tok]

def configured_markets():
    text = os.environ.get("NCZ_BING_MARKETS", "")
    if not text:
        multi = CONFIG_DIR / "bing-markets"
        single = CONFIG_DIR / "bing-market"
        if multi.is_file():
            text = multi.read_text(errors="ignore")
        elif single.is_file():
            text = single.read_text(errors="ignore")
    if not text:
        text = os.environ.get("NCZ_BING_MARKET", "")
    markets = []
    seen = set()
    for market in split_tokens(text or "en-US"):
        if MARKET_RE.match(market) and market not in seen:
            markets.append(market)
            seen.add(market)
    return markets or ["en-US"]

def all_archived_markets():
    if not DATA_ROOT.is_dir():
        return []
    return sorted(p.name for p in DATA_ROOT.iterdir() if p.is_dir() and MARKET_RE.match(p.name))

def retention_days():
    raw = os.environ.get("NCZ_BING_RETENTION_DAYS", "")
    conf = CONFIG_DIR / "bing-retention-days"
    if not raw and conf.is_file():
        raw = conf.read_text(errors="ignore").strip()
    if raw.lower() in ("", "default"):
        return 365
    if raw.lower() in ("0", "forever", "none", "never"):
        return 0
    try:
        return max(0, int(raw))
    except ValueError:
        return 365

def fetch_json(market, idx, n):
    params = urllib.parse.urlencode({"format": "js", "idx": idx, "n": n, "mkt": market})
    url = f"{API}?{params}"
    with urllib.request.urlopen(url, timeout=30) as response:
        return json.loads(response.read().decode("utf-8"))

def image_url(urlbase, tier):
    return "https://www.bing.com" + urlbase + tier + ".jpg"

def download(url, dest, timeout=90):
    dest.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix=dest.name + ".", suffix=".part", dir=str(dest.parent))
    os.close(fd)
    tmp = Path(tmp_name)
    try:
        with urllib.request.urlopen(url, timeout=timeout) as response, tmp.open("wb") as out:
            while True:
                chunk = response.read(1024 * 128)
                if not chunk:
                    break
                out.write(chunk)
        if tmp.stat().st_size == 0:
            raise RuntimeError("empty download")
        tmp.replace(dest)
    except Exception:
        tmp.unlink(missing_ok=True)
        raise

def normalize_image(image, market):
    date = str(image.get("startdate", "")).strip()
    urlbase = str(image.get("urlbase", "")).strip()
    if not DATE_RE.match(date) or not urlbase:
        return None
    return {
        "schema": 1,
        "provider": "bing",
        "market": market,
        "date": date,
        "enddate": str(image.get("enddate", "")).strip(),
        "urlbase": urlbase,
        "caption": str(image.get("title", "")).replace("\n", " ").strip(),
        "copyright": str(image.get("copyright", "")).replace("\n", " ").strip(),
        "copyrightlink": str(image.get("copyrightlink", "")).strip(),
        "quiz": str(image.get("quiz", "")).strip(),
        "hsh": str(image.get("hsh", "")).strip(),
    }

def read_meta(path, market, date):
    meta_path = path.with_suffix(".json")
    txt_path = path.with_suffix(".txt")
    meta = {}
    if meta_path.is_file():
        try:
            meta = json.loads(meta_path.read_text(errors="ignore"))
        except json.JSONDecodeError:
            meta = {}
    meta.setdefault("provider", "bing")
    meta.setdefault("market", market)
    meta.setdefault("date", date)
    meta.setdefault("caption", "")
    meta.setdefault("copyright", "")
    if txt_path.is_file() and (not meta["caption"] or not meta["copyright"]):
        lines = txt_path.read_text(errors="ignore").splitlines()
        if lines:
            meta["caption"] = meta["caption"] or lines[0]
        if len(lines) > 1:
            meta["copyright"] = meta["copyright"] or lines[1]
    return meta

def write_sidecars(directory, meta):
    date = meta["date"]
    txt_path = directory / f"{date}.txt"
    json_path = directory / f"{date}.json"
    if not txt_path.exists():
        txt_path.write_text(f"{meta.get('caption', '')}\n{meta.get('copyright', '')}\n")
    if not json_path.exists():
        json_path.write_text(json.dumps(meta, ensure_ascii=False, indent=2, sort_keys=True) + "\n")

def is_pinned(path):
    return path.with_suffix(".pinned").exists()

def fetch_market(market):
    directory = DATA_ROOT / market
    directory.mkdir(parents=True, exist_ok=True)
    fetched = 0
    seen_dates = set()
    for idx, n in BACKFILL:
        try:
            payload = fetch_json(market, idx, n)
        except Exception as exc:
            log(f"{market}: fetch idx={idx} failed: {exc}")
            continue
        images = payload.get("images", [])
        log(f"{market}: idx={idx}&n={n} returned {len(images)} image(s)")
        for image in images:
            meta = normalize_image(image, market)
            if not meta or meta["date"] in seen_dates:
                continue
            seen_dates.add(meta["date"])
            out = directory / f"{meta['date']}.jpg"
            if not out.exists():
                try:
                    try:
                        download(image_url(meta["urlbase"], "_UHD"), out)
                    except Exception:
                        download(image_url(meta["urlbase"], "_1920x1080"), out)
                    fetched += 1
                    log(f"{market}: cached {meta['date']} ({out.stat().st_size} bytes)")
                except Exception as exc:
                    log(f"{market}: image {meta['date']} failed: {exc}")
                    continue
            write_sidecars(directory, meta)
    prune_market(market)
    return fetched

def prune_market(market):
    keep_days = retention_days()
    if keep_days <= 0:
        return
    cutoff = (datetime.datetime.now(datetime.UTC).date() - datetime.timedelta(days=keep_days)).strftime("%Y%m%d")
    directory = DATA_ROOT / market
    for image in sorted(directory.glob("*.jpg")):
        date = image.stem
        if DATE_RE.match(date) and date < cutoff and not is_pinned(image):
            for suffix in (".jpg", ".txt", ".json"):
                image.with_suffix(suffix).unlink(missing_ok=True)
            log(f"{market}: pruned {date}")

def archive_entries(markets):
    entries = []
    for market in markets:
        directory = DATA_ROOT / market
        if not directory.is_dir():
            continue
        for image in directory.glob("*.jpg"):
            date = image.stem
            if not DATE_RE.match(date):
                continue
            meta = read_meta(image, market, date)
            entries.append((date, market, image, meta))
    return sorted(entries, key=lambda item: (item[0], item[1], str(item[2])), reverse=True)

def ensure_thumb(meta):
    urlbase = meta.get("urlbase", "")
    market = meta.get("market", "")
    date = meta.get("date", "")
    if not urlbase or not market or not date:
        return ""
    thumb = THUMB_ROOT / market / f"{date}_400x240.jpg"
    if not thumb.exists():
        try:
            download(image_url(urlbase, "_400x240"), thumb, timeout=45)
        except Exception as exc:
            log(f"{market}: thumbnail {date} failed: {exc}")
            return ""
    return str(thumb)

def cmd_fetch(_args):
    total = 0
    markets = configured_markets()
    for market in markets:
        total += fetch_market(market)
    return 0 if total or archive_entries(markets) else 1

def cmd_pick(_args):
    entries = archive_entries(configured_markets())
    if not entries:
        return 1
    print(random.choice(entries)[2])
    return 0

def cmd_latest(_args):
    entries = archive_entries(configured_markets())
    if not entries:
        return 1
    print(entries[0][2])
    return 0

def cmd_info(_args):
    entries = archive_entries(configured_markets())
    if not entries:
        return 1
    meta = entries[0][3]
    print(meta.get("caption", ""))
    print(meta.get("copyright", ""))
    return 0

def cmd_list(args):
    if args and args[0] == "--all":
        markets = all_archived_markets()
    elif args:
        markets = [m for m in args if MARKET_RE.match(m)]
    else:
        markets = configured_markets()
    rows = []
    for date, market, image, meta in archive_entries(markets):
        thumb = ensure_thumb(meta)
        rows.append({
            "provider": "bing",
            "date": date,
            "market": market,
            "path": str(image),
            "caption": meta.get("caption", ""),
            "copyright": meta.get("copyright", ""),
            "thumbnail_path": thumb,
            "pinned": is_pinned(image),
        })
    print(json.dumps(rows, ensure_ascii=False, indent=2))
    return 0

def cmd_pin(args, pinned):
    usage = "usage: ncz-wallpaper-bing pin <market> <yyyymmdd>"
    if len(args) != 2 or not MARKET_RE.match(args[0]) or not DATE_RE.match(args[1]):
        print(usage, file=sys.stderr)
        return 2
    marker = DATA_ROOT / args[0] / f"{args[1]}.pinned"
    image = marker.with_suffix(".jpg")
    if not image.exists():
        print(f"no archived image: {image}", file=sys.stderr)
        return 1
    if pinned:
        marker.write_text("pinned\n")
    else:
        marker.unlink(missing_ok=True)
    return 0

def cmd_markets(_args):
    print("en-US\tUnited States")
    print("en-GB\tUnited Kingdom")
    print("en-AU\tAustralia")
    print("en-CA\tCanada")
    print("de-DE\tGermany")
    print("fr-FR\tFrance")
    print("ja-JP\tJapan")
    print("zh-CN\tChina")
    return 0

cmd = sys.argv[1] if len(sys.argv) > 1 else "fetch"
args = sys.argv[2:]
commands = {
    "fetch": cmd_fetch,
    "pick": cmd_pick,
    "latest": cmd_latest,
    "info": cmd_info,
    "list": cmd_list,
    "markets": cmd_markets,
}
if cmd == "pin":
    raise SystemExit(cmd_pin(args, True))
if cmd == "unpin":
    raise SystemExit(cmd_pin(args, False))
if cmd not in commands:
    print("usage: ncz-wallpaper-bing {fetch|pick|latest|info|list [--all]|markets|pin <market> <yyyymmdd>|unpin <market> <yyyymmdd>}", file=sys.stderr)
    raise SystemExit(2)
raise SystemExit(commands[cmd](args))
PY
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

# A systemd --user service may have been started before the compositor session
# imported WAYLAND_DISPLAY and the /opt/singularity environment. Refresh the
# values at rotate time so an old daemon process can still repaint the live
# desktop instead of only changing dconf/state.
if command -v systemctl >/dev/null 2>&1; then
    _ncz_env=$(systemctl --user show-environment 2>/dev/null || true)
    for _ncz_name in DISPLAY WAYLAND_DISPLAY XDG_SESSION_TYPE XDG_CURRENT_DESKTOP DESKTOP_SESSION \
        DBUS_SESSION_BUS_ADDRESS GSETTINGS_SCHEMA_DIR XDG_DATA_DIRS GI_TYPELIB_PATH PATH LD_LIBRARY_PATH; do
        _ncz_line=$(printf '%s\n' "$_ncz_env" | grep "^$_ncz_name=" | tail -n1)
        [ -n "$_ncz_line" ] && export "$_ncz_line"
    done
    unset _ncz_env _ncz_name _ncz_line
fi

# WHICH COLLECTION. The user's choice lives in a plain file so it can be set
# without a settings daemon and read identically from a timer, a shell or the
# desktop. Unset = "ncz", the shipped art, which is the pre-collections
# behaviour.
CONF="${XDG_CONFIG_HOME:-$HOME/.config}/ncz-wallpaper/collection"
COLLECTION=""
[ -r "$CONF" ] && COLLECTION=$(tr -d " \t\r\n" < "$CONF" 2>/dev/null)
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

# ROTATION IS CONFIGURABLE, and can be switched off.
#
# Read every iteration, not once: the desktop UI writes these files, and a user
# who changes the interval or turns rotation off should not have to log out for
# it to take effect.
#
#   ~/.config/ncz-wallpaper/rotate-enabled   "0" disables rotation entirely
#   ~/.config/ncz-wallpaper/rotate-interval  seconds between changes
#
# Defaults preserve the previous behaviour exactly: enabled, 600s.
CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/ncz-wallpaper"
while true; do
    interval=""
    [ -r "$CONF_DIR/rotate-interval" ] && interval=$(tr -d " \t\r\n" < "$CONF_DIR/rotate-interval" 2>/dev/null)
    case "$interval" in
        ''|*[!0-9]*) interval=600 ;;
    esac
    # Refuse a pathological interval rather than spinning: a 0 or 1 second
    # rotation would hammer gsettings and, for the Bing collection, the network.
    [ "$interval" -lt 30 ] && interval=30

    sleep "$interval"

    enabled=""
    [ -r "$CONF_DIR/rotate-enabled" ] && enabled=$(tr -d " \t\r\n" < "$CONF_DIR/rotate-enabled" 2>/dev/null)
    [ "$enabled" = "0" ] && continue
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
