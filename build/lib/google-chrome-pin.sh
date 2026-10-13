# shellcheck shell=bash
# google-chrome-pin.sh -- the ONE Google Chrome deb an image may carry.
#
# Chrome used to be fetched live from Google ("whatever is current stable") by
# both build/build-vendor-mirror.sh and build/build-desktop-mirror.sh, while
# manifests/vendor-debs.tsv pins one exact version + sha256. Every Google stable
# release therefore broke the provenance gate of every branch until someone
# re-pinned by hand (155.0.8059.39-1 -> .79-1 on 2026-10-13). The deb is now a
# staged build input like the Vivaldi debs: assets/google-chrome/, pinned in
# manifests/build-inputs.tsv, fetched from the store by build/stage-build-inputs.sh
# and refreshed deliberately with build/refresh-google-chrome.sh (which verifies
# Google's signed InRelease -> Packages -> deb chain).
#
# ncz_chrome_staged_deb <root> <arch>: print the staged deb that matches the
# vendor-debs.tsv pin for <arch> (exact version and sha256), or fail with a
# message saying how to stage/refresh it.
ncz_chrome_staged_deb() {
    local root="$1" arch="$2" row ver sha deb got gotv
    row="$(awk -F'\t' -v a="$arch" '$1=="google-chrome-stable" && $3==a {print $2"\t"$6; exit}' "$root/manifests/vendor-debs.tsv")"
    [ -n "$row" ] || { echo "ERROR: no google-chrome-stable/$arch row in manifests/vendor-debs.tsv" >&2; return 1; }
    ver="${row%%$'\t'*}"; sha="${row#*$'\t'}"
    deb="$root/assets/google-chrome/google-chrome-stable_${ver}_${arch}.deb"
    if [ ! -f "$deb" ]; then
        echo "ERROR: $deb is not staged (build/stage-build-inputs.sh --arch $arch; to move to a newer Chrome: build/refresh-google-chrome.sh)" >&2
        return 1
    fi
    got="$(sha256sum "$deb" | awk '{print $1}')"
    gotv="$(dpkg-deb -f "$deb" Version 2>/dev/null || true)"
    if [ "$got" != "$sha" ] || [ "$gotv" != "$ver" ]; then
        echo "ERROR: $deb is $gotv/$got; manifests/vendor-debs.tsv pins $ver/$sha" >&2
        return 1
    fi
    printf '%s\n' "$deb"
}
