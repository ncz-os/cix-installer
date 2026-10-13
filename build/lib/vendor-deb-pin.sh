# shellcheck shell=bash
# vendor-deb-pin.sh -- the ONE staged deb an image may carry for a vendor alias.
#
# Alias for discovery, store for reproducibility: build/refresh-vendor-debs.sh resolves an
# alias (manifests/vendor-aliases.tsv) through the vendor's signed index and records the
# result in manifests/vendor-debs.tsv; builders take only the staged file that matches that
# record (exact version and sha256), never a live download.
#
# ncz_vendor_staged_deb <root> <package> <arch> <store_dir>: print the staged deb for
# <package>/<arch> under <root>/<store_dir>/ that matches the vendor-debs.tsv row, or fail
# with a message saying how to stage or refresh it.
ncz_vendor_staged_deb() {
    local root="$1" pkg="$2" arch="$3" dir="$4" row ver sha deb got gotv
    row="$(awk -F'\t' -v p="$pkg" -v a="$arch" '$1==p && $3==a {print $2"\t"$6; exit}' "$root/manifests/vendor-debs.tsv")"
    [ -n "$row" ] || { echo "ERROR: no $pkg/$arch row in manifests/vendor-debs.tsv" >&2; return 1; }
    ver="${row%%$'\t'*}"; sha="${row#*$'\t'}"
    deb="$root/$dir/${pkg}_${ver}_${arch}.deb"
    if [ ! -f "$deb" ]; then
        echo "ERROR: $deb is not staged (build/stage-build-inputs.sh --arch $arch; to move to the alias' newest version: build/refresh-vendor-debs.sh $pkg)" >&2
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
