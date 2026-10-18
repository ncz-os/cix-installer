#!/bin/bash
# amd-accel.sh -- AMD GPU / NPU userspace (Vulkan compute, XDNA/xdna driver,
# XRT runtime, NPU inference library) for amd64, with a deferred retry when
# the network is not up at install time. Sourced by post-install/54-gpu-accel.sh;
# installed as /usr/local/sbin/ncz-amd-accel-setup and run by
# ncz-amd-accel-setup.timer.
#
# Architecture mirrors post-install/lib/intel-accel.sh (the reference design),
# adapted for the facts of the AMD stack as verified live on real AMD hosts
# (ACHILLES, 192.168.207.11 and HYDRA, 192.168.207.78, both Ryzen
# Strix/Phoenix 1022:1502 "AMD IPU Device" NPUs + 1002:15bf "Phoenix1" iGPUs,
# 2026-10-17):
#
#   * GPU compute needs NO native NCZ package at all. Verified live: Debian
#     mesa-vulkan-drivers (RADV) + libvulkan1 alone ship a working Vulkan
#     ICD for AMD GPUs (radeon_icd.json -> libvulkan_radeon.so, RADV). The
#     GPU half of this lib is therefore Debian-only: it installs the
#     Debian-origin package set with no native-candidate gate, exactly like
#     the Debian set on the Intel path. No candidate probe, no 75, no
#     deferral on the GPU class. (ROCm/OpenCL is out of scope here: 54
#     already wires the ROCm Debian packages on the NVIDIA-free path.)
#
#   * The NPU half is the native-NCZ-only acquisition (no vendor repo, no
#     key fetch -- the signed NCZ source is supplied by hook24,
#     24-apt-sources.sh via apt-separation.sh). This lib never fetches a
#     key, never writes a repo.radeon.com sources.list entry, and never
#     trusts a vendor origin. If the native NCZ NPU package is not yet
#     published, the install reports honest deferred/retry state; it does
#     NOT fall back to a vendor origin.
#
# Native NCZ candidate names (the namespace convention, built against
# Debian; amd64). NOTE: as of 2026-10-17 the AMD native NCZ namespace is
# NOT PUBLISHED YET (apt-cache search amdxdna/rocm on an onboarded host
# returns nothing) -- this is the expected state this lib is written
# against, not a bug. The convention below mirrors Intel's
# libopenvino-intel-*-plugin-<ver> style: a <name>-<version> artifact
# prefix for the plugin/library artifacts, plus a fixed driver/runtime
# D-set (single-version candidates, matching the Intel D-set shape).
#   C) amd-npu-xrt-<ver>               XRT/xdna userspace runtime
#      amd-npu-infer-<ver>              NPU inference library
#   D) amd-xdna-driver, amd-xdna-firmware,
#      amd-xdna-runtime, amd-xdna-validation
#      (artifacts in flight -- the amdxdna kernel module is built upstream
#       by the NCZ kernel overlay; these four D components carry the
#       userspace runtime, firmware, and validation tools the NPU userspace
#       must not be silently skipped without.)
#
# Debian-origin runtime (kept -- install from the configured Debian suite,
# independent of native availability; no native index needed):
#   GPU: mesa-vulkan-drivers, libvulkan1, libgl1-mesa-dri
#   NPU: (none -- the XDNA stack is native-NCZ-only, see above)
#
# Rules this lib encodes (the caller / test can rely on):
#   * The Debian GPU set is installed first, NO native index needed. A
#     network-down install still gets it from the offline mirror.
#   * Already-installed packages are skipped without calling apt.
#   * Every apt transaction is simulated first (apt-get install -s); a sim
#     that reports ANY `Remv ` refuses the whole install (status:
#     `failed:would-remove-N-packages`, return 1, no endless retry).
#   * Sim and real install use the SAME expanded args array (including
#     `-y` and `--no-install-recommends`); no --force-yes, no
#     --allow-downgrades, no `-o APT::Get::AllowUnauthenticated=true`.
#   * The NPU user-mode driver/runtime + firmware set (D above) is
#     required when NPU=1 is requested: if ANY of `amd-xdna-driver`,
#     `amd-xdna-firmware`, `amd-xdna-runtime`, `amd-xdna-validation` is
#     missing from the index, the install returns 75 (retry later) and
#     does NOT mark `done`. NPU userspace must not be silently skipped.
#   * GPU-only / NPU-only / both-zero selectors are all handled.
#   * Apt index update is fail-closed (ErrorMode-any) yet an offline
#     install with already-seeded Debian packages still works.
#
# Retry policy (mirrors intel-accel.sh 2026-10-17, PROTEUS defect:
# failed:gave-up-after-36-attempts on a Preview2-era install whose native
# candidates were simply not yet published -- 10-minute retries are
# exhausted long before the native packages are published, and the pending
# marker is then dropped so NO later publish ever triggers the install):
#   * Fast budget: while TRIES < NCZ_AMD_MAX_TRIES (36) the deferred unit
#     retries at the timer cadence (10 min). The counter lives in the
#     pending marker and is RESUMED by every timer `run`: the only code
#     that re-arms is ncz_amd_recover (on a gave-up status) and the
#     install-time entry, so a run that reset TRIES would restart the same
#     budget forever and the give-up below could never be reached.
#     Only an explicit re-arm (`rearm`, or recover's re-arm) starts a new
#     budget, and that new budget is bounded like any other.
#   * A 75 that is caused ONLY by native candidates missing from a FRESHLY
#     FETCHED index (i.e. apt-get update succeeded and the only gap is the
#     missing native NPU plugin or NPU-driver candidates; every
#     Debian-origin package already resolves) is "transient publication
#     lag", not a broken system. After the fast budget it DEFERS instead
#     of giving up: the pending marker is kept, the status is
#     `deferred:native-candidates-unpublished`, and the deferred run exits
#     0 (SuccessExitStatus). The pending marker keeps
#     ncz-amd-accel-setup active, so the next apt index refresh that
#     publishes the candidates (e.g. ncz-update-apply, which forces a
#     re-check) or any re-arm installs the stack then. The 10-min timer
#     keeps firing on the marker, but a deferred run re-checks the index
#     (apt-get update) at most once per NCZ_AMD_DEFER_SECS (default 1 day,
#     LAST= in the marker).
#   * Network-down (no fresh index fetch possible) and would-remove
#     refusals keep the old semantics: after the budget they stay failed /
#     refused and the marker is dropped (no endless 10-min loop;
#     ncz_amd_recover re-arms them once hardware is confirmed again).
#   * Recovery: on every re-run of the deferred entry (`ncz-amd-accel-setup
#     rearm` / `run`) a system left at `failed:gave-up-*` is re-armed when
#     AMD GPU or NPU hardware is still present (ncz_amd_recover, invoked
#     from the deferred entry and from ncz-update-apply), requesting only
#     the classes still present (GPU and/or NPU). This makes a shipped
#     upgrade of the installer payload revive gave-up machines. The
#     re-armed install gets a fresh, bounded budget: the recovery run
#     counts attempt 1 and the next failures count down as usual, so a
#     machine whose network is still down is not handed an unbounded loop.
#
# Return codes from ncz_amd_setup / ncz_amd_accel_install / _run:
#   0  complete (all requested classes installed)
#   1  refused (simulation would remove packages; never silently marks
#      done)
#   75 retry later (network down / index missing / native NPU candidates
#      not yet published; leaves /var/lib/ncz/amd-accel.pending and arms
#      the timer)
#
# Test seams: NCZ_AMD_ROOT (prefix for every file path), NCZ_AMD_ASSETS,
# NCZ_AMD_NPU_AVAILABLE / NCZ_AMD_NPU_DRIVERS_AVAILABLE env toggles used by
# build/test-amd-accel-deferred.sh to mock native candidate availability.
# Tested by build/test-amd-accel-deferred.sh and the NPU-driver /
# would-remove cases added in that test.

_na_r()      { printf '%s' "${NCZ_AMD_ROOT:-}"; }
_na_pending() { echo "$(_na_r)/var/lib/ncz/amd-accel.pending"; }
_na_statusf() { echo "$(_na_r)/var/lib/ncz/amd-accel.status"; }
ncz_amd_log() { echo "[amd-accel] $*"; }
ncz_amd_log_err() { echo "[amd-accel] $*" >&2; }
ncz_amd_status() { mkdir -p "$(dirname "$(_na_statusf)")"; echo "$1" > "$(_na_statusf)"; ncz_amd_log "status: $1"; }

# Scratch directory for the lib's own temporary files. It lives under the
# same NCZ_AMD_ROOT prefix as every other path this lib touches (so the
# test fixture stays inside its sandbox) and never uses world-shared /tmp.
# Prints the directory on success; when it cannot be created the caller
# must skip the file entirely rather than retarget itself at /tmp.
_ncz_amd_tmpdir() {
    local d="${NCZ_AMD_TMPDIR:-$(_na_r)/var/lib/ncz/tmp}"
    mkdir -p "$d" 2>/dev/null && printf '%s\n' "$d"
}

# ncz_amd_setup clears these at entry; the probe helpers set them. The
# DEFERRED flag means "rc 75 is caused ONLY by native NPU candidates
# missing from the index": the index itself fetched fine (apt-get update
# succeeded, so the network is up) and the ONLY gap is that the requested
# native NCZ NPU plugin / NPU-driver candidates are not published yet.
# Only that class of 75 is allowed to fall back to the slow (deferred)
# retry after the fast budget; network-down (fresh index not fetchable)
# and would-remove keep their current semantics.
NCZ_AMD_DEFERRED=0

ncz_amd_clear_deferred() {
    NCZ_AMD_DEFERRED=0
}

# True when the configured apt sources (under NCZ_AMD_ROOT) contain NO
# remote (http/https) origin: an all-local (file:/mirror-only) index is
# never a fresh fetch, so a successful apt-get update there proves nothing
# about publication lag. A missing candidate on such a system must NOT be
# treated as deferred-unpublished.
# _ncz_amd_has_remote_uri FILE -> 0 when an ACTIVE deb/deb-src line or a
# deb822 "URIs:" value names at least one remote URI. Each URI scheme is
# judged on its own, so a deb822 line listing a file: mirror AND an https
# origin still counts as remote. Remote = any scheme:// other than the
# local file:// and copy:// (cdrom: URIs carry no "//"). One pipeline, so
# no `a || b` status masking.
_ncz_amd_has_remote_uri() {
    # Disabled sources fetch nothing: drop deb822 stanzas with "Enabled: no"
    # and one-line entries with an [enabled=no] option first (apt booleans:
    # no/false/off/0/without/disable). apt ends a
    # line at "#", so a URL in a trailing comment is not an origin either.
    # deb822 fields may fold onto indented continuation lines ("URIs: a"
    # then " b"): join them first so every URI is on its field line.
    awk 'BEGIN { RS = "" }
         /(^|\n)(Types|URIs|Suites):/ { gsub(/\n[ \t]+/, " ") }
         !/(^|\n)[[:space:]]*[Ee]nabled:[[:space:]]*([Nn][Oo]|[Ff][Aa][Ll][Ss][Ee]|[Oo][Ff][Ff]|0|[Ww][Ii][Tt][Hh][Oo][Uu][Tt]|[Dd][Ii][Ss][Aa][Bb][Ll][Ee])[[:space:]]*(\n|$)/ { print }' "$1" 2>/dev/null \
         | grep -E '^[[:space:]]*(deb(-src)?[[:space:]]|URIs:[[:space:]])' \
         | grep -viE '^[[:space:]]*deb(-src)?[[:space:]]+\[[^]]*enabled=(no|false|off|0|without|disable)([[:space:]]|\])' \
         | sed 's/#.*//' \
         | grep -oE '[a-z][a-z0-9+.-]*://' \
         | grep -vqE '^(file|copy)://'
}

_ncz_amd_repos_all_local() {
    local base f
    # apt reads sources.list.d/*.list|*.sources plus etc/apt/sources.list
    # (checked below); other files directly under etc/apt are not sources.
    base="$(_na_r)/etc/apt/sources.list.d"
    # *.list may be a SYMLINK to a managed config file (common on
    # Debian); -f follows symlinks, so those are read like any other
    # real file.
    for f in "$base"/*.list "$base"/*.sources; do
        # No match (or no directory) leaves the literal pattern as $f: not a
        # regular file (a dangling symlink is not one either), so skip it.
        [ -f "$f" ] || continue
        # (55-t2-firmware backups are NAME.list.disabled-for-build[.XXXXXX]:
        # they do not end in .list/.sources, so the glob never sees them and
        # apt never reads them; a file that does end in .list is read by apt)
        # Any ACTIVE remote-origin deb line disqualifies "all local".
        # deb822 (.sources) files use "URIs: <uri>"; check both shapes.
        if _ncz_amd_has_remote_uri "$f"; then
            return 1
        fi
    done
    # An inline deb line in the root sources.list counts too.
    f="$(_na_r)/etc/apt/sources.list"
    if [ -f "$f" ] && _ncz_amd_has_remote_uri "$f"; then
        return 1
    fi
    return 0
}

# ncz_amd_disable_legacy_vendor_list FILE -> comments out ONLY the active
# deb/deb-src lines in FILE whose actual URI matches the known AMD vendor
# repos (repo.radeon.com -- ROCm/amdgpu; and apt.repos.intel.com is NOT an
# AMD host and is NOT recognized here). The original bytes are preserved in
# a unique ${f}.disabled-for-build.XXXXXX backup; unrelated active lines
# and comments are preserved verbatim. Must NOT be called on a file ending
# in .disabled-for-build.
#
# Mirrors post-install/lib/intel-accel.sh's ncz_intel_disable_legacy_vendor_list
# (same URL-skip-bracket-options parsing, same unique-backup discipline, same
# honest-on-failure behaviour). The URL literals ARE referenced on purpose:
# the disabler MUST recognize the legacy host pattern, so the test cannot
# ban this token outright -- grep tests strip leading `#`/comment-only lines.
ncz_amd_disable_legacy_vendor_list() {
    local f="$1" tmp bak
    [ -f "$f" ] || return 0
    case "$f" in
        *.disabled-for-build|*.disabled-for-build.*) return 0 ;;
    esac
    # Refuse symlinks: rewriting through a symlink could clobber an unrelated
    # target. Honest failure rather than a silent skip.
    if [ -L "$f" ]; then
        ncz_amd_log_err "$f is a symlink; refusing to rewrite (leaving untouched)"
        return 1
    fi
    tmp=$(mktemp "${f}.ncz.XXXXXX") || {
        ncz_amd_log_err "could not create temp file next to $f; leaving it untouched"
        return 1
    }
    if ! cp -p "$f" "$tmp"; then
        ncz_amd_log_err "could not copy $f to temp; leaving it untouched"
        rm -f "$tmp"
        return 1
    fi
    # Rewrite: comment out ONLY active deb/deb-src lines whose actual URI
    # matches the known legacy AMD vendor host. Everything else is emitted
    # verbatim.
    if ! awk '
        /^[[:space:]]*deb(-src)?[[:space:]]/ {
            uri = ""
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^[A-Za-z][A-Za-z0-9+.-]*:\/\//) { uri = $i; break }
            }
            if (uri ~ /^https?:\/\/(repo\.radeon\.com|www\.amd\.com\/community)\/(rocm|amdgpu)(\/|$)/) {
                print "# [amd-accel] disabled legacy vendor source: " $0
                next
            }
        }
        { print }
    ' "$f" > "$tmp"; then
        ncz_amd_log_err "awk rewrite failed for $f; leaving it untouched"
        rm -f "$tmp"
        return 1
    fi
    if cmp -s "$f" "$tmp"; then
        rm -f "$tmp"
        return 0
    fi
    bak=$(mktemp "${f}.disabled-for-build.XXXXXX") || {
        ncz_amd_log_err "could not create backup for $f; leaving it untouched"
        rm -f "$tmp"
        return 1
    }
    if ! cp -p "$f" "$bak"; then
        ncz_amd_log_err "could not write backup $bak; leaving $f untouched"
        rm -f "$tmp" "$bak"
        return 1
    fi
    if ! mv "$tmp" "$f"; then
        ncz_amd_log_err "could not replace $f atomically; original preserved, backup at $bak"
        rm -f "$tmp"
        return 1
    fi
    ncz_amd_log "disabled known legacy vendor source line(s) in $f (backup: ${bak##*/})"
    return 0
}

# ncz_amd_debian_packages GPU NPU -> the Debian-origin packages (Vulkan
# loader + Mesa RADV ICD, OpenCL ICD) minus the ones already installed.
# These are seeded in manifests/desktop-amd64.pkgs, so they resolve from
# the offline mirror with no network and with no AMD/NCZ index. The NPU
# set is empty: the XDNA runtime is native-NCZ-only (see header).
ncz_amd_debian_packages() {
    _d=""
    [ "$1" = 1 ] && _d="mesa-vulkan-drivers libvulkan1 libgl1-mesa-dri"
    [ "$2" = 1 ] && _d="$_d libvulkan1"
    for _p in $(echo "$_d" | tr ' ' '\n' | sed '/^$/d' | sort -u); do
        dpkg-query -W -f='${Status}' "$_p" 2>/dev/null | grep -q '^install ok installed' || printf '%s ' "$_p"
    done
}

# ncz_amd_native_npu_vers NPU -> prints "NPUVER" of the latest available
# native NPU runtime version on stdout ("0" when NPU is not requested).
# Returns non-zero when the requested class has NO candidate in any
# configured apt repo (i.e. the native NCZ suite has not yet published the
# NPU runtime). This is the ONLY place that decides "can we install the NPU
# runtime at all".
ncz_amd_native_npu_vers() {
    _nv=0
    if [ "$1" = 1 ]; then
        _nv=$(ncz_amd_pick_native_vers amd-npu-xrt-) || return 1
        [ -n "$_nv" ] || return 1
    fi
    printf '%s\n' "$_nv"
}

ncz_amd_pick_native_vers() {
    _pfx=$1; _best=
    for _n in $(apt-cache pkgnames "$_pfx" 2>/dev/null); do
        case "$_n" in "$_pfx"*) ;; *) continue ;; esac
        _c=$(apt-cache policy "$_n" 2>/dev/null \
             | sed -n 's/^[[:space:]]*Candidate:[[:space:]]*//p' | head -1)
        [ -n "$_c" ] || continue
        case "$_c" in "(none)"|"") continue ;; esac
        case "$_c" in *ncz*) ;; *) continue ;; esac
        _s=${_n#"$_pfx"}
        [ -n "$_s" ] || continue
        if [ -z "$_best" ]; then
            _best=$_s
        else
            _hi=$(printf '%s\n%s\n' "$_best" "$_s" | sort -V | tail -1)
            [ "$_hi" = "$_s" ] && _best=$_s
        fi
    done
    [ -n "$_best" ] || return 1
    printf '%s\n' "$_best"
}

# ncz_amd_required_npu_drivers -> prints the set of required NPU
# userspace/firmware package NAMES (one per line, no version). The names
# are the native NCZ D components; they don't carry a version suffix
# because the native suite publishes single-version candidates. The
# function does NOT probe for them: that's ncz_amd_npu_drivers_present
# below. Defined as a separate function so the test can assert the list
# without needing any apt state.
ncz_amd_required_npu_drivers() {
    printf '%s\n' amd-xdna-driver amd-xdna-firmware \
                  amd-xdna-runtime amd-xdna-validation
}

# ncz_amd_npu_drivers_present -> 0 if every required NPU driver/firmware
# package has a real Candidate (numeric version) in the configured repos;
# 1 if any is missing or only "(none)". This is the gate: NPU userspace
# MUST NOT be silently skipped; if any driver is missing the caller
# returns 75 retry and does NOT mark done.
#
# Diagnostic output is written to STDERR (not stdout): the caller's package
# list is built from command-substitution `$(ncz_amd_packages ...)` and any
# diagnostic on stdout would be captured AS a package name and forwarded to
# `apt-get install`, producing a phantom-arg failure.
ncz_amd_npu_drivers_present() {
    for _u in $(ncz_amd_required_npu_drivers); do
        _c=$(apt-cache policy "$_u" 2>/dev/null \
             | sed -n 's/^[[:space:]]*Candidate:[[:space:]]*//p' | head -1)
        [ -n "$_c" ] || { ncz_amd_log_err "NPU driver missing: $_u (no native NCZ candidate yet)"; return 1; }
        case "$_c" in "(none)"|"") ncz_amd_log_err "NPU driver missing: $_u (no native NCZ candidate yet)"; return 1 ;; esac
        case "$_c" in *ncz*) ;; *) ncz_amd_log_err "NPU driver missing: $_u (no native NCZ candidate yet)"; return 1 ;; esac
    done
    return 0
}

# ncz_amd_packages GPU NPU -> the native NCZ package names to install
# (NPU runtime + NPU user-mode drivers) on stdout. The GPU class is
# Debian-only (see header): it contributes NO native candidate here.
# Return codes:
#   0 = all requested classes have candidates (or NPU not requested);
#   1 = a requested class has no candidate (the caller must distinguish:
#       rc=1 from ncz_amd_native_npu_vers means the NPU runtime is not yet
#       published -- a deferrable publication lag, not a connectivity
#       failure. The caller checks NCZ_AMD_INDEX_FRESH to decide.);
#   2 = NPU drivers missing (NPU=1 requested but the D set is incomplete).
# GPU=1 and NPU=1 are independent:
#   * GPU install is handled by the Debian set (no native candidate);
#   * NPU runtime + the four driver/compiler/firmware packages are
#     installed ONLY when NPU=1 AND every required driver has a candidate.
#     If a driver is missing the function returns 2 so the caller knows NPU
#     is still incomplete.
ncz_amd_packages() {
    # Each requested class is resolved on its own. ncz_amd_native_npu_vers
    # fails as a whole when the NPU runtime has no candidate; remember
    # which classes are missing.
    _n=; _missn=0
    if [ "$2" = 1 ]; then
        _n=$(ncz_amd_native_npu_vers "$2") || _n=
        [ -n "$_n" ] || _missn=1
    fi
    _p=""
    _npustate=0
    if [ "$2" = 1 ]; then
        if [ -n "$_n" ] && ncz_amd_npu_drivers_present; then
            _p="amd-npu-xrt-$_n"
            for _u in $(ncz_amd_required_npu_drivers); do
                _p="$_p $_u"
            done
        elif [ -n "$_n" ]; then
            # NPU runtime is NOT safe without its driver/runtime/firmware
            # stack; the caller (rc=2) will defer. Don't include it in the
            # output list; the GPU half (Debian) is still installed.
            _npustate=2
        else
            # The NPU runtime itself is unpublished, so the drivers alone
            # cannot assemble an NPU stack. Same deferral, but the reason is
            # a missing candidate (rc=1 territory) rather than a missing
            # driver set; both are "retry once published", so keep rc=2.
            _npustate=2
        fi
    fi
    echo "$_p" | tr ' ' '\n' | sed '/^$/d' | sort -u | tr '\n' ' '
    # Return value = the first class still missing:
    #   rc 1 -> a native candidate (the NPU runtime) is unpublished;
    #   rc 2 -> the NPU runtime is published but its driver set is not.
    # rc 1 is reported in preference to rc 2: both defer when the index is
    # fresh, but rc 1 also carries the "fresh index" classification.
    if [ "$_missn" = 1 ]; then
        return 1
    fi
    [ "$_npustate" = 0 ] || return "$_npustate"
}

# ncz_amd_apt_install PKGS... -> 0 installed, 1 refused (would-remove),
# 75 retry later (transient: simulation unreachable OR real install
# failed). Sim and real install use the SAME expanded args array
# (NCZ_AMD_APT_BASE_ARGS below, including -y and
# --no-install-recommends; -y is harmless under `-s`). No force /
# allow-downgrades / trust waiver.
NCZ_AMD_APT_BASE_ARGS=( -y --no-install-recommends )
ncz_amd_apt_install() {
    ncz_amd_log "packages: $*"
    _sim=$(LC_ALL=C apt-get install -s "${NCZ_AMD_APT_BASE_ARGS[@]}" "$@" 2>&1); _rc=$?
    if [ "$_rc" -ne 0 ]; then
        printf '%s\n' "$_sim" | tail -5
        ncz_amd_log "simulation failed (rc=$_rc); transient/unavailable -- retry later"
        return 75
    fi
    _rm=$(printf '%s\n' "$_sim" | grep -c '^Remv ')
    if [ "$_rm" -gt 0 ]; then
        printf '%s\n' "$_sim" | grep '^Remv ' | head -10
        ncz_amd_status "failed:would-remove-$_rm-packages"; return 1
    fi
    DEBIAN_FRONTEND=noninteractive apt-get install "${NCZ_AMD_APT_BASE_ARGS[@]}" "$@" 2>&1 | tail -10
    [ "${PIPESTATUS[0]:-0}" -eq 0 ] || return 75
    return 0
}

# ncz_amd_setup GPU NPU -> 0 done, 75 retry later, 1 refused/permanent.
# Native NCZ acquisition only for the NPU half (no key fetch, no repo
# wiring -- the signed NCZ source is supplied by hook24, apt-separation.sh).
# The GPU half is Debian-only. If the index does not yet carry the
# requested native NPU runtime, or any NPU driver is missing, the function
# returns 75 and the caller arms the retry timer.
#
# GPU (Debian) is installed even when NPU drivers are missing (the GPU
# half is independent of the NPU driver stack). The function reports 75
# (not done) when NPU was requested but is still incomplete, so the caller
# arms the timer for the next native publish without falsely marking
# success.
#
# 75 cause classification (deferred-retry policy, mirrors intel-accel.sh
# 2026-10-17): on return, NCZ_AMD_DEFERRED is 1 ONLY when the 75 is caused
# solely by native NPU candidates missing from a freshly fetched index
# (apt-get update succeeded and the sources include a remote origin;
# everything else resolved). That class may fall back to the slow deferred
# retry after the fast budget; every other 75 (network down, probe
# failure, apt install failure) keeps the old semantics.
ncz_amd_setup() {
    ncz_amd_clear_deferred
    # Reversibly move a known-legacy rocm.list aside BEFORE apt-get update
    # so a stray AMD vendor origin cannot shadow the native NCZ suite.
    # Only NCZ_AMD_ROOT is touched (defaults to / for real installs, $W/r
    # for the deferred-retry test fixture).
    ncz_amd_disable_legacy_vendor_list "$(_na_r)/etc/apt/sources.list.d/rocm.list" || return 75
    # Best-effort refresh; offline already-seeded Debian packages still
    # resolve on the mirror with a stale index. Don't fatal on a
    # network-only failure before the staging/debian path runs. No metadata
    # date-check bypass (`Acquire::Check-Date=false`) -- that is an
    # unrelated TUF/Release-date weakness; a cached signed index already
    # on disk is used as-is.
    #
    # A successful refresh of a REMOTE index is the "fresh index fetched"
    # evidence the deferred policy needs: if apt-get update exits 0 while
    # at least one source is a remote (http/https) origin, the index is up
    # to date and a missing native NPU candidate is a PUBLICATION gap, not
    # a connectivity gap. An all-local (file:/mirror) index, or a failed
    # update, never proves that. The flag is set only AFTER the Debian set
    # (which must resolve from the same index) is handled: if the Debian
    # set install fails, the index was not usable for the runtime either
    # and the 75 must NOT be misclassified as publication lag.
    # The update runs OUTSIDE a pipeline: `_updrc=$?` is then the real
    # apt-get status under ANY POSIX shell (the lib is sourced by the
    # installer's bash hooks, but this exact status is what decides
    # deferred-vs-gave-up, so it must not depend on a bash-only PIPESTATUS).
    _ud=$(_ncz_amd_tmpdir)
    if [ -n "$_ud" ]; then
        _ulog="$_ud/amd-accel-update.log"
        apt-get update >"$_ulog" 2>&1
        _updrc=$?
        tail -3 "$_ulog"
        rm -f "$_ulog"
    else
        # No scratch dir: still capture the real status, just not the log.
        apt-get update >/dev/null 2>&1
        _updrc=$?
    fi
    # Debian-origin packages first: they need no native index, so an
    # offline install (mirror seeds) or an install without a link still
    # gets them. Already-installed packages are skipped without calling
    # apt at all.
    _dp=$(ncz_amd_debian_packages "$1" "$2")
    if [ -n "${_dp// /}" ]; then
        # shellcheck disable=SC2086
        ncz_amd_apt_install $_dp || return $?
    fi
    if [ "${_updrc:-1}" -eq 0 ] && ! _ncz_amd_repos_all_local; then
        NCZ_AMD_INDEX_FRESH=1
    else
        NCZ_AMD_INDEX_FRESH=0
    fi
    _pk=$(ncz_amd_packages "$1" "$2")
    _rc=$?
    case "$_rc" in
        0) _npustate=0 ;;
        1)
            # The NPU runtime has no candidate. Install the class that IS
            # available first (GPU is Debian, already handled above; if NPU
            # is the only class requested there is nothing native to
            # install now). Then classify the gap. When the index is fresh
            # (remote sources, apt-get update succeeded, Debian set
            # resolved) this is a PUBLICATION LAG, not a connectivity
            # failure: the candidate simply has not been published yet, and
            # the deferred-retry path via NCZ_AMD_DEFERRED (checked by
            # ncz_amd_accel_run after the fast budget) takes over.
            if [ -n "${_pk// /}" ]; then
                # shellcheck disable=SC2086
                ncz_amd_apt_install $_pk || return $?
            fi
            if [ "${NCZ_AMD_INDEX_FRESH:-0}" = 1 ]; then
                ncz_amd_log "native NPU candidate not yet published (fresh index); will retry, then defer" >&2
                NCZ_AMD_DEFERRED=1
            else
                ncz_amd_log "native NCZ index unreachable (network?)"
            fi
            return 75 ;;
        2) ncz_amd_log "NPU driver(s) missing from native index; will retry once published" >&2; _npustate=2 ;;
        *) ncz_amd_log "native candidate probe failed (rc=$_rc); retry later" >&2; return 75 ;;
    esac
    # Install whatever IS available (NPU runtime + drivers). NPU drivers
    # are intentionally excluded from _pk when _npustate=2 (see
    # ncz_amd_packages), so a partial NPU stack cannot land here.
    if [ "$_npustate" != 0 ]; then
        # NPU was requested but is incomplete. Do NOT return 0 (done):
        # the caller would mark the whole install done even though the NPU
        # half is still missing. The GPU Debian set is already installed
        # above (it is independent of the NPU driver stack), but the NPU
        # half must stay pending/deferred until the native candidates are
        # published. This is the critical fix: without it, a GPU+NPU
        # machine with the NPU set missing would be marked done on the
        # first re-arm, losing the deferred retry.
        [ "${NCZ_AMD_INDEX_FRESH:-0}" = 1 ] && NCZ_AMD_DEFERRED=1
        return 75
    fi
    if [ -n "${_pk// /}" ]; then
        # shellcheck disable=SC2086
        ncz_amd_apt_install $_pk || return $?
    fi
    return 0
}

ncz_amd_arm_retry() {   # GPU NPU
    mkdir -p "$(dirname "$(_na_pending)")"
    printf 'GPU=%s\nNPU=%s\nTRIES=0\n' "$1" "$2" > "$(_na_pending)"
    _sd="$(_na_r)/etc/systemd/system"
    _as="${NCZ_AMD_ASSETS:-$(_na_r)/usr/local/lib/cix-installer/assets/amd}"
    mkdir -p "$_sd/timers.target.wants" "$(_na_r)/usr/local/sbin"
    install -m0644 "$_as/ncz-amd-accel-setup.service" "$_sd/ncz-amd-accel-setup.service"
    install -m0644 "$_as/ncz-amd-accel-setup.timer" "$_sd/ncz-amd-accel-setup.timer"
    install -m0755 "${NCZ_AMD_LIB_SRC:-$(_na_r)/usr/local/lib/cix-installer/post-install/lib/amd-accel.sh}" \
        "$(_na_r)/usr/local/sbin/ncz-amd-accel-setup"
    ln -sf ../ncz-amd-accel-setup.timer "$_sd/timers.target.wants/ncz-amd-accel-setup.timer"
    ncz_amd_status "pending:retry-after-boot"
}

ncz_amd_finish() {
    rm -f "$(_na_pending)" "$(_na_r)/etc/systemd/system/timers.target.wants/ncz-amd-accel-setup.timer"
}

# Install-time entry (54-gpu-accel.sh). Takes the SAME lock as the deferred
# entry: an upgrade install runs while ncz-amd-accel-setup.timer may already
# be active, and without the lock install can delete a marker a deferred run
# just armed, or a deferred run can append LAST= to a marker install removed.

# ncz_amd_budget_resume -> the retry budget decision for one deferred run.
# Reads the armed marker and leaves the attempt number of THIS run in
# _ncz_t (the stored count + 1, or 1 when the run is an explicit re-arm).
#
# The counter is never rewound silently. A marker written by
# ncz_amd_arm_retry carries TRIES=0; the timer's own `run` must RESUME it,
# because the publication-lag class re-arms ONLY through ncz_amd_recover
# (an install-time arm has no re-arm path at all). Resetting to 0 there
# made `pending:attempt-$_t` count the same fresh 1..N on a machine that
# was already armed, so the give-up half of the retry/give-up policy could
# never be reached and every timer tick kept paying for an apt-get update
# + simulation. Only an explicit re-arm (`rearm`, or recover's re-arm when
# a gave-up status is revived) may start a new budget.
ncz_amd_budget_resume() {
    local raw
    raw=$(sed -n 's/^TRIES=//p' "$1")
    # Corrupt -> 0. Shell arithmetic reads a leading 0 as octal (TRIES=09
    # aborts) and a non-number aborts the run; a real count is short and
    # decimal. A marker without TRIES (older write, or a marker edited by
    # hand) is backfilled so the count cannot silently restart.
    case "$raw" in
        ""|0*|*[!0-9]*|?????????*) raw=0 ;;
    esac
    # An explicit re-arm starts a new budget even over a partially spent
    # marker; recover's own arm_retry already wrote a fresh TRIES=0.
    [ "${_rearm_budget:-0}" = 1 ] && raw=0
    _ncz_t=$(( raw + 1 ))
    if grep -q '^TRIES=' "$1"; then
        sed -i "s/^TRIES=.*/TRIES=$_ncz_t/" "$1"
    else
        echo "TRIES=$_ncz_t" >> "$1"
    fi
}

ncz_amd_accel_install() {   # GPU NPU
    local _lk _rc
    _lk="$(_na_r)/run/ncz-amd-accel.lock"
    mkdir -p "${_lk%/*}" 2>/dev/null || true
    if command -v flock >/dev/null 2>&1 && exec 9>"$_lk"; then
        if ! flock -w "${NCZ_AMD_LOCK_WAIT:-600}" 9; then
            exec 9>&-
            ncz_amd_log "another run holds $_lk; leaving this one to it"
            # The run holding the lock owns the marker from here: it has
            # already (re-)armed it, so this install must not undo that.
            return 0
        fi
    fi
    ncz_amd_setup "$1" "$2"; _rc=$?
    case "$_rc" in
        0)  ncz_amd_status "done"; ncz_amd_finish ;;
        75) ncz_amd_log "not finished at install time; ncz-amd-accel-setup.timer retries after boot"; ncz_amd_arm_retry "$1" "$2" ;;
        *)  ncz_amd_finish ;;
    esac
    exec 9>&- 2>/dev/null || true
    return 0
}

# Hardware probe used by the recovery path: which AMD classes are still
# present for this deferred install to serve? Prints "GPU NPU" (each 0/1)
# so a re-arm requests exactly what the machine has -- re-arming NPU on a
# GPU-only machine would wait forever for NPU drivers it never needs.
# Class match follows 54-gpu-accel.sh exactly, adapted for AMD:
#   GPU: display class 03xx (0300/0302/0380) vendor 1002 (AMD/ATI's real
#        GPU vendor ID -- 54's DISPLAY_PCI uses [1002:]).
#   NPU: class 1180 ("Signal processing controller") vendor 1022 AND a
#        known XDNA device ID (1502/17f0/17f2/17f3/1b0b/1b0c) -- class
#        1180 alone is NOT vendor-specific (Intel also uses it for
#        non-NPU devices), so the NPU match requires BOTH class 1180 AND
#        vendor 1022 AND a known XDNA device ID (exactly the IDs the
#        upstream amdxdna driver binds in v7.3-rc6,
#        drivers/accel/amdxdna/amdxdna_pci_drv.c). Verified live on
#        ACHILLES 192.168.207.11 and HYDRA 192.168.207.78 (both
#        0000:0a:00.1 class=0x118000 vendor=0x1022 device=0x1502,
#        `lspci -nn` line: "Signal processing controller [1180]: ... AMD
#        IPU Device [1022:1502]").
# The sysfs vendor/class files are PCI-core cached and never touch device
# config space (the GU502LV rule). When no sysfs PCI tree exists (test
# fixture) the probe reports presence (fail-open: the deferred run then
# just re-checks the index and stays pending) rather than silently
# dropping a legitimate marker.
_ncz_amd_npu_device_ids="1502 17f0 17f2 17f3 1b0b 1b0c"
ncz_amd_hw_classes() {
    local root="${NCZ_AMD_PCI_ROOT:-/sys/bus/pci/devices}" d v c dev g=0 n=0 id
    [ -d "$root" ] || { echo "1 1"; return 0; }
    for d in "$root"/*; do
        [ -r "$d/vendor" ] || continue
        v=$(tr -d '[:space:]' < "$d/vendor" 2>/dev/null)
        c=$(tr -d '[:space:]' < "$d/class" 2>/dev/null)
        # GPU: AMD/ATI (1002) display class 0300/0302/0380.
        if [ "$v" = "0x1002" ]; then
            case "$c" in
                0x0300*|0x0302*|0x0380*) g=1 ;;
            esac
        fi
        # NPU: AMD (1022) class 1180 + known XDNA device ID. Verified on
        # ACHILLES 192.168.207.11 and HYDRA 192.168.207.78 as class
        # 0x118000 -- the 24-bit sysfs class value of a 1180-class device
        # is exactly 0x118000 (subclass/subclass are 00 for these), so
        # match that exact value (not a 0x1180* prefix, which would
        # over-match any 118x subclass the PCI-SIG may add later).
        if [ "$v" = "0x1022" ]; then
            case "$c" in
                0x118000)
                    dev=$(tr -d '[:space:]' < "$d/device" 2>/dev/null)
                    # device file carries "0x1502"; strip the 0x prefix
                    # and case-insensitive-compare against the known set.
                    dev=${dev#0x}; dev=${dev#0X}
                    for id in $_ncz_amd_npu_device_ids; do
                        [ "$(printf '%s' "$dev" | tr 'A-F' 'a-f')" = "$id" ] && { n=1; break; }
                    done
                    ;;
            esac
        fi
    done
    echo "$g $n"
}
ncz_amd_hw_present() {
    case "$(ncz_amd_hw_classes)" in "0 0") return 1 ;; esac
    return 0
}

# ncz_amd_recover -> re-arm the deferred install on a system whose status
# is `failed:gave-up-*` and whose hardware is still present. Called from
# the deferred entry on EVERY run and from ncz-update-apply after an apt
# index refresh, so a shipped upgrade of the installer payload revives
# gave-up machines without touching their apt state. Idempotent: no-op when
# the status is not a gave-up or the marker is already armed.
ncz_amd_recover() {
    local s
    [ -r "$(_na_statusf)" ] || return 0
    s=$(head -1 "$(_na_statusf)")
    case "$s" in
        failed:gave-up-*) ;;
        *) return 0 ;;
    esac
    # If the marker is already present the system was already re-armed by a
    # previous recover or arm_retry call: do not touch the TRIES counter or
    # the status (idempotent, status-scoped).
    [ -r "$(_na_pending)" ] && return 0
    local hw
    hw=$(ncz_amd_hw_classes)
    if [ "$hw" = "0 0" ]; then
        ncz_amd_log "gave-up status kept: no AMD GPU/NPU hardware present"
        return 0
    fi
    ncz_amd_log "re-arming deferred install (was: $s; GPU NPU = $hw)"
    # shellcheck disable=SC2086
    ncz_amd_arm_retry $hw
    # On a running system the manager booted without the timer link (the
    # gave-up path removed it), so the new link alone would wait for the
    # next boot: load and start the timer now. Skipped for a target root.
    if [ -z "$(_na_r)" ] && [ -d /run/systemd/system ]; then
        systemctl daemon-reload >/dev/null 2>&1 || true
        systemctl start ncz-amd-accel-setup.timer >/dev/null 2>&1 || true
    fi
    return 0
}

# Deferred entry: ncz-amd-accel-setup run / rearm. The timer and
# ncz-update-apply can start it at the same time; one run at a time, or a
# run that defers could rewrite the marker another run just removed.
ncz_amd_accel_run() {
    local _lk _rc
    _lk="$(_na_r)/run/ncz-amd-accel.lock"
    mkdir -p "${_lk%/*}" 2>/dev/null || true
    if command -v flock >/dev/null 2>&1 && exec 9>"$_lk"; then
        if ! flock -w "${NCZ_AMD_LOCK_WAIT:-600}" 9; then
            exec 9>&-
            ncz_amd_log "another run holds $_lk; leaving this one to it"
            return 0
        fi
    fi
    _ncz_amd_accel_run_locked; _rc=$?
    exec 9>&- 2>/dev/null || true
    return "$_rc"
}

_ncz_amd_accel_run_locked() {
    _pf=$(_na_pending)
    # `rearm` is an explicit re-arm: it starts a NEW retry budget even when
    # a marker with a partially spent one is already armed (armed marker +
    # operator/recovery re-arm). The timer's own `run` never resets.
    _rearm_budget=0
    if [ "${_NCZ_AMD_REARM:-0}" = 1 ]; then _NCZ_AMD_REARM=0; _rearm_budget=1; fi
    # A gave-up system must recover when the installer payload is upgraded
    # or the update hook refreshes the index, provided the hardware is
    # still there. Run it BEFORE the pending check: the marker is gone on
    # a gave-up system, so without this the unit would stay a no-op forever
    # (the exact PROTEUS dead-end this fixes).
    ncz_amd_recover
    [ -r "$_pf" ] || { ncz_amd_log "nothing pending"; return 0; }
    # Slow retry while deferred: the 10-min timer keeps firing on the
    # marker, but a deferred system re-checks the index at most once per
    # NCZ_AMD_DEFER_SECS (default 1 day) instead of running apt-get update
    # every 10 minutes indefinitely. ncz-update-apply passes
    # NCZ_AMD_FORCE=1 because it has just refreshed the index itself.
    _last=$(sed -n 's/^LAST=//p' "$_pf")
    # corrupt -> re-check now. Shell arithmetic reads a leading 0 as octal
    # (LAST=09 aborts the run) and overflows past 18 digits: epoch seconds
    # are 1-12 digits with no leading zero.
    case "$_last" in ""|0*|*[!0-9]*|?????????????*) _last= ;; esac
    # A stamp in the future (clock stepped back, bad write) would throttle
    # until the clock catches up: treat it as corrupt too.
    [ -n "$_last" ] && [ "$_last" -gt "$(date +%s)" ] && _last=
    if [ -n "$_last" ] && [ "${NCZ_AMD_FORCE:-0}" != 1 ] \
       && grep -q '^deferred:' "$(_na_statusf)" 2>/dev/null \
       && [ $(( $(date +%s) - _last )) -lt "${NCZ_AMD_DEFER_SECS:-86400}" ]; then
        ncz_amd_log "deferred: next index re-check is at most daily; nothing to do now"
        return 0
    fi
    _g=$(sed -n 's/^GPU=//p' "$_pf"); _n=$(sed -n 's/^NPU=//p' "$_pf")
    ncz_amd_budget_resume "$_pf"; _t=$_ncz_t
    ncz_amd_log "attempt $_t (GPU=$_g NPU=$_n)"
    ncz_amd_setup "${_g:-0}" "${_n:-0}"; _rc=$?
    if [ "$_rc" = 0 ]; then ncz_amd_status "done"; ncz_amd_finish; return 0; fi
    if [ "$_rc" = 75 ] && [ "$_t" -lt "${NCZ_AMD_MAX_TRIES:-36}" ]; then
        ncz_amd_status "pending:attempt-$_t"; return 75
    fi
    if [ "$_rc" = 75 ] && [ "${NCZ_AMD_DEFERRED:-0}" = 1 ]; then
        # Fast budget exhausted, but the only gap is native NPU candidates
        # not yet published on a freshly fetched index. Do NOT give up:
        # keep the pending marker (the timer's ConditionPathExists stays
        # live, so every apt index refresh -- ncz-update-apply or the
        # timer itself -- re-checks the index) and report the slow-retry
        # state. Exit 0 (SuccessExitStatus) so systemd records a clean
        # oneshot; the marker -- not the exit code -- is what keeps the
        # retry armed.
        ncz_amd_status "deferred:native-candidates-unpublished"
        if grep -q '^LAST=' "$_pf"; then
            sed -i "s/^LAST=.*/LAST=$(date +%s)/" "$_pf"
        elif [ -f "$_pf" ]; then
            # never create a marker that holds only LAST= (no GPU/NPU)
            echo "LAST=$(date +%s)" >> "$_pf"
        fi
        return 0
    fi
    # Network-down (no fresh index), probe/apt failure, or would-remove
    # refusal: old semantics. Drop the marker; ncz_amd_recover (or an
    # explicit re-arm) can revive it once hardware is confirmed again.
    [ "$_rc" = 75 ] && ncz_amd_status "failed:gave-up-after-$_t-attempts"
    ncz_amd_finish
    return 1
}

# CLI entry. Only when EXECUTED, never when sourced: 54-gpu-accel.sh and
# ncz-update-apply source this file to call the functions, and a bare `exit`
# there would kill the sourcing shell.
if [ "${NCZ_AMD_ACCEL_LIB:-0}" != 1 ] && [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    case "${1:-}" in
        # `rearm` starts a new retry budget; `run` (the timer/service entry)
        # resumes the one in the marker.
        rearm) _NCZ_AMD_REARM=1; ncz_amd_accel_run; exit $? ;;
        run)   ncz_amd_accel_run; exit $? ;;
        # Any other verb is an operator/typo error, not a no-op success.
        # Exit 0 here would report SUCCESS while installing nothing and
        # re-arming nothing (the unit only whitelists 75), so a typo'd
        # `rearm` would silently disable the deferred install. Fail loudly.
        *)
            echo "usage: ${0##*/} {run|rearm}" >&2
            exit 2
            ;;
    esac
fi
# The `run` command is provided for the test harness: `run ncz_amd_accel_run`
# invokes the named function. This is NOT the CLI dispatch above (which runs
# only when the file is executed, not sourced); it's a convenience wrapper
# for the mock-based test fixture.
if [ "${NCZ_AMD_ACCEL_LIB:-0}" = 1 ]; then
    run() {
        [ $# -ge 1 ] || return 2
        "$@"
    }
fi

