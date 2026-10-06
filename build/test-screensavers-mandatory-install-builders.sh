#!/bin/bash
# Sections (3)-(7) of the screensaver mandatory-install test. Sourced.
[ -n "${NCZ_SS_TEST_DRIVING:-}" ] || exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-screensavers-mandatory-install.sh"

# (3) build-desktop-mirror.sh: ncz-screensavers required, floor sourced.
BDM="$ROOT/build/build-desktop-mirror.sh"
if [ -r "$BDM" ]; then
    # The row must end in "|required" (the third pipe-separated value).
    if grep -E '^ncz-screensavers\|.*\|required[[:space:]]*$' "$BDM" >/dev/null; then
        ok "build-desktop-mirror.sh marks ncz-screensavers as required"
    else
        bad "build-desktop-mirror.sh still lists ncz-screensavers as optional"
    fi

    # No NCZ_LOCAL_DEBS data line for ncz-screensavers-plugin: it is carried on
    # the medium, not the stage-0 pool (a comment referencing it is fine).
    if grep -E '^ncz-screensavers-plugin\|.*\|(optional|required)' "$BDM" >/dev/null; then
        bad "build-desktop-mirror.sh seeds ncz-screensavers-plugin into the stage-0 pool (it must travel with the payload)"
    else
        ok "build-desktop-mirror.sh does not seed ncz-screensavers-plugin into the stage-0 pool"
    fi

    if grep -q 'screensavers-version.env' "$BDM"; then
        ok "build-desktop-mirror.sh sources build/screensavers-version.env"
    else
        bad "build-desktop-mirror.sh does NOT source build/screensavers-version.env"
    fi
else
    bad "build-desktop-mirror.sh missing"
fi

# ---------------------------------------------------------------------------
# (4) build-squashfs-layers.sh + build-role-delta-mkosi.sh -- the consumers
#     of desktop-mirror. Both must pre-flight the mirror the DESKTOP layer
#     actually installs from (desktop-mirror when MIRROR_DIRS is not
#     overridden), not the base role's suite/vendor mirrors, and only for the
#     stages that build a desktop layer. assert-mirror's own fail/pass
#     behaviour is covered by the cases in section (1) above.
# ---------------------------------------------------------------------------
SQFS="$ROOT/build/build-squashfs-layers.sh"
if [ -r "$SQFS" ]; then
    if grep -q 'assert-mirror-has-screensavers.sh' "$SQFS" \
       && grep -q 'desktop|all)' "$SQFS" \
       && grep -q '_ss_effective="desktop-mirror"' "$SQFS"; then
        ok "build-squashfs-layers.sh pre-flights desktop-mirror for ncz-screensavers (desktop|all only)"
    else
        bad "build-squashfs-layers.sh pre-flights the wrong mirror or the wrong stages"
    fi
else
    bad "build-squashfs-layers.sh missing"
fi

RD="$ROOT/build/build-role-delta-mkosi.sh"
if [ -r "$RD" ]; then
    if grep -q 'assert-mirror-has-screensavers.sh' "$RD" \
       && grep -q 'desktop) MIRROR_DIRS="desktop-mirror"' "$RD" \
       && grep -q 'assert-mirror-has-screensavers.sh" \$_ss_mirrors --arch "\$ARCH"' "$RD"; then
        ok "build-role-delta-mkosi.sh pre-flights desktop-mirror for ncz-screensavers (target arch)"
    else
        bad "build-role-delta-mkosi.sh does NOT pre-flight desktop-mirror with the target arch"
    fi
else
    bad "build-role-delta-mkosi.sh missing"
fi

# ---------------------------------------------------------------------------
# (5) post-install/24-apt-sources.sh -- live update path. The fixed hook
#     verifies at least one NCZ-OS apt source resolves ncz-screensavers so
#     `apt upgrade` on a running image can pull newer screensaver debs.
# ---------------------------------------------------------------------------
S24="$ROOT/post-install/24-apt-sources.sh"
if [ -r "$S24" ]; then
    # The canary must distinguish an NCZ-OS *network* origin from the
    # install-time /cdrom pool, otherwise it can pass while both live sources
    # are dead (20-desktop.sh registers file:///cdrom before 24 runs).
    if grep -q 'NCZ-OS apt sources carry ncz-screensavers' "$S24" \
       && grep -q 'packages\.buildkite\.com/ncz-os/ncz' "$S24" \
       && grep -q 'pub-d7b784e01679403d9c70fcd23fff5b96\.r2\.dev' "$S24" \
       && grep -q 'only from the offline /cdrom pool' "$S24"; then
        ok "24-apt-sources.sh proves the candidate comes from an NCZ-OS network source, not only /cdrom"
    else
        bad "24-apt-sources.sh does NOT distinguish an NCZ-OS network origin from the offline /cdrom pool"
    fi
fi

# ---------------------------------------------------------------------------
# (6) build/verify-installed-target.sh -- the post-install assertion. The
#     fixed verifier asserts what the PUBLISHED 0.8.9 deb actually ships:
#     the engine + idle timer + calibrator + schema + the shipped 74-title
#     catalogue (each title backed by its binary) + idle daemon enabled +
#     schema compiled + the operator "default saver = blackhole" rule
#     (package schema default AND the effective Cygnus override), and treats
#     the Singularity plugin files as required when the image pins the
#     separate ncz-screensavers-plugin package (or it is installed).
# ---------------------------------------------------------------------------
VIT="$ROOT/build/verify-installed-target.sh"
# Section (vi) is sourced from these siblings; search the set, not only the parent.
VIT_SET="$VIT $ROOT/build/verify-installed-target-screensavers.sh $ROOT/build/verify-installed-target-screensavers-default.sh"
if [ -r "$VIT" ]; then
    # The plugin contract follows the image's intent: required when the image
    # pins the plugin (WANT_SSP, from the pin file) or it is installed, and
    # never attributed to the engine package (which ships no plugin files).
    if grep -q 'if \[ "${WANT_SSP:-0}" = 1 \] || \[ -n "$SS_PLUGIN" \]' $VIT_SET && ! grep -q 'shipped by ncz-screensavers' $VIT_SET \
       && grep -q 'ncz-screensavers-plugin.lock' $VIT_SET; then
        ok "verify-installed-target.sh requires the plugin when the image pins it (or it is installed)"
    else
        bad "verify-installed-target.sh does not tie the plugin requirement to the image's plugin pin"
    fi

    if grep -q 'need >= 74' $VIT_SET; then
        ok "verify-installed-target.sh asserts >= 74 catalogue rows"
    else
        bad "verify-installed-target.sh does NOT assert the 74-title catalogue"
    fi

    # every catalogue title must have its binary
    if grep -q 'has no binary /usr/lib/ncz-screensavers/' $VIT_SET; then
        ok "verify-installed-target.sh asserts each catalogue title has its binary"
    else
        bad "verify-installed-target.sh does NOT check catalogue binaries exist"
    fi

    # the version floor is enforced from the single source of truth
    if grep -q 'NCZ_SCREENSAVERS_MIN_VERSION' $VIT_SET && grep -q 'compare-versions' $VIT_SET; then
        ok "verify-installed-target.sh enforces the version floor from screensavers-version.env"
    else
        bad "verify-installed-target.sh does NOT enforce the version floor"
    fi

    # both parity facts are emitted (screensaver_plugin_version was dropped by
    # an earlier draft, breaking verify-dual-arch-parity.sh's fact comparison)
    if grep -q '\[fact\] screensaver_plugin_version=' "$VIT"; then
        ok "verify-installed-target.sh emits the screensaver_plugin_version fact"
    else
        bad "verify-installed-target.sh does NOT emit the screensaver_plugin_version fact (parity check breaks)"
    fi

    # the effective default: the package schema default is mode='off', so the
    # Cygnus override (mode='one' + blackhole + cygnus palette) is what makes
    # "default saver = blackhole" true end to end.
    if grep -q "99-ncz-cygnus-screensaver.gschema.override" $VIT_SET && grep -q "blackhole-color-mode='cygnus'" $VIT_SET; then
        ok "verify-installed-target.sh asserts the effective Cygnus blackhole default"
    else
        bad "verify-installed-target.sh does NOT assert the effective (Cygnus override) default saver"
    fi
fi

# (7) Hook 57 retirement: gone from inventory, both hook lists, and disk.
INV="$ROOT/docs/platform-inventory.tsv"
if [ -r "$INV" ]; then
    if grep -qE 'post-install/57-screensaver\.sh' "$INV"; then
        bad "platform-inventory.tsv still lists post-install/57-screensaver.sh"
    else
        ok "platform-inventory.tsv no longer lists post-install/57-screensaver.sh"
    fi
fi
for plat in amd64 sky1-arm64; do
    lst="$ROOT/post-install/hooks.list.$plat"
    if [ -r "$lst" ]; then
        if grep -q '^57-screensaver\.sh$' "$lst"; then
            bad "hooks.list.$plat still contains 57-screensaver.sh"
        else
            ok "hooks.list.$plat no longer contains 57-screensaver.sh"
        fi
    fi
done
if [ -r "$ROOT/post-install/57-screensaver.sh" ]; then
    bad "post-install/57-screensaver.sh still on disk"
else
    ok "post-install/57-screensaver.sh deleted"
fi

echo
