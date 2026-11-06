#!/bin/bash
# build/lib/fetch-pinned-rev.sh -- clone an upstream repo AT A PINNED REVISION.
#
# M9: build-gst-cix.sh used `git clone --depth 1` of a branch, so build day's head was
# what shipped, and the patch it then extracts from that tree (subprojects/gst-plugins-cix)
# came from whatever head happened to contain. A branch name is not a pin.
#
# ncz_fetch_pinned_rev URL REV DEST
#   0  DEST is a checkout of exactly REV
#   1  refused: REV is empty, not a full 40-hex sha, or the checkout does not match it
#
# Full shas only: a short sha or a tag can be moved or become ambiguous, and this exists to
# remove exactly that freedom.

ncz_fetch_pinned_rev() {
    local url="$1" rev="$2" dest="$3"
    case "$rev" in
        '')            echo "ERROR: no pinned revision for $url; set the pin (release.conf / env) before building" >&2; return 1 ;;
        *[!0-9a-f]*)   echo "ERROR: '$rev' is not a full lowercase 40-hex sha - a branch or tag is not a pin" >&2; return 1 ;;
    esac
    [ "${#rev}" = 40 ] || { echo "ERROR: '$rev' is ${#rev} characters, expected a full 40-hex sha" >&2; return 1; }

    rm -rf "$dest"
    mkdir -p "$dest"
    if ! git -C "$dest" init -q; then
        echo "ERROR: cannot initialise $dest" >&2; return 1
    fi
    if ! git -C "$dest" fetch -q --depth 1 "$url" "$rev"; then
        echo "ERROR: cannot fetch $rev from $url" >&2; return 1
    fi
    if ! git -C "$dest" checkout -q FETCH_HEAD; then
        echo "ERROR: cannot check out $rev in $dest" >&2; return 1
    fi
    local got
    got="$(git -C "$dest" rev-parse HEAD)"
    if [ "$got" != "$rev" ]; then
        echo "ERROR: $dest is at $got, expected $rev" >&2; return 1
    fi
    return 0
}
