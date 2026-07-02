#!/bin/sh
# r40 partman/late_command — extract pre-built rootfs.tar.zst into /target
# right after partman finishes (so /target is mounted) and before
# bootstrap-base runs. The bookworm bootstrap-base.run-debootstrap will then
# call /usr/sbin/debootstrap (our stub), which detects /target/etc/os-release
# from this extraction and exits 0.
#
# r55+ adds live progress feedback to /dev/tty3 (the d-i log VT — Alt+F3 during
# install) so the long extract phase no longer sits silent at "1%".
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
# loader) is staged to <media>/cixmini/sqtools by build-iso. Preferred over the
# rootfs.tar.zst path; falls through to the tarball if no base.squashfs present.
SQFS_DIR=""
for d in /cdrom/cixmini /hd-media/cixmini /media/cdrom/cixmini /run/live/medium/cixmini; do
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
    ROLE=desktop
    grep -qw "ncz_variant=server" /proc/cmdline 2>/dev/null && ROLE=server
    START=$(date +%s)
    msg "extracting base.squashfs -> /target"
    echo "[sqfs] unsquashfs base ..." > $SER 2>&1
    run_unsq -f -d /target "$SQFS_DIR/base.squashfs" >/dev/null 2>>$SER
    RC=$?
    echo "[sqfs] base rc=$RC -> $(find /target -xdev -type f 2>/dev/null | wc -l) files" > $SER 2>&1
    if [ "$RC" -ne 0 ]; then msg "FATAL: unsquashfs base rc=$RC"; exit 1; fi
    if [ -f "$SQFS_DIR/$ROLE.squashfs" ]; then
        msg "applying $ROLE.squashfs delta -> /target"
        run_unsq -f -d /target "$SQFS_DIR/$ROLE.squashfs" >/dev/null 2>>$SER
        echo "[sqfs] $ROLE rc=$? -> $(find /target -xdev -type f 2>/dev/null | wc -l) files" > $SER 2>&1
        # apply overlay whiteouts: a char device 0:0 in the delta marks a deletion
        find /target -xdev -type c 2>/dev/null | while IFS= read -r w; do
            [ "$(stat -c '%t %T' "$w" 2>/dev/null)" = "0 0" ] && rm -rf "$w"
        done
    else
        msg "no $ROLE.squashfs on media — base only"
    fi
    ELAPSED=$(( $(date +%s) - START ))
    # BAKED marker: run-all runs ONLY machine hooks (fstab/rescue/bootloader), not
    # the desktop/kernel/network hooks — this is what avoids the regression.
    mkdir -p /target/etc; : > /target/etc/ncz-baked
    # first-boot oneshot: finish deferred dpkg config (chroot half-configured pkgs
    # e.g. falkon) + regen machine identity, before the display manager.
    mkdir -p /target/usr/local/sbin /target/etc/systemd/system/multi-user.target.wants
    cat > /target/usr/local/sbin/ncz-firstboot <<'FBS'
#!/bin/sh
export DEBIAN_FRONTEND=noninteractive
dpkg --configure -a 2>/dev/null || true
[ -s /etc/machine-id ] || systemd-machine-id-setup 2>/dev/null || true
systemctl disable ncz-firstboot.service 2>/dev/null || true
touch /var/lib/ncz-firstboot-done
FBS
    chmod +x /target/usr/local/sbin/ncz-firstboot
    cat > /target/etc/systemd/system/ncz-firstboot.service <<'FBU'
[Unit]
Description=NCZ first-boot finalize (dpkg configure + machine identity)
ConditionPathExists=!/var/lib/ncz-firstboot-done
DefaultDependencies=no
After=local-fs.target
Before=display-manager.service gdm.service graphical.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/ncz-firstboot
[Install]
WantedBy=multi-user.target
FBU
    ln -sf ../ncz-firstboot.service /target/etc/systemd/system/multi-user.target.wants/ncz-firstboot.service
    FINAL_MB=$(du -sm /target 2>/dev/null | awk '{print $1}')
    msg "--- layered squashfs install done: ${FINAL_MB} MB in ${ELAPSED}s (role=$ROLE) ---"
    echo "[sqfs] DONE ${FINAL_MB}MB role=$ROLE files=$(find /target -xdev -type f|wc -l)" > $SER 2>&1
    [ -f /target/etc/os-release ] || echo "[sqfs] WARN no os-release" > $SER 2>&1
    touch /target/.cix-r40-rootfs-extracted /target/.cix-squashfs-install
    exit 0
fi


ROOTFS=""
for d in /cdrom/cixmini /hd-media/cixmini /media/cdrom/cixmini /run/live/medium/cixmini; do
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
