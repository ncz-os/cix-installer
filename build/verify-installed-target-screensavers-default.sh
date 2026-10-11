# shellcheck shell=bash
# verify-installed-target-screensavers-default.sh -- continuation of section
# (vi), sourced from inside the installed-package branch of
# verify-installed-target-screensavers.sh. Checks (e) schema default,
# (e2) Cygnus override, (f) idle timer, (g) gtk4-reference ban, (h) plugin.
# Shares gate_miss, fetch, exists, lsnames, TMP, SS_PLUGIN, WANT_SSP, SSP_PIN_VER.
        # (e) operator rule "default saver = blackhole", part 1: the PACKAGE
        #     schema default. Multiline match: the key header on one line, the
        #     <default> on a later line inside the same <key> block.
        if fetch /usr/share/glib-2.0/schemas/dev.ncz.screensaver.gschema.xml "$TMP/ss.schema.xml"; then
            ss_default="$(awk '
                /<key name="hack-id"/ { found = 1; next }
                found && /<\/key>/      { found = 0 }
                found && /<default>/    {
                    v = $0
                    sub(/^[[:space:]]*<default>/, "", v)
                    sub(/<\/default>.*$/, "", v)
                    gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
                    print v
                }
            ' "$TMP/ss.schema.xml")"
            if [ "$ss_default" = "'blackhole_gles3'" ]; then
                echo "[verify-target]     package schema default hack-id: blackhole_gles3"
            else
                gate_miss screensavers "package schema default hack-id is '$ss_default', expected 'blackhole_gles3' (operator 2026-10-05: default saver must be blackhole)"
            fi
        else
            gate_miss screensavers "schema dev.ncz.screensaver.gschema.xml not present"
        fi
        # (e2) operator rule, part 2: the EFFECTIVE default. The package schema
        #     ships mode='off' (no animated saver), so without the Cygnus
        #     override the system's default is "off", not blackhole. The
        #     override is written by 62-cygnus-screensaver-default.sh at
        #     install time (it self-validates with glib-compile-schemas
        #     --dry-run before installing and never fails the install -- so a
        #     missing override is real information: 62 skipped or validation
        #     refused).
        if fetch /usr/share/glib-2.0/schemas/99-ncz-cygnus-screensaver.gschema.override "$TMP/ss.cygnus-override" \
           && grep -q "^mode='one'" "$TMP/ss.cygnus-override" \
           && grep -q "^hack-id='blackhole_gles3'" "$TMP/ss.cygnus-override" \
           && grep -q "^blackhole-color-mode='cygnus'" "$TMP/ss.cygnus-override"; then
            echo "[verify-target]     effective default: blackhole_gles3 / cygnus palette (override present)"
        else
            gate_miss screensavers "Cygnus screensaver override missing or incomplete (99-ncz-cygnus-screensaver.gschema.override needs mode='one' + hack-id='blackhole_gles3' + blackhole-color-mode='cygnus'; the package default alone is mode='off')"
        fi
        # (f) the idle timer is enabled, and the older swayidle idle manager is NOT
        #     (they would both lock the session)
        idled=0; oldidle=0
        for w in $(lsnames /etc/systemd/user | grep '\.wants$'); do
            lsnames "/etc/systemd/user/$w" | grep -qx 'ncz-screensaver-idled.service' && idled=1
            lsnames "/etc/systemd/user/$w" | grep -qx 'ncz-idle-manager.service' && oldidle=1
        done
        [ "$idled" = 1 ] || gate_miss screensavers "ncz-screensaver-idled.service is not enabled (no .wants symlink under /etc/systemd/user)"
        [ "$oldidle" = 0 ] || gate_miss screensavers "ncz-idle-manager.service is still enabled next to ncz-screensaver-idled (legacy hook 57 left running)"
        # (f2) the desktop idle LOCK is ordered AFTER the saver (operator 2026-10-11).
        #      The shell locks at dev.sinty.lockscreen:idle-delay; the saver starts at
        #      dev.ncz.screensaver:hack-idle-delay. Because ext-session-lock-v1 is
        #      EXCLUSIVE, a lock at or before the saver means the lock surface wins the
        #      race and the layer-shell saver never shows (observed on PROTEUS: the shell
        #      locked at 300s, the saver never ran). 63-ncz-idle-lock-order.sh writes the
        #      override that keeps the lock strictly later.
        if fetch /opt/singularity/share/glib-2.0/schemas/99-ncz-idle-lock-order.gschema.override "$TMP/ss.lockorder" \
           && fetch /usr/share/glib-2.0/schemas/dev.ncz.screensaver.gschema.xml "$TMP/ss.lockorder-saver"; then
            _lock_at="$(sed -n 's/^idle-delay=//p' "$TMP/ss.lockorder" | tail -1 | tr -dc '0-9')"
            _saver_at="$(awk '
                /<key name="hack-idle-delay"/ { found = 1 }
                found && /<default>/ { v = $0; sub(/^.*<default>/, "", v); sub(/<\/default>.*$/, "", v); gsub(/[^0-9]/, "", v); if (v != "") { print v; exit } }
                found && /<\/key>/ { found = 0 }
            ' "$TMP/ss.lockorder-saver" 2>/dev/null)"
            if [ -z "$_lock_at" ] || [ -z "$_saver_at" ] || [ "$_lock_at" -le "$_saver_at" ]; then
                gate_miss screensavers "desktop idle lock is not ordered after the screensaver: 99-ncz-idle-lock-order override idle-delay='${_lock_at:-none}', saver hack-idle-delay='${_saver_at:-unknown}'; the lock must fire strictly after the saver or it hides it (post-install/63-ncz-idle-lock-order.sh)"
            else
                echo "[verify-target]     idle lock ordered after the saver (lock ${_lock_at}s > saver ${_saver_at}s)"
            fi
        else
            gate_miss screensavers "idle-lock-order override missing (/opt/singularity/share/glib-2.0/schemas/99-ncz-idle-lock-order.gschema.override): the desktop lock can fire with the screensaver and hide it (hook 63)"
        fi
        # (g) the GTK4 reference app is for OTHER distros
        grep -q '^Package: ncz-screensavers-gtk4-reference$' "$TMP/dpkg-status" 2>/dev/null && gate_miss screensavers "ncz-screensavers-gtk4-reference is installed on NCZ-OS (it must not be)"
        # (h) the Singularity "Screensaver and Lockscreen" settings plugin
        #     (ncz-screensavers-plugin, pinned deb on the install medium, hook 59).
        #     Expected (WANT_SSP=1): the package at the pinned version, its .so and
        #     .plugin, and the override that enables it for new users. Not
        #     expected and not installed: skipped, said so.
        if [ "${WANT_SSP:-0}" = 1 ] || [ -n "$SS_PLUGIN" ]; then
            if [ -z "$SS_PLUGIN" ]; then
                gate_miss screensavers "ncz-screensavers-plugin is expected (pinned ${SSP_PIN_VER:-?}) but not installed: hook 59 refused it (pin/ABI, see 59-ncz-screensavers-pkg.log) or the deb was not on the medium"
            else
                echo "[verify-target]     ncz-screensavers-plugin $SS_PLUGIN installed"
                if [ -n "${SSP_PIN_VER:-}" ] && [ "$SS_PLUGIN" != "$SSP_PIN_VER" ]; then
                    gate_miss screensavers "ncz-screensavers-plugin $SS_PLUGIN installed, the image pins $SSP_PIN_VER"
                fi
            fi
            for f in /opt/singularity/lib/singularity/plugins/screensaver/libscreensaver.so \
                     /opt/singularity/lib/singularity/plugins/screensaver/screensaver.plugin; do
                exists "$f" || gate_miss screensavers "$f (Singularity screensaver plugin)"
            done
            # the plugin page reads Version and Icon from the plugin file: "Version Unknown" and a
            # generic icon mean a file without them
            if fetch /opt/singularity/lib/singularity/plugins/screensaver/screensaver.plugin "$TMP/ss.plugin-file"; then
                _ssp_mv="$(sed -n 's/^Version=//p' "$TMP/ss.plugin-file" | head -n 1)"
                _ssp_mi="$(sed -n 's/^Icon=//p' "$TMP/ss.plugin-file" | head -n 1)"
                if [ -n "$SS_PLUGIN" ] && [ "$_ssp_mv" != "$SS_PLUGIN" ]; then
                    gate_miss screensavers "screensaver.plugin says Version='${_ssp_mv}' but ncz-screensavers-plugin $SS_PLUGIN is installed (the plugin page would show Version Unknown or a stale version)"
                fi
                if [ -z "$_ssp_mi" ] || ! exists "/opt/singularity/share/icons/hicolor/scalable/apps/${_ssp_mi}.svg"; then
                    gate_miss screensavers "screensaver.plugin Icon='${_ssp_mi}' has no /opt/singularity/share/icons/hicolor/scalable/apps/${_ssp_mi}.svg (generic icon on the plugin page)"
                fi
            fi
            # a plugin in the lock category needs a shell whose Plugins page has that row
            # (an older shell lists it under Other)
            _ssp_mc="$(sed -n 's/^X-Singularity-Category=//p' "$TMP/ss.plugin-file" 2>/dev/null | head -n 1)"
            if [ "$_ssp_mc" = lock ]; then
                if ! fetch /opt/singularity/bin/singularity-desktop "$TMP/ss.shell-bin" || ! grep -aq 'Screensaver and Lock' "$TMP/ss.shell-bin"; then
                    gate_miss screensavers "screensaver.plugin declares X-Singularity-Category=lock but the installed shell has no Screensaver and Lock row (the plugin would sit in Other)"
                fi
                rm -f "$TMP/ss.shell-bin"
            fi
            if fetch /opt/singularity/share/glib-2.0/schemas/99-zz-ncz-screensaver-plugin.gschema.override "$TMP/ss.plugin-override" && grep -q "^enabled-plugins=.*'screensaver'" "$TMP/ss.plugin-override"; then :; else
                gate_miss screensavers "the default enabled-plugins does not contain 'screensaver' (99-zz-ncz-screensaver-plugin.gschema.override missing or wrong): new users would not get the Settings page"
            fi
        else
            echo "[verify-target]     ncz-screensavers-plugin: not expected by this image (no plugin pin on the target) and not installed"
        fi
