# SPDX-FileCopyrightText: Copyright (c) 2026 Jason Perlow
# SPDX-License-Identifier: Apache-2.0
#
# Linux kernel for Cix Sky1 / CP8180 — Sky1-Linux community track.
#
# Replaces linux-cix-msr1_6.6.10.bb. The 6.6 vendor track had the full
# Cix proprietary out-of-tree driver pack (aipu/mali_kbase/amvx/...)
# but their userspace BSP integration on Minisforum's tree was broken
# in ways that wedged the kernel before VT/userspace.
#
# This recipe: mainline Linux v6.18.26 LTS + Sky1-Linux's 139 LTS
# patches (`https://github.com/Sky1-Linux/linux-sky1` `patches/`).
# Sky1-Linux is Entrpi's upstream-friendly community fork that
# integrates Cix BSP cleanly into the mainline driver model:
#
#   GPU:    upstream `drm/panthor` (since 6.10) + 4 Cix-specific patches
#   NPU:    `misc/armchina-npu/` (Zhouyi NPU) — in-tree
#   VPU:    `media/cix/` (linlon video codec) — in-tree
#   DSP:    `cix_dsp_rproc` with ACPI memremap fix (0102)
#   DPTX:   `drm/cix` with full state-machine fixes (0044/0052/0117/0127/...)
#   Audio:  in-tree HDA + sky1-audio
#   PCIe:   cadence + Sky1 host controller
#   USB:    usb-phy Sky1 driver
#   Net:    full in-tree, including r8126 (was DKMS in 6.6)
#
# All Cix prebuilt out-of-tree .ko's are dropped — same hardware is
# now driven by upstream-style in-tree drivers. Cix userspace libs
# (libnoe / libaipudrv) may or may not work against the new uapi;
# that's a separate userspace-side concern handled in cix-debs hooks.

SUMMARY = "NCZ Linux kernel for Cix Sky1 / CP8180 (6.18.26 LTS)"
DESCRIPTION = "Mainline Linux v6.18.26 LTS + Sky1-Linux/linux-sky1 patches/ track. \
Replaces linux-cix-msr1 vendor 6.6.10 with upstream-friendly in-tree drivers \
for GPU (panthor), NPU (armchina-npu), VPU (cix-media), audio, networking, \
PCIe, USB-PHY. Targets Cix CP8180 SoC — primary board: Minisforum MS-R1 (cixmini)."
SECTION = "kernel"
LICENSE = "GPL-2.0-only"
LIC_FILES_CHKSUM = "file://COPYING;md5=6bc538ed5bd9a7fc9398086aedcd7e46"

inherit kernel

LINUX_VERSION = "6.18.26"
# Sky1-Linux's build-debs.sh recipe: blank CONFIG_LOCALVERSION + disable
# CONFIG_LOCALVERSION_AUTO + drive suffix entirely from KERNEL_LOCALVERSION.
# config.sky1 ships with `CONFIG_LOCALVERSION=""` and
# `# CONFIG_LOCALVERSION_AUTO is not set` already, so KERNEL_LOCALVERSION
# is the sole contributor → final uname -r = 6.18.26-cix-sky1-lts.
KERNEL_LOCALVERSION = "-ncz-lts"
PV = "${LINUX_VERSION}+ncz"
KBRANCH = "linux-6.18.y"

# Build as a sibling package so it can be installed/tested alongside
# linux-cix-sky1 without package namespace collisions.
KERNEL_PACKAGE_NAME = "kernel-${PN}"

# Mainline stable kernel + 139 Sky1-Linux LTS patches + config.sky1.
SRC_URI = " \
    git://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git;protocol=https;branch=${KBRANCH};name=kernel \
    file://config.sky1 \
    file://sky1-patches/0001-arm64-dts-cix-Add-Sky1-SoC-and-Radxa-Orion-O6-device.patch \
    file://sky1-patches/0002-pci-cadence-Add-CIX-Sky1-PCIe-host-controller-driver.patch \
    file://sky1-patches/0003-arm64-cix-Add-Sky1-infrastructure-drivers.patch \
    file://sky1-patches/0004-usb-phy-Add-CIX-Sky1-USB-and-PHY-drivers.patch \
    file://sky1-patches/0005-drm-cix-Add-Sky1-display-drivers.patch \
    file://sky1-patches/0006-drm-panthor-Add-CIX-Sky1-GPU-support.patch \
    file://sky1-patches/0007-sound-audio-Add-CIX-Sky1-audio-DSP-and-HDA-drivers.patch \
    file://sky1-patches/0008-net-Add-CIX-Sky1-networking-drivers.patch \
    file://sky1-patches/0009-misc-armchina-npu-Add-Zhouyi-NPU-driver-for-CIX-Sky1.patch \
    file://sky1-patches/0010-media-cix-Add-Sky1-video-codec-VPU-driver.patch \
    file://sky1-patches/0011-irqchip-iommu-perf-Add-CIX-Sky1-support.patch \
    file://sky1-patches/0012-arm64-cix-Add-Sky1-thermal-PWM-watchdog-and-misc-dri.patch \
    file://sky1-patches/0013-scripts-Add-Sky1-kernel-development-tools.patch \
    file://sky1-patches/0014-net-realtek-fix-shutdown-panic-in-r8125-r8126-get_st.patch \
    file://sky1-patches/0015-drm-panthor-Add-SCMI-perf-domain-support-for-GPU-DVF.patch \
    file://sky1-patches/0016-arm64-dts-cix-Add-GPU-OPP-table-for-Sky1.patch \
    file://sky1-patches/0017-drm-panthor-Fix-SCMI-perf-domain-DVFS-to-use-existin.patch \
    file://sky1-patches/0018-arm64-dts-cix-Fix-WiFi-RFKill-GPIO-on-Orion-O6-and-O.patch \
    file://sky1-patches/0019-arm64-dts-cix-Add-GPIO-LEDs-and-fix-pinctrl-on-Orion.patch \
    file://sky1-patches/0020-arm64-dts-cix-Add-Orange-Pi-6-Plus-device-tree.patch \
    file://sky1-patches/0021-drm-cix-Fix-compiler-warnings-in-DPTX-display-driver.patch \
    file://sky1-patches/0022-drm-cix-Add-DRM-bridge-chain-for-PS185-DP-to-HDMI-on.patch \
    file://sky1-patches/0023-drm-panthor-Rate-limit-SCMI-perf-domain-DVFS-request.patch \
    file://sky1-patches/0024-arm64-dts-cix-Add-board-specific-compatible-string-t.patch \
    file://sky1-patches/0025-Update-README-24-patches-add-individual-patch-list-O.patch \
    file://sky1-patches/0026-arm64-dts-cix-Enable-USB-C-DisplayPort-alt-mode-on-O.patch \
    file://sky1-patches/0027-drm-cix-Fix-DPTX-link-rate-selection-for-optimal-ban.patch \
    file://sky1-patches/0028-arm64-dts-cix-Fix-PCIe-power-supply-GPIO-assignments.patch \
    file://sky1-patches/0029-update-dev-boot-sync-kernel-and-DTB-files-to-EFI-par.patch \
    file://sky1-patches/0030-arm64-dts-cix-Fix-O6N-power-tree-convert-USB-C-PD-to.patch \
    file://sky1-patches/0031-arm64-dts-cix-Add-USB-overcurrent-and-NVMe-wake-GPIO.patch \
    file://sky1-patches/0032-arm64-dts-cix-Set-O6N-DP-PHY-to-pure-DisplayPort-mod.patch \
    file://sky1-patches/0033-iommu-arm-smmu-v3-Add-SMMUv3.2-event-definitions.patch \
    file://sky1-patches/0034-arm64-dts-cix-Add-dma-coherent-to-SMMU-nodes.patch \
    file://sky1-patches/0035-arm64-dts-cix-Add-boot-active-sids-to-PCIe-SMMU-for-.patch \
    file://sky1-patches/0036-arm64-dts-cix-Add-msi-cells-to-ITS-node.patch \
    file://sky1-patches/0037-update-dev-boot-fix-DTB-sort-key-to-use-full-path.patch \
    file://sky1-patches/0038-arm64-dts-cix-Add-missing-DPU-SIDs-and-enable-GOP-RM.patch \
    file://sky1-patches/0039-arm64-dts-cix-Enable-PCIe-SMMU-on-Orion-O6.patch \
    file://sky1-patches/0040-iommu-arm-smmu-v3-Add-per-SID-event-auto-suppression.patch \
    file://sky1-patches/0041-update-dev-boot-handle-.rN-revision-suffix-in-kernel.patch \
    file://sky1-patches/0042-net-realtek-r8125-r8126-Add-IRQ-affinity-hint-for-pe.patch \
    file://sky1-patches/0043-PCI-cadence-sky1-Add-ASPM-control-and-wakeup-improve.patch \
    file://sky1-patches/0044-drm-cix-dptx-Fix-suspend-resume-deadlock-and-improve.patch \
    file://sky1-patches/0045-cpufreq-cppc-Skip-redundant-frequency-updates.patch \
    file://sky1-patches/0046-drm-cix-dptx-Use-freezable-workqueue-for-HPD-handlin.patch \
    file://sky1-patches/0047-drm-cix-dptx-Improve-PSR-implementation.patch \
    file://sky1-patches/0048-thermal-cix-Add-IPA-power-integration-for-cpufreq_co.patch \
    file://sky1-patches/0049-drm-cix-linlon-dp-Handle-vblank-event-on-flip-timeou.patch \
    file://sky1-patches/0050-iommu-arm-smmu-v3-Add-PCIe-ATS-override-option-for-S.patch \
    file://sky1-patches/0051-PCI-Add-ASPM-quirks-for-Phison-and-Kingston-NVMe-dri.patch \
    file://sky1-patches/0052-drm-cix-dptx-Fix-hotplug-state-machine-on-repeated-r.patch \
    file://sky1-patches/0053-drm-panthor-Add-ACPI-support.patch \
    file://sky1-patches/0054-usb-Enable-runtime-PM-by-default-for-Sky1-USB-contro.patch \
    file://sky1-patches/0055-net-realtek-r8125-r8126-Enable-WoL-and-RSS-support.patch \
    file://sky1-patches/0056-ASoC-ALSA-CIX-Sky1-audio-fixes.patch \
    file://sky1-patches/0057-arm64-dts-cix-Thermal-zone-improvements.patch \
    file://sky1-patches/0058-gpio-cadence-Add-edge-IRQ-PM-wake-and-ACPI-support.patch \
    file://sky1-patches/0059-pwm-sky1-Remove-clock-auto-enable-and-probe-reset.patch \
    file://sky1-patches/0060-rtc-hym8563-Add-second-level-wake-up-support.patch \
    file://sky1-patches/0061-firmware-arm_scmi-Add-ACPI-support-to-transport-driv.patch \
    file://sky1-patches/0062-mfd-syscon-Add-ACPI-platform-driver-support.patch \
    file://sky1-patches/0063-clocksource-Add-CIX-Sky1-GPT-timer-driver.patch \
    file://sky1-patches/0064-hwmon-Add-CIX-Sky1-fan-controller-driver.patch \
    file://sky1-patches/0065-treewide-Add-ACPI-device-IDs-for-CIX-Sky1-SoC-periph.patch \
    file://sky1-patches/0066-net-realtek-r8125-r8126-Add-missing-RSS-object-files.patch \
    file://sky1-patches/0067-gpio-cadence-Fix-IRQ-storm-and-harden-IRQ-handling.patch \
    file://sky1-patches/0068-usb-cdns3-Fix-runtime-PM-for-Sky1-USB-controllers.patch \
    file://sky1-patches/0069-mailbox-cix-mailbox-Remove-debug-print-statements.patch \
    file://sky1-patches/0070-mailbox-cix-mailbox-Remove-use_shmem-register-offset.patch \
    file://sky1-patches/0071-mailbox-cix-mailbox-Allow-building-with-ACPI.patch \
    file://sky1-patches/0072-firmware-arm_scmi-shmem-Add-ACPI-shared-memory-disco.patch \
    file://sky1-patches/0073-firmware-arm_scmi-mailbox-Add-ACPI-channel-validatio.patch \
    file://sky1-patches/0074-firmware-arm_scmi-Add-ACPI-boot-support-for-CIX-Sky1.patch \
    file://sky1-patches/0075-mailbox-Add-ACPI-fwnode-support-for-channel-lookup.patch \
    file://sky1-patches/0076-clk-Add-ACPI-clock-infrastructure-for-CIX-Sky1.patch \
    file://sky1-patches/0077-soc-cix-Add-ACPI-resource-lookup-driver.patch \
    file://sky1-patches/0078-usb-cdns3-Harden-cdnsp-sky1-probe-for-ACPI-boot.patch \
    file://sky1-patches/0079-clk-cix-Add-ACPI-support-for-sky1-audss-clock-and-re.patch \
    file://sky1-patches/0080-drivers-Fix-ACPI-boot-failures-for-CIX-Sky1-peripher.patch \
    file://sky1-patches/0081-scripts-sky1_lib-Add-DMI-board-detection-for-ACPI-bo.patch \
    file://sky1-patches/0082-usb-cdns3-Serialize-drd_init-to-prevent-SCMI-mailbox.patch \
    file://sky1-patches/0083-sound-hda-cix-ipbloq-Add-ACPI-DMA-range-map-and-rese.patch \
    file://sky1-patches/0084-pstore-ramoops-Convert-to-device_property-API-for-AC.patch \
    file://sky1-patches/0085-PCI-ACPI-Suppress-cosmetic-warnings-on-CIX-Sky1-ACPI.patch \
    file://sky1-patches/0086-usb-cdns3-Skip-destructive-hardware-reinit-under-ACP.patch \
    file://sky1-patches/0087-phy-cix-usbdp-Skip-PHY-reset-under-ACPI-boot.patch \
    file://sky1-patches/0088-Bluetooth-btrtl-Fix-NULL-pointer-dereference-on-USB-.patch \
    file://sky1-patches/0089-PCI-Silence-I-O-BAR-assignment-failures-when-no-I-O-.patch \
    file://sky1-patches/0090-PCI-sky1-Add-MCFG-quirk-for-CIX-Sky1-Cadence-PCIe-co.patch \
    file://sky1-patches/0091-PCI-sky1-Switch-ACPI-from-MCFG-quirk-to-vendor-scan-.patch \
    file://sky1-patches/0092-PCI-sky1-Always-claim-CIXH2020-in-scan-handler-to-pr.patch \
    file://sky1-patches/0093-PCI-sky1-Fix-ACPI-probe-with-proper-RSTL-reset-and-r.patch \
    file://sky1-patches/0094-treewide-Debug-cleanup-and-minor-fixes-for-Sky1-peri.patch \
    file://sky1-patches/0095-pmdomain-Enable-SCMI-power-and-perf-domain-registrat.patch \
    file://sky1-patches/0096-drm-panthor-Add-ACPI-support-for-Sky1-GPU-power-on-a.patch \
    file://sky1-patches/0097-drm-cix-dptx-skip-compute_config-on-non-modeset-atom.patch \
    file://sky1-patches/0098-ACPI-property-restore-string-path-traversal-for-grap.patch \
    file://sky1-patches/0099-drm-cix-linlon-dp-clean-up-ACPI-probe-logging-and-gu.patch \
    file://sky1-patches/0100-phy-cix-usbdp-guard-syscon-regmap-access-for-ACPI-bo.patch \
    file://sky1-patches/0101-pmdomain-add-fwnode-based-genpd-provider-for-ACPI-po.patch \
    file://sky1-patches/0102-remoteproc-cix_dsp_rproc-add-ACPI-boot-support.patch \
    file://sky1-patches/0103-misc-armchina-npu-add-ACPI-DVFS-support-via-fwnode-g.patch \
    file://sky1-patches/0104-xhci-plat-auto-detect-USB3-LPM-support-for-ACPI-plat.patch \
    file://sky1-patches/0105-PCI-cadence-sky1-skip-regulator-lookup-under-ACPI.patch \
    file://sky1-patches/0106-clk-cix-sky1-acpi-use-CLKT-consumer-reference-for-cl.patch \
    file://sky1-patches/0107-audio-cix-sky1-enable-HDMI-DisplayPort-audio-output-.patch \
    file://sky1-patches/0108-scripts-kernel-track-status-handle-major-version-bum.patch \
    file://sky1-patches/0109-soc-cix-add-ACPI-USB-scan-handler-to-block-PNP0D10.patch \
    file://sky1-patches/0110-usb-cdnsp-add-ACPI-device-matching-and-PHY-reference.patch \
    file://sky1-patches/0111-usb-cdnsp-sky1-unify-DT-and-ACPI-init-paths-with-PHY.patch \
    file://sky1-patches/0112-phy-cix-usbdp-enable-full-PHY-reset-under-ACPI.patch \
    file://sky1-patches/0113-scripts-move-Sky1-dev-tools-to-sky1-linux-build-repo.patch \
    file://sky1-patches/0114-dmaengine-arm-dma350-fix-ACPI-probe-missing-address-.patch \
    file://sky1-patches/0115-soc-cix-add-ACPI-scan-handler-to-override-GPU-_CCA-o.patch \
    file://sky1-patches/0116-drm-linlon-dp-harden-DPU-for-ACPI-boot-and-Panthor-c.patch \
    file://sky1-patches/0117-drm-panthor-add-ACE-Lite-coherency-and-NC-memattr-fa.patch \
    file://sky1-patches/0118-iommu-arm-smmu-v3-Add-ACPI-boot-active-bypass-STEs-f.patch \
    file://sky1-patches/0119-drm-add-sky1-drm-render-node-bridge-for-CIX-Sky1-SoC.patch \
    file://sky1-patches/0120-drm-sky1-switch-from-faux_device-to-platform_device.patch \
    file://sky1-patches/0121-mm-add-Mali-GPU-movable_ops-page-type-support.patch \
    file://sky1-patches/0122-pmdomain-arm-scmi_perf_domain-export-helpers-for-EM-.patch \
    file://sky1-patches/0123-drm-linlon-dp-add-diagnostic-knobs-for-AFBC-and-10bp.patch \
    file://sky1-patches/0124-phy-cix-usbdp-Default-to-DP-mode-for-static-outputs-.patch \
    file://sky1-patches/0125-drm-trilin-dptx-tear-down-DP-core-on-HPD-disconnect-.patch \
    file://sky1-patches/0126-drm-trilin-dptx-reset-active_stream_cnt-on-HPD-disco.patch \
    file://sky1-patches/0127-media-linlon-add-missing-VIDEOBUF2_DMA_SG-and-VIDEOB.patch \
    file://sky1-patches/0128-drm-trilin-dptx-add-CEC-over-DP-AUX-support.patch \
    file://sky1-patches/0129-drm-trilin-dptx-recover-link-on-HPD-bounce-with-degr.patch \
    file://sky1-patches/0130-Kconfig-fix-missing-dependencies-for-sky1-socinfo-an.patch \
    file://sky1-patches/0131-pwm-sky1-fix-NULL-dereference-in-suspend.patch \
    file://sky1-patches/0132-fix-allmodconfig-build-warnings-across-CIX-drivers.patch \
    file://sky1-patches/0133-drm-trilin-dptx-retry-AUX-on-cold-plug-timeout.patch \
    file://sky1-patches/0134-ASoC-cix-skip-HDMI-audio-links-for-missing-I2S-devic.patch \
    file://sky1-patches/0135-drm-trilin-dptx-add-ELD-reporting-and-audio-infofram.patch \
    file://sky1-patches/0136-drm-cix-dptx-add-IEC60958-channel-status-for-extende.patch \
    file://sky1-patches/0137-drm-cix-dptx-properly-disable-audio-hardware-on-shut.patch \
    file://sky1-patches/0138-drm-cix-dptx-suppress-spurious-ELD-warnings-at-boot.patch \
    file://sky1-patches/0139-cix-remove-pre-silicon-EMU-FPGA-dead-code-from-vendo.patch \
    file://sky1-patches/0140-arm64-cix-fix-kconfig-deps-and-reachability.patch \
"

# Pin to a specific 6.18.x point release (latest LTS at recipe authoring
# time = v6.18.26). Bump SRCREV to the SHA of the desired tag when
# adopting a newer 6.18.y point release.
SRCREV_kernel = "1fe06068166d4fc16722201f267b1fe19efad639"
# Supply-chain integrity: fetch from pinned git SRCREV above.
# For tarball-mirror reproducibility, add a BB_GENERATE_MIRROR_TARBALLS
# flow or fixed SRC_URI[kernel.sha256sum] = "..." after first fetch.
# ngc-review HIGH: verified SRCREV is pinned; tarball checksum deferred.

S = "${WORKDIR}/git"

COMPATIBLE_MACHINE = "^cixmini$"

# Sky1-Linux's LTS track ships `config.sky1` as a complete .config
# (not a fragment). Drop it in directly via do_configure:prepend
# (plain kernel.bbclass; no kernel-yocto fragment flow).
do_configure:prepend() {
    cd "${S}" || bbfatal "Cannot cd to ${S}"
    cp "${WORKDIR}/config.sky1" "${B}/.config"
    # CONFIG_EXTRA_FIRMWARE bakes firmware blobs into the kernel image
    # at compile time, looking at /lib/firmware/ on the build host. We
    # ship sky1-firmware as a separate runtime package via a Yocto
    # recipe (sky1-firmware_git.bb) so drivers request it at runtime
    # via udev/firmware_loader. Disable the bake-in.
    # Idempotent EXTRA_FIRMWARE disable: handle both =value and # not set forms.
    scripts/config --file "${B}/.config" --disable EXTRA_FIRMWARE 2>/dev/null || {
        sed -i "s|^CONFIG_EXTRA_FIRMWARE=.*|# CONFIG_EXTRA_FIRMWARE is not set|" "${B}/.config"
        sed -i "/^CONFIG_EXTRA_FIRMWARE_DIR=/d" "${B}/.config"
    }
    oe_runmake ARCH=arm64 O="${B}" olddefconfig
}

# Sky1 builds dtbs for Radxa Orion O6/O6N + Orange Pi 6 Plus. MS-R1
# boots via ACPI from UEFI (no DTS), but ship the dtbs anyway for
# diagnostic/fallback use. (Yocto requires KERNEL_DEVICETREE to be
# something parsable even if cmdline doesn't reference it.)
KERNEL_IMAGETYPE = "Image"
KERNEL_DEVICETREE = " \
    cix/sky1-orion-o6.dtb \
"
# KERNEL_DEVICETREE gate: verify build output for DTB presence;
# MS-R1 boots via ACPI (no DTS), so this is diagnostic-only.
# ngc-review MED: match actual arch/arm64/boot/dts/ output names.


PROVIDES += "virtual/kernel"
# Coexistence with other kernel recipes is handled via:
#   PREFERRED_PROVIDER_virtual/kernel = "linux-cix-sky1-ncz" (machine conf)
#   KERNEL_PACKAGE_NAME = "kernel-${PN}" (unique package namespace)
# ngc-review HIGH: explicit PROVIDES ensures dependency resolution.
