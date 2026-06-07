# R80 rescue ISO build result

Built on STUDIO from committed builder:

```sh
OUT_ISO=/Users/jperlow/ncz-r80-rescue-cixmini.iso ./tools/rescue/build-r80-rescue-iso.py
```

Output:

- Path: `/Users/jperlow/ncz-r80-rescue-cixmini.iso`
- Size: 86 MiB
- Label: `NCZ_R80_RESCUE`
- SHA256: `067448b715070ef9537c060b377f7d28b0cc89b9f9734ceda715959790ba1d21`

Structural verification performed:

```sh
bsdtar -tf /Users/jperlow/ncz-r80-rescue-cixmini.iso
# confirmed:
# EFI/boot/bootaa64.efi
# EFI/boot/grubaa64.efi
# EFI/debian/grub.cfg
# boot/grub/grub.cfg
# install.a64/vmlinuz
# install.a64/initrd.gz
```

Initrd verification:

- `/rescue-start.sh` present and executable
- `/lib/debian-installer-startup.d/S01ncz-rescue` present and executable
- `/rescue-tools/README` present
- rescue script starts HTTP server on port 80
- rescue script starts easy unauthenticated LAN shell on port 2323 via BusyBox `nc`
- if a future initrd has `telnetd`, rescue script starts telnetd on port 23 too

Connect after boot:

```sh
nc <cixmini-ip> 2323
curl http://<cixmini-ip>/
```

Note: R80 installer initrd BusyBox does not include `telnetd`; this ISO uses `nc -l -p 2323` for the same easy shell recovery path. The script attempts telnetd only if present.
