#!/bin/bash
# stage-build-inputs.sh -- stage the gitignored, non-reproducible build inputs
# from ONE configured artifact store, checksum-pinned in git.
#
# WHY (r201). Several image inputs are not in git and not rebuilt by a clean
# checkout: the rescue rootfs, the relocatable CPython 3.11 + uv, the Artist
# Pack wallpaper debs and the recovery-container rootfs. r201 copied them from
# PROTEUS's r200 tree by hand; the recovery rootfs was never produced anywhere,
# so post-install/38-recovery-container.sh failed on every image
# ("assets/mgmt/ncz-mgmt-rootfs.tar.zst missing").
#
# STORE LOCATION: <store>/<arch>/<repo-relative dest>. The store is the
# directory named by NCZ_BUILD_INPUTS_DIR or, when that is unset, by the first
# line of "${XDG_CONFIG_HOME:-$HOME/.config}/ncz/build-inputs-dir" (one file per
# build host, so the mount spelling stays out of git). The pins (sha256, size)
# live in manifests/build-inputs.tsv; a file whose checksum differs is refused.
#
# PUBLIC INPUTS (--public). The inputs that also exist at a public URL are
# listed in manifests/build-inputs-public.tsv (same sha256 as the pin, plus the
# URL and, for an archive, the member to extract). --public fetches those over
# the network without any store and reports every other input as internal-only.
#
# USAGE
#   build/stage-build-inputs.sh --arch amd64|arm64           # fetch + verify (default)
#   build/stage-build-inputs.sh --arch arm64 --check         # verify only, copy nothing
#   build/stage-build-inputs.sh --arch arm64 --only assets/python311   # subset by dest prefix
#   build/stage-build-inputs.sh --arch arm64 --replace-local # overwrite a LOCAL file whose sha256 differs from the
#                                                            # pin (default: refuse; a locally rebuilt input is never clobbered)
#   build/stage-build-inputs.sh --arch amd64 --publish       # copy from this tree to the store
#                                                            # and rewrite the pins
#   build/stage-build-inputs.sh --arch amd64 --public        # fetch the publicly available inputs
#                                                            # (manifests/build-inputs-public.tsv), no store
# Producing the mgmt rootfs (needs root + debootstrap; any container works):
#   build/build-mgmt-rootfs.sh <chroot> assets/mgmt/ncz-mgmt-rootfs.tar.zst forky <arch>
#   then --publish. It is NOT byte-reproducible (debootstrap/apt timestamps), which is
#   exactly why it is pinned by checksum here instead of rebuilt per image.
#
# Exit: 0 all staged/verified, 1 anything missing or mismatched (every miss printed).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TSV="${NCZ_BUILD_INPUTS_TSV:-$ROOT/manifests/build-inputs.tsv}"
TREE="${NCZ_BUILD_INPUTS_TREE:-$ROOT}"
ARCH="" ; MODE=fetch ; ONLY="" ; REPLACE_LOCAL=0

while [ $# -gt 0 ]; do
    case "$1" in
        --arch) ARCH="${2:?--arch needs a value}"; shift ;;
        --check) MODE=check ;;
        --publish) MODE=publish ;;
        --replace-local) REPLACE_LOCAL=1 ;;
        --public) MODE=public ;;
        --only) ONLY="${2:?--only needs a dest prefix}"; shift ;;
        -h|--help) sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "stage-build-inputs: unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done
case "$ARCH" in
    amd64|arm64) ;;
    "") ARCH="${NCZ_TARGET_ARCH:-}"
        [ -n "$ARCH" ] || { echo "stage-build-inputs: --arch amd64|arm64 required" >&2; exit 2; } ;;
    *) echo "stage-build-inputs: bad --arch $ARCH" >&2; exit 2 ;;
esac
[ -f "$TSV" ] || { echo "stage-build-inputs: $TSV not found" >&2; exit 1; }

STORE=""
SITE_CONF="${XDG_CONFIG_HOME:-$HOME/.config}/ncz/build-inputs-dir"
SITE_DIR=""
[ -r "$SITE_CONF" ] && SITE_DIR="$(head -n1 "$SITE_CONF" | tr -d '[:space:]')"
[ "$MODE" = public ] && SITE_DIR="" && NCZ_BUILD_INPUTS_DIR=""   # --public never reads a store
for d in "${NCZ_BUILD_INPUTS_DIR:-}" "$SITE_DIR"; do
    [ -n "$d" ] || continue
    if [ -d "$d" ] || { [ "$MODE" = publish ] && [ -d "$(dirname "$d")" ]; }; then STORE="$d"; break; fi
done
# A missing store is only an error when an input actually has to be fetched or published, so a
# build host without the NFS mount can still build from an already-staged tree.
if [ -z "$STORE" ] && [ "$MODE" = publish ]; then
    echo "stage-build-inputs: FAIL: no build-inputs store configured (set NCZ_BUILD_INPUTS_DIR or $SITE_CONF)" >&2
    exit 1
fi
echo "[build-inputs] arch=$ARCH mode=$MODE store=${STORE:-<none mounted>}"

sha_of() { sha256sum "$1" | awk '{print $1}'; }
FAIL=0; N=0; N_OK=0; N_COPIED=0
miss() { echo "[build-inputs] MISSING/BAD: $1" >&2; FAIL=1; }

# --public: dest -> "sha256<TAB>url<TAB>member" from the public-source list.
PUB_TSV="${NCZ_BUILD_INPUTS_PUBLIC_TSV:-$(dirname "$TSV")/build-inputs-public.tsv}"
N_INTERNAL=0
pub_row() {  # pub_row <arch> <dest> -> prints "sha url member" or nothing
    [ -f "$PUB_TSV" ] || return 0
    awk -F'\t' -v a="$1" -v d="$2" '!/^[[:space:]]*(#|$)/ && $1==a && $2==d {print $3"\t"$4"\t"$5; exit}' "$PUB_TSV"
}
fetch_public() {  # fetch_public <url> <member|-> <out>: download (and extract) into <out>
    local url=$1 member=$2 out=$3 w
    command -v curl >/dev/null 2>&1 || { echo "curl is required for --public" >&2; return 1; }
    w="$(mktemp -d "${TMPDIR:-/var/tmp}/bi-pub.XXXXXX")" || return 1
    if ! curl -fsSL --retry 3 -o "$w/dl" "$url"; then rm -rf "$w"; return 1; fi
    if [ -n "$member" ] && [ "$member" != - ]; then
        tar -C "$w" -xf "$w/dl" "$member" 2>/dev/null && [ -f "$w/$member" ] || { rm -rf "$w"; return 1; }
        mv -f "$w/$member" "$out"
    else
        mv -f "$w/dl" "$out"
    fi
    rm -rf "$w"
}

if [ "$MODE" = publish ]; then
    NEW="$(mktemp "${TMPDIR:-/var/tmp}/build-inputs.XXXXXX")"
    trap 'rm -f "$NEW"' EXIT
fi

while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
        ''|'#'*) [ "$MODE" = publish ] && printf '%s\n' "$line" >> "$NEW"; continue ;;
    esac
    IFS=$'\t' read -r a dest sha size note <<<"$line"
    if [ "$a" != "$ARCH" ]; then [ "$MODE" = publish ] && printf '%s\n' "$line" >> "$NEW"; continue; fi
    if [ -n "$ONLY" ]; then case "$dest" in "$ONLY"*) ;; *) [ "$MODE" = publish ] && printf '%s\n' "$line" >> "$NEW"; continue ;; esac; fi
    N=$((N + 1))
    local_f="$TREE/$dest"; store_f="$STORE/$ARCH/$dest"
    case "$MODE" in
    publish)
        if [ ! -f "$local_f" ]; then miss "$dest not in this tree ($local_f)"; printf '%s\t%s\t%s\t%s\t%s\n' "$a" "$dest" "$sha" "$size" "$note" >> "$NEW"; continue; fi
        nsha="$(sha_of "$local_f")"; nsize="$(stat -c %s "$local_f")"
        mkdir -p "$(dirname "$store_f")"
        cp -f "$local_f" "$store_f.part" && mv -f "$store_f.part" "$store_f"
        [ "$(sha_of "$store_f")" = "$nsha" ] || { miss "$dest changed on the way to $store_f"; }
        printf '%s\t%s\t%s\t%s\t%s\n' "$a" "$dest" "$nsha" "$nsize" "$note" >> "$NEW"
        echo "[build-inputs] published $dest sha256=$nsha ($nsize B)"; N_COPIED=$((N_COPIED + 1)) ;;
    *)
        if [ -f "$local_f" ] && [ "$(sha_of "$local_f")" = "$sha" ]; then N_OK=$((N_OK + 1)); continue; fi
        if [ "$MODE" = check ]; then
            if [ -f "$local_f" ]; then miss "$dest sha256 differs from the pin ($sha)"; else miss "$dest not staged (run build/stage-build-inputs.sh --arch $ARCH)"; fi
            continue
        fi
        if [ "$MODE" = public ]; then
            if [ -f "$local_f" ] && [ "$REPLACE_LOCAL" != 1 ]; then
                miss "$dest exists locally with sha256 $(sha_of "$local_f") != pin $sha: refusing to overwrite; remove it or pass --replace-local"
                continue
            fi
            pr="$(pub_row "$a" "$dest")"
            if [ -z "$pr" ]; then
                echo "[build-inputs] INTERNAL-ONLY: $dest has no public source (manifests/build-inputs-public.tsv): $note" >&2
                N_INTERNAL=$((N_INTERNAL + 1)); FAIL=1; continue
            fi
            IFS=$'\t' read -r psha purl pmember <<<"$pr"
            if [ "$psha" != "$sha" ]; then miss "$dest: public-source sha256 $psha does not match the pin $sha (stale build-inputs-public.tsv row)"; continue; fi
            mkdir -p "$(dirname "$local_f")"
            if ! fetch_public "$purl" "${pmember:--}" "$local_f.part"; then rm -f "$local_f.part"; miss "$dest: download/extract failed from $purl"; continue; fi
            if [ "$(sha_of "$local_f.part")" != "$sha" ]; then miss "$dest from $purl has sha256 $(sha_of "$local_f.part") != pin $sha: refusing"; rm -f "$local_f.part"; continue; fi
            mv -f "$local_f.part" "$local_f"
            [ "$dest" = assets/python311/uv ] && chmod 0755 "$local_f"
            echo "[build-inputs] fetched $dest from its public source ($size B, sha256 verified)"; N_COPIED=$((N_COPIED + 1))
            continue
        fi
        if [ -f "$local_f" ] && [ "$REPLACE_LOCAL" != 1 ]; then
            miss "$dest exists locally with sha256 $(sha_of "$local_f") != pin $sha: refusing to overwrite (a rebuilt or modified input); publish it, remove it, or pass --replace-local"
            continue
        fi
        if [ -z "$STORE" ]; then miss "$dest not staged and no build-inputs store is configured (set NCZ_BUILD_INPUTS_DIR or $SITE_CONF; or use --public for the inputs that have a public source)"; continue; fi
        if [ ! -f "$store_f" ]; then miss "$dest not in the store ($store_f): $note"; continue; fi
        if [ "$(sha_of "$store_f")" != "$sha" ]; then miss "$dest in the store has the wrong sha256 (pin $sha): refusing"; continue; fi
        [ -f "$local_f" ] && echo "[build-inputs] replacing $dest (local sha256 $(sha_of "$local_f") != pin $sha) as requested"
        mkdir -p "$(dirname "$local_f")"
        cp -f "$store_f" "$local_f.part" && mv -f "$local_f.part" "$local_f"
        [ "$dest" = assets/python311/uv ] && chmod 0755 "$local_f"
        echo "[build-inputs] staged $dest ($size B)"; N_COPIED=$((N_COPIED + 1)) ;;
    esac
done < "$TSV"

if [ "$MODE" = publish ] && [ "$FAIL" = 0 ]; then
    cp -f "$NEW" "$TSV"
    echo "[build-inputs] pins rewritten in $TSV; commit it"
fi
if [ "$N" = 0 ]; then echo "[build-inputs] FAIL: no rows for arch=$ARCH${ONLY:+ prefix=$ONLY} in $TSV" >&2; exit 1; fi
if [ "$FAIL" != 0 ]; then
    [ "$N_INTERNAL" -gt 0 ] && echo "[build-inputs] $N_INTERNAL input(s) are internal-only and cannot be fetched publicly (see INTERNAL-ONLY lines)" >&2
    echo "[build-inputs] FAIL ($ARCH): see MISSING/BAD lines above" >&2; exit 1
fi
echo "[build-inputs] OK ($ARCH): $N inputs, $N_OK already staged, $N_COPIED copied"
