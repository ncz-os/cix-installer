#!/bin/bash
# 10-amd64-kernel.sh — install BOTH AMD64 kernel lines (dpkg-tracked).
#
# AMD64 analogue of 10-our-kernel.sh (arm64/Sky1). Differs in one
# structural way: arm64 has exactly one shipping "edge" kernel, resolved
# via apt from the Buildkite repo. AMD64 has no apt repo for its kernels
# yet (both lines were built on PROTEUS/CERBERUS) — so this hook installs
# the two staged .deb sets directly with dpkg, the same pattern
# 10-our-kernel.sh already
# uses for its *embedded-deb* fast path (local_deb()+dpkg -i), just
# without an apt-repo fallback because none exists.
#
# Both kernels are installed side by side on purpose: T2-unified-stable
# (7.2.6) as the DEFAULT, vanilla-edge (7.3-rc3) as the alternate GRUB
# entry. Do not prune one the way 10-our-kernel.sh prunes "not KVER_NEXT"
# — that pruning exists because arm64 ships exactly one kernel; here two
# are the intended end state.
set -euo pipefail

# Real root cause of a full-install abort on arm64 (2026-09-15): this hook
# was REQUIRED (run-all.sh's MACHINE_HOOKS_RE has no arch axis -- filenames
# only) and had NO arch guard, so it ran unconditionally on every build.
# On arm64, $ASSETS/amd64-{stable,edge} never exist, both install_one()
# calls WARN-and-return, INSTALLED_KERNELS stays 0, and the hook's own
# "no AMD64 kernel installed" check did `exit 1` -- a REQUIRED-hook
# failure that run-all.sh (correctly) treats as fatal and aborts the
# whole install ("Failed to run preseeded command ... exit code 1").
# Same detection pattern already established in 21-flatpak-arch-filter.sh
# and 52-vivaldi.sh: env var first, then the late.sh-stamped BUILD_ARCH
# file, then dpkg as a last-resort fallback.
INSTALLER_META=/usr/local/lib/cix-installer
NCZ_SYSTEM_ARCH="${NCZ_TARGET_ARCH:-}"
if [ -z "$NCZ_SYSTEM_ARCH" ] && [ -r "$INSTALLER_META/BUILD_ARCH" ]; then
    NCZ_SYSTEM_ARCH=$(tr -d '[:space:]' < "$INSTALLER_META/BUILD_ARCH")
fi
NCZ_SYSTEM_ARCH="${NCZ_SYSTEM_ARCH:-$(dpkg --print-architecture 2>/dev/null || true)}"
if [ "$NCZ_SYSTEM_ARCH" != "amd64" ]; then
    echo "[10-amd64] NCZ_SYSTEM_ARCH=$NCZ_SYSTEM_ARCH -- not amd64, skipping (arm64/Sky1 uses 10-our-kernel.sh)"
    exit 0
fi

ASSETS=/usr/local/lib/cix-installer/assets/kernel
INSTALLED_KERNELS=0

install_one(){
    local label="$1" dir="$2"
    local kver img hdr
    [ -d "$dir" ] || { echo "[10-amd64] WARN: $dir absent — skipping $label"; return 0; }
    # Sort -V picks the highest-version .deb when more than one is staged --
    # but stage-amd64-kernel.sh now prunes to exactly one image + one
    # headers pair per line, so the "two versions accumulated" condition is
    # closed at the source. If we ever see multiple here, log it loudly;
    # silently picking tail-1 would mask a real regression of the staging
    # contract.
    img=$(find "$dir" -maxdepth 1 -name 'linux-image-*.deb')
    hdr=$(find "$dir" -maxdepth 1 -name 'linux-headers-*.deb')
    local img_count=0 hdr_count=0
    [ -n "$img" ] && img_count=$(echo "$img" | wc -l | tr -d ' ')
    [ -n "$hdr" ] && hdr_count=$(echo "$hdr" | wc -l | tr -d ' ')
    if [ "$img_count" -ne 1 ] || [ "$hdr_count" -ne 1 ]; then
        echo "[10-amd64] ERROR: $label has $img_count image .deb(s) and $hdr_count headers .deb(s) (must be exactly 1 each -- stage-amd64-kernel.sh should prune)" >&2
        ls -1 "$dir"/linux-image-*_amd64.deb "$dir"/linux-headers-*_amd64.deb 2>/dev/null | sed 's/^/    /' >&2
        return 0
    fi
    # KVER from the .deb FILENAME, NOT from a KVER sidecar file. The sidecar
    # is a build-host text file tracked in git; it can drift out of sync
    # with the .deb the build actually shipped if base.squashfs was reused
    # from a prior build, and that drift is exactly what produced the
    # false "no AMD64 kernel installed" ERROR on 2026-09-28 (kernel was
    # installed -- vmlinuz-7.3.0-rc5 was right there -- but the hook
    # checked /boot/vmlinuz-$KVER sidecar's rc4-xhcifix and saw it absent).
    # The .deb filename is the upstream kernel package maintainer's own
    # declaration of the installed version -- it can disagree with nothing.
    # Naming convention: linux-image-<KVER>_<PKGVER>_amd64.deb
    kver="$(basename "$img")"
    kver="${kver#linux-image-}"
    kver="${kver%_amd64.deb}"
    kver="${kver%_*}"      # strip the _<PKGVER> suffix, leaving "7.3.0-rc5-1-t2-trixie"
    if [ -z "$kver" ] || [ -z "$img" ]; then
        echo "[10-amd64] WARN: $label incomplete (could not derive kver from '$(basename "$img" 2>/dev/null)') — skipping"
        return 0
    fi
    echo "[10-amd64] installing $label kernel $kver"
    echo "    $(basename "$img")"
    echo "    $(basename "$hdr")"
    # dpkg first (fast, no network); fix any unmet deps via apt against the
    # sources 24-apt-sources.sh already wired for the base manifest install.
    if ! dpkg -i "$img" "$hdr" 2>&1 | tail -20; then
        echo "    dpkg reported unmet deps — resolving via apt-get -f install"
        apt-get -f install -y 2>&1 | tail -20 || true
    fi
    # Verify against the kernel package we ACTUALLY installed, by querying
    # dpkg -- the .deb is now part of dpkg's database, so this can no
    # longer disagree with reality the way the KVER sidecar did. Falling
    # back to /boot/vmlinuz-$kver keeps a useful diagnostic if dpkg-query
    # somehow doesn't see the install (e.g. the dpkg -i was redirected to
    # apt-get -f which resolved a different version).
    # dpkg-query -W was rejected by dpkg under --root on some hosts
    # ("unknown option -W"); dpkg -s works uniformly and reports the
    # Status line the way dpkg-query -W -f='${Status}' does.
    local pkg_status pkg_ok=0
    pkg_status="$(dpkg -s "linux-image-${kver}" 2>/dev/null \
                  | awk '/^Status: / { sub(/^Status: /, "", $0); print; exit }')"
    case "$pkg_status" in
        *"install ok installed"*) pkg_ok=1 ;;
    esac
    if [ "$pkg_ok" -ne 1 ]; then
        echo "[10-amd64] WARN: $label: dpkg says linux-image-${kver} is not 'install ok installed' (got '${pkg_status:-<absent>}')" >&2
    fi
    if [ ! -s "/boot/vmlinuz-$kver" ]; then
        echo "[10-amd64] WARN: $label installed but /boot/vmlinuz-$kver missing" >&2
        ls -la /boot 2>&1
        return 0
    fi
    modcount=$(find "/usr/lib/modules/$kver" \( -name '*.ko' -o -name '*.ko.xz' \) 2>/dev/null | wc -l)
    if [ "$modcount" -lt 50 ]; then
        echo "[10-amd64] WARN: $label modules dir suspiciously small (.ko=$modcount)" >&2
        return 0
    fi
    echo "    OK: /boot/vmlinuz-$kver + $modcount .ko modules (dpkg-query confirms install)"
    INSTALLED_KERNELS=$((INSTALLED_KERNELS + 1))
    depmod -a "$kver" 2>/dev/null || true
    echo "$kver" >> /usr/local/lib/cix-installer/KVER_LIST_AMD64
}

: > /usr/local/lib/cix-installer/KVER_LIST_AMD64

install_one "stable (T2-unified)" "$ASSETS/amd64-stable"
install_one "edge (vanilla 7.3-rc3)" "$ASSETS/amd64-edge"

if [ "$INSTALLED_KERNELS" -eq 0 ]; then
    echo "[10-amd64] ERROR: no AMD64 kernel installed — Phase 1 cannot continue." >&2
    exit 1
fi

# Debian's generic kernel is not needed once a real NCZ kernel line is in —
# same rationale as 10-our-kernel.sh's "we ship our own" removal.
apt-get remove -y --purge "linux-image-amd64" 2>/dev/null || true
apt-get autoremove -y --purge 2>/dev/null || true

echo "[10-amd64] kernel phase OK — $INSTALLED_KERNELS line(s) installed:"
cat /usr/local/lib/cix-installer/KVER_LIST_AMD64 2>/dev/null || true
