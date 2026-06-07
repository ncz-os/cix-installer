# R80 rescue display-capable rebuild

The first rescue image booted to black screen because it used the generic R80 Debian-installer kernel (`6.1.0-42-arm64`) and initrd module set, not the R80 Sky1 LTS kernel/display stack.

Fix committed in `tools/rescue/build-r80-rescue-iso.py`:

- Replace `install.a64/vmlinuz` in the rescue media with R80 embedded LTS kernel:
  - `cixmini/assets/kernel/lts/Image-cixmini.bin`
  - kernel ABI: `6.18.26-cix-sky1-lts`
- Extract R80 LTS modules into rescue initrd:
  - `cixmini/assets/kernel/lts/modules-cixmini.tgz`
- Copy R80 Sky1 firmware into rescue initrd:
  - `cixmini/assets/sky1-firmware`
- Load Sky1 display module stack during rescue startup:
  - `cix_mbox`
  - `scmi_mailbox_transport`
  - `clk-sky1-acpi`
  - `reset_sky1`, `reset_sky1_audss`
  - `cix-acpi-resource-lookup`
  - `cix-usbdp-phy`, `cix-edp-panel`, `pwm_bl`
  - DRM helpers
  - `cix_virtual`, `trilin-dpsub`, `linlon-dp`
- Keep Etcher-safe raw USB image output at 768 MiB.

Rebuilt artifacts:

```text
/Users/jperlow/ncz-r80-rescue-cixmini.img
  size: 768 MiB
  type: MBR + FAT32 NCZRESCUE
  sha256: d32f6d9ccec17de1da52639795643793aa5cfdf6470ffeb6c1221c45463ccf66

/Users/jperlow/ncz-r80-rescue-cixmini.iso
  sha256: b2a0531656baf615deee2263637e4b21bedf0073699ebfbe13da610d4f7f4bf4
```

Verification performed:

- `.img` reports `partition-scheme: fdisk`, `DOS_FAT_32`, `FAT32: NCZRESCUE`
- rescue kernel in image is 60 MiB R80 Sky1 LTS kernel
- rescue initrd is 128 MiB and contains:
  - `lib/modules/6.18.26-cix-sky1-lts/kernel/drivers/gpu/drm/cix/linlon-dp/linlon-dp.ko`
  - `lib/modules/6.18.26-cix-sky1-lts/kernel/drivers/gpu/drm/cix/dptx/trilin-dpsub.ko`
  - `lib/modules/6.18.26-cix-sky1-lts/kernel/drivers/gpu/drm/cix/cix_virtual.ko`
- rescue startup contains `linlon-dp` load and FIFO-backed interactive `nc` shell fix.

Use `.img` with Balena Etcher.
