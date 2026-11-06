#!/bin/bash
# warm-debootstrap-cache.sh LOG CACHE_DIR [PARALLEL]
#
# debootstrap fetches each package exactly once per run and never retries, so
# against a degraded mirror (snapshot.debian.org answers 503/504 on pool
# objects while its indices still serve) a retry loop gains only the handful of
# files that happened to be CDN-cached at that instant -- convergence can take
# hours of whole-run retries.
#
# This instead reads the URLs debootstrap already reported as failed
# ("W: Couldn't download package ... at <url>") and retries each one on its
# own, in parallel, into the same cache directory.  debootstrap then resumes
# from a warm cache and only walks packages that are still genuinely missing.
#
# A small serial probe runs first: if the mirror cannot serve even a three-file
# sample it is down, and spraying several hundred requests at it would waste
# the window in which it might recover.  Exit 3 = "down, try again later",
# which the calling wrapper treats like any other failed attempt.
#
# Nothing here is trusted implicitly: debootstrap still checks every cached
# .deb against the checksums in the signed Packages index, so a bad download is
# rejected at unpack time rather than accepted.
set -uo pipefail

LOG=${1:?usage: warm-debootstrap-cache.sh LOG CACHE_DIR [PARALLEL]}
CACHE=${2:?usage: warm-debootstrap-cache.sh LOG CACHE_DIR [PARALLEL]}
PAR=${3:-4}

[ -r "$LOG" ] || { echo "warm-cache: no log at $LOG" >&2; exit 1; }
mkdir -p "$CACHE"
# A killed run can leave a .part file behind; they are never used as cache.
rm -f "$CACHE"/*.part 2>/dev/null

mapfile -t urls < <(grep -o "https://[^[:space:]]*\.deb" "$LOG" | sort -u)
if [ "${#urls[@]}" -eq 0 ]; then
    echo "warm-cache: no failed .deb URLs in $LOG (nothing to do)"
    exit 0
fi

miss=()
for u in "${urls[@]}"; do
    f="$CACHE/$(basename "$u")"
    [ -s "$f" ] || miss+=("$u")
done
echo "warm-cache: ${#urls[@]} distinct .deb URLs, ${#miss[@]} still missing, parallel=$PAR"
if [ "${#miss[@]}" -eq 0 ]; then
    exit 0
fi

# ---- probe (breaker) -------------------------------------------------------
probe_n=${#miss[@]}
[ "$probe_n" -gt 3 ] && probe_n=3
fail_probes=0
i=0
while [ "$i" -lt "$probe_n" ]; do
    url=${miss[$i]}
    f="$CACHE/$(basename "$url")"
    ok=0
    a=1
    while [ "$a" -le 3 ]; do
        if wget -q -T 45 -t 1 -O "$f.part" "$url" 2>/dev/null && [ -s "$f.part" ]; then
            mv -f "$f.part" "$f"
            ok=1
            break
        fi
        rm -f "$f.part"
        sleep $((2 * a))
        a=$((a + 1))
    done
    [ "$ok" -eq 1 ] || fail_probes=$((fail_probes + 1))
    i=$((i + 1))
done

if [ "$fail_probes" -eq "$probe_n" ]; then
    echo "warm-cache: mirror appears DOWN (0/$probe_n probes fetched) - skipping this wave"
    exit 3
fi
echo "warm-cache: probe ok ($((probe_n - fail_probes))/$probe_n fetched) - running the wave"

# recompute: the probe may have filled some entries
miss=()
for u in "${urls[@]}"; do
    f="$CACHE/$(basename "$u")"
    [ -s "$f" ] || miss+=("$u")
done
if [ "${#miss[@]}" -eq 0 ]; then
    echo "warm-cache: cache complete after probe"
    exit 0
fi

# ---- wave ------------------------------------------------------------------
fetch_one() {
    url="$1"
    f="$CACHE/$(basename "$url")"
    tries=8
    [ -s "$f" ] && return 0
    a=1
    while [ "$a" -le "$tries" ]; do
        if wget -q -T 45 -t 1 -O "$f.part" "$url" 2>/dev/null && [ -s "$f.part" ]; then
            mv -f "$f.part" "$f"
            echo "OK   $(basename "$url") (attempt $a)"
            return 0
        fi
        rm -f "$f.part"
        sleep $((3 * a))
        a=$((a + 1))
    done
    echo "MISS $(basename "$url") after $tries attempts"
    return 1
}
export -f fetch_one
export CACHE

printf "%s\n" "${miss[@]}" | xargs -r -P "$PAR" -I{} bash -c 'fetch_one "$@"' _ {} 2>/dev/null

got=0
for u in "${miss[@]}"; do
    [ -s "$CACHE/$(basename "$u")" ] && got=$((got + 1))
done
echo "warm-cache: recovered $got of ${#miss[@]} missing packages (cache now $(find "$CACHE" -name '*.deb' | wc -l) files)"
