#!/bin/bash
# build/lib/verify-build-input.sh -- check a fetched file against the committed pin.
#
# M9: the build still downloads a few things (a compiler-less Python, uv), and until
# now their only check was "unpack it and run it". That proves the file is not
# truncated and is the right architecture; it does not prove the bytes are the ones
# anyone reviewed. manifests/build-inputs.tsv already pins the same artifacts after
# vendoring, so the pin exists - it was simply never consulted at download time.
#
# ncz_verify_build_input PINFILE DEST FILE
#   0  sha256 matches the pin row for DEST
#   1  mismatch, or the file is missing (the caller must refuse: this is not the
#      reviewed bytes)
#   2  no pin row yet (first vendoring): the caller warns loudly and continues, so
#      the pin-creating flow still works
#
# Never write the pin from here: pins are moved by stage-build-inputs.sh --publish.

ncz_verify_build_input() {
    local pinfile="$1" dest="$2" file="$3" want got
    if [ ! -r "$pinfile" ]; then
        echo "ERROR: no pin file at $pinfile" >&2
        return 1
    fi
    if [ ! -f "$file" ]; then
        echo "ERROR: nothing to verify at $file" >&2
        return 1
    fi
    want="$(awk -F'\t' -v d="$dest" '$2==d && $1 !~ /^#/ {print $3; exit}' "$pinfile")"
    [ -n "$want" ] || return 2
    got="$(sha256sum "$file" | cut -d' ' -f1)"
    if [ "$got" = "$want" ]; then
        return 0
    fi
    echo "ERROR: $dest sha256 $got != pinned $want ($pinfile)" >&2
    return 1
}
