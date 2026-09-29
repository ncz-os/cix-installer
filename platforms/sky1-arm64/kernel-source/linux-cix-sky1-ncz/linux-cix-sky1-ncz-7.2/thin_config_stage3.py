#!/usr/bin/env python3
"""
Stage 3 thinning of config.sky1-next -- the big single-file wins that were
flagged as "already confirmed" cuts from session start but never actually
applied: XFS/NTFS3/CIFS/NFSD, Mellanox/Broadcom/Amazon/Microsemi NIC
silicon, IP_VS/BONDING/VXLAN/DSA software networking features, NXP CAAM +
ARM CryptoCell crypto. Plus continuation of remaining networking (foreign
vendor MACs/PHYs/USB dongles), foreign Sound platforms, foreign SoC-driver
remainder, foreign firmware misc, foreign watchdog/thermal remainder,
Android, foreign HW-tracing.

Explicitly NOT touched: WiFi/BT chip drivers (kept broad -- common M.2
module vendors: Intel, Realtek, MediaTek, Qualcomm-Atheros, Broadcom are
all plausible purchasable M.2 WiFi/BT modules for O6/O6N/OrangePi6+, can't
narrow to one), WWAN (O6N M.2 B-key), Camera/ISP core + CIX camera (real),
DRM CIX + Parade PS185 (real, OrangePi6+), MMC/SD (OrangePi6+ TF slot),
UFS (O6N V1.11), generic USB/HID peripheral classes, CEC framework.

Dry-run by default. Pass --apply to write config.sky1-next in place.
"""
import re
import sys

PATH = "config-7.2-lean-msr1-o6n.defconfig"

PROTECT_EXACT = {
    "CONFIG_MFD_CORE", "CONFIG_MFD_CROS_EC", "CONFIG_MFD_CROS_EC_DEV", "CONFIG_CROS_EC",
    "CONFIG_CROS_EC_I2C", "CONFIG_CROS_EC_UCSI", "CONFIG_UCSI_PMIC_GLINK",
    "CONFIG_KEYBOARD_CROS_EC", "CONFIG_I2C_CROS_EC_TUNNEL",
    "CONFIG_SND_SOC_CROS_EC_CODEC", "CONFIG_CROS_EC_PWM", "CONFIG_I2C_MUX_PCA954x",
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
    "CONFIG_USB_ROLE_SWITCH", "CONFIG_ARM_SMMU", "CONFIG_ARM_SMMU_V3",
    "CONFIG_CEC_CORE", "CONFIG_CEC_NOTIFIER",
    # DRM: real CIX + real OrangePi6+ Parade bridge
    "CONFIG_DRM_CIX", "CONFIG_DRM_CIX_VIRTUAL", "CONFIG_DRM_TRILIN_DP_CIX",
    "CONFIG_DRM_CIX_EDP_PANEL", "CONFIG_DRM_PARADE_PS8640", "CONFIG_DRM_ANALOGIX_ANX7625",
    "CONFIG_DRM_SIMPLEDRM",  # UNCERTAIN, early-boot fallback fb, leave alone
    # Media/camera: real CIX ISP + generic core
    "CONFIG_MEDIA_SUPPORT", "CONFIG_MEDIA_CONTROLLER", "CONFIG_VIDEO_DEV",
    "CONFIG_VIDEO_V4L2_I2C", "CONFIG_VIDEO_V4L2_SUBDEV_API", "CONFIG_MEDIA_CEC_SUPPORT",
    # Networking core kept broad -- WiFi/BT/WWAN module reasoning
    "CONFIG_WIRELESS", "CONFIG_CFG80211", "CONFIG_MAC80211", "CONFIG_RFKILL",
    "CONFIG_RFKILL_GPIO", "CONFIG_BT_HCIBTUSB", "CONFIG_BT_L2CAP",
    "CONFIG_NFC", "CONFIG_NFC_NCI",
    "CONFIG_WWAN", "CONFIG_MHI_WWAN_CTRL", "CONFIG_MHI_WWAN_MBIM", "CONFIG_MHI_NET",
    # MMC/UFS -- real hardware, keep entirely (see task history)
    "CONFIG_MMC",
    # R8169 -- real, live-confirmed ethernet on cixmini/O6N
    "CONFIG_R8169",
    # Realtek/generic USB ethernet -- plausible common USB-C dock/dongle NICs
    "CONFIG_USB_RTL8152", "CONFIG_USB_RTL8153_ECM",
}

STAGE3 = [
    ("Already-confirmed filesystem cruft (never actually applied)", [], [
        "CONFIG_XFS_FS", "CONFIG_NTFS3_FS", "CONFIG_NFSD", "CONFIG_NFSD_V4",
        "CONFIG_NFSD_LEGACY_CLIENT_TRACKING", "CONFIG_CIFS", "CONFIG_CIFS_DFS_UPCALL",
        "CONFIG_CIFS_UPCALL", "CONFIG_CIFS_XATTR",
    ]),

    ("Already-confirmed networking software features (never actually applied)", [], [
        "CONFIG_IP_VS", "CONFIG_IP_VS_TAB_BITS", "CONFIG_IP_VS_SH_TAB_BITS",
        "CONFIG_IP_VS_MH_TAB_INDEX", "CONFIG_BONDING", "CONFIG_VXLAN",
    ]),

    ("Already-confirmed foreign NIC silicon (never actually applied)", [], [
        "CONFIG_MLX4_EN", "CONFIG_MLX4_CORE", "CONFIG_MLX4_DEBUG", "CONFIG_MLX4_CORE_GEN2",
        "CONFIG_MLX5_CORE", "CONFIG_MLX5_CORE_EN", "CONFIG_MLX5_EN_ARFS", "CONFIG_MLX5_EN_RXNFC",
        "CONFIG_MLX5_MPFS", "CONFIG_MLX5_ESWITCH", "CONFIG_MLX5_BRIDGE",
        "CONFIG_MLX5_SW_STEERING", "CONFIG_MLX5_HW_STEERING",
        "CONFIG_BNX2X", "CONFIG_BNX2X_SRIOV", "CONFIG_ENA_ETHERNET",
        "CONFIG_MSCC_OCELOT_SWITCH_LIB",
    ]),

    ("Already-confirmed foreign crypto (never actually applied)", [], [
        "CONFIG_CRYPTO_DEV_FSL_CAAM_COMMON", "CONFIG_CRYPTO_DEV_FSL_CAAM_CRYPTO_API_DESC",
        "CONFIG_CRYPTO_DEV_FSL_CAAM_AHASH_API_DESC", "CONFIG_CRYPTO_DEV_FSL_CAAM",
        "CONFIG_CRYPTO_DEV_FSL_CAAM_JR", "CONFIG_CRYPTO_DEV_FSL_CAAM_RINGSIZE",
        "CONFIG_CRYPTO_DEV_FSL_CAAM_CRYPTO_API", "CONFIG_CRYPTO_DEV_FSL_CAAM_CRYPTO_API_QI",
        "CONFIG_CRYPTO_DEV_FSL_CAAM_AHASH_API", "CONFIG_CRYPTO_DEV_FSL_CAAM_PKC_API",
        "CONFIG_CRYPTO_DEV_FSL_CAAM_RNG_API", "CONFIG_CRYPTO_DEV_FSL_CAAM_PRNG_API",
        "CONFIG_CRYPTO_DEV_CCREE",
    ]),

    ("Foreign DSA switch chips + remaining foreign MACs", [
        r"^CONFIG_B53", r"^CONFIG_NET_DSA_BCM_SF2", r"^CONFIG_NET_DSA_MSCC",
        r"^CONFIG_E1000", r"^CONFIG_IGB", r"^CONFIG_IGBVF", r"^CONFIG_AMD_XGBE",
        r"^CONFIG_BCMGENET", r"^CONFIG_BGMAC", r"^CONFIG_SYSTEMPORT", r"^CONFIG_BCMASP",
        r"^CONFIG_THUNDER_NIC", r"^CONFIG_BGX", r"^CONFIG_RGX",
        r"^CONFIG_HIX5HD2_GMAC", r"^CONFIG_HNS", r"^CONFIG_MVNETA", r"^CONFIG_MVPP2",
        r"^CONFIG_MVMDIO", r"^CONFIG_SKY2",
        r"^CONFIG_NET_MEDIATEK_STAR_EMAC", r"^CONFIG_QCOM_EMAC", r"^CONFIG_RMNET",
        r"^CONFIG_SH_ETH", r"^CONFIG_RAVB", r"^CONFIG_RENESAS_ETHER_SWITCH", r"^CONFIG_RTSN",
        r"^CONFIG_SNI_AVE", r"^CONFIG_SNI_NETSEC",
        r"^CONFIG_TI_K3_AM65", r"^CONFIG_TI_ICSSG", r"^CONFIG_TI_ICSS_IEP", r"^CONFIG_TI_DAVINCI_MDIO",
        r"^CONFIG_FEC$", r"^CONFIG_FSL_FMAN", r"^CONFIG_FSL_XGMAC_MDIO",
        r"^CONFIG_FSL_DPAA", r"^CONFIG_FSL_ENETC", r"^CONFIG_NXP_ENETC",
        r"^CONFIG_STMMAC_ETH", r"^CONFIG_STMMAC_PLATFORM", r"^CONFIG_DWMAC_",
    ], []),

    ("Foreign MII/USB PHY vendor drivers", [
        r"^CONFIG_MESON_GXL_PHY", r"^CONFIG_AQUANTIA_PHY", r"^CONFIG_AX88796B_PHY",
        r"^CONFIG_BROADCOM_PHY", r"^CONFIG_BCM54140_PHY", r"^CONFIG_BCM7XXX_PHY",
        r"^CONFIG_BCM_NET_PHYLIB", r"^CONFIG_MARVELL_PHY", r"^CONFIG_MARVELL_10G_PHY",
        r"^CONFIG_MARVELL_88Q2XXX_PHY", r"^CONFIG_MICREL_PHY", r"^CONFIG_MICROCHIP_PHY",
        r"^CONFIG_MICROSEMI_PHY", r"^CONFIG_AT803X_PHY", r"^CONFIG_ROCKCHIP_PHY",
        r"^CONFIG_SMSC_PHY", r"^CONFIG_DP83867_PHY", r"^CONFIG_DP83869_PHY",
        r"^CONFIG_DP83TD510_PHY", r"^CONFIG_VITESSE_PHY", r"^CONFIG_PCS_RZN1_MIIC",
    ], []),

    ("Foreign USB Ethernet dongle chips (not RTL8152/8153)", [
        r"^CONFIG_USB_PEGASUS", r"^CONFIG_USB_RTL8150", r"^CONFIG_USB_LAN78XX",
        r"^CONFIG_USB_NET_AX", r"^CONFIG_USB_NET_DM9601", r"^CONFIG_USB_NET_SR9800",
        r"^CONFIG_USB_NET_SMSC", r"^CONFIG_USB_NET_NET1080", r"^CONFIG_USB_NET_PLUSB",
        r"^CONFIG_USB_NET_MCS7830", r"^CONFIG_USB_NET_ZAURUS",
        r"^CONFIG_USB_BELKIN", r"^CONFIG_USB_ARMLINUX",
    ], []),

    ("BT/WiFi/NFC chip drivers for silicon not on any board (kept core+common modules)", [
        r"^CONFIG_BT_QCOMSMD", r"^CONFIG_BT_HCIRSI", r"^CONFIG_BT_NXPUART",
        r"^CONFIG_WCN36XX", r"^CONFIG_NFC_S3FWRN5",
    ], []),

    ("Foreign Sound platform/DSP stacks", [
        r"^CONFIG_SND_SOC_FSL_", r"^CONFIG_SND_SOC_IMX", r"^CONFIG_SND_IMX_SOC",
        r"^CONFIG_SND_SOC_MEDIATEK", r"^CONFIG_SND_SOC_MT\d",
        r"^CONFIG_SND_MESON_", r"^CONFIG_SND_SOC_QCOM", r"^CONFIG_SND_SOC_LPASS",
        r"^CONFIG_SND_SOC_QDSP6", r"^CONFIG_SND_SOC_APQ8016",
        r"^CONFIG_SND_SOC_MSM8996", r"^CONFIG_SND_SOC_SDM845", r"^CONFIG_SND_SOC_SM8250",
        r"^CONFIG_SND_SOC_SC7180", r"^CONFIG_SND_SOC_SC7280", r"^CONFIG_SND_SOC_SC8280XP",
        r"^CONFIG_SND_SOC_X1E80100", r"^CONFIG_SND_SOC_RCAR", r"^CONFIG_SND_SOC_MSIOF",
        r"^CONFIG_SND_SOC_RZ", r"^CONFIG_SND_SOC_ROCKCHIP", r"^CONFIG_SND_SOC_RK3399_GRU",
        r"^CONFIG_SND_SOC_SAMSUNG", r"^CONFIG_SND_SUN8I_CODEC", r"^CONFIG_SND_SUN50I_CODEC",
        r"^CONFIG_SND_SUN4I_", r"^CONFIG_SND_SOC_TEGRA",
        r"^CONFIG_SND_SOC_TI_", r"^CONFIG_SND_SOC_DAVINCI_MCASP", r"^CONFIG_SND_SOC_J721E_EVM",
        r"^CONFIG_SND_SOC_SOF_MTK", r"^CONFIG_SND_SOC_SOF_XTENSA",
        # discrete codec chips (no board reference)
        r"^CONFIG_SND_SOC_WM8", r"^CONFIG_SND_SOC_AK46", r"^CONFIG_SND_SOC_DA72",
        r"^CONFIG_SND_SOC_ES7", r"^CONFIG_SND_SOC_ES8",
    ], []),

    ("Foreign camera/ISP/DVB/TV drivers", [
        r"^CONFIG_VIDEO_ALLEGRO", r"^CONFIG_VIDEO_AMLOGIC", r"^CONFIG_VIDEO_AMPHION",
        r"^CONFIG_VIDEO_ASPEED", r"^CONFIG_VIDEO_ATMEL", r"^CONFIG_VIDEO_CADENCE",
        r"^CONFIG_VIDEO_CODA", r"^CONFIG_VIDEO_IPU3", r"^CONFIG_VIDEO_MARVELL",
        r"^CONFIG_VIDEO_MEDIATEK", r"^CONFIG_VIDEO_MICROCHIP", r"^CONFIG_VIDEO_NUVOTON",
        r"^CONFIG_VIDEO_TEGRA", r"^CONFIG_VIDEO_QCOM", r"^CONFIG_VIDEO_RASPBERRYPI",
        r"^CONFIG_VIDEO_RENESAS", r"^CONFIG_VIDEO_ROCKCHIP", r"^CONFIG_VIDEO_SAMSUNG",
        r"^CONFIG_VIDEO_STM", r"^CONFIG_VIDEO_SUN", r"^CONFIG_VIDEO_TI_", r"^CONFIG_VIDEO_XILINX",
        r"^CONFIG_DVB_", r"^CONFIG_MEDIA_TUNER", r"^CONFIG_MEDIA_SDR_SUPPORT",
        r"^CONFIG_MEDIA_ANALOG_TV_SUPPORT", r"^CONFIG_MEDIA_DIGITAL_TV_SUPPORT",
        r"^CONFIG_USB_.*_DVB", r"^CONFIG_CEC_NXP_TDA9950", r"^CONFIG_CEC_MESON_G12A_AO",
    ], []),

    ("Foreign firmware/EFI/TEE misc", [
        r"^CONFIG_IMX_SCMI", r"^CONFIG_RASPBERRYPI_FIRMWARE", r"^CONFIG_INTEL_STRATIX10",
        r"^CONFIG_MTK_ADSP_IPC", r"^CONFIG_TI_SCI_PROTOCOL",
        r"^CONFIG_GOOGLE_FIRMWARE", r"^CONFIG_GOOGLE_CBMEM", r"^CONFIG_GOOGLE_COREBOOT",
        r"^CONFIG_QCOM_SCM", r"^CONFIG_QCOM_TZMEM", r"^CONFIG_QCOM_QSEECOM",
        r"^CONFIG_EXYNOS_ACPM", r"^CONFIG_TEGRA_IVC", r"^CONFIG_TEGRA_BPMP",
        r"^CONFIG_ZYNQMP_FIRMWARE", r"^CONFIG_GNSS",
    ], []),

    ("Remaining vendor watchdog/thermal not caught earlier", [
        r"^CONFIG_ARMADA_37XX_WATCHDOG", r"^CONFIG_ORION_WATCHDOG",
        r"^CONFIG_UNIPHIER_WATCHDOG", r"^CONFIG_RTD119X_WATCHDOG",
        r"^CONFIG_BCM_KONA_WDT", r"^CONFIG_IMX2_WDT", r"^CONFIG_IMX_SC_WDT",
        r"^CONFIG_IMX7ULP_WDT", r"^CONFIG_STI_THERMAL", r"^CONFIG_QCOM_TSENS",
    ], []),

    ("Android-specific drivers (NCZ-OS is not Android)", [
        r"^CONFIG_ANDROID_BINDER",
    ], []),

    ("Foreign HW-tracing (per-vendor CoreSight glue)", [
        r"^CONFIG_CORESIGHT_SOURCE_ETM4X_TEGRA", r"^CONFIG_CORESIGHT_QCOM",
        r"^CONFIG_ULTRASOC_SMB",
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
    for i, line in enumerate(lines):
        sym, enabled = symbol_of(line)
        if not sym or not enabled:
            continue
        if sym in PROTECT_EXACT:
            continue
        for label, patterns, explicit in STAGE3:
            hit = sym in explicit or any(re.match(p, sym) for p in patterns)
            if hit:
                changes.append((i, sym, line.rstrip("\n"), label))
                break

    by_label = {}
    for i, sym, old, label in changes:
        by_label.setdefault(label, []).append(sym)

    print(f"=== Stage 3 dry-run: {len(changes)} symbols would be disabled ===\n")
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
