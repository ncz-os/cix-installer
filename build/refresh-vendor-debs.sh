#!/bin/bash
# refresh-vendor-debs.sh -- move the vendor browser debs to the newest version of their alias.
#
# Alias for discovery, store for reproducibility. Each package in
# manifests/vendor-aliases.tsv (google-chrome-stable, vivaldi-stable) is resolved through the
# vendor's signed apt index: index signature by the pinned key -> Packages sha256 -> deb
# sha256 -> deb control fields (build/lib/vendor_alias.py). The resolved deb is staged under
# assets/<dir>/, its version/URL/sha256 recorded in manifests/vendor-debs.tsv,
# manifests/build-inputs.tsv and sbom/expected-assets.txt, published to the build-inputs store
# (build/stage-build-inputs.sh --publish) and manifests/determinism.pin is regenerated. Image
# builds only ever consume the staged, pinned store file, never the alias.
#
# One command, idempotent: with nothing new upstream it downloads nothing (the pinned deb is
# already staged) and leaves every ledger byte-identical.
#
# Usage: build/refresh-vendor-debs.sh [--check | --no-publish] [package...]
#   --check       resolve only; exit 10 when a pin is behind its alias, 0 when current
#   --no-publish  stage and rewrite the ledgers, but do not publish to the store
#   package       default: every package in manifests/vendor-aliases.tsv
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE=refresh PUBLISH=1 PKGS=()
for a in "$@"; do
    case "$a" in
        --check) MODE=check ;;
        --no-publish) PUBLISH=0 ;;
        -h|--help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) echo "refresh-vendor-debs: unknown option $a" >&2; exit 2 ;;
        *) PKGS+=("$a") ;;
    esac
done
for t in python3 gpg gpgv dpkg dpkg-deb sha256sum; do
    command -v "$t" >/dev/null || { echo "ERROR: missing $t" >&2; exit 1; }
done
if [ "${#PKGS[@]}" -eq 0 ]; then
    while IFS=$'\t' read -r p _; do
        case "$p" in ''|'#'*) continue ;; esac
        PKGS+=("$p")
    done < "$ROOT/manifests/vendor-aliases.tsv"
fi
rc=0
python3 -I "$ROOT/build/lib/vendor_alias.py" "$MODE" "$ROOT" "${PKGS[@]}" || rc=$?
[ "$MODE" = check ] && exit "$rc"
[ "$rc" -eq 0 ] || exit "$rc"
if [ "$PUBLISH" = 1 ]; then
    for p in "${PKGS[@]}"; do
        row="$(awk -F'\t' -v p="$p" '$1==p {print $8"\t"$9; exit}' "$ROOT/manifests/vendor-aliases.tsv")"
        dir="${row%%$'\t'*}"; arches="${row#*$'\t'}"
        for a in ${arches//,/ }; do
            bash "$ROOT/build/stage-build-inputs.sh" --arch "$a" --publish --only "$dir/"
        done
    done
fi
bash "$ROOT/build/gen-base-pin.sh"
echo "done: commit manifests/vendor-debs.tsv manifests/build-inputs.tsv sbom/expected-assets.txt manifests/determinism.pin if they changed"
