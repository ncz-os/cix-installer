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
# and refreshed deliberately with build/refresh-google-chrome.sh, which resolves the
# google-chrome-stable alias through Google's signed InRelease -> Packages -> deb
# chain (build/refresh-vendor-debs.sh; alias for discovery, store for reproducibility).
#
# ncz_chrome_staged_deb <root> <arch>: print the staged deb that matches the
# vendor-debs.tsv pin for <arch> (exact version and sha256), or fail with a
# message saying how to stage/refresh it.
# shellcheck source=build/lib/vendor-deb-pin.sh
. "$(dirname "${BASH_SOURCE[0]}")/vendor-deb-pin.sh"
ncz_chrome_staged_deb() {
    ncz_vendor_staged_deb "$1" google-chrome-stable "$2" assets/google-chrome
}
