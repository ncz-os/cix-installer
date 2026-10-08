#!/bin/bash
# stage-build-inputs.sh -- stage the gitignored, non-reproducible build inputs
# from ONE documented ARGONAS location, checksum-pinned in git.
#
# WHY (r201). Several image inputs are not in git and not rebuilt by a clean
# checkout: the rescue rootfs, the relocatable CPython 3.11 + uv, the Artist
# Pack wallpaper debs and the recovery-container rootfs. r201 copied them from
# PROTEUS's r200 tree by hand; the recovery rootfs was never produced anywhere,
# so post-install/38-recovery-container.sh failed on every image
# ("assets/mgmt/ncz-mgmt-rootfs.tar.zst missing").
#
# CANONICAL LOCATION (ARGONAS, spelled per host):
#   /mnt/datapool/projects/ncz-os-assets/build-inputs/<arch>/<repo-relative dest>
#   HYDRA/ACHILLES/PROTEUS: /mnt/argonas/datapool/projects/ncz-os-assets/build-inputs
#   ULTRA:                  /mnt/argonas-projects/ncz-os-assets/build-inputs
# Override with NCZ_BUILD_INPUTS_DIR. The pins (sha256, size) live in
# manifests/build-inputs.tsv; a file whose checksum differs is refused.
#
# USAGE
#   build/stage-build-inputs.sh --arch amd64|arm64           # fetch + verify (default)
#   build/stage-build-inputs.sh --arch arm64 --check         # verify only, copy nothing
#   build/stage-build-inputs.sh --arch arm64 --only assets/python311   # subset by dest prefix
#   build/stage-build-inputs.sh --arch arm64 --replace-local # overwrite a LOCAL file whose sha256 differs from the
#                                                            # pin (default: refuse; a locally rebuilt input is never clobbered)
#   build/stage-build-inputs.sh --arch amd64 --publish       # copy from this tree to ARGONAS
#                                                            # and rewrite the pins
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
        --only) ONLY="${2:?--only needs a dest prefix}"; shift ;;
        -h|--help) sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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
for d in "${NCZ_BUILD_INPUTS_DIR:-}" \
         /mnt/argonas/datapool/projects/ncz-os-assets/build-inputs \
         /mnt/datapool/projects/ncz-os-assets/build-inputs \
         /mnt/argonas-projects/ncz-os-assets/build-inputs \
         /mnt/argonas/projects/ncz-os-assets/build-inputs; do
    [ -n "$d" ] || continue
    if [ -d "$d" ] || { [ "$MODE" = publish ] && [ -d "$(dirname "$d")" ]; }; then STORE="$d"; break; fi
done
# A missing store is only an error when an input actually has to be fetched or published, so a
# build host without the NFS mount can still build from an already-staged tree.
if [ -z "$STORE" ] && [ "$MODE" = publish ]; then
    echo "stage-build-inputs: FAIL: no ARGONAS build-inputs store mounted (set NCZ_BUILD_INPUTS_DIR)" >&2
    exit 1
fi
echo "[build-inputs] arch=$ARCH mode=$MODE store=${STORE:-<none mounted>}"

sha_of() { sha256sum "$1" | awk '{print $1}'; }
FAIL=0; N=0; N_OK=0; N_COPIED=0
miss() { echo "[build-inputs] MISSING/BAD: $1" >&2; FAIL=1; }

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
        if [ -f "$local_f" ] && [ "$REPLACE_LOCAL" != 1 ]; then
            miss "$dest exists locally with sha256 $(sha_of "$local_f") != pin $sha: refusing to overwrite (a rebuilt or modified input); publish it, remove it, or pass --replace-local"
            continue
        fi
        if [ -z "$STORE" ]; then miss "$dest not staged and no ARGONAS build-inputs store is mounted (set NCZ_BUILD_INPUTS_DIR)"; continue; fi
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
if [ "$FAIL" != 0 ]; then echo "[build-inputs] FAIL ($ARCH): see MISSING/BAD lines above" >&2; exit 1; fi
echo "[build-inputs] OK ($ARCH): $N inputs, $N_OK already staged, $N_COPIED copied"
