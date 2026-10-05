# amd64 7.3.0-rc6 edge kernel: the AER ANFE revert (7.3.0-rc6-1-t2-edge-aerfix)

Operator policy of 2026-10-05: stable 7.2.9 is the default and installer boot kernel on
both arches; amd64 (T2 Macs and generic PCs) additionally carries a bootable, non-default
7.3.0-rc6 edge entry. This records the edge build that fills the amd64 channel, how it was
verified, and the installer change that stages it. Supersedes the 2026-09-30 "amd64 ships
no edge" rule (no validated amd64 7.3 kernel existed then; one does now).

## Artifact

- Staging directory:
  `/mnt/argonas-yocto-shared/kernel-staging/amd64-t2-rc6-20261004/7.3.0-rc6-1-t2-edge-aerfix`
- KVER: `7.3.0-rc6-1-t2-edge-aerfix`; Debian version `7.3.0-rc6-1`; arch `amd64`.
- Channel: edge (test-only, non-default). The amd64 default stays `7.2.9-2-t2-trixie`.
- Kernel package: `linux-image-7.3.0-rc6-1-t2-edge-aerfix`, plus
  `linux-headers-7.3.0-rc6-1-t2-edge-aerfix` (both built from the same tree; headers carry
  `include/config/kernel.release = 7.3.0-rc6-1-t2-edge-aerfix` and the image's modules carry
  vermagic `7.3.0-rc6-1-t2-edge-aerfix SMP preempt mod_unload`).
- `assets/kernel/amd64-edge/KVER` pins the channel; `assets/kernel/amd64-edge-manifest.json`
  mirrors the artifact paths, sha256 and source revisions.

## The revert, and why it (not the quirk) is the edge kernel

The T2 power-off is caused by upstream commit `eddba19b8b5f` "PCI/AER: Support Advisory
Non-Fatal Errors", which unmasked Advisory Non-Fatal Errors on device enumeration and routed
them through the Uncorrectable recovery path. On a MacBookPro16,1 the machine goes dark
14-27 s after boot with no oops and no log line. Two candidate fixes were built:

- `7.3.0-rc6-1-t2-edge-aerfix` — the **full revert** of `eddba19b8b5f`
  (`9010-Revert-PCI-AER-Support-Advisory-Non-Fatal-Errors.patch`, t2linux
  `linux-t2-patches` PR 70; amd64-kernel-t2 branch
  `feat/t2-9010-aer-anfe-revert-20261005`, commit `6d04bdc`).
- `7.3.0-rc6-2-t2-edge` — the **narrower 9011 quirk** that keeps the upstream ANFE code but
  leaves the ANFE bit masked only on the Apple Secure Enclave function (PCI `106b:1802`).

The operator decision is to ship the revert. It is the build proven on hardware: MEDUSA
(T2 MacBookPro16,1) ran the edge kernel with the full desktop and no power-off. The 9011
quirk build is kept only as a future candidate and is **not** shipped.

## Verification performed (2026-10-05)

`sha256sum -c SHA256SUMS` in the staging directory: all four entries OK (image deb, headers
deb, config, provenance). The image/headers/config sha256 are recorded in
`assets/kernel/amd64-edge-manifest.json`.

The build really is the revert and not the quirk. The configs of the revert, the plain rc6
build (`7.3.0-rc6-1-t2-edge-plain`) and the quirk are byte-identical, so any difference is
source-only. The `System.map` symbol sets separate them:

| build | System.map symbol delta vs plain rc6 |
|---|---|
| `7.3.0-rc6-1-t2-edge-aerfix` (revert) | loses `__pci_print_aer`, `__pci_print_aer.cold`, `__pfx___pci_print_aer`, `__pfx_aer_get_uncor_info`, `aer_get_uncor_info`; gains `pci_print_aer.cold` |
| `7.3.0-rc6-2-t2-edge` (quirk 9011) | none — identical symbol set to plain rc6 |

Removing the `__pci_print_aer` split and the `aer_get_uncor_info` call is exactly what the
full revert does; the quirk keeps the upstream code and only adds an inlined static helper,
so it leaves no symbol trace. The revert build's `System.map` has 198,965 symbols vs the
plain/quirk 198,969.

The build's own gates (recorded in the staging directory by the build) are also green:
`STATIC-GATE.txt` PASS (depmod `-e` 0 unknown symbols; t2bce/apple-gmux/amdgpu/i915/HID/
brcmfmac/thunderbolt modules present; `CONFIG_SENSORS_APPLESMC` unset; DKMS `t2smc`,
`t2gmux`, `t2smp`, `t2thunderbolt` build against these headers) and `KVM-GATE.txt` PASS
(qemu KVM boots the image to root; the only modprobe failure is the known `t2bce_ave` oops
on the emulated T2 host).

## Installer assets change

- `assets/kernel/amd64-edge/KVER` (`7.3.0-rc6-1-t2-edge-aerfix`) and
  `assets/kernel/amd64-edge-manifest.json` added. The amd64 `.deb`s themselves are
  gitignored (`assets/kernel/amd64-edge/*.deb`) exactly like `assets/kernel/amd64-stable/`.
- `build/verify-kernel-default-policy.sh` check 5 now accepts a pinned amd64 edge instead of
  banning one; checks 8 and 10 enforce the `7.3.0-rc6` pin (and the rEFInd pipeline pin
  marker). `build/test-kernel-default-policy.sh` proves pinned rc6 accepted, rc5/unpinned
  rc6/release edge refused.
- `assets/refind/zz1-ncz-refind-refresh-amd64` classifies only the pinned
  `7.3.0-rc6*-t2-edge-aerfix` as edge; `assets/refind/ncz-refind-refresh-amd64.sh` accepts a
  `KVER_EDGE` only when it matches the pin and ignores every other -rc.
- `post-install/10-amd64-kernel.sh` installs `amd64-stable` as the default and, when
  present, the pinned `amd64-edge` as a second (non-default) line; an unpinned `amd64-edge`
  KVER is refused and the hook exits non-zero.
- `build/stage-amd64-kernel.sh edge` copies the pool build matching the committed pin into
  `assets/kernel/amd64-edge/`; `build/publish-amd64-kernel.sh edge` publishes under
  `amd64-edge-*` and refuses a KVER that disagrees with the pin.
- `build/build-iso-di.sh`, `build/iso/write-usb-image.py` and
  `build/verify-base-kernel-assets.sh` stage/validate the amd64 edge `.deb` pair when
  present; `build/preflight-freshness-gate.sh` globs `amd64-edge-*` and selects the edge
  line by the committed pin, not by mtime.

The amd64 default boot entry and `default_selection` are unchanged, so 7.2.9 remains the
default on both arches; the edge entry is console-only and non-default, matching the arm64
Sky1 edge entry.

## Open

- Operator-supervised hardware re-confirmation of the rc6 edge entry on the amd64 installer
  image (MEDUSA already ran the kernel directly).
- The 9011 quirk build remains a future candidate, not staged.
