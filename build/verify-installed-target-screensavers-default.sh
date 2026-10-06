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
            if fetch /opt/singularity/share/glib-2.0/schemas/99-zz-ncz-screensaver-plugin.gschema.override "$TMP/ss.plugin-override" && grep -q "^enabled-plugins=.*'screensaver'" "$TMP/ss.plugin-override"; then :; else
                gate_miss screensavers "the default enabled-plugins does not contain 'screensaver' (99-zz-ncz-screensaver-plugin.gschema.override missing or wrong): new users would not get the Settings page"
            fi
        else
            echo "[verify-target]     ncz-screensavers-plugin: not expected by this image (no plugin pin on the target) and not installed"
        fi
