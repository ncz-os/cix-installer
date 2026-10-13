#!/bin/bash
# post-install/lib/kernel-purity.sh -- shared Debian-kernel blocking policy.
#
# Sourced by post-install/10-our-kernel.sh (arm64) and
# post-install/10-amd64-kernel.sh (amd64) BEFORE either hook touches apt.
#
# Why this exists (policy since 2026-10-04, Cygnus 26.10):
#   NCZ-OS ships its own unified 7.3 kernel -- linux-image-cixmini (arm64) /
#   linux-image-<ver>-t2-trixie (amd64). Until now the ONLY guarantee that
#   Debian's default kernel (forky's 7.1.x linux-image-arm64 / linux-image-amd64
#   meta or a versioned linux-image-7.1*) could not be installed was a
#   `apt-get remove --purge` run AFTER our kernel was in place. That is
#   after-the-fact: anything apt pulled in earlier (or a package that
#   Depends/Recommends linux-image-* resolving during a later upgrade) could
#   still drag the Debian kernel back on. The remove lines stay as
#   belt-and-braces, but the real guarantee is an apt preferences pin.
#
#   Priority -1 makes apt treat a Debian-origin candidate as unavailable, so a
#   package that Depends/Recommends linux-image-* cannot pull the Debian
#   kernel in: the dependency is either skipped (Recommends) or the install
#   fails closed (Depends) instead of silently installing a second kernel.
#
#   The origin qualifier on the glob pin is what keeps OUR packages working:
#   our own linux-image-cixmini / linux-image-<ver>-t2-trixie match the
#   linux-image-* glob but come from the NCZ-Origin repos (Buildkite/R2), not
#   from `o=Debian`, so they stay at full priority and upgrade normally. The
#   global (origin-less) rules below only name Debian metapackages and
#   arch-suffixed versioned names, which are never NCZ package names.
#
#   No `Provides: linux-image` shim is added to our kernel packages: the only
#   in-tree consumers of a kernel image are our own hooks (which install the
#   package explicitly), and a third-party package that Depends on the Debian
#   metapackage should fail closed rather than be silently satisfied by a
#   foreign-provider shim.

# Print the exact preferences file contents to stdout. Kept separate from the
# writer so build/test-kernel-purity-pin.sh can feed the real text into an
# apt simulation without touching /etc/apt.
ncz_kernel_purity_pin_text() {
    cat <<'PIN'
# /etc/apt/preferences.d/00-ncz-kernel-purity.pref
# Written by post-install/10-our-kernel.sh (arm64) and
# post-install/10-amd64-kernel.sh (amd64). Do not edit by hand; see
# post-install/lib/kernel-purity.sh for the rationale (policy since
# 2026-10-04: no Debian default kernel may enter or boot a Cygnus 26.10 image).
#
# A Debian-origin linux-image-*/linux-headers-* candidate is unavailable.
# The origin qualifier leaves NCZ-Origin kernel packages installable.
Package: linux-image-* linux-headers-* linux-image linux-headers
Pin: release o=Debian
Pin-Priority: -1

# Belt-and-braces for the Debian metapackages: global -1 because these exact
# names are never NCZ package names, even if a source omitted its Origin field.
Package: linux-image-arm64 linux-image-amd64 linux-headers-arm64 linux-headers-amd64
Pin-Priority: -1

# Belt-and-braces for the Debian arch-suffixed versioned kernels
# (linux-image-7.1.x-...-amd64 / -arm64). NCZ's amd64 kernel ends in
# -t2-trixie and arm64 uses linux-image-cixmini, so neither is caught here.
Package: linux-image-*-arm64 linux-image-*-amd64 linux-headers-*-arm64 linux-headers-*-amd64
Pin-Priority: -1
PIN
}

ncz_write_kernel_purity_pin() {
    local pref=/etc/apt/preferences.d/00-ncz-kernel-purity.pref
    install -d -m 0755 /etc/apt/preferences.d
    ncz_kernel_purity_pin_text > "$pref"
    chmod 0644 "$pref"
    echo "[kernel-purity] wrote $pref (Debian linux-image-*/linux-headers-* pinned -1)"

    # Also hold the Debian metapackages if apt is present. A hold on a
    # not-installed package is harmless and prevents a later dependency from
    # installing it; on an installed one it prevents any change.
    if command -v apt-mark >/dev/null 2>&1; then
        local p
        for p in linux-image-arm64 linux-image-amd64 linux-headers-arm64 linux-headers-amd64; do
            apt-mark hold "$p" >/dev/null 2>&1 || true
        done
        echo "[kernel-purity] held Debian kernel metapackages (linux-image/headers-{arm64,amd64})"
    fi
}
