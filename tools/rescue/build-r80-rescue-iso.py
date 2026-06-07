#!/usr/bin/env python3
import gzip
import os
import shutil
import subprocess
import sys
from pathlib import Path

SRC_ISO = Path(os.environ.get("R80_ISO", "/Users/jperlow/ncz-installer-cixmini-26.6-r80.iso"))
OUT_ISO = Path(os.environ.get("OUT_ISO", "/Users/jperlow/ncz-r80-rescue-cixmini.iso"))
OUT_IMG = Path(os.environ.get("OUT_IMG", "/Users/jperlow/ncz-r80-rescue-cixmini.img"))
WORK = Path(os.environ.get("WORKDIR", "/var/folders/tx/qq80lg3x1zs1b1hkmtk2spgm0000gp/T/opencode/ncz-r80-rescue-build"))
VOL = "NCZ_R80_RESCUE"


def run(cmd, **kwargs):
    print("+", " ".join(map(str, cmd)))
    subprocess.run(cmd, check=True, **kwargs)


def ensure_tools():
    for tool in ["bsdtar", "hdiutil", "cpio", "gzip"]:
        if not shutil.which(tool):
            raise SystemExit(f"missing required tool: {tool}")
    if not SRC_ISO.exists():
        raise SystemExit(f"source ISO not found: {SRC_ISO}")


def extract_iso_tree(root: Path):
    root.mkdir(parents=True, exist_ok=True)
    # Extract just the boot pieces and docs/pool needed by the initrd. The ISO
    # itself does not need the full package pool for rescue because the rescue
    # script uses tools already present in the d-i initrd.
    for member in [
        "EFI/boot/bootaa64.efi",
        "EFI/boot/grubaa64.efi",
        "boot/grub/grub.cfg",
        "install.a64/vmlinuz",
        "install.a64/initrd.gz",
        "cixmini/assets/kernel/lts/Image-cixmini.bin",
        "cixmini/assets/kernel/lts/modules-cixmini.tgz",
        "cixmini/assets/sky1-firmware",
    ]:
        run(["bsdtar", "-xf", str(SRC_ISO), "-C", str(root), member])


def unpack_initrd(initrd_gz: Path, out: Path):
    out.mkdir(parents=True, exist_ok=True)
    p1 = subprocess.Popen(["gzip", "-dc", str(initrd_gz)], stdout=subprocess.PIPE)
    p2 = subprocess.run(["cpio", "-id", "--quiet"], cwd=out, stdin=p1.stdout, check=False)
    if p1.stdout:
        p1.stdout.close()
    rc1 = p1.wait()
    if rc1 != 0 or p2.returncode not in (0, 2):
        # cpio may return 2 for device nodes when not root on macOS; those are
        # non-fatal for our modified archive because the original already had them.
        raise SystemExit(f"initrd unpack failed: gzip={rc1} cpio={p2.returncode}")


def repack_initrd(src: Path, out_gz: Path):
    if out_gz.exists():
        out_gz.unlink()
    # Use portable newc cpio; include leading . paths.
    find = subprocess.Popen(["find", "."], cwd=src, stdout=subprocess.PIPE)
    cpio = subprocess.Popen(["cpio", "-o", "-H", "newc", "--quiet"], cwd=src, stdin=find.stdout, stdout=subprocess.PIPE)
    if find.stdout:
        find.stdout.close()
    with gzip.open(out_gz, "wb", compresslevel=9) as gz:
        shutil.copyfileobj(cpio.stdout, gz)
    if cpio.stdout:
        cpio.stdout.close()
    rc_find = find.wait()
    rc_cpio = cpio.wait()
    if rc_find or rc_cpio:
        raise SystemExit(f"initrd repack failed: find={rc_find} cpio={rc_cpio}")


def write_rescue_payload(initrd: Path):
    script = r'''#!/bin/sh
set -eu
PATH=/bin:/sbin:/usr/bin:/usr/sbin
LOG=/tmp/ncz-rescue.log
exec >>$LOG 2>&1

echo "=== NCZ R80 rescue startup $(date) ==="

# Make sure basic pseudo-fs and devices exist.
mount -t proc proc /proc 2>/dev/null || true
mount -t sysfs sysfs /sys 2>/dev/null || true
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
mkdir -p /dev/pts /tmp /run /target-ro /rescue-www
mount -t devpts devpts /dev/pts 2>/dev/null || true

# Load likely storage/network/fs modules. Ignore failures: d-i kernel may have
# many built in, and module availability depends on R80 initrd contents.
for m in nvme nvme-core sd_mod usb-storage uas ahci xhci-hcd xhci-pci r8169 realtek ext4 vfat fat nls_cp437 nls_ascii efivarfs; do
    modprobe "$m" 2>/dev/null || true
done

# Bring up network using DHCP on all visible non-loopback interfaces.
for i in $(ls /sys/class/net 2>/dev/null | grep -v '^lo$' || true); do
    ip link set "$i" up 2>/dev/null || true
    udhcpc -i "$i" -q -n -t 5 2>/dev/null || true
done

# Prefer the static rescue address if no DHCP address appeared.
if ! ip -4 addr show | grep -q 'inet '; then
    ip addr add 192.168.207.66/24 dev $(ls /sys/class/net | grep -v '^lo$' | head -1) 2>/dev/null || true
    ip route add default via 192.168.207.1 2>/dev/null || true
fi

ip -4 addr show || true

# Mount local filesystems read-only by default. Never fsck/mutate automatically.
n=0
for dev in /dev/nvme*n*p* /dev/sd*[0-9] /dev/mmcblk*p*; do
    [ -b "$dev" ] || continue
    n=$((n+1))
    mp="/target-ro/$(basename "$dev")"
    mkdir -p "$mp"
    mount -o ro "$dev" "$mp" 2>/dev/null || rmdir "$mp" 2>/dev/null || true
done

cat > /rescue-www/index.txt <<EOF
NCZ R80 rescue is running.

Remote shell: nc <this-ip> 2323
HTTP file browser/root: http://<this-ip>/
Log: /tmp/ncz-rescue.log
Mounted local filesystems: /target-ro/*
Helper commands:
  /rescue-tools/status
  /rescue-tools/fix-lib-symlink
  /rescue-tools/force-r80-lts-default
  /rescue-tools/remount-target-rw <mountpoint>
EOF
ln -s /target-ro /rescue-www/target-ro 2>/dev/null || true
ln -s /tmp/ncz-rescue.log /rescue-www/ncz-rescue.log 2>/dev/null || true

cat > /rescue-tools/status <<'EOF'
#!/bin/sh
set -x
uname -a
ip addr
ip route
mount
ls -la /target-ro
cat /tmp/ncz-rescue.log 2>/dev/null | tail -100
EOF
chmod +x /rescue-tools/status

cat > /rescue-tools/remount-target-rw <<'EOF'
#!/bin/sh
set -eu
mp=${1:?usage: remount-target-rw /target-ro/<partition>}
mount -o remount,rw "$mp"
echo "$mp is now rw"
EOF
chmod +x /rescue-tools/remount-target-rw

cat > /rescue-tools/fix-lib-symlink <<'EOF'
#!/bin/sh
set -eu
root=${1:-/target-ro/nvme0n1p2}
[ -d "$root" ] || { echo "root mount not found: $root"; exit 1; }
ls -ld "$root/lib" "$root/usr/lib"
if [ -L "$root/lib" ]; then
    echo "$root/lib already symlink -> $(readlink "$root/lib")"
    exit 0
fi
mount -o remount,rw "$root"
ts=$(date +%Y%m%d-%H%M%S)
mv "$root/lib" "$root/lib.broken.$ts"
ln -s usr/lib "$root/lib"
mkdir -p "$root/usr/lib/modules"
cp -a "$root/lib.broken.$ts/modules/." "$root/usr/lib/modules/" 2>/dev/null || true
sync
echo "fixed /lib symlink under $root; backup is lib.broken.$ts"
EOF
chmod +x /rescue-tools/fix-lib-symlink

cat > /rescue-tools/force-r80-lts-default <<'EOF'
#!/bin/sh
set -eu
esp=${1:-/target-ro/nvme0n1p1}
[ -d "$esp/loader" ] || { echo "ESP loader dir not found under $esp"; exit 1; }
mount -o remount,rw "$esp"
cp "$esp/loader/loader.conf" "$esp/loader/loader.conf.rescue-bak.$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
printf 'default cixmini-lts.conf\ntimeout 5\n' > "$esp/loader/loader.conf"
sync
echo "set $esp loader default to cixmini-lts.conf"
EOF
chmod +x /rescue-tools/force-r80-lts-default

# HTTP file transfer/browser. BusyBox httpd is present in R80 d-i initrd.
httpd -f -p 80 -h / >/tmp/httpd.log 2>&1 &

# Easy unauthenticated LAN shell. Prefer telnetd if available; otherwise use
# a FIFO-backed nc shell so command input works with BusyBox nc implementations
# that do not support -e. Respawns after disconnect.
if command -v telnetd >/dev/null 2>&1; then
    telnetd -l /bin/sh -p 23 2>/tmp/telnetd.log || true
else
    (
      while true; do
        rm -f /tmp/rescue-shell.in
        mkfifo /tmp/rescue-shell.in
        { echo "NCZ R80 rescue shell. Try: /rescue-tools/status"; /bin/sh -i < /tmp/rescue-shell.in 2>&1; } | nc -l -p 2323 > /tmp/rescue-shell.in
        rm -f /tmp/rescue-shell.in
        sleep 1
      done
    ) &
fi

echo "=== NCZ rescue ready ==="
/rescue-tools/status || true
'''
    (initrd / "rescue-start.sh").write_text(script)
    os.chmod(initrd / "rescue-start.sh", 0o755)
    (initrd / "rescue-tools").mkdir(exist_ok=True)
    (initrd / "rescue-tools" / "README").write_text("Helpers are generated by /rescue-start.sh at boot.\n")
    # Run once during d-i startup and also respawn from inittab so rescue
    # services survive d-i restarts and do not depend on main-menu.
    hookdir = initrd / "lib" / "debian-installer-startup.d"
    hookdir.mkdir(parents=True, exist_ok=True)
    hook = "#!/bin/sh\n/bin/sh /rescue-start.sh >/dev/console 2>&1 &\nexit 0\n"
    (hookdir / "S01ncz-rescue").write_text(hook)
    os.chmod(hookdir / "S01ncz-rescue", 0o755)
    inittab = initrd / "etc" / "inittab"
    if inittab.exists():
        txt = inittab.read_text()
        if "ncz-rescue" not in txt:
            txt += "\n# NCZ rescue services\n::respawn:/bin/sh /rescue-start.sh >/dev/console 2>&1\n"
            inittab.write_text(txt)


def write_grub(root: Path):
    # ISO extraction preserves read-only modes; make tree writable before edits.
    for path in root.rglob("*"):
        try:
            if path.is_file():
                path.chmod(0o644)
            elif path.is_dir():
                path.chmod(0o755)
        except PermissionError:
            pass
    grub = root / "boot" / "grub" / "grub.cfg"
    grub.parent.mkdir(parents=True, exist_ok=True)
    grub.write_text(r'''set timeout=8
set default=0
set menu_color_normal=light-green/black
set menu_color_highlight=black/light-green
insmod gzio
insmod part_gpt
insmod part_msdos
insmod fat
insmod iso9660
search --no-floppy --file /install.a64/vmlinuz --set=root

menuentry "NCZ R80 RESCUE — network shell + HTTP + read-only disk mounts" {
    echo "Booting NCZ R80 rescue kernel/initrd..."
    linux /install.a64/vmlinuz rescue/enable=true priority=low loglevel=4 console=tty0 console=ttyAMA2,115200 efi=noruntime acpi=force arm-smmu-v3.disable_bypass=0 audit_backlog_limit=8192 clk_ignore_unused keep_bootcon panic=30 module_blacklist=typec_rts5453,rts5453
    initrd /install.a64/initrd.gz
}

menuentry "NCZ R80 RESCUE — verbose/debug" {
    linux /install.a64/vmlinuz rescue/enable=true DEBCONF_DEBUG=5 loglevel=7 console=tty0 console=ttyAMA2,115200 efi=noruntime acpi=force arm-smmu-v3.disable_bypass=0 audit_backlog_limit=8192 clk_ignore_unused keep_bootcon panic=30 module_blacklist=typec_rts5453,rts5453
    initrd /install.a64/initrd.gz
}

menuentry "Reboot" { reboot }
menuentry "Power off" { halt }
''')
    # Also write the removable-media fallback config locations.
    (root / "EFI" / "boot").mkdir(parents=True, exist_ok=True)
    (root / "EFI" / "debian").mkdir(parents=True, exist_ok=True)
    shutil.copy2(grub, root / "EFI" / "debian" / "grub.cfg")
    shutil.copy2(grub, root / "boot" / "grub" / "arm64-efi" / "grub.cfg") if (root / "boot" / "grub" / "arm64-efi").exists() else None



def make_usb_img(tree: Path):
    """Create an Etcher-friendly raw USB image with an MBR + FAT32 partition."""
    if OUT_IMG.exists():
        OUT_IMG.unlink()
    dmg = WORK / "ncz-r80-rescue-fat.dmg"
    if dmg.exists():
        dmg.unlink()
    run([
        "hdiutil", "create", "-size", "256m", "-layout", "MBRSPUD",
        "-fs", "MS-DOS FAT32", "-volname", "NCZRESCUE",
        str(dmg),
    ])
    attach = subprocess.check_output(["hdiutil", "attach", "-readwrite", "-noverify", "-noautoopen", str(dmg)], text=True)
    print(attach)
    mountpoint = None
    disk = None
    for line in attach.splitlines():
        parts = line.split()
        if parts and parts[0].startswith("/dev/disk"):
            if disk is None:
                disk = parts[0].replace("s1", "")
            if len(parts) >= 3 and parts[-1].startswith("/Volumes/"):
                mountpoint = Path(parts[-1])
    if mountpoint is None:
        raise SystemExit("failed to find mounted FAT partition from hdiutil attach")
    try:
        run(["ditto", str(tree) + "/", str(mountpoint) + "/"])
        run(["sync"])
    finally:
        if disk:
            subprocess.run(["hdiutil", "detach", disk], check=False)
            subprocess.run(["hdiutil", "detach", disk, "-force"], check=False)
    # Convert whole disk image to raw. hdiutil UDRW is already raw-ish, but
    # imageinfo reports a disk image wrapper; convert UFBI gives the full device.
    raw_tmp = WORK / "ncz-r80-rescue-fat.raw"
    if raw_tmp.exists():
        raw_tmp.unlink()
    conv = subprocess.run(["hdiutil", "convert", str(dmg), "-format", "UFBI", "-o", str(raw_tmp)], check=False)
    if conv.returncode != 0:
        # hdiutil-created MBRSPUD image is already a raw disk image suitable for Etcher.
        shutil.copy2(dmg, OUT_IMG)
    else:
        produced = raw_tmp if raw_tmp.exists() else Path(str(raw_tmp) + ".dmg")
        produced.rename(OUT_IMG)
    run(["hdiutil", "imageinfo", str(OUT_IMG)])
    run(["shasum", "-a", "256", str(OUT_IMG)])


def make_iso(tree: Path):
    if OUT_ISO.exists():
        OUT_ISO.unlink()
    # hdiutil creates UDTO ISO from folder. UEFI removable path is present.
    tmp_cdr = OUT_ISO.with_suffix(".cdr")
    if tmp_cdr.exists():
        tmp_cdr.unlink()
    run(["hdiutil", "makehybrid", "-iso", "-joliet", "-default-volume-name", VOL, "-o", str(tmp_cdr), str(tree)])
    candidates = [tmp_cdr, Path(str(tmp_cdr) + ".iso"), OUT_ISO.with_suffix(".iso.cdr"), Path(str(OUT_ISO) + ".cdr")]
    for candidate in candidates:
        if candidate.exists():
            candidate.rename(OUT_ISO)
            break
    if not OUT_ISO.exists():
        raise SystemExit(f"hdiutil did not produce expected ISO; checked: {candidates}")
    subprocess.run(["hdiutil", "imageinfo", str(OUT_ISO)], check=False)
    run(["shasum", "-a", "256", str(OUT_ISO)])


def main():
    ensure_tools()
    if WORK.exists():
        shutil.rmtree(WORK)
    tree = WORK / "iso-tree"
    initrd_dir = WORK / "initrd"
    extract_iso_tree(tree)
    # Boot the same Sky1 LTS kernel that R80 installs, not the generic d-i kernel.
    shutil.copy2(tree / "cixmini" / "assets" / "kernel" / "lts" / "Image-cixmini.bin",
                 tree / "install.a64" / "vmlinuz")
    unpack_initrd(tree / "install.a64" / "initrd.gz", initrd_dir)
    # Inject matching Sky1 modules and firmware into the rescue initrd so display,
    # storage, network, and repair tools run against the LTS kernel ABI.
    run(["tar", "-C", str(initrd_dir), "-xzf", str(tree / "cixmini" / "assets" / "kernel" / "lts" / "modules-cixmini.tgz")])
    fw_src = tree / "cixmini" / "assets" / "sky1-firmware"
    fw_dst = initrd_dir / "lib" / "firmware"
    if fw_src.exists():
        shutil.copytree(fw_src, fw_dst, dirs_exist_ok=True)
    write_rescue_payload(initrd_dir)
    repack_initrd(initrd_dir, tree / "install.a64" / "initrd.gz")
    write_grub(tree)
    (tree / "README-RESCUE.txt").write_text("NCZ R80 rescue ISO. Connect: nc <ip> 2323 or HTTP http://<ip>/\n")
    make_usb_img(tree)
    make_iso(tree)


if __name__ == "__main__":
    main()
