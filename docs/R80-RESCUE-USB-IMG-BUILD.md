# R80 rescue USB image for Balena Etcher

Use this artifact for Balena Etcher, not the bare ISO:

```text
/Users/jperlow/ncz-r80-rescue-cixmini.img
```

Why: this `.img` has a DOS/MBR partition table and a FAT32 partition, so Etcher should not warn about a missing partition table.

Build command:

```sh
OUT_IMG=/Users/jperlow/ncz-r80-rescue-cixmini.img \
OUT_ISO=/Users/jperlow/ncz-r80-rescue-cixmini.iso \
./tools/rescue/build-r80-rescue-iso.py
```

Current artifacts:

```text
/Users/jperlow/ncz-r80-rescue-cixmini.img
  size: 256 MiB
  file: DOS/MBR boot sector; partition 1 ID=0xb FAT32
  volume: NCZRESCUE
  sha256: b4dee81bd908f5c59d374a9fbc6a6497f59da967198e736b2c7e0712299c0251

/Users/jperlow/ncz-r80-rescue-cixmini.iso
  size: 86 MiB
  label: NCZ_R80_RESCUE
  sha256: e89ce6038dec6ee3245555742e3e2b4631b38f92c26c7f6de2392ef9791fe498
```

Verification performed on `.img`:

- `file` reports `DOS/MBR boot sector; partition 1 : ID=0xb`
- `hdiutil imageinfo` reports `partition-scheme: fdisk`, `partition-hint: MBR`, `DOS_FAT_32`, `FAT32: NCZRESCUE`
- Mounted FAT partition contains:
  - `EFI/boot/bootaa64.efi`
  - `EFI/boot/grubaa64.efi`
  - `EFI/debian/grub.cfg`
  - `boot/grub/grub.cfg`
  - `install.a64/vmlinuz`
  - `install.a64/initrd.gz`
  - `README-RESCUE.txt`

Rescue access after boot:

```sh
nc <cixmini-ip> 2323
curl http://<cixmini-ip>/
```

R80 initrd does not include busybox telnetd; rescue starts an unauthenticated BusyBox `nc` shell on port `2323` and HTTP on port `80`. If telnetd is present in a future initrd, the script also starts telnetd on port 23.
