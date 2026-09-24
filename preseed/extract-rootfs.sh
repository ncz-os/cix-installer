#!/bin/sh
# See docs/ISO-BUILD-GUARDRAILS.md before changing this file --
# these are ISO build MECHANICS, stable across builds by design.
#
# STATUS (2026-08-26): this file is the DEAD-CODE TWIN of the r159
# layered-squashfs branch baked into the /usr/sbin/debootstrap stub by
# build/build-iso-di.sh. partman/late_command is NOT a real d-i hook
# (only partman/early_command exists), so this script never runs in
# production. The live install-time extraction happens via the stub
# heredoc in build-iso-di.sh.
#
# The trap this creates: a fix made here is forgotten in the stub (round 1
# of the 2026-08-26 0700-root incident -- the gate landed here and shipped
# nowhere) OR a fix made in the stub is forgotten here (round 3 -- the
# real fix shipped and this file kept drifting). To close the trap
# without doing the larger unification refactor, see
# build/check-extract-rootfs-consistency.sh: it diffs the r159 branches
# of this file and the stub and FAILS THE BUILD on any drift after
# normalization. Any change to the extraction logic in either file must
# be mirrored in the other (or the check will refuse to ship).
#
# THE LONG-PROMISED UNIFICATION (making this file the single source of
# truth and embedding it into the stub heredoc at build time, so the two
# copies become one) is deferred pending its own reviewed look -- see
# docs/ISO-BUILD-GUARDRAILS.md's "dead-code twin" trap entry for the
# history and the reason this file still carries the same logic shape
# as the stub.
#
# r40 partman/late_command — extract pre-built rootfs.tar.zst into /target
# right after partman finishes (so /target is mounted) and before
# bootstrap-base runs. The bookworm bootstrap-base.run-debootstrap will then
# call /usr/sbin/debootstrap (our stub), which detects /target/etc/os-release
# from this extraction and exits 0.
#
# r55+ adds live progress feedback to /dev/tty3 (the d-i log VT — Alt+F3 during
# install) so the long extract phase no longer sits silent at "1%".
echo "[EXTRACT-TOP] running pid=$$ $(date 2>/dev/null); base=[$(ls -la /cdrom/ncz-payload/base.squashfs 2>&1)]; cdrom_mounted=[$(mount|grep -c cdrom)]" > /dev/ttyAMA0 2>&1
set -e

LOG=/var/log/cix-rootfs-extract.log
TTY=/dev/tty3
exec > "$LOG" 2>&1

_dumplog() {
    for p in /dev/nvme0n1p1 /dev/vda1 /dev/sda1; do
        mkdir -p /run/esplog 2>/dev/null
        if mount -t vfat "$p" /run/esplog 2>/dev/null; then
            cp "$LOG" /run/esplog/EXTRACT.LOG 2>/dev/null; sync; umount /run/esplog 2>/dev/null; break
        fi
    done
}
trap _dumplog EXIT

# msg <text> — log AND print to tty3 with timestamp.
# Avoid `local` (non-POSIX) so the script stays portable to busybox sh
# in the d-i partman late_command environment.
msg() {
    msg_s="[$(date -u +%H:%M:%S)] $*"
    echo "$msg_s"
    printf '%s\n' "$msg_s" >"$TTY" 2>/dev/null || true
}

msg "=== r40 rootfs extract starting ==="
echo "--- mounts ---"
mount | grep -E "cdrom|hd-media|media|target|run/live" || true

# ============================================================================
# r159: LAYERED SQUASHFS install via bundled unsquashfs (no kernel mount/overlay/loop
# — those failed silently in the d-i env). The sqtools bundle (unsquashfs + libs +
# loader) is staged to <media>/ncz-payload/sqtools by build-iso. Preferred over the
# rootfs.tar.zst path; falls through to the tarball if no base.squashfs present.
SQFS_DIR=""
for d in /cdrom/ncz-payload /hd-media/ncz-payload /media/cdrom/ncz-payload /run/live/medium/ncz-payload; do
    [ -f "$d/base.squashfs" ] && { SQFS_DIR="$d"; break; }
done
if [ -n "$SQFS_DIR" ]; then
    set +e
    SER=/dev/ttyAMA0
    msg "LAYERED SQUASHFS install from $SQFS_DIR (unsquashfs bundle)"
    echo "[sqfs] base=$(ls -la "$SQFS_DIR/base.squashfs" 2>&1)" > $SER 2>&1
    LDR=$(ls "$SQFS_DIR"/sqtools/ld-* 2>/dev/null | head -1)
    UNSQ_BIN="$SQFS_DIR/sqtools/unsquashfs"
    if [ ! -x "$UNSQ_BIN" ] || [ -z "$LDR" ]; then
        msg "FATAL: sqtools bundle missing (bin=$UNSQ_BIN ldr=$LDR)"
        echo "[sqfs] FATAL sqtools missing; ls: $(ls -la "$SQFS_DIR/sqtools" 2>&1)" > $SER 2>&1
        exit 1
    fi
    run_unsq() { "$LDR" --library-path "$SQFS_DIR/sqtools" "$UNSQ_BIN" "$@"; }
    ncz_component_record() {
        _ncz_comp=""
        if [ -r /tmp/ncz-components ] && command -v tr >/dev/null 2>&1; then
            _ncz_comp=$(tr -d ' \t\r\n' < /tmp/ncz-components 2>/dev/null || true)
            [ -n "$_ncz_comp" ] && { printf '%s\n' "$_ncz_comp"; return 0; }
        fi
        if [ -r /var/lib/ncz-components/COMPONENTS ] && command -v tr >/dev/null 2>&1; then
            _ncz_comp=$(tr -d ' \t\r\n' < /var/lib/ncz-components/COMPONENTS 2>/dev/null || true)
            [ -n "$_ncz_comp" ] && {
                printf '%s\n' "$_ncz_comp" > /tmp/ncz-components 2>/dev/null || true
                printf '%s\n' "$_ncz_comp"
                return 0
            }
        fi
        if command -v debconf-get >/dev/null 2>&1; then
            _ncz_comp=$(debconf-get ncz/components 2>/dev/null | tr -d ' \t\r\n' || true)
            [ -n "$_ncz_comp" ] && {
                printf '%s\n' "$_ncz_comp" > /tmp/ncz-components 2>/dev/null || true
                printf '%s\n' "$_ncz_comp"
                return 0
            }
        fi
        if [ -r /var/lib/cdebconf/questions.dat ]; then
            _ncz_comp=$(awk '
                $0 == "Name: ncz/components" { inq=1; next }
                inq && /^Value: / { sub(/^Value: /, ""); print; exit }
                inq && /^Name: / { exit }
            ' /var/lib/cdebconf/questions.dat 2>/dev/null | tr -d ' \t\r\n' || true)
            [ -n "$_ncz_comp" ] && {
                printf '%s\n' "$_ncz_comp" > /tmp/ncz-components 2>/dev/null || true
                printf '%s\n' "$_ncz_comp"
                return 0
            }
        fi
        for _ncz_log in /var/log/syslog /var/log/installer/syslog; do
            [ -r "$_ncz_log" ] || continue
            _ncz_comp=$(awk '
                /debconf: --> GET ncz\/components/ { want=1; next }
                want && /debconf: <-- 0 / {
                    sub(/^.*debconf: <-- 0 /, "")
                    val=$0
                    want=0
                }
                END { if (val != "") print val }
            ' "$_ncz_log" 2>/dev/null | tr -d ' \t\r\n' || true)
            [ -n "$_ncz_comp" ] && {
                printf '%s\n' "$_ncz_comp" > /tmp/ncz-components 2>/dev/null || true
                mkdir -p /var/lib/ncz-components 2>/dev/null || true
                printf '%s\n' "$_ncz_comp" > /var/lib/ncz-components/COMPONENTS 2>/dev/null || true
                printf '%s\n' "$_ncz_comp"
                return 0
            }
        done
        return 1
    }
    # The ISO installs one complete target.  The desktop layer is the internal
    # name for that complete payload; rEFInd provides console/recovery choices
    # after installation instead of selecting an install-time server overlay.
    #
    # r303: install-time component toggle (see preseed/component-selector.sh).
    # If the operator opted out of the desktop, do NOT extract desktop.squashfs
    # at all — the system boots to console via cixmini-console.conf (set as
    # default by 70-bootloader.sh when COMPONENTS_DESKTOP=0). BASE-only installs
    # are still bit-identical to the previous /cdrom/ncz-payload/base.squashfs
    # payload, which carries a usable userspace (network, ssh, etc.) — the
    # desktop is purely an overlay.
    ROLE=desktop
    _applied_role="$ROLE"
    msg "component-selector state before ROLE decision: /tmp=[$(ls -l /tmp/ncz-components 2>&1)] value=[$(cat /tmp/ncz-components 2>/dev/null || true)] durable=[$(ls -l /var/lib/ncz-components/COMPONENTS 2>&1)] durable_value=[$(cat /var/lib/ncz-components/COMPONENTS 2>/dev/null || true)]"
    _ck=$(ncz_component_record 2>/dev/null || true)
    if [ -n "$_ck" ]; then
        _want_desktop=1
        case ",$_ck," in
            *",desktop,"*) _want_desktop=1 ;;
            *)              _want_desktop=0 ;;
        esac
        if [ "$_want_desktop" = 0 ]; then
            ROLE=base
            _applied_role=base
            msg "component-selector: desktop toggle OFF — installing BASE ONLY (no desktop.squashfs overlay)"
        fi
    fi
    START=$(date +%s)
    msg "extracting base.squashfs -> /target"
    echo "[sqfs] unsquashfs base ..." > $SER 2>&1
    run_unsq -f -d /target "$SQFS_DIR/base.squashfs" >/dev/null 2>>$SER
    RC=$?
    echo "[sqfs] base rc=$RC -> $(find /target -xdev -type f 2>/dev/null | wc -l) files" > $SER 2>&1
    if [ "$RC" -ne 0 ]; then msg "FATAL: unsquashfs base rc=$RC"; exit 1; fi
    # 2026-08-26: defensive chmod 0755 /target after the base extraction.
    # Why: unsquashfs -f -d sets the destination's mode to match the squashfs
    # root entry, including when /target is a mounted btrfs subvolume root
    # (which the d-i partman recipe just created). A root at 0700 denies
    # traversal to every non-root UID, which silently breaks greetd, NIC
    # bring-up (systemd sandboxed), rtc-efi, and anything else that boots
    # without raw-root privileges. O6N install confirmed live 2026-08-26 with
    # mode 0700 + the symptom set; the exact upstream mechanism (build-side
    # squashfs vs install-side btrfs interaction) was not pinpointed before
    # this fix — the symptom is real, the chain is plausible, this is the
    # minimal belt-and-suspenders that closes the class regardless of which
    # side regresses. Unconditional, must fail loudly on chmod failure.
    chmod 0755 /target || { msg "FATAL: chmod 0755 /target failed"; exit 1; }
    if [ "$ROLE" = "desktop" ] && [ -f "$SQFS_DIR/$ROLE.squashfs" ]; then
        # Apply the complete overlay contract (0:0 whiteouts plus opaque
        # directories) before extracting the upperdir squashfs.
        OVERLAY_MANIFEST="$SQFS_DIR/$ROLE.overlay-manifest"
        if [ ! -s "$OVERLAY_MANIFEST" ]; then
            msg "FATAL: missing $ROLE overlay manifest"
            exit 1
        fi
        OVERLAY_COUNT=0
        OVERLAY_TAB=$(printf '\t')
        while IFS="$OVERLAY_TAB" read -r kind rel; do
            case "$kind" in
                '#'*|'') continue ;;
                whiteout|opaque) ;;
                *) msg "FATAL: invalid $ROLE overlay operation '$kind'"; exit 1 ;;
            esac
            case "$rel" in
                ''|.|/*|../*|*/../*|*/..)
                    msg "FATAL: unsafe $ROLE overlay path '$rel'"
                    exit 1
                    ;;
            esac
            if ! rm -rf "/target/$rel"; then
                msg "FATAL: cannot apply $kind '$rel'"
                exit 1
            fi
            OVERLAY_COUNT=$((OVERLAY_COUNT + 1))
        done < "$OVERLAY_MANIFEST"
        msg "applied $OVERLAY_COUNT $ROLE overlay operation(s)"

        msg "applying $ROLE.squashfs delta -> /target"
        run_unsq -f -d /target "$SQFS_DIR/$ROLE.squashfs" >/dev/null 2>>$SER
        RC=$?
        echo "[sqfs] $ROLE rc=$RC -> $(find /target -xdev -type f 2>/dev/null | wc -l) files" > $SER 2>&1
        if [ "$RC" -ne 0 ]; then msg "FATAL: unsquashfs $ROLE rc=$RC"; exit 1; fi
        # Remove whiteout marker nodes by their already-validated manifest
        # paths instead of scanning/stat-ing the complete target filesystem.
        while IFS="$OVERLAY_TAB" read -r kind rel; do
            [ "$kind" = whiteout ] || continue
            if ! rm -rf "/target/$rel"; then
                msg "FATAL: cannot remove whiteout marker '$rel'"
                exit 1
            fi
        done < "$OVERLAY_MANIFEST"
        HOTFIX_ROLE="$ROLE-hotfix"
        HOTFIX_IMAGE="$SQFS_DIR/$HOTFIX_ROLE.squashfs"
        HOTFIX_MANIFEST="$SQFS_DIR/$HOTFIX_ROLE.overlay-manifest"
        if [ -f "$HOTFIX_IMAGE" ]; then
            if [ ! -s "$HOTFIX_MANIFEST" ]; then
                msg "FATAL: missing $HOTFIX_ROLE overlay manifest"
                exit 1
            fi
            HOTFIX_COUNT=0
            while IFS="$OVERLAY_TAB" read -r kind rel; do
                case "$kind" in
                    '#'*|'') continue ;;
                    whiteout|opaque) ;;
                    *) msg "FATAL: invalid $HOTFIX_ROLE overlay operation '$kind'"; exit 1 ;;
                esac
                case "$rel" in
                    ''|.|/*|../*|*/../*|*/..)
                        msg "FATAL: unsafe $HOTFIX_ROLE overlay path '$rel'"
                        exit 1
                        ;;
                esac
                if ! rm -rf "/target/$rel"; then
                    msg "FATAL: cannot apply $HOTFIX_ROLE $kind '$rel'"
                    exit 1
                fi
                HOTFIX_COUNT=$((HOTFIX_COUNT + 1))
            done < "$HOTFIX_MANIFEST"
            msg "applied $HOTFIX_COUNT $HOTFIX_ROLE overlay operation(s)"

            msg "applying $HOTFIX_ROLE.squashfs delta -> /target"
            run_unsq -f -d /target "$HOTFIX_IMAGE" >/dev/null 2>>$SER
            RC=$?
            echo "[sqfs] $HOTFIX_ROLE rc=$RC -> $(find /target -xdev -type f 2>/dev/null | wc -l) files" > $SER 2>&1
            if [ "$RC" -ne 0 ]; then msg "FATAL: unsquashfs $HOTFIX_ROLE rc=$RC"; exit 1; fi
            while IFS="$OVERLAY_TAB" read -r kind rel; do
                [ "$kind" = whiteout ] || continue
                if ! rm -rf "/target/$rel"; then
                    msg "FATAL: cannot remove $HOTFIX_ROLE whiteout marker '$rel'"
                    exit 1
                fi
            done < "$HOTFIX_MANIFEST"
        fi
    else
        if [ "$_applied_role" = "base" ]; then
            msg "role=base (operator toggled desktop OFF at install) — skipping desktop overlay"
            echo "[sqfs] role=base (component-selector: desktop OFF) — base-only install" > $SER 2>&1
        else
            msg "WARNING: $ROLE.squashfs not on media -- installing BASE ONLY. This is NOT a working $ROLE system (no desktop, no server packages, missing ssh on server). Rebuild the ISO with $ROLE.squashfs staged."
            echo "[sqfs] WARNING: $ROLE.squashfs missing -- base-only degraded install" > $SER 2>&1
        fi
    fi
    # 2026-08-26 ROOT-MODE GATE — post-full-layer-stack hard verification
    # (docs/ISO-BUILD-GUARDRAILS.md). Root cause of the 0700-root incident,
    # found+proven 2026-08-26: `unsquashfs -f -d /target` re-stamps /target's
    # OWN mode from EACH layer's root entry (verified with the bundled sqtools
    # unsquashfs AND squashfs-tools 4.6.1: an existing 755 dir became 700
    # after extracting a layer whose root entry was drwx------).
    # desktop-hotfix.squashfs was built 2026-08-25 out-of-repo from a
    # mktemp -d staging dir (mode 0700), so the LAST layer stamped / to 0700
    # on every install. The defensive chmod above (right after base) does
    # NOT protect against a LATER layer (role delta or hotfix) re-breaking
    # the mode -- pin 0755 again here, after the FULL layer stack, and
    # hard-verify; exit 1 makes the install fail loudly instead of shipping
    # a broken root.
    chmod 0755 /target || { msg "FATAL: chmod 0755 /target failed (post-full-stack)"; exit 1; }
    _ncz_rm=$(ls -ld /target 2>/dev/null | awk '{print $1}')
    [ -n "$_ncz_rm" ] || _ncz_rm="???"
    if [ "$_ncz_rm" != "drwxr-xr-x" ]; then
        msg "FATAL: /target root mode is $_ncz_rm after layer extraction (expected drwxr-xr-x/0755) — refusing to ship a broken install"
        exit 1
    fi
    msg "verified /target root mode = drwxr-xr-x (0755) after full layer stack"
    if [ ! -f "/target/etc/os-release" ]; then
        msg "FATAL: squashfs extract produced no os-release"
        exit 1
    fi
    ELAPSED=$(( $(date +%s) - START ))
    # BAKED marker: run-all runs ONLY machine hooks (fstab/rescue/bootloader), not
    # the desktop/kernel/network hooks — this is what avoids the regression.
    mkdir -p /target/etc; : > /target/etc/ncz-baked

    # r309: PERSIST THE COMPONENT SELECTION INTO /target.
    #
    # component-selector.sh runs in preseed/early_command, which fires BEFORE
    # partman mounts the real root at /target. Its writes to
    # /target/etc/cix-installer/COMPONENTS and /target/var/lib/cix-components/
    # therefore landed in the installer RAMDISK and were destroyed the moment
    # partman mounted the real filesystem over /target. Measured on .66
    # (2026-08-22): none of the three consumer paths existed on the installed
    # system, so post-install/run-all.sh and build/70-bootloader.sh both fell
    # back to their "file missing => all components enabled" default and ran
    # the full desktop hook set + wrote GUI rEFInd entries on an install where
    # the operator had explicitly deselected desktop and browsers.
    #
    # This block runs in partman/late_command, where /target IS the mounted
    # target filesystem, so it is the earliest point the selection can be
    # stored durably. Prefer /tmp/ncz-components; if d-i has removed it by
    # this phase, recover the same debconf answer from cdebconf.
    _comp=$(ncz_component_record 2>/dev/null || true)
    if [ -n "$_comp" ]; then
        for _d in /target/usr/local/lib/cix-installer /target/etc/cix-installer \
                  /target/var/lib/cix-components; do
            mkdir -p "$_d" 2>/dev/null || continue
            printf '%s\n' "$_comp" > "$_d/COMPONENTS" 2>/dev/null || true
        done
        for _bit in desktop browsers mgmt-container rescue-partition \
                    wallpaper-rotator; do
            _v=0
            case ",$_comp," in *,"$_bit",*) _v=1 ;; esac
            printf '%s\n' "$_v" \
                > "/target/etc/cix-installer/COMPONENTS_$_bit" 2>/dev/null || true
        done
        msg "persisted component selection to /target: $_comp"
    else
        msg "WARNING: component selection unavailable in /tmp and cdebconf — consumers will default to ALL components"
    fi
    # r159: finish deferred dpkg config; purge pkgs that cannot configure in a
    # chroot (e.g. falkon needs a display) so d-i pkgsel's apt does not choke on a
    # half-configured package. Bind-mount for maintainer scripts, then unmount.
    for _m in proc sys dev; do mount --bind /$_m "/target/$_m" 2>/dev/null; done
    mount --bind /dev/pts "/target/dev/pts" 2>/dev/null
    chroot /target dpkg --configure -a 2>/dev/null
    # r172: PRESERVE falkon (the NCZ web browser). It can't finish configuring in
    # the d-i chroot (its postinst wants a display/dbus), so r159 purged it as
    # "non-configured" — which left the installed desktop with NO working browser
    # (firefox on resolute is a snap stub that no-ops in an offline image; only
    # falkon + epiphany are real debs). Keep falkon (+ its parts) out of the purge
    # and let ncz-firstboot's `dpkg --configure -a` finish it on first boot where
    # X/dbus exist. Everything else non-ii is still purged so pkgsel's dpkg stays
    # clean.
    _BAD=$(chroot /target dpkg -l 2>/dev/null | awk '$1 ~ /^.[A-Z]/ && $1 != "ii" {print $2}' | grep -viE '^falkon')
    [ -n "$_BAD" ] && { msg "purging non-configured (keeping falkon): $_BAD"; chroot /target dpkg --purge --force-all $_BAD 2>/dev/null; }
    # Best-effort configure of falkon now; if it still can't (no display), it stays
    # unpacked and ncz-firstboot configures it. pkgsel tolerates unpacked (unlike
    # a broken statoverride) as long as dpkg itself isn't wedged.
    chroot /target dpkg --configure falkon 2>/dev/null || true
    # r169: drop orphaned dpkg statoverrides whose owning user no longer exists.
    # The GNOME-purge/autoremove in the squashfs build (and this block's own
    # dpkg --configure/purge above) can leave a statoverride like
    #   geoclue geoclue 755 /var/lib/geoclue
    # after the 'geoclue' system user is gone. A dangling override makes dpkg
    # abort with "unknown system user 'geoclue' in statoverride file" on EVERY
    # later dpkg op → d-i pkgsel apt-get install fails ("Installation step
    # failed"). Clean at install time, after configure/purge, before pkgsel runs.
    # r170: collect orphan paths in a FIRST read-only pass, then remove them —
    # dpkg-statoverride --remove rewrites the very file we read, so removing
    # inside the read loop corrupts it (r169 removed geoclue but mangled the
    # file into an "unknown system user 'root'" abort). Guard on getent working
    # so a broken NSS can't nuke every (legitimate, e.g. root:shadow) override.
    chroot /target sh -c '
        getent passwd root >/dev/null 2>&1 || exit 0
        orphans=""
        while read u g m f; do
            [ -n "$u" ] && [ -n "$f" ] || continue
            getent passwd "$u" >/dev/null 2>&1 || orphans="$orphans
$f"
        done < /var/lib/dpkg/statoverride
        printf "%s\n" "$orphans" | while IFS= read -r p; do
            [ -n "$p" ] && dpkg-statoverride --remove "$p" 2>/dev/null || true
        done
    ' 2>/dev/null || true
    msg "pruned orphaned statoverrides (missing user)"
    for _m in dev/pts dev sys proc; do umount "/target/$_m" 2>/dev/null; done
    # r159: disable needrestart kernel hints so pkgsel/apt does not raise the
    # "pending kernel upgrade / consider rebooting" note (baked kernel != d-i
    # installer kernel) that blocks "Select and install software".
    mkdir -p /target/etc/needrestart/conf.d
    printf '$nrconf{kernelhints} = 0;\n' > /target/etc/needrestart/conf.d/99-baked.conf
    # r160: per-machine ssh host keys. The Ubuntu cloud rootfs ships
    # openssh-server but STRIPS the host keys (cloud-init would normally
    # regenerate them); without keys sshd refuses to start and the installed
    # system is unreachable on :22. Generate here, at install time, so every
    # machine gets unique keys — never bake host keys into the squashfs.
    chroot /target ssh-keygen -A 2>/dev/null || \
        msg "WARNING: ssh-keygen -A failed (openssh-server missing from image?)"
    # r160: fleet remote-access policy. The cloud-image drop-in forces
    # PasswordAuthentication no; the fleet is LAN-only and wants password
    # fallback when keys break. OpenSSH keyword resolution is first-value-wins
    # across lexically-sorted sshd_config.d, so 10- beats any later drop-in.
    rm -f /target/etc/ssh/sshd_config.d/60-cloudimg-settings.conf
    mkdir -p /target/etc/ssh/sshd_config.d
    printf 'PasswordAuthentication yes\n' > /target/etc/ssh/sshd_config.d/10-ncz-fleet.conf
    # r160: de-cloud the network stack. The cloud rootfs enables
    # systemd-networkd + its wait-online + networkd-dispatcher ALONGSIDE
    # NetworkManager; networkd has no .network config on NCZ so
    # systemd-networkd-wait-online stalls every boot for its full ~120s
    # timeout. NCZ is NetworkManager-managed — drop the networkd enablement
    # symlinks (NM + NM-wait-online stay).
    rm -f /target/etc/systemd/system/multi-user.target.wants/systemd-networkd.service \
          /target/etc/systemd/system/multi-user.target.wants/networkd-dispatcher.service \
          /target/etc/systemd/system/sockets.target.wants/systemd-networkd.socket \
          /target/etc/systemd/system/network-online.target.wants/systemd-networkd-wait-online.service \
          /target/etc/systemd/system/dbus-org.freedesktop.network1.service 2>/dev/null
    # first-boot oneshot: finish deferred dpkg config (chroot half-configured pkgs
    # e.g. falkon) + regen machine identity, before the display manager.
    mkdir -p /target/usr/local/sbin /target/etc/systemd/system/multi-user.target.wants
    cat > /target/usr/local/sbin/ncz-firstboot <<'FBS'
#!/bin/sh
export DEBIAN_FRONTEND=noninteractive
dpkg --configure -a 2>/dev/null || true
[ -s /etc/machine-id ] || systemd-machine-id-setup 2>/dev/null || true

# r177: per-machine hostname ncz-<last-6-hex-of-primary-ethernet-MAC>. The real
# hardware MAC is authoritative HERE (first boot on the actual box), not at bake
# time. Only rename when the hostname is still a placeholder/default so a
# user-chosen name on later boots is never clobbered.
HOSTNAME_SETTLED=1   # set to 0 to keep the service enabled + retry the derive next boot
_cur=$(cat /etc/hostname 2>/dev/null | tr -d '[:space:]')
case "$_cur" in
    ""|ncz-setup|mini|cixmini|localhost|localhost.localdomain|debian|ubuntu|nclawzero)
        # Find the primary ethernet MAC. Two passes per attempt: first prefer an
        # iface with link (carrier=1), else the first eligible ethernet. Retry a
        # few seconds in case NIC enumeration lags this early oneshot.
        _pick_mac() {
            for _pref in 1 0; do
                for _if in /sys/class/net/*; do
                    _n=${_if##*/}
                    case "$_n" in
                        lo|wl*|ww*|wlan*|docker*|veth*|virbr*|br-*|vmnet*|tap*|tun*|bond*|dummy*|sit*|ip6*) continue ;;
                    esac
                    # physical only: must have a backing device, must not be wireless
                    [ -e "$_if/device" ] || continue
                    [ -d "$_if/wireless" ] && continue
                    _m=$(cat "$_if/address" 2>/dev/null)
                    [ -n "$_m" ] || continue
                    case "$_m" in 00:00:00:00:00:00) continue ;; esac
                    if [ "$_pref" = 1 ] && [ "$(cat "$_if/carrier" 2>/dev/null)" != 1 ]; then
                        continue
                    fi
                    printf '%s' "$_m"; return 0
                done
            done
            return 1
        }
        _mac=""
        _try=0
        while [ "$_try" -lt 15 ]; do
            _mac=$(_pick_mac) && [ -n "$_mac" ] && break
            _mac=""; _try=$((_try+1)); sleep 1
        done
        _newname=""
        if [ -n "$_mac" ]; then
            _h6=$(printf '%s' "$_mac" | tr -d ':' | tr 'A-F' 'a-f' | tail -c 6)
            [ -n "$_h6" ] && _newname="ncz-$_h6"
        fi
        if [ -z "$_newname" ]; then
            # No eligible ethernet MAC this boot. RETRY on the next few boots so a
            # slow-to-enumerate NIC eventually names the box; after MAXTRIES fall
            # back to a machine-id-derived name so it is NEVER stuck as ncz-setup.
            _bt=$(cat /var/lib/ncz-firstboot-tries 2>/dev/null)
            case "$_bt" in ''|*[!0-9]*) _bt=0 ;; esac
            _bt=$((_bt + 1))
            printf '%s\n' "$_bt" > /var/lib/ncz-firstboot-tries 2>/dev/null || true
            if [ "$_bt" -lt 3 ]; then
                HOSTNAME_SETTLED=0
                echo "ncz-firstboot: no eligible ethernet MAC yet (attempt $_bt) — will retry next boot" >&2
            else
                _mid=$(tr -cd '0-9a-f' < /etc/machine-id 2>/dev/null | tail -c 6)
                [ -n "$_mid" ] && _newname="ncz-$_mid"
                echo "ncz-firstboot: no ethernet MAC after $_bt boots — machine-id fallback ${_newname:-<none>}" >&2
            fi
        fi
        if [ -n "$_newname" ]; then
            if command -v hostnamectl >/dev/null 2>&1 && hostnamectl set-hostname "$_newname" 2>/dev/null; then
                :
            else
                printf '%s\n' "$_newname" > /etc/hostname
                hostname "$_newname" 2>/dev/null || true
            fi
            if grep -q '^127\.0\.1\.1' /etc/hosts 2>/dev/null; then
                sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t$_newname/" /etc/hosts
            else
                printf '127.0.1.1\t%s\n' "$_newname" >> /etc/hosts
            fi
        fi
        ;;
esac

# 2026-08-26 first-boot root-mode belt (0700-root incident; see
# docs/ISO-BUILD-GUARDRAILS.md). Runs AFTER dpkg --configure -a above (package
# postinsts are the last code to run before a login screen) and before
# display-manager.service (unit ordering), so a bad / mode is corrected before
# greetd would hit EACCES traversing /. Always emits a NCZ-ROOTMODE marker to
# kmsg+console so build/kvm-install-gate.sh phase 2 can assert the final mode
# from OUTSIDE the VM via the boot serial capture.
_rm=$(ls -ld / 2>/dev/null | awk '{print $1}')
[ -n "$_rm" ] || _rm="???"
if [ "$_rm" != "drwxr-xr-x" ]; then
    echo "ncz-firstboot: WARNING / mode was $_rm (expected drwxr-xr-x/0755) — correcting" > /dev/kmsg 2>/dev/null || true
    chmod 0755 / 2>/dev/null || true
    _rm=$(ls -ld / 2>/dev/null | awk '{print $1}')
    [ -n "$_rm" ] || _rm="???"
fi
echo "NCZ-ROOTMODE: $_rm" > /dev/kmsg 2>/dev/null || true
echo "NCZ-ROOTMODE: $_rm" > /dev/console 2>/dev/null || true

# 2026-09-08 GPU glvnd-compat belt (labwc SIGSEGV / free(): invalid pointer
# incident, O6N first-boot). post-install/26-gpu-default-mali.sh correctly
# disables /etc/ld.so.conf.d/01-cixgpu-compat.conf at install time via a
# rename to .disabled -- but dpkg does not know about that rename, so the
# dpkg --configure -a above (cix-libglvnd has a deferred/triggered postinst)
# re-lays-down its shipped default conffile and silently UNDOES the disable
# on every single fresh install's first boot, before hook 26 or the operator
# ever gets a chance to notice. Symptom: labwc SIGSEGVs in __eglLoadVendors
# (cix-libglvnd 1.1.0's ancient glvnd shim fighting the system glvnd 1.7.0 +
# Mesa 26 stack) on every launch -- greetd start-limit-hits, black screen.
# Same belt-after-dpkg-configure pattern as the root-mode fix above, for the
# same reason: package postinsts are the last code to run before the login
# screen, so re-assert our config choice AFTER them, not just at build time.
if [ -e /etc/ld.so.conf.d/01-cixgpu-compat.conf ]; then
    echo "ncz-firstboot: WARNING 01-cixgpu-compat.conf re-appeared after dpkg --configure -a -- disabling again" > /dev/kmsg 2>/dev/null || true
    mv /etc/ld.so.conf.d/01-cixgpu-compat.conf /etc/ld.so.conf.d/01-cixgpu-compat.conf.disabled 2>/dev/null || true
    ldconfig 2>/dev/null || true
fi

# Only finalize (disable + mark done) when the hostname is SETTLED. When we are
# deliberately retrying the MAC-derive on a later boot (HOSTNAME_SETTLED=0), we
# leave the service enabled and NOT-done so it runs again — dpkg-configure and
# machine-id above already ran this boot, and the host will never be permanently
# stuck as ncz-setup (machine-id fallback after MAXTRIES guarantees a name).
if [ "${HOSTNAME_SETTLED:-1}" = 1 ]; then
    systemctl disable ncz-firstboot.service 2>/dev/null || true
    touch /var/lib/ncz-firstboot-done
fi
FBS
    chmod +x /target/usr/local/sbin/ncz-firstboot
    cat > /target/etc/systemd/system/ncz-firstboot.service <<'FBU'
[Unit]
Description=NCZ first-boot finalize (dpkg configure + machine identity)
ConditionPathExists=!/var/lib/ncz-firstboot-done
DefaultDependencies=no
# dpkg --configure -a may run package ldconfig triggers; let systemd's stock
# ldconfig.service finish first so both do not race over /etc/ld.so.cache~.
After=local-fs.target ldconfig.service
Before=display-manager.service gdm.service graphical.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/ncz-firstboot
[Install]
WantedBy=multi-user.target
FBU
    ln -sf ../ncz-firstboot.service /target/etc/systemd/system/multi-user.target.wants/ncz-firstboot.service
    [ -e /target/etc/fstab ] || touch /target/etc/fstab
    : > /target/etc/fstab.orig
    # r177: deterministic hostname PLACEHOLDER. ncz-firstboot rewrites this to
    # ncz-<mac6> on first boot (guarded on the placeholder). Baked squashfs may
    # ship its own /etc/hostname; force the placeholder so the derive always fires.
    printf 'ncz-setup\n' > /target/etc/hostname
    [ -e /target/etc/resolv.conf ] || touch /target/etc/resolv.conf
    FINAL_MB=$(du -sm /target 2>/dev/null | awk '{print $1}')
    msg "--- layered squashfs install done: ${FINAL_MB} MB in ${ELAPSED}s (role=$_applied_role) ---"
    echo "[sqfs] DONE ${FINAL_MB}MB role=$_applied_role files=$(find /target -xdev -type f|wc -l)" > $SER 2>&1
    [ -f /target/etc/os-release ] || echo "[sqfs] WARN no os-release" > $SER 2>&1
    touch /target/.cix-r40-rootfs-extracted /target/.cix-squashfs-install
    exit 0
fi

# Find rootfs.tar.zst on the install media
ROOTFS=""
for d in /cdrom/ncz-payload /hd-media/ncz-payload /media/cdrom/ncz-payload /run/live/medium/ncz-payload; do
    if [ -f "$d/rootfs.tar.zst" ]; then
        ROOTFS="$d/rootfs.tar.zst"
        SIZE=$(stat -c%s "$ROOTFS" 2>/dev/null || echo 0)
        SIZE_MB=$((SIZE / 1024 / 1024))
        msg "FOUND rootfs: $ROOTFS (${SIZE_MB} MB compressed)"
        break
    fi
done

if [ -z "$ROOTFS" ]; then
    # THIN/netinstall mode ships no rootfs.tar.zst — the base is installed by
    # real debootstrap, not pre-extracted. This is the normal path for the
    # canonical builds, so skip cleanly (exit 0) rather than aborting partman.
    # Only FULL-mode ISOs stage rootfs.tar.zst for the debootstrap-stub path.
    msg "no rootfs.tar.zst on media (thin/netinstall mode) — base installs via debootstrap; skipping extract"
    exit 0
fi
if ! command -v zstd >/dev/null; then
    msg "FATAL: zstd not in PATH"
    exit 1
fi
if ! [ -d /target ]; then
    msg "FATAL: /target does not exist"
    exit 1
fi
if ! mountpoint -q /target; then
    msg "WARN: /target is not a mountpoint"
fi

# best-effort progress reporter via background loop
# writes /target size + % every 3s to tty3 — gives the user something to watch
# instead of d-i's stuck "1%" main bar
EXTRACTED_TOTAL_KB=3000000  # rootfs decompresses to ~3 GB; rough estimate for %
(
    while [ -d /target ]; do
        sleep 3
        # /target size in KB (du in d-i busybox supports -s -k)
        CUR_KB=$(du -sk /target 2>/dev/null | awk '{print $1}')
        [ -z "$CUR_KB" ] && CUR_KB=0
        PCT=$(( CUR_KB * 100 / EXTRACTED_TOTAL_KB ))
        [ "$PCT" -gt 100 ] && PCT=100
        FILES=$(find /target -xdev -type f 2>/dev/null | wc -l)
        printf '[%s] extracting rootfs: %d MB / ~3000 MB (%d%%) — %d files\n' \
            "$(date -u +%H:%M:%S)" "$((CUR_KB/1024))" "$PCT" "$FILES" >"$TTY" 2>/dev/null || true
    done
) &
PROG_PID=$!
# shellcheck disable=SC2064  # PROG_PID set at trap-arm time and never reassigned, intentional
trap "kill $PROG_PID 2>/dev/null || true" EXIT

# Try to advance d-i's main progress bar via debconf — best effort, OK if it
# isn't reachable in this context.
if [ -f /usr/share/debconf/confmodule ]; then
    (
        . /usr/share/debconf/confmodule 2>/dev/null && {
            db_progress INFO cdebconf/progress-fallback 2>/dev/null || true
        }
    ) 2>/dev/null || true
fi

msg "--- extracting (typically 30-60s on USB 3 SSD) ---"
START=$(date +%s)

# tar's --checkpoint emits a status line every N records (1 record = 512 bytes,
# so checkpoint=20000 ≈ every 10 MB). Output goes to stderr -> our log AND tty3.
# Busybox tar may not support --checkpoint; fall back to plain extraction
# in that case (still get the background loop progress).
if zstd -dc "$ROOTFS" | tar --checkpoint=20000 \
        --checkpoint-action=ttyout='[r40] %u files (%T{%c} elapsed)\n' \
        -xpf - -C /target 2>"$TTY"; then
    EXTRACT_RC=0
else
    EXTRACT_RC=$?
    msg "tar with --checkpoint failed rc=$EXTRACT_RC; retrying without checkpoint"
    if zstd -dc "$ROOTFS" | tar -xpf - -C /target; then
        EXTRACT_RC=0
    else
        EXTRACT_RC=$?
    fi
fi

END=$(date +%s)
ELAPSED=$((END - START))

kill $PROG_PID 2>/dev/null || true
trap - EXIT

if [ "$EXTRACT_RC" -ne 0 ]; then
    msg "FATAL: rootfs extract failed rc=$EXTRACT_RC after ${ELAPSED}s"
    exit "$EXTRACT_RC"
fi

FINAL_KB=$(du -sk /target 2>/dev/null | awk '{print $1}')
FINAL_MB=$((FINAL_KB / 1024))
FINAL_FILES=$(find /target -xdev -type f 2>/dev/null | wc -l)
msg "--- extract done: ${FINAL_MB} MB, ${FINAL_FILES} files in ${ELAPSED}s ---"

ls -la /target | head -15
df -h /target | head -3

touch /target/.cix-r40-rootfs-extracted
[ -f /target/etc/os-release ] && {
    echo "--- /target/etc/os-release ---"
    cat /target/etc/os-release
} || msg "WARN: /target/etc/os-release missing"

msg "[r40] rootfs extracted — bootstrap-base stub will skip-success"
exit 0
