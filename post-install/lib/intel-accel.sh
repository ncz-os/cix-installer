#!/bin/bash
# intel-accel.sh -- Intel GPU / NPU userspace (OpenCL, VA-API, Level Zero,
# OpenVINO plugins) for amd64, with a deferred retry when the network is not
# up at install time. Sourced by post-install/54-gpu-accel.sh; installed as
# /usr/local/sbin/ncz-intel-accel-setup and run by ncz-intel-accel-setup.timer.
#
# Native NCZ/Forky acquisition ONLY (no Ubuntu/Intel repo).
# The signed NCZ apt source is supplied by hook24 (24-apt-sources.sh via
# apt-separation.sh); this lib never fetches a key, never writes an
# apt.repos.intel.com sources.list entry, and never trusts the
# `ubuntu24` Ubuntu-only component. If the native NCZ package is not yet
# published for the requested plugin class, the install reports honest
# deferred/retry state; it does NOT fall back to a vendor origin.
#
# Native NCZ candidate names (built against Debian Forky; amd64):
#   C) libopenvino-2026.4.1
#      libopenvino-intel-cpu-plugin-2026.4.1
#      libopenvino-intel-gpu-plugin-2026.4.1
#      libopenvino-intel-npu-plugin-2026.4.1
#   D) intel-driver-compiler-npu, intel-fw-npu,
#      intel-level-zero-npu, intel-validation-npu   (artifacts in flight)
#
# Debian-origin runtime (kept -- install from the configured Debian suite,
# independent of native availability; seeded by manifests/desktop-amd64.pkgs):
#   intel-opencl-icd, intel-media-va-driver, libze1, libze-intel-gpu1
#
# Rules this lib encodes (the caller / test can rely on):
#   * Debian runtime set is installed first, NO native index needed. A
#     network-down install still gets them from the offline mirror.
#   * Already-installed packages are skipped without calling apt.
#   * Every apt transaction is simulated first (apt-get install -s); a sim
#     that reports ANY `Remv ` refuses the whole install (status:
#     `failed:would-remove-N-packages`, return 1, no endless retry).
#   * Sim and real install use the SAME expanded args array (including
#     `-y` and `--no-install-recommends`); no --force-yes, no
#     --allow-downgrades, no `-o APT::Get::AllowUnauthenticated=true`.
#   * The NPU user-mode driver/compiler + firmware set (D above) is
#     required when NPU=1 is requested: if ANY of `intel-driver-compiler-npu`,
#     `intel-fw-npu`, `intel-level-zero-npu`, `intel-validation-npu` is
#     missing from the index, the install returns 75 (retry later) and
#     does NOT mark `done`. NPU userspace must not be silently skipped.
#   * GPU-only / NPU-only / both-zero selectors are all handled. The CPU
#     plugin (libopenvino-intel-cpu-plugin-<ver>) is preserved as a build
#     component; the current installer's selector doesn't request CPU.
#   * Apt index update is fail-closed (ErrorMode-any) yet an offline install
#     with already-seeded Debian packages still works.
#
# Retry policy (2026-10-17, PROTEUS defect: failed:gave-up-after-36-attempts
# on a Preview2-era install whose NPU D set + NPU plugin were simply not yet
# published to the NCZ index -- 10-minute retries are exhausted long before
# the native packages are published, and the pending marker is then dropped
# so NO later publish ever triggers the install):
#   * Fast budget: while TRIES < NCZ_INTEL_MAX_TRIES (36) the deferred unit
#     retries at the timer cadence (10 min).
#   * A 75 that is caused ONLY by native candidates missing from a FRESHLY
#     FETCHED index (i.e. apt-get update succeeded and the only gap is the
#     missing native plugin or NPU-driver candidates; every Debian-origin
#     package already resolves) is "transient publication lag", not a broken
#     system. After the fast budget it DEFERS instead of giving up: the
#     pending marker is kept, the status is
#     `deferred:native-candidates-unpublished`, and the deferred run exits
#     0 (SuccessExitStatus). The pending marker keeps ncz-intel-accel-setup
#     active, so the next apt index refresh that publishes the candidates
#     (e.g. ncz-update-apply) or any re-arm installs the stack then. No
#     timer change: OnUnitInactiveSec=10min fires while the unit is not
#     running, so a deferred install keeps being re-checked -- cheaply,
#     since it is a no-op until the candidates appear.
#   * Network-down (no fresh index fetch possible) and would-remove refusals
#     keep the old semantics: after the budget they stay failed / refused
#     and the marker is dropped (no endless 10-min loop; ncz_intel_recover
#     re-arms them once hardware is confirmed again).
#   * Recovery: on every re-run of the deferred entry (`ncz-intel-accel-setup
#     rearm` / `run`) a system left at `failed:gave-up-*` is re-armed when
#     Intel GPU or NPU hardware is still present (ncz_intel_recover,
#     invoked from the deferred entry and from ncz-update-apply). This makes
#     a shipped upgrade of the installer payload revive gave-up machines.
#
# Return codes from ncz_intel_setup / ncz_intel_accel_install / _run:
#   0  complete (all requested plugins and NPU drivers installed)
#   1  refused (simulation would remove packages; or NPU drivers missing
#      under "no retry" conditions; never silently marks done)
#   75 retry later (network down / index missing / native candidates not yet
#      published; leaves /var/lib/ncz/intel-accel.pending and arms timer)
#
# Test seams: NCZ_INTEL_ROOT (prefix for every file path), NCZ_INTEL_ASSETS,
# NCZ_NATIVE_OPENCV_AVAILABLE / NCZ_NATIVE_NPU_AVAILABLE env toggles used by
# build/test-intel-accel-deferred.sh to mock native candidate availability.
# Tested by build/test-intel-accel-deferred.sh and the NPU-driver /
# would-remove cases added in that test.

_ni_r()      { printf '%s' "${NCZ_INTEL_ROOT:-}"; }
_ni_pending() { echo "$(_ni_r)/var/lib/ncz/intel-accel.pending"; }
_ni_statusf() { echo "$(_ni_r)/var/lib/ncz/intel-accel.status"; }
ncz_intel_log() { echo "[intel-accel] $*"; }
ncz_intel_log_err() { echo "[intel-accel] $*" >&2; }
ncz_intel_status() { mkdir -p "$(dirname "$(_ni_statusf)")"; echo "$1" > "$(_ni_statusf)"; ncz_intel_log "status: $1"; }

# Scratch directory for the lib's own temporary files. It lives under the
# same NCZ_INTEL_ROOT prefix as every other path this lib touches (so the
# test fixture stays inside its sandbox) and never uses world-shared /tmp.
# Prints the directory on success; when it cannot be created the caller must
# skip the file entirely rather than retarget itself at /tmp.
_ncz_intel_tmpdir() {
    local d="${NCZ_INTEL_TMPDIR:-$(_ni_r)/var/lib/ncz/tmp}"
    mkdir -p "$d" 2>/dev/null && printf '%s\n' "$d"
}

# ncz_intel_setup clears these at entry; the probe helpers set them. The
# DEFERRED flag means "rc 75 is caused ONLY by native candidates missing
# from the index": the index itself fetched fine (apt-get update succeeded,
# so the network is up) and the ONLY gap is that the requested native NCZ
# plugin / NPU-driver candidates are not published yet. Only that class of
# 75 is allowed to fall back to the slow (deferred) retry after the fast
# budget; network-down (fresh index not fetchable) and would-remove keep
# their current semantics.
NCZ_INTEL_DEFERRED=0

ncz_intel_clear_deferred() {
    NCZ_INTEL_DEFERRED=0
}
# True when the configured apt sources (under NCZ_INTEL_ROOT) contain NO
# remote (http/https) origin: an all-local (file:/mirror-only) index is
# never a fresh fetch, so a successful apt-get update there proves nothing
# about publication lag. A missing candidate on such a system must NOT be
# treated as deferred-unpublished.
_ncz_intel_repos_all_local() {
    local base f
    for base in "$(_ni_r)/etc/apt/sources.list.d" "$(_ni_r)/etc/apt"; do
        [ -d "$base" ] || continue
        # *.list may be a SYMLINK to a managed config file (common on
        # Debian); -f follows symlinks, so those are read like any other
        # real file.
        for f in "$base"/*.list "$base"/*.sources; do
            # No match leaves the literal pattern as $f: not a regular file
            # (a dangling symlink is not one either), so skip it.
            [ -f "$f" ] || continue
            case "$f" in *.disabled-for-build|*.disabled-for-build.*) continue ;; esac
            # Any ACTIVE remote-origin deb line disqualifies "all local".
            # deb822 (.sources) files use "URIs: <uri>"; check both shapes.
            # ONE grep per file, so the pipeline status cannot mask a hit
            # in the second branch (`a | grep -q X || b | grep -q Y`).
            if grep -Eq '^[[:space:]]*deb(-src)?[[:space:]].*https?://|^[[:space:]]*URIs:[[:space:]].*https?://' "$f" 2>/dev/null; then
                return 1
            fi
        done
    done
    # An inline deb line in the root sources.list counts too.
    f="$(_ni_r)/etc/apt/sources.list"
    if [ -f "$f" ] && grep -Eq '^[[:space:]]*deb(-src)?[[:space:]].*https?://' "$f" 2>/dev/null; then
        return 1
    fi
    return 0
}

# ncz_intel_disable_legacy_vendor_list FILE -> comments out ONLY the active
# deb/deb-src lines in FILE whose actual URI matches apt.repos.intel.com
# (the only KNOWN legacy Intel vendor source this lib recognizes). The
# original bytes are preserved in a unique ${f}.disabled-for-build.XXXXXX
# backup; unrelated active lines and comments are preserved verbatim. Must
# NOT be called on a file ending in .disabled-for-build.
#
# Mirrors post-install/55-t2-firmware.sh's ncz_t2_disable_legacy_vendor_list
# (same URL-skip-bracket-options parsing, same unique-backup discipline, same
# honest-on-failure behaviour). The URL literal IS referenced on purpose:
# the disabler MUST recognize the legacy host pattern, so the test cannot
# ban this token outright -- grep tests strip leading `#`/comment-only lines.
ncz_intel_disable_legacy_vendor_list() {
    local f="$1" tmp bak
    [ -f "$f" ] || return 0
    case "$f" in
        *.disabled-for-build|*.disabled-for-build.*) return 0 ;;
    esac
    # Refuse symlinks: rewriting through a symlink could clobber an unrelated
    # target. Honest failure rather than a silent skip.
    if [ -L "$f" ]; then
        ncz_intel_log_err "$f is a symlink; refusing to rewrite (leaving untouched)"
        return 1
    fi
    tmp=$(mktemp "${f}.ncz.XXXXXX") || {
        ncz_intel_log_err "could not create temp file next to $f; leaving it untouched"
        return 1
    }
    if ! cp -p "$f" "$tmp"; then
        ncz_intel_log_err "could not copy $f to temp; leaving it untouched"
        rm -f "$tmp"
        return 1
    fi
    # Rewrite: comment out ONLY active deb/deb-src lines whose actual URI
    # matches the known legacy host/path. Everything else is emitted verbatim.
    if ! awk '
        /^[[:space:]]*deb(-src)?[[:space:]]/ {
            uri = ""
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^[A-Za-z][A-Za-z0-9+.-]*:\/\//) { uri = $i; break }
            }
            if (uri ~ /^https?:\/\/apt\.repos\.intel\.com\/openvino(\/|$)/) {
                print "# [intel-accel] disabled legacy vendor source: " $0
                next
            }
        }
        { print }
    ' "$f" > "$tmp"; then
        ncz_intel_log_err "awk rewrite failed for $f; leaving it untouched"
        rm -f "$tmp"
        return 1
    fi
    if cmp -s "$f" "$tmp"; then
        rm -f "$tmp"
        return 0
    fi
    bak=$(mktemp "${f}.disabled-for-build.XXXXXX") || {
        ncz_intel_log_err "could not create backup for $f; leaving it untouched"
        rm -f "$tmp"
        return 1
    }
    if ! cp -p "$f" "$bak"; then
        ncz_intel_log_err "could not write backup $bak; leaving $f untouched"
        rm -f "$tmp" "$bak"
        return 1
    fi
    if ! mv "$tmp" "$f"; then
        ncz_intel_log_err "could not replace $f atomically; original preserved, backup at $bak"
        rm -f "$tmp"
        return 1
    fi
    ncz_intel_log "disabled known legacy vendor source line(s) in $f (backup: ${bak##*/})"
    return 0
}

# ncz_intel_debian_packages GPU NPU -> the Debian-origin packages (Level Zero
# loader + Intel GPU driver, OpenCL ICD, VA driver) minus the ones already
# installed. These are seeded in manifests/desktop-amd64.pkgs, so they resolve
# from the offline mirror with no network and with no Intel/NCZ index.
ncz_intel_debian_packages() {
    _d=""
    [ "$1" = 1 ] && _d="intel-opencl-icd intel-media-va-driver libze1 libze-intel-gpu1"
    [ "$2" = 1 ] && _d="$_d libze1"
    for _p in $(echo "$_d" | tr ' ' '\n' | sed '/^$/d' | sort -u); do
        dpkg-query -W -f='${Status}' "$_p" 2>/dev/null | grep -q '^install ok installed' || printf '%s ' "$_p"
    done
}

# ncz_intel_native_opencl_vers GPU NPU -> prints "GPUVER NPUVER" of the
# latest available native OpenVINO plugin versions on stdout (one per
# requested class, "0" when that class is not requested). Returns non-zero
# when the requested class has NO candidate in any configured apt repo
# (i.e. the native NCZ suite has not yet published the plugin). This is
# the ONLY place that decides "can we install the plugin at all".
ncz_intel_native_opencl_vers() {
    _gv=0; _nv=0
    if [ "$1" = 1 ]; then
        _gv=$(ncz_intel_pick_native_vers libopenvino-intel-gpu-plugin-) || return 1
        [ -n "$_gv" ] || return 1
    fi
    if [ "$2" = 1 ]; then
        _nv=$(ncz_intel_pick_native_vers libopenvino-intel-npu-plugin-) || return 1
        [ -n "$_nv" ] || return 1
    fi
    printf '%s %s\n' "$_gv" "$_nv"
}

ncz_intel_pick_native_vers() {
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

# ncz_intel_required_npu_drivers -> prints the set of required NPU
# userspace/firmware package NAMES (one per line, no version). The names
# are the native NCZ D components; they don't carry a version suffix
# because the native suite publishes single-version candidates. The
# function does NOT probe for them: that's ncz_intel_npu_drivers_present
# below. Defined as a separate function so the test can assert the list
# without needing any apt state.
ncz_intel_required_npu_drivers() {
    printf '%s\n' intel-driver-compiler-npu intel-fw-npu \
                  intel-level-zero-npu intel-validation-npu
}

# ncz_intel_npu_drivers_present -> 0 if every required NPU driver/firmware
# package has a real Candidate (numeric version) in the configured repos;
# 1 if any is missing or only "(none)". This is the gate: NPU userspace
# MUST NOT be silently skipped; if any driver is missing the caller
# returns 75 retry and does NOT mark done.
#
# Diagnostic output is written to STDERR (not stdout): the caller's package
# list is built from command-substitution `$(ncz_intel_packages ...)` and any
# diagnostic on stdout would be captured AS a package name and forwarded to
# `apt-get install`, producing a phantom-arg failure.
ncz_intel_npu_drivers_present() {
    for _u in $(ncz_intel_required_npu_drivers); do
        _c=$(apt-cache policy "$_u" 2>/dev/null \
             | sed -n 's/^[[:space:]]*Candidate:[[:space:]]*//p' | head -1)
        [ -n "$_c" ] || { ncz_intel_log_err "NPU driver missing: $_u (no native NCZ candidate yet)"; return 1; }
        case "$_c" in "(none)"|"") ncz_intel_log_err "NPU driver missing: $_u (no native NCZ candidate yet)"; return 1 ;; esac
        case "$_c" in *ncz*) ;; *) ncz_intel_log_err "NPU driver missing: $_u (no native NCZ candidate yet)"; return 1 ;; esac
    done
    return 0
}

# ncz_intel_packages GPU NPU -> the native NCZ package names to install
# (OpenVINO plugins + NPU user-mode drivers) on stdout. Return codes:
#   0 = all requested classes have candidates;
#   1 = a requested class has no candidate (the caller must distinguish:
#       rc=1 from ncz_intel_native_opencl_vers means the class is not yet
#       published -- a deferrable publication lag, not a connectivity
#       failure. The caller checks NCZ_INTEL_INDEX_FRESH to decide.);
#   2 = NPU drivers missing (NPU=1 requested but the D set is incomplete).
# The old caller translated rc=1 to "network?" -- that is wrong when the
# index is fresh and only the candidate is missing. The 2026-10-17 fix
# (ncz_intel_setup) now checks NCZ_INTEL_INDEX_FRESH before deciding
# whether rc=1 is a deferrable publication lag or a real connectivity
# failure.
# CPU plugin is intentionally NOT requested by the current installer; the
# library preserves it as a build component for completeness but does not
# include it in the install list unless GPU is selected AND the CPU
# component exists alongside (the install-time selector in 54-gpu-accel.sh
# never asks for CPU).
#
# GPU=1 and NPU=1 are independent:
#   * GPU plugin is installed whenever its candidate exists, regardless of
#     NPU driver availability;
#   * NPU plugin + the four driver/compiler/firmware packages are installed
#     ONLY when NPU=1 AND every required driver has a candidate. If a
#     driver is missing the function returns 2 so the caller knows NPU is
#     still incomplete, but it still prints the GPU plugin (if any) so the
#     caller can install what's there.
ncz_intel_packages() {
    _v=$(ncz_intel_native_opencl_vers "$1" "$2") || return $?
    set -- $1 $2 $_v
    _g=$3; _n=$4
    _p=""
    [ "$1" = 1 ] && _p="libopenvino-intel-gpu-plugin-$_g"
    _npustate=0
    if [ "$2" = 1 ]; then
        if ncz_intel_npu_drivers_present; then
            _p="$_p libopenvino-intel-npu-plugin-$_n"
            for _u in $(ncz_intel_required_npu_drivers); do
                _p="$_p $_u"
            done
        else
            # NPU plugin is NOT safe without its driver/compiler/firmware
            # stack; the caller (rc=2) will defer. Don't include it in the
            # output list; the GPU plugin (if any) is still installed.
            _npustate=2
        fi
    fi
    echo "$_p" | tr ' ' '\n' | sed '/^$/d' | sort -u | tr '\n' ' '
    [ "$_npustate" = 0 ] || return "$_npustate"
}

# ncz_intel_apt_install PKGS... -> 0 installed, 1 refused (would-remove),
# 75 retry later (transient: simulation unreachable OR real install failed).
# Sim and real install use the SAME expanded args array (NCZ_INTEL_APT_BASE_ARGS
# below, including -y and --no-install-recommends; -y is harmless under `-s`).
# No force / allow-downgrades / trust waiver.
NCZ_INTEL_APT_BASE_ARGS=( -y --no-install-recommends )
ncz_intel_apt_install() {
    ncz_intel_log "packages: $*"
    _sim=$(LC_ALL=C apt-get install -s "${NCZ_INTEL_APT_BASE_ARGS[@]}" "$@" 2>&1); _rc=$?
    if [ "$_rc" -ne 0 ]; then
        printf '%s\n' "$_sim" | tail -5
        ncz_intel_log "simulation failed (rc=$_rc); transient/unavailable -- retry later"
        return 75
    fi
    _rm=$(printf '%s\n' "$_sim" | grep -c '^Remv ')
    if [ "$_rm" -gt 0 ]; then
        printf '%s\n' "$_sim" | grep '^Remv ' | head -10
        ncz_intel_status "failed:would-remove-$_rm-packages"; return 1
    fi
    DEBIAN_FRONTEND=noninteractive apt-get install "${NCZ_INTEL_APT_BASE_ARGS[@]}" "$@" 2>&1 | tail -10
    [ "${PIPESTATUS[0]:-0}" -eq 0 ] || return 75
    return 0
}

# ncz_intel_setup GPU NPU -> 0 done, 75 retry later, 1 refused/permanent.
# Native NCZ acquisition only: no key fetch, no repo wiring. The signed
# NCZ source is supplied by hook24 (apt-separation.sh). If the index does
# not yet carry the requested native plugin, or any NPU driver is missing,
# the function returns 75 and the caller arms the retry timer.
#
# GPU plugin is installed even when NPU drivers are missing (the GPU plugin
# is independent of the NPU driver stack). The function reports 75 (not
# done) when NPU was requested but is still incomplete, so the caller arms
# the timer for the next native publish without falsely marking success.
#
# 75 cause classification (deferred-retry policy, 2026-10-17): on return,
# NCZ_INTEL_DEFERRED is 1 ONLY when the 75 is caused solely by native
# candidates missing from a freshly fetched index (apt-get update succeeded
# and the sources include a remote origin; everything else resolved).
# That class may fall back to the slow deferred retry after the fast
# budget; every other 75 (network down, probe failure, apt install
# failure) keeps the old semantics.
ncz_intel_setup() {
    ncz_intel_clear_deferred
    # Reversibly move a known-legacy intel-openvino.list aside BEFORE
    # apt-get update so a stray Intel vendor origin cannot shadow the native
    # NCZ suite. Only NCZ_INTEL_ROOT is touched (defaults to / for real
    # installs, $W/r for the deferred-retry test fixture).
    ncz_intel_disable_legacy_vendor_list "$(_ni_r)/etc/apt/sources.list.d/intel-openvino.list" || return 75
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
    # to date and a missing native candidate is a PUBLICATION gap, not a
    # connectivity gap. An all-local (file:/mirror) index, or a failed
    # update, never proves that. The flag is set only AFTER the Debian set
    # (which must resolve from the same index) is handled: if the Debian
    # set install fails, the index was not usable for the runtime either
    # and the 75 must NOT be misclassified as publication lag.
    # The update runs OUTSIDE a pipeline: `_updrc=$?` is then the real
    # apt-get status under ANY POSIX shell (the lib is sourced by the
    # installer's bash hooks, but this exact status is what decides
    # deferred-vs-gave-up, so it must not depend on a bash-only PIPESTATUS).
    _ud=$(_ncz_intel_tmpdir)
    if [ -n "$_ud" ]; then
        _ulog="$_ud/intel-accel-update.log"
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
    _dp=$(ncz_intel_debian_packages "$1" "$2")
    if [ -n "${_dp// /}" ]; then
        # shellcheck disable=SC2086
        ncz_intel_apt_install $_dp || return $?
    fi
    if [ "${_updrc:-1}" -eq 0 ] && ! _ncz_intel_repos_all_local; then
        NCZ_INTEL_INDEX_FRESH=1
    else
        NCZ_INTEL_INDEX_FRESH=0
    fi
    _pk=$(ncz_intel_packages "$1" "$2")
    _rc=$?
    case "$_rc" in
        0) _npustate=0 ;;
        1)
            # A requested class has no candidate (ncz_intel_packages ->
            # ncz_intel_native_opencl_vers). When the index is fresh (remote
            # sources, apt-get update succeeded, Debian set resolved) this
            # is a PUBLICATION LAG, not a connectivity failure: the
            # candidate simply has not been published yet. The GPU plugin
            # (if any) was already installed above; the missing class is
            # handled through the deferred-retry path via
            # NCZ_INTEL_DEFERRED, which the caller (ncz_intel_accel_run)
            # checks after the fast budget is exhausted.
            if [ "${NCZ_INTEL_INDEX_FRESH:-0}" = 1 ]; then
                ncz_intel_log "native candidate not yet published (fresh index); will retry, then defer" >&2
                NCZ_INTEL_DEFERRED=1
            else
                ncz_intel_log "native NCZ index unreachable (network?)"
            fi
            return 75 ;;
        2) ncz_intel_log "NPU driver(s) missing from native index; will retry once published" >&2; _npustate=2 ;;
        *) ncz_intel_log "native candidate probe failed (rc=$_rc); retry later" >&2; return 75 ;;
    esac
    # Install whatever IS available (gpu plugin, etc). NPU plugin + drivers
    # are intentionally excluded from _pk when _npustate=2 (see
    # ncz_intel_packages), so a partial NPU stack cannot land here.
    if [ -n "${_pk// /}" ]; then
        # shellcheck disable=SC2086
        ncz_intel_apt_install $_pk || return $?
    elif [ "$_npustate" != 0 ]; then
        # Nothing installable yet; rely on the deferred retry path.
        [ "${NCZ_INTEL_INDEX_FRESH:-0}" = 1 ] && NCZ_INTEL_DEFERRED=1
        return 75
    fi
    # NPU was incomplete (or finished); the timer retry flag in the caller
    # decides whether to mark done. Returning 75 here still triggers the
    # retry arming; returning 0 marks done.
    if [ "$_npustate" != 0 ]; then
        # Everything installable was installed above; the ONLY remaining
        # gap is the unpublished NPU set, and it is missing from a freshly
        # fetched index. That is publication lag, not a broken system.
        [ "${NCZ_INTEL_INDEX_FRESH:-0}" = 1 ] && NCZ_INTEL_DEFERRED=1
        return 75
    fi
    return 0
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
    ncz_intel_setup "$1" "$2"; _rc=$?
    case "$_rc" in
        0)  ncz_intel_status "done"; ncz_intel_finish ;;
        75) ncz_intel_log "not finished at install time; ncz-intel-accel-setup.timer retries after boot"; ncz_intel_arm_retry "$1" "$2" ;;
        *)  ncz_intel_finish ;;
    esac
    return 0
}

# Hardware presence probe used by the recovery path: is there still an
# Intel GPU/NPU for this deferred install to serve? Class match follows
# 54-gpu-accel.sh exactly (display class 03xx vendor 8086 = GPU; class 1200
# vendor 8086 = NPU). The sysfs vendor/class files are PCI-core cached and
# never touch device config space (the GU502LV rule). When no sysfs PCI
# tree exists (test fixture) the probe reports presence (fail-open: the
# deferred run then just re-checks the index and stays pending) rather
# than silently dropping a legitimate marker.
ncz_intel_hw_present() {
    local root="${NCZ_INTEL_PCI_ROOT:-/sys/bus/pci/devices}" d
    [ -d "$root" ] || return 0
    for d in "$root"/*; do
        [ -r "$d/vendor" ] || continue
        local v c
        v=$(tr -d '[:space:]' < "$d/vendor" 2>/dev/null)
        c=$(tr -d '[:space:]' < "$d/class" 2>/dev/null)
        [ "$v" = "0x8086" ] || continue
        # sysfs class is "0x030000" (display) or "0x120000" (NPU/processing).
        case "$c" in
            0x03*|0x12*) return 0 ;;
        esac
    done
    return 1
}

# ncz_intel_recover -> re-arm the deferred install on a system whose status
# is `failed:gave-up-*` and whose hardware is still present. Called from
# the deferred entry on EVERY run and from ncz-update-apply after an apt
# index refresh, so a shipped upgrade of the installer payload revives
# gave-up machines without touching their apt state. Idempotent: no-op when
# the status is not a gave-up or the marker is already armed.
ncz_intel_recover() {
    local s
    [ -r "$(_ni_statusf)" ] || return 0
    s=$(head -1 "$(_ni_statusf)")
    case "$s" in
        failed:gave-up-*) ;;
        *) return 0 ;;
    esac
    # If the marker is already present the system was already re-armed by a
    # previous recover or arm_retry call: do not touch the TRIES counter or
    # the status (idempotent, status-scoped).
    [ -r "$(_ni_pending)" ] && return 0
    if ! ncz_intel_hw_present; then
        ncz_intel_log "gave-up status kept: no Intel GPU/NPU hardware present"
        return 0
    fi
    ncz_intel_log "re-arming deferred install (was: $s)"
    ncz_intel_arm_retry 1 1
    return 0
}

# Deferred entry: ncz-intel-accel-setup run / rearm
ncz_intel_accel_run() {
    _pf=$(_ni_pending)
    # A gave-up system must recover when the installer payload is upgraded
    # or the update hook refreshes the index, provided the hardware is
    # still there. Run it BEFORE the pending check: the marker is gone on
    # a gave-up system, so without this the unit would stay a no-op forever
    # (the exact PROTEUS dead-end this fixes).
    ncz_intel_recover
    [ -r "$_pf" ] || { ncz_intel_log "nothing pending"; return 0; }
    _g=$(sed -n 's/^GPU=//p' "$_pf"); _n=$(sed -n 's/^NPU=//p' "$_pf"); _t=$(sed -n 's/^TRIES=//p' "$_pf")
    _t=$(( ${_t:-0} + 1 ))
    sed -i "s/^TRIES=.*/TRIES=$_t/" "$_pf"
    ncz_intel_log "attempt $_t (GPU=$_g NPU=$_n)"
    ncz_intel_setup "${_g:-0}" "${_n:-0}"; _rc=$?
    if [ "$_rc" = 0 ]; then ncz_intel_status "done"; ncz_intel_finish; return 0; fi
    if [ "$_rc" = 75 ] && [ "$_t" -lt "${NCZ_INTEL_MAX_TRIES:-36}" ]; then
        ncz_intel_status "pending:attempt-$_t"; return 75
    fi
    if [ "$_rc" = 75 ] && [ "${NCZ_INTEL_DEFERRED:-0}" = 1 ]; then
        # Fast budget exhausted, but the only gap is native candidates not
        # yet published on a freshly fetched index. Do NOT give up: keep
        # the pending marker (the timer's ConditionPathExists stays live, so
        # every apt index refresh -- ncz-update-apply or the timer itself --
        # re-checks the index) and report the slow-retry state. Exit 0
        # (SuccessExitStatus) so systemd records a clean oneshot; the
        # marker -- not the exit code -- is what keeps the retry armed.
        ncz_intel_status "deferred:native-candidates-unpublished"
        return 0
    fi
    # Network-down (no fresh index), probe/apt failure, or would-remove
    # refusal: old semantics. Drop the marker; ncz_intel_recover (or an
    # explicit re-arm) can revive it once hardware is confirmed again.
    [ "$_rc" = 75 ] && ncz_intel_status "failed:gave-up-after-$_t-attempts"
    ncz_intel_finish
    return 1
}

if [ "${NCZ_INTEL_ACCEL_LIB:-0}" != 1 ]; then
    case "${1:-}" in
        run|rearm) ncz_intel_accel_run; exit $? ;;
    esac
fi
