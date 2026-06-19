#!/bin/bash
# check-cix-deps.sh — dependency-closure check for the CIX proprietary debs +
# our kernel debs against the SERVER-only mirror. Uses apt's real resolver in a
# throwaway root (server-mirror + a local pool of cix/kernel debs as sources).
# Reports, per package, whether it installs server-only and which deps are
# unsatisfied (e.g. desktop libs that only exist online).
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SERVER="$REPO/build/server-mirror"
CIX="$REPO/assets/cix-debs"
KDEBS="$REPO/build/kernel-debs"
SUITE=resolute
ARCH=arm64
OUTRPT="$REPO/build/cix-deps.report"

[ -d "$SERVER" ] || { echo "ERROR: $SERVER missing (run build-server-mirror.sh)"; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
POOL="$T/pool"; mkdir -p "$POOL"
cp -n "$CIX"/*.deb "$KDEBS"/*.deb "$POOL"/ 2>/dev/null || true
( cd "$POOL" && dpkg-scanpackages -m . /dev/null > Packages 2>/dev/null )

mkdir -p "$T/etc/apt/apt.conf.d" "$T/var/lib/apt/lists/partial" \
         "$T/var/lib/dpkg" "$T/var/cache/apt/archives/partial"
: > "$T/var/lib/dpkg/status"
cat > "$T/etc/apt/sources.list" <<EOF
deb [trusted=yes] file://$SERVER $SUITE main
deb [trusted=yes] file://$POOL ./
EOF

APTOPTS=(
  -o Dir="$T" -o Dir::State="$T/var/lib/apt"
  -o Dir::State::status="$T/var/lib/dpkg/status"
  -o Dir::Cache="$T/var/cache/apt" -o Dir::Etc="$T/etc/apt"
  -o APT::Architecture="$ARCH" -o APT::Architectures="$ARCH"
  -o Acquire::Languages=none -o APT::Install-Recommends=0
)
apt-get "${APTOPTS[@]}" update >/dev/null 2>&1

# the packages we ship (names from the local pool index)
NAMES=$(awk '/^Package: /{print $2}' "$POOL/Packages" | sort -u)

ok=0; bad=0
{
    echo "# CIX/kernel dep-closure vs SERVER-only mirror — $(date -u +%FT%TZ)"
    echo "# server mirror: $(find "$SERVER" -name '*.deb' | wc -l) debs"
    echo "# our packages : $(echo "$NAMES" | wc -l)"
    echo ""
} > "$OUTRPT"

for p in $NAMES; do
    if apt-get "${APTOPTS[@]}" install -s -y "$p" > "$T/one.log" 2>&1 && grep -q '^Inst ' "$T/one.log"; then
        ok=$((ok+1))
        # note if it drags in nothing but itself vs pulls server deps
        ndeps=$(grep -c '^Inst ' "$T/one.log")
        echo "OK   $p  (installs, $ndeps pkgs incl deps)" >> "$OUTRPT"
    else
        bad=$((bad+1))
        echo "FAIL $p" >> "$OUTRPT"
        grep -E "Depends:|Conflicts:|but it is not|Unable to locate" "$T/one.log" \
            | sed 's/^/       /' | sort -u >> "$OUTRPT"
    fi
done

echo "== cix/kernel dep-closure vs server-only mirror =="
echo "  OK (installs server-only): $ok"
echo "  FAIL (needs more, likely desktop/online): $bad"
echo "  report: $OUTRPT"
echo ""
echo "--- FAIL detail ---"
grep -A4 '^FAIL ' "$OUTRPT" | head -60 || echo "  (none — all install server-only)"
