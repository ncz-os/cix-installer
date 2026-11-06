#!/bin/bash
# post-install/lib/apt-separation.sh -- keep NCZ-OS package updates separate
# from Debian's on installed systems, and refuse foreign sources outright.
#
# 2026-10-15 (native Forky-only installer): the installer now builds
# its own native T2 audio+firmware set (apple-t2-audio-config,
# apple-firmware-script) and the selected NCZ Forky Intel NPU stack
# (libopenvino-2026.4.1 and its intel-* plugins, intel-driver-compiler-npu,
# intel-fw-npu, intel-level-zero-npu, intel-validation-npu) directly on Debian
# Forky. The old policy let the third-party Ubuntu T2 repo
# (adityagarg8.github.io) win the known T2 set at priority 990, and the Intel
# apt repo (apt.repos.intel.com) win its libopenvino-intel-* plugin set at
# 990 -- that preference is gone. This file is the SINGLE SOURCE for the
# pin text: nothing else in the tree may restate it.
#
# Sourced by post-install/24-apt-sources.sh, shipped inside the ncz-apt-policy
# deb (build/build-ncz-apt-policy-deb.sh) for systems that are already
# installed, and by the gates build/test-apt-separation.sh,
# build/check-ncz-repo-policy.sh and check-installed-apt-config.sh.
#
# Why (2026-10-07, measured on a T2 MacBook Pro test machine, r200):
#   * `apt list --upgradable` mixed three populations: NCZ rebuilds, a leaked
#     Ubuntu build of a Debian package (fonts-liberation 1:2.1.5-3build1
#     shadowing Debian's 1:2.1.5-3 because it sorts higher), and genuine
#     Debian testing updates.
#   * Two NCZ repos (Buildkite + R2) were configured and overlap; same-version
#     rebuilds (ncz-wallpapers-* 1.0) showed as "1.0 -> 1.0".
#   * Buildkite Packages is a managed registry: its Release says
#     `Origin: packagecloud.io/<uuid>`, `Label: <uuid>`. We cannot make it say
#     "NCZ-OS". Only the reprepro/R2 copy carries `Origin: NCZ-OS`. So the
#     pins match NCZ by the repository HOST (apt `Pin: origin <host>`) ONLY.
#     They deliberately do NOT match `release o=NCZ-OS`: the offline install
#     mirror (build/build-forky-mirror.sh) is stamped `Origin: NCZ-OS` and
#     carries Debian-named packages that must keep apt's default priority.
#
# Rules the pin file encodes (apt priority = who wins a version contest).
# 990 (not 1000+) on purpose: never forces a downgrade.
#   NCZ origin, NCZ-reserved namespace (ncz-* cix-* ... kernels)   990
#   NCZ origin, allowlisted intentional Debian-name override       990
#   NCZ origin, any other name (i.e. a Debian-named package)       100  -> Debian (500) wins
#   Debian origin, NCZ-reserved prefixes (ncz-* cix-* cixmini-*)    -1  -> Debian cannot hijack
#   Ubuntu T2 host (adityagarg8.github.io)        EVERY package     -1  (whole host, no exception;
#                                                              whatever old t2.list files survive)
#   Intel apt host (apt.repos.intel.com)          EVERY package     -1  (same: whatever ncz-intel-accel-setup
#                                                              wrote, no exception)
#   Debian apfs-dkms / other Debian-origin T2 names: STAY at 500   (no special pin, normal upgrade)
# Exact-name overrides retain the unchanged strict publisher version gate.
#
# Test overrides: NCZ_APT_NCZ_HOSTS / NCZ_APT_T2_HOST / NCZ_APT_INTEL_HOST
# may be set before sourcing (build/test-apt-separation.sh points them at
# localhost addresses).

: "${NCZ_APT_NCZ_HOSTS:=packages.buildkite.com pub-d7b784e01679403d9c70fcd23fff5b96.r2.dev}"
: "${NCZ_APT_T2_HOST:=adityagarg8.github.io}"
: "${NCZ_APT_NCZ_RELEASE_ORIGIN:=NCZ-OS}"
: "${NCZ_APT_INTEL_HOST:=apt.repos.intel.com}"
NCZ_APT_PIN_NAME=10-ncz-origin-separation.pref

# Names only NCZ may supply. One glob per line. linux-image-*/linux-headers-*
# are here because NCZ's kernels (linux-image-cixmini, -t2-trixie, ...) live in
# the NCZ repo; Debian's own kernels are blocked separately by
# lib/kernel-purity.sh (and check-ncz-repo-policy.sh rejects the Debian
# `-amd64`/`-arm64` kernel names and metapackages in the NCZ suite).
ncz_apt_namespace_patterns() {
    cat <<'EOF'
ncz-*
cix-*
cixmini-*
chromium-ncz-*
panthor-cix-dkms
zoder
linux-image-*
linux-headers-*
EOF
}

# Prefixes that no non-NCZ origin may ever supply.
ncz_apt_reserved_prefixes() { printf '%s\n' 'ncz-*' 'cix-*' 'cixmini-*' 'chromium-ncz-*'; }

# Intentional overrides of Debian-named packages. TAB-separated:
#   name  architectures(comma list, * = any)  reason
# Adding a row here is the ONLY way a Debian-named package may be published to
# the NCZ suite and win over Debian on an installed system. The list is
# deliberately narrow -- every row is one of two kinds:
#   (1) a row that crosses a Debian package (libdrm*, libgtk4-layer-shell0)
#       we honestly rebuild from Debian sources and ship to every relevant arch.
#   (2) a row for a name we now build NATIVE for the Forky-only installer, so
#       the legacy foreign repo (Ubuntu T2 host / Intel apt host) cannot win.
# Rows are pinned to the exact architecture of the artifact. No wildcard
# `libopenvino-*` / `intel-*` glob is permitted here, and strict version
# checking remains on (the publisher refuses a same-version rebuild with
# different content).
ncz_apt_debian_overrides() {
    # Both arches ship the pinned +ncz2 set from the offline mirror (r201: amd64 had shipped +ncz1/stock);
    # dev/freedreno1/etnaviv1/tegra0 are arm64-only (the amd64 mirror does not carry them).
    local n why='libdrm ACPI-identity patch for Panthor (build/build-libdrm-debs.sh; pinned set 2.4.134-3+ncz2, release.conf NCZ_LIBDRM_NCZ_REV)'
    printf '%s\t%s\t%s\n' libdrm-common 'all,amd64,arm64' "$why"
    for n in libdrm2 libdrm-amdgpu1 libdrm-intel1 libdrm-nouveau2 libdrm-radeon1; do   # arch 'all' = the registry spelling of a ${ARCH} row
        printf '%s\t%s\t%s\n' "$n" 'all,amd64,arm64' "$why"
    done
    for n in libdrm-dev libdrm-freedreno1 libdrm-etnaviv1 libdrm-tegra0; do
        printf '%s\t%s\t%s\n' "$n" arm64 "$why"
    done
    # arm64 only: the Mali EGL driver attaches a NULL buffer in eglDestroySurface(), which
    # unmaps a live layer surface; Debian's build disconnects the desktop on Sky1. The patched
    # build must also reach systems installed before it existed, through `apt upgrade`.
    printf '%s\t%s\t%s\n' libgtk4-layer-shell0 arm64 \
        'gtk4-layer-shell 1.3.0 + patches 0001-0002 (packaging/gtk4-layer-shell/make-deb.sh; 1.3.0-1+ncz20261013)'
    # --- Native Forky-only installer rebuilds (2026-10-15) ----------
    # A. apple-t2-audio-config: independent NCZ MIT-licensed functional ALSA UCM
    #    set, native Forky build from the public immutable source revision
    #    92a5c84e0d097c41e016699d896edb76baf472fc; artifact 0.5.1+ncz1 is
    #    Architecture: all (6 UCM configs + 2 docs, no ELF binaries). Builds
    #    as data-only all; amd64 is also allowed by the content gate. The
    #    name is absent from signed Debian snapshot 20261012T023456Z. Both
    #    target upgrade simulations had zero removals. Replaces the
    #    adityagarg8.github.io 990 allowlist row in the r200 pin text.
    printf '%s\t%s\t%s\n' apple-t2-audio-config 'all,amd64' \
        'NCZ MIT functional ALSA UCM source 92a5c84e0d097c41e016699d896edb76baf472fc (artifact 0.5.1+ncz1, arch all: 6UCM+2docs/noELF); adityagarg8 host now -1'
    # B. apple-firmware-script: NCZ Forky-native firmware extractor at the
    #    public immutable source 6ee3987de2cd7494993eeb60fbe226f78f5b75e5;
    #    package 20261015+ncz1/all. Independent public source (no carry-over
    #    from the Ubuntu T2 repo); no general foreign
    #    firmware waiver permitted. Replaces the adityagarg8 990 row.
    printf '%s\t%s\t%s\n' apple-firmware-script 'all,amd64' \
        'NCZ Forky-native firmware extractor source 6ee3987de2cd7494993eeb60fbe226f78f5b75e5 (package 20261015+ncz1/all); adityagarg8 host now -1'
    # C. libopenvino-2026.4.1 + the three intel plugin shlibs (own Forky
    #    upstream source build). Publication is amd64 ONLY.
    #    NO 'libopenvino-*' wildcard: the artifact list is the actual
    #    selected CPackConfig names. The artifact is not ready yet; the
    #    publisher and version gate decide when the deb ships. Bypassing the
    #    version gate to push a not-yet-built artifact is forbidden.
    for n in libopenvino-2026.4.1 libopenvino-intel-cpu-plugin-2026.4.1 \
             libopenvino-intel-gpu-plugin-2026.4.1 libopenvino-intel-npu-plugin-2026.4.1; do
        printf '%s\t%s\t%s\n' "$n" amd64 \
            "NCZ Forky upstream CPackConfig build (amd64 only); apt.repos.intel.com host now -1, no libopenvino-* glob"
    done
    # D. NCZ Forky build of the four Intel NPU CPack components (own Forky
    #    upstream source). amd64 ONLY. NO 'intel-*' wildcard. Same migration
    #    note: artifact not yet ready, strict version checking stays on.
    for n in intel-driver-compiler-npu intel-fw-npu intel-level-zero-npu intel-validation-npu; do
        printf '%s\t%s\t%s\n' "$n" amd64 \
            "NCZ Forky upstream CPack component build (amd64 only); apt.repos.intel.com host now -1, no intel-* glob"
    done
}

# Known-bad builds that leaked into the NCZ repo and must never be offered or
# kept as a candidate (apt then falls back to Debian's own version, which on a
# machine that already installed the leak is a one-time downgrade).
# TAB-separated: name  version  reason
ncz_apt_leaked_versions() {
    printf '%s\t%s\t%s\n' fonts-liberation '1:2.1.5-3build1' \
        'Ubuntu build published to the NCZ repo by mistake; it shadows Debian 1:2.1.5-3 only because "build1" sorts higher'
}

# Vendor .debs that the offline pool stages (build/build-desktop-mirror.sh) but
# that are NOT published to the NCZ repo; their own vendor repos update them.
ncz_apt_vendor_staged() { printf '%s\n' google-chrome-stable vivaldi-stable; }

# Legacy informational list of T2 package names historically associated with
# the third-party t2-ubuntu-repo (Ubuntu-built). The 2026-10-15 policy pins the
# whole $NCZ_APT_T2_HOST origin at -1 -- nothing from that host may win a
# contest -- so this list is NO LONGER consulted by the pin text. It is
# preserved as a reminder of the names that used to be allowlisted, for any
# downstream consumer that wants to know which names used to be T2-only.
# Apple's applesmc-t2 / apple-bce etc. are the DKMS and daemon packages the
# t2linux project ships; post-install/55-t2-firmware.sh still installs
# apple-firmware-script + apple-t2-audio-config by name, but the new pin
# rejects everything from that host, so an installed system needs an
# NCZ-origin build of those names to keep them current.
ncz_apt_t2_packages() {
    cat <<'EOF'
apfs-dkms
apple-bce
apple-firmware-script
apple-t2-audio-config
apple-touchbar
applesmc-t2
bcm5974-t2
t2-apple-audio-dsp-mic
t2-apple-audio-dsp-speakers161
t2-ncm
t2-touchid
t2fanrd
EOF
}

_ncz_apt_join() { tr '\n' ' ' | sed 's/ *$//'; }

# Classify one package name for the repo-content gate.
#   prints: namespace | override | vendor | debian-named | debian-kernel
ncz_apt_name_class() {
    local name="$1" pat
    case "$name" in
        linux-image-amd64|linux-image-arm64|linux-headers-amd64|linux-headers-arm64) echo debian-kernel; return ;;
        linux-image-*-amd64|linux-image-*-arm64|linux-headers-*-amd64|linux-headers-*-arm64) echo debian-kernel; return ;;
    esac
    while IFS= read -r pat; do
        # shellcheck disable=SC2254
        case "$name" in $pat) echo namespace; return ;; esac
    done < <(ncz_apt_namespace_patterns)
    if ncz_apt_debian_overrides | cut -f1 | grep -qxF -- "$name"; then echo override; return; fi
    if ncz_apt_vendor_staged | grep -qxF -- "$name"; then echo vendor; return; fi
    echo debian-named
}

# ncz_apt_override_arch_ok NAME ARCH -> 0 when the override row allows ARCH.
ncz_apt_override_arch_ok() {
    local name="$1" arch="$2" row archs
    row="$(ncz_apt_debian_overrides | awk -F'\t' -v n="$name" '$1==n{print $2; exit}')"
    [ -n "$row" ] || return 1
    archs=",$row,"
    case "$archs" in *",*,"*|*",$arch,"*) return 0 ;; esac
    return 1
}

# The preferences file, to stdout.
ncz_apt_separation_pin_text() {
    local ns resv allow h
    ns="$(ncz_apt_namespace_patterns | _ncz_apt_join)"
    resv="$(ncz_apt_reserved_prefixes | _ncz_apt_join)"
    allow="$(ncz_apt_debian_overrides | cut -f1 | _ncz_apt_join)"
    cat <<EOF
# /etc/apt/preferences.d/$NCZ_APT_PIN_NAME
# Written by post-install/24-apt-sources.sh and the ncz-apt-policy package from
# post-install/lib/apt-separation.sh. Do not edit by hand: the next
# 'apt upgrade' of ncz-apt-policy rewrites it.
#
# NCZ-OS packages come from the NCZ repo; Debian packages come from Debian.
# Priorities: 990 = wins, 500 = apt default (Debian), 100 = only if nothing
# better, -1 = never. Origins are matched by repository HOST because Buildkite
# Packages is a managed registry whose Release Origin cannot be set to NCZ-OS.
# Not matched by Release Origin: the offline install mirror is also labelled
# NCZ-OS and must keep priority 500 for its Debian-named packages.
#
# Debian-named packages in the NCZ repo (fonts-liberation 1:2.1.5-3build1) lose
# to Debian unless named in the override list below.

# Debian can never supply an NCZ-reserved name.
Package: $resv
Pin: release o=Debian
Pin-Priority: -1

EOF
    ncz_apt_leaked_versions | while IFS=$'\t' read -r n v why; do
        printf '# Leaked build, never offered: %s\nPackage: %s\nPin: version %s\nPin-Priority: -1\n\n' "$why" "$n" "$v"
    done
    for h in $NCZ_APT_NCZ_HOSTS; do
        _ncz_apt_nczstanzas "origin $h" "$ns" "$allow"
    done
    cat <<EOF
# Whole-host rejection (2026-10-15, native Forky-only installer):
# the third-party Ubuntu T2 repo (legacy t2.list files may still exist on
# installed systems from earlier hook 55 runs) and the Intel apt repo
# (whatever ncz-intel-accel-setup wrote) are blocked wholesale. NO package
# from either host may win a contest -- not a known T2 set, not
# libopenvino-intel-*, not intel-opencl-icd, nothing. The NCZ suite covers
# the few names it actually rebuilds natively (apple-t2-audio-config,
# apple-firmware-script, libopenvino-2026.4.1 + its intel-* plugins,
# intel-driver-compiler-npu / intel-fw-npu / intel-level-zero-npu /
# intel-validation-npu); everything else comes from Debian at 500.
Package: *
Pin: origin $NCZ_APT_T2_HOST
Pin-Priority: -1

Package: *
Pin: origin $NCZ_APT_INTEL_HOST
Pin-Priority: -1
EOF
}

_ncz_apt_nczstanzas() {  # "origin host"  namespace-globs  allowlist-names
    printf '# NCZ origin: %s\nPackage: %s\nPin: %s\nPin-Priority: 990\n\n' "$1" "$2" "$1"
    printf 'Package: %s\nPin: %s\nPin-Priority: 990\n\n' "$3" "$1"
    printf 'Package: *\nPin: %s\nPin-Priority: 100\n\n' "$1"
}

# ncz_apt_write_separation_pin [ROOT]
ncz_apt_write_separation_pin() {
    local root="${1:-}" pref
    pref="$root/etc/apt/preferences.d/$NCZ_APT_PIN_NAME"
    install -d -m 0755 "$root/etc/apt/preferences.d"
    ncz_apt_separation_pin_text > "$pref"
    chmod 0644 "$pref"
    echo "[apt-separation] wrote $pref"
}

# --- single NCZ repo + documented fallback -----------------------------------
# Exactly ONE NCZ repo is enabled: Buildkite Packages (superset: 19 packages vs
# R2's 13; carries zoder, libdrm, the NPU embed model that R2's 300 MB
# single-PUT limit rejects; since 2026-07-26). R2 stays installed
# as a DISABLED fallback (<name>.list.disabled: apt ignores it silently) with
# its keyring staged, and `ncz-apt-source r2` switches to it.
#
# ncz_apt_write_ncz_sources HERE [ROOT]  -> prints "buildkite", "r2" or "none"
# (which one is ENABLED); returns 1 when none could be wired.
ncz_apt_write_ncz_sources() {
    local here="$1" root="${2:-}" kr_dir sl_dir tmp
    kr_dir="$root/etc/apt/keyrings"; sl_dir="$root/etc/apt/sources.list.d"
    local bk_kr="$kr_dir/buildkite-ncz-apt-keyring.gpg" r2_kr="$kr_dir/ncz-os-apt-keyring.gpg"
    local bk_src="$sl_dir/ncz-os-apt-buildkite.list" r2_src="$sl_dir/ncz-os-apt-r2.list"
    local bk_ok=0 r2_ok=0
    install -d "$kr_dir" "$sl_dir"

    # Dearmor to a temp file and move it into place only on success: a failing
    # gpg must never truncate a keyring that already works (hook 24 re-runs).
    _ncz_apt_stage_keyring() {  # asc dest
        [ -f "$1" ] || return 0
        tmp="$(mktemp "$kr_dir/.keyring.XXXXXX")" || return 0
        if gpg --dearmor < "$1" > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
            chmod 0644 "$tmp"; mv -f "$tmp" "$2"
        else
            rm -f "$tmp"
        fi
    }
    _ncz_apt_stage_keyring "$here/buildkite-ncz-apt-keyring.asc" "$bk_kr"
    _ncz_apt_stage_keyring "$here/ncz-os-apt-keyring.asc" "$r2_kr"
    [ -s "$bk_kr" ] && bk_ok=1
    [ -s "$r2_kr" ] && r2_ok=1

    local bk_line="deb [signed-by=/etc/apt/keyrings/buildkite-ncz-apt-keyring.gpg] https://packages.buildkite.com/ncz-os/ncz/any/ any main"
    local r2_line="deb [signed-by=/etc/apt/keyrings/ncz-os-apt-keyring.gpg] https://pub-d7b784e01679403d9c70fcd23fff5b96.r2.dev any main"
    # Exactly one enabled NCZ repo, whatever state a previous run (or the r200
    # dual configuration) left: drop every NCZ list first, then write the one.
    rm -f "$bk_src" "$bk_src.disabled" "$r2_src" "$r2_src.disabled"
    if [ "$bk_ok" = 1 ]; then
        printf '%s\n' \
          '# NCZ-OS packages (kernels, CIX userspace, Singularity Desktop, NCZ wallpapers/screensavers).' \
          '# The ONE enabled NCZ repo: Buildkite Packages (public, no auth). Origin is matched by host in' \
          '# /etc/apt/preferences.d/10-ncz-origin-separation.pref. Fallback: ncz-apt-source r2.' \
          "$bk_line" > "$bk_src"
        [ "$r2_ok" = 1 ] && printf '%s\n' \
          '# DISABLED fallback copy of the NCZ repo on Cloudflare R2 (reprepro Release: Origin NCZ-OS).' \
          '# Not a second source: enabling it disables the Buildkite one. Use: ncz-apt-source r2' \
          "$r2_line" > "$r2_src.disabled"
        echo buildkite
    elif [ "$r2_ok" = 1 ]; then
        printf '%s\n' \
          '# NCZ-OS packages from Cloudflare R2. ENABLED ONLY because the Buildkite keyring was unusable' \
          '# when this was written. Switch back with: ncz-apt-source buildkite' \
          "$r2_line" > "$r2_src"
        echo r2
    else
        echo none; return 1
    fi
    return 0
}

# --- the switch helper (installed as /usr/sbin/ncz-apt-source) ----------------
ncz_apt_source_helper_text() {
    cat <<'EOF'
#!/bin/sh
# ncz-apt-source -- show or switch the ONE enabled NCZ-OS apt repo.
#   ncz-apt-source status | buildkite | r2
# Exactly one of the two is ever enabled; the other is kept as <file>.disabled.
# R2 is a degraded fallback: it carries fewer packages than Buildkite.
set -eu
D="${NCZ_APT_ROOT:-}/etc/apt/sources.list.d"
BK="$D/ncz-os-apt-buildkite.list"; R2="$D/ncz-os-apt-r2.list"
state() {
    for n in buildkite r2; do
        f=$BK; [ "$n" = r2 ] && f=$R2
        if [ -f "$f" ]; then echo "$n: enabled"
        elif [ -f "$f.disabled" ]; then echo "$n: disabled"
        else echo "$n: not installed"; fi
    done
}
switch() {   # $1 = want (BK|R2 var names)
    want="$1"; other="$2"
    [ -f "$want" ] || [ -f "$want.disabled" ] || { echo "ncz-apt-source: $want is not installed" >&2; exit 1; }
    [ -f "$want" ] || mv "$want.disabled" "$want"
    [ -f "$other" ] && mv "$other" "$other.disabled"
    :
}
case "${1:-status}" in
    status) state ;;
    buildkite) [ "$(id -u)" = 0 ] || [ -n "${NCZ_APT_ROOT:-}" ] || { echo "run as root" >&2; exit 1; }
               switch "$BK" "$R2"; state ;;
    r2)        [ "$(id -u)" = 0 ] || [ -n "${NCZ_APT_ROOT:-}" ] || { echo "run as root" >&2; exit 1; }
               switch "$R2" "$BK"; state ;;
    *) echo "usage: ncz-apt-source status|buildkite|r2" >&2; exit 2 ;;
esac
if [ "${1:-status}" != status ] && [ -z "${NCZ_APT_ROOT:-}" ]; then
    echo "now run: apt-get update"
fi
EOF
}

ncz_apt_install_source_helper() {   # [ROOT]
    local root="${1:-}"
    install -d -m 0755 "$root/usr/sbin"
    ncz_apt_source_helper_text > "$root/usr/sbin/ncz-apt-source"
    chmod 0755 "$root/usr/sbin/ncz-apt-source"
}
