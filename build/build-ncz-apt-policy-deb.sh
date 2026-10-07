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
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG=ncz-apt-policy
# 1.0.1: 1.0.0 shipped a /bin/sh postinst that sourced the bash-only library
# and died under dash. 1.0.0 must never be published.
VERSION="${NCZ_APT_POLICY_VERSION:-1.0.1}"
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

SIZE_KB=$(du -sk "$WORK/usr" | cut -f1)
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

if [ -z "${SOURCE_DATE_EPOCH:-}" ]; then
    SOURCE_DATE_EPOCH="$(git -C "$ROOT" log -1 --format=%ct -- post-install/lib/apt-separation.sh build/build-ncz-apt-policy-deb.sh 2>/dev/null || true)"
    : "${SOURCE_DATE_EPOCH:=1790000000}"
fi
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
echo "built: $DEB ($(du -h "$DEB" | cut -f1))"
