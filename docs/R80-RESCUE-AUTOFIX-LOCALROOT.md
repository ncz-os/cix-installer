# R80 rescue auto-fix local root build

Built a rescue image that automatically repairs the known local root breakage on boot.

Primary artifact for Etcher:

```text
/Users/jperlow/ncz-r80-rescue-cixmini.img
sha256: a3d3063de7e7118fb0a718f305a4f6d51a26eea2bdf2665e4f994ddf59108f41
```

Secondary ISO:

```text
/Users/jperlow/ncz-r80-rescue-cixmini.iso
sha256: 4ab352dc171d19f163b5988318ddd3f7cc2a420d30912598fe4e6d662e100d40
```

Behavior:

- boots R80 Sky1 LTS kernel (`6.18.26-cix-sky1-lts`) with R80 LTS module tree in initrd
- loads btrfs/ext4/vfat/storage/network modules
- scans local partitions
- mounts candidate root filesystems rw (tries plain, `subvol=@`, and `subvol=/`)
- if root contains `/usr/lib` and `/etc/os-release` (or `/usr/lib/os-release`) and `/lib` is a real directory, it:
  - moves `/lib` to `/lib.broken.<timestamp>`
  - creates `/lib -> usr/lib`
  - copies any preserved `modules/` into `/usr/lib/modules/`
- scans FAT partitions for systemd-boot ESP and forces:
  - `default cixmini-lts.conf`
  - `timeout 5`
- still starts HTTP on port 80 and FIFO-backed BusyBox nc shell on 2323 if service stays up

Verification:

- initrd contains `btrfs.ko`
- `rescue-start.sh` contains AUTO-FIX logic, btrfs loading, httpd ownership, FIFO nc shell, and keepalive loop.

Disable auto-fix with kernel arg:

```text
ncz_rescue_no_autofix
```
