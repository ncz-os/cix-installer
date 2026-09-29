#!/usr/bin/env python3
"""
Stage 1 thinning of config.sky1-next per the hardware audit
(~/config-sky1-next-hardware-audit.md on cixmini). Targets the highest-
confidence, zero-ambiguity categories: CAN, MMC/SD/UFS, SATA/SCSI/SAS/PATA/
RAID-HBA, Pinctrl (foreign vendors), MFD (foreign PMICs), DMA/remoteproc/
SoundWire/vendor-clocks (foreign), IIO (discrete sensor chips).

Dry-run by default: prints every line it WOULD change. Pass --apply to
actually write config.sky1-next in place.
"""
import re
import sys

PATH = "config-7.2-lean-msr1-o6n.defconfig"

# Exact symbols that must NEVER be touched, no matter what pattern matches.
PROTECT_EXACT = {
    "CONFIG_PINCTRL", "CONFIG_PINMUX", "CONFIG_PINCONF",
    "CONFIG_GENERIC_PINCTRL_GROUPS", "CONFIG_GENERIC_PINMUX_FUNCTIONS",
    "CONFIG_GENERIC_PINCONF", "CONFIG_PINCTRL_SKY1", "CONFIG_PINCTRL_SKY1_BASE",
    "CONFIG_PINCTRL_SINGLE",  # UNCERTAIN per report -- leave alone this pass
    "CONFIG_MFD_CROS_EC", "CONFIG_MFD_CROS_EC_DEV", "CONFIG_CROS_EC",
    "CONFIG_CROS_EC_I2C", "CONFIG_CROS_EC_UCSI", "CONFIG_UCSI_PMIC_GLINK",
    "CONFIG_KEYBOARD_CROS_EC", "CONFIG_I2C_CROS_EC_TUNNEL",
    "CONFIG_SND_SOC_CROS_EC_CODEC", "CONFIG_CROS_EC_PWM",
    "CONFIG_I2C_MUX_PCA954x",  # UNCERTAIN, board-plausible -- leave alone
    # cros_ec is confirmed real hardware (all 3 board DTS) -- its own
    # integrated sensor-hub IIO drivers are an interface to that real chip,
    # not foreign-SoC cruft. Protect them the same way as the rest of the
    # cros_ec family above.
    "CONFIG_IIO_CROS_EC_SENSORS_CORE", "CONFIG_IIO_CROS_EC_SENSORS",
    "CONFIG_IIO_CROS_EC_LIGHT_PROX", "CONFIG_IIO_CROS_EC_BARO",
    "CONFIG_CIX_MBOX", "CONFIG_CIX_DSP_RPROC", "CONFIG_CIX_DSP",
    "CONFIG_HWSPINLOCK_SKY1", "CONFIG_SKY1_GPT_TIMER",
    "CONFIG_CLK_SKY1_ACPI", "CONFIG_CLK_SKY1_AUDSS",
    "CONFIG_IIO_SCMI", "CONFIG_IIO",  # keep IIO core, only cut leaf chip drivers
    "CONFIG_ARM_SCMI_PROTOCOL", "CONFIG_ARM_SCMI_TRANSPORT_MAILBOX",
    "CONFIG_ARM_SCMI_TRANSPORT_SMC", "CONFIG_ARM_SCMI_TRANSPORT_OPTEE",
    "CONFIG_ARM_PSCI_FW", "CONFIG_ARM_SMCCC_SOC_ID",
}

# (category_label, [vendor-prefix regexes], [explicit exact symbols])
# A line is a CUT candidate if it matches any prefix regex OR is in the
# explicit set, AND is not in PROTECT_EXACT.
STAGE1 = [
    ("CAN bus (zero hardware)", [
        r"^CONFIG_CAN($|_)",
    ], []),

    # UFS removed from cut list: O6N officially supports a pluggable UFS
    # module connector (v1.11+) per Radxa spec sheet -- audit's "zero UFS
    # hardware" claim is contradicted by real product documentation.
    ("SATA/SCSI/SAS/PATA/RAID-HBA (zero hardware, explicit per report)", [], [
        "CONFIG_SATA_AHCI", "CONFIG_SATA_AHCI_PLATFORM", "CONFIG_AHCI_BRCM",
        "CONFIG_AHCI_DWC", "CONFIG_AHCI_CEVA", "CONFIG_AHCI_MVEBU", "CONFIG_AHCI_XGENE",
        "CONFIG_AHCI_QORIQ", "CONFIG_SATA_SIL24", "CONFIG_SATA_RCAR", "CONFIG_SATA_PMP",
        "CONFIG_ATA", "CONFIG_ATA_SFF", "CONFIG_ATA_BMDMA",
        "CONFIG_PATA_PLATFORM", "CONFIG_PATA_OF_PLATFORM",
        "CONFIG_SCSI_SAS_ATTRS", "CONFIG_SCSI_SAS_LIBSAS", "CONFIG_SCSI_SAS_ATA",
        "CONFIG_SCSI_SAS_HOST_SMP", "CONFIG_SCSI_HISI_SAS", "CONFIG_SCSI_HISI_SAS_PCI",
        "CONFIG_MEGARAID_SAS", "CONFIG_SCSI_MPT3SAS",
    ]),

    ("Pinctrl (foreign vendors)", [
        r"^CONFIG_PINCTRL_MTK", r"^CONFIG_PINCTRL_MT\d",
        r"^CONFIG_PINCTRL_MSM", r"^CONFIG_PINCTRL_QCM", r"^CONFIG_PINCTRL_QCS",
        r"^CONFIG_PINCTRL_QDF", r"^CONFIG_PINCTRL_QDU", r"^CONFIG_PINCTRL_SA87",
        r"^CONFIG_PINCTRL_SC7", r"^CONFIG_PINCTRL_SC8", r"^CONFIG_PINCTRL_SDM",
        r"^CONFIG_PINCTRL_SDX", r"^CONFIG_PINCTRL_SM\d", r"^CONFIG_PINCTRL_X1E",
        r"^CONFIG_PINCTRL_LPASS_LPI", r"^CONFIG_PINCTRL_RENESAS", r"^CONFIG_PINCTRL_SH_PFC",
        r"^CONFIG_PINCTRL_PFC_", r"^CONFIG_PFC_R8A", r"^CONFIG_PINCTRL_RZG",
        r"^CONFIG_PINCTRL_RZT", r"^CONFIG_PINCTRL_RZV",
        r"^CONFIG_PINCTRL_SUNXI", r"^CONFIG_PINCTRL_SUN\d",
        r"^CONFIG_PINCTRL_MESON", r"^CONFIG_PINCTRL_AMLOGIC",
        r"^CONFIG_PINCTRL_TEGRA", r"^CONFIG_PINCTRL_MVEBU", r"^CONFIG_PINCTRL_ARMADA",
        r"^CONFIG_PINCTRL_AC5", r"^CONFIG_PINCTRL_SAMSUNG", r"^CONFIG_PINCTRL_EXYNOS",
        r"^CONFIG_PINCTRL_RTD", r"^CONFIG_PINCTRL_ROCKCHIP", r"^CONFIG_PINCTRL_SOPHGO",
        r"^CONFIG_PINCTRL_STM32", r"^CONFIG_PINCTRL_UNIPHIER", r"^CONFIG_PINCTRL_VISCONTI",
        r"^CONFIG_PINCTRL_RP1", r"^CONFIG_PINCTRL_OWL",
        r"^CONFIG_PINCTRL_DA9062", r"^CONFIG_PINCTRL_MAX77620", r"^CONFIG_PINCTRL_RK805",
        r"^CONFIG_PINCTRL_TPS6594", r"^CONFIG_PINCTRL_ZYNQMP",
        r"^CONFIG_PINCTRL_IPROC", r"^CONFIG_PINCTRL_NS2", r"^CONFIG_PINCTRL_BCM",
    ], []),

    ("DMA/remoteproc/SoundWire/vendor-clocks (foreign)", [
        r"^CONFIG_.*_EDMA", r"^CONFIG_.*_QDMA", r"^CONFIG_MTK_HSDMA", r"^CONFIG_MTK_CQDMA",
        r"^CONFIG_QCOM_HIDMA", r"^CONFIG_QCOM_BAM_DMA", r"^CONFIG_RCAR_DMAC",
        r"^CONFIG_STM32_DMA", r"^CONFIG_SUN4I_DMA", r"^CONFIG_SUN6I_DMA",
        r"^CONFIG_TEGRA20_APB_DMA", r"^CONFIG_TEGRA210_ADMA", r"^CONFIG_TI_EDMA",
        r"^CONFIG_K3_UDMA", r"^CONFIG_XILINX_ZYNQMP_DMA",
        r"^CONFIG_QCOM_Q6V5", r"^CONFIG_IMX_REMOTEPROC", r"^CONFIG_ST_REMOTEPROC",
        r"^CONFIG_MTK_SCP",
        r"^CONFIG_SOUNDWIRE_QCOM", r"^CONFIG_SOUNDWIRE_CADENCE",
        r"^CONFIG_COMMON_CLK_MT\d", r"^CONFIG_COMMON_CLK_MESON",
        r"^CONFIG_COMMON_CLK_QCOM", r"^CONFIG_COMMON_CLK_RS9",
        r"^CONFIG_ARCH_R\dA", r"^CONFIG_STARFIVE",
    ], []),

    ("IIO discrete sensor chips (no sensor found on any board)", [
        r"^CONFIG_IIO_[A-Z0-9_]+$",  # any IIO_* leaf, will be filtered by explicit protect list below
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
        for label, patterns, explicit in STAGE1:
            hit = sym in explicit or any(re.match(p, sym) for p in patterns)
            if hit:
                changes.append((i, sym, line.rstrip("\n"), label))
                break

    by_label = {}
    for i, sym, old, label in changes:
        by_label.setdefault(label, []).append(sym)

    print(f"=== Stage 1 dry-run: {len(changes)} symbols would be disabled ===\n")
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
