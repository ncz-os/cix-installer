# Kernel build policy — Yocto is the single authoritative build system

> **All NCZ-OS / CIX Sky1 kernels are built ONLY from the Yocto tree (`meta-cix`).**
> No hand-rolled `git apply`, no `/tmp` one-off compiles, no loose module tarballs.
> This is what we ship and what we tell downstream consumers (Radxa O6, GitHub #32):
> *"Use Yocto — Yocto is our build system,"* and we can prove it builds from clean.

## Authoritative source

- **Tree:** `~/yocto-docker` on **ARGOS** (the designated Yocto host; heavy compiles never run on STUDIO).
  - Layers: `meta-cix`, `meta-nclawzero`, `meta-openembedded`, `poky`.
- **Kernel recipe:** `meta-cix/recipes-kernel/linux-cix-sky1-next/linux-cix-sky1-next_7.1.bb`
  - `LINUX_VERSION = 7.1.0`, `PV = 7.1.0+sky1-next`, `KBRANCH = master`,
    `SRCREV_kernel = 8cd9520d35a6c38db6567e97dd93b1f11f185dc6` (torvalds/linux v7.1 mainline).
  - Patch series `files/next-patches-v7.1/0001..0010` in `SRC_URI`:
    `0001` squashed CIX Sky1 drivers; `0002-0004` clk/mailbox; `0005-0009` DRM color
    formats; **`0010-soc-cix-acpi-resource-lookup-resolve-dev_id-by-acpi`** (USB
    reset-lookup `dev_id`-NULL fix — required for USB to enumerate).
- **Build container:** `crops/poky:ubuntu-22.04` (BitBake 2.8.1), `~/yocto-docker` bind-mounted at `/workdir`.

## How to build (the only sanctioned path)

```bash
# on ARGOS
docker run --rm -v /home/jasonperlow/yocto-docker:/workdir \
  crops/poky:ubuntu-22.04 --workdir=/workdir -- bash -lc '
    source poky/oe-init-build-env build-cix
    bitbake -c cleansstate linux-cix-sky1-next   # force from-clean patch+compile
    bitbake linux-cix-sky1-next
  '
```

A plain `bitbake linux-cix-sky1-next` is enough for incremental changes: editing
`SRC_URI`/patches changes the `do_patch` signature, so BitBake re-runs
patch+compile+deploy automatically. Use `cleansstate` when you need an
authoritative from-clean build (release artifacts).

## Deploy output (the only artifacts we trust)

```
~/yocto-docker/build-cix/tmp/deploy/images/cixmini/kernel-linux-cix-sky1-next/
    Image--7.1.0+sky1-next...-cixmini-<ts>.bin      # kernel
    modules--7.1.0+sky1-next...-cixmini-<ts>.tgz    # /usr/lib/modules tree
    sky1-orion-o6--...-cixmini-<ts>.dtb             # device tree
```

## Handoff to the installer

`cix-installer` consumes the Yocto deploy output — it does **not** build kernels.
Stage the deploy artifacts into `cix-installer/assets/kernel/{stable,next}/` as
`Image-cixmini.bin` + `modules-cixmini.tgz` (+ `KVER` marker), then bake the ISO.

## Deploying to a target safely (lesson from 2026-06-26)

Never `tar -C /` a modules tarball: on a usrmerge rootfs that clobbers the
`/lib -> usr/lib` symlink and orphans `ld-linux` → the box wedges every boot.
Extract modules with `--keep-directory-symlink` into `/usr`, then `depmod` +
`update-initramfs`. Keep a known-good kernel as the bootloader default.

## RETIRED — do not use (consolidated into Yocto)

- `~/cix-7.1-ncz-work/` + `build-7013.sh` — manual git tree with `git apply
  --reject` and `SUBLEVEL=` editing. **Replaced by the recipe patch series.**
- `~/modules-7.1.0*.tar.gz`, `~/ARCHIVE-*/...artifacts-7.1-rc7-*` — hand-built
  artifacts. **Replaced by the Yocto deploy dir.**
- Any `/tmp` one-off Docker kernel compiles. **Use the recipe above.**

These are archived for history only; new work goes through the recipe.
