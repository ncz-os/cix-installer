# SPDX-FileCopyrightText: Copyright (c) 2026 Jason Perlow
# SPDX-License-Identifier: Apache-2.0
#
# Linux kernel for Cix Sky1 / CP8180 -- NCZ 7.2 track.
#
# Base: torvalds mainline v7.2 release tag
#       (KBRANCH=master + SRCREV pinned to the v7.2 tag COMMIT).
#       (Bumped 2026-08-22 from v7.2-rc7 -> v7.2 release. The rc7 pin
#       shipped as KERNELRELEASE 7.2.0-rc7-sky1-ncz; this recipe must stay
#       pinned to the intended release tag so metadata and artifact agree.)
#       (Rebased 2026-08-02 from v7.2-rc5 -> v7.2-rc6: all 170 CIX commits
#       replayed with ZERO conflicts and range-diff 170/170 "=".)
#       (Forward-ported 2026-07-26 from v7.2-rc4 -> v7.2-rc5: the rc4->rc5
#       diff touched 595 files and none of them overlap this patch series'
#       footprint, so 169 of 170 patches applied byte-identical; the one
#       exception, 0184, had a pre-existing malformed hunk in
#       drivers/thermal/cpufreq_cooling.c -- unrelated to the rc5 rebase,
#       fixed in place. See CORRESPONDING-SOURCE.md for the rc5 pristine
#       base self-mirror.)
# Patches: patches-7.2 = cixtech 2026q2 vendor driver set
#   (github.com/cixtech/cix_opensource__linux @ cix_k6.6.89_2026q2)
#   forward-ported from k6.6.89 onto v7.2-rc4, PLUS the NCZ core ACPI
#   glue patches (from patches-7.1) that still apply.
#   Upstream v7.2-rc4 (and rc5, unchanged in this area) already carries: sky1-orion-o6 DTS, cix-mailbox,
#   pci-sky1 (Cadence HPA, OF), pinctrl-sky1, reset-sky1, HDA cix-ipbloq
#   -- those are used as-is with NCZ ACPI deltas on top.
#   USB host role initialization is completed by patch 0112, which connects
#   the imported USBSSP platform driver to the v7.2 unified cdns3 role core.
# Config: config-7.2.defconfig = 7.1 NCZ config + olddefconfig on v7.2-rc4
#   + CIX 2026q2 symbols + CONFIG_BTRFS_FS=y (built-in; btrfs root without
#   initrd module).
# NPU (Zhouyi V3/V3_1, CIX Sky1 CRE0-2): ADDED via patches 0119-0125.
#   The Entrpi v7.1 sky1-next armchina-npu driver (46 files, ~12K lines)
#   was carried over from the 7.1 squashed tree and forward-ported onto
#   v7.2-rc4: pm_runtime_put() now void (7.0.x), platform_driver::remove
#   now void (7.1), NULL pd_core[] guards (BIOS v1.0 CRE0-2 missing _HID),
#   ACPI _STA quirks for CIXH4000/NPU0 children, force-D0 on missing
#   pd_core, and the tightening of the hidden Sky1 SCMI/NPU child device
#   match (parent HID + child ACPI name + uid). CONFIG_ARMCHINA_NPU=m,
#   ARCH_V3=y (Sky1 reports ZHOUYI V3, ISA version 5) + ARCH_V3_1=y +
#   SOC_SKY1=y; SOC_DEFAULT/SOC_R329 explicitly off (each .c calls
#   module_platform_driver, so the linker errors on duplicate
#   init_module/cleanup_module if both SOCs compile into the same module).
# VPU (Linlon AMLogic-derived codec, ACPI HID CIXH3010): ADDED via
#   patches 0126-0129. The Entrpi v7.1 sky1-next Linlon VPU driver
#   (63 files, ~39K lines, Kconfig symbol VIDEO_LINLON) was carried
#   over from the 7.1 squashed tree and forward-ported onto v7.2-rc4:
#   add the missing "select VIDEOBUF2_DMA_SG" / "select VIDEOBUF2_MEMOPS"
#   in Kconfig (so the dep chain resolves when no other driver enables
#   videobuf2-dma-sg), and add explicit "#include <linux/string.h>" +
#   strncpy->strscpy in three cix files where the 7.2 include chain
#   no longer drags string.h primitives in transitively. The result is
#   drivers/media/platform/cix/amvx.ko (~575 KB unstripped, ~118 KB
#   installed + xz), depends=videobuf2-v4l2,videodev,videobuf2-dma-sg,
#   videobuf2-common. Requires the cix-vpu-umd userspace firmware
#   blobs staged at /lib/firmware/ (separate recipe) for the
#   H.264/H.265/AV1 decode/encode firmwares; this kernel-side work
#   only adds the driver, it does not stage the firmware.
#   Patch 0129 makes missing firmware fail as -ENOENT without leaving
#   later waiters stuck on a completed failed cache entry, and avoids
#   registering a hardware session after firmware has already failed.

# RTC (RA8900CE, ACPI HID RX008900): RESOLVED. cixtech vendor issue #39
#   (Orange Pi 6 Plus, 2026-07-03) = mainline rtc-ds1307 supports ra8900
#   only via i2c_device_id (no ACPI table), so ACPI-enumerated RTC never
#   binds -> rtc-efi fallback, clock resets. Vendor fix = patch
#   0049-add-hym8563-rx8900-rtc-driver. We carry it as patches-7.2/
#   0040-add-hym8563-rx8900-rtc-driver: rtc-rx8900.c has acpi_match
#   RX008900 (=y built-in, "Third Party RX8900 Driver"), rtc-hym8563.c
#   has acpi_match HYM8563. Full ACPI chain present: i2c-cadence
#   (CIXH200B, =y) -> RTC0 child (RX008900) -> rtc-rx8900. Battery-backed
#   hwclock works at boot without initrd. No further action needed.
# AUDSS clk+reset: kept as cixtech 2026q2 self-contained drivers
#   (clk-sky1-audss.c, reset-sky1-audss.c; compat "cix,sky1-audss-reset",
#   ACPI HID CIXH6062). The upstream "Add Cix Sky1 AUDSS clock and reset
#   support" series (Zabel reviewing ~2026-06-30) is NOT in v7.2-rc4 and
#   is DT-oriented; adopting an in-review series would be worse than the
#   vendor driver, and only the vendor form carries the ACPI HID cixmini
#   needs. The audss determine_rate migration (old hand-patch 9001) is
#   already in the vendor clk driver, so NO divergent hand-patch is
#   carried. RECONCILE-WHEN-LANDED: once the audss series merges in a
#   stable release, drop these two vendor files and adopt the mainline
#   form, forward-porting the ACPI HID if upstream stays DT-only.
# Required cmdline: clk_ignore_unused acpi_scmi_en=off; UEFI O/S HW
#   Description = ACPI. acpi_scmi_en=off keeps the 2026q2 deny-handler
#   from blocking CIXHA010 so the BIOS-1.0 CLKT clkdev bridge
#   (clk-sky1-acpi, patch 0096) can provide the 207 consumer clocks;
#   without it every apb/pclk consumer (PCIe/USB PHYs, pwm, uart) is
#   clockless and NVMe never appears (patches 0093-0098 chain).
# linlon-dp (linlondp + trilin-dptx): the 26q2 driver set is carried as
#   0008 (base) + 0067 (the 26q2 feature merge: cluster, single-master DRM,
#   pipeline binding/source_id consolidation, ACPI CIXH50C0 cluster +
#   CIXH5010 DPU slave detection, cluster PM, IOMMU-on-demand, etc.). The
#   0067 swap rebuilds linlondp_kms/linlondp_drv/linlondp_cluster and the
#   dptx/* files on top of 0008 (the v7.2 driver surface). The v7.2 API
#   drift is fixed by 0081 (private-obj init -> .atomic_create_state,
#   drm_atomic_state -> drm_atomic_commit, fbdev_generic -> drm_client_setup,
#   drm_panel_prepare/enable return void, MST add/remove payload split,
#   const display_mode, drm_format_info const, panel->init devm alloc,
#   edp panel return-void, from_timer -> timer_container_of,
#   drm_atomic_commit_put, color format enums -> BIT(...)). Patch 0131
#   (this series) is the v7.2 port of cix k6.6.89 1009 (WERROR fixups
#   only — static-marking file-local helpers, __maybe_unused on debug
#   locals, missing-include fixes); the drm_atomic.c %llx->%x revert
#   hunk from 1009 is dropped (already in the right state on v7.2-rc4).
#   Single-master DRM enumeration requires 26q2 firmware exposing the
#   cluster (ACPI _HID CIXH50C0 parent of CIXH5010 DPU children). With
#   older firmware the four DPU devices appear as siblings and each
#   registers its own DRM card (the "Cannot find any crtc or sizes"
#   path); that fallback is graceful — no kernel crash, just a less
#   usable user-mode display. Metal validation pending: QEMU-virt has no
#   Sky1 display hardware, so this kernel+recipe change can only be
#   proven to boot + compile cleanly here; the single-card vs multi-card
#   behaviour has to be checked on a real CIX SKY1 board with 26q2
#   firmware. Do not enable CONFIG_DRM_CIX_COMPONENT_BIND_BYPASSED —
#   it forces the multi-card path and defeats the 26q2 single-master code.

SUMMARY = "NCZ Linux kernel for Cix Sky1 / CP8180 (v7.2 + CIX 2026q2 patch set)"
DESCRIPTION = "NCZ kernel: mainline Linux v7.2 release plus the cixtech 2026q2 Sky1 driver set forward-ported by NCZ. Not a CIX/vendor release."
SECTION = "kernel"
LICENSE = "GPL-2.0-only"
LIC_FILES_CHKSUM = "file://COPYING;md5=6bc538ed5bd9a7fc9398086aedcd7e46"

inherit kernel
FILESEXTRAPATHS:prepend := "${THISDIR}/linux-cix-sky1-ncz-7.2:"

LINUX_VERSION = "7.2"
KERNEL_LOCALVERSION = "-sky1-ncz"
PATCHTOOL = "git"
PV = "7.2+ncz"
KBRANCH = "master"
KERNEL_PACKAGE_NAME = "kernel-${PN}"

# OE-Core 2026 keeps the kernel source and module-build artifacts in this
# recipe work directory. module.bbclass publishes those locations to
# external-module recipes through work-shared/${MACHINE}.
do_shared_workdir:append() {
    shared_kernel_dir="${TMPDIR}/work-shared/${MACHINE}"
    install -d "$shared_kernel_dir"
    ln -sfn "${S}" "$shared_kernel_dir/kernel-source"
    ln -sfn "${WORKDIR}/kernel-build-artifacts" "$shared_kernel_dir/kernel-build-artifacts"
    ln -sfn "${KERNEL_PACKAGE_NAME}-abiversion" "${WORKDIR}/kernel-build-artifacts/kernel-abiversion"
    ln -sfn "${KERNEL_PACKAGE_NAME}-localversion" "${WORKDIR}/kernel-build-artifacts/kernel-localversion"
}

# v7.2 release tag COMMIT (torvalds mainline, on master). SRCREV must be the
# commit, not the annotated tag object -- same convention as rc4/rc5/rc6/rc7.
# Verified on 2026-08-22:
#   v7.2-rc5 = f5098b6bae761e346ebcd9da7f95622c04733cff
#   v7.2-rc6 = 075b74841bd0065a3bda3440873c747938e69b68
#   v7.2-rc7 = db2ddb87143519e20a95aa36c60b36107b736a58
#   v7.2     = 8d3ae59288f1e7d58d76558a6ee96d533bc5019f   <- pinned below
# Bumped 2026-08-22 from v7.2-rc7 after replaying all 197 wired patches onto
# the release tag with build/port-series.sh v7.2: 197 applied, 0 failed.
# Cycle history, kept because it records what each rebase actually touched:
#   rc5 -> rc6 (2026-08-02): all 170 CIX commits replayed, range-diff 170/170
#     "=" -- none altered, dropped or added. rc6 is an ordinary bugfix cycle
#     for our purposes (615 commits, 530 files): drm/panthor gained 2 firmware
#     validation hardening commits (b921b8613790, a3caaa068092),
#     drivers/gpu/drm/arm (komeda/linlondp) untouched, realtek changes are
#     rtase-only (not r8169), arm64 work is KVM/vgic. No Sky1 failure mode
#     fixed -- hygiene only.
SRCREV_kernel = "8d3ae59288f1e7d58d76558a6ee96d533bc5019f"

SRC_URI = " \
    git://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git;protocol=https;branch=${KBRANCH};name=kernel \
    file://config-7.2-lean-msr1-o6n.defconfig \
    file://patches-7.2/0001-mailbox-add-acpi-support-to-cix-mailbox-driver.patch \
    file://patches-7.2/0002-acpi-Add-a-property-reference-count-interface.patch \
    file://patches-7.2/0003-clk-clk-scmi-register-clkdev-for-acpi.patch \
    file://patches-7.2/0004-clk-add-cix-clk-driver.patch \
    file://patches-7.2/0005-reset-add-cix-reset-driver.patch \
    file://patches-7.2/0006-soc-add-cix-acpi-resource-lookup-driver.patch \
    file://patches-7.2/0007-remoteproc-add-cix-dsp-remoteproc-driver.patch \
    file://patches-7.2/0008-drm-add-cix-linlon-dp-driver.patch \
    file://patches-7.2/0009-irqchip-add-cix-sky1-pdc-driver.patch \
    file://patches-7.2/0010-sound-hda-add-cix-ipbloq-hda-driver.patch \
    file://patches-7.2/0011-kernel-dma-Export-dma_declare_coherent_memory-for-mo.patch \
    file://patches-7.2/0012-mfd-syscon-add-acpi-support-for-cix-soc.patch \
    file://patches-7.2/0013-dma-arm-dma350-add-acpi-support-for-cix-soc.patch \
    file://patches-7.2/0014-gpio-add-acpi-support-to-cadence-driver.patch \
    file://patches-7.2/0015-clk-clkdev-increase-clkdev-MAX_CON_ID-from-16-to-32.patch \
    file://patches-7.2/0016-i2c-add-acpi-support-for-cadence-driver.patch \
    file://patches-7.2/0017-firmware-add-cix-dsp-ipc-driver.patch \
    file://patches-7.2/0018-sound-soc-add-cix-sof-driver.patch \
    file://patches-7.2/0019-sound-soc-add-cix-soc-support.patch \
    file://patches-7.2/0020-syscon-add-device_syscon_regmap_lookup_by_property.patch \
    file://patches-7.2/0021-phy-add-cix-phy-driver.patch \
    file://patches-7.2/0022-typec-add-rts5453-driver.patch \
    file://patches-7.2/0023-soc-add-cix-acpi-usb-scan-handler.patch \
    file://patches-7.2/0024-pwm-add-pwm-support-for-CIX-SoC.patch \
    file://patches-7.2/0025-disable-acpi-pcie-devices.patch \
    file://patches-7.2/0026-add-cix-vendor-pci-driver.patch \
    file://patches-7.2/0027-pci-cadence-sky1-cix-fix-sky1-cix-vendor-pcie-driver.patch \
    file://patches-7.2/0028-regulator-add-acpi-support.patch \
    file://patches-7.2/0029-pci-cadence-sky1-fix-clk-under-ACPI.patch \
    file://patches-7.2/0030-hda-cix-ipbloq-skip-init-of-verb-table-at-resume.patch \
    file://patches-7.2/0031-arm-smmu-v3-add-suspend-resume-support.patch \
    file://patches-7.2/0032-pci-cadence-add-PCI_SKY1_HOST_CIX-for-bsp-driver.patch \
    file://patches-7.2/0033-panthor-set-DPM_FLAG_NO_DIRECT_COMPLETE-for-STR-on-s.patch \
    file://patches-7.2/0034-thermal-set-thermal_zone-type-from-firmware-in-acpi_.patch \
    file://patches-7.2/0035-DPTSW-19618-linlon-dp-Set-AFBC-32x8-to-the-highest-p.patch \
    file://patches-7.2/0036-pwm-sky1-check-pwm-state-before-enable-disable-clk-i.patch \
    file://patches-7.2/0037-clocksource-add-sky1-gpt-timer-driver.patch \
    file://patches-7.2/0038-drm-cix-fix-hdmi-str.patch \
    file://patches-7.2/0039-pinctrl-sky1-add-acpi-support.patch \
    file://patches-7.2/0040-add-hym8563-rx8900-rtc-driver.patch \
    file://patches-7.2/0041-arm64-add-model-name-for-Cix-Sky1-Soc.patch \
    file://patches-7.2/0042-add-cix-thermal-ipa-driver.patch \
    file://patches-7.2/0043-add-thermal-IPA-support.patch \
    file://patches-7.2/0044-DPTSW-25537-drm-cix-dptx-HPD-fast-replug-link-train-.patch \
    file://patches-7.2/0045-watchdog-sbsa-Update-the-value-of-the-refresh-regist.patch \
    file://patches-7.2/0046-drm-cix-dptx-trigger-connector-hotplug-on-resume_ear.patch \
    file://patches-7.2/0047-dptx-check-null-pointer-in-trilin_dp_panel_hw_cfg.patch \
    file://patches-7.2/0048-firmware-arm_scmi-mailbox-set-max_rx_timeout_ms-to-3.patch \
    file://patches-7.2/0049-optee-check-system_state-when-probing-at-shutdown.patch \
    file://patches-7.2/0051-thermal-ipa-enhance-ipa.patch \
    file://patches-7.2/0052-add-cix_dst-driver.patch \
    file://patches-7.2/0053-linlondp-fix-build-of-debugfs.patch \
    file://patches-7.2/0054-linlondp-add-missing-headers.patch \
    file://patches-7.2/0055-linlondp-add-api-fix-up-to-6.18.patch \
    file://patches-7.2/0056-linlondp-disable-enable_render-by-default.patch \
    file://patches-7.2/0057-linlondp-set-DRM_FBDEV_DMA_DRIVER_OPS-for-linlondp-k.patch \
    file://patches-7.2/0058-drm-panel-add-fwnode_drm_find_panel.patch \
    file://patches-7.2/0059-gpio-gpio-cadence-fix-crashing-pcie-on-cix-p1-acpi-s.patch \
    file://patches-7.2/0060-drm-linlon-dp-remove-existing-drivers-that-may-own-t.patch \
    file://patches-7.2/0061-acpi-add-backward-complibility-to-old-firmware-with-.patch \
    file://patches-7.2/0062-rtc-rx8900-drop-removed-of_gpio-header-include.patch \
    file://patches-7.2/0063-drm-cix-add-color-format-compat-macros-for-v7.1.patch \
    file://patches-7.2/0064-soc-cix-acpi-resource-lookup-resolve-dev_id-by-ACPI-.patch \
    file://patches-7.2/0065-clk-cix-replace-with-cixtech-2026q2-k6.6.89-driver-s.patch \
    file://patches-7.2/0066-soc-cix-replace-with-cixtech-2026q2-platform-ACPI-su.patch \
    file://patches-7.2/0067-drm-cix-replace-linlon-dp-dptx-with-cixtech-2026q2-o.patch \
    file://patches-7.2/0068-phy-cix-replace-with-cixtech-2026q2.patch \
    file://patches-7.2/0069-thermal-cix-replace-IPA-drivers-with-cixtech-2026q2.patch \
    file://patches-7.2/0070-ASoC-HDA-cix-replace-SOF-machine-ipbloq-with-cixtech.patch \
    file://patches-7.2/0071-firmware-cix-replace-dsp-ipc-with-cixtech-2026q2.patch \
    file://patches-7.2/0072-usb-cdns3-replace-sky1-platform-glue-with-cixtech-20.patch \
    file://patches-7.2/0073-HDA-drop-vendor-hda_cix_ipbloq-upstream-sound-hda-co.patch \
    file://patches-7.2/0074-cix-fix-6.6-7.2-API-drift-in-clk-soc-phy-thermal-fir.patch \
    file://patches-7.2/0075-firmware-arm_scmi-add-acpi-support-to-SCMI-NCZ-0003-.patch \
    file://patches-7.2/0076-firmware-arm_scmi-add-backward-complibility-to-old-f.patch \
    file://patches-7.2/0077-pmdomain-add-acpi-support-to-cix-soc-NCZ-0008-forwar.patch \
    file://patches-7.2/0078-pmdomain-fix-dev_pm_domain_attach_by_name-for-sky1-m.patch \
    file://patches-7.2/0079-usb-cdns3-wire-CIX-Sky1-USBSSP-glue-into-v7.2-unifie.patch \
    file://patches-7.2/0080-ASoC-cix-fix-6.6-7.2-API-drift-rtd-id-daifmt-parse-d.patch \
    file://patches-7.2/0081-drm-cix-fix-6.6-7.2-API-drift-in-linlon-dp-dptx.patch \
    file://patches-7.2/0082-pmdomain-scmi-export-perf-est-power-power-scale-by-d.patch \
    file://patches-7.2/0083-soc-cix-acpi-reserved-memory-without-fdt_reserved_me.patch \
    file://patches-7.2/0084-drm-panthor-fix-7.2-API-drift-add-cix-sky1-acpi-scmi.patch \
    file://patches-7.2/0085-firmware-arm_scmi-mailbox-fix-acpi-driver-data-type-confusion.patch \
    file://patches-7.2/0086-drm-panthor-try-named-gpu_core-acpi-clock-before-bare-null-lookup.patch \
    file://patches-7.2/0087-reset-sky1-restore-acpi-support.patch \
    file://patches-7.2/0088-pmdomain-scmi-perf-defer-fwnode-provider.patch \
    file://patches-7.2/0089-clk-cix-acpi-pm-runtime-acpi-power-mgmt-resume-gate.patch \
    file://patches-7.2/0090-acpi-pm-skip-notifier-removal-in-probe-failure-cleanup.patch \
    file://patches-7.2/0091-clk-reset-sky1-audss-dont-defer-on-missing-parents-regmap.patch \
    file://patches-7.2/0092-drm-panthor-explicitly-enable-core-clock-before-hw-init.patch \
    file://patches-7.2/0093-firmware-arm_scmi-activate-implemented-protocols-on-acpi.patch \
    file://patches-7.2/0094-drm-panthor-sky1-acpi-defer-probe-gpu-clock-not-ready.patch \
    file://patches-7.2/0095-phy-cix-defer-probe-acpi-clkdev-clocks-not-registered.patch \
    file://patches-7.2/0096-clk-cix-sky1-clkt-clkdev-bridge-bios10.patch \
    file://patches-7.2/0138-clk-cix-sky1-bind-acpi-bus.patch \
    file://patches-7.2/0147-clk-cix-sky1-restore-platform-supplier.patch \
    file://patches-7.2/0148-clk-cix-sky1-reject-partial-clkt-maps.patch \
    file://patches-7.2/0157-clk-cix-sky1-dont-defer-bridge-on-partial-scmi-readiness.patch \
    file://patches-7.2/0158-pwm-sky1-defer-probe-on-missing-clkt-clkdev.patch \
    file://patches-7.2/0097-soc-cix-acpi-resource-lookup-v1-bios10.patch \
    file://patches-7.2/0098-soc-cix-v1-lookup-owns-cixa1019.patch \
    file://patches-7.2/0099-pci-sky1-acpi-standard-ecam-mode-knob.patch \
    file://patches-7.2/0100-iommu-smmu-v3-sky1-pcie-bypass-ste-ats-override.patch \
    file://patches-7.2/0101-pci-sky1-acpi-block-cixh2020-standard-mode.patch \
    file://patches-7.2/0102-phy-cix-usbdp-reset-control-get-optional.patch \
    file://patches-7.2/0103-phy-cix-usb2-usb3-reset-control-get-optional.patch \
    file://patches-7.2/0104-clk-sky1-audss-adopt-v8-gate-ops.patch \
    file://patches-7.2/0105-clk-sky1-audss-drop-prepare-unmatched-put-noidle.patch \
    file://patches-7.2/0106-iommu-smmu-v3-sky1-disable-event-queue-storm.patch \
    file://patches-7.2/0107-regulator-preserve-acpi-firmware-enabled-rails.patch \
    file://patches-7.2/0108-iommu-smmu-v3-sky1-disable-pri-restore-evtq.patch \
    file://patches-7.2/0109-pci-cix-force-clock-pm-off-sky1-endpoints.patch \
    file://patches-7.2/0110-net-r8169-skip-hw-tally-rtl8127-sky1.patch \
    file://patches-7.2/0111-reset-cix-acpi-fwnode-lookup-fallback.patch \
    file://patches-7.2/0112-usb-cdns3-initialize-host-role-for-Sky1-USBSSP.patch \
    file://patches-7.2/0113-usb-cdns3-restore-cdnsp-sky1-acpi-host-bringup.patch \
    file://patches-7.2/0114-usb-cdns3-restore-full-sky1-next-USBSSP-driver-set-h.patch \
    file://patches-7.2/0115-usb-cdns3-restore-remaining-sky1-next-cdns3-cdnsp-fi.patch \
    file://patches-7.2/0116-usb-cdns3-restore-sky1-next-Kconfig-Makefile-USB_CDN.patch \
    file://patches-7.2/0117-pmdomain-arm-export-CIX-SCMI-perf-helpers.patch \
    file://patches-7.2/0118-usb-typec-restore-rts5453-Sky1-driver.patch \
    file://patches-7.2/0119-misc-armchina-npu-add-Zhouyi-NPU-driver-for-CIX-Sky1.patch \
    file://patches-7.2/0120-misc-armchina-npu-fix-pm_runtime_put-void-return-7.2.patch \
    file://patches-7.2/0121-misc-armchina-npu-sky1-null-pd-core-guard.patch \
    file://patches-7.2/0122-acpi-sta_quirk-add-cixh4010-npu-cores.patch \
    file://patches-7.2/0123-misc-armchina-npu-force-D0-before-probe.patch \
    file://patches-7.2/0124-acpi-sta_quirk-tighten-hidden-Sky1-SCMI-NPU-child.patch \
    file://patches-7.2/0125-misc-armchina-npu-platform_remove-void-7.2.patch \
    file://patches-7.2/0126-media-cix-add-Sky1-video-codec-VPU-driver.patch \
    file://patches-7.2/0127-media-linlon-add-missing-VIDEOBUF2_DMA_SG-and-VIDEOB.patch \
    file://patches-7.2/0128-media-cix-add-linux-string.h-includes-7.2-build-fix.patch \
    file://patches-7.2/0129-media-cix-handle-missing-VPU-firmware-cleanly.patch \
    file://patches-7.2/0130-media-cix-vpu-sync-upstream-v1.0.1-irq-reset-race-fix.patch \
    file://patches-7.2/0131-drm-linlondp-fix-WERROR.patch \
    file://patches-7.2/0132-firmware-arm_scmi-setup-channel-for-acpi-activated-protocols.patch \
    file://patches-7.2/0133-drm-linlondp-pin-display-power-domain-unconditionally.patch \
    file://patches-7.2/0134-drm-trilin-dptx-restore-runtime-pm.patch \
    file://patches-7.2/0135-media-cix-vpu-sync-upstream-v1.0.2.patch \
    file://patches-7.2/0152-media-cix-amvx-serror-drain-masked-reads.patch \
    file://patches-7.2/0153-media-cix-amvx-scmi-perf-devfreq.patch \
    file://patches-7.2/0154-drm-cix-dptx-validate-reset-and-clock-lookups.patch \
    file://patches-7.2/0155-phy-cix-usbdp-acquire-pclk-before-asserting-resets.patch \
    file://patches-7.2/0156-drm-cix-linlondp-propagate-aclk-enable-failures.patch \
    file://patches-7.2/0159-armchina-npu-drop-irqf-oneshot.patch \
    file://patches-7.2/0160-hwmon-scmi-dont-skip-thermal-zone-on-config-set-fail.patch \
    file://patches-7.2/0161-drm-cix-edp-panel-acpi-desc-properties.patch \
    file://patches-7.2/0162-drm-cix-linlondp-defer-on-missing-aclk-instead-of-failing.patch \
    file://patches-7.2/0163-phy-cix-usb3-defer-on-missing-clocks-fix-ref-clk-check.patch \
    file://patches-7.2/0164-usb-cdns3-cdnsp-sky1-defer-on-missing-clocks.patch \
    file://patches-7.2/0165-i2c-cadence-defer-on-missing-clock.patch \
    file://patches-7.2/0166-clocksource-sky1-defer-on-missing-timer-clocks.patch \
    file://patches-7.2/0167-soc-cix-acpi-resource-lookup-tighten-badly-specified-guard.patch \
    file://patches-7.2/0168-clk-cix-sky1-remap-clkt-bridge-on-scmi-clocks-bind.patch \
    file://patches-7.2/0169-drm-cix-linlondp-dont-double-put-acpi-pxlclk.patch \
    file://patches-7.2/0170-drm-cix-dptx-optional-phy-reset-and-vid-clk23.patch \
    file://patches-7.2/0171-asoc-cix-pick-hdmi-codec-child-explicitly.patch \
    file://patches-7.2/0172-thermal-cix-resolve-scmi-perf-domain-via-genpd-acpi.patch \
    file://patches-7.2/0173-amvx-vb2-queue-lock-7.2.patch \
    file://patches-7.2/0176-drm-cix-dptx-aux-dpcd-robustness-cold-boot.patch \
    file://patches-7.2/0177-pinctrl-sky1-quiet-absent-optional-pin-groups.patch \
    file://patches-7.2/0178-firmware-arm-scmi-quiet-fastchannel-fallback-noise.patch \
    file://patches-7.2/0179-iommu-arm-smmu-v3-demote-benign-fw-config-notes.patch \
    file://patches-7.2/0180-usb-cdns3-sky1-fix-runtime-pm-parent-child-order.patch \
    file://patches-7.2/0181-regulator-cix-handle-unsupported-pmic-constraints-quietly.patch \
    file://patches-7.2/0182-asoc-cix-hdmi-audio-drop-duplicate-dapm-registration.patch \
    file://patches-7.2/0183-genpd-cix-dedupe-power-domain-opp-table.patch \
    file://patches-7.2/0184-thermal-cix-cpufreq-cooling-acpi-no-of-node.patch \
    file://patches-7.2/0185-firmware-arm-scmi-perf-skip-opp-repopulation.patch \
    file://patches-7.2/0187-drm-panthor-route-scmi-dvfs-through-perf-opp.patch \
    file://patches-7.2/0190-soc-cix-only-deny-generic-ACPI-ids-on-sky1.patch \
    file://patches-7.2/0191-soc-cix-default-acpi_scmi_en-off-so-the-clock-bridge-binds.patch \
    file://patches-7.2/0192-usb-cdns3-sky1-keep-the-wrapper-pinned-by-its-children.patch \
    file://patches-7.2/0193-usb-hub-give-root-hubs-the-same-power-on-good-floor.patch \
    file://patches-7.2/0200-rpmsg-virtio-ratelimit-no-used-buffer.patch \
    file://patches-7.2/0201-acpi-table-upgrade-add-disable-and-exclude-options.patch \
    file://patches-7.2/0202-platform-acpi-resolve-named-irq-resources.patch \
    file://patches-7.2/0203-power-opp-accept-acpi-only-configurations.patch \
    file://patches-7.2/0204-topology-has-missing-cpufreq-ref.patch \
    file://patches-7.2/0205-acpi-processor-clarify-ignore-ppc-module-parameter.patch \
    file://patches-7.2/0206-pstore-ramoops-parse-firmware-node-properties.patch \
    file://patches-7.2/0207-drm-cix-demote-internal-tbu-noop-logs.patch \
    file://patches-7.2/0208-bluetooth-btrtl-return-register-read-error.patch \
    file://patches-7.2/0209-firmware-arm-scmi-use-rational-perf-frequency-conversion.patch \
    file://patches-7.2/0210-acpi-thermal-bind-devfreq-cooling-devices-safely.patch \
    file://patches-7.2/0211-drm-panthor-declare-scmi-perf-softdep.patch \
    file://patches-7.2/0212-cacheinfo-share-global-firmware-ids-across-levels.patch \
    file://patches-7.2/0213-hwmon-cix-add-safe-acpi-fan-control.patch \
    file://patches-7.2/0214-acpi-demote-cix-sky1-ecam-duplicate-reservations.patch \
    file://patches-7.2/0215-pci-cix-enable-root-port-io-window-assignment.patch \
    file://patches-7.2/0216-resctrl-mpam-expose-proportional-bandwidth.patch \
    file://patches-7.2/0217-rtw89-disable-hw-rfkill-polling-on-orion-o6.patch \
    file://patches-7.2/0218-rtw89-check-acpi-dsm-before-evaluating.patch \
    file://patches-7.2/0219-DEBUG-ncz-resume-beacons-ramoops.patch \
    file://patches-7.2/0220-misc-armchina-npu-use-irq-object-as-dev-id.patch \
    file://patches-7.2/0221-usb-cdns3-sky1-defer-child-until-wrapper-ready.patch \
    file://patches-7.2/0222-usb-hub-recover-connect-events-on-powered-but-runtime-suspended-ports.patch \
"

COMPATIBLE_MACHINE = "(cixmini)"
S = "${UNPACKDIR}/${BB_GIT_DEFAULT_DESTSUFFIX}"

PROVIDES = "${PN} virtual/kernel"

do_configure:prepend() {
    cd ${S}
    cp ${UNPACKDIR}/config-7.2-lean-msr1-o6n.defconfig ${B}/.config
    oe_runmake ARCH=arm64 O=${B} olddefconfig
}

KERNEL_IMAGETYPE = "Image"
KERNEL_DEVICETREE = " \
    cix/sky1-orion-o6.dtb \
"
