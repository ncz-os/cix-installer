#!/usr/bin/env python3
"""
Stage 2 thinning of config.sky1-next -- continuation of Stage 1, now
informed by real Radxa spec sheets for all four boards (O6, O6N, MS-R1,
OrangePi 6+) cross-checked against the DTS-based audit. Targets categories
with zero evidence across BOTH sources: MFD/PMIC, vendor thermal zones,
vendor watchdogs, non-8250 vendor serial UARTs, vendor I2C/SPI host
controllers, foreign SoC-driver + PM-domain menu groups, remaining foreign
DMA/IRQ/PHY-subsystem/Android/HW-tracing.

Explicitly NOT touched this stage (real hardware confirmed via spec sheets,
NOT just DTS -- DTS search already proven to miss real slot-based/module
hardware twice this session): MMC/SD (OrangePi 6+ TF slot), UFS (O6N V1.11),
WiFi/BT chip drivers (M.2 module on 3 boards), WWAN (O6N M.2 B-key cellular),
Camera/ISP (confirmed on 3 board specs + DTS), DRM panels/bridges (needs its
own careful pass -- OrangePi 6+ uses a real Parade PS185 HDMI bridge chip).

Dry-run by default: prints every line it WOULD change. Pass --apply to
actually write config.sky1-next in place.
"""
import re
import sys

PATH = "config-7.2-lean-msr1-o6n.defconfig"

PROTECT_EXACT = {
    "CONFIG_MFD_CORE",  # generic infra, needed by cros_ec MFD driver too
    "CONFIG_MFD_CROS_EC", "CONFIG_MFD_CROS_EC_DEV", "CONFIG_CROS_EC",
    "CONFIG_CROS_EC_I2C", "CONFIG_CROS_EC_UCSI", "CONFIG_UCSI_PMIC_GLINK",
    "CONFIG_KEYBOARD_CROS_EC", "CONFIG_I2C_CROS_EC_TUNNEL",
    "CONFIG_SND_SOC_CROS_EC_CODEC", "CONFIG_CROS_EC_PWM",
    "CONFIG_I2C_MUX_PCA954x",
    "CONFIG_CIX_MBOX", "CONFIG_CIX_DSP_RPROC", "CONFIG_CIX_DSP",
    "CONFIG_HWSPINLOCK_SKY1", "CONFIG_SKY1_GPT_TIMER",
    "CONFIG_CLK_SKY1_ACPI", "CONFIG_CLK_SKY1_AUDSS",
    "CONFIG_SKY1_WATCHDOG", "CONFIG_SENSORS_CIX_FAN",
    "CONFIG_SERIAL_8250", "CONFIG_SERIAL_AMBA_PL011", "CONFIG_SERIAL_AMBA_PL011_CONSOLE",
    "CONFIG_I2C_CADENCE", "CONFIG_SPI_CADENCE_QUADSPI",
    "CONFIG_CIX_SKY1_SOCINFO", "CONFIG_CIX_DDR_LP", "CONFIG_CIX_ACPI_RESOURCE_LOOKUP",
    "CONFIG_CIX_ACPI_USB_SCAN", "CONFIG_CIX_BUS_PERF", "CONFIG_CIX_CPU_IPA",
    "CONFIG_SKY1_PDC", "CONFIG_RESET_SKY1", "CONFIG_RESET_SKY1_AUDSS",
    "CONFIG_PWM_SKY1", "CONFIG_NVMEM_SKY1",
    "CONFIG_PHY_CIX_PCIE", "CONFIG_PHY_CIX_USB2", "CONFIG_PHY_CIX_USB3", "CONFIG_PHY_CIX_USBDP",
    "CONFIG_USB_CDNSP_SKY1", "CONFIG_TYPEC_RTS5453", "CONFIG_TYPEC_DP_ALTMODE",
    "CONFIG_USB_ROLE_SWITCH",
    # DRM bridge -- real Parade chip on OrangePi 6+, not touched this stage anyway
    "CONFIG_DRM_PARADE_PS8640", "CONFIG_DRM_ANALOGIX_ANX7625",
    # ARM SMMU / IOMMU core -- real, Sky1 has SMMU per sky1.dtsi
    "CONFIG_ARM_SMMU", "CONFIG_ARM_SMMU_V3",
    # CEC framework -- real, used by trilin DP driver for CEC-over-DP-AUX
    # (patch 0032, confirmed in the original audit's DRM section). This
    # sits inside the MFD line-range (5170-5507) and would otherwise get
    # wrongly swept up by the line-range cut.
    "CONFIG_CEC_CORE", "CONFIG_CEC_NOTIFIER",
}

STAGE2 = [
    ("Vendor thermal zone drivers (foreign)", [
        r"^CONFIG_MTK_THERMAL", r"^CONFIG_BRCMSTB_THERMAL", r"^CONFIG_BCM2711_THERMAL",
        r"^CONFIG_BCM2835_THERMAL", r"^CONFIG_EXYNOS_THERMAL", r"^CONFIG_STI_THERMAL",
        r"^CONFIG_STM_THERMAL", r"^CONFIG_TEGRA_SOCTHERM", r"^CONFIG_TEGRA_BPMP_THERMAL",
        r"^CONFIG_QCOM_TSENS", r"^CONFIG_QCOM_SPMI_TEMP_ALARM",
    ], []),

    ("Vendor watchdog drivers (foreign)", [
        r"^CONFIG_MESON_WATCHDOG", r"^CONFIG_MEDIATEK_WATCHDOG", r"^CONFIG_QCOM_WDT",
        r"^CONFIG_S3C2410_WATCHDOG", r"^CONFIG_RENESAS_WDT", r"^CONFIG_RENESAS_RZAWDT",
        r"^CONFIG_RENESAS_RZN1WDT", r"^CONFIG_RENESAS_RZV2HWDT", r"^CONFIG_IMX2_WDT",
        r"^CONFIG_IMX_SC_WDT", r"^CONFIG_IMX7ULP_WDT", r"^CONFIG_TEGRA_WATCHDOG",
        r"^CONFIG_STM32_WATCHDOG", r"^CONFIG_SUNXI_WATCHDOG", r"^CONFIG_BCM2835_WDT",
        r"^CONFIG_BCM7038_WDT", r"^CONFIG_BCM_KONA_WDT", r"^CONFIG_ARMADA_37XX_WATCHDOG",
        r"^CONFIG_ORION_WATCHDOG", r"^CONFIG_UNIPHIER_WATCHDOG", r"^CONFIG_RTD119X_WATCHDOG",
    ], []),

    ("Vendor non-8250 serial UART drivers (foreign)", [
        r"^CONFIG_SERIAL_MESON", r"^CONFIG_SERIAL_SAMSUNG", r"^CONFIG_SERIAL_TEGRA",
        r"^CONFIG_SERIAL_IMX", r"^CONFIG_SERIAL_SH_SCI", r"^CONFIG_SERIAL_RSCI",
        r"^CONFIG_SERIAL_MSM", r"^CONFIG_SERIAL_QCOM_GENI", r"^CONFIG_SERIAL_BCM63XX",
        r"^CONFIG_SERIAL_XILINX_PS_UART", r"^CONFIG_SERIAL_FSL_LPUART",
        r"^CONFIG_SERIAL_FSL_LINFLEXUART", r"^CONFIG_SERIAL_STM32",
        r"^CONFIG_SERIAL_MVEBU_UART", r"^CONFIG_SERIAL_OWL",
    ], []),

    ("Vendor I2C host controllers (foreign)", [
        r"^CONFIG_I2C_BCM2835", r"^CONFIG_I2C_BCM_IPROC", r"^CONFIG_I2C_BRCMSTB",
        r"^CONFIG_I2C_DESIGNWARE", r"^CONFIG_I2C_EXYNOS5", r"^CONFIG_I2C_IMX",
        r"^CONFIG_I2C_LPI2C", r"^CONFIG_I2C_MESON", r"^CONFIG_I2C_MT65XX",
        r"^CONFIG_I2C_MV64XXX", r"^CONFIG_I2C_PXA", r"^CONFIG_I2C_QCOM_CCI",
        r"^CONFIG_I2C_QCOM_GENI", r"^CONFIG_I2C_QUP", r"^CONFIG_I2C_RIIC",
        r"^CONFIG_I2C_RZV2M", r"^CONFIG_I2C_RK3X", r"^CONFIG_I2C_S3C2410",
        r"^CONFIG_I2C_SH_MOBILE", r"^CONFIG_I2C_TEGRA", r"^CONFIG_I2C_UNIPHIER",
        r"^CONFIG_I2C_RCAR",
    ], []),

    ("Vendor SPI host controllers (foreign)", [
        r"^CONFIG_SPI_ARMADA_3700", r"^CONFIG_SPI_BCM2835", r"^CONFIG_SPI_BCM_QSPI",
        r"^CONFIG_SPI_DESIGNWARE", r"^CONFIG_SPI_DW_", r"^CONFIG_SPI_FSL_LPSPI",
        r"^CONFIG_SPI_FSL_QUADSPI", r"^CONFIG_SPI_FSL_DSPI", r"^CONFIG_SPI_NXP_FLEXSPI",
        r"^CONFIG_SPI_IMX", r"^CONFIG_SPI_MESON_SPICC", r"^CONFIG_SPI_MESON_SPIFC",
        r"^CONFIG_SPI_MT65XX", r"^CONFIG_SPI_MTK_NOR", r"^CONFIG_SPI_OMAP24XX",
        r"^CONFIG_SPI_ORION", r"^CONFIG_SPI_PL022", r"^CONFIG_SPI_ROCKCHIP",
        r"^CONFIG_SPI_RPCIF", r"^CONFIG_SPI_RSPI", r"^CONFIG_SPI_RZV2H",
        r"^CONFIG_SPI_RZV2M", r"^CONFIG_SPI_QCOM_QSPI", r"^CONFIG_SPI_QCOM_GENI",
        r"^CONFIG_SPI_QUP", r"^CONFIG_SPI_S3C64XX", r"^CONFIG_SPI_SH_MSIOF",
        r"^CONFIG_SPI_STM32", r"^CONFIG_SPI_SUN6I", r"^CONFIG_SPI_TEGRA",
    ], []),

    ("Foreign SoC-driver + PM-domain menu groups", [
        r"^CONFIG_AMLOGIC_", r"^CONFIG_MESON_", r"^CONFIG_APPLE_",
        r"^CONFIG_BCM2835_", r"^CONFIG_RASPBERRYPI_", r"^CONFIG_SOC_BRCMSTB",
        r"^CONFIG_ARCH_BCM", r"^CONFIG_FSL_", r"^CONFIG_QORIQ_",
        r"^CONFIG_FUJITSU_", r"^CONFIG_HISILICON_", r"^CONFIG_HISI_",
        r"^CONFIG_SOC_IMX", r"^CONFIG_IMX8M_", r"^CONFIG_IMX9_",
        r"^CONFIG_MTK_", r"^CONFIG_SOC_MEDIATEK",
        r"^CONFIG_QCOM_", r"^CONFIG_SOC_QCOM",
        r"^CONFIG_SOPHGO_", r"^CONFIG_XILINX_", r"^CONFIG_ZYNQMP_",
        r"^CONFIG_TEGRA_PMC", r"^CONFIG_SOC_TEGRA", r"^CONFIG_ARCH_TEGRA",
        r"^CONFIG_RENESAS_", r"^CONFIG_ROCKCHIP_", r"^CONFIG_SOC_ROCKCHIP",
        r"^CONFIG_SAMSUNG_", r"^CONFIG_EXYNOS_",
    ], []),

    ("Remaining foreign DMA/SoundWire/PHY/IRQ (not caught by Stage 1)", [
        r"^CONFIG_PHY_BCM", r"^CONFIG_PHY_QCOM", r"^CONFIG_PHY_MTK",
        r"^CONFIG_PHY_ROCKCHIP", r"^CONFIG_PHY_TEGRA", r"^CONFIG_PHY_RENESAS",
        r"^CONFIG_PHY_MESON", r"^CONFIG_PHY_SAMSUNG", r"^CONFIG_PHY_EXYNOS",
        r"^CONFIG_SOUNDWIRE_", r"^CONFIG_ANDROID_BINDER",
        r"^CONFIG_COMMON_CLK_SAMSUNG", r"^CONFIG_COMMON_CLK_ROCKCHIP",
        r"^CONFIG_COMMON_CLK_IMX", r"^CONFIG_COMMON_CLK_BCM",
    ], []),
]

def load(path):
    with open(path) as f:
        return f.readlines()

def symbol_of(line):
    m = re.match(r"^(CONFIG_[A-Za-z0-9_]+)=(y|m)\s*$", line)
    if m:
        return m.group(1), True
    m = re.match(r"^# (CONFIG_[A-Za-z0-9_]+) is not set\s*$", line)
    if m:
        return m.group(1), False
    return None, None

def main():
    apply_changes = "--apply" in sys.argv
    lines = load(PATH)
    changes = []

    # MFD section: precise line-range cut (5170-5507 per audit citation),
    # everything enabled in that range except the protected cros_ec/core set.
    for i in range(5169, 5507):  # 0-indexed, inclusive of line 5170..5507
        if i >= len(lines):
            break
        sym, enabled = symbol_of(lines[i])
        if sym and enabled and sym not in PROTECT_EXACT:
            changes.append((i, sym, lines[i].rstrip("\n"), "MFD/PMIC (line-range 5170-5507)"))

    for i, line in enumerate(lines):
        sym, enabled = symbol_of(line)
        if not sym or not enabled:
            continue
        if sym in PROTECT_EXACT:
            continue
        if any(c[0] == i for c in changes):
            continue  # already caught by MFD range
        for label, patterns, explicit in STAGE2:
            hit = sym in explicit or any(re.match(p, sym) for p in patterns)
            if hit:
                changes.append((i, sym, line.rstrip("\n"), label))
                break

    by_label = {}
    for i, sym, old, label in changes:
        by_label.setdefault(label, []).append(sym)

    print(f"=== Stage 2 dry-run: {len(changes)} symbols would be disabled ===\n")
    for label, syms in by_label.items():
        print(f"[{label}] {len(syms)} symbols:")
        print("  " + ", ".join(syms))
        print()

    if apply_changes:
        for i, sym, old, label in changes:
            lines[i] = f"# {sym} is not set\n"
        with open(PATH, "w") as f:
            f.writelines(lines)
        print(f"APPLIED: {len(changes)} lines changed in {PATH}")
    else:
        print("(dry run only -- pass --apply to write changes)")

if __name__ == "__main__":
    main()
