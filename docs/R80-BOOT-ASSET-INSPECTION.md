# R80 boot asset inspection checkpoint

Source ISO: `/Users/jperlow/ncz-installer-cixmini-26.6-r80.iso`
SHA256: `44b6517f3f559f74f944ddfc4855bb44a68a563063abdabdf566b9437014ddc3`

Bootable ISO contents verified with `bsdtar -tf`:

- UEFI bootloader: `EFI/boot/bootaa64.efi` (990,600 bytes)
- GRUB config: `boot/grub/grub.cfg`
- Debian installer kernel: `install.a64/vmlinuz` (63,085,056 bytes)
- Debian installer initrd: `install.a64/initrd.gz` (130,431,688 bytes)

Installed-system kernel assets embedded in ISO:

- LTS kernel image: `cixmini/assets/kernel/lts/Image-cixmini.bin` (63,085,056 bytes)
- LTS modules: `cixmini/assets/kernel/lts/modules-cixmini.tgz` (108,455,845 bytes)
- LTS module tree starts with `lib/modules/6.18.26-cix-sky1-lts/`
- Edge kernel image: `cixmini/assets/kernel/next/Image-cixmini.bin` (64,444,928 bytes)
- Edge modules: `cixmini/assets/kernel/next/modules-cixmini.tgz` (112,803,094 bytes)

For rescue ISO, use the R80 installer bootloader/kernel/initrd path because it is known bootable. Add a rescue preseed/initrd hook that starts telnet + file transfer and mounts local disks read-only by default.
