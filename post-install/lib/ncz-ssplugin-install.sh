# shellcheck shell=bash
# ncz-ssplugin-install.sh -- the Singularity screensaver settings plugin
# (ncz-screensavers-plugin): pin loading, the ABI rule, and the offline
# install. Sourced (bash), never executed:
#   * post-install/59-ncz-screensavers-pkg.sh calls ncz_ssplugin_install after
#     the engine (ncz-screensavers) is installed;
#   * build/check-ssplugin-abi.sh uses ssplugin_load_lock + ssplugin_abi_verdict
#     at build time, so the build gate and the installer apply ONE rule.
#
# The pin is post-install/lib/ncz-screensavers-plugin.lock. It lives in the
# post-install tree because late.sh refreshes that tree from the install medium
# on every install (baked or not), so the installer always reads the pin that
# was built into the medium it booted from.
#
# Test seams (all default to the real system): NCZ_SSPLUGIN_ROOT prefixes every
# target path; NCZ_SSPLUGIN_LOCK overrides the pin file; NCZ_SSPLUGIN_DEB_DIRS
# overrides the deb search list.

_ssp_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ssp_log() { echo "[59-ncz-screensavers] plugin: $*"; }
ssp_err() { echo "[59-ncz-screensavers] plugin: $*" >&2; }

ssp_sha256() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }

# ssplugin_load_lock LOCKFILE ARCH -> sets SSP_PKG SSP_VERSION SSP_SHA256
# SSP_PAYLOAD SSP_LIBSHA SSP_ABI_LIB SSP_ARGONAS_DIR SSP_SOURCE SSP_MAINT.
# Returns 1 (with a message) when the file is unreadable or a field is empty.
ssplugin_load_lock() {
    local lock="$1" arch="$2" v
    [ -r "$lock" ] || { ssp_err "pin file $lock not readable"; return 1; }
    # Subshell-free parse: only KEY=VALUE lines, values may be double-quoted.
    # Sourcing would also work; parsing keeps a stray line from executing.
    local NCZ_SSPLUGIN_PKG="" NCZ_SSPLUGIN_VERSION="" NCZ_SSPLUGIN_MAINTAINER="" \
          NCZ_SSPLUGIN_ARGONAS_DIR="" NCZ_SSPLUGIN_SOURCE="" NCZ_SSPLUGIN_ABI_LIB=""
    local sha="" payload="" libsha="" key val line
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in ''|'#'*) continue ;; esac
        key="${line%%=*}"; val="${line#*=}"
        [ "$key" = "$line" ] && continue
        val="${val%\"}"; val="${val#\"}"
        case "$key" in
            NCZ_SSPLUGIN_PKG|NCZ_SSPLUGIN_VERSION|NCZ_SSPLUGIN_MAINTAINER|NCZ_SSPLUGIN_ARGONAS_DIR|NCZ_SSPLUGIN_SOURCE|NCZ_SSPLUGIN_ABI_LIB)
                printf -v "$key" '%s' "$val" ;;
            "NCZ_SSPLUGIN_SHA256_$arch") sha="$val" ;;
            "NCZ_SSPLUGIN_PAYLOAD_$arch") payload="$val" ;;
            "NCZ_SSPLUGIN_LIBSINGULARITY_SHA256_$arch") libsha="$val" ;;
        esac
    done < "$lock"
    SSP_PKG="$NCZ_SSPLUGIN_PKG"; SSP_VERSION="$NCZ_SSPLUGIN_VERSION"
    SSP_MAINT="$NCZ_SSPLUGIN_MAINTAINER"; SSP_ARGONAS_DIR="$NCZ_SSPLUGIN_ARGONAS_DIR"
    SSP_SOURCE="$NCZ_SSPLUGIN_SOURCE"; SSP_ABI_LIB="$NCZ_SSPLUGIN_ABI_LIB"
    SSP_SHA256="$sha"; SSP_PAYLOAD="$payload"; SSP_LIBSHA="$libsha"
    for v in SSP_PKG SSP_VERSION SSP_MAINT SSP_ARGONAS_DIR SSP_SOURCE SSP_ABI_LIB SSP_SHA256 SSP_PAYLOAD SSP_LIBSHA; do
        if [ -z "${!v}" ]; then
            ssp_err "pin file $lock has no value for $v (arch $arch)"
            return 1
        fi
    done
    case "$SSP_SHA256$SSP_LIBSHA" in
        *[!0-9a-f]*) ssp_err "pin file $lock: sha256 values for $arch are not lowercase hex"; return 1 ;;
    esac
    [ "${#SSP_SHA256}" = 64 ] && [ "${#SSP_LIBSHA}" = 64 ] || {
        ssp_err "pin file $lock: sha256 values for $arch are not 64 hex digits"; return 1; }
    return 0
}

# ssplugin_abi_verdict PAYLOAD_VERSION LIBSINGULARITY_SHA256 -> prints one of
#   version-match   payload version == the one the plugin was built against
#   lib-identical   different payload build, byte-identical libsingularity
#   MISMATCH        neither: the plugin must be rebuilt for this payload
# and returns 0 for the first two, 1 for MISMATCH. Needs ssplugin_load_lock.
# Byte identity of libsingularity is the whole Singularity ABI the plugin sees:
# every Singularity symbol it imports (singularity_plugin_get_type, the
# singularity_widgets_* rows) is defined there, and identical bytes mean
# identical type/struct layout, not just identical symbol names. A symbol-only
# comparison is deliberately NOT accepted: a GObject class struct can change
# size without any symbol changing.
ssplugin_abi_verdict() {
    local ver="$1" libsha="$2"
    if [ -n "$ver" ] && [ "$ver" = "$SSP_PAYLOAD" ]; then echo version-match; return 0; fi
    if [ -n "$libsha" ] && [ "$libsha" = "$SSP_LIBSHA" ]; then echo lib-identical; return 0; fi
    echo MISMATCH; return 1
}

# Rebuild instructions, printed by the build gate and the installer alike.
ssplugin_rebuild_help() {
    local arch="$1" ver="$2"
    cat >&2 <<EOF
  The plugin ($SSP_PKG $SSP_VERSION, $arch) was linked against Singularity payload
  $SSP_PAYLOAD (libsingularity sha256 $SSP_LIBSHA); this payload is
  ${ver:-unknown}. Rebuild the plugin against THIS payload (docs/SCREENSAVER-PLUGIN.md):
    amd64: PROTEUS 192.168.207.68, container debian:forky
    arm64: ULTRA   192.168.207.88, container debian:testing
    in that container, with an ncz-screensavers checkout (integration/cygnus-26.10-2026-10-03):
      apt-get install ./ncz-singularity-desktop_${ver:-<version>}_$arch.deb valac meson ninja-build \\
          libgtk-4-dev libgee-0.8-dev libjson-glib-dev libpeas-2-dev
      sh tools/build-plugin.sh /opt/singularity out/build-$arch
      NCZ_SINGULARITY_MIN=<payload yyyymmdd> sh tools/make-plugin-deb.sh $arch out/build-$arch \\
          out/ncz-screensavers-plugin_<version>_$arch.deb <version>
  Then copy the deb + SHA256SUMS + BUILT-FROM.txt to a new ARGONAS directory
  ncz-screensavers-debs/plugin-<version>-<date>/, update
  post-install/lib/ncz-screensavers-plugin.lock (sha256, payload version and
  libsingularity sha256 for BOTH arches), commit, and run
  build/stage-screensaver-plugin.sh $arch before stage 2 (make image).
EOF
}

# ncz_ssplugin_install ARCH -- install the pinned plugin from the install
# medium. Returns 0 when installed (or not applicable), 1 on any failure; the
# caller turns 1 into the hook's exit status. Never installs a plugin whose ABI
# does not match the installed payload: a mismatched .so would be loaded into
# Singularity Settings. The installed-target verifier then fails the image gate
# because the plugin is expected but missing.
ncz_ssplugin_install() {
    local arch="${1:-$(dpkg --print-architecture 2>/dev/null)}"
    local R="${NCZ_SSPLUGIN_ROOT:-}"
    local lock="${NCZ_SSPLUGIN_LOCK:-$_ssp_here/ncz-screensavers-plugin.lock}"
    if [ ! -r "$lock" ]; then
        ssp_err "FATAL: pin file $lock is missing; this installer was built without the plugin pin, refusing to guess"
        return 1
    fi
    ssplugin_load_lock "$lock" "$arch" || return 1

    if dpkg-query -W -f='${Status} ${Version}\n' "$SSP_PKG" 2>/dev/null | grep -qx "install ok installed $SSP_VERSION"; then
        ssp_log "$SSP_PKG $SSP_VERSION already installed"
    else
        # --- the pinned deb from the medium (fresh copy first, union-synced copy second)
        local dirs d f deb=""
        dirs="${NCZ_SSPLUGIN_DEB_DIRS:-/cdrom/ncz-payload/assets/ncz-screensavers-plugin /usr/local/lib/cix-installer/assets/ncz-screensavers-plugin}"
        for d in $dirs; do
            for f in "$R$d/${SSP_PKG}_${SSP_VERSION}_${arch}.deb"; do
                [ -f "$f" ] || continue
                if [ "$(ssp_sha256 "$f")" = "$SSP_SHA256" ]; then deb="$f"; break 2; fi
                ssp_err "WARN: $f does not match the pinned sha256 $SSP_SHA256; ignoring it"
            done
        done
        if [ -z "$deb" ]; then
            ssp_err "FATAL: no ${SSP_PKG}_${SSP_VERSION}_${arch}.deb with sha256 $SSP_SHA256 under: $dirs"
            ssp_err "       the image was built without staging it (build/stage-screensaver-plugin.sh $arch)"
            return 1
        fi
        ssp_log "using $deb (sha256 matches the pin)"

        # --- ABI: the plugin must sit on the payload it was linked against
        local pver plib libsha verdict
        pver="$(dpkg-query -W -f='${Version}' ncz-singularity-desktop 2>/dev/null || true)"
        plib="$(readlink -f "$R$SSP_ABI_LIB" 2>/dev/null || true)"
        libsha=""; [ -n "$plib" ] && [ -f "$plib" ] && libsha="$(ssp_sha256 "$plib")"
        if verdict="$(ssplugin_abi_verdict "$pver" "$libsha")"; then
            ssp_log "ABI ok ($verdict): payload ${pver:-none}, libsingularity ${libsha:-absent}"
        else
            ssp_err "FATAL: ABI MISMATCH: installed ncz-singularity-desktop ${pver:-<not installed>}, libsingularity ${libsha:-<absent>}; NOT installing the plugin"
            ssplugin_rebuild_help "$arch" "$pver"
            return 1
        fi

        # --- simulate first; a local deb pulls its Depends from the offline /cdrom pool
        local sim out rc
        sim="$(DEBIAN_FRONTEND=noninteractive apt-get install -s -y --no-install-recommends "$deb" 2>&1)" || {
            ssp_err "FATAL: simulation failed; refusing to install:"; printf '%s\n' "$sim" | tail -15 >&2; return 1; }
        if printf '%s\n' "$sim" | grep -q '^Remv '; then
            ssp_err "FATAL: simulation would REMOVE packages; refusing:"; printf '%s\n' "$sim" | grep '^Remv ' >&2; return 1
        fi
        out="$(DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$deb" 2>&1)"; rc=$?
        printf '%s\n' "$out" | tail -6
        [ "$rc" -eq 0 ] || { ssp_err "FATAL: apt install of $deb failed rc=$rc"; return 1; }
    fi

    # --- post-install assertions (what the installed-target verifier re-checks)
    dpkg-query -W -f='${Status} ${Version}\n' "$SSP_PKG" 2>/dev/null | grep -qx "install ok installed $SSP_VERSION" || {
        ssp_err "FATAL: $SSP_PKG $SSP_VERSION is not in the installed state after apt"; return 1; }
    local p=/opt/singularity/lib/singularity/plugins/screensaver
    for f in "$p/libscreensaver.so" "$p/screensaver.plugin"; do
        [ -e "$R$f" ] || { ssp_err "FATAL: $SSP_PKG installed but $f is absent"; return 1; }
    done
    # The package postinst adds 'screensaver' to the distribution default
    # enabled-plugins (from 20-desktop.sh's 99-ncz-defaults override) so a NEW
    # user starts with the page enabled; ncz-screensaver ensure-plugin covers
    # existing users at their next login.
    local ov=/opt/singularity/share/glib-2.0/schemas/99-zz-ncz-screensaver-plugin.gschema.override
    if ! grep -q "^enabled-plugins=.*'screensaver'" "$R$ov" 2>/dev/null; then
        ssp_err "FATAL: $ov missing or without 'screensaver': new users would not see the plugin (did 20-desktop.sh write the dev.sinty.desktop enabled-plugins default before this hook?)"
        return 1
    fi
    ssp_log "OK: $SSP_PKG $SSP_VERSION installed, enabled by default for new users"
    return 0
}
