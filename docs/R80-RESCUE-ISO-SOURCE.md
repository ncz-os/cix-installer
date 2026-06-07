# R80 rescue ISO source checkpoint

Milestone committed before rescue ISO construction.

Known-good installer ISO on STUDIO:

- Path: `/Users/jperlow/ncz-installer-cixmini-26.6-r80.iso`
- Size: 924 MiB
- Label: `NCX_REINHARDT`
- Type: ISO 9660 CD-ROM filesystem data, DOS/MBR boot sector, bootable
- SHA256: `44b6517f3f559f74f944ddfc4855bb44a68a563063abdabdf566b9437014ddc3`

Goal: construct a correctly bootable CIX mini rescue ISO from R80 boot kernel/initrd, with easy telnet access, file-transfer tooling, local filesystem mount/repair tools, and bootloader/rootfs recovery scripts.
