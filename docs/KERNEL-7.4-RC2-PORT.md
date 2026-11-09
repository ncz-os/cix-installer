# KERNEL-7.4-RC2-PORT -- port context, ownership decisions, and status

K1 deliverable of the 2026-11-09 12-hour mission (kernel 7.4-rc2 on both arches).
Findings gathered from MNEMOS projects/kernelwatch (impact assessor + U1 audit +
K2 build record) on 2026-11-09. Base tag v7.4-rc2 = 7475ea8b58616b33c04afb976cf0fbaad9dd63fb.

## The 7.3.x lines: patch ownership decisions

Recorded here so the 7.4-rc2 ports carry the same decisions forward.

### T2 (amd64, Apple T2 Macs)

- **9001 owns CPU offline.** 9001 is a DUPLICATE of DKMS t2smp (same notifier
  prio 1/-1, same 106b:1801 gate). The staged 7.3 config sets
  CONFIG_CPUMASK_OFFSTACK=y, which makes the t2smp alloc_cpumask_var defect
  real, so the in-tree 9001 (K1-corrected form) is the owner and t2smp is not
  carried as a separate authority.
- **t2gmux owns APP000B.** CONFLICT: t2gmux and apple-gmux both match APP000B
  with no blacklist between them; patch 2009 makes display devices defer until
  a switcheroo handler registers. t2gmux is the owner; do not re-introduce a
  second APP000B claim.
- **9010 is an AER revert only (fallback).** 9010 is a broad AER revert held as
  fallback only; 9011 supersedes it on the 7.3 line (the 'aerfix' flavour that
  named both 9010/9011 is retired: build.sh and cix verify-kernel-default-policy
  refuse it). Gotcha carried forward: pcie_ports=compat does NOT stop ANFE
  unmask on Macs (negotiate_os_control takes AER control on x86_apple_machine
  before the compat check).
- Upstream/dropped on 7.3: 7002 (a5be7ad8f5f0, in v7.3-rc1); applesmc
  3001-3009 (t2linux 3001 fails 13/50 on 7.3 after the 94f5081d3592
  hwmon_with_info conversion); 7003 (Linux has NO imac5k_table - the table and
  missing sentinel exist only in the t2linux 7003 patch); 9003 not carried;
  9507 held.
- t2linux keeps moving t2bce ("Update t2bce for kernel v7.3", 14765f64e612 /
  aaec903cd721, 2026-10-21/22). The 7.3-era K2 audit once found our t2bce
  behind t2linux HEAD (1001 vs 6780d522fc19). The 7.4-rc2 series should be
  checked against current t2linux t2bce before final.

### CIX / Sky1 (arm64)

- **ALL accelerator drivers (Mali / VPU / NPU / Panthor) are DKMS, never
  in-tree.** They must be rebuilt against each kernel's headers (7.4-rc2 now).
  Platform enablement (PCI, clk, pinctrl, mailbox, reset, soc) is the in-tree
  patch series: mainline carries DT-only Sky1 drivers and the series rewrites
  them with ACPI support as incremental patches.
- The 205-patch series replayed on mainline: 178/205 applied on v7.3-rc5
  (same 27 fail on the base itself), 0 upstream at that time. CIX's own
  "patches for mainline" series (cix-linux-main) is the upstreaming lane:
  520a35aaafd8 (2026-10-20) renamed patches-7.1 -> patches-7.3 and dropped
  audss patches merged upstream; many of its subjects match our sky1-stable
  patches 0001-0016 and are supersede candidates when they land in a release.
- Prior-art note: srcshelton cix-sources 7.2.7/7.2.8 carries 0005-clk-cix
  (touches clk-sky1-audss.c, a drop-decision 0074 file) = prior art only.

## ONE-unified-kernel decision

One kernel for all arches. **Rescue = the same kernel + an accelerator
blacklist** (no separate rescue kernel). Names: the default stays 7.3.3
(7.3.3-t2-ncz+r297 amd64 / 7.3.3-sky1-ncz+r298 arm64); the 7.4-rc2 kernels are
**EDGE entries** only until their gates and (per-host, operator-authorized)
one-shot hardware boots pass.

## 7.4-rc2 port status (as of 2026-11-09)

### amd64 T2 -- K2, branch kernel-dev/amd64-7.4-rc2-r2 (linux-t2-ncz)

- Tip b5dfdaf (queue applied at 24882b9; SHIPPED-ARTIFACTS.sha256 updated
  after the build). Base v7.4-rc2 verified = 7475ea8b (the annotated tag
  object fd923000 is the tag, not a mismatch).
- Queue: 24/24 patches applied, zero rejects, zero obsolete.
- Build on HYDRA (k2-t2-742-20261109): linux-image f57b58f8, linux-headers
  4a8a1cf4, linux-image-dbg d9781768, linux-libc-dev a76b7fff (7.4.0-rc2-2),
  config f0f1fcd8, PROVENANCE present. olddefconfig from the 7.3.3 config.
- **KVM boot gate: PASS** (kernel-ci gates/kvm_gate.py, gate-kvm2): running
  release 7.4.0-rc2-t2-ncz, EFI runtime yes, modprobe_ok [efivarfs], zero bad
  markers, no panic/Oops/BUG/Call Trace.
  - Gate note: 7.4 renamed CONFIG_EFI_VARS_FS -> **CONFIG_EFIVAR_FS (=m)** and
    the gate initramfs carries only --load modules: run with `--load efivarfs`
    or the EFI check fails with mount-failed on a healthy kernel.
- T2 module result: full T2 stack builds **in-tree** in linux-image
  (drivers/staging/t2bce/{t2bce_core,t2bce_dma,t2bce_audio,t2bce_ave},
  apple-gmux, appletbdrm, hid-appletb-bl, hid-appletb-kbd, thunderbolt_net).
  Zero DKMS packages involved for the T2 line.

### arm64 Sky1 -- K3, branch kernel-dev/sky1-7.4-rc2-r1 (linux-cix)

- Tip 8b1b41ae (branch created for the mission; linux-cix.git on ARGONAS).
- Port report (ULTRA ~/Projects/k3-sky1-742-20261109/port-status.tsv):
  6 CLEAN / 27 CONFLICT / 0 OBSOLETE. The CONFLICT patches are
  series-interdependent and are being refreshed in series order via hive job
  01a1c1a8-a3cf-795d-bc57-ead04a0a5855 (build:linux-cix, eligible_hosts
  ultra), zoder review per refreshed patch.
- DKMS drivers (Mali/VPU/NPU/Panthor) must be rebuilt against the 7.4-rc2
  headers before the arm64 gate can pass its DKMS ABI step.

## Open items

1. post-install/56-t2-dkms.sh KVER filter `grep -v -- '-rc'` skips -rc kernels
   (known since the 7.3 U1 audit): no t2smc/fan control on rc kernels. Blocks
   a clean unified rc image; fix test-first.
2. release-kernel.sh regenerates the kernel manifest only at its last step but
   the overlay gate checks it earlier (a version bump stops at the overlay
   step) - file as a test-first fix.
3. Check our t2bce against current t2linux t2bce (14765f64e612) before the
   7.4-rc2 final.
4. K4 acceptance for every build: same SRCREV for image/headers/modules/
   initramfs/boot assets/provenance; ELF build IDs; overlay modversions; patch
   gates on real data; KVM boot validation (desktop + server media); static
   gates; rescue entry kept and a rescue boot tested.
5. Hardware (K5, operator-authorized one-shot boots only): stage ready-to-boot
   packages + exact boot procedure per host (O6N, MEDUSA, CHIMERA, PEGASUS,
   DELL). Never reboot from here; never read amdgpu debugfs on T2 hosts; mask
   suspend; take the lease.
