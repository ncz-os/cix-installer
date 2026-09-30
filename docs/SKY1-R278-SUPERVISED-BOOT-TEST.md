# Sky1 r278 (7.3.0-rc5) supervised boot test sheet: O6N

> **Superseded by `docs/SKY1-R279-SUPERVISED-BOOT-TEST.md`.** The edge pointer
> now names r279, which carries the linlon-dp re-aim, native PCIe, the
> runtime-PM gate and uncompressed modules. Keep this sheet only to test r278
> itself.

Operator-only. Nothing here is automated, and no agent reboots, flashes, or
repartitions the O6N (.3) or MS-R1 (.66). Run each step at the console with
the serial console (`ttyAMA0`) attached and logging.

- **Kernel under test:** `r278-7.3.0-rc5-sky1-ncz-20260927` in ARGONAS
  `yocto-shared/kernel-staging/`. It is the edge channel (`assets/kernel/edge`)
  and is test-only.
- **Known-good kernels:** 7.2.8 (`r277`) is the default entry, and 7.2.7 is
  kept as a rescue kernel. Neither entry is removed, disabled, or re-ordered at
  any point.
- **r278 compared with the next rebuild:** the staged r278 still carries the
  old `fwnode_drm_find_panel()` export (0058). The re-aimed linlon-dp call
  site, meta-cix `0001-drm-cix-trilin-dp-drop-fwnode_drm_find_panel-use-cou.patch`
  (PR r2), takes effect only in the next rebuild (r279+). Section D applies to
  both. Items that apply only to r279+ are marked **[r279+]**.

## 0. Preconditions (stop if any fails)

1. `uname -r` is `7.2.8-sky1-ncz`, and the system booted from the default entry.
2. `grep -c '^menuentry' /boot/efi/EFI/BOOT/refind.conf` is recorded. The
   `RESCUE` menuentry and the 7.2.7 rescue kernel on the ESP are present:
   `ls -la /boot/efi/vmlinuz-*`. Copy `refind.conf` and the `ls` output into
   the capture dir.
3. Back up the ESP: `sudo cp -a /boot/efi /root/esp-backup-$(date +%F)`.
4. In the staging dir, `sha256sum -c SHA256SUMS` passes (run it before copying
   anything).

## A. Baseline capture on 7.2.8 (before touching anything)

Run the capture block below into `~/r278-test/baseline-7.2.8/`. It supplies
the reference for every diff in section E.

```sh
D=~/r278-test/$1; mkdir -p "$D"; cd "$D"
uname -a > uname.txt; cat /proc/cmdline > cmdline.txt
sudo dmesg -T > dmesg.txt; sudo journalctl -b -k --no-pager > journal-k.txt
lspci -nnk > lspci-nnk.txt; lspci -tv > lspci-tree.txt; lsblk -o NAME,MODEL,SIZE,TRAN > lsblk.txt
lsusb -t > lsusb-t.txt; lsusb > lsusb.txt
sudo nvme list > nvme.txt 2>&1
ls -la /dev/mali0 /dev/aipu /dev/video* /dev/dri/* > devnodes.txt 2>&1
for c in /sys/class/drm/card*-*; do echo "$c $(cat $c/status 2>/dev/null)"; done > drm-connectors.txt
grep . /sys/class/thermal/thermal_zone*/type /sys/class/thermal/thermal_zone*/temp > thermal.txt 2>&1
grep . /sys/class/thermal/cooling_device*/type > cooling.txt 2>&1
sudo cat /sys/kernel/debug/clk/clk_summary > clk_summary.txt 2>&1
sudo cat /sys/kernel/debug/devices_deferred > devices_deferred.txt 2>&1
ls /sys/bus/platform/drivers/*/ 2>/dev/null | grep -E 'CIXH|CIXHA' > acpi-bound.txt
lsmod > lsmod.txt
```

## B. Install r278 beside 7.2.8 (non-default entry)

This follows the installer's own edge path (`post-install/10-our-kernel.sh`,
the KVER_EDGE block), plus the installed rEFInd wrapper
(`post-install/11-fix-cixmini-boot.sh`). The modules archive is **never** extracted with `-C /`
into the live root. It is unpacked into a scratch directory, checked, and
only its single new `lib/modules/7.3.0-rc5-sky1-ncz` directory is copied in.

```sh
K=7.3.0-rc5-sky1-ncz; S=<staging>/r278-7.3.0-rc5-sky1-ncz-20260927; T=~/r278-test/unpack
mkdir -p "$T" && tar -C "$T" -xzf "$S/modules-cixmini.tgz"
tar -C "$T" -I zstd -xf "$S/headers-cixmini.tar.zst"
ls "$T/lib/modules"                      # must list exactly: 7.3.0-rc5-sky1-ncz
[ ! -e /usr/lib/modules/$K ] || { echo "already present: stop and investigate"; exit 1; }
sudo cp -a "$T/lib/modules/$K" /usr/lib/modules/          # modules + build/ (headers)
sudo install -m0644 "$S/Image-cixmini.bin" /boot/vmlinuz-$K
sudo install -m0644 "$S/config-$K" /boot/config-$K
# accelerator overlays built for this KVER. Panthor is not shipped (every
# entry blacklists it), so only mali, vpu and npu are copied.
sudo mkdir -p /usr/lib/modules/$K/updates
for o in mali vpu npu; do sudo cp "$S/overlays/$o/$K/"*.ko /usr/lib/modules/$K/updates/; done
sudo depmod -a $K
sudo dracut --force --kver $K /boot/initrd.img-$K
# The rEFInd wrapper classifies /boot kernels itself: newest release kernel ->
# the default "7.2 ..." entries, newest -rc kernel -> "7.3 Edge / Experimental".
sudo /usr/lib/cixmini/cixmini-update-bootloader
grep -n 'default_selection\|^menuentry' /boot/efi/EFI/BOOT/refind.conf
```

The wrapper must print `stable=7.2.8-sky1-ncz edge=7.3.0-rc5-sky1-ncz`.
Stop if `default_selection` changed, or if the RESCUE entry or the 7.2.7
rescue kernel disappeared (compare with step 0.2). If either happened, restore
`/root/esp-backup-*` before any reboot.

## C. Supervised boot

1. Reboot at the console and choose **7.3 Edge / Experimental Kernel (Console)**
   first. Choose the (Mali, Experimental) entry only after the console entry
   passes.
2. Log the serial console for the whole boot. A hang, a panic, or a reboot
   loop is an immediate FAIL: go to section G.
3. Once logged in, run the capture block into `~/r278-test/r278-console/`
   (and later `~/r278-test/r278-mali/`).

## D. Checks (all on the r278 boot)

| # | Check | Command | PASS | FAIL |
|---|---|---|---|---|
| D1 | Right kernel, right cmdline | `uname -r; cat /proc/cmdline` | `7.3.0-rc5-sky1-ncz`; cmdline has `sky1_pcie_native=off pcie_pnp_en acpi_scmi_en=off` | anything else |
| D2 | No crash | `grep -c -E 'Oops|BUG:|Call trace|panic' dmesg.txt` | 0 | >0 |
| D3 | PCIe root ports enumerate | `diff baseline-7.2.8/lspci-tree.txt r278-console/lspci-tree.txt` | same root ports and endpoints as 7.2.8 | a root port or endpoint missing |
| D4 | 17cd:0100 collision not reintroduced | `lspci -nnk -d 17cd:0100` | every root port shows `Kernel driver in use: pcieport` | `cdns3-pci-wrap`, `cdnsp-pci` or no driver; or `cdns3_pci` in dmesg |
| D5 | Sky1 PCIe driver-name clash is benign | `grep "already registered" dmesg.txt` | at most `Driver 'sky1-pcie' is already registered` (pci-sky1.c and the CIX driver share the name; harmless under `sky1_pcie_native=off`) | any other driver name; or `sky1_pcie_native` missing from the cmdline |
| D6 | NVMe | `sudo nvme list; lsblk` | same NVMe device and size as baseline; root mounted | missing or read-only |
| D7 | USB3 (CDNSP over ACPI) | `lsusb -t; dmesg | grep -i -E 'cdnsp|xhci'` | 5000M/10000M buses present as on baseline; a USB3 stick enumerates at 5000M | missing SuperSpeed bus |
| D8 | SCMI + mailbox (0001) | `dmesg | grep -i -E 'scmi|mbox|CIXHA001'` | no `failed to setup channel` | SCMI channel failure |
| D9 | CIXHA010 clock provider, deferred devices | `cat devices_deferred.txt; grep CIXHA010 acpi-bound.txt` | CIXHA010 bound; deferred list no longer than baseline (known: CIXH5040/CIXH5041 eDP) | new deferred CIX device |
| D10 | Clocks (CLKT queue decision) | `diff <(awk '{print $1}' baseline-7.2.8/clk_summary.txt | sort) <(awk '{print $1}' r278-console/clk_summary.txt | sort)` | no clock present on 7.2.8 is missing | a missing clock: record it (this triggers porting 0096/0138/0147/0148/0157/0168) |
| D11 | Thermals (0172 queue decision) | `diff baseline-7.2.8/thermal.txt ...` and `cooling.txt` | same zones and cooling devices; sane temps | a missing zone or cooling device: record it (this triggers porting 0172) |
| D12 | GPU (mali overlay) | `sudo modprobe mali_kbase; ls -l /dev/mali0; ls /sys/bus/platform/drivers/mali/` | `/dev/mali0`; bound to `CIXH5000:00` | modprobe error or vermagic mismatch |
| D13 | VPU | `sudo modprobe amvx; ls /dev/video*` | video nodes as on baseline | missing |
| D14 | NPU (DKMS/overlay, never in-tree) | `sudo modprobe aipu; ls -l /dev/aipu; modinfo -F filename aipu` | `/dev/aipu`; module under `updates/` | missing, or an in-tree `armchina` module loaded |
| D15 | Display via linlon-dp | `lsmod | grep -E 'linlon_dp|trilin_dpsub'; cat drm-connectors.txt; dmesg | grep -i -E 'linlon|trilin|edp-panel'` | linlon-dp and trilin-dpsub loaded; a DP connector `connected`; picture on the monitor; no `invalid edp-panel` or `invalid drm_panel` | module load failure (`Unknown symbol`), no card, black screen |
| D16 | **[r279+]** re-aimed eDP lookup | `dmesg | grep 'edp-panel reference on a non-OF firmware node'` | absent, or present once per ACPI DP node that names an `edp-panel`, and that port still probes as DP | DP port missing from `/sys/class/drm` |
| D17 | Audio (sanity) | `aplay -l` | same cards as baseline | missing HDMI/DP or analog card |
| D18 | Mali entry | reboot into the (Mali, Experimental) entry and repeat D2, D12, D15 | desktop reaches login | compositor falls back to llvmpipe, or a crash |

D5 is informational under the shipped cmdline. If an operator ever boots
with native Sky1 PCIe (`sky1_pcie_native` removed), the vendor driver fails
to register because of that name clash. That is the 0027 rename hunk the rc5
port does not carry. Do not test native mode on this kernel.

## E. Overall verdict

- **PASS:** D1-D15 and D17 pass on the console entry and D18 passes on the
  Mali entry. Record the capture dirs, and store a MNEMOS milestone with the
  verdict and the evidence.
- **CONDITIONAL:** everything boots and D10 or D11 shows a missing clock or
  thermal item. Record which one. That, and only that, re-opens the queued
  forward-ports (CLKT chain or 0172).
- **FAIL:** anything else. Record the failing item, then roll back (section G).

## F. What to hand back

Archive `~/r278-test/` (baseline and r278 dirs plus the serial log) and put
it next to the staging dir. Note the rEFInd menu before and after.

## G. Rollback

1. Reboot and select the default **7.2 Mali (Default)** entry, which is
   unchanged. If that fails, choose the **RESCUE** entry (the 7.2.7 known-good
   kernel).
2. Remove r278:
   ```sh
   K=7.3.0-rc5-sky1-ncz
   sudo rm -f /boot/vmlinuz-$K /boot/initrd.img-$K /boot/config-$K
   sudo rm -rf /usr/lib/modules/$K
   sudo /usr/lib/cixmini/cixmini-update-bootloader    # prints edge=<none>
   grep -n 'default_selection\|^menuentry' /boot/efi/EFI/BOOT/refind.conf   # matches step 0.2
   ```
3. If the ESP is damaged, restore it from `/root/esp-backup-<date>` in the
   RESCUE environment.
