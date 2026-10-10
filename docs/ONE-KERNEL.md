# One-kernel policy (operator ruling 2026-10-10: "ship only OUR kernel")

Every NCZ-OS image must contain **exactly one kernel**: the NCZ kernel (amd64:
`linux-image-7.3.0-rc6-4-t2-edge-aer9010`; arm64: `linux-image-cixmini`
`7.3.0-rc6-sky1-ncz+r285`). There must be no Debian `linux-image-*`,
`linux-headers-*`, `linux-modules-*`, `*-modules-<kver>-*-di` kernel-module d-i
udeb, or second kernel/initrd anywhere — installed rootfs (squashfs layers),
`/cdrom` pool + offline mirror, ESP/boot files, d-i boot assets, installer
initrd, or refind entries.

The one-kernel rule is enforced by `audit_kernel_purity()` in
`build/forky-provenance.py`, run on every `--image` scan (and unit-tested both
directions in `build/test-no-ubuntu.sh` §2e). It FAILS if any kernel-artifact
package it saw is not a reviewed NCZ kernel, and if more than one kernel version
string is present. It should also be run in the KVM/ship gate; add
`build/check-forky-provenance.sh --image <img>` to the KVM gate and
`build/ship-image.sh` already runs the full provenance gate.

## Audit of the r202 images (where every kernel artifact lives)

`build/forky-provenance.py --image` was run against both r202 images
(`ncz-os-amd64-20261010-7d541884.img`, `ncz-os-arm64-20261010-e4886bb5.img`) and
every kernel-artifact package recorded, by place:

| place | amd64 | arm64 |
|---|---|---|
| NCZ kernel debs in the payload (`assets/kernel/*`) | `linux-image/headers-7.3.0-rc6-4-t2-edge-aer9010` | `linux-image/headers-cixmini`, `cixmini-boot` |
| installed rootfs (`base.squashfs`, `desktop.squashfs` dpkg status) | only the NCZ kernel+headers | only the NCZ kernel+headers+`cixmini-boot` |
| offline `/cdrom` pool (closure) | **Debian** `linux-image-7.1.13+deb14-amd64`, `linux-image-amd64`, `linux-modules-7.1.13+deb14-amd64`, `linux-binary-7.1.13+deb14-amd64`, `linux-base-amd64` | **Debian** `linux-image-7.1.13+deb14-arm64`, `linux-image-arm64`, `linux-modules-7.1.13+deb14-arm64`, `linux-binary-7.1.13+deb14-arm64`, `linux-base-arm64` |
| `/cdrom` d-i `Packages` index + pool (merged substrate) | **64 Debian d-i kernel-module udebs** (`{base,btrfs,crypto,ext4,nic,scsi,...}-modules-7.1.8+deb14.1-amd64-di` and `…-7.2.6+deb14-amd64-di`) + `linux-base/linux-binary-*-di` | **79 Debian d-i kernel-module udebs** (same set, `-7.1.8+deb14.1-arm64-di` / `-7.2.6+deb14-arm64-di`) |
| ESP boot (`/linux`, `/initrd.gz`) | **Debian d-i kernel + initrd** (netinst) | **Debian d-i kernel + initrd** (netinst) |
| installer initrd (d-pkg status) | Debian d-i udeb set | Debian d-i udeb set |
| arm64 `/cdrom/pool` | — | NCZ `linux-image/headers-cixmini` (published) |

**The installed system already ships only our kernel.** The "second kernel" is
entirely the **installer's** Debian d-i kernel + its module udebs, merged from
the netinst substrate, plus five Debian kernel debs that the offline closure
pulled in.

## The mechanism (decided; KVM gate UNPROVEN in this session)

The installer boots the netinst's **Debian d-i kernel + initrd** (ESP `/linux` +
`/initrd.gz`, built by `build/iso/build-refind-esp.py` from the imported
substrate), and loads Debian's `*-modules-<kver>-*-di` udebs at install time.
To satisfy the one-kernel policy the correct mechanism is:

1. **Do not merge the substrate's Debian kernel/module udebs** into the image's
   `/cdrom/pool` (`write-usb-image.py`'s `copytree(installer_pool, …)`), and
   stop seeding Debian kernel debs into the offline closure
   (`manifests/installer-base*.pkgs`); and
2. **build the installer initrd from OUR kernel + our module set** so d-i runs
   our kernel (the ESP `/linux` and the initrd), keeping the Debian d-i
   *userland* udebs (partman/apt-setup/etc.) which are arch-independent.

Step 1 alone removes the kernel-module residual from provenance but would leave
the installer without its running kernel modules — so it must ship with step 2
(the initrd). Because the change touches the installer's boot path, it is
**UNPROVEN until the KVM install gate (`build/kvm-install-gate-gpt.sh`) reaches
"finish the installation" on a rebuilt image**. No image was rebuilt in this
session.

Implementation surface for step 1 (staged, gated, ready to enable after the
gate): `build/iso/write-usb-image.py:filter_substrate_kernel_artifacts()` removes
Debian kernel/module/binary udebs from the copied substrate pool when
`NCZ_ONE_KERNEL=1` (`make image` passes it), and the offline closure seed drops
Debian kernel packages. Left **default-off** so the current (unverified) build
path is unchanged.

## Residual after the one-kernel fix

With the Debian kernel-module udebs no longer in the image, the substrate
provenance residual drops by the kernel counts (64 amd64 / 79 arm64 above); the
remaining non-kernel d-i/base udebs (`apt-setup-udeb`, `dbus-udeb`,
`fdisk-udeb`, `grub-mount-udeb`, `exim4-*`, …) still cannot be authorized by a
single `testing` snapshot (`manifests/base.pin` records 91.8 % / 90.7 %) — see
`docs/FORKY-PROVENANCE.md` §"Substrate vs snapshot". That is a genuine,
documented gap that a newer netinst must close; it is **not** addressed by
adding a fourth origin.
