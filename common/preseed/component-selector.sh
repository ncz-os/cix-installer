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
# WHAT IT TOGGLES (three opt-OUT toggles; default = all selected = today's
# behaviour, so an operator who accepts the prompt unchanged gets exactly
# what the previous installer shipped):
#
#   desktop             — Singularity desktop overlay (desktop.squashfs) +
#                         desktop-only post-install hooks (greeter, brand,
#                         boot-splash, Vivaldi, Chrome, wallpaper rotator,
#                         etc.). OFF = console-only system, default rEFInd
#                         entry retargeted at cixmini-console.
#   mgmt-container      — ncz-recovery systemd-nspawn container (38-recovery-
#                         container.sh). OFF = no recovery tier installed.
#   rescue-partition    — 4 GiB NCZRESCUE ext4 partition (72-rescue-partition.sh).
#                         OFF = partman recipe drops the rescue stanza (root
#                         partition becomes p2; total 2-partition recipe).
#                         TOUCHES PARTITIONING — disk-fs-chooser.sh reads
#                         /tmp/ncz-components and reuses its fail-closed
#                         pattern (verify pin before wipe, exact recipe match).
#
# Internal compatibility tokens:
#   browsers and wallpaper-rotator are not shown to the operator. They are
#   automatically enabled when desktop is enabled, and disabled when desktop is
#   disabled, so existing post-install hook gates can keep reading their
#   COMPONENTS_<name> bits.
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
# TEST/UNATTENDED override: kernel cmdline `ncz_components=desktop,mgmt-container,...`
# (comma-separated, matching the multiselect answer format) skips the prompt
# entirely. There is NO prompt timeout any more: the prompt is synchronous
# (see the prompt block for why the old 90s poll-and-kill design corrupted
# the cdebconf protocol stream and wedged every metal install); headless
# runs MUST pass ncz_components=. Legacy explicit browsers/wallpaper-rotator tokens are accepted
# harmlessly, but desktop remains the source of truth for both. Empty + absent
# override → prompt is shown. This is how the KVM install gate and any other
# unattended pipeline runs without a human present.
set +e

. /usr/share/debconf/confmodule 2>/dev/null || . /usr/lib/cdebconf/confmodule 2>/dev/null || true
# shared NCZ dialog look (brand in the frame title, arch + build on the last body line); optional, never fatal
for _ncz_u in "${NCZ_UI_SH:-}" /ncz/ncz-ui.sh /cdrom/ncz-payload/ncz-ui.sh "$(dirname "$0")/ncz-ui.sh"; do
    [ -n "$_ncz_u" ] && [ -r "$_ncz_u" ] && . "$_ncz_u" && break
done
command -v ncz_ui_brand >/dev/null 2>&1 || { ncz_ui_brand() { echo "NCZ-OS"; }; ncz_ui_id() { echo ""; }; }

log() {
    echo "[ncz components] $*"
    # Progress chatter goes to VT3 (and the serial diag console); VT1/console is the
    # newt UI and raw lines written over it corrupt the screen. Failures stay visible.
    case "$*" in
        ABORT*|FATAL*|ERROR*) _vs="/dev/console /dev/tty1 /dev/tty3" ;;
        *) _vs="/dev/tty3" ;;
    esac
    for _v in $_vs; do
        echo "[ncz components] $*" > "$_v" 2>/dev/null || true
    done
}

# --- curated candidate list -------------------------------------------------
# Order here is the order shown in the multiselect AND the unique stencil for
# the comma-separated answer / cmdline override. Add a name here + wire it
# into the consumers (disk-fs-chooser.sh for rescue-partition, extract-rootfs.
# sh for desktop, run-all.sh for hooks) and the toggle is real.
COMPONENTS="\
desktop:Full Singularity desktop (GUI labwc + greetd + branding)\
|mgmt-container:ncz-recovery management container (nspawn)\
|rescue-partition:4 GiB NCZRESCUE partition (rescue rootfs + kernel)"

# Optional NVIDIA driver + CUDA toolkit component. HIDDEN unless the installer
# sees an NVIDIA display controller (PCI vendor 0x10de, class 0x03xx) in sysfs;
# default ON when shown. It downloads from NVIDIA's apt repo (network needed;
# post-install/54-gpu-accel.sh defers to first boot when offline), so it is not
# baked into the ISO. Skipping it only skips the NVIDIA driver/CUDA; the machine
# still boots and displays with nouveau.
_HAS_NV=0
# amd64 only: post-install/54-gpu-accel.sh (the only consumer) is amd64-only, so offering the option on an arm64
# machine with an NVIDIA PCIe card would be a no-op the operator cannot see.
case "${NCZ_UNAME_M:-$(uname -m 2>/dev/null)}" in x86_64|amd64) _NV_ARCH_OK=1 ;; *) _NV_ARCH_OK=0 ;; esac
for _d in $([ "$_NV_ARCH_OK" = 1 ] && echo /sys/bus/pci/devices/*); do
    [ -r "$_d/vendor" ] && [ -r "$_d/class" ] || continue
    case "$(cat "$_d/vendor" 2>/dev/null)" in 0x10de) ;; *) continue ;; esac
    case "$(cat "$_d/class" 2>/dev/null)" in 0x03*) _HAS_NV=1; break ;; esac
done
if [ "$_HAS_NV" = 1 ]; then
    COMPONENTS="$COMPONENTS|cuda:NVIDIA driver + CUDA toolkit (downloaded during install; needs network)"
fi

INTERNAL_COMPONENTS="desktop browsers mgmt-container rescue-partition wallpaper-rotator cuda"

# Validate a token against the full internal set (posix sh + grep -qx).
component_is_valid() {
    _want="$1"
    case " $INTERNAL_COMPONENTS " in *" $_want "*) return 0 ;; *) return 1 ;; esac
}

# --- read cmdline override --------------------------------------------------
CMD=$(cat /proc/cmdline 2>/dev/null)
OVR=""
for tok in $CMD; do
    case "$tok" in
        ncz_components=*) OVR="${tok#ncz_components=}" ;;
        ncz_components_timeout=*) : ;; # deprecated no-op (2026-08-24): the poll-and-kill timeout WAS the wedge bug; see prompt block below
    esac
done

# --- build the question -----------------------------------------------------
# The full candidate set is the default answer (opt-OUT: today's behaviour).
# That keeps a prompt the operator just hits OK on bit-identical to a pre-
# component-selector install.
#
# 2026-09-26: also build a parallel Choices-C: field. cdebconf's newt
# frontend renders a multiselect by iterating over the Choices-C: list
# when present and falling back to the raw Choices: token otherwise;
# when a Choices-C: line is missing for a token the newt layout puts
# "<token> <ERR>" next to the checkbox (verified against cdebconf
# 0.283/src/modules/frontend/newt/newt.c:633-716: choices_trans[i] is
# passed verbatim as the newtCheckbox label, and choices_trans is
# populated only when a Choices-C: field is present -- otherwise the
# label is the token + "<ERR>" stub). That is precisely what the O6N
# 2026-09-26 photograph shows: "desktop <ERR>", with the other two
# components rendering normally because the descriptions embedded in
# the Description body of THIS template incidentally happen to look
# like valid Choices-C entries.
#
# The fix is to declare Choices-C: with the exact same descriptions the
# Description body uses, so the newt frontend has a label for every
# token and never falls back to the <ERR> stub. Belt-and-suspenders:
# also add Choices: as the token list (unchanged) so the text frontend
# still works when cdebconf-newt isn't available.
_DEFAULT=""
_OFFERED=""
_CHOICES_C=""
_oldifs=$IFS; IFS='|'
for line in $COMPONENTS; do
    code=${line%%:*}; desc=${line#*:}
    [ -z "$_DEFAULT" ] && _DEFAULT="$code" || _DEFAULT="$_DEFAULT, $code"
    [ -z "$_OFFERED" ] && _OFFERED="$code" || _OFFERED="$_OFFERED, $code"
    [ -z "$_CHOICES_C" ] && _CHOICES_C="$desc" || _CHOICES_C="$_CHOICES_C, $desc"
done
IFS=$_oldifs

# Validate the cmdline override tokens (drop unknown ones, with a warning).
# Operator expectation: an unattended override list is a STRICT SUBSET of
# the known internal set; misspelled tokens are NOT silently dropped-but-applied.
# Legacy browsers/wallpaper-rotator override tokens still parse, but desktop
# below decides whether they remain active.
_OVR_FILTERED=""
if [ -n "$OVR" ]; then
    _ov_old=$IFS; IFS=','
    for _tok in $OVR; do
        _tok=$(echo "$_tok" | tr -d ' \t')
        [ -z "$_tok" ] && continue
        if component_is_valid "$_tok"; then
            [ -z "$_OVR_FILTERED" ] && _OVR_FILTERED="$_tok" || _OVR_FILTERED="$_OVR_FILTERED, $_tok"
        else
            log "WARNING: ncz_components=$_tok is not a known component — dropping"
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
Choices: ${_CHOICES_C}
Choices-C: ${_OFFERED}
Default: ${_DEFAULT}
Description: $(ncz_ui_brand) - optional components
 Untick to skip an optional component. Enter accepts the defaults, which
 install everything.
 .
 $(ncz_ui_id)
TPL
    # ------------------------------------------------------------------
    # SYNCHRONOUS FOREGROUND prompt — 2026-08-24 root-cause fix for the
    # metal 'Internal error! Cannot find "ok" in menu.' installer wedge.
    #
    # The previous implementation ran this prompt in a BACKGROUND subshell
    # ('( ... ) &') polled for up to 90s and then killed. That can never
    # work, and it broke EVERY metal install since it landed (2026-08-20):
    #
    #   * POSIX: in a non-interactive shell without job control, a
    #     backgrounded command gets its stdin redirected from /dev/null.
    #     In this postinst context stdin IS the cdebconf reply pipe, so
    #     the subshell could not read a single protocol reply — while its
    #     COMMANDS still reached cdebconf on the inherited fd3. Proven by
    #     fd forensics in the QEMU repro: subshell fd0 -> /dev/null,
    #     fd3 -> the live confmodule command pipe.
    #   * cdebconf's channel is ONE strictly synchronous stream shared by
    #     the whole d-i process tree. Each of the subshell's commands
    #     (SET, FSET, SETTITLE, INPUT, ...) therefore queued one reply
    #     that nobody read. Every later confmodule read — the rest of the
    #     file-preseed postinst, then main-menu itself — got the reply
    #     meant for an EARLIER command. main-menu's GET of
    #     debian-installer/main-menu read a stale "0 ok", took the literal
    #     string "ok" as the chosen menu entry, logged
    #         Internal error! Cannot find "ok" in menu.
    #     and exited: blank blue screen, install wedged forever.
    #   * The old rc=99 "could not be shown" log line was busybox ash
    #     dying on confmodule's 'return ""' after reading EOF — the rc
    #     file was never written. The 90s kill path would have done the
    #     same damage on any run that got that far.
    #
    # Measured live on metal (.66, 2026-08-24, /proc + questions.dat
    # forensics) and reproduced + fd-traced under QEMU on the same
    # unattended cmdline. The KVM install gate never caught it because
    # the gate injects ncz_components= and so never walks this branch.
    #
    # The fix: prompt SYNCHRONOUSLY IN THE FOREGROUND, exactly like the
    # carrier-detection db_set above (safe since 2026-07-17) and like
    # disk-fs-chooser.sh — foreground children inherit the REAL reply
    # pipe and consume every reply they cause. No timeout: any timeout
    # that kills a confmodule client mid-transaction re-creates the bug.
    # Unattended/headless runs must pass ncz_components=<list> on the
    # kernel cmdline (the KVM install gate already does), which skips
    # this prompt entirely.
    # ------------------------------------------------------------------
    # The dialog is DEFERRED to just before partitioning (partman/early_command runs this script again with --prompt).
    # Shown here, in the first early_command, it was followed by 15-20 s of silent d-i steps (cdrom-detect, the media
    # preseed reload, localechooser, load-cdrom, ethdetect) with an empty blue console on both arches; now the
    # questions come in one block right before the install progress bars start. Until then everything is enabled.
    if [ "${1:-}" != "--prompt" ]; then
        CHOSEN="$_DEFAULT"
        log "interactive install: the component dialog is shown right before partitioning (all components enabled until then)"
    else
        log "showing component prompt (synchronous; unattended runs preseed ncz_components= on the cmdline)"
        _prompt_rc=99
        if debconf-loadtemplate ncz /tmp/ncz-components.templates 2>/dev/null; then
            db_set      ncz/components "$_DEFAULT" 2>/dev/null || true
            db_fset     ncz/components seen false 2>/dev/null || true
            db_settitle ncz/components 2>/dev/null || true
            if db_input critical ncz/components && db_go; then
                if db_get ncz/components; then
                    CHOSEN="$RET"
                    _prompt_rc=0
                fi
            else
                _prompt_rc=2
            fi
        else
            _prompt_rc=3
        fi
        if [ "$_prompt_rc" = 0 ]; then
            log "component prompt answered: $CHOSEN"
        elif [ "$_prompt_rc" = 3 ]; then
            log "WARNING: could not load component template — using default (all enabled)"
            CHOSEN="$_DEFAULT"
        else
            log "WARNING: component prompt could not be shown/completed (rc=$_prompt_rc) — using default (all enabled)"
            CHOSEN="$_DEFAULT"
        fi
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
        component_is_valid "$_tok" || continue
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
WANT_MGMT=0;              has_component mgmt-container    && WANT_MGMT=1
WANT_RESCUE_PART=0;       has_component rescue-partition  && WANT_RESCUE_PART=1
WANT_CUDA=0;              has_component cuda              && WANT_CUDA=1
WANT_BROWSERS=$WANT_DESKTOP
WANT_WALLPAPER=$WANT_DESKTOP

CHOSEN=""
[ "$WANT_DESKTOP" = 1 ]     && CHOSEN="desktop,browsers,wallpaper-rotator"
[ "$WANT_MGMT" = 1 ]        && { [ -z "$CHOSEN" ] && CHOSEN="mgmt-container" || CHOSEN="$CHOSEN,mgmt-container"; }
[ "$WANT_RESCUE_PART" = 1 ] && { [ -z "$CHOSEN" ] && CHOSEN="rescue-partition" || CHOSEN="$CHOSEN,rescue-partition"; }
[ "$WANT_CUDA" = 1 ]        && { [ -z "$CHOSEN" ] && CHOSEN="cuda" || CHOSEN="$CHOSEN,cuda"; }

log "SELECTED COMPONENTS: $CHOSEN"
log "  desktop=$WANT_DESKTOP  browsers=$WANT_BROWSERS  mgmt-container=$WANT_MGMT  rescue-partition=$WANT_RESCUE_PART  wallpaper-rotator=$WANT_WALLPAPER  cuda=$WANT_CUDA"

# --- persist for the two consumers -----------------------------------------
# 1. d-i env (consumed by disk-fs-chooser.sh and extract-rootfs.sh, both
#    run in the installer environment, not the chroot).
echo "$CHOSEN" > /tmp/ncz-components 2>/dev/null || true
mkdir -p /var/lib/ncz-components 2>/dev/null || true
echo "$CHOSEN" > /var/lib/ncz-components/COMPONENTS 2>/dev/null || true

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
        for _bit in desktop browsers mgmt-container rescue-partition wallpaper-rotator cuda; do
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
