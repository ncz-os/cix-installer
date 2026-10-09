#!/bin/bash
# intel-accel.sh -- Intel GPU / NPU userspace (OpenCL, VA-API, Level Zero,
# OpenVINO plugins) for amd64, with a deferred retry when the network is not
# up at install time. Sourced by post-install/54-gpu-accel.sh; installed as
# /usr/local/sbin/ncz-intel-accel-setup and run by ncz-intel-accel-setup.timer.
#
# r201 (PEGASUS has no OpenVINO / Level Zero userspace): the hook curled
#   https://apt.repos.intel.com/openvino/2026/GPG-PUB-KEY-INTEL-OPENVINO-2026
# which answers HTTP 403, so the key fetch failed on EVERY install, network or
# not, and the stack was skipped with no retry. It also asked for `openvino`,
# `intel-driver-compiler-npu`, `intel-level-zero-npu` and `level-zero`, none of
# which the ubuntu24 component publishes (checked 2026-10-07: it carries only
# versioned libopenvino-*-<ver> packages), so the transaction could not succeed.
#
# Now:
#   * the signing key is vendored (assets/intel/GPG-PUB-KEY-INTEL-SW-PRODUCTS.PUB,
#     Intel's published apt key; it verifies the ubuntu24 InRelease), checked
#     against a pinned sha256 -- no network needed for the key;
#   * Level Zero, the OpenCL ICD and the VA driver come from Debian (libze1,
#     libze-intel-gpu1, intel-opencl-icd, intel-media-va-driver); only the
#     OpenVINO core/GPU/NPU packages come from Intel's repo at the exact reviewed
#     version, with package identity and sha256 checked before apt installs them;
#   * the Debian-origin packages are seeded in manifests/desktop-amd64.pkgs and are
#     installed FIRST, with no Intel index needed, so an offline install, the KVM
#     gate and an install without a link still get them from the mirror; packages
#     already installed are skipped without calling apt. Only the OpenVINO plugins
#     wait for the Intel repo (deferred timer);
#   * every transaction is simulated first (apt-get install -s); any removal
#     refuses it -- nothing is forced. Simulated on debian:forky 2026-10-07:
#     GPU set 15 installs / 0 removals, NPU set 7 / 0;
#   * the separately distributed NPU user-mode driver is NOT approved here;
#     having an NPU plugin installed is not proof of a working NPU driver;
#   * a failure that can heal (no network, repo unreachable, download error)
#     leaves /var/lib/ncz/intel-accel.pending and enables the timer, which
#     retries after boot (2 min, then every 10 min, at most NCZ_INTEL_MAX_TRIES).
#
# Test seams: NCZ_INTEL_ROOT (prefix for every file path), NCZ_INTEL_ASSETS.
# Tested by build/test-intel-accel-deferred.sh.

NCZ_INTEL_KEY_SHA256=db932ba032a71f732dc415eef5f4f185fc7ae768487d7a357bc2772746b6c48c
NCZ_INTEL_KEY_URL="${NCZ_INTEL_KEY_URL:-https://apt.repos.intel.com/intel-gpg-keys/GPG-PUB-KEY-INTEL-SW-PRODUCTS.PUB}"
NCZ_INTEL_REPO="https://apt.repos.intel.com/openvino ubuntu24 main"
NCZ_INTEL_OPENVINO_VERSION=2026.4.1.22982

# Exact vendor bytes verified against Intel's signed ubuntu24 index, then
# installed successfully with dependencies from the pinned Forky snapshot.
# Keep these rows identical to manifests/vendor-debs.tsv. No environment override.
ncz_intel_openvino_hashes() {
    printf '%s\n' \
        'libopenvino-2026.4.1 ce8a501d7fabcee72ed4c32328f90ff853812dba64b611c137bca12c733246a7' \
        'libopenvino-intel-gpu-plugin-2026.4.1 71d2c0157ec1662dcf65fb83d734a53e1e7f6a297de8c88f835c22ac7a35bb0a' \
        'libopenvino-intel-npu-plugin-2026.4.1 57e6064917e141b01f7d451e56a3776c2ea01e3b1ad5a21933d3559d0a0a08bb'
}

# Also written here for already-installed systems that have not yet received
# ncz-apt-policy 1.0.3. Prevent Intel from supplying any Debian prerequisite or
# a newer unreviewed build of the same versioned package name.
ncz_intel_write_pins() {
    local pref="$(_ni_r)/etc/apt/preferences.d/09-ncz-intel-openvino.pref"
    mkdir -p "$(dirname "$pref")"
    cat > "$pref" <<EOF
Package: libopenvino-2026.4.1 libopenvino-intel-gpu-plugin-2026.4.1 libopenvino-intel-npu-plugin-2026.4.1
Pin: version $NCZ_INTEL_OPENVINO_VERSION
Pin-Priority: 990

Package: libopenvino-2026.4.1 libopenvino-intel-gpu-plugin-2026.4.1 libopenvino-intel-npu-plugin-2026.4.1
Pin: version *
Pin-Priority: -1

Package: *
Pin: origin apt.repos.intel.com
Pin-Priority: -1
EOF
}

_ni_r()      { printf '%s' "${NCZ_INTEL_ROOT:-}"; }
_ni_keyring() { echo "$(_ni_r)/etc/apt/keyrings/intel-openvino.gpg"; }
_ni_pending() { echo "$(_ni_r)/var/lib/ncz/intel-accel.pending"; }
_ni_statusf() { echo "$(_ni_r)/var/lib/ncz/intel-accel.status"; }
ncz_intel_log() { echo "[intel-accel] $*"; }
ncz_intel_status() { mkdir -p "$(dirname "$(_ni_statusf)")"; echo "$1" > "$(_ni_statusf)"; ncz_intel_log "status: $1"; }

# Keyring from the vendored key (sha256-pinned); network fetch only as fallback.
ncz_intel_keyring() {
    _kr=$(_ni_keyring)
    [ -s "$_kr" ] && return 0
    mkdir -p "$(dirname "$_kr")"
    _src="${NCZ_INTEL_ASSETS:-$(_ni_r)/usr/local/lib/cix-installer/assets/intel}/GPG-PUB-KEY-INTEL-SW-PRODUCTS.PUB"
    _tmp="$_kr.download"
    if [ -s "$_src" ]; then
        cp "$_src" "$_tmp"
    elif ! curl -fsSL --max-time 30 "$NCZ_INTEL_KEY_URL" -o "$_tmp" 2>/dev/null; then
        rm -f "$_tmp"; ncz_intel_log "WARN: no vendored key and the key download failed"; return 1
    fi
    if [ "$(sha256sum "$_tmp" | cut -d' ' -f1)" != "$NCZ_INTEL_KEY_SHA256" ]; then
        rm -f "$_tmp"; ncz_intel_log "ERROR: Intel key sha256 mismatch -- refusing it"; return 1
    fi
    gpg --dearmor < "$_tmp" > "$_kr" 2>/dev/null && [ -s "$_kr" ] || { rm -f "$_tmp" "$_kr"; return 1; }
    rm -f "$_tmp"
    return 0
}

ncz_intel_repo() {
    _list="$(_ni_r)/etc/apt/sources.list.d/intel-openvino.list"
    mkdir -p "$(dirname "$_list")"
    cat > "$_list" <<EOF
# Written by post-install/lib/intel-accel.sh (54-gpu-accel.sh / ncz-intel-accel-setup).
# Intel publishes OpenVINO only under ubuntuNN components; only the versioned
# libopenvino-* plugins are taken from here, everything else comes from Debian.
deb [signed-by=/etc/apt/keyrings/intel-openvino.gpg] $NCZ_INTEL_REPO
EOF
}

# ncz_intel_debian_packages GPU NPU -> the Debian-origin packages (Level Zero
# loader + Intel GPU driver, OpenCL ICD, VA driver) minus the ones already
# installed. These are seeded in manifests/desktop-amd64.pkgs, so they resolve
# from the offline mirror with no network and with no Intel repo index.
ncz_intel_debian_packages() {
    _d=""
    [ "$1" = 1 ] && _d="intel-opencl-icd intel-media-va-driver libze1 libze-intel-gpu1"
    [ "$2" = 1 ] && _d="$_d libze1"
    for _p in $(echo "$_d" | tr ' ' '\n' | sed '/^$/d' | sort -u); do
        dpkg-query -W -f='${Status}' "$_p" 2>/dev/null | grep -q '^install ok installed' || printf '%s ' "$_p"
    done
}

# ncz_intel_packages GPU NPU -> exact version-qualified Intel packages.
ncz_intel_packages() {
    [ "$1" = 1 ] || [ "$2" = 1 ] || return 0
    printf '%s ' "libopenvino-2026.4.1=$NCZ_INTEL_OPENVINO_VERSION"
    [ "$1" != 1 ] || printf '%s ' "libopenvino-intel-gpu-plugin-2026.4.1=$NCZ_INTEL_OPENVINO_VERSION"
    if [ "$2" = 1 ]; then
        printf '%s ' "libopenvino-intel-npu-plugin-2026.4.1=$NCZ_INTEL_OPENVINO_VERSION"
        ncz_intel_log 'NPU: separate user-mode driver not installed by this OpenVINO transaction; hardware acceptance remains required' >&2
    fi
}

# Signed-index APT download, then independently bound bytes/control identity.
# Only verified local debs enter the simulated/real APT transaction. Owned
# download scratch is removed on every normal success/failure path.
ncz_intel_openvino_install() (
    local cache work p name file expected identity rc
    local -a files=()
    cache="$(_ni_r)/var/cache/ncz/intel-openvino"
    mkdir -p "$cache" || return 75
    work=$(mktemp -d "$cache/download.XXXXXX") || return 75
    trap 'rm -rf "$work"' EXIT
    for p in "$@"; do
        name=${p%%=*}
        expected=$(ncz_intel_openvino_hashes | awk -v n="$name" '$1==n {print $2}')
        [ -n "$expected" ] && [ "$p" = "$name=$NCZ_INTEL_OPENVINO_VERSION" ] || {
            ncz_intel_status 'failed:unapproved-openvino-package'; return 1;
        }
        (cd "$work" && apt-get download "$p") || return 75
        file="$work/${name}_${NCZ_INTEL_OPENVINO_VERSION}_amd64.deb"
        identity=$(dpkg-deb -f "$file" Package Version Architecture 2>/dev/null) || {
            ncz_intel_status 'failed:invalid-openvino-deb'; return 1;
        }
        if [ "$identity" != "$(printf 'Package: %s\nVersion: %s\nArchitecture: amd64' "$name" "$NCZ_INTEL_OPENVINO_VERSION")" ] ||
           [ "$(sha256sum "$file" | cut -d' ' -f1)" != "$expected" ]; then
            ncz_intel_status 'failed:openvino-identity-or-hash'; return 1
        fi
        files+=("$file")
    done
    ncz_intel_apt_install "${files[@]}"; rc=$?
    return "$rc"
)

# ncz_intel_apt_install PKGS... -> 0 installed, 75 retry later, 1 refused.
# Simulated first; any removal refuses the whole transaction.
ncz_intel_apt_install() {
    ncz_intel_log "packages: $*"
    _sim=$(LC_ALL=C apt-get install -s --no-install-recommends "$@" 2>&1) && _rc=0 || _rc=$?
    if [ "$_rc" -ne 0 ]; then
        printf '%s\n' "$_sim" | tail -5
        ncz_intel_log "simulation failed (rc=$_rc)"; return 75
    fi
    _rm=$(printf '%s\n' "$_sim" | grep -c '^Remv ' || true)
    if [ "$_rm" -gt 0 ]; then
        printf '%s\n' "$_sim" | grep '^Remv ' | head -10
        ncz_intel_status "failed:would-remove-$_rm-packages"; return 1
    fi
    if DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@" 2>&1 | tail -10; then
        [ "${PIPESTATUS[0]:-0}" -eq 0 ] || return 75
    else
        return 75
    fi
    return 0
}

# ncz_intel_setup GPU NPU -> 0 done, 75 retry later, 1 refused/permanent
ncz_intel_setup() {
    # The Debian-origin set needs neither the Intel key nor the Intel repo, so a missing key must not
    # keep it from installing: only the OpenVINO plugins (Intel repo) wait for the key.
    _key=0
    ncz_intel_write_pins || return 1
    if ncz_intel_keyring; then _key=1; ncz_intel_repo; fi
    apt-get update 2>&1 | tail -3
    # Debian-origin packages first: they need no Intel index, so an offline
    # install (mirror seeds) or an install without a link still gets them.
    # Already-installed packages are skipped without calling apt at all.
    _dp=$(ncz_intel_debian_packages "$1" "$2")
    if [ -n "${_dp// /}" ]; then
        # shellcheck disable=SC2086
        ncz_intel_apt_install $_dp || return $?
    fi
    [ "$_key" = 1 ] || { ncz_intel_log "Intel signing key unavailable; OpenVINO plugins deferred"; return 75; }
    _pk=$(ncz_intel_packages "$1" "$2") || return 1
    [ -n "${_pk// /}" ] || { ncz_intel_log "nothing more requested (GPU=$1 NPU=$2)"; return 0; }
    # shellcheck disable=SC2086
    ncz_intel_openvino_install $_pk
}

ncz_intel_arm_retry() {   # GPU NPU
    mkdir -p "$(dirname "$(_ni_pending)")"
    printf 'GPU=%s\nNPU=%s\nTRIES=0\n' "$1" "$2" > "$(_ni_pending)"
    _sd="$(_ni_r)/etc/systemd/system"
    _as="${NCZ_INTEL_ASSETS:-$(_ni_r)/usr/local/lib/cix-installer/assets/intel}"
    mkdir -p "$_sd/timers.target.wants" "$(_ni_r)/usr/local/sbin"
    install -m0644 "$_as/ncz-intel-accel-setup.service" "$_sd/ncz-intel-accel-setup.service"
    install -m0644 "$_as/ncz-intel-accel-setup.timer" "$_sd/ncz-intel-accel-setup.timer"
    install -m0755 "${NCZ_INTEL_LIB_SRC:-$(_ni_r)/usr/local/lib/cix-installer/post-install/lib/intel-accel.sh}" \
        "$(_ni_r)/usr/local/sbin/ncz-intel-accel-setup"
    ln -sf ../ncz-intel-accel-setup.timer "$_sd/timers.target.wants/ncz-intel-accel-setup.timer"
    ncz_intel_status "pending:retry-after-boot"
}

ncz_intel_finish() {
    rm -f "$(_ni_pending)" "$(_ni_r)/etc/systemd/system/timers.target.wants/ncz-intel-accel-setup.timer"
}

# Install-time entry (54-gpu-accel.sh).
ncz_intel_accel_install() {   # GPU NPU
    ncz_intel_setup "$1" "$2" && _rc=0 || _rc=$?
    case "$_rc" in
        0)  ncz_intel_status "done"; ncz_intel_finish ;;
        75) ncz_intel_log "not finished at install time; ncz-intel-accel-setup.timer retries after boot"; ncz_intel_arm_retry "$1" "$2" ;;
        *)  ncz_intel_finish ;;
    esac
    return 0
}

# Deferred entry: ncz-intel-accel-setup run
ncz_intel_accel_run() {
    _pf=$(_ni_pending)
    [ -r "$_pf" ] || { ncz_intel_log "nothing pending"; return 0; }
    _g=$(sed -n 's/^GPU=//p' "$_pf"); _n=$(sed -n 's/^NPU=//p' "$_pf"); _t=$(sed -n 's/^TRIES=//p' "$_pf")
    _t=$(( ${_t:-0} + 1 ))
    sed -i "s/^TRIES=.*/TRIES=$_t/" "$_pf"
    ncz_intel_log "attempt $_t (GPU=$_g NPU=$_n)"
    ncz_intel_setup "${_g:-0}" "${_n:-0}" && _rc=0 || _rc=$?
    if [ "$_rc" = 0 ]; then ncz_intel_status "done"; ncz_intel_finish; return 0; fi
    if [ "$_rc" = 75 ] && [ "$_t" -lt "${NCZ_INTEL_MAX_TRIES:-36}" ]; then ncz_intel_status "pending:attempt-$_t"; return 75; fi
    [ "$_rc" = 75 ] && ncz_intel_status "failed:gave-up-after-$_t-attempts"
    ncz_intel_finish
    return 1
}

if [ "${NCZ_INTEL_ACCEL_LIB:-0}" != 1 ] && [ "${1:-}" = run ]; then
    ncz_intel_accel_run
    exit $?
fi
