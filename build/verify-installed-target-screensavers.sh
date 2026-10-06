#!/bin/bash
# verify-installed-target-screensavers.sh -- section (vi) of
# verify-installed-target.sh. Sourced, not executed: it shares gate_miss,
# fetch, exists, lsnames, TMP, HERE_VT and sets SS_STATUS / SS_PLUGIN for the
# [fact] lines the caller emits. Split out so the review hunk stays under
# 9000 bytes.
#
# --- (vi) ncz-screensavers (mandatory on desktop images; operator 2026-10-05) ---------
# Intent, in order: VERIFY_EXPECT_SCREENSAVERS=1|0 from the caller (the gate sets it
# from the checkout's manifests/install-extra.pkgs); else auto = the target's own
# manifest asks for it or the package is already present in its dpkg database. A
# silent skip here once hid a missing assertion, so "not requested" is only
# reachable when nothing points at the package.
#
# What the PUBLISHED package (ncz-screensavers 0.8.9+, amd64+arm64) ships --
# verified against the actual 0.8.9 .deb, not against its Description:
#   * the engine            /usr/bin/ncz-screensaver
#   * the idle daemon       /usr/libexec/ncz-screensaver-idled (+ -run, user unit)
#   * the calibrator        /usr/libexec/ncz-screensavers/ncz-screensaver-calibrate
#   * the gschema           /usr/share/glib-2.0/schemas/dev.ncz.screensaver.gschema.xml
#   * the 74-title catalogue /usr/share/ncz-screensavers/hacks.tsv, one binary
#     per title under /usr/lib/ncz-screensavers/<hack-id>
# It does NOT ship the Singularity plugin (libscreensaver.so +
# screensaver.plugin), the GTK4 settings app, or a launcher .desktop entry.
# The plugin ships in a separate ncz-screensavers-plugin package that is not
# published yet (the deb's own Description: "The settings UI ... is the
# Singularity plugin (ncz-screensavers-plugin, installed by the NCZ-OS
# image)"). We therefore assert exactly the 0.8.9 contents above, and treat
# the plugin files as required ONLY when that package is installed. An
# earlier draft asserted the plugin files unconditionally and asserted a
# settings app + .desktop entry the package never shipped -- both would have
# failed every healthy install.
#
# The operator rule "default saver = blackhole" has TWO parts: the package
# schema default (hack-id='blackhole_gles3') and the Cygnus override that
# 62-cygnus-screensaver-default.sh writes at install time (mode='one' +
# blackhole-color-mode='cygnus'). The package schema default alone is
# mode='off' -- no animated saver -- so both are asserted; checking the
# schema default by itself is a tautology that could never fail.
WANT_SS="${VERIFY_EXPECT_SCREENSAVERS:-auto}"
if [ "$WANT_SS" = auto ]; then
    WANT_SS=0
    if fetch /usr/local/lib/cix-installer/manifests/install-extra.pkgs "$TMP/extra.pkgs" && sed 's/#.*//' "$TMP/extra.pkgs" | awk 'NF {print $1}' | grep -qx ncz-screensavers; then WANT_SS=1; fi
    grep -q '^Package: ncz-screensavers$' "$TMP/dpkg-status" 2>/dev/null && WANT_SS=1
fi
SS_STATUS=""; SS_PLUGIN=""
if [ "$WANT_SS" = 1 ]; then
    echo "[verify-target] (vi) ncz-screensavers"
    SS_STATUS="$(awk 'BEGIN{RS="";FS="\n"} { pk=""; st=""; ver=""; for(i=1;i<=NF;i++){ if($i ~ /^Package: /) pk=substr($i,10); if($i ~ /^Status: /) st=substr($i,9); if($i ~ /^Version: /) ver=substr($i,10)} if(pk=="ncz-screensavers" && st=="install ok installed") print ver }' "$TMP/dpkg-status" 2>/dev/null)"
    # shellcheck disable=SC2034  # read by the caller and the default sibling
    SS_PLUGIN="$(awk 'BEGIN{RS="";FS="\n"} { pk=""; st=""; ver=""; for(i=1;i<=NF;i++){ if($i ~ /^Package: /) pk=substr($i,10); if($i ~ /^Status: /) st=substr($i,9); if($i ~ /^Version: /) ver=substr($i,10)} if(pk=="ncz-screensavers-plugin" && st=="install ok installed") print ver }' "$TMP/dpkg-status" 2>/dev/null)"
    if [ -z "$SS_STATUS" ]; then
        gate_miss screensavers "ncz-screensavers is not installed (59-ncz-screensavers-pkg did not install it)"
    else
        echo "[verify-target]     ncz-screensavers $SS_STATUS installed"
        # (a) version floor: single source of truth, same file the install
        #     hook, the mirror builders and the pre-flights source. It sits
        #     next to this script (build/); if a copy of the verifier is run
        #     without it, the floor check is skipped (the install hook already
        #     enforced it at install time).
        NCZ_SS_FLOOR=""
        if [ -r "$HERE_VT/screensavers-version.env" ]; then
            # shellcheck disable=SC1090
            . "$HERE_VT/screensavers-version.env"
            NCZ_SS_FLOOR="${NCZ_SCREENSAVERS_MIN_VERSION:-}"
        fi
        # Phase 2: the registry floor must agree with the env file. The
        # installed version is still compared against the env floor, so a
        # target that passed before this change still passes.
        if [ -f "$HERE_VT/components.py" ] && [ -n "$NCZ_SS_FLOOR" ]; then
            _ss_reg_floor="$(python3 "$HERE_VT/components.py" --root "$(cd "$HERE_VT/.." && pwd)" query --name ncz-screensavers --kind staged-deb --field version_floor 2>/dev/null || true)"
            if [ -n "$_ss_reg_floor" ] && [ "$_ss_reg_floor" != "$NCZ_SS_FLOOR" ]; then
                gate_miss screensavers "registry floor ${_ss_reg_floor} disagrees with screensavers-version.env floor $NCZ_SS_FLOOR"
            fi
        fi
        if [ -n "$NCZ_SS_FLOOR" ] && ! dpkg --compare-versions "$SS_STATUS" ge "$NCZ_SS_FLOOR"; then
            gate_miss screensavers "ncz-screensavers $SS_STATUS is below the required floor $NCZ_SS_FLOOR (build/screensavers-version.env)"
        elif [ -n "$NCZ_SS_FLOOR" ]; then
            echo "[verify-target]     ncz-screensavers $SS_STATUS >= floor $NCZ_SS_FLOOR"
        fi
        # (b) exactly the files the published package ships -- no more, no
        #     less (a settings app / .desktop entry / plugin files are NOT
        #     in 0.8.9 and must not be asserted).
        for f in /usr/bin/ncz-screensaver \
                 /usr/libexec/ncz-screensaver-idled \
                 /usr/libexec/ncz-screensaver-run \
                 /usr/libexec/ncz-screensavers/ncz-screensaver-calibrate \
                 /usr/lib/systemd/user/ncz-screensaver-idled.service \
                 /usr/share/glib-2.0/schemas/dev.ncz.screensaver.gschema.xml \
                 /usr/share/ncz-screensavers/hacks.tsv; do
            exists "$f" || gate_miss screensavers "$f"
        done

        # (c) shipped 74-title catalogue: every non-comment row is a Title
        #     (a row with no Title field is an empty stub), and EVERY title
        #     must have its binary under /usr/lib/ncz-screensavers/.
        if fetch /usr/share/ncz-screensavers/hacks.tsv "$TMP/hacks.tsv"; then
            NCZ_UTENS="$(awk -F'\t' '!/^#/ && NF >= 3 && $2 != "" {n++} END{print n+0}' "$TMP/hacks.tsv")"
            if [ "$NCZ_UTENS" -lt 74 ]; then
                gate_miss screensavers "shipped catalogue has only $NCZ_UTENS non-empty Title rows (need >= 74)"
            else
                echo "[verify-target]     shipped catalogue rows: $NCZ_UTENS (>= 74)"
            fi
            if lsnames /usr/lib/ncz-screensavers > "$TMP/hackbins" 2>/dev/null; then
                while IFS= read -r _ncz_hid; do
                    [ -n "$_ncz_hid" ] || continue
                    grep -qx "$_ncz_hid" "$TMP/hackbins" || gate_miss screensavers "catalogue title '$_ncz_hid' has no binary /usr/lib/ncz-screensavers/$_ncz_hid"
                done < <(awk -F'\t' '!/^#/ && NF >= 3 && $2 != "" {print $1}' "$TMP/hacks.tsv")
            else
                gate_miss screensavers "/usr/lib/ncz-screensavers unreadable (hack binaries)"
            fi
        else
            gate_miss screensavers "hacks.tsv present but unreadable"
        fi
        # (d) the schema must be compiled into gschemas.compiled or the settings
        #     UI and the idle timer cannot read it
        if fetch /usr/share/glib-2.0/schemas/gschemas.compiled "$TMP/gschemas.compiled" && grep -aq 'dev.ncz.screensaver' "$TMP/gschemas.compiled"; then
            :;
        else
            gate_miss screensavers "dev.ncz.screensaver missing from gschemas.compiled (glib-compile-schemas did not run)"
        fi

        # shellcheck source=./verify-installed-target-screensavers-default.sh
        . "$HERE_VT/verify-installed-target-screensavers-default.sh"
    fi
else
    echo "[verify-target] (vi) ncz-screensavers not requested by this image; skipped"
fi
