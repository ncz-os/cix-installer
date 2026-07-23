# SPDX-FileCopyrightText: Copyright (c) 2026 Jason Perlow
# SPDX-License-Identifier: Apache-2.0
SUMMARY = "NCZ Linux kernel for Cix Sky1 / CP8180 (v7.1.2 stable + CIX patch set)"
DESCRIPTION = "NCZ kernel: mainline-stable Linux v7.1.2 (linux-7.1.y) plus the CIX Sky1 patch set, forward-ported and built by NCZ. Not a CIX/vendor release. NPU/VPU via DKMS, mesa/libmali are userspace apt pkgs."
SECTION = "kernel"
LICENSE = "GPL-2.0-only"
LIC_FILES_CHKSUM = "file://COPYING;md5=6bc538ed5bd9a7fc9398086aedcd7e46"
inherit kernel
FILESEXTRAPATHS:prepend := "${THISDIR}/linux-cix-sky1-ncz-7.1.1:"

LINUX_VERSION = "7.1.2"
KERNEL_LOCALVERSION = "-ncz2"
PATCHTOOL = "git"
PV = "${LINUX_VERSION}+ncz"
KBRANCH = "linux-7.1.y"
KERNEL_PACKAGE_NAME = "kernel"
SRCREV_kernel = "03e2778d1f11de9260543f969e9e888a1c2bf830"
SRC_URI = "\
    git://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git;protocol=https;branch=${KBRANCH};name=kernel \
    file://config-7.0.defconfig \
    file://patches-7.1/0001-mailbox-add-acpi-support-to-cix-mailbox-driver.patch \
    file://patches-7.1/0002-acpi-Add-a-property-reference-count-interface.patch \
    file://patches-7.1/0003-firmware-arm_scmi-add-acpi-support-to-SCMI.patch \
    file://patches-7.1/0004-clk-clk-scmi-register-clkdev-for-acpi.patch \
    file://patches-7.1/0005-clk-add-cix-clk-driver.patch \
    file://patches-7.1/0006-reset-add-cix-reset-driver.patch \
    file://patches-7.1/0007-soc-add-cix-acpi-resource-lookup-driver.patch \
    file://patches-7.1/0008-pmdomain-add-acpi-support-to-cix-soc.patch \
    file://patches-7.1/0009-remoteproc-add-cix-dsp-remoteproc-driver.patch \
    file://patches-7.1/0010-drm-add-cix-linlon-dp-driver.patch \
    file://patches-7.1/0011-drm-panthor-add-acpi-support-for-cix-p1.patch \
    file://patches-7.1/0012-irqchip-add-cix-sky1-pdc-driver.patch \
    file://patches-7.1/0013-sound-hda-add-cix-ipbloq-hda-driver.patch \
    file://patches-7.1/0014-kernel-dma-Export-dma_declare_coherent_memory-for-mo.patch \
    file://patches-7.1/0015-mfd-syscon-add-acpi-support-for-cix-soc.patch \
    file://patches-7.1/0016-dma-arm-dma350-add-acpi-support-for-cix-soc.patch \
    file://patches-7.1/0017-gpio-add-acpi-support-to-cadence-driver.patch \
    file://patches-7.1/0018-clk-clkdev-increase-clkdev-MAX_CON_ID-from-16-to-32.patch \
    file://patches-7.1/0019-i2c-add-acpi-support-for-cadence-driver.patch \
    file://patches-7.1/0020-firmware-add-cix-dsp-ipc-driver.patch \
    file://patches-7.1/0021-sound-soc-add-cix-sof-driver.patch \
    file://patches-7.1/0022-sound-soc-add-cix-soc-support.patch \
    file://patches-7.1/0023-syscon-add-device_syscon_regmap_lookup_by_property.patch \
    file://patches-7.1/0024-phy-add-cix-phy-driver.patch \
    file://patches-7.1/0025-usb-add-usb-cdns3-driver-for-cix-soc.patch \
    file://patches-7.1/0026-typec-add-rts5453-driver.patch \
    file://patches-7.1/0027-soc-add-cix-acpi-usb-scan-handler.patch \
    file://patches-7.1/0028-pwm-add-pwm-support-for-CIX-SoC.patch \
    file://patches-7.1/0029-usb-cdns3-fix-spin-lock-issue-in-suspend-resume.patch \
    file://patches-7.1/0030-disable-acpi-pcie-devices.patch \
    file://patches-7.1/0031-add-cix-vendor-pci-driver.patch \
    file://patches-7.1/0032-pci-cadence-sky1-cix-fix-sky1-cix-vendor-pcie-driver.patch \
    file://patches-7.1/0033-regulator-add-acpi-support.patch \
    file://patches-7.1/0034-pci-cadence-sky1-fix-clk-under-ACPI.patch \
    file://patches-7.1/0035-hda-cix-ipbloq-skip-init-of-verb-table-at-resume.patch \
    file://patches-7.1/0036-arm-smmu-v3-add-suspend-resume-support.patch \
    file://patches-7.1/0037-gpu-panthor-fix-suspend-resume-for-sky1.patch \
    file://patches-7.1/0038-pci-cadence-add-PCI_SKY1_HOST_CIX-for-bsp-driver.patch \
    file://patches-7.1/0039-panthor-set-DPM_FLAG_NO_DIRECT_COMPLETE-for-STR-on-s.patch \
    file://patches-7.1/0040-pmdomain-fix-dev_pm_domain_attach_by_name-for-sky1-m.patch \
    file://patches-7.1/0041-thermal-set-thermal_zone-type-from-firmware-in-acpi_.patch \
    file://patches-7.1/0042-DPTSW-19618-linlon-dp-Set-AFBC-32x8-to-the-highest-p.patch \
    file://patches-7.1/0043-pwm-sky1-check-pwm-state-before-enable-disable-clk-i.patch \
    file://patches-7.1/0044-clocksource-add-sky1-gpt-timer-driver.patch \
    file://patches-7.1/0045-drm-cix-fix-hdmi-str.patch \
    file://patches-7.1/0046-pinctrl-sky1-add-acpi-support.patch \
    file://patches-7.1/0047-add-hym8563-rx8900-rtc-driver.patch \
    file://patches-7.1/0048-arm64-add-model-name-for-Cix-Sky1-Soc.patch \
    file://patches-7.1/0049-add-cix-thermal-ipa-driver.patch \
    file://patches-7.1/0050-add-thermal-IPA-support.patch \
    file://patches-7.1/0051-DPTSW-25537-drm-cix-dptx-HPD-fast-replug-link-train-.patch \
    file://patches-7.1/0052-usb-cdns3-fix-TypeC-hotplug-enumerati-on-failure.patch \
    file://patches-7.1/0053-watchdog-sbsa-Update-the-value-of-the-refresh-regist.patch \
    file://patches-7.1/0054-drm-cix-dptx-trigger-connector-hotplug-on-resume_ear.patch \
    file://patches-7.1/0055-dptx-check-null-pointer-in-trilin_dp_panel_hw_cfg.patch \
    file://patches-7.1/0056-firmware-arm_scmi-mailbox-set-max_rx_timeout_ms-to-3.patch \
    file://patches-7.1/0057-optee-check-system_state-when-probing-at-shutdown.patch \
    file://patches-7.1/0058-ACPI-thermal-bind-devfreq-cooling-devices-via-devfre.patch \
    file://patches-7.1/0059-DPTSW-24991-usb-fix-SError-during-poweroff-by-releas.patch \
    file://patches-7.1/0060-DPTSW-25423-usb-cdns3-sky1-disabled-IRQ-before-disab.patch \
    file://patches-7.1/0061-DPTSW-16421-thermal-Register-the-GPU-Energy-Model-us.patch \
    file://patches-7.1/0062-thermal-ipa-enhance-ipa.patch \
    file://patches-7.1/0063-usb-cdns3-fix-cdnsp-timeout-at-resume.patch \
    file://patches-7.1/0064-add-cix_dst-driver.patch \
    file://patches-7.1/0065-linlondp-fix-build-of-debugfs.patch \
    file://patches-7.1/0066-linlondp-add-missing-headers.patch \
    file://patches-7.1/0067-linlondp-add-api-fix-up-to-6.18.patch \
    file://patches-7.1/0068-linlondp-disable-enable_render-by-default.patch \
    file://patches-7.1/0069-linlondp-set-DRM_FBDEV_DMA_DRIVER_OPS-for-linlondp-k.patch \
    file://patches-7.1/0070-drm-panel-add-fwnode_drm_find_panel.patch \
    file://patches-7.1/0071-gpio-gpio-cadence-fix-crashing-pcie-on-cix-p1-acpi-s.patch \
    file://patches-7.1/0072-drm-linlon-dp-remove-existing-drivers-that-may-own-t.patch \
    file://patches-7.1/0073-firmware-arm_scmi-add-backward-complibility-to-old-f.patch \
    file://patches-7.1/0074-acpi-add-backward-complibility-to-old-firmware-with-.patch \
    file://patches-7.1/9001-clk-cix-migrate-audss-divider-to-determine-rate.patch \
    file://patches-7.1/9002-rtc-rx8900-drop-removed-of_gpio-header.patch \
    file://patches-7.1/9003-drm-cix-update-connector-color-format-enums.patch \
    file://patches-7.1/9004-drm-cix-add-color-format-compat-macros-for-v7.1.patch \
    file://patches-7.1/9005-drm-linlondp-fix-srctree-src-include-path.patch \
    file://patches-7.1/9006-drm-linlondp-migrate-private-obj-init-to-create-state.patch \
    file://patches-7.1/9007-soc-cix-acpi-resource-lookup-resolve-dev_id-by-acpi.patch \
    file://patches-7.1/9008-reset-sky1-restore-acpi-support.patch \
    file://patches-7.1/9009-pmdomain-scmi-perf-defer-fwnode-provider.patch \
    file://patches-7.1/9010-clk-sky1-acpi-fix-acpi-power-management.patch \
    file://patches-7.1/9011-pm-runtime-gate-until-late-initcall.patch \
    file://patches-7.1/9012-pm-runtime-gate-all-callbacks.patch \
    file://patches-7.1/9013-acpi-skip-notifier-on-probe-fail.patch \
    file://patches-7.1/9014-clk-sky1-audss-dont-defer-on-missing-parents.patch \
    file://patches-7.1/9014b-clk-sky1-audss-dont-defer-on-missing-regmap.patch \
"
S = "${WORKDIR}/git"
COMPATIBLE_MACHINE = "(cixmini)"
PROVIDES = "${PN} virtual/kernel"

do_configure:prepend() {
    cd ${S}
    cp ${WORKDIR}/config-7.0.defconfig ${B}/.config
    oe_runmake ARCH=arm64 O=${B} olddefconfig
}

KERNEL_IMAGETYPE = "Image"
KERNEL_DEVICETREE = " \
    cix/sky1-orion-o6.dtb \
"
