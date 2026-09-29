#!/bin/bash
# NCZ-MIXED-HOOK: rescue partition; explicit arm64 and amd64 kernel branches; TODO split (docs/platform-inventory.tsv; runs on every platform, listed in both hooks.list files)
# 72-rescue-partition.sh — populate the r130 dedicated RESCUE PARTITION.
#
# The partman recipe in preseed.cfg creates a 4 GiB ext4 partition
# (NCZRESCUE) with NO mountpoint on the main system. This hook fills it with
# the pre-built rescue rootfs (assets/rescue/rescue-rootfs.tar.zst) and the
# shipping kernel payload, then records a readiness marker.
#
# IMPORTANT — division of labour with 70-bootloader.sh:
#   This hook runs in Phase 2 (numbered hooks). 70-bootloader.sh runs LATER,
#   in run-all.sh's EXIT trap, and rewrites the ESP refind.conf + staged
#   vmlinuz-* every run. So the rEFInd "RESCUE PARTITION" menuentry is written
#   by 70-bootloader.sh (the sole ESP owner), gated on the RESCUE_READY marker
#   this hook leaves behind. Here we only touch the rescue PARTITION (never the
#   ESP), so nothing we do gets clobbered.
#
# On arm64 the rescue partition ships the SHIPPING kernel from
# assets/kernel/edge. It used to ship
# legacy 7.0.12 on the "a recovery env should be boring" principle, which
# was right while two kernels existed. With one kernel that rule would leave
# the rescue partition carrying modules for a kernel no longer built --
# exactly the state found on O6N, where the rescue partition held only 7.0.12
# modules.
#
# 70-bootloader.sh boots this partition with the NORMAL cmdline (display
# drivers KEPT) so the local console is usable; we do NOT apply the
# rescue.target KMS/display blacklist here (that earlier left the rescue
# screen blank).
set -uo pipefail

INSTALLER_META=/usr/local/lib/cix-installer
ASSETS_KERNEL="$INSTALLER_META/assets/kernel"
RESCUE_ASSETS="$INSTALLER_META/assets/rescue"
TARBALL="$RESCUE_ASSETS/rescue-rootfs.tar.zst"
MNT=/mnt/ncz-rescue
MARKER="$INSTALLER_META/RESCUE_READY"

echo "[72] rescue partition population"

# --- preconditions ---
# arm64 stages a raw Image + modules archive and records KVER_NEXT on the ISO.
# AMD64 installs its stable and edge .debs in 10-amd64-kernel.sh and records
# the successfully installed versions in KVER_LIST_AMD64.  This hook used to
# understand only the arm64 contract, so every AMD64 run failed here before it
# could write RESCUE_READY; ncz-refind-refresh-amd64 then (correctly) refused
# to ship without recovery and returned bootloader rc=1.
NCZ_SYSTEM_ARCH="${NCZ_TARGET_ARCH:-}"
if [ -z "$NCZ_SYSTEM_ARCH" ] && [ -r "$INSTALLER_META/BUILD_ARCH" ]; then
    NCZ_SYSTEM_ARCH=$(tr -d '[:space:]' < "$INSTALLER_META/BUILD_ARCH")
fi
NCZ_SYSTEM_ARCH="${NCZ_SYSTEM_ARCH:-$(dpkg --print-architecture 2>/dev/null || true)}"
KVER_RESCUE=""
case "$NCZ_SYSTEM_ARCH" in
    amd64|x86_64)
        KVER_RESCUE=$(sed -n '1p' "$INSTALLER_META/KVER_LIST_AMD64" 2>/dev/null || true)
        if [ -z "$KVER_RESCUE" ]; then
            echo "[72] ERROR: no stable kernel in KVER_LIST_AMD64 — cannot build AMD64 rescue partition" >&2
            exit 1
        fi
        if [ ! -s "/boot/vmlinuz-$KVER_RESCUE" ] || \
           [ ! -s "/boot/initrd.img-$KVER_RESCUE" ] || \
           [ ! -d "/usr/lib/modules/$KVER_RESCUE" ]; then
            echo "[72] ERROR: installed AMD64 stable kernel payload is incomplete for $KVER_RESCUE" >&2
            exit 1
        fi
        ;;
    arm64|aarch64)
        [ -f "$INSTALLER_META/KVER_NEXT" ] && KVER_RESCUE=$(cat "$INSTALLER_META/KVER_NEXT" 2>/dev/null || true)
        if [ -z "$KVER_RESCUE" ]; then
            echo "[72] ERROR: no KVER_NEXT sidecar — cannot build an arm64 rescue partition" >&2
            exit 1
        fi
        if [ ! -f "$ASSETS_KERNEL/edge/Image-cixmini.bin" ] || [ ! -f "$ASSETS_KERNEL/edge/modules-cixmini.tgz" ]; then
            echo "[72] ERROR: shipping kernel assets missing under $ASSETS_KERNEL/edge" >&2
            exit 1
        fi
        ;;
    *)
        echo "[72] ERROR: unsupported target architecture '$NCZ_SYSTEM_ARCH'" >&2
        exit 1
        ;;
esac
if [ ! -f "$TARBALL" ]; then
    echo "[72] ERROR: $TARBALL not present (run build/build-rescue-rootfs.sh at bake time)" >&2
    exit 1
fi
for t in blkid lsblk findmnt zstd tar depmod; do
    command -v "$t" >/dev/null 2>&1 || { echo "[72] ERROR: missing required tool $t" >&2; exit 1; }
done

# --- locate the rescue partition ---
ROOT_SRC=$(findmnt -no SOURCE / 2>/dev/null || true)
ESP_SRC=$(findmnt -no SOURCE /boot/efi 2>/dev/null || true)
echo "[72] root=$ROOT_SRC  esp=$ESP_SRC"

RESCUE_SRC=$(blkid -L NCZRESCUE 2>/dev/null || true)
if [ -z "$RESCUE_SRC" ]; then
    # by GPT partition label
    RESCUE_SRC=$(lsblk -rno NAME,PARTLABEL 2>/dev/null | awk '$2=="NCZRESCUE"{print "/dev/"$1}' | head -1)
fi
if [ -z "$RESCUE_SRC" ] && [ -n "$ROOT_SRC" ]; then
    # by elimination: a partition on the root disk that is neither / nor ESP
    DISK=$(lsblk -no PKNAME "$ROOT_SRC" 2>/dev/null | head -1)
    if [ -n "$DISK" ]; then
        for p in $(lsblk -rno NAME,TYPE "/dev/$DISK" 2>/dev/null | awk '$2=="part"{print "/dev/"$1}'); do
            [ "$p" = "$ROOT_SRC" ] && continue
            [ "$p" = "$ESP_SRC" ] && continue
            RESCUE_SRC="$p"
            break
        done
    fi
fi
if [ -z "$RESCUE_SRC" ] || [ ! -b "$RESCUE_SRC" ]; then
    echo "[72] ERROR: no rescue partition found (no NCZRESCUE, no spare partition)" >&2
    echo "      block devices:"; lsblk 2>&1 | sed 's/^/        /' | head -20
    exit 1
fi
echo "[72] rescue partition = $RESCUE_SRC"

# Guard: never clobber the live root or ESP.
if [ "$RESCUE_SRC" = "$ROOT_SRC" ] || [ "$RESCUE_SRC" = "$ESP_SRC" ]; then
    echo "[72] ERROR: refusing to use $RESCUE_SRC (it is the live root or ESP)" >&2
    exit 1
fi

# --- ensure ext4 + label ---
FST=$(blkid -s TYPE -o value "$RESCUE_SRC" 2>/dev/null || true)
if [ "$FST" != "ext4" ]; then
    command -v mkfs.ext4 >/dev/null 2>&1 || {
        echo "[72] ERROR: $RESCUE_SRC is '$FST' and mkfs.ext4 is unavailable" >&2
        exit 1
    }
    echo "[72] $RESCUE_SRC is '$FST' — formatting ext4 (NCZRESCUE)"
    mkfs.ext4 -F -L NCZRESCUE "$RESCUE_SRC" || { echo "[72] ERROR: mkfs failed" >&2; exit 1; }
else
    command -v e2label >/dev/null 2>&1 && e2label "$RESCUE_SRC" NCZRESCUE 2>/dev/null || true
fi

# --- mount + extract rootfs ---
mkdir -p "$MNT"
umount "$MNT" 2>/dev/null || true
if ! mount "$RESCUE_SRC" "$MNT"; then
    echo "[72] ERROR: mount $RESCUE_SRC failed" >&2; exit 1
fi

echo "[72] extracting rescue rootfs -> $MNT"
if ! zstd -dc "$TARBALL" | tar -xpf - -C "$MNT" --numeric-owner; then
    echo "[72] rootfs extract failed — unmounting + skipping"
    umount "$MNT" 2>/dev/null || true
    exit 1
fi

# Every installed rescue partition needs its own D-Bus identity and SSH host
# keys. The golden archive deliberately carries neither, so keys from one NCZ
# device cannot impersonate another rescue environment.
echo "[72] generating per-device rescue machine-id + SSH host keys"
rm -f "$MNT/etc/machine-id" "$MNT/var/lib/dbus/machine-id" \
      "$MNT"/etc/ssh/ssh_host_*
if ! chroot "$MNT" systemd-machine-id-setup >/dev/null 2>&1 || \
   [ ! -s "$MNT/etc/machine-id" ]; then
    echo "[72] ERROR: could not generate rescue machine-id" >&2
    umount "$MNT" 2>/dev/null || true
    exit 1
fi
mkdir -p "$MNT/var/lib/dbus"
ln -sf /etc/machine-id "$MNT/var/lib/dbus/machine-id"
if ! chroot "$MNT" ssh-keygen -A >/dev/null 2>&1 || \
   [ ! -s "$MNT/etc/ssh/ssh_host_ed25519_key" ]; then
    echo "[72] ERROR: could not generate rescue SSH host keys" >&2
    umount "$MNT" 2>/dev/null || true
    exit 1
fi
echo "[72]   rescue identity and SSH host keys generated"

# --- per-device rescue hostname + static-IP-fallback octet (fix 2026-09-13) ---
# The golden rescue-rootfs tarball (build/build-rescue-rootfs.sh) bakes ONE
# constant RESCUE_HOSTNAME ("ncz-rescue") and ONE constant static-IP-fallback
# address, identical across EVERY board that installs from this pipeline --
# the same class of bug already fixed for the main OS by
# post-install/37-ntp-hostname.sh (ncz-<MAC-derived-hex>), and the same class
# of bug that already caused one real production collision on the static IP
# (192.168.207.66 collided with cixmini the build host, fixed 2026-07-20 by
# moving to .199 -- see build/build-rescue-rootfs.sh). .199 is no longer a
# PRODUCTION collision, but it is still shared by every board's rescue
# partition, so two boards booting rescue with no DHCP on the same LAN would
# still collide with EACH OTHER. build-rescue-rootfs.sh runs on the generic
# ARGOS build host and has no specific board to read a MAC from -- this hook
# runs at install time ON the target board, same as 37-ntp-hostname.sh, so it
# is the right place to make both values per-device.
echo "[72] setting per-device rescue hostname + static-IP-fallback octet"
RESCUE_MAC=""
for ifpath in /sys/class/net/*; do
    [ -e "$ifpath" ] || continue
    iface=${ifpath##*/}
    case "$iface" in lo|virbr*|docker*|veth*|br-*|tun*|tap*) continue ;; esac
    if [ -d "$ifpath/wireless" ] || [ -d "$ifpath/phy80211" ]; then continue; fi
    if [ -r "$ifpath/address" ]; then
        m=$(tr -d ":" < "$ifpath/address" | tr "[:upper:]" "[:lower:]")
        if [ -n "$m" ] && [ "$m" != "000000000000" ]; then
            RESCUE_MAC="$m"
            break
        fi
    fi
done
if [ -z "$RESCUE_MAC" ] && [ -r /etc/machine-id ]; then
    # No wired NIC found (shouldn't happen on Sky1 boards) -- fall back to the
    # just-generated machine-id, same ladder as 37-ntp-hostname.sh pass 3.
    RESCUE_MAC=$(sha256sum /etc/machine-id 2>/dev/null | cut -c1-12)
fi
if [ -n "$RESCUE_MAC" ]; then
    RESCUE_HOSTNAME_INSTALLED="ncz-rescue-${RESCUE_MAC: -6}"
    # Map the MAC into a per-device static-IP-fallback octet.
    #
    # CORRECTED 2026-09-13 (zoder/MiniMax-M3 + TYDEUS/nemotron35 adversarial
    # review, both independently confirmed): the original 31-bucket range
    # (220-250, "% 31") mathematically cannot meet this block's own stated
    # goal of avoiding rescue-to-rescue collisions. Birthday-paradox collision
    # probability P(collision) ~= 1 - exp(-k(k-1)/2n): for n=31, k=10 boards
    # -> ~76%, k=20 -> ~99.8%, k=30 -> ~99.9998%. A SINGLE IP octet cannot fix
    # this for a 20-30 board fleet -- even the full 0-255 range (n=256) is
    # still ~86% collision at k=30; the birthday problem needs roughly n>=k^2
    # for a low collision rate, which one octet never supplies. A COMPLETE
    # fix needs either (a) a two-MAC-byte-derived address outside
    # 192.168.207.0/24 -- which defeats reachability, since this subnet is
    # the fleet's only routed LAN segment (CLAUDE.md directive 8) -- or
    # (b) an ARP-probe-and-retry claim added to ncz-rescue-net-fallback
    # itself (a different file/service, out of scope for this hook). NEITHER
    # is done here; this is a documented, accepted residual risk, not a
    # closed one.
    #
    # What IS done: widen from 31 to 114 buckets (140-253). Verified clear
    # 2026-09-13 against the Island gateway's `show ip dhcp reservations`
    # (15 static reservations, all <= .101) and `show ip neighbors` (only
    # live host above .101 was .132/forge-worker-01, well below this
    # window). This is a MEANINGFUL REDUCTION, not a fix: at k=10 boards
    # P(collision) drops from ~76% to ~35% (n=114); it does not reach a low
    # absolute probability for a large fleet. The real exposure is narrower
    # than "the whole fleet collides" -- it requires two boards to be
    # simultaneously rescue-booted AND both to have failed DHCP AND to land
    # on the same derived octet -- but the residual risk is real and should
    # be tracked as a follow-up, not assumed solved by this widening.
    OCTET_DEC=$(( 16#${RESCUE_MAC: -2} % 114 + 140 ))
    # Never let a MAC-derived value land exactly on the shared .199 baked
    # default -- that would make a MAC-derived board indistinguishable from
    # one that failed derivation and is still sitting on the baked fallback.
    [ "$OCTET_DEC" = 199 ] && OCTET_DEC=198
else
    echo "[72] WARN: could not derive a MAC for rescue hostname/IP -- leaving baked defaults" >&2
    RESCUE_HOSTNAME_INSTALLED=""
    OCTET_DEC=""
fi
if [ -n "$RESCUE_HOSTNAME_INSTALLED" ]; then
    echo "$RESCUE_HOSTNAME_INSTALLED" > "$MNT/etc/hostname"
    if grep -q "^127\.0\.1\.1" "$MNT/etc/hosts" 2>/dev/null; then
        sed -i "s|^127\.0\.1\.1.*|127.0.1.1\t${RESCUE_HOSTNAME_INSTALLED}|" "$MNT/etc/hosts"
    else
        printf '127.0.1.1\t%s\n' "$RESCUE_HOSTNAME_INSTALLED" >> "$MNT/etc/hosts"
    fi
    echo "[72]   rescue hostname -> $RESCUE_HOSTNAME_INSTALLED (MAC-derived)"
fi
if [ -n "$OCTET_DEC" ] && [ -f "$MNT/usr/local/sbin/ncz-rescue-net-fallback" ]; then
    sed -i -E "s|192\.168\.207\.[0-9]+/24|192.168.207.${OCTET_DEC}/24|g" \
        "$MNT/usr/local/sbin/ncz-rescue-net-fallback"
    echo "[72]   rescue static-IP-fallback -> 192.168.207.${OCTET_DEC}/24 (MAC-derived)"
fi

# --- auto-network + remote recovery access (operator directive 2026-07-29) ---
# A rescue partition that can't be reached over the network is useless when
# the failure being recovered from is a bricked main-kernel boot -- physical
# console access may not be available. The baked ncz-rescue-net units provide
# bounded DHCP plus a static fallback; ssh is also baked and enabled. This hook
# validates that release contract and removes stale competing networkd wiring.
echo "[72] verifying rescue rootfs auto-network + remote access"
# The rescue image already ships one authoritative, time-bounded network owner:
# ncz-rescue-net (dhclient/udhcpc) plus ncz-rescue-net-fallback. Do not also
# enable systemd-networkd for the same NIC; v17 shipped both and produced a DHCP
# ownership race. Remove any stale networkd wiring/config from an older image.
rm -f "$MNT/etc/systemd/system/multi-user.target.wants/systemd-networkd.service" \
      "$MNT/etc/systemd/system/network-online.target.wants/systemd-networkd-wait-online.service"
rm -f "$MNT/etc/systemd/network/20-wired-dhcp.network"
if [ ! -x "$MNT/usr/local/sbin/ncz-rescue-net" ] || \
   [ ! -x "$MNT/usr/local/sbin/ncz-rescue-net-fallback" ] || \
   [ ! -L "$MNT/etc/systemd/system/multi-user.target.wants/ncz-rescue-net.service" ] || \
   [ ! -L "$MNT/etc/systemd/system/multi-user.target.wants/ncz-rescue-net-fallback.service" ]; then
    echo "[72] ERROR: rescue rootfs lacks enabled ncz-rescue-net DHCP/fallback units" >&2
    umount "$MNT" 2>/dev/null || true
    exit 1
fi
mkdir -p "$MNT/etc/systemd/system/multi-user.target.wants"
if [ -f "$MNT/usr/lib/systemd/system/ssh.service" ]; then
    mkdir -p "$MNT/etc/systemd/system/multi-user.target.wants"
    ln -sf /usr/lib/systemd/system/ssh.service "$MNT/etc/systemd/system/multi-user.target.wants/ssh.service"
    echo "[72]   ssh.service enabled"
else
    echo "[72] ERROR: ssh.service not present in rescue rootfs image" >&2
    umount "$MNT" 2>/dev/null || true
    exit 1
fi
if [ -f "$MNT/usr/lib/systemd/system/inetd.service" ] || [ -x "$MNT/usr/sbin/telnetd" ] || [ -x "$MNT/usr/sbin/in.telnetd" ]; then
    mkdir -p "$MNT/etc/systemd/system/multi-user.target.wants"
    for svc in inetd.service telnet.socket; do
        [ -f "$MNT/usr/lib/systemd/system/$svc" ] && ln -sf "/usr/lib/systemd/system/$svc" "$MNT/etc/systemd/system/multi-user.target.wants/$svc"
    done
    echo "[72]   telnet available and enabled (console fallback, LAN-only per fleet doctrine)"
fi
echo "[72] auto-network + remote access verified (single owner: ncz-rescue-net)"

# --- install shipping kernel + modules into the rescue rootfs ---
# Modules MUST go in via --keep-directory-symlink (never plain -C /): the
# tarball carries a top-level lib/ entry, and on a usrmerge rootfs /lib is a
# symlink to usr/lib. A naive extract would clobber that symlink and orphan
# ld-linux — the exact failure mode this rescue env exists to repair.
echo "[72] installing shipping kernel $KVER_RESCUE into rescue rootfs"
if [ "$NCZ_SYSTEM_ARCH" = "amd64" ] || [ "$NCZ_SYSTEM_ARCH" = "x86_64" ]; then
    # The .deb install already produced the authoritative kernel, initrd and
    # module tree. Copy those exact files so rescue cannot drift from the T2
    # kernel that 70-bootloader.sh stages on the ESP.
    install -D -m 0644 "/boot/vmlinuz-$KVER_RESCUE" "$MNT/boot/vmlinuz-$KVER_RESCUE" || {
        echo "[72] ERROR: failed to copy AMD64 rescue kernel" >&2
        umount "$MNT" 2>/dev/null || true
        exit 1
    }
    install -D -m 0644 "/boot/initrd.img-$KVER_RESCUE" "$MNT/boot/initrd.img-$KVER_RESCUE" || {
        echo "[72] ERROR: failed to copy AMD64 rescue initrd" >&2
        umount "$MNT" 2>/dev/null || true
        exit 1
    }
    mkdir -p "$MNT/usr/lib/modules/$KVER_RESCUE"
    cp -a "/usr/lib/modules/$KVER_RESCUE/." "$MNT/usr/lib/modules/$KVER_RESCUE/" || {
        echo "[72] ERROR: failed to copy AMD64 rescue modules" >&2
        umount "$MNT" 2>/dev/null || true
        exit 1
    }
else
    install -D -m 0644 "$ASSETS_KERNEL/edge/Image-cixmini.bin" "$MNT/boot/vmlinuz-$KVER_RESCUE" || {
        echo "[72] ERROR: failed to copy arm64 rescue kernel" >&2
        umount "$MNT" 2>/dev/null || true
        exit 1
    }
    tar xzf "$ASSETS_KERNEL/edge/modules-cixmini.tgz" -C "$MNT/usr" --strip-components=0 --keep-directory-symlink || {
        echo "[72] ERROR: failed to extract arm64 rescue modules" >&2
        umount "$MNT" 2>/dev/null || true
        exit 1
    }
fi
if [ ! -d "$MNT/usr/lib/modules/$KVER_RESCUE" ]; then
    echo "[72] WARN: kernel install did not produce $MNT/usr/lib/modules/$KVER_RESCUE"
    ls "$MNT/usr/lib/modules/" 2>&1 | sed 's/^/        /'
else
    MODC=$(find "$MNT/usr/lib/modules/$KVER_RESCUE" -name '*.ko*' 2>/dev/null | wc -l)
    echo "[72] $MODC modules staged; running depmod"
    depmod -b "$MNT" "$KVER_RESCUE" 2>/dev/null || echo "[72] WARN: depmod returned non-zero"
fi

# initrd: reuse the main system's edge initrd (generic; mounts root=PARTUUID).
# 70-bootloader.sh stages the ESP copy; this in-rootfs copy is for completeness.
if [ -s "/boot/initrd.img-$KVER_RESCUE" ]; then
    install -D -m 0644 "/boot/initrd.img-$KVER_RESCUE" "$MNT/boot/initrd.img-$KVER_RESCUE"
fi

# --- AGENTS.md (refresh from asset if present) ---
if [ -f "$RESCUE_ASSETS/AGENTS.md" ]; then
    install -m 0644 "$RESCUE_ASSETS/AGENTS.md" "$MNT/AGENTS.md"
    install -D -m 0644 "$RESCUE_ASSETS/AGENTS.md" "$MNT/root/AGENTS.md"
    echo "[72] AGENTS.md refreshed in rescue rootfs"
fi

# --- verify the usrmerge /lib symlink survived ---
if [ -L "$MNT/lib" ]; then
    echo "[72] OK: rescue /lib -> $(readlink "$MNT/lib") (usrmerge symlink intact)"
else
    echo "[72] WARN: rescue /lib is not a symlink — running fixlib"
    [ -x "$MNT/usr/local/sbin/ncz-rescue-fixlib" ] && chroot "$MNT" /usr/local/sbin/ncz-rescue-fixlib / 2>/dev/null || true
fi

# --- readiness marker for 70-bootloader.sh ---
RP_PARTUUID=$(blkid -s PARTUUID -o value "$RESCUE_SRC" 2>/dev/null || true)
if [ -z "$RP_PARTUUID" ]; then
    echo "[72] ERROR: $RESCUE_SRC has no PARTUUID; cannot create a bootable rescue entry" >&2
    umount "$MNT" 2>/dev/null || true
    exit 1
fi
{
    echo "PARTUUID=$RP_PARTUUID"
    echo "KVER=$KVER_RESCUE"
    echo "DEV=$RESCUE_SRC"
} > "$MARKER"
echo "[72] wrote marker $MARKER (PARTUUID=$RP_PARTUUID)"

# --- hide the rescue partition from the desktop (udisks/gvfs/xfdesktop) ---
# It is an internal volume (HintSystem=true), so its auto-shown desktop icon
# cannot be mounted by an unprivileged click -- udisks polkit returns
# NotAuthorized (operator-reported 2026-06-25). UDISKS_IGNORE removes it from
# the volume list entirely; admins still sudo-mount it when needed.
install -d -m 0755 /etc/udev/rules.d
cat > /etc/udev/rules.d/99-ncz-rescue-hide.rules <<'UDEV'
# NCZ rescue partition: internal system volume, not user-mountable data.
SUBSYSTEM=="block", ENV{ID_FS_LABEL}=="NCZRESCUE", ENV{UDISKS_IGNORE}="1"
UDEV
echo "[72] udev rule installed: NCZRESCUE hidden from desktop (UDISKS_IGNORE)"

# --- finish: sync, unmount, reclaim space ---
sync
umount "$MNT" 2>/dev/null || true
rm -f "$TARBALL" 2>/dev/null || true   # reclaim ~hundreds of MB on the main root
echo "[72] rescue partition ready — 70-bootloader.sh will add the loader entry"
exit 0
