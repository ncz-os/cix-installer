# amd64 7.3.0-rc6 kernel: the 9011 AER quirk (7.3.0-rc6-3-t2-edge-aer9011)

> File name kept for link stability. Until 2026-10-06 this report described the
> 9010 revert build `7.3.0-rc6-1-t2-edge-aerfix`; that history is preserved
> verbatim below ("History").

Operator decision 2026-10-05: the amd64 unified 7.3 kernel ships the **narrow
9011 quirk** as its default AER fix. The broad **9010 revert** is kept only as a
held fallback patch in amd64-kernel-t2 (`held/`), not built and not shipped.
The rescue entry boots this same kernel with the accelerator blacklist
(`assets/kernel/KERNEL-POLICY`).

## Artifact

- Staging directory (ARGONAS kernel-staging, new revision dir):
  `kernel-staging/amd64-t2-rc6-20261004/7.3.0-rc6-3-t2-edge-aer9011`
  (HYDRA/ACHILLES `/mnt/argonas/datapool/yocto-shared/...`, ULTRA
  `/mnt/argonas-yocto-shared/...`).
- KVER `7.3.0-rc6-3-t2-edge-aer9011`; Debian version `7.3.0-rc6-3`; vermagic
  `7.3.0-rc6-3-t2-edge-aer9011 SMP preempt mod_unload modversions`.
- Source: v7.3-rc6 `a90ee4305c4a5df72c11b31dacfdc76e00fcf78a` + amd64-kernel-t2
  `feat/t2-7.3-unified-20261006` at `23e85e5` (20 patches, 0 fuzz).
- sha256 (also `assets/kernel/amd64-stable-manifest.json` and `SHA256SUMS` in
  the staging dir):
  - image deb `6ac6b170cfe07265ab4439e9d3fc296fe0a0a09e2ccab6081a94316565836ed4`
  - headers deb `fd8760ea314683210a56873b98039202a10d6be8a1e54f246845b018b82156da`
  - kernel_config `df84b2f18841d1c965f1d13c148e6ed4db698cbd59b311b9a04569dd37ec99dc`
  - PROVENANCE `6234ebff3954d1df4d052ec6e9534f604cd4e9ce834a7461ea1746de456409ef`

## Why 9011 and not the revert

`eddba19b8b5f` ("PCI/AER: Support Advisory Non-Fatal Errors", new in v7.3-rc1)
unmasks Advisory Non-Fatal Errors (Correctable Error Mask bit 13) in
`pci_aer_init()`. On a MacBookPro16,1 that cuts power 14-27 s after boot with no
oops and no log line. The revert (9010) removed ANFE support for every PCIe
device on every machine. A diagnostic kernel then isolated the trigger to one
function, the Apple T2 Secure Enclave (PCI `106b:1802`): with only that
function's ANFE bit left masked the machine stayed up past 120 s, with it
unmasked power was cut at 14 s; the other three T2 functions and the Navi 14
switch port were fine unmasked. 9011 masks ANFE on exactly `106b:1802` and
keeps upstream behaviour everywhere else, so generic PCs keep ANFE reporting and
the change is a candidate for upstream. Upstream `aer.c` is unchanged since
`eddba19b8b5f` through rc6 (not fixed upstream).

The previous `aerfix` name was used for the 9010 build (rc6-1) and for a 9011
build (rc6-2), so it is retired; amd64-kernel-t2 `build.sh` and
`build/verify-kernel-default-policy.sh` here both refuse it.

## What else is in this build (beyond rc6-1)

- 9001 corrected (zero-initialized ownership mask, `device_hotplug_lock`,
  restore on the `PM_SUSPEND_PREPARE` rollback path); it owns CPU offline on T2.
- 9507 (HDA direct-complete) held, not applied.
- 1003 t2bce_ave ERR_PTR fix (no more `t2bce_ave_init()` oops without a T2) and
  5002 appletbdrm suspend/resume.
- Config: `MODVERSIONS=y`, `DPM_WATCHDOG=y` (off unless
  `pm.dpm_watchdog_enabled=1`), `EFI_VARS_PSTORE=y`, `DRM_PANIC_SCREEN="kmsg"`,
  `RTW89_8922DE=m`, `NTFS_FS_WOF_COMPRESSION=y`, `CGROUP_DMEM=y`. Module
  signing/lockdown and the early framebuffer (efifb) are unchanged.

## Verification (2026-10-06, ACHILLES)

- Static gate PASS: 20 patches (9011, 9001 yes; 9010, 9507 no); built config
  byte-identical to amd64-kernel-t2 `reference/shipping/config-7.3.0-rc6-3-t2-edge-aer9011`;
  headers `auto.conf` == image config; headers `Module.symvers` CRCs equal the
  built vmlinux `__crc_*` values for all 12027 exports (same-build pairing);
  `depmod -e` 0 unknown symbols (self-test fires); applesmc absent; all 4220
  modules Kbuild-compressed (xz CRC32); t2smc and t2gmux (three source revisions)
  build `rc=0`, `W=1`, 0 warnings, `modversions` vermagic.
- initramfs check PASS: installed with `dpkg -i`; the generated initrd holds only
  this KVER's modules, 839 of them byte-identical to the image deb's.
- KVM gate PASS twice (OVMF EFI): efivarfs 21/21 variables read, pstore backend
  `efi_pstore`, T2 in-tree stack loads, unsigned DKMS t2smc and t2gmux load
  (taint E/O/C, not refused), a t2smc copy with one corrupted symbol CRC is
  refused (`disagrees about version of symbol`), no oops; DPM watchdog `N` by
  default and `Y` with `pm.dpm_watchdog_enabled=1`.
- Not covered by any gate: T2 hardware. qemu has no `106b:1801/1802`, so the
  9011 and 9001 Apple paths never run there. MEDUSA confirmation is pending.

## History (2026-10-05): the 9010 revert build `7.3.0-rc6-1-t2-edge-aerfix`

Operator policy of 2026-10-05: stable 7.2.9 is the default and installer boot kernel on
both arches; amd64 (T2 Macs and generic PCs) additionally carries a bootable, non-default
7.3.0-rc6 edge entry. This records the edge build that fills the amd64 channel, how it was
verified, and the installer change that stages it. Supersedes the 2026-09-30 "amd64 ships
no edge" rule (no validated amd64 7.3 kernel existed then; one does now).

### Artifact

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

### The revert, and why it (not the quirk) is the edge kernel

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

### Verification performed (2026-10-05)

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

### Installer assets change

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

### amd64 edge command line: `pcie_ports=compat`

Operator directive 2026-10-05 (see the sibling note
`2026-10-05-amd64-edge-pcie-ports-compat.md`): the amd64 edge entry also
carries `pcie_ports=compat`, matching the T2 Linux community baseline, as defence in depth
alongside the revert. It is applied to the edge entry only, via
`NCZ_T2_EDGE_EXTRA_CMDLINE` in `assets/refind/ncz-refind-refresh-amd64.sh`; stable,
stable-console and rescue entries are untouched. Because the amd64 image ships one unified
x86 kernel for T2 Macs and generic PCs, the token is set only when
`ncz_is_t2_hardware` (in `assets/refind/ncz-t2-detect.sh`, sourced by the refresh script)
identifies an Apple T2 Mac from DMI on the target machine: a generic workstation or server
keeps its native AER/PME/hotplug port services. compat disables the native AER/PME/
hotplug port services without blocking the firmware `_OSC` grant (MEDUSA: 30+ min up,
`pcie_portdrv_init returned -13`). Whether compat alone avoids the power cut is untested,
so the revert stays.

### Open

- Operator-supervised hardware re-confirmation of the rc6 edge entry on the amd64 installer
  image (MEDUSA already ran the kernel directly).
- The 9011 quirk build remains a future candidate, not staged.
