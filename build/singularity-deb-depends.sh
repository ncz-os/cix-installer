#!/bin/bash
# singularity-deb-depends.sh -- derive the Depends: of ncz-singularity-desktop
# from the real /opt/singularity payload, every build.
#
# Why: the package used to carry a hand-kept 18-entry Depends: that silently
# omitted libraries the payload links (libseat1, libinput10, libliftoff0,
# libxcb-errors0, libdisplay-info3, libpipewire-0.3-0t64, libpam0g, ...). The
# published 20261005+...+deps1 package fixed that by hand once, but the head
# build in stage 1 (build-squashfs-layers.sh build_singularity_payload) kept
# producing the short list. This script makes the list a function of the
# payload that is actually being packaged, so it cannot rot.
#
# Method (direct mode; Debian userland with dpkg-dev and binutils, and the
# libraries the payload links already installed -- true inside the
# build-singularity.sh container, which built the payload against them):
#   1. enumerate every ELF in the payload; collect DT_NEEDED and DT_SONAME
#   2. external sonames = needed - provided by the payload itself
#   3. owner of each external soname = dpkg -S on the native multiarch path;
#      an external soname no installed package owns is a hard error
#   4. dpkg-shlibdeps over all payload ELFs (payload lib dirs on -l) gives the
#      Debian-standard, versioned dependency set from shlibs/symbols files
#   5. Depends = (4) + any owner from (3) that (4) did not cover (warned)
#      + the explicit runtime packages in build/singularity-runtime-extra-deps.txt
#
# Container mode (--container) runs the same thing in debian:<codename> for
# the target architecture (qemu-user via binfmt for a foreign arch). It first
# installs the owning packages, found with apt-file, so it works on a bare
# payload tarball that was built elsewhere. build-singularity-deb.sh uses it
# when no matching sidecar from build-singularity.sh is present.
#
# Output (-o FILE, default stdout) is a small key: value file:
#   X-Payload-SHA256: <sha256 of the payload tgz, or '-' for a directory>
#   X-Architecture:   <dpkg architecture the payload was analysed as>
#   X-Suite:          <Debian codename of the analysing userland>
#   Depends:          <comma-separated Depends>
#   X-Soname:         <soname> <package>      (one per external soname)
#   X-Runtime:        <package>               (one per explicit runtime dep)
#
# Usage:
#   singularity-deb-depends.sh [--direct] [--payload-sha256 SHA] [-o FILE] <payload-dir|payload.tgz>
#   singularity-deb-depends.sh --container --arch ARCH [--codename C] [-o FILE] <payload.tgz|payload-dir>
set -euo pipefail

die() { echo "ERROR: singularity-deb-depends: $*" >&2; exit 1; }
log() { echo "[deps] $*" >&2; }

SELF="$(readlink -f "$0")"
BUILD_DIR="$(dirname "$SELF")"
EXTRA_FILE="${NCZ_SINGULARITY_EXTRA_DEPS_FILE:-$BUILD_DIR/singularity-runtime-extra-deps.txt}"

MODE=direct
ARCH=""
CODENAME=""
OUTFILE=""
PAYLOAD_SHA=""
INPUT=""
while [ $# -gt 0 ]; do
    case "$1" in
        --direct) MODE=direct ;;
        --container) MODE=container ;;
        --list-external) MODE=list-external ;;
        --container-inner) MODE=container-inner ;;
        --arch) ARCH="${2:?--arch needs a value}"; shift ;;
        --codename) CODENAME="${2:?--codename needs a value}"; shift ;;
        --payload-sha256) PAYLOAD_SHA="${2:?--payload-sha256 needs a value}"; shift ;;
        -o) OUTFILE="${2:?-o needs a value}"; shift ;;
        -h|--help) sed -n '2,45p' "$SELF"; exit 0 ;;
        -*) die "unknown option: $1" ;;
        *) [ -z "$INPUT" ] || die "only one payload argument is accepted"; INPUT="$1" ;;
    esac
    shift
done
[ -n "$INPUT" ] || die "usage: $(basename "$0") [--direct|--container --arch ARCH] [-o FILE] <payload-dir|payload.tgz>"
[ -e "$INPUT" ] || die "payload not found: $INPUT"
[ -f "$EXTRA_FILE" ] || die "runtime extra deps file missing: $EXTRA_FILE"

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/sing-deps.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT

# ---------------------------------------------------------------------------
# container mode: re-exec this script inside debian:<codename> for ARCH
# ---------------------------------------------------------------------------
if [ "$MODE" = container ]; then
    [ -n "$ARCH" ] || die "--container needs --arch (the payload's dpkg architecture)"
    if [ -z "$CODENAME" ] && [ -r "$BUILD_DIR/../release.conf" ]; then
        # shellcheck source=../release.conf
        CODENAME="$(. "$BUILD_DIR/../release.conf" >/dev/null 2>&1; printf '%s' "${NCZ_BASE_CODENAME:-}")"
    fi
    CODENAME="${CODENAME:-forky}"
    case "$ARCH" in
        amd64) PLATFORM=linux/amd64 ;;
        arm64) PLATFORM=linux/arm64 ;;
        *) die "unsupported --arch $ARCH (amd64|arm64)" ;;
    esac
    CE="$(command -v docker || command -v podman || true)"
    [ -n "$CE" ] || die "--container needs docker or podman"
    if [ -f "$INPUT" ]; then
        [ -n "$PAYLOAD_SHA" ] || PAYLOAD_SHA="$(sha256sum "$INPUT" | cut -d' ' -f1)"
        mkdir -p "$STAGE/payload"
        tar -C "$STAGE/payload" -xzf "$INPUT"
        PAYLOAD_DIR="$STAGE/payload"
    else
        PAYLOAD_DIR="$(readlink -f "$INPUT")"
    fi
    mkdir -p "$STAGE/out"
    CE_ARGS=(--rm --network="${SINGULARITY_CONTAINER_NETWORK:-host}" --platform "$PLATFORM"
             -v "$BUILD_DIR":/ncz-build:ro -v "$PAYLOAD_DIR":/payload:ro -v "$STAGE/out":/out
             -e NCZ_SINGULARITY_EXTRA_DEPS_FILE="/ncz-build/$(basename "$EXTRA_FILE")")
    if "$CE" --version 2>/dev/null | grep -qi podman; then
        CE_ARGS+=(--security-opt label=disable)
    fi
    [ "$(dirname "$(readlink -f "$EXTRA_FILE")")" = "$BUILD_DIR" ] || \
        die "--container needs the extra deps file inside $BUILD_DIR"
    log "container: debian:$CODENAME $PLATFORM via $(basename "$CE")"
    "$CE" run "${CE_ARGS[@]}" "debian:$CODENAME" \
        bash /ncz-build/singularity-deb-depends.sh --container-inner \
        --payload-sha256 "${PAYLOAD_SHA:--}" -o /out/depends /payload
    [ -s "$STAGE/out/depends" ] || die "container run produced no depends file"
    if [ -n "$OUTFILE" ]; then
        cp "$STAGE/out/depends" "$OUTFILE"
    else
        cat "$STAGE/out/depends"
    fi
    exit 0
fi

# ---------------------------------------------------------------------------
# container-inner: (inside a disposable debian container only) install the
# analysis tools now; the owning library packages are installed once the
# external sonames are known, below.
# ---------------------------------------------------------------------------
INNER=0
if [ "$MODE" = container-inner ]; then
    [ -f /.dockerenv ] || [ -f /run/.containerenv ] || \
        die "--container-inner installs packages; it only runs inside a disposable container"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends apt-file dpkg-dev binutils ca-certificates >/dev/null
    apt-file update >/dev/null
    INNER=1
    MODE=direct
fi

# ---------------------------------------------------------------------------
# locate the payload root (…/opt/singularity)
# ---------------------------------------------------------------------------
if [ -d "$INPUT" ]; then
    if [ -d "$INPUT/opt/singularity" ]; then
        ROOT="$INPUT/opt/singularity"
    elif [ -d "$INPUT/bin" ]; then
        ROOT="$INPUT"
    else
        die "$INPUT is neither an extracted payload nor an /opt/singularity tree"
    fi
    PAYLOAD_SHA="${PAYLOAD_SHA:--}"
else
    case "$INPUT" in
        *.tgz|*.tar.gz) ;;
        *) die "unrecognised payload type: $INPUT (want a directory or .tgz)" ;;
    esac
    [ -n "$PAYLOAD_SHA" ] || PAYLOAD_SHA="$(sha256sum "$INPUT" | cut -d' ' -f1)"
    mkdir -p "$STAGE/payload"
    tar -C "$STAGE/payload" -xzf "$INPUT"
    ROOT="$STAGE/payload/opt/singularity"
fi
[ -d "$ROOT" ] || die "payload root missing: $ROOT"
command -v readelf >/dev/null 2>&1 || die "readelf (binutils) is required"

# ---------------------------------------------------------------------------
# 1/2. ELF inventory, DT_NEEDED and DT_SONAME
# ---------------------------------------------------------------------------
: > "$STAGE/elfs"
while IFS= read -r -d '' f; do
    if [ "$(od -An -tx1 -N4 "$f" 2>/dev/null | tr -d ' \n')" = "7f454c46" ]; then
        printf '%s\n' "$f" >> "$STAGE/elfs"
    fi
done < <(find "$ROOT" -type f -print0)
LC_ALL=C sort -o "$STAGE/elfs" "$STAGE/elfs"
[ -s "$STAGE/elfs" ] || die "no ELF files under $ROOT"

: > "$STAGE/needed"; : > "$STAGE/provided"; : > "$STAGE/dynelfs"
while IFS= read -r f; do
    dyn="$(readelf -d "$f" 2>/dev/null || true)"
    [ -n "$dyn" ] || continue
    printf '%s\n' "$f" >> "$STAGE/dynelfs"
    printf '%s\n' "$dyn" | sed -n 's/.*(SONAME).*\[\(.*\)\].*/\1/p' >> "$STAGE/provided"
    printf '%s\n' "$dyn" | sed -n 's/.*(NEEDED).*\[\(.*\)\].*/\1/p' >> "$STAGE/needed"
done < "$STAGE/elfs"
LC_ALL=C sort -u -o "$STAGE/needed" "$STAGE/needed"
LC_ALL=C sort -u -o "$STAGE/provided" "$STAGE/provided"
# A payload library without DT_SONAME is still payload-provided by file name.
while IFS= read -r f; do
    case "$(basename "$f")" in (*.so|*.so.*) basename "$f" ;; esac
done < "$STAGE/dynelfs" >> "$STAGE/provided"
LC_ALL=C sort -u -o "$STAGE/provided" "$STAGE/provided"
LC_ALL=C comm -23 "$STAGE/needed" "$STAGE/provided" > "$STAGE/external"

if [ "$MODE" = list-external ]; then
    cat "$STAGE/external"
    exit 0
fi

log "payload: $INPUT"
log "ELF files: $(wc -l < "$STAGE/elfs") (dynamic: $(wc -l < "$STAGE/dynelfs"))"
log "external sonames: $(wc -l < "$STAGE/external")"

command -v dpkg >/dev/null 2>&1 || die "direct mode needs a Debian userland (dpkg)"
command -v dpkg-shlibdeps >/dev/null 2>&1 || die "direct mode needs dpkg-shlibdeps (dpkg-dev)"
DEB_ARCH="$(dpkg --print-architecture)"
[ -z "$ARCH" ] || [ "$ARCH" = "$DEB_ARCH" ] || \
    die "--arch $ARCH does not match this userland ($DEB_ARCH); use --container"
TRIPLET="$(dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null)"
[ -n "$TRIPLET" ] || die "cannot determine the multiarch triplet"
SUITE="$(. /etc/os-release 2>/dev/null; printf '%s' "${VERSION_CODENAME:-unknown}")"

# container-inner: install the package that ships each external soname at the
# native multiarch path. One apt-file pass for all sonames (qemu-user makes
# each pass expensive). Exact path only: that excludes e.g. apulse, which
# ships a libpulse.so.0 in a private subdirectory.
if [ "$INNER" = 1 ] && [ -s "$STAGE/external" ]; then
    # sonames are [A-Za-z0-9._+-]; only '.' and '+' are regex metacharacters
    grep -qvE '^[A-Za-z0-9._+-]+$' "$STAGE/external" && die "unexpected characters in a soname: $(grep -vE '^[A-Za-z0-9._+-]+$' "$STAGE/external" | head -n1)"
    re_all="$(sed 's/[.+]/\\&/g' "$STAGE/external" | paste -sd'|' -)"
    apt-file search -x "^/(usr/)?lib/${TRIPLET}/(${re_all})\$" > "$STAGE/hits" 2>/dev/null || true
    : > "$STAGE/install"
    while IFS= read -r so; do
        pick="$(awk -F': ' -v so="$so" '{ n = split($2, a, "/"); if (a[n] == so) print $1 }' "$STAGE/hits" \
                | grep -vE '(-dev|-dbg|-dbgsym|-cross|-doc)$' | LC_ALL=C sort -u \
                | awk '{ print ($0 ~ /^lib/ ? 0 : 1), length($0), $0 }' \
                | LC_ALL=C sort -n -k1,1 -k2,2 -k3,3 | head -n1 | cut -d' ' -f3 || true)"
        [ -n "$pick" ] || die "no $DEB_ARCH package in $SUITE ships $so"
        printf '%s\n' "$pick" >> "$STAGE/install"
    done < "$STAGE/external"
    LC_ALL=C sort -u -o "$STAGE/install" "$STAGE/install"
    log "container: installing $(wc -l < "$STAGE/install") owning packages"
    xargs -r apt-get install -y -qq --no-install-recommends < "$STAGE/install" >/dev/null
fi

# ---------------------------------------------------------------------------
# 3. owner of each external soname (native multiarch path, installed packages)
# ---------------------------------------------------------------------------
: > "$STAGE/owners"; missing=0
while IFS= read -r so; do
    [ -n "$so" ] || continue
    owner="$(dpkg -S "/usr/lib/$TRIPLET/$so" "/lib/$TRIPLET/$so" 2>/dev/null \
             | grep -v '^diversion by' | sed 's/: .*//' | tr ',' '\n' \
             | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/:.*//' | sed '/^$/d' \
             | LC_ALL=C sort -u | head -n1 || true)"
    if [ -z "$owner" ]; then
        echo "ERROR: external soname $so is not owned by any installed $DEB_ARCH package" >&2
        missing=$((missing + 1))
        continue
    fi
    printf '%s %s\n' "$so" "$owner" >> "$STAGE/owners"
done < "$STAGE/external"
[ "$missing" -eq 0 ] || die "$missing external soname(s) unresolved; install the owning packages (or use --container)"

# ---------------------------------------------------------------------------
# 4. dpkg-shlibdeps (versioned, from shlibs/symbols)
# ---------------------------------------------------------------------------
mkdir -p "$STAGE/pkg/debian"
cat > "$STAGE/pkg/debian/control" <<'CONTROL'
Source: ncz-singularity-desktop

Package: ncz-singularity-desktop
Architecture: any
CONTROL
LDIRS=()
while IFS= read -r d; do LDIRS+=("-l$d"); done < <(
    while IFS= read -r f; do
        case "$(basename "$f")" in (*.so|*.so.*) dirname "$f" ;; esac
    done < "$STAGE/dynelfs" | LC_ALL=C sort -u)
EARGS=()
while IFS= read -r f; do EARGS+=("-e$f"); done < "$STAGE/dynelfs"
# --ignore-missing-info: the payload's own libraries are not in any package and
# have no shlibs file. A system library hidden by it is caught by the owner
# cross-check below, which is computed independently from dpkg -S.
shl="$(cd "$STAGE/pkg" && dpkg-shlibdeps -O --ignore-missing-info -xncz-singularity-desktop \
        "${LDIRS[@]}" "${EARGS[@]}" 2>"$STAGE/shlibdeps.err")" || {
    cat "$STAGE/shlibdeps.err" >&2
    die "dpkg-shlibdeps failed"
}
grep -v -e 'useless dependency' -e 'binaries to analyze should already be' \
     -e 'no dependency information found for' -e 'were not linked against' \
     -e 'symbol .* used by .* found in none of the libraries' \
     -e 'Note: libraries are not searched in other binary packages' \
     -e 'to help dpkg-shlibdeps find private libraries' "$STAGE/shlibdeps.err" >&2 || true
printf '%s\n' "$shl" | sed -n 's/^shlibs:Depends=//p' | tr ',' '\n' \
    | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | sed '/^$/d' > "$STAGE/shl"

bare() { sed -e 's/[[:space:]]*(.*//' -e 's/[[:space:]]*$//'; }

# ---------------------------------------------------------------------------
# 5. merge: shlibdeps + uncovered owners + explicit runtime packages
# ---------------------------------------------------------------------------
cp "$STAGE/shl" "$STAGE/entries"
# every alternative of every entry, bare
tr '|' '\n' < "$STAGE/entries" | sed 's/^[[:space:]]*//' | bare | LC_ALL=C sort -u > "$STAGE/covered"
while read -r so owner; do
    if ! grep -qxF "$owner" "$STAGE/covered"; then
        log "WARN: dpkg-shlibdeps did not emit $owner (owner of $so); adding it unversioned"
        printf '%s\n' "$owner" >> "$STAGE/entries"
        printf '%s\n' "$owner" >> "$STAGE/covered"
    fi
done < "$STAGE/owners"
grep -vE '^[[:space:]]*(#|$)' "$EXTRA_FILE" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' > "$STAGE/extra"
while IFS= read -r p; do
    grep -qxF "$p" "$STAGE/covered" || { printf '%s\n' "$p" >> "$STAGE/entries"; printf '%s\n' "$p" >> "$STAGE/covered"; }
done < "$STAGE/extra"
# stable order: by bare package name
DEPENDS="$(awk '{ e=$0; b=$0; sub(/[[:space:]]*[(|].*/, "", b); print b "\t" e }' "$STAGE/entries" \
           | LC_ALL=C sort -t "$(printf '\t')" -k1,1 -u | cut -f2- | paste -sd, - | sed 's/,/, /g')"
[ -n "$DEPENDS" ] || die "computed an empty Depends"

{
    echo "# ncz-singularity-desktop Depends, generated by build/singularity-deb-depends.sh"
    echo "# from the payload ELF closure (dpkg-shlibdeps + dpkg -S) and"
    echo "# build/singularity-runtime-extra-deps.txt. Do not edit; it is regenerated per build."
    echo "X-Payload-SHA256: $PAYLOAD_SHA"
    echo "X-Architecture: $DEB_ARCH"
    echo "X-Suite: $SUITE"
    echo "Depends: $DEPENDS"
    while read -r so owner; do echo "X-Soname: $so $owner"; done < "$STAGE/owners"
    while IFS= read -r p; do echo "X-Runtime: $p"; done < "$STAGE/extra"
} > "$STAGE/result"
log "Depends entries: $(printf '%s\n' "$DEPENDS" | tr ',' '\n' | wc -l)"
if [ -n "$OUTFILE" ]; then
    cp "$STAGE/result" "$OUTFILE"
else
    cat "$STAGE/result"
fi
