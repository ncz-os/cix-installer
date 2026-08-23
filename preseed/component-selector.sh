#!/bin/sh
# component-selector.sh — NCZ installer interactive COMPONENT SELECTOR.
# Invoked from preseed/early_command (see preseed.cfg), before
# disk-fs-chooser.sh, so the rescue-partition choice is available when
# disk-fs-chooser.sh builds its partman recipe.
#
# WHY a custom chooser (same reasoning as the two existing choosers): the ISO
# boots d-i at priority=critical so finish-install auto-reboots cleanly. At
# critical priority EVERY d-i native question is auto-answered silently. The
# only thing that IS shown is a question explicitly db_input'd at CRITICAL
# priority. So we register our own cdebconf `multiselect` template and
# db_input it at CRITICAL, which forces a real on-screen prompt even under
# the critical threshold.
#
# WHAT IT TOGGLES (five opt-OUT toggles; default = all selected = today's
# behaviour, so an operator who accepts the prompt unchanged gets exactly
# what the previous installer shipped):
#
#   desktop             — Singularity desktop overlay (desktop.squashfs) +
#                         desktop-only post-install hooks (greeter, brand,
#                         boot-splash, etc.). OFF = console-only system,
#                         default rEFInd entry retargeted at cixmini-console.
#   browsers            — Vivaldi + Chrome brand hooks. Only meaningful when
#                         desktop is ON; silently ignored otherwise.
#   mgmt-container      — ncz-recovery systemd-nspawn container (38-recovery-
#                         container.sh). OFF = no recovery tier installed.
#   rescue-partition    — 4 GiB NCZRESCUE ext4 partition (72-rescue-partition.sh).
#                         OFF = partman recipe drops the rescue stanza (root
#                         partition becomes p2; total 2-partition recipe).
#                         TOUCHES PARTITIONING — disk-fs-chooser.sh reads
#                         /tmp/ncz-components and reuses its fail-closed
#                         pattern (verify pin before wipe, exact recipe match).
#   wallpaper-rotator   — Bing daily wallpaper + 10-min autoswitcher
#                         (45-wallpaper-rotator.sh). Requires desktop.
#
# Persistence: writes two locations:
#   /tmp/ncz-components                 — consumed by disk-fs-chooser.sh
#                                         (partman/early_command, d-i env)
#                                         and extract-rootfs.sh
#                                         (partman/late_command, d-i env).
#   /target/usr/local/lib/cix-installer/COMPONENTS
#                                       — consumed by post-install hooks
#                                         (run-all.sh, 70-bootloader.sh) that
#                                         run inside the chroot.
# Both empty / both carry the full list: an operator who accepts the default
# ("all selected") is bit-identical to a pre-component-selector install.
#
# SAFETY DOCTRINE: this script is NOT destructive on its own — it only writes
# two files. The destructive peers (disk-fs-chooser.sh for rescue-partition,
# extract-rootfs.sh for desktop overlay, run-all.sh for the hooks) each re-read
# the file and apply their own fail-closed checks. A blank / missing file is
# treated as "all components enabled" (the legacy default) so a chooser crash
# CANNOT silently degrade the install.
#
# TEST/UNATTENDED override: kernel cmdline `ncz_components=desktop,browsers,...`
# (comma-separated, matching the multiselect answer format) skips the prompt
# entirely. Any token NOT in the offered set is dropped silently. Empty +
# absent override → prompt is shown. This is how the KVM install gate and
# any other unattended pipeline runs without a human present.
set +e

. /usr/share/debconf/confmodule 2>/dev/null || . /usr/lib/cdebconf/confmodule 2>/dev/null || true

log() { echo "[ncz components] $*"; echo "[ncz components] $*" > /dev/tty3 2>/dev/null || true; }

# --- curated candidate list -------------------------------------------------
# Order here is the order shown in the multiselect AND the unique stencil for
# the comma-separated answer / cmdline override. Add a name here + wire it
# into the consumers (disk-fs-chooser.sh for rescue-partition, extract-rootfs.
# sh for desktop, run-all.sh for hooks) and the toggle is real.
COMPONENTS="\
desktop:Full Singularity desktop (GUI labwc + greetd + branding)\
|browsers:Bundled browsers (Vivaldi + Chrome)\
|mgmt-container:ncz-recovery management container (nspawn)\
|rescue-partition:4 GiB NCZRESCUE partition (rescue rootfs + kernel)\
|wallpaper-rotator:7-wallpaper + 10-min Bing autoswitcher"

# Validate a token against the offered set (posix sh + grep -qx).
component_is_offered() {
    _want="$1"
    printf '%s\n' "$COMPONENTS" | tr '|' '\n' | cut -d: -f1 | grep -qx "$_want"
}

# --- read cmdline override --------------------------------------------------
CMD=$(cat /proc/cmdline 2>/dev/null)
OVR=""
for tok in $CMD; do
    case "$tok" in
        ncz_components=*) OVR="${tok#ncz_components=}" ;;
    esac
done

# --- build the question -----------------------------------------------------
# The full candidate set is the default answer (opt-OUT: today's behaviour).
# That keeps a prompt the operator just hits OK on bit-identical to a pre-
# component-selector install.
_DEFAULT=""
_OFFERED=""
_LONG=""
_oldifs=$IFS; IFS='|'
for line in $COMPONENTS; do
    code=${line%%:*}; desc=${line#*:}
    [ -z "$_DEFAULT" ] && _DEFAULT="$code" || _DEFAULT="$_DEFAULT, $code"
    [ -z "$_OFFERED" ] && _OFFERED="$code" || _OFFERED="$_OFFERED, $code"
    _LONG="$_LONG  $code — $desc\\n"
done
IFS=$_oldifs

# Validate the cmdline override tokens (drop unknown ones, with a warning).
# Operator expectation: an unattended override list is a STRICT SUBSET of
# the offered set; misspelled tokens are NOT silently dropped-but-applied.
_OVR_FILTERED=""
if [ -n "$OVR" ]; then
    _ov_old=$IFS; IFS=','
    for _tok in $OVR; do
        _tok=$(echo "$_tok" | tr -d ' \t')
        [ -z "$_tok" ] && continue
        if component_is_offered "$_tok"; then
            [ -z "$_OVR_FILTERED" ] && _OVR_FILTERED="$_tok" || _OVR_FILTERED="$_OVR_FILTERED, $_tok"
        else
            log "WARNING: ncz_components=$_tok is not an offered component — dropping"
        fi
    done
    IFS=$_ov_old
fi

CHOSEN=""
if [ -n "$_OVR_FILTERED" ]; then
    CHOSEN="$_OVR_FILTERED"
    log "cmdline override: components = $CHOSEN"
else
    if [ -n "$OVR" ]; then
        # override was present but resolved to empty (all tokens unknown) —
        # fall back to the prompt so the operator can recover
        log "cmdline ncz_components= had no valid tokens — falling back to prompt"
    fi
    cat > /tmp/ncz-components.templates <<TPL
Template: ncz/components
Type: multiselect
Choices: ${_OFFERED}
Default: ${_DEFAULT}
Description: NCZ-OS install — select which OPTIONAL COMPONENTS to install
 Untick to skip an optional component. Default (Enter OK) = all of the
 below installed, which is exactly what the previous installer shipped.
 .
  desktop          — toggle the Singularity desktop GUI on/off (this is the
                     full desktop overlay + all desktop hooks; OFF = console)
  browsers         — Vivaldi + Chrome only (no effect without desktop)
  mgmt-container   — ncz-recovery nspawn container (rescue tier)
  rescue-partition — 4 GiB NCZRESCUE partition (rescue rootfs + boot entry)
  wallpaper-rotator— 7-wallpaper + 10-min Bing autoswitch (requires desktop)
 .
${_LONG}
TPL
    if debconf-loadtemplate ncz /tmp/ncz-components.templates 2>/dev/null; then
        db_set     ncz/components "$_DEFAULT" 2>/dev/null || true
        db_fset    ncz/components seen false   || true
        db_settitle ncz/components 2>/dev/null
        if db_input critical ncz/components && db_go; then
            db_get ncz/components && CHOSEN="$RET"
        else
            log "WARNING: component prompt could not be shown/completed — using default (all enabled)"
            CHOSEN="$_DEFAULT"
        fi
    else
        log "WARNING: could not load component template — using default (all enabled)"
        CHOSEN="$_DEFAULT"
    fi
fi

# Normalise: dedupe, drop blanks, drop unknowns (defence in depth — anyone
# hand-setting the file bypasses the template). If everything got dropped,
# fall back to the opt-OUT default of "everything enabled" so the legacy
# install behaviour is never lost.
_normalise() {
    _in="$1"
    _out=""
    _norm_old=$IFS; IFS=','
    for _tok in $_in; do
        _tok=$(echo "$_tok" | tr -d ' \t')
        [ -z "$_tok" ] && continue
        component_is_offered "$_tok" || continue
        # Join with a BARE comma. The old ", " join silently broke every
        # has_component() match after the first token (",$CHOSEN," contained
        # ", browsers," which never matches the *,browsers,* pattern), so the
        # per-component COMPONENTS_<name> bits were written 0 for everything
        # except the first selected component.
        case ",$(printf '%s' "$_out" | tr -d ' \t')," in *,"$_tok",*) : ;; *) [ -z "$_out" ] && _out="$_tok" || _out="$_out,$_tok" ;; esac
    done
    IFS=$_norm_old
    echo "$_out"
}
CHOSEN=$( _normalise "$CHOSEN" )
[ -n "$CHOSEN" ] || CHOSEN="$_DEFAULT"

# Boolean presence helpers consumed by the post-install peers.
has_component() {
    # replays the same comma-token match as _normalise. Whitespace-tolerant on
    # purpose: CHOSEN may arrive from debconf (", " separated) or from a
    # hand-edited file, and a space must never silently turn a selected
    # component into an unselected one.
    _want="$1"
    _hc=$(printf '%s' "$CHOSEN" | tr -d ' \t')
    case ",$_hc," in *,"$_want",*) return 0 ;; *) return 1 ;; esac
}
WANT_DESKTOP=0;           has_component desktop           && WANT_DESKTOP=1
WANT_BROWSERS=0;          has_component browsers          && WANT_BROWSERS=1
WANT_MGMT=0;              has_component mgmt-container    && WANT_MGMT=1
WANT_RESCUE_PART=0;       has_component rescue-partition  && WANT_RESCUE_PART=1
WANT_WALLPAPER=0;         has_component wallpaper-rotator && WANT_WALLPAPER=1

log "SELECTED COMPONENTS: $CHOSEN"
log "  desktop=$WANT_DESKTOP  browsers=$WANT_BROWSERS  mgmt-container=$WANT_MGMT  rescue-partition=$WANT_RESCUE_PART  wallpaper-rotator=$WANT_WALLPAPER"

# --- persist for the two consumers -----------------------------------------
# 1. d-i env (consumed by disk-fs-chooser.sh and extract-rootfs.sh, both
#    run in the installer environment, not the chroot).
echo "$CHOSEN" > /tmp/ncz-components 2>/dev/null || true

# 2. in-chroot (consumed by post-install/70-bootloader.sh and
#    post-install/run-all.sh, both run inside the target). Both paths
#    survive late.sh's `rm -rf /target/usr/local/lib/cix-installer` + `cp -a`
#    that runs in preseed/late_command and would otherwise wipe this file:
#   - /target/etc/cix-installer/   — late.sh WRITES to it but never wipes it
#   - /target/var/lib/cix-components   — outside the cix-installer tree
#     entirely, so survives any future refactor of late.sh's copy logic.
# The single source of truth is the COMMA-SEPARATED LIST; the per-toggle
# COMPONENTS_<name> files are convenience copies for consumers that just
# want one bit.
COMP_DST_DIR=/target/etc/cix-installer
[ -d "$COMP_DST_DIR" ] || mkdir -p "$COMP_DST_DIR" 2>/dev/null || true
ALT_DST_DIR=/target/var/lib/cix-components
[ -d "$ALT_DST_DIR" ] || mkdir -p "$ALT_DST_DIR" 2>/dev/null || true
if [ -d "$COMP_DST_DIR" ] || [ -d "$ALT_DST_DIR" ]; then
    if [ -d "$COMP_DST_DIR" ]; then
        echo "$CHOSEN" > "$COMP_DST_DIR/COMPONENTS" 2>/dev/null || true
        for _bit in desktop browsers mgmt-container rescue-partition wallpaper-rotator; do
            _v=0; has_component "$_bit" && _v=1
            echo "$_v" > "$COMP_DST_DIR/COMPONENTS_$_bit" 2>/dev/null || true
        done
    fi
    if [ -d "$ALT_DST_DIR" ]; then
        echo "$CHOSEN" > "$ALT_DST_DIR/COMPONENTS" 2>/dev/null || true
    fi
fi

log "chooser complete: components=$CHOSEN"
exit 0
