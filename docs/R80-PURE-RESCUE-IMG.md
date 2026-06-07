# R80 pure rescue image

This is the recovery image to use now. It does **not** run Debian Installer as PID1.
It uses the R80 Sky1 LTS kernel and a pure `/init` that repairs the local disk.

Artifact:

```text
/Users/jperlow/ncz-r80-pure-rescue-cixmini.img
sha256: 3249c2f17a9f2ec544da9d0da25591ba004ad261eac5edd51206d80be11681d3
```

Properties:

- 768 MiB Etcher-safe raw image
- MBR partition table
- FAT32 partition `NCZRESCUE`
- UEFI boot files from R80
- boots R80 Sky1 LTS kernel (`6.18.26-cix-sky1-lts`)
- initrd contains R80 LTS modules and Sky1 firmware
- pure `/init`, no d-i main-menu/partman/debconf lifecycle

Pure rescue init behavior:

- mounts proc/sys/dev
- loads storage, network, btrfs/ext4/vfat, and Sky1 display modules
- DHCPs all NICs, static fallback `192.168.207.66/24`
- repairs local root before any read-only browsing mounts:
  - tries btrfs `subvol=@`, btrfs `subvol=/`, btrfs root, then ext4
  - detects installed root by os-release
  - if `/lib` is a real dir, moves to `lib.broken.<timestamp>` and creates `/lib -> usr/lib`
  - preserves `modules/` into `/usr/lib/modules`
- finds systemd-boot ESP and writes:
  - `default cixmini-lts.conf`
  - `timeout 5`
- starts HTTP on port 80 from `/www`
- starts BusyBox nc shell on port 2323
- if repairs were applied, reboots after 20 seconds unless `ncz_rescue_no_autoreboot` is passed

Verification completed:

- `hdiutil imageinfo` reports fdisk + DOS_FAT_32 + FAT32 `NCZRESCUE`
- FAT contains `install.a64/vmlinuz` and `install.a64/initrd.gz`
- initrd `/init` contains btrfs mount, `/lib` repair, HTTP, nc shell, and reboot logic
- initrd contains `btrfs.ko`
- initrd contains Sky1 display module `linlon-dp.ko`
