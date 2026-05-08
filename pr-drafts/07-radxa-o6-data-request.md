# Data request — Radxa Orion O6 working-stack capture

**Audience:** anyone with an Orion O6 currently booted into Radxa's
stock Debian 12 image (NVMe rootfs working).

**Purpose:** we (nclawzero / cix-installer) ship a 6.18.26 LTS kernel
that boots clean on the Cixtech MS-R1 (cixmini, same Sky1 / CP8180
SoC), but on the Orion O6 our `sky1-pcie` driver gets stuck in a probe
loop — Root Complex never trains, NVMe never enumerates, kernel panics
on root mount. Our Yocto kernel was forward-ported from the 6.6 BSP to
6.18 LTS but only validated against MS-R1. We need to identify Radxa's
quirk delta and backport it.

**Context** (what we already know from the failure log):

```
[3.516820] sky1-pcie sky1-pcie.2.auto: RC's dev_sts: 0x00003850
[3.534789] sky1-pcie sky1-pcie.2.auto: root err status =0x0,id = 0x0
... (1900+ identical lines until ring buffer saturates) ...
[3.659635] VFS: Cannot open root device "PARTUUID=...": error -6 (ENXIO)
[3.659687] Kernel panic - not syncing: VFS: Unable to mount root fs
```

Failing kernel: `6.18.26-cix-sky1-lts`. ACPI tables show `OEMID=RADXA`
`OEMTABLEID=ORIONO6` SSDT.

## What we need

Boot O6 into Radxa's Debian 12 stock image (NVMe working). Then:

```sh
# Save into a tarball: o6-radxa-capture-$(date +%Y%m%d).tar.gz
mkdir -p /tmp/o6cap && cd /tmp/o6cap

# 1. Kernel + cmdline
uname -a > uname.txt
cat /proc/cmdline > cmdline.txt
dpkg -l 'linux-image-*' > kernel-pkg.txt

# 2. Full dmesg from boot
dmesg > dmesg.txt
journalctl -b -k > journalctl-kernel.txt

# 3. PCIe topology (the load-bearing one)
sudo lspci -vvv > lspci-vvv.txt
sudo lspci -nn -t > lspci-tree.txt
cat /proc/iomem | grep -iE 'pci|sky1' > iomem-pci.txt
cat /proc/interrupts > interrupts.txt

# 4. PCIe + PHY drivers loaded
ls /sys/bus/platform/drivers/sky1-pcie/ > pcie-bound.txt
ls /sys/bus/platform/drivers/cix-pcie-phy/ > phy-bound.txt
find /sys/devices -iname 'CIXH2020*' -o -iname 'CIXH2023*' | head -50 > cix-acpi-paths.txt

# 5. ACPI tables (this is the crown jewel for our diff)
sudo cp -a /sys/firmware/acpi/tables /tmp/o6cap/acpi-tables
# Particularly want: SSDT*, DSDT, IORT, MCFG

# 6. NVMe + storage
ls -la /dev/nvme* > nvme-devs.txt
sudo nvme list > nvme-list.txt
lsblk -o NAME,KNAME,TYPE,SIZE,FSTYPE,UUID,PARTUUID > lsblk.txt

# 7. Bootloader / firmware level
sudo dmidecode -t bios > dmidecode-bios.txt
sudo dmidecode -t system > dmidecode-system.txt
ls /sys/firmware/efi/efivars/ | head > efivars-list.txt

# Bundle
cd /tmp && tar czf o6-radxa-capture-$(date +%Y%m%d).tar.gz o6cap/
ls -la o6-radxa-capture-*.tar.gz
```

Send back the tarball (or paste the contents of `dmesg.txt` and
`lspci-vvv.txt` if the tarball is awkward — those are the two
load-bearing files).

## Why each file matters

| File | What we'll do with it |
|---|---|
| `dmesg.txt` | Compare the successful sky1-pcie probe sequence against our spam loop. Identify what timing/order/quirk we're missing. |
| `lspci-vvv.txt` | See which devices ENUMERATE behind the RCs (NVMe, GPU slot, USB controller, etc.). Capabilities + LnkSta show what link speed/width trained. |
| `cmdline.txt` | Any kernel cmdline tweaks Radxa applies that we don't (`pcie_aspm=off`, etc.). |
| `acpi-tables/` | The ASL we can `iasl -d` and diff against MS-R1's. The PCIe RC `_HID(CIXH2020)` device blocks may declare different power/clock resources. |
| `iomem-pci.txt` | Confirm where PCIe Configuration Space + BARs land in physical address space. |
| `kernel-pkg.txt` | The kernel **version** Radxa ships for O6 production. Our anchor for finding the patch series. |

## Bonus questions

If you happen to know:

1. Which **Radxa kernel branch** is used to build your image? (e.g.
   `radxa/linux:linux-6.6-orion-rkr` or similar.)
2. Which **EDK2 commit** is on this O6 right now? (BIOS version /
   build date from `dmidecode -t bios`.)
3. Is there a **changelog** or release-notes page describing what
   Radxa patches on top of the Cixtech 6.6 BSP?

## We're not asking you to debug

We just want the **passing-state evidence**. The diff between our
failing kernel and Radxa's working one is what we'll work on locally.
Capturing the above is ~5 minutes of typing on a working board.

Thanks!

— Jason / nclawzero
