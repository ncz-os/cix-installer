#!/bin/bash
# build-ncz-apt-policy-deb.sh -- package the NCZ/Debian apt separation as an
# NCZ-OS package so machines that are ALREADY installed (r200 and earlier, which
# only ever ran hook 24 once at install time) pick it up through `apt upgrade`.
#
# The package carries post-install/lib/apt-separation.sh (the single source of
# the pins) and /usr/sbin/ncz-apt-source. Its postinst
#   * (re)writes /etc/apt/preferences.d/10-ncz-origin-separation.pref, and
#   * migrates a dual-repo configuration: if both ncz-os-apt-buildkite.list and
#     ncz-os-apt-r2.list are enabled, R2 becomes ncz-os-apt-r2.list.disabled.
# It never touches sources.list.d otherwise and never removes a package.
#
# Delivery: nothing installs a standalone package by itself, so it is pulled in
# two ways -- manifests/install-extra.pkgs + hook 24 on new installs, and ncz-update-apply,
# which installs it before every refresh/apply. (No Depends from ncz-singularity-desktop:
# that deb is ABI-gated against exact versions and must not be rewrapped.) Publish it BEFORE building images or a new
# Singularity package.
#
# Version: bump NCZ_APT_POLICY_VERSION whenever lib/apt-separation.sh changes
# (the version gate refuses a same-version rebuild with different content).
# Output: build/ncz-apt-policy-deb/ncz-apt-policy_<ver>_all.deb
# Publishing is an operator action (build/ops/argos/ncz-reprepro-publish.sh).
set -euo pipefail
umask 022   # reproducible file modes: the version gate compares content, modes included
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG=ncz-apt-policy
# 1.0.1: 1.0.0 shipped a /bin/sh postinst that sourced the bash-only library
# and died under dash. 1.0.0 must never be published.
# 1.0.2: control-data change (deterministic Installed-Size, see below) so the same
# Architecture:all package is byte-identical on every host and needs ONE reviewed
# ledger row instead of one per host.
VERSION="${NCZ_APT_POLICY_VERSION:-1.0.2}"
OUT="${NCZ_APT_POLICY_OUT:-$ROOT/build/ncz-apt-policy-deb}"
LIB="$ROOT/post-install/lib/apt-separation.sh"
[ -r "$LIB" ] || { echo "ERROR: $LIB missing" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
install -d "$WORK/DEBIAN" "$WORK/usr/share/ncz-apt-policy" "$WORK/usr/sbin" "$WORK/usr/share/doc/$PKG"
install -m 0644 "$LIB" "$WORK/usr/share/ncz-apt-policy/apt-separation.sh"
# shellcheck source=../post-install/lib/apt-separation.sh
. "$LIB"
ncz_apt_install_source_helper "$WORK"
printf 'NCZ-OS apt policy: keeps NCZ-OS package updates separate from Debian ones.\nSee docs/APT-SEPARATION.md in cix-installer.\n' > "$WORK/usr/share/doc/$PKG/README"

# Installed-Size MUST be a host-independent value: `du -sk` counts allocated
# blocks, which differ by filesystem (amd64 build host ext4, arm64 btrfs/tmpfs ...), so
# the SAME package produced different bytes on different hosts -- the r203 input
# finding that forced two reviewed ledger rows for one Architecture:all package.
# Sum the actual file sizes instead (KiB, rounded up): deterministic everywhere,
# so one deb byte-identity exists for both arches.
SIZE_KB=$(find "$WORK/usr" -type f -printf '%s\n' 2>/dev/null \
    | awk '{s+=$1} END{printf "%d", (s+1023)/1024}')
case "$SIZE_KB" in ''|*[!0-9]*) SIZE_KB=0 ;; esac
cat > "$WORK/DEBIAN/control" <<CONTROL
Package: $PKG
Version: $VERSION
Section: admin
Priority: optional
Architecture: all
Maintainer: Jason Perlow <jperlow@gmail.com>
Installed-Size: $SIZE_KB
Depends: apt, bash
Description: NCZ-OS apt origin separation (pins and single-repo policy)
 Writes /etc/apt/preferences.d/10-ncz-origin-separation.pref so NCZ-OS
 packages come from the NCZ-OS repository, Debian packages from Debian, and
 third-party T2 packages only for the known T2 package set. Installs
 ncz-apt-source to switch the single enabled NCZ repo to its fallback.
CONTROL

# bash, not sh: the library is bash (process substitution, $'\t').
cat > "$WORK/DEBIAN/postinst" <<'POSTINST'
#!/bin/bash
set -e
if [ "$1" = configure ]; then
    # shellcheck disable=SC1091
    . /usr/share/ncz-apt-policy/apt-separation.sh
    ncz_apt_write_separation_pin
    d=/etc/apt/sources.list.d
    if [ -f "$d/ncz-os-apt-buildkite.list" ] && [ -f "$d/ncz-os-apt-r2.list" ]; then
        mv "$d/ncz-os-apt-r2.list" "$d/ncz-os-apt-r2.list.disabled"
        echo "ncz-apt-policy: two NCZ repos were enabled; R2 is now a disabled fallback (ncz-apt-source status)"
    fi
fi
exit 0
POSTINST
cat > "$WORK/DEBIAN/postrm" <<'POSTRM'
#!/bin/sh
set -e
if [ "$1" = purge ]; then rm -f /etc/apt/preferences.d/10-ncz-origin-separation.pref; fi
exit 0
POSTRM
chmod 0755 "$WORK/DEBIAN/postinst" "$WORK/DEBIAN/postrm"

# mtime epoch: a fixed value per package version, NOT the build's global
# SOURCE_DATE_EPOCH (the commit time of HEAD, which moves on every commit) and
# NOT the commit time of this script or the library (a comment-only edit here
# moved the epoch and so the bytes of an unchanged 1.0.2 package, which then no
# longer matched its reviewed row in manifests/ncz-packages.tsv).  The bytes now
# depend only on the packaged content and this value.  When the content changes,
# bump VERSION, set a new epoch here and update the ledger row
# (build/test-ncz-apt-policy-deb.sh checks the built sha against that row).
# 1791662078 is the epoch the reviewed 1.0.2 bytes were built with.
SOURCE_DATE_EPOCH=1791662078
export SOURCE_DATE_EPOCH
find "$WORK" -type d -exec chmod 0755 {} +
chmod 0644 "$WORK/usr/share/doc/$PKG/README"
find "$WORK" -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +

install -d "$OUT"
DEB="$OUT/${PKG}_${VERSION}_all.deb"
dpkg-deb -Zxz --build --root-owner-group "$WORK" "$DEB" >/dev/null
# shellcheck source=lib/deb-version-gate.sh
. "$ROOT/build/lib/deb-version-gate.sh"
ncz_deb_version_gate "$DEB" || exit 1
ncz_policy_deb_lib_check "$DEB" "$LIB" || exit 1
echo "built: $DEB ($(du -h "$DEB" | cut -f1))"
