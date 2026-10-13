#!/bin/bash
# stage-singularity-payload.sh -- materialize the pinned Singularity desktop
# payload deb into assets/cix-debs/, sha256-verified against
# manifests/singularity-payload.tsv.
#
# WHY. `build/build-image.sh --sources pinned` reproduces the committed payload
# pin. assets/cix-debs/ is git-ignored, so on a fresh clone it holds no payload
# deb, and the refresh-sources stage then rebuilt the payload from source. That
# rebuild carries a new build timestamp in its version, so it can never be the
# pinned bytes. This script stages exactly the pinned file instead and fails
# closed when it cannot.
#
# Sources, in order (the first that yields the pinned sha256 wins):
#   1. assets/cix-debs/<file> already present with the pinned sha256;
#   2. NCZ_SINGULARITY_PAYLOAD_DIR/<file> (optional local directory);
#   3. the NCZ apt repository: NCZ_APT_BASE (default
#      https://packages.buildkite.com/ncz-os/ncz/any). The index row for <file>
#      must carry the pinned SHA256 before anything is downloaded, and the
#      downloaded bytes are checked again.
#
# USAGE
#   build/stage-singularity-payload.sh --arch amd64|arm64            # stage
#   build/stage-singularity-payload.sh --arch amd64 --check          # verify only
#   build/stage-singularity-payload.sh --arch amd64 --offline        # no network
#   build/stage-singularity-payload.sh --arch amd64 --print-path     # pinned dest path
# Exit: 0 staged/verified; 1 missing or mismatched (fails closed); 2 usage.
set -uo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"

ARCH=""; MODE=stage; OFFLINE="${NCZ_OFFLINE:-0}"
while [ $# -gt 0 ]; do
    case "$1" in
        --arch) ARCH="${2:-}"; shift 2 ;;
        --check) MODE=check; shift ;;
        --offline) OFFLINE=1; shift ;;
        --print-path) MODE=print; shift ;;
        -h|--help) sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "stage-singularity-payload: unknown argument: $1" >&2; exit 2 ;;
    esac
done
case "$ARCH" in
    amd64|arm64) ;;
    *) echo "usage: $0 --arch amd64|arm64 [--check|--offline|--print-path]" >&2; exit 2 ;;
esac

PIN="${NCZ_SINGULARITY_PAYLOAD_PIN:-$ROOT/manifests/singularity-payload.tsv}"
DEST_DIR="$ROOT/assets/cix-debs"
say() { echo "[payload] $*"; }
die() { echo "stage-singularity-payload: FAIL: $*" >&2; exit 1; }

[ -f "$PIN" ] || die "missing $PIN"
row="$(awk -F'\t' -v a="$ARCH" '!/^#/ && $1==a {print; exit}' "$PIN")"
[ -n "$row" ] || die "no '$ARCH' row in $PIN"
want="$(printf '%s' "$row" | cut -f2)"
file="$(printf '%s' "$row" | cut -f3)"
case "$want" in
    [0-9a-f][0-9a-f]*) [ "${#want}" = 64 ] || die "malformed sha256 '$want' in $PIN" ;;
    *) die "malformed sha256 '$want' in $PIN" ;;
esac
case "$file" in
    ncz-singularity-desktop_*_"$ARCH".deb) ;;
    *) die "pinned file name '$file' is not an ncz-singularity-desktop $ARCH deb" ;;
esac
dest="$DEST_DIR/$file"
if [ "$MODE" = print ]; then printf '%s\n' "$dest"; exit 0; fi

sha_of() { sha256sum "$1" | awk '{print $1}'; }

if [ -f "$dest" ]; then
    got="$(sha_of "$dest")"
    [ "$got" = "$want" ] || die "$dest has sha256 $got, pin is $want (remove it to restage)"
    say "pinned payload present: $file ($want)"
    exit 0
fi
[ "$MODE" = check ] && die "pinned payload not staged: $dest"

mkdir -p "$DEST_DIR"
WORK="$(mktemp -d "${TMPDIR:-$ROOT/build}/ncz-payload.XXXXXX")" || die "mktemp failed"
trap 'rm -rf "$WORK"' EXIT

install_verified() { # $1 candidate file, $2 origin label
    local got; got="$(sha_of "$1")"
    if [ "$got" != "$want" ]; then
        echo "[payload] $2: sha256 $got != pin $want; not used" >&2
        return 1
    fi
    install -m 0644 "$1" "$dest.partial" && mv -f "$dest.partial" "$dest" || return 1
    say "staged $file from $2 (sha256 $want)"
    return 0
}

if [ -n "${NCZ_SINGULARITY_PAYLOAD_DIR:-}" ] && [ -f "$NCZ_SINGULARITY_PAYLOAD_DIR/$file" ]; then
    install_verified "$NCZ_SINGULARITY_PAYLOAD_DIR/$file" "$NCZ_SINGULARITY_PAYLOAD_DIR" && exit 0
fi

[ "$OFFLINE" = 1 ] && die "--offline and $file is not staged (set NCZ_SINGULARITY_PAYLOAD_DIR to a directory holding it)"

base="${NCZ_APT_BASE:-https://packages.buildkite.com/ncz-os/ncz/any}"
base="${base%/}"
idx="$WORK/Packages"
curl -fsSL --retry 3 "$base/dists/any/main/binary-$ARCH/Packages" -o "$idx" \
    || die "cannot fetch the package index $base/dists/any/main/binary-$ARCH/Packages"
read -r rel isha < <(python3 -I - "$idx" "$file" <<'PYEOF'
import sys
idx, name = sys.argv[1], sys.argv[2]
with open(idx, encoding="utf-8", errors="replace") as fh:
    stanzas = fh.read().split("\n\n")
for st in stanzas:
    fields = {}
    for line in st.splitlines():
        if line[:1] in (" ", "\t") or ": " not in line:
            continue
        k, v = line.split(": ", 1)
        fields[k] = v.strip()
    fn = fields.get("Filename", "")
    if fn.rsplit("/", 1)[-1] == name:
        print(fn, fields.get("SHA256", "-"))
        sys.exit(0)
print("- -")
PYEOF
)
[ -n "${rel:-}" ] && [ "$rel" != - ] || die "$file is not in the package index at $base (publish it first)"
[ "$isha" = "$want" ] || die "the package index lists $file with sha256 $isha, pin is $want"
curl -fsSL --retry 3 "$base/$rel" -o "$WORK/$file" || die "download of $base/$rel failed"
install_verified "$WORK/$file" "$base" || die "downloaded $file does not match the pin"
exit 0
