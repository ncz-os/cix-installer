#!/bin/bash
# post-install/lib/apt-separation.sh -- keep NCZ-OS package updates separate
# from Debian's (and from the third-party T2 repo's) on installed systems.
#
# Sourced by post-install/24-apt-sources.sh, shipped inside the ncz-apt-policy
# deb (build/build-ncz-apt-policy-deb.sh) for systems that are already
# installed, and by the gates build/test-apt-separation.sh and
# build/check-ncz-repo-policy.sh. This file is the SINGLE SOURCE for the
# namespace, the allowlist of intentional Debian-name overrides, the T2 set and
# the pin text; nothing else in the tree may restate them.
#
# Why (operator 2026-10-07, measured on MEDUSA, r200):
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
# Rules the pin file encodes (apt priority = who wins a version contest):
#   NCZ origin, NCZ-reserved namespace (ncz-* cix-* ... kernels)   990
#   NCZ origin, allowlisted intentional Debian-name override       990
#   NCZ origin, any other name (i.e. a Debian-named package)       100  -> Debian (500) wins
#   Debian origin, NCZ-reserved prefixes (ncz-* cix-* cixmini-*)    -1  -> Debian cannot hijack
#   T2 repo, known T2 package names                                990
#   T2 repo, anything else                                         100  -> Debian wins
#   T2 repo, kernel/headers                                         -1
# 990 (not 1000+) on purpose: never forces a downgrade.
#
# Test overrides: NCZ_APT_NCZ_HOSTS / NCZ_APT_T2_HOST may be set before
# sourcing (build/test-apt-separation.sh points them at localhost).

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
# the NCZ suite and win over Debian on an installed system.
ncz_apt_debian_overrides() {
    # Both arches ship the pinned +ncz2 set from the offline mirror (r201: amd64 had shipped +ncz1/stock);
    # etnaviv1/tegra0 are not built for amd64.
    local n why='libdrm ACPI-identity patch for Panthor (build/build-libdrm-debs.sh; pinned set 2.4.134-3+ncz2, release.conf NCZ_LIBDRM_NCZ_REV)'
    printf '%s\t%s\t%s\n' libdrm-common 'all,amd64,arm64' "$why"
    for n in libdrm2 libdrm-amdgpu1 libdrm-dev libdrm-freedreno1 libdrm-intel1 libdrm-nouveau2 libdrm-radeon1; do   # arch 'all' = the registry spelling of a ${ARCH} row
        printf '%s\t%s\t%s\n' "$n" 'all,amd64,arm64' "$why"
    done
    for n in libdrm-etnaviv1 libdrm-tegra0; do
        printf '%s\t%s\t%s\n' "$n" arm64 "$why"
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

# The known T2 package set from the third-party t2-ubuntu-repo (Ubuntu-built).
# None of these names exist in Debian. post-install/55-t2-firmware.sh installs
# apple-firmware-script and apple-t2-audio-config; the rest are the DKMS and
# daemon packages the t2linux project ships for the same hardware.
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
    local ns resv allow t2 h
    ns="$(ncz_apt_namespace_patterns | _ncz_apt_join)"
    resv="$(ncz_apt_reserved_prefixes | _ncz_apt_join)"
    allow="$(ncz_apt_debian_overrides | cut -f1 | _ncz_apt_join)"
    t2="$(ncz_apt_t2_packages | _ncz_apt_join)"
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
# Third-party t2-ubuntu-repo (Ubuntu-built). Only the known T2 set may win;
# everything else it carries ranks below Debian; it never supplies a kernel.
Package: linux-image-* linux-headers-* linux-t2*
Pin: origin $NCZ_APT_T2_HOST
Pin-Priority: -1

Package: $t2
Pin: origin $NCZ_APT_T2_HOST
Pin-Priority: 990

Package: *
Pin: origin $NCZ_APT_T2_HOST
Pin-Priority: 100

# Intel OpenVINO repo (suite ubuntu24, written by the deferred ncz-intel-accel-setup).
# The deferred install is an UNPINNED apt-get install, so the pin decides:
# libopenvino-intel-* comes from Intel (Debian forky ships same-named plugin packages with
# other versions); the Level Zero / OpenCL runtime comes from Debian forky even if the Intel
# repo carries an Ubuntu build of it. Nothing here refers to the install medium (gone after install),
# and no other Intel package is demoted.
Package: libopenvino-intel-*
Pin: origin $NCZ_APT_INTEL_HOST
Pin-Priority: 990

Package: intel-opencl-icd libze1 libze-intel-gpu1
Pin: origin $NCZ_APT_INTEL_HOST
Pin-Priority: 100
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
# single-PUT limit rejects; operator directive 2026-07-26). R2 stays installed
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
