#!/bin/bash
# /usr/local/lib/ncx/upstream-watch.sh
#
# NCX upstream-watch agent — polls every 6 hours for relevant updates from:
#   - Mesa3D (panthor/panvk Gallium + Vulkan driver progress)
#   - Sky1-Linux GitHub org (kernel patches, mesa-sky1, vulkan-wsi-layer, sky1-gpu-support)
#   - CIX official PPA (archive.cixtech.com new package versions)
#   - kernel.org panthor patches (LKML / dri-devel mailing list)
#   - ARM-China Compass NPU driver upstream
#   - GNOME / KDE upstream relevant to ARM/Mali
#
# Output: /var/log/ncx/upstream-watch.log (one digest per run)
# Notification: writes /var/lib/ncx/upstream-watch-changes.txt with new findings
#
# Designed to be quiet: only logs CHANGES vs last known state.

set -e
LOG=/var/log/ncx/upstream-watch.log
STATE=/var/lib/ncx/upstream-watch
CHANGES=/var/lib/ncx/upstream-watch-changes.txt
NOTIFY_EMAIL=""  # set by user via /etc/ncx/upstream-watch.conf if desired

mkdir -p "$(dirname $LOG)" "$STATE"

[ -f /etc/ncx/upstream-watch.conf ] && . /etc/ncx/upstream-watch.conf

ts() { date -u +'%Y-%m-%d %H:%M:%S UTC'; }
log() { echo "[$(ts)] $*" >> "$LOG"; }
note() { echo "$*" >> "$CHANGES"; }

: > "$CHANGES"
log "=== upstream-watch run start ==="

# ----------------------------------------------------------------------
# 1. Sky1-Linux GitHub org — new commits to relevant repos
# ----------------------------------------------------------------------
SKY1_REPOS="linux-sky1 mesa-sky1 vulkan-wsi-layer sky1-gpu-support cix-gpu-kmd kwin-sky1 sky1-firmware sky1-image-build"
for repo in $SKY1_REPOS; do
    LATEST=$(curl -fsSL --max-time 10 "https://api.github.com/repos/Sky1-Linux/$repo/commits?per_page=1" 2>/dev/null \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[0]['sha'][:8],'|',d[0]['commit']['author']['date'],'|',d[0]['commit']['message'].split(chr(10))[0][:80])" 2>/dev/null \
        || echo "fetch_failed")
    PREV_FILE="$STATE/sky1-$repo.last"
    PREV=$(cat "$PREV_FILE" 2>/dev/null || echo "")
    if [ "$LATEST" != "$PREV" ] && [ "$LATEST" != "fetch_failed" ]; then
        note "[Sky1-Linux/$repo] NEW: $LATEST"
        echo "$LATEST" > "$PREV_FILE"
        log "  Sky1-Linux/$repo: $LATEST"
    fi
done

# ----------------------------------------------------------------------
# 2. Mesa3D (panthor + panvk) — recent merge requests
# ----------------------------------------------------------------------
# Mesa is on gitlab.freedesktop.org, polling MR list filtered to panthor/panvk
for term in panthor panvk; do
    LATEST=$(curl -fsSL --max-time 10 "https://gitlab.freedesktop.org/api/v4/projects/176/merge_requests?state=opened&search=$term&per_page=3" 2>/dev/null \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print('|'.join(f\"!{m['iid']} {m['title'][:80]}\" for m in d[:3]))" 2>/dev/null \
        || echo "fetch_failed")
    PREV_FILE="$STATE/mesa-$term.last"
    PREV=$(cat "$PREV_FILE" 2>/dev/null || echo "")
    if [ "$LATEST" != "$PREV" ] && [ "$LATEST" != "fetch_failed" ]; then
        note "[Mesa3D $term MRs] $LATEST"
        echo "$LATEST" > "$PREV_FILE"
        log "  Mesa3D $term: $LATEST"
    fi
done

# ----------------------------------------------------------------------
# 3. CIX PPA — package version changes in archive.cixtech.com
# ----------------------------------------------------------------------
CIX_PKGS="cix-gpu-umd cix-gpu-dkms cix-gpu-driver cix-noe-umd cix-npu-driver-dkms cix-vpu-driver-dkms cix-firmware cix-ai-engine"
TMPDIR=$(mktemp -d)
curl -fsSL --max-time 10 https://archive.cixtech.com/debian/dists/trixie/main/binary-arm64/Packages.gz 2>/dev/null \
    | gunzip 2>/dev/null > "$TMPDIR/Packages" || echo "" > "$TMPDIR/Packages"

for pkg in $CIX_PKGS; do
    VER=$(awk -v p="$pkg" '/^Package: / {pkgname=$2} pkgname==p && /^Version: / {print $2; exit}' "$TMPDIR/Packages" 2>/dev/null)
    [ -z "$VER" ] && continue
    PREV_FILE="$STATE/cix-$pkg.ver"
    PREV=$(cat "$PREV_FILE" 2>/dev/null || echo "")
    if [ "$VER" != "$PREV" ]; then
        note "[CIX PPA] $pkg → $VER (was $PREV)"
        echo "$VER" > "$PREV_FILE"
        log "  cix $pkg: $VER"
    fi
done
rm -rf "$TMPDIR"

# ----------------------------------------------------------------------
# 4. kernel.org dri-devel — recent patch series mentioning panthor/Mali-G720
# ----------------------------------------------------------------------
LATEST=$(curl -fsSL --max-time 10 "https://patchwork.freedesktop.org/api/1.0/series/?ordering=-date&q=panthor&page_size=3" 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print('|'.join(f\"#{s['id']} {s['name'][:80]}\" for s in d.get('results',[])[:3]))" 2>/dev/null \
    || echo "fetch_failed")
PREV_FILE="$STATE/dri-devel-panthor.last"
PREV=$(cat "$PREV_FILE" 2>/dev/null || echo "")
if [ "$LATEST" != "$PREV" ] && [ "$LATEST" != "fetch_failed" ]; then
    note "[dri-devel panthor patches] $LATEST"
    echo "$LATEST" > "$PREV_FILE"
    log "  dri-devel panthor: $LATEST"
fi

# ----------------------------------------------------------------------
# 5. ARM-China Compass NPU driver
# ----------------------------------------------------------------------
LATEST=$(curl -fsSL --max-time 10 "https://api.github.com/repos/Arm-China/Compass_NPU_Driver/commits?per_page=1" 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[0]['sha'][:8],'|',d[0]['commit']['author']['date'],'|',d[0]['commit']['message'].split(chr(10))[0][:80])" 2>/dev/null \
    || echo "fetch_failed")
PREV_FILE="$STATE/arm-china-compass.last"
PREV=$(cat "$PREV_FILE" 2>/dev/null || echo "")
if [ "$LATEST" != "$PREV" ] && [ "$LATEST" != "fetch_failed" ]; then
    note "[Arm-China Compass NPU] $LATEST"
    echo "$LATEST" > "$PREV_FILE"
    log "  Arm-China NPU: $LATEST"
fi

# ----------------------------------------------------------------------
# 6. GNOME mutter — bug reports related to Mali / panvk
# ----------------------------------------------------------------------
LATEST=$(curl -fsSL --max-time 10 "https://gitlab.gnome.org/api/v4/projects/682/issues?search=panvk&state=opened&per_page=3" 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print('|'.join(f\"#{i['iid']} {i['title'][:80]}\" for i in d[:3]))" 2>/dev/null \
    || echo "fetch_failed")
PREV_FILE="$STATE/mutter-panvk.last"
PREV=$(cat "$PREV_FILE" 2>/dev/null || echo "")
if [ "$LATEST" != "$PREV" ] && [ "$LATEST" != "fetch_failed" ]; then
    note "[mutter panvk issues] $LATEST"
    echo "$LATEST" > "$PREV_FILE"
    log "  mutter panvk: $LATEST"
fi

# ----------------------------------------------------------------------
# Summary + notification
# ----------------------------------------------------------------------
NCHANGES=$(wc -l < "$CHANGES" 2>/dev/null || echo 0)
log "=== upstream-watch run end: $NCHANGES change(s) ==="

if [ "$NCHANGES" -gt 0 ]; then
    echo ""
    echo "NCX upstream-watch — $NCHANGES new finding(s) at $(ts):"
    cat "$CHANGES"

    # Optional email notification
    if [ -n "$NOTIFY_EMAIL" ] && command -v mail >/dev/null 2>&1; then
        cat "$CHANGES" | mail -s "[NCX] $NCHANGES upstream changes" "$NOTIFY_EMAIL" || true
    fi
fi
