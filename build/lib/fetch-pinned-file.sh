#!/bin/bash
# build/lib/fetch-pinned-file.sh -- fetch a URL into a cache ONLY when its sha256
# matches the pin (M9, docs/BUILD-STABILITY.md "Pin and cache the network inputs").
#
# ncz_fetch_pinned_file URL SHA256 DEST [CACHE_DIR]
#   0  DEST now carries the pinned bytes; on a cache hit no network call is made,
#      on a miss the verified file is also stored in CACHE_DIR for reuse
#   1  refused: bad arguments, unreachable URL, or the downloaded bytes do not
#      match SHA256 (the error names both hashes)
#
# Behaviour:
#   cache hit    CACHE_DIR/<name> exists with the pinned sha -- copied straight
#                to DEST, no download.
#   miss         download to CACHE_DIR/<name>.tmp.<pid>, verify, rename into
#                the cache, then copy to DEST. DEST is written only after the
#                cache entry is verified.
#   mismatch     the temp file is removed, DEST is left untouched, and the
#                failure names the expected and actual sha256. A poisoned or
#                stale cache file is never served: it is replaced by a fresh,
#                verified download.
#   download failure -- DEST untouched, no temp file left behind.
#
# CACHE_DIR defaults to ~/.cache/ncz-fetch-pinned. file:// URLs are served
# locally; every other URL goes through curl.

ncz_fetch_pinned_file() {
    local url="$1" pin="$2" dest="$3" cache_dir="${4:-${XDG_CACHE_HOME:-$HOME/.cache}/ncz-fetch-pinned}"

    case "$url" in '')   echo "ERROR: no URL given to fetch" >&2; return 1 ;; esac
    case "$dest" in '')  echo "ERROR: no DEST path given" >&2; return 1 ;; esac
    case "$pin" in
        '')            echo "ERROR: no pinned sha256 given -- a bare URL is not a pin" >&2; return 1 ;;
        *[!0-9a-fA-F]*) echo "ERROR: '$pin' is not a hex sha256" >&2; return 1 ;;
    esac
    [ "${#pin}" = 64 ] || { echo "ERROR: '$pin' is ${#pin} characters, expected a full 64-hex sha256" >&2; return 1; }
    pin="$(printf '%s' "$pin" | tr '[:upper:]' '[:lower:]')"

    local name tmp actual cache_file
    name="$(basename "$url")"
    case "$name" in
        ''|.|..|*/*)
            echo "ERROR: URL '$url' has no safe basename to cache under (got '$name')" >&2
            return 1
            ;;
    esac
    cache_file="$cache_dir/$name"

    local _curl=(curl -fsSL --output)
    local _have_curl=0
    command -v curl >/dev/null 2>&1 && _have_curl=1

    # Fetch into $1, serving file:// URLs locally so no network is required.
    do_fetch() {
        local target="$1"
        case "$url" in
            file://*)
                local src="${url#file://}"
                [ -f "$src" ] || return 1
                cp -f -- "$src" "$target"
                ;;
            *)
                [ "$_have_curl" = 1 ] || return 1
                "${_curl[@]}" "$target" "$url"
                ;;
        esac
    }

    # Serve a verified cache entry if present; never serve an entry with the
    # wrong hash (stale/poisoned) -- it is replaced by a fresh, verified download.
    if [ -f "$cache_file" ]; then
        actual="$(sha256sum "$cache_file" | awk '{print $1}')"
        if [ "$actual" = "$pin" ]; then
            cp -f -- "$cache_file" "$dest" || { echo "ERROR: cannot copy $cache_file to $dest" >&2; return 1; }
            echo "[fetch-pinned-file] cache hit: $cache_file (sha256 ${pin:0:12}...)"
            return 0
        fi
        echo "[fetch-pinned-file] cache entry $cache_file is sha256 ${actual:0:12}... (expected ${pin:0:12}...); replacing it" >&2
        rm -f -- "$cache_file"
    fi

    mkdir -p -- "$cache_dir" || { echo "ERROR: cannot create cache dir $cache_dir" >&2; return 1; }

    tmp="$(mktemp "$cache_dir/$name.tmp.XXXXXX")" || { echo "ERROR: cannot create temp file in $cache_dir" >&2; return 1; }
    if ! do_fetch "$tmp"; then
        rm -f -- "$tmp"
        echo "ERROR: cannot fetch $url" >&2
        return 1
    fi

    actual="$(sha256sum "$tmp" | awk '{print $1}')"
    if [ "$actual" != "$pin" ]; then
        rm -f -- "$tmp"
        echo "ERROR: sha256 mismatch for $url" >&2
        echo "       expected (pin) : $pin" >&2
        echo "       actual         : $actual" >&2
        return 1
    fi

    # Verified: rename into the cache (atomic replace of any stale entry), then DEST.
    mv -f -- "$tmp" "$cache_file" || { rm -f -- "$tmp"; echo "ERROR: cannot store $cache_file in cache" >&2; return 1; }
    cp -f -- "$cache_file" "$dest" || { echo "ERROR: cannot copy $cache_file to $dest" >&2; return 1; }
    echo "[fetch-pinned-file] cached + verified: $cache_file -> $dest"
    return 0
}
