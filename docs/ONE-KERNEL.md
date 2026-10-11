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

## The mechanism (IMPLEMENTED and KVM-PROVEN in r203)

The installer boots OUR kernel. There are two halves, both live since r203:

1. **Step 1 — do not merge the substrate's Debian kernel/module udebs.**
   `build/iso/write-usb-image.py:filter_substrate_kernel_artifacts()` removes the
   Debian kernel/module/binary udebs from the copied substrate pool; `NCZ_ONE_KERNEL=1`
   (the `make image` default) enables it, and the offline closure seed drops
   Debian kernel debs.
2. **Step 2 — build the installer initrd from OUR kernel + our module set.**
   `build/iso/patch-initrd-t2-kernel.py` swaps the ESP `/linux` for our vmlinuz
   and appends our `lib/modules/<our-kver>` overlay onto the d-i initrd. Since
   r203 it ALSO prunes the substrate's own kernel from the base initrd:
   `filter_base_cpio()` drops, byte-verbatim, every `[usr/]lib/modules/<kver>`
   whose kver is not ours (591 members on the amd64 netinst) and the base
   `var/lib/dpkg/status`; `prune_initrd_status()` removes the Debian
   `*-modules-*-di` / `linux-base-*-di` / `linux-binary-*-di` records and the
   Architecture-less `debian-installer` marker, and bakes the pruned status into
   the overlay (the later archive wins); `verify_one_kernel_initrd()` fails the
   build closed if any Debian kernel path or record survives. The Debian d-i
   *userland* udebs (partman/apt-setup/anna/…) stay.

**Evidence (amd64, `b48ba99d`).** The r203 amd64 gate reported 25+25 initrd
kernel items before this work and **0 after** (`provenance-gate`: 8602 packages,
0 failures), and the KVM install gate **PASSed phase 1 + phase 2 + UI check** —
the installer booted OUR kernel, reached the finish stage with no ship-critical
hook failure, and the installed system booted.
`build/iso/tests/test_patch_initrd.py` unit-tests the prune both directions
(wired into `make parity`).

## Residual after the one-kernel fix

With the Debian kernel modules gone from the image, the kernel residual is
**zero**. The remaining installer d-i/base packages are authorized by the pinned
snapshot (forky) plus the reviewed per-package `manifests/sid-exceptions.tsv`
ledger — see `docs/FORKY-PROVENANCE.md` §"sid exceptions". No fourth origin is
added.
