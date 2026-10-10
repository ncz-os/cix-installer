#!/bin/bash
# offline.sh -- phase-2 network-OFF enforcement for the NCZ-OS build.
#
# Two-phase model (docs/IMAGE-BUILD-PROCESS.md SS "Hermetic builds"):
#   PHASE 1  fetch-inputs   ONLINE allowed.  Every external input is resolved
#                           and PRE-FETCHED into content-addressed caches on
#                           ARGONAS; the run writes inputs.lock recording every
#                           (what, url, resolved rev/digest, sha256).
#   PHASE 2  everything else NETWORK OFF.  Every stage consumes only the caches.
#                           Any attempted network access must FAIL the build
#                           loudly -- never silently fall through.
#
# --offline is FAIL-CLOSED and is the DEFAULT for --full/--weekly/nightly (any
# build that can be published).  --online-ok (developer only) is accepted only
# together with --no-publish.
#
# Usage (sourced by build-image.sh and build-singularity.sh):
#   . build/lib/offline.sh
#   ncz_offline_enabled                       # 0/1
#   ncz_offline_export_env                    # GOFLAGS/GOPROXY/CARGO_NET_OFFLINE/...
#   ncz_nonet_run <cmd...>                    # run a host command with no netns
#   ncz_container_network_arg                 # "--network none" when offline
# ---------------------------------------------------------------------------
set -uo pipefail

ncz_offline_enabled() { [ "${NCZ_OFFLINE:-0}" = 1 ]; }

# Export the per-ecosystem "do not touch the network" switches.  Each is the
# ecosystem's own documented offline switch, so a missing cache is a hard error
# in the tool itself, not a silent fetch.
ncz_offline_export_env() {
    export GOMODCACHE="${GOMODCACHE:-}"
    export GOFLAGS="${GOFLAGS:+$GOFLAGS }-mod=mod -modcacherw"
    export GOPROXY=off
    export GOSUMDB=off
    export GONOSUMCHECK=1
    export GOTOOLCHAIN=local
    export CARGO_NET_OFFLINE=true
    export PIP_NO_INDEX=1
    export PIP_FIND_LINKS="${PIP_FIND_LINKS:-}"
    export UV_OFFLINE=1
    export NPM_CONFIG_OFFLINE=true
    export YARN_ENABLE_NETWORK=false
    export MESON_WRAP_MODE=nodownload
    # git: only file:// is allowed (the local mirrors); NO network protocols.
    export GIT_ALLOW_PROTOCOL=file
    export GIT_TERMINAL_PROMPT=0
    # belt-and-braces: a raw http(s) client that ignores the above still hits a
    # blackhole.  This does NOT block raw sockets -- the netns does that.
    export http_proxy="http://127.0.0.1:9/" https_proxy="http://127.0.0.1:9/" \
           HTTP_PROXY="http://127.0.0.1:9/" HTTPS_PROXY="http://127.0.0.1:9/" \
           ftp_proxy="http://127.0.0.1:9/" all_proxy="http://127.0.0.1:9/" \
           no_proxy="" NO_PROXY=""
}

# Can we create a network namespace on this host?
ncz_nonet_available() {
    [ "$(uname -s)" = Linux ] || return 1
    command -v unshare >/dev/null 2>&1 || return 1
    if [ "$(id -u)" = 0 ]; then
        unshare -n true 2>/dev/null && return 0
    fi
    if command -v sudo >/dev/null 2>&1 && sudo -n unshare -n true 2>/dev/null; then
        return 0
    fi
    unshare -rn true 2>/dev/null && return 0
    return 1
}

# Run a host command with NO network (loopback only).  Enforcement order:
#   1. unshare -n           (root, or sudo -n)
#   2. unshare -rn          (unprivileged user+net namespace)
#   3. container           (podman/docker --network none) when NCZ_NONET_IMAGE set
#   4. FAIL CLOSED          when NCZ_OFFLINE_STRICT=1 (the default for offline)
#      else degraded proxy-blackhole with a loud WARN
ncz_nonet_run() {
    if [ "$(uname -s)" != Linux ]; then
        echo "ncz_nonet_run: not Linux; refusing to pretend network is off" >&2
        return 97
    fi
    command -v unshare >/dev/null 2>&1 || {
        echo "ncz_nonet_run: unshare not found" >&2; return 97; }
    if [ "$(id -u)" = 0 ]; then
        unshare -n "$@"; return $?
    fi
    if command -v sudo >/dev/null 2>&1 && sudo -n unshare -n true 2>/dev/null; then
        sudo -n unshare -n "$@"; return $?
    fi
    if unshare -rn true 2>/dev/null; then
        unshare -rn "$@"; return $?
    fi
    if [ "${NCZ_OFFLINE_STRICT:-1}" = 1 ]; then
        echo "ncz_nonet_run: no usable network namespace (unshare); refusing." >&2
        echo "ncz_nonet_run: set NCZ_OFFLINE_STRICT=0 to degrade to a proxy blackhole (NOT a real block)." >&2
        return 98
    fi
    echo "ncz_nonet_run: WARN degraded -- proxy blackhole only (raw sockets NOT blocked)" >&2
    local off=0; ncz_offline_export_env; "$@"
}

# The container-run network argument: offline => none.
ncz_container_network_arg() {
    if ncz_offline_enabled; then printf '%s\n' "none"; else printf '%s\n' "${NCZ_CONTAINER_NETWORK:-host}"; fi
}
