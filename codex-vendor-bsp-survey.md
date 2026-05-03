# Cix CP8180 / Sky1 vendor BSP survey

**Surveyed:** 2026-05-02 from jperlow-mlt. Method: `gh api` on github.com (orgs probed: `Sky1-Linux`, `cixtech`, `radxa`, `radxa-pkg`, `radxa-build`, `orangepi-xunlong`, plus the community `visorcraft` repo). All URLs below were verified live; nothing fabricated.

## Vendor repository map

| Vendor | Org | Repo | Branch / pushed | Notes |
|---|---|---|---|---|
| **Cix Tech (SoC vendor)** | `cixtech` | [`cix_opensource__linux`](https://github.com/cixtech/cix_opensource__linux) | `cix_p1_k6.6_master` (2026-02-11), `cix_k6.6.89_2025q4` | The same vendor tree the Minisforum repo is downstream of. Largest "official" surface. |
| | `cixtech` | [`cix_opensource__arm-trusted-firmware`](https://github.com/cixtech/cix_opensource__arm-trusted-firmware) | `cix_p1_k6.6_2025q3_tfa_open_dev` | Has `plat/cix/sky1/` and `plat/qemu/`, `plat/qemu_sbsa/`. Build script `build_sky1.sh` at root. |
| | `cixtech` | [`linux-mainline`](https://github.com/cixtech/linux-mainline) | `master` (2026-01-22) | Cix's upstream-mainlining work tracker. Has wiki at `/wiki`. |
| | `cixtech` | [`bios`](https://github.com/cixtech/bios) | `cix_p1_community_dev` | edk2 + edk2-platforms + tf-a aggregate; submodules. |
| **Radxa (Orion O6)** | `radxa-build` | [`radxa-orion-cix-p1`](https://github.com/radxa-build/radxa-orion-cix-p1) | `main` (2026-04-13) | New canonical Radxa image build. Replaces `radxa-build/orion-o6`. **Only contains GH workflow that calls `RadxaOS-SDK/rsdk`** — the actual source is in `RadxaOS-SDK/rsdk` (not `radxa/`). |
| | `radxa-pkg` | [`edk2-cix`](https://github.com/radxa-pkg/edk2-cix) | `main` (2026-04-28) | Active Radxa fork of Cix edk2 (UEFI). |
| | `radxa-pkg` | [`cix-drivers-dkms`](https://github.com/radxa-pkg/cix-drivers-dkms) | `main` | DKMS source for out-of-tree Cix drivers. |
| | `radxa-pkg` | [`cix-profiles`](https://github.com/radxa-pkg/cix-profiles) | `main` | Image-build profile metadata. |
| | `radxa` | [`cix-android-manifests`](https://github.com/radxa/cix-android-manifests) | `cix_radxa_o6_rc2` | Android repo manifests pointing at all the Cix-side BSP repos — useful as a manifest of "what's the canonical SHA combo." |
| **Sky1-Linux (community)** | `Sky1-Linux` | [`linux-sky1`](https://github.com/Sky1-Linux/linux-sky1) | `main` (2026-02-28) | **140-patch series** layered on mainline 6.18/6.19. Single best source for the bugs you're hitting. Maintainer: `Entrpi <entrpi@proton.me>`. |
| | `Sky1-Linux` | [`sky1-linux-build`](https://github.com/Sky1-Linux/sky1-linux-build) | `master` | `scripts/build-debs.sh` shows the LOCALVERSION pattern that gets the version string right. |
| | `Sky1-Linux` | [`sky1-image-build`](https://github.com/Sky1-Linux/sky1-image-build) | `main` | Disk-image / live-ISO build. Has `package-loadouts/{desktop,developer,minimal,server}`. |
| | `Sky1-Linux` | [`acpi-to-dts-tools`](https://github.com/Sky1-Linux/acpi-to-dts-tools) | `main` | DSDT→DTS converter, directly relevant to ACPI-vs-DT reserved-mem mismatches. |
| | `Sky1-Linux` | [`sky1-firmware`](https://github.com/Sky1-Linux/sky1-firmware) | `main` | GPU/DSP/VPU firmware blobs. |
| | `Sky1-Linux` | [`sky1-drivers-dkms`](https://github.com/Sky1-Linux/sky1-drivers-dkms) | `main` | DKMS overlay for 5GbE/VPU/NPU. |
| **Orange Pi (6 Plus)** | `orangepi-xunlong` | [`component_cix-next`](https://github.com/orangepi-xunlong/component_cix-next) | `main` (2026-04-17) | Active. Holds prebuilt `cix_binary/{gpu,isp,npu,vpu}` blobs + `cix_opensource/{gpu,isp,npu,vpu}` source bits + `debian/` packaging + `grub.efi`. **No kernel source here** — kernel comes from `linux-orangepi` separately. |
| | `orangepi-xunlong` | [`component_cix-current`](https://github.com/orangepi-xunlong/component_cix-current) | `main` (2025-12-22) | Older snapshot of the same shape. |
| | `orangepi-xunlong` | [`linux-orangepi`](https://github.com/orangepi-xunlong/linux-orangepi) | many `orange-pi-6.*` branches | Generic OPi kernel; need to identify the cix-specific branch — none is obviously labeled `sky1`/`cix` from a quick scan. |
| **MetaComputing (Framework 13 mainboard)** | — | **No public BSP repo found** | — | Product launched 2025-12 / 2026 ([linuxgizmos](https://linuxgizmos.com/metacomputing-launches-45-tops-arm-linux-ready-pc-powered-by-cix-cp8180/)). Open-issue exists in `geerlingguy/sbc-reviews#103`. No `MetaComputing` GitHub org publishes a BSP at this time. They appear to be relying on Cix-vendor + community trees. |
| **Community: Orange Pi 6 Plus GPU bring-up** | `visorcraft` | [`orange-pi-6-plus-gpu`](https://github.com/visorcraft/orange-pi-6-plus-gpu) | `master` (2026-02-13) | Mainline/Armbian Panthor GPU bring-up via SCMI ACPI/SMC. Cross-references for the ACPI vs DT split. |

## Per-topic findings

### (a) Kernel tree URL — fork or own tree?

| Vendor | Tree | Relationship |
|---|---|---|
| **Sky1-Linux** | [`linux-sky1`](https://github.com/Sky1-Linux/linux-sky1) | NOT a fork. Patch series applied on top of `cdn.kernel.org` mainline (6.18.x LTS, 6.19.x latest, RC, next). Four tracks. README documents apply procedure. |
| **cixtech** | [`cix_opensource__linux`](https://github.com/cixtech/cix_opensource__linux) (branch `cix_p1_k6.6_master`) | Same family as the Minisforum tree (`cix_opensource__linux` ancestor). 6.6-series LTS. |
| **Radxa** | None of their own. The `radxa-build/radxa-orion-cix-p1` repo's `.github/workflows/build.yaml` calls into `RadxaOS-SDK/rsdk` actions — Radxa consumes the Cix tree downstream and packages images. |
| **Orange Pi** | `component_cix-next` carries no kernel sources, just driver bundles + a `grub.efi`. The kernel ships as `.deb`s in `debs/`. |

**The single highest-leverage tree for our bug class is `Sky1-Linux/linux-sky1`** — patch-series style means we can cherry-pick individual fixes onto our existing 6.6 tree without a tree migration.

### (b) trilin_dpsub / trilin_dp_core / trilin_dptx / linlondp patches

Sky1-Linux has the most relevant DPTX/DPSUB fixes by a wide margin. Key patches in [`patches-latest/`](https://github.com/Sky1-Linux/linux-sky1/tree/main/patches-latest):

- **0022 — DRM bridge chain for PS185 DP-to-HDMI on Orange Pi 6 Plus** ([commit](https://github.com/Sky1-Linux/linux-sky1/blob/main/patches-latest/0022-drm-cix-Add-DRM-bridge-chain-for-PS185-DP-to-HDMI-on.patch)). Replaces the vendor `dp_to_hdmi = "yes"` DT hack with a proper bridge chain (`dp4 → simple-bridge (PS185) → hdmi-connector`). The `pdb-gpios`/`pinctrl-0` migration plus terminal-bridge connector-type lookup is the *exact* shape that fixes "link trains, monitor stays black on HDMI sink."
- **0027 — DPTX link rate selection** — fixes wrong-rate bandwidth picks.
- **0044 — DPTX suspend/resume deadlock** + locking improvements.
- **0049 — linlon-dp vblank event on flip timeout** — guards a starvation case.
- **0052 — Hotplug state machine on repeated resets** ([patch](https://github.com/Sky1-Linux/linux-sky1/blob/main/patches-latest/0052-drm-cix-dptx-Fix-hotplug-state-machine-on-repeated-r.patch)). Clears `DP_STATE_INIT_TRAIN` in `core_off`, adds settling delay after `reset_dp_and_reinit`, gates `enable` on both `INITIALIZED` and `READY`. **Prime suspect for our "scanout active, monitor black" symptom.**
- **0097 — skip compute_config on non-modeset atomic** — black-screen-on-replug class.
- **0117 — linlon-dp ACPI-boot + Panthor coexistence harden**.
- **0119 / 0120 — sky1-drm render node, faux→platform_device migration**.
- **0124 — AFBC and 10bpc diagnostic knobs** in linlon-dp (color-format quirks).
- **0126 — tear down DP core on HPD disconnect** — clean PHY state on replug.
- **0127 — reset `active_stream_cnt` on HPD disconnect** — CHANGELOG explicitly says: "*prevents stale stream count from causing DP TX misconfiguration (black screen) after USB-C replug*". Direct match.
- **0130 — recover link on HPD bounce with degraded DPCD status**.
- **0134 — retry AUX on cold-plug timeout**.
- **0136 — ELD reporting and audio infoframe for HDMI/DP channel mapping**.
- **0138 — properly disable audio hardware on shutdown**.

The `cixtech/cix_opensource__linux` tree is the upstream of these (since the patches are applied to mainline, not Cix), but the Sky1-Linux pre-rolled patches are easier to cherry-pick than tracing them out of Cix's monolithic vendor tree.

### (c) ARM-Trusted-Firmware for QEMU virt + Cix

[`cixtech/cix_opensource__arm-trusted-firmware`](https://github.com/cixtech/cix_opensource__arm-trusted-firmware) on branch `cix_p1_k6.6_2025q3_tfa_open_dev`:

- **Has `plat/cix/sky1/`** with `plat_sip.c` containing `reboot_reason_init` ([html_url](https://github.com/cixtech/cix_opensource__arm-trusted-firmware/blob/cix_p1_k6.6_2025q3_tfa_open_dev/plat/cix/sky1/plat_sip.c)) — which is the SiP that our kernel SMC call hits and panics on without EL3.
- **Has `plat/qemu/` and `plat/qemu_sbsa/`** in the same tree — TF-A upstream's QEMU virt port. So a `make PLAT=qemu` against this tree gives you a TF-A image suitable for `-bios`. There's also a working `build_sky1.sh` driver script at root for the Sky1 plat.
- **No prebuilt binary releases.** No `releases` and no tags found — must build. Cross-compile with `aarch64-none-elf-` (build script uses `gcc-arm-10.3-2021.07-x86_64-aarch64-none-elf`).

Recommendation: build `PLAT=qemu` from this tree (not from upstream TF-A) so QEMU sees the same SiP namespace the Cix kernel expects. That lets `__arm_smccc_smc` into `reboot_reason_init` resolve instead of panicking.

### (d) cix-dsp-rproc reserved-memory at 0xce000000 / 0xCDE08000

Sky1-Linux has the targeted fix:

- **patches-latest/0102 — `remoteproc: cix_dsp_rproc: add ACPI boot support`** ([patch](https://github.com/Sky1-Linux/linux-sky1/blob/main/patches-latest/0102-remoteproc-cix_dsp_rproc-add-ACPI-boot-support.patch)). Fixes:
  1. ACPI syscon lookup via `fwnode_find_reference()` + `dev_get_regmap()` instead of `syscon_regmap_lookup_by_phandle()`.
  2. `devm_clk_get_optional()` + `devm_reset_control_get_optional_exclusive()` for ACPI clock/reset bridge.
  3. **`memremap(MEMREMAP_WB)` for memory regions in system RAM (DSP firmware load area at 0xcde00000) since `ioremap_wc()` rejects linear-map addresses on arm64; detect via `pfn_is_map_memory()`.** — this is the exact 0xCDE08000 range that's failing in our dmesg.

Also relevant: `Sky1-Linux/acpi-to-dts-tools` is the toolkit for DSDT↔DTS conversion when you need to cross-check what the firmware's reserving vs. what the driver expects. Has a `acpi-to-dts.sh` driver script.

`cixtech/cix_opensource__linux` defines the canonical `Documentation/devicetree/bindings/remoteproc/cix_dsp_rproc.yaml` binding (ID `CIXH6000` matches the dmesg `[CIXH6000:00]`).

### (e) Plymouth / initramfs

**No vendor solves Plymouth on Cix in their public repos.** Specifically:

- Sky1-Linux `sky1-image-build/package-loadouts/` has `desktop/`, `developer/`, `minimal/`, `server/` — none mention plymouth in the tree's content listing.
- `radxa-pkg/cix-drivers-dkms` has `debian/` packaging but no plymouth pre/post hooks.
- `orangepi-xunlong/component_cix-next/debian/` has `boot/`, `dkms/`, `fb/`, `grub-post-silicon.cfg`, `iso_grub.cfg`, `iso_grub_acpi.cfg` — boot config and dkms only, no plymouth handling.
- A code-search for "plymouth" across the Sky1-Linux org returned no hits.

The Sky1-Linux image-build flow likely just doesn't ship a splash. The Cix-Debian-misc init-rename problem appears to be a Cix-vendor-package quirk that none of the downstream consumers tried to fix — they sidestep it by using their own image-build tooling rather than `update-initramfs` against the Cix-supplied init.

**Best-available answer for us:** strip `cix-debian-misc.postinst`'s init rename out, mirror Sky1-Linux's image-build approach (it's a clean Debian image-build, not the Cix vendor flow). Plymouth then "just works" as on any normal Debian arm64 image.

### (f) KERNEL_LOCALVERSION / suffix handling

**Solved by Sky1-Linux's [`sky1-linux-build/scripts/build-debs.sh`](https://github.com/Sky1-Linux/sky1-linux-build/blob/master/scripts/build-debs.sh)**:

```bash
# Remove any localversion files (we use LOCALVERSION env var instead)
rm -f localversion*

# Ensure consistent version string (no config-based suffix)
./scripts/config --set-str LOCALVERSION ""
./scripts/config --disable LOCALVERSION_AUTO

# Then export LOCALVERSION env var:
export LOCALVERSION="-${VARIANT}.r${REVISION}"
KERN_RELEASE=$(make -s ARCH=arm64 kernelrelease LOCALVERSION="${LOCALVERSION}")
```

Their kernel configs (`config/config.sky1*`) all carry `CONFIG_LOCALVERSION=""` and `# CONFIG_LOCALVERSION_AUTO is not set`. The complete recipe is: (1) blank `CONFIG_LOCALVERSION` in kconfig, (2) disable `CONFIG_LOCALVERSION_AUTO`, (3) `rm -f localversion*` files, (4) drive the suffix entirely through the `LOCALVERSION` env var on the make command line.

Yocto's `plain-kernel.bbclass` doubling our suffix is a kbuild-side issue: the defconfig is contributing one suffix and the bbclass injects another. Adopting Sky1's "blank in config + env-driven only" pattern eliminates the doubling cleanly.

## Ranked next-pull priority

1. **Cherry-pick from `Sky1-Linux/linux-sky1/patches-latest/`**: 0022, 0027, 0044, 0049, 0052, 0097, 0117, 0124, 0126, 0127, 0130, 0134 (DPTX/linlon-dp fixes — direct hits on the monitor-black bug). Apply as a curated subset on top of the Minisforum 6.6 tree, not a full rebase to 6.18/6.19.
2. **Cherry-pick `Sky1-Linux/linux-sky1/patches-latest/0102`** (cix_dsp_rproc ACPI / `memremap(MEMREMAP_WB)`) — fixes the 0xCDE08000 reserved-mem rejection.
3. **Build TF-A from `cixtech/cix_opensource__arm-trusted-firmware` branch `cix_p1_k6.6_2025q3_tfa_open_dev`, `PLAT=qemu`** — produces a `bl1.bin`/`bl31.bin` to use as `-bios` so QEMU validation no longer panics in `reboot_reason_init`.
4. **Adopt Sky1's `sky1-linux-build/scripts/build-debs.sh` LOCALVERSION recipe** — fix the doubled suffix without changing Yocto class.
5. **Use `Sky1-Linux/acpi-to-dts-tools/acpi-to-dts.sh`** as a diagnostic to dump the live DSDT and cross-reference firmware reservation vs. driver-expected `0xce000000` region (will tell us whether the fix is purely kernel-side per #2, or whether a UEFI/edk2 patch on top of `radxa-pkg/edk2-cix` is also needed).
6. **Sidestep `cix-debian-misc.postinst`** by mirroring Sky1-Linux's `sky1-image-build` chroot flow rather than running the Cix-vendor init-rename. Plymouth then works as on any Debian arm64 image. No vendor has a public Plymouth-on-Cix patch — this is the cleanest path.
7. **Keep `cixtech/cix_opensource__linux` (`cix_p1_k6.6_master`) as the long-tail reference** for anything Sky1-Linux didn't pre-roll. Do not switch to it as the working tree — it's larger and harder to cherry-pick from than the Sky1 patch series.
8. **Watch `radxa-pkg/edk2-cix`** (active 2026-04-28) for any UEFI/ACPI table fixes that affect (d) — Radxa is the most-active downstream packager and may push DSDT changes upstream.