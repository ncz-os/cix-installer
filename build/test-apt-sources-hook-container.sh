#!/bin/bash
# test-apt-sources-hook-container.sh -- run the REAL post-install/24-apt-sources.sh (with the NCZ/Debian
# separation pin it now installs) in a debian:forky container with no network, and prove it still passes.
#
# Constraint from the amd64 image builder: 24 runs a bare `apt-get update -o Acquire::Check-Date=false`,
# fails hard if no NCZ source can be wired, and decides the ncz-screensavers candidate by grepping
# `apt-cache policy` for `file:/+cdrom` and the NCZ network hosts. The pin must not change that.
#
#   * the offline pool is a real flat repo at /cdrom/ncz-payload/apt-repo (file:///cdrom), as late.sh wires it
#   * a shim gpg (cat) stands in for GnuPG so the hook does not try to apt-install it with no network
#   * hook rc, the single enabled NCZ list, the pin file, and the ncz-screensavers canary verdict are asserted
#   * `apt-cache policy ncz-screensavers` is compared WITH and WITHOUT the pin: same source lines (the pin may only
#     change priorities), and still `file:/cdrom` present
#   * a second run is idempotent; with neither keyring the hook still FAILS hard (exit 1)
# Self-skips (exit 0) when neither docker nor podman has a local debian:forky.
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="$HERE/.."
RT=""
for c in docker podman; do
    command -v "$c" >/dev/null 2>&1 && "$c" image inspect debian:forky >/dev/null 2>&1 && { RT="$c"; break; }
done
[ -n "$RT" ] || { echo "SKIP: no docker/podman with a local debian:forky image"; exit 0; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS  $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL  $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'; }

cat > "$T/inside.sh" <<'INSIDE'
set -u
# an installed NCZ-OS system has only ncz-base.sources (hook 23), not the container image stock source
rm -f /etc/apt/sources.list /etc/apt/sources.list.d/debian.sources
mkdir -p /shim /opt && cp -a /src/post-install /opt/pi && cp /src/release.conf /opt/RELEASE
printf '#!/bin/sh\ncat\n' > /shim/gpg; chmod +x /shim/gpg
# the offline pool, as preseed/late.sh wires it
mkdir -p /cdrom/ncz-payload/apt-repo /etc/apt/sources.list.d
cat > /cdrom/ncz-payload/apt-repo/Packages <<EOF
Package: ncz-screensavers
Version: 0.8.9
Architecture: all
Maintainer: T <t@example.invalid>
Description: t
Filename: ./x.deb
Size: 1
SHA256: 0000000000000000000000000000000000000000000000000000000000000000

EOF
printf 'Origin: nclawzero\nSuite: forky\nCodename: forky\nArchitectures: all amd64 arm64\nComponents: main\nDate: Mon, 05 Oct 2026 00:00:00 UTC\n' > /cdrom/ncz-payload/apt-repo/Release
echo 'deb [trusted=yes] file:///cdrom/ncz-payload/apt-repo /' > /etc/apt/sources.list.d/cixmini-offline.list
shape() { apt-cache policy ncz-screensavers 2>/dev/null | awk '/^ +[0-9]+ /{print $2}' | sort -u | tr '\n' ' '; }

PATH=/shim:$PATH bash /opt/pi/24-apt-sources.sh > /tmp/h1.log 2>&1; echo "RC_HOOK=$?"
[ -s /etc/apt/preferences.d/10-ncz-origin-separation.pref ] && echo PIN=yes || echo PIN=no
echo "NCZ_ENABLED=$(ls /etc/apt/sources.list.d/ncz-os-apt-*.list 2>/dev/null | wc -l)"
[ -f /etc/apt/sources.list.d/ncz-os-apt-r2.list.disabled ] && echo R2_DISABLED=yes || echo R2_DISABLED=no
[ -f /etc/apt/sources.list.d/cixmini-offline.list ] && echo OFFLINE_LIST_KEPT=yes || echo OFFLINE_LIST_KEPT=no
grep -q 'WARN: ncz-screensavers resolves only from the offline /cdrom pool' /tmp/h1.log && echo CANARY=offline-warn || echo CANARY=other
SHAPE_PIN="$(shape)"; echo "SHAPE_PIN=$SHAPE_PIN"
case "$SHAPE_PIN" in *file:/cdrom*) echo CDROM_VISIBLE=yes ;; *) echo CDROM_VISIBLE=no ;; esac
# the same policy output WITHOUT the pin
mv /etc/apt/preferences.d/10-ncz-origin-separation.pref /tmp/pin.bak
echo "SHAPE_NOPIN=$(shape)"
mv /tmp/pin.bak /etc/apt/preferences.d/10-ncz-origin-separation.pref
# idempotent re-run
PATH=/shim:$PATH bash /opt/pi/24-apt-sources.sh > /tmp/h2.log 2>&1; echo "RC_RERUN=$?"
echo "NCZ_ENABLED_AFTER_RERUN=$(ls /etc/apt/sources.list.d/ncz-os-apt-*.list 2>/dev/null | wc -l)"
# the hook must still fail hard when no NCZ source can be wired (no keyrings)
rm -f /opt/pi/*.asc /etc/apt/sources.list.d/ncz-os-apt-* /etc/apt/keyrings/buildkite-ncz-apt-keyring.gpg /etc/apt/keyrings/ncz-os-apt-keyring.gpg
PATH=/shim:$PATH bash /opt/pi/24-apt-sources.sh > /tmp/h3.log 2>&1; echo "RC_NOKEYS=$?"
grep -v "^\[23\]" /tmp/h1.log | head -30 | sed 's/^/LOG: /'
INSIDE
cp "$T/inside.sh" "$T/i.sh"
OUT="$("$RT" run --rm --network none -v "$ROOT:/src:ro" -v "$T/i.sh:/i.sh:ro" debian:forky bash /i.sh 2>&1)"
want() { printf '%s\n' "$OUT" | grep -qx "$1" && ok "$1" || bad "expected $1" "$OUT"; }
echo "=== real hook 24 with the pin, no network, offline pool at /cdrom ==="
want RC_HOOK=0; want PIN=yes; want NCZ_ENABLED=1; want R2_DISABLED=yes; want OFFLINE_LIST_KEPT=yes
want CANARY=offline-warn; want CDROM_VISIBLE=yes; want RC_RERUN=0; want NCZ_ENABLED_AFTER_RERUN=1
want RC_NOKEYS=1
sp="$(printf '%s\n' "$OUT" | sed -n 's/^SHAPE_PIN=//p')"; sn="$(printf '%s\n' "$OUT" | sed -n 's/^SHAPE_NOPIN=//p')"
[ -n "$sp" ] && [ "$sp" = "$sn" ] && ok "apt-cache policy ncz-screensavers lists the same sources with and without the pin ($sp)" \
    || bad "policy source lines differ with the pin: pin='$sp' nopin='$sn'"
echo "test-apt-sources-hook-container: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
