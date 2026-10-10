#!/bin/bash
# compare-lib.sh -- normalising helpers for build/compare-images.sh and the
# determinism test suite.  A "normalising helper" renders an artifact's
# *content* into a stable text form that is independent of the build host,
# so two artifacts can be diffed and every remaining difference is either
# real (a content change) or explicitly listed as an expected exception.
#
#   ncz_canon_squashfs LIST  <file>   # mode+size+path listing, host-independent
#   ncz_canon_tar      LIST  <file>   # sorted member listing with fixed owner
#   ncz_canon_json     <file>         # canonical JSON with volatile keys dropped
#   ncz_canon_fat      LIST  <file>   # mtools mdir listing, normalised
#   ncz_canon_tree     <dir>          # sha256 of every file, sorted by path
#
# All helpers emit sorted, newline-terminated text and print nothing on stderr
# on success.  They never touch the network.

# JSON keys dropped as build-time-only (a run-metadata.json lives OUTSIDE the
# hashed artifacts, but a receipt may legitimately carry a build host/time:
# those are not part of the determinism contract).
NCZ_JSON_VOLATILE_KEYS="${NCZ_JSON_VOLATILE_KEYS:-finished_at started_at host built_at build_time timestamp}"

ncz_canon_json() {
    python3 -I - "$1" "$NCZ_JSON_VOLATILE_KEYS" <<'PYEOF'
import json, sys
path, volatile = sys.argv[1], set(sys.argv[2].split())
volatile_re = ("ncz_timestamped_debs",)  # version strings carry a build time; values kept

def strip(obj):
    if isinstance(obj, dict):
        out = {}
        for k, v in obj.items():
            if k in volatile:
                out[k] = "<volatile>"
            elif k.endswith("_sha256") or k.endswith("_size"):
                out[k] = v  # kept: part of the content pin
            else:
                out[k] = strip(v)
        return out
    if isinstance(obj, list):
        return [strip(x) for x in obj]
    return obj

with open(path) as fh:
    data = json.load(fh)
print(json.dumps(strip(data), indent=2, sort_keys=True))
PYEOF
}

# Squashfs listing normalised to "<mode> <size> <path>" per member, sorted.
# unsquashfs -ll prints owner/group names that depend on the host's passwd db,
# plus a timestamp that -all-time 0 already pins; we keep only mode, size and
# path so a host with different uid->name mapping does not show as a diff.
ncz_canon_squashfs_list() {
    unsquashfs -ll "$1" 2>/dev/null | awk '
        NF >= 4 && $1 ~ /^[-dlbcps]/ {
            mode=$1; size=$3; path=$NF;
            # mode string as-is (type char + 9 permission bits) + size + path
            print mode, size, path;
        }' | sort
}

# tar member listing: fixed reference time, numeric owner, sorted.
ncz_canon_tar_list() {
    tar -tvf "$1" --numeric-owner --full-time 2>/dev/null \
        | awk '{ $4=$5=""; print }' \
        | LC_ALL=C sort
}

# FAT (ESP) listing via mtools: recursive mdir, normalised.
ncz_canon_fat_list() {
    mdir -i "$1" -b -/ ::/ 2>/dev/null | LC_ALL=C sort
}

# Portable file mode (GNU stat -c, BSD stat -f).
_ncz_stat_mode() {
    stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null || echo '?'
}

# Recursive content listing of a directory tree: "<kind> <mode> <sha256|target> <relpath>".
# Portable (no GNU find -printf) so the determinism test also runs on the
# macOS dev box, and content-hash based so a single byte change is caught.
ncz_canon_tree() {
    local dir="$1" path mode
    ( cd "$dir" && find . -mindepth 1 2>/dev/null | LC_ALL=C sort | while IFS= read -r path; do
        mode="$(_ncz_stat_mode "$path")"
        if [ -L "$path" ]; then
            printf 'l %s %s %s\n' "$mode" "$(readlink "$path")" "${path#./}"
        elif [ -f "$path" ]; then
            printf 'f %s %s %s\n' "$mode" "$(sha256sum "$path" | awk '{print $1}')" "${path#./}"
        elif [ -d "$path" ]; then
            printf 'd %s - %s\n' "$mode" "${path#./}"
        fi
    done )
}

# Strip a snapshot/ISO date stamp from a filename or string (for normalising
# artifact NAMES that legitimately carry a build date).
ncz_normalise_name() {
    sed -E 's/-(19|20)[0-9]{6}-/-YYYYMMDD-/g; s/[0-9]{8}/YYYYMMDD/g' <<<"$1"
}
