#!/usr/bin/env python3
import gzip, os, shutil, subprocess
from pathlib import Path

SRC_ISO = Path(os.environ.get('R80_ISO', '/Users/jperlow/ncz-installer-cixmini-26.6-r80.iso'))
OUT_IMG = Path(os.environ.get('OUT_IMG', '/Users/jperlow/ncz-r80-pure-rescue-cixmini.img'))
OUT_ISO = Path(os.environ.get('OUT_ISO', '/Users/jperlow/ncz-r80-pure-rescue-cixmini.iso'))
WORK = Path(os.environ.get('WORKDIR', '/var/folders/tx/qq80lg3x1zs1b1hkmtk2spgm0000gp/T/opencode/ncz-r80-pure-rescue-build'))


def run(cmd, **kw):
    print('+', ' '.join(map(str, cmd)), flush=True)
    subprocess.run(cmd, check=True, **kw)


def clean():
    if WORK.exists():
        subprocess.run(['chmod', '-R', 'u+w', str(WORK)], check=False)
        shutil.rmtree(WORK)
    WORK.mkdir(parents=True)


def extract(member, dest):
    run(['bsdtar', '-xf', str(SRC_ISO), '-C', str(dest), member])


def unpack_initrd(gz, dest):
    dest.mkdir(parents=True, exist_ok=True)
    p1 = subprocess.Popen(['gzip', '-dc', str(gz)], stdout=subprocess.PIPE)
    p2 = subprocess.run(['cpio', '-id', '--quiet'], cwd=dest, stdin=p1.stdout, check=False)
    if p1.stdout:
        p1.stdout.close()
    rc1 = p1.wait()
    if rc1 != 0 or p2.returncode not in (0, 2):
        raise SystemExit(f'unpack failed gzip={rc1} cpio={p2.returncode}')


def repack_initrd(src, out):
    if out.exists(): out.unlink()
    find = subprocess.Popen(['find', '.'], cwd=src, stdout=subprocess.PIPE)
    cpio = subprocess.Popen(['cpio', '-o', '-H', 'newc', '--quiet'], cwd=src, stdin=find.stdout, stdout=subprocess.PIPE)
    if find.stdout: find.stdout.close()
    with gzip.open(out, 'wb', compresslevel=9) as gz:
        shutil.copyfileobj(cpio.stdout, gz)
    if cpio.stdout: cpio.stdout.close()
    if find.wait() or cpio.wait():
        raise SystemExit('repack failed')

PURE_INIT = r'''#!/bin/sh
set +e
export PATH=/bin:/sbin:/usr/bin:/usr/sbin

mount -t proc proc /proc 2>/dev/null || true
mount -t sysfs sysfs /sys 2>/dev/null || true
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
mkdir -p /dev/pts /run /tmp /target-ro /target-rw /target-esp /www /rescue-tools /mnt
mount -t devpts devpts /dev/pts 2>/dev/null || true

LOG=/tmp/ncz-rescue.log
exec >>$LOG 2>&1

echo "=== NCZ PURE RESCUE $(date) ==="
cat /proc/cmdline

for a in sh cat ls cp mv rm mkdir rmdir ln mount umount dmesg ps grep sed awk cut head tail sort uniq sleep sync date uname ping nc httpd udhcpc ip route chmod chown readlink realpath find tar gzip gunzip killall pidof blkid; do
    [ -e /bin/$a ] || ln -s /bin/busybox /bin/$a 2>/dev/null || true
    [ -e /usr/bin/$a ] || ln -s /bin/busybox /usr/bin/$a 2>/dev/null || true
done

for m in nvme nvme-core sd_mod usb-storage uas ahci xhci-hcd xhci-pci r8169 realtek btrfs xor raid6_pq zstd_compress zstd_decompress ext4 mbcache jbd2 vfat fat nls_cp437 nls_ascii efivarfs cix_mbox scmi_mailbox_transport clk-sky1-acpi reset_sky1 reset_sky1_audss cix-acpi-resource-lookup cix-usbdp-phy cix-edp-panel pwm_bl drm drm_kms_helper drm_display_helper drm_dma_helper drm_shmem_helper cix_virtual trilin-dpsub linlon-dp; do
    modprobe "$m" 2>/dev/null || true
done

# DHCP all NICs; static fallback.
for i in $(ls /sys/class/net 2>/dev/null | grep -v '^lo$'); do
    ip link set "$i" up 2>/dev/null || true
    udhcpc -i "$i" -q -n -t 5 2>/dev/null || true
done
if ! ip -4 addr show | grep -q 'inet '; then
    iface=$(ls /sys/class/net 2>/dev/null | grep -v '^lo$' | head -1)
    [ -n "$iface" ] && ip addr add 192.168.207.66/24 dev "$iface" 2>/dev/null || true
    [ -n "$iface" ] && ip route add default via 192.168.207.1 2>/dev/null || true
fi
ip addr || true
ip route || true

repair_root() {
    root="$1"
    echo "[repair] checking root $root"
    [ -d "$root/usr/lib" ] || return 0
    if [ -d "$root/lib" ] && [ ! -L "$root/lib" ]; then
        ts=$(date +%Y%m%d-%H%M%S)
        echo "[repair] /lib real dir -> lib.broken.$ts + symlink"
        mv "$root/lib" "$root/lib.broken.$ts"
        ln -s usr/lib "$root/lib"
        mkdir -p "$root/usr/lib/modules"
        cp -a "$root/lib.broken.$ts/modules/." "$root/usr/lib/modules/" 2>/dev/null || true
        return 1
    fi
    echo "[repair] /lib ok"
    return 0
}

fix_boot_default() {
    esp="$1"
    [ -d "$esp/loader/entries" ] || return 0
    echo "[repair] ESP $esp -> default cixmini-lts.conf"
    cp "$esp/loader/loader.conf" "$esp/loader/loader.conf.rescue-bak.$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
    printf 'default cixmini-lts.conf\ntimeout 5\n' > "$esp/loader/loader.conf"
    return 1
}

fixed=0
if ! grep -qw ncz_rescue_no_autofix /proc/cmdline; then
    for dev in /dev/nvme*n*p* /dev/sd*[0-9] /dev/mmcblk*p*; do
        [ -b "$dev" ] || continue
        umount /target-rw 2>/dev/null || true
        mounted=0
        for opt in rw,subvol=@ rw,subvol=/ rw; do
            mount -t btrfs -o "$opt" "$dev" /target-rw 2>/dev/null && mounted=1 && break
        done
        if [ "$mounted" != 1 ]; then
            mount -t ext4 -o rw "$dev" /target-rw 2>/dev/null && mounted=1 || true
        fi
        [ "$mounted" = 1 ] || continue
        if [ -e /target-rw/etc/os-release ] || [ -e /target-rw/usr/lib/os-release ]; then
            repair_root /target-rw; [ $? -eq 1 ] && fixed=1
        fi
        sync; umount /target-rw 2>/dev/null || true
    done
    for dev in /dev/nvme*n*p* /dev/sd*[0-9] /dev/mmcblk*p*; do
        [ -b "$dev" ] || continue
        umount /target-esp 2>/dev/null || true
        mount -t vfat -o rw "$dev" /target-esp 2>/dev/null || continue
        fix_boot_default /target-esp; [ $? -eq 1 ] && fixed=1
        sync; umount /target-esp 2>/dev/null || true
    done
fi

# Read-only browse mounts.
for dev in /dev/nvme*n*p* /dev/sd*[0-9] /dev/mmcblk*p*; do
    [ -b "$dev" ] || continue
    mp=/target-ro/$(basename "$dev")
    mkdir -p "$mp"
    mount -o ro "$dev" "$mp" 2>/dev/null || rmdir "$mp" 2>/dev/null || true
done

cat > /www/index.txt <<EOF
NCZ pure rescue is running.
Shell: nc <ip> 2323
Log: /ncz-rescue.log
Mounts: /target-ro/*
fixed=$fixed
EOF
ln -sf /tmp/ncz-rescue.log /www/ncz-rescue.log
ln -sf /target-ro /www/target-ro

cat > /rescue-tools/status <<'EOF'
#!/bin/sh
uname -a
cat /proc/cmdline
ip addr
ip route
mount
ls -la /target-ro
cat /tmp/ncz-rescue.log | tail -120
EOF
chmod +x /rescue-tools/status

killall httpd 2>/dev/null || true
httpd -f -p 80 -h /www >/tmp/httpd.log 2>&1 &

while true; do
    rm -f /tmp/rescue-shell.in
    mkfifo /tmp/rescue-shell.in
    cat /tmp/rescue-shell.in | /bin/sh -i 2>&1 | nc -l -p 2323 > /tmp/rescue-shell.in
    rm -f /tmp/rescue-shell.in
    sleep 1
done &

if [ "$fixed" = 1 ] && ! grep -qw ncz_rescue_no_autoreboot /proc/cmdline; then
    echo "[repair] fixed local system; rebooting in 20s"
    sleep 20
    reboot -f
fi

echo "=== rescue ready fixed=$fixed ==="
while true; do sleep 3600; done
'''

def write_grub(tree):
    grub = tree/'boot/grub/grub.cfg'
    grub.parent.mkdir(parents=True, exist_ok=True)
    grub.write_text('''set timeout=5\nset default=0\ninsmod part_gpt\ninsmod part_msdos\ninsmod fat\nsearch --no-floppy --file /install.a64/vmlinuz --set=root\nmenuentry "NCZ PURE RESCUE autofix local root + known-good boot" {\n linux /install.a64/vmlinuz loglevel=4 console=tty0 console=ttyAMA2,115200 efi=noruntime acpi=force arm-smmu-v3.disable_bypass=0 audit_backlog_limit=8192 clk_ignore_unused keep_bootcon panic=30 module_blacklist=typec_rts5453,rts5453\n initrd /install.a64/initrd.gz\n}\nmenuentry "NCZ PURE RESCUE no autofix/no reboot" {\n linux /install.a64/vmlinuz ncz_rescue_no_autofix ncz_rescue_no_autoreboot loglevel=4 console=tty0 console=ttyAMA2,115200 efi=noruntime acpi=force arm-smmu-v3.disable_bypass=0 audit_backlog_limit=8192 clk_ignore_unused keep_bootcon panic=30 module_blacklist=typec_rts5453,rts5453\n initrd /install.a64/initrd.gz\n}\n''')
    (tree/'EFI/boot').mkdir(parents=True, exist_ok=True)
    (tree/'EFI/debian').mkdir(parents=True, exist_ok=True)
    shutil.copy2(grub, tree/'EFI/debian/grub.cfg')


def build():
    if WORK.exists():
        subprocess.run(['chmod','-R','u+w',str(WORK)], check=False)
        shutil.rmtree(WORK)
    tree=WORK/'tree'; initrd=WORK/'initrd'
    tree.mkdir(parents=True); initrd.mkdir(parents=True)
    for m in ['EFI/boot/bootaa64.efi','EFI/boot/grubaa64.efi','install.a64/initrd.gz','cixmini/assets/kernel/lts/Image-cixmini.bin','cixmini/assets/kernel/lts/modules-cixmini.tgz','cixmini/assets/sky1-firmware']:
        extract(m, tree)
    (tree/'install.a64').mkdir(exist_ok=True)
    shutil.copy2(tree/'cixmini/assets/kernel/lts/Image-cixmini.bin', tree/'install.a64/vmlinuz')
    unpack_initrd(tree/'install.a64/initrd.gz', initrd)
    run(['tar','-C',str(initrd),'-xzf',str(tree/'cixmini/assets/kernel/lts/modules-cixmini.tgz')])
    fw_src=tree/'cixmini/assets/sky1-firmware'
    if fw_src.exists(): shutil.copytree(fw_src, initrd/'lib/firmware', dirs_exist_ok=True)
    (initrd/'init').write_text(PURE_INIT); os.chmod(initrd/'init',0o755)
    repack_initrd(initrd, tree/'install.a64/initrd.gz')
    write_grub(tree)
    (tree/'README-RESCUE.txt').write_text('NCZ pure rescue. Shell: nc <ip> 2323. HTTP: http://<ip>/\n')
    # USB image
    dmg=WORK/'pure.dmg'
    run(['hdiutil','create','-size','768m','-layout','MBRSPUD','-fs','MS-DOS FAT32','-volname','NCZRESCUE',str(dmg)])
    attach=subprocess.check_output(['hdiutil','attach','-readwrite','-noverify','-noautoopen',str(dmg)], text=True)
    print(attach)
    disk=None; mp=None
    for line in attach.splitlines():
        parts=line.split()
        if parts and parts[0].startswith('/dev/disk'):
            if disk is None: disk=parts[0].replace('s1','')
            if len(parts)>=3 and parts[-1].startswith('/Volumes/'): mp=Path(parts[-1])
    if not mp: raise SystemExit('no mountpoint')
    try:
        run(['ditto',str(tree)+'/',str(mp)+'/']); run(['sync'])
    finally:
        if disk:
            subprocess.run(['hdiutil','detach',disk],check=False)
            subprocess.run(['hdiutil','detach',disk,'-force'],check=False)
    raw=WORK/'pure.raw'
    conv=subprocess.run(['hdiutil','convert',str(dmg),'-format','UFBI','-o',str(raw)],check=False)
    produced = raw if raw.exists() else Path(str(raw)+'.dmg')
    if produced.exists(): produced.rename(OUT_IMG)
    else: shutil.copy2(dmg, OUT_IMG)
    run(['hdiutil','imageinfo',str(OUT_IMG)])
    run(['shasum','-a','256',str(OUT_IMG)])

if __name__ == '__main__':
    build()
