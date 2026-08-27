# Release history (archive)

Per-release detail for NCZ-OS ISOs up to and including 26.7 "Maximilian".
Retained for provenance. **Current release notes live in
[`docs/releases/`](releases/); the current position on kernels, hardware and
source is in the [README](../README.md), [DESIGN-RATIONALE](DESIGN-RATIONALE.md)
and [SOURCE-RELEASES](SOURCE-RELEASES.md).**

Entries below describe what was true of that specific release at the time and
are not maintained.

---

## Status

**26.7 "Maximilian"** — current release. **Singularity Desktop** (native
Wayland, no X11/XFCE) is the sole desktop, and the default GPU driver is the
CIX **`mali_kbase`** blob DDK (hardware GLES/EGL/OpenCL via `libmali` on the
primary 7.2 boot entry) rather than the open Mesa panvk/rusticl stack that
earlier releases (r113–r194, summarized below) shipped — Mesa panvk/rusticl
remains the GPU compute stack on the 7.0.12 secondary/fallback kernel only.
Apt hosting is **Buildkite Packages primary, Cloudflare R2 backup** (not R2
alone, as r194 below shipped). Tested and validated on **Radxa Orion O6N** and **Minisforum MS-R1** — see
**Hardware support & testing status** above. NCZ-OS ships **one build**; the
former Reinhardt/Magnetar variant split is gone, and console-only operation is
a boot entry (`systemd.unit=multi-user.target`) on the same image.

The remainder of this section is a **historical changelog** — each entry
below describes what was true of that specific release at the time; read
newer entries (higher in the list) as superseding older claims about
"current" GPU driver, apt host, or kernel-tiering state. For the current
kernel/GPU/desktop story, see the callout at the top of this README and
[`kernel-source/SOURCE.md`](../kernel-source/SOURCE.md).

What changed since the r147 baseline:

- **r193 — the apt kernel-upgrade promise actually works now.** r147/r192
  documented "`apt upgrade` pulls new kernels, no reinstall" — true of the
  *design*, but not of what actually happened on a running system: the
  installer staged the kernel by raw-copying files (`install -D` + `tar
  xzf`) straight into `/boot` and `/usr/lib/modules`, completely bypassing
  dpkg. `apt-cache policy linux-image-cixmini-lts` showed `Installed:
  (none)` even on a box actively running that exact kernel, so `apt
  upgrade` had nothing it thought needed upgrading — confirmed live on
  .66. Three-part fix, each verified against real apt transactions on real
  hardware:
  1. The kernel now installs via `apt-get install
     linux-image-cixmini-{lts,edge}` from the signed apt repository, so
     dpkg tracks it like any other package.
  2. The bootloader ESP-write logic (previously locked inside the
     install-time-only `70-bootloader.sh`) is now a shared script
     (`ncz-refind-refresh`) installed to `/usr/local/sbin/`, callable again
     after install — a plain `apt upgrade` needs a way to regenerate the
     rEFInd menu for the new kernel, not just install it.
  3. The `cixmini-boot` package (pulled in as a kernel dependency) has its
     own hook that fires on every kernel install/upgrade — but it wrote
     systemd-boot entries, dead code since this distro switched to rEFInd
     at r118. Redirected it to call the real refresh instead, with an apt
     hook that keeps the redirect in place across future `cixmini-boot`
     upgrades.
  A subsequent adversarial review caught a bug that would have made part 3
  never run at all (a hook-ordering gap in `run-all.sh`), plus two races
  in a combined multi-kernel/multi-package apt transaction — all fixed and
  re-verified before this release.
- **r194 — apt repository migrated to Cloudflare R2; NoMachine removed;
  quieter boot.** A community member on real hardware hit a hard install
  failure — `apt-get update` returned `403 Forbidden` fetching the kernel
  package repository (a required step). Root cause: the private Buildkite
  registry's auth file used a malformed hostname pattern, so the read token
  never actually attached to requests; making the registry public to work
  around that instead tripped a resource-limit wall on the plan tier,
  blocking downloads either way. Fixed by migrating kernel builds + CIX
  proprietary userspace to a public Cloudflare R2 bucket — no client-side
  auth, no plan-tier limits, verified end-to-end on a fresh install. Also
  this release: IPv6 nameserver fallbacks added to the installer's
  install-time DNS config (IPv4-only before); NoMachine removed entirely
  (its first-boot network install was unreliable, confirmed failing on a
  fresh install) with xrdp as the sole graphical remote-access path; and
  three services that failed or were misconfigured on every boot for no
  benefit on this hardware (`cix-audio-switch` — a vendor stub with a
  blank `ExecStart=`, `iscsid`, `apport`) are now masked at install time.
- **r192 — layered-squashfs bug sweep + dual-variant fix + apt-source hardening.**
  A day-long pass validating a fresh install end-to-end turned up and fixed
  several real bugs, none of which were cosmetic:
  - **ISO was ~3 GB bloated.** The squashfs layers were being staged twice —
    once correctly, once redundantly via a generic asset-copy step that had
    no exclusion for `assets/squashfs/`. Fixed; ISO went 7.98 GB → 5.0 GB.
  - **Server variant never actually shipped on the ISO.** `manifests/server.pkgs`
    didn't exist, so `server.squashfs` had never been built; the rEFInd menu
    offered a Magnetar boot option that silently degraded to a base-only
    install. Now built, staged, and boot-tested under KVM.
  - **`vivaldi-stable` stuck half-configured on every fresh install.** Root
    cause: a manifest inline comment corrupted the whole apt transaction,
    silently dropping `librsvg2-bin` and a handful of Vulkan/SPIR-V packages
    along with it — not a missing apt source (the Ubuntu archive was there
    the whole time). Fixed at the parser level so this class of bug can't
    recur; also fixed a stuck `needrestart` kernel-upgrade prompt that could
    hang a squashfs build indefinitely with no tty to answer it.
  - **Offline-mirror rebuilds now incremental**, not a full wipe-and-redownload
    of the ~1500-package closure every time.
  - **Kernel config gap**: the Sky1 NPU reports Zhouyi ISA version 5 (V3), but
    only `CONFIG_ARMCHINA_NPU_ARCH_V3_1` (version 6) was enabled — NPU was
    dark on a subset of installs. Both are now enabled.
  - Assorted smaller fixes: a desktop icon (Zoder) that launched a bare
    terminal instead of pointing at the project page; several install-time
    hooks (SSH, telnet console, NTP/hostname, failsafe recovery console,
    xrdp, the nspawn recovery container, the Magnetar headless
    toggle) that were present in the repo but never actually wired into the
    baked-image hook allowlist, so they silently never ran.
- **r147 — first apt-capable kernel-upgrade release.** `apt upgrade` /
  `ncz-update` pulls new kernels from Buildkite Packages — no reinstall to
  move kernels. QEMU-validated end-to-end.
- **r126 — open Mesa is the full default; desktop + Vulkan fixed.**
  `26-gpu-default-open.sh` now demotes *every* CIX GPU component out of the
  loader paths. Previously the CIX `cix-libglvnd` `libGLX.so.0` ran a "CIX
  driver check", failed (no `mali_kbase`; panthor owns the GPU), and called
  `abort()` — taking down Xorg and crash-looping lightdm (boots looked like
  "server" with no GUI). The CIX Vulkan ICD (`mali.json`) and WSI implicit
  layer aborted `vkCreateInstance` for every app the same way. Demoting
  cixgpu-compat (GL/GLX), `mali.json`, and the WSI layer — alongside the
  existing cixgpu-pro (OpenCL) demote — makes Mesa the default everywhere:
  desktop boots straight to the XFCE greeter, `panvk` Vulkan and `rusticl`
  OpenCL both work with no env overrides.
- **r125 — rusticl OpenCL works out of the box.** Bundled the missing
  `libclang-cpp` + `libLLVMSPIRVLib` runtime libs (`$ORIGIN` RPATH) and the
  `libclc` SPIR-V into the Mesa bundle, and demoted the CIX `libOpenCL.so.1`
  that was shadowing `ocl-icd`. `clinfo` → `Mali-G720 MC10 (Panfrost)`,
  OpenCL 3.0.
- **r124 — agents are opt-in; NPU gating hardened.** All agents (including
  `zeroclaw`) now install on demand via `ncz agent install` (desktop icon +
  first-login notice) instead of auto-activating, removing the first-boot
  crash-loop. NPU SSDT injection gating was tightened so it no longer misfires
  on unidentified boards.
- **r113 — first full release** with the Mesa 26.1.3 GPU compute stack
  (panvk + rusticl), validated NPU embeddings, and the A/B kernel program
  (6.18 LTS default + 7.0.x edge).

---

## Current ISO — 26.7 "Maximilian"

Three-tier kernel channel + desktop/GPU rebrand: **7.2 (`linux-cix-sky1-ncz`,
`KERNELRELEASE 7.2.0-rc5-sky1-ncz`) is the primary/default boot entry**,
**7.0.12-cix-sky1-next is the legacy/emergency fallback** (also what the
d-i installer environment itself boots — `INSTALLER_KERNEL_FLAVOR=legacy`
maps to this slot). It is an EOL kernel carried only until 7.2 completes its
release process. The NCZRESCUE partition boots that same legacy kernel with
the GPU/NPU/VPU stack blacklisted. See the
kernel-tiering callout at the top of this README and
[Positioning](../README.md) for why this is a
deliberate three-way split rather than a single "the kernel."

The desktop is **Singularity** (labwc/wlroots, native Wayland) — X11/XFCE is
fully removed, not an option. The default GPU driver is the out-of-tree CIX
**`mali_kbase`** blob DDK (hardware GLES/EGL/OpenCL via `libmali`); the
in-tree `panthor` + Mesa/PanVK Vulkan path is staged as a non-default
follow-up boot entry pending a GPU power-domain fix. See
[Driver support matrix](../README.md#driver-support-matrix--ms-r1--o6--o6n) and
[7.2 (Mali) GPU driver notes](../README.md#gpu-drivers-and-boot-options) above.

**Upgrade kernels & drivers with apt — no reinstall**
- Kernels + CIX userspace + Singularity Desktop (compiled/mirrored):
  **Buildkite Packages** `ncz-os/ncz` (primary, CloudFront-backed CDN) with
  **Cloudflare R2 as an independent second apt source** (not merely a
  mirror URL) — `apt upgrade` / `ncz-update` pulls new
  `linux-image-cixmini-{lts,edge}` and the mirrored CIX proprietary
  packages from whichever source resolves. See
  [OTA channel](../README.md#ota-channel-kernel--driver-updates--persistent-apt-sources)
  above for the dual-source rationale. No Codeberg apt source exists for
  this.
- Kernel source + Yocto recipes: GitLab
  [`ncz-os/meta-cix`](https://gitlab.com/ncz-os/meta-cix), plus the 7.2
  shipping kernel's pristine base + patch series is additionally mirrored
  in-repo/on GitLab Generic Packages for GPL corresponding-source purposes —
  see [`kernel-source/SOURCE.md`](../kernel-source/SOURCE.md) and
  [`kernel-source/linux-cix-sky1-ncz/CORRESPONDING-SOURCE.md`](../kernel-source/linux-cix-sky1-ncz/CORRESPONDING-SOURCE.md).

**Kernels:** 7.2.0-rc6-sky1-ncz (primary/default, `edge`) + 7.0.12-cix-sky1-next
(legacy fallback, "legacy" in the rEFInd menu — EOL, carried only until 7.2
releases). Two channels only. 7.1.x was experimental/non-working and never
shipped, and 6.18.26 was retired at r195 and never reinstated.

Provenance: **7.0.12** is *our* port — the raw v7.0.12 stable tag plus our
MS-R1-specific validation and fixes (SCMI, GPU, VPU, NPU, display, audio).
**7.2** goes further: mainline v7.2-rc5 (forward-ported from rc4, 2026-07-26)
plus our full ~130-patch (170 wired into the recipe; the in-repo
`patches-7.2/` directory also carries some superseded/experimental patches
not built) forward-port of the CIX Sky1 BSP, including fixes
that don't exist in any vendor drop yet, plus the `mali_kbase` DKMS/overlay
GPU driver port.

**Install:** unattended d-i (auto-partition, ESP + NCZRESCUE rescue
partition), boots rEFInd. Interactive disk + root-filesystem choice —
**btrfs** (default) or **ext4**; no ZFS root support yet. The d-i installer
environment itself runs on the 7.0.12 ("legacy" slot) kernel.

**Recovery:** NCZRESCUE partition with full repair toolset + automatic networking, reachable independent of the main rootfs; installer remote-diagnostics (network-console + telnet/http) on USB boot.

**O6N / MS-R1 driver support:** NVMe/PCIe, USB, Ethernet/Wi-Fi, Audio, NPU (Zhouyi V3 /dev/aipu), GPU (`mali_kbase`/`libmali` on the primary 7.2 channel — GLES/EGL/OpenCL, no Vulkan yet; `panthor`/Mesa panvk+rusticl on the 7.0.12 fallback channel), VPU — all working. See the driver support matrix above for per-subsystem, per-board detail.

**Reproduce:** kernels from kernel.org stable/mainline git + meta-cix patch series under Yocto ([docs/KERNEL-BUILD-YOCTO.md](KERNEL-BUILD-YOCTO.md), [kernel-source/SOURCE.md](../kernel-source/SOURCE.md)); ISO via build/build-iso-di.sh ([docs/NEXT_ISO.md](NEXT_ISO.md)).

## Previous ISO — r195 (NCZ-OS 26.6, historical)

> The section below is a point-in-time historical record of the 26.6 release
> and predates the Singularity Desktop / `mali_kbase` / apt-dual-source /
> three-tier-kernel work described above. Kept for changelog continuity —
> do not read it as describing the current ISO.

Kernel-channel refresh: **7.0.12-cix-sky1-next is now the stable channel**
and **7.2.0-rc1-ncz is the new edge channel**; the 6.18 LTS kernel is
retired from the ISO. The 7.2 edge kernel fixes a real VPU boot-hang
(pm_runtime IRQ-before-reset race — the same fix CIX shipped independently
in their v1.0.1 VPU driver), corrects the RTL8127 PCIe ASPM/ClockPM quirk
(the ACPI hardware-revision match was wrong, so the quirk could silently
never fire), removes the in-tree panthor driver from the build entirely
(the out-of-tree Mali DDK stack is the driver of record), and carries the
linlondp 26q2 -Werror fixes. Kernels are built under **Yocto Project 6.0
"Wrynose"** (openembedded-core + bitbake 2.18). base.squashfs shed ~2 GB
of dead weight (test/validation packages that the installer never installed
are no longer baked into the image). The rescue partition's self-configuring
networking (DHCP + static fallback) is verified as a release gate as of this
release. Also carries r194's changes (Cloudflare R2 apt channel, NoMachine
removal, quieter boot journal).

**Upgrade kernels & drivers with apt — no reinstall (as of r195)**
- Kernels + CIX userspace (compiled/mirrored): **Buildkite Packages** `ncz-os/ncz`, served over a CloudFront-backed CDN — `apt upgrade` / `ncz-update` pulls new `linux-image-cixmini-{lts,edge}` and the 31 mirrored CIX proprietary packages. No Codeberg apt source exists for this (see OTA channel section above; note apt hosting has since changed again, see "Current ISO" above).
- Kernel source + Yocto recipes: GitLab [`ncz-os/meta-cix`](https://gitlab.com/ncz-os/meta-cix).

**Kernels (r195):** 7.0.12-cix-sky1-next (default, stable) + 7.2.0-rc1-ncz (edge). (6.18 LTS retired from the ISO as of r195 and never reinstated — 26.7 ships two kernel channels only, legacy 7.0.12 and edge 7.2; 7.1.2 was experimental/non-working and never shipped.)

Provenance: **7.0.12 stable** is *our* port — the raw v7.0.12 stable tag
plus our MS-R1-specific validation and fixes (SCMI, GPU, VPU, NPU, display,
audio). **7.2.0-rc1-ncz edge** goes further: mainline v7.2-rc1 plus our full
~130-patch forward-port of the CIX Sky1 BSP (tracked as individual patch
files in meta-cix), including fixes that don't exist in any vendor drop yet.

**Install (r195):** unattended d-i (auto-partition, ESP + NCZRESCUE rescue partition), boots rEFInd. Interactive disk + root-filesystem choice — **btrfs** (default) or **ext4**; no ZFS root support yet. Installer runs on the 7.0.12 stable kernel.

**Recovery (r195):** NCZRESCUE partition with full repair toolset + automatic networking, reachable independent of the main rootfs; installer remote-diagnostics (network-console + telnet/http) on USB boot.

**MS-R1 (cixmini) driver support (r195) — 7.0.12 / 7.2:** NVMe/PCIe, USB, Ethernet/Wi-Fi, Audio, NPU (Zhouyi V3 /dev/aipu), GPU (Mali-G720 panthor renderD128, Mesa 26.1.3 panvk+rusticl; compositing off), VPU — all working.

**Reproduce (r195):** kernels from kernel.org stable git + meta-cix patch series under Yocto ([docs/KERNEL-BUILD-YOCTO.md](KERNEL-BUILD-YOCTO.md)); ISO via build/build-iso-di.sh ([docs/NEXT_ISO.md](NEXT_ISO.md)). No separate kernel-source repo needed — meta-cix carries every Sky1-specific patch as a tracked file.
