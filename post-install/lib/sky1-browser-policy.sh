# sky1-browser-policy.sh -- Sky1 (arm64) browser defaults: chromium-ncz-sky1 is
# the default browser, and Vivaldi / Google Chrome are launched with VA-API off.
# POSIX sh; sourced by post-install/52-vivaldi.sh and 53-chrome.sh on arm64 only.
#
# Why (r201, docs/HW-VIDEO-DECODE-STATUS.md): 84-vpu-vaapi.sh exports
# LIBVA_DRIVER_NAME=libcix_va session-wide, so stock-Chromium browsers (Vivaldi,
# Google Chrome) take the VA-API decode path, and the CIX VA-API driver hangs or
# spins on H.264/HEVC: playback freezes. chromium-ncz-sky1 decodes through the
# V4L2 stateful decoder (no libva in the binary) and was validated on O6N and
# MS-R1. So on Sky1:
#   * chromium-ncz-sky1 is the default (x-www-browser + gnome-www-browser
#     alternatives, /etc/xdg and /etc/skel mimeapps.list, existing users'
#     mimeapps entries that still name the seeded Vivaldi/Chrome default);
#   * Vivaldi and Chrome stay installed, but every way of starting them goes
#     through VA-API-off launchers: /usr/local/share/applications/<id>.desktop
#     overrides (XDG_DATA_DIRS lists /usr/local/share before /usr/share, so the
#     same desktop ID resolves to the override), /usr/local/bin wrappers (PATH
#     order), and the /etc/skel and existing ~/Desktop launcher copies.
# amd64 never sources this file: VA-API works there and Vivaldi stays default.
#
# ncz_sky1_browser_policy
#   Idempotent. Every path is under ${NCZ_BROWSER_ROOT:-} (test seam). Set
#   NCZ_BROWSER_NO_ALTERNATIVES=1 to skip update-alternatives (tests).
# Tested by build/test-sky1-media-defaults.sh.

NCZ_NO_VAAPI_ENV="LIBVA_DRIVER_NAME=ncz-no-vaapi"
NCZ_NO_VAAPI_FLAG="--disable-features=VaapiVideoDecoder,VaapiVideoEncoder"
NCZ_BROWSER_MIME_KEYS="text/html x-scheme-handler/http x-scheme-handler/https x-scheme-handler/ftp x-scheme-handler/chrome x-scheme-handler/about x-scheme-handler/unknown application/x-extension-htm application/x-extension-html application/xhtml+xml"

_ncz_bp_log() { echo "[sky1-browser] $*"; }

# Rewrite a packaged .desktop: every Exec= becomes
#   Exec=env LIBVA_DRIVER_NAME=ncz-no-vaapi <binary> --disable-features=... <rest>
_ncz_bp_novaapi_desktop() {   # SRC DST
    awk -v envv="$NCZ_NO_VAAPI_ENV" -v flag="$NCZ_NO_VAAPI_FLAG" '
        /^Exec=/ && index($0, envv) == 0 {
            cmd = substr($0, 6)
            if (substr(cmd, 1, 1) == "\"") {           # quoted program path
                n = index(substr(cmd, 2), "\"")
                n = (n == 0) ? 0 : n + 2
            } else {
                n = index(cmd, " ")
            }
            if (n == 0 || n > length(cmd)) { bin = cmd; rest = "" } else { bin = substr(cmd, 1, n - 1); rest = substr(cmd, n) }
            print "Exec=env " envv " " bin " " flag rest
            next
        }
        { print }
    ' "$1" > "$2.ncz-tmp" && mv -f "$2.ncz-tmp" "$2"
}

_ncz_bp_wrapper() {   # NAME TARGET
    _r="${NCZ_BROWSER_ROOT:-}"
    cat > "$_r/usr/local/bin/$1" <<EOF
#!/bin/sh
# NCZ-OS Sky1 (post-install/lib/sky1-browser-policy.sh): start $1 with VA-API
# off. The CIX VA-API decoder hangs on H.264/HEVC (docs/HW-VIDEO-DECODE-STATUS.md).
export $NCZ_NO_VAAPI_ENV
exec $2 $NCZ_NO_VAAPI_FLAG "\$@"
EOF
    chmod 0755 "$_r/usr/local/bin/$1"
}

# Point the browser keys of a mimeapps.list at DESKTOP_ID.
#   MODE=system : set every browser key (add the ones that are missing);
#   MODE=user   : only replace values that are the seeded Vivaldi/Chrome default.
_ncz_bp_mimeapps() {   # FILE DESKTOP_ID MODE
    _f="$1"
    [ -f "$_f" ] || { [ "$3" = system ] || return 0; printf '[Default Applications]\n' > "$_f"; }
    awk -v id="$2" -v mode="$3" -v keys="$NCZ_BROWSER_MIME_KEYS" '
        BEGIN { nk = split(keys, K, " "); for (i = 1; i <= nk; i++) want[K[i]] = 1 }
        function flush_missing(   i) {
            if (mode != "system" || done) return
            for (i = 1; i <= nk; i++) if (!(K[i] in seen)) print K[i] "=" id
            done = 1
        }
        /^\[/ {
            if (insec) flush_missing()
            insec = ($0 == "[Default Applications]"); if (insec) hadsec = 1
            print; next
        }
        insec && index($0, "=") {
            k = substr($0, 1, index($0, "=") - 1); v = substr($0, index($0, "=") + 1)
            if (k in want) {
                seen[k] = 1
                if (mode == "system" || v ~ /^(vivaldi-stable|google-chrome|com\.google\.Chrome)\.desktop;?$/) { print k "=" id; next }
            }
        }
        { print }
        END {
            if (insec) flush_missing()
            else if (mode == "system" && !hadsec) { print "[Default Applications]"; flush_missing() }
        }
    ' "$_f" > "$_f.ncz-tmp" && cat "$_f.ncz-tmp" > "$_f"
    rm -f "$_f.ncz-tmp"
}

ncz_sky1_browser_policy() {
    _r="${NCZ_BROWSER_ROOT:-}"
    _apps="$_r/usr/share/applications"
    _local="$_r/usr/local/share/applications"
    mkdir -p "$_local" "$_r/usr/local/bin"

    # --- 1. Vivaldi / Chrome: VA-API off on every launch path --------------------
    _overrides=""
    for _id in vivaldi-stable.desktop google-chrome.desktop; do
        if [ -f "$_apps/$_id" ]; then
            _ncz_bp_novaapi_desktop "$_apps/$_id" "$_local/$_id"
            chmod 0644 "$_local/$_id"
            _overrides="$_overrides $_id"
        else
            rm -f "$_local/$_id"
        fi
    done
    if [ -x "$_r/usr/bin/vivaldi-stable" ]; then
        _ncz_bp_wrapper vivaldi-stable /usr/bin/vivaldi-stable
        if [ -x "$_r/usr/bin/vivaldi" ]; then _ncz_bp_wrapper vivaldi /usr/bin/vivaldi; else _ncz_bp_wrapper vivaldi /usr/bin/vivaldi-stable; fi
    fi
    if [ -x "$_r/usr/bin/google-chrome-stable" ]; then
        _ncz_bp_wrapper google-chrome-stable /usr/bin/google-chrome-stable
        if [ -x "$_r/usr/bin/google-chrome" ]; then _ncz_bp_wrapper google-chrome /usr/bin/google-chrome; else _ncz_bp_wrapper google-chrome /usr/bin/google-chrome-stable; fi
    fi
    # Desktop-icon copies (52/53 copy the packaged file, /usr/bin exec, VA-API on).
    for _pair in "Vivaldi.desktop:vivaldi-stable.desktop" "Google-Chrome.desktop:google-chrome.desktop"; do
        _icon=${_pair%%:*}; _id=${_pair#*:}
        [ -f "$_local/$_id" ] || continue
        for _d in "$_r/etc/skel/Desktop" "$_r"/home/*/Desktop; do
            [ -f "$_d/$_icon" ] || continue
            cat "$_local/$_id" > "$_d/$_icon"    # cat > keeps the owner of a user's copy
        done
    done
    [ -n "$_overrides" ] && _ncz_bp_log "VA-API-off launchers:$_overrides (+ /usr/local/bin wrappers)"

    # --- 2. default browser -> chromium-ncz-sky1 --------------------------------
    if [ ! -x "$_r/usr/bin/chromium-ncz-sky1" ]; then
        _ncz_bp_log "WARN: /usr/bin/chromium-ncz-sky1 missing; default browser left unchanged"
        return 0
    fi
    _cid=chromium-ncz-sky1.desktop
    if [ ! -f "$_apps/$_cid" ]; then
        _found=$(grep -l '^Exec=.*chromium-ncz-sky1' "$_apps"/*.desktop 2>/dev/null | head -1)
        [ -n "$_found" ] && _cid=${_found##*/}
    fi
    if [ "${NCZ_BROWSER_NO_ALTERNATIVES:-0}" != 1 ] && command -v update-alternatives >/dev/null 2>&1; then
        for _alt in x-www-browser gnome-www-browser; do
            update-alternatives --install "/usr/bin/$_alt" "$_alt" /usr/bin/chromium-ncz-sky1 600 >/dev/null 2>&1
            update-alternatives --set "$_alt" /usr/bin/chromium-ncz-sky1 >/dev/null 2>&1 || _ncz_bp_log "WARN: could not select $_alt"
        done
    fi
    mkdir -p "$_r/etc/xdg" "$_r/etc/skel/.config"
    _ncz_bp_mimeapps "$_r/etc/xdg/mimeapps.list" "$_cid" system
    _ncz_bp_mimeapps "$_r/etc/skel/.config/mimeapps.list" "$_cid" system
    for _m in "$_r"/home/*/.config/mimeapps.list; do
        [ -f "$_m" ] && _ncz_bp_mimeapps "$_m" "$_cid" user
    done
    _ncz_bp_log "default browser: $_cid (x-www-browser, gnome-www-browser, mimeapps)"
    return 0
}
