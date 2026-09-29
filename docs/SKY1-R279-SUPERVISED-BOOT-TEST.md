# Sky1 r279 (7.3.0-rc5) supervised boot test sheet: O6N

This sheet supersedes the r278 sheet (`docs/SKY1-R278-SUPERVISED-BOOT-TEST.md`)
for the edge line. It keeps every r278 check and adds the r279 items.

It is for the operator only. No agent reboots, flashes or repartitions the
O6N (.3) or MS-R1 (.66). Run each step at the console with the serial console
(`ttyAMA0`) attached and logging.

- **Kernel under test:** `r279-7.3.0-rc5-sky1-ncz-20260929` in ARGONAS `yocto-shared/kernel-staging/`.
  It is on the edge channel (`assets/kernel/edge`) and is test-only. The
  staging dir's `PROVENANCE.txt` gives the source, SRCREV, gates and ELF
  build IDs.
- **Known-good kernels:** 7.2.8 (`r277`) is the default and shipping kernel,
  and 7.2.7 is the RESCUE entry. Neither entry is removed, disabled or
  re-ordered.
- **What r279 adds over r278:**
  1. The linlon-dp eDP lookup is re-aimed, with no `fwnode_drm_find_panel`
     (D15, D16).
  2. Sky1 native PCIe mode is repaired: driver name, HPA root-port window,
     capability walk, ECAM region and ACPI clocks (section N).
  3. The early-boot runtime-PM gate is restored (D19).
  4. Modules are uncompressed plain `.ko` (D20).
  5. All four accelerator overlays are rebuilt against r279's own headers
     (D12-D14, D21).

## 0. Preconditions: stop if any fails

1. `uname -r` shows `7.2.8-sky1-ncz`, booted from the default entry.
2. Record the output of `grep -c '^menuentry' /boot/efi/EFI/BOOT/refind.conf`.
   The `RESCUE` menuentry and the 7.2.7 rescue kernel (`/boot/efi/vmlinuz-*-rescue`)
   must both be present. Copy `refind.conf` and `ls -la /boot/efi/` into
   `~/r279-test/`.
3. Back up the ESP: `sudo cp -a /boot/efi /root/esp-backup-$(date +%F)`.
4. In the staging dir, run `sha256sum -c SHA256SUMS`. It must pass.
5. If r278 was installed with the r278 sheet, remove it first using that
   sheet's section G. r278 and r279 have the same KVER, so they cannot both be
   installed.

## A. Baseline capture on 7.2.8

Run the capture block into `~/r279-test/baseline-7.2.8/`. It is the r278
block plus cache topology and energy-model state:

```sh
D=~/r279-test/$1; mkdir -p "$D"; cd "$D"
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
lscpu -C > lscpu-caches.txt 2>&1
grep . /sys/devices/system/cpu/cpu*/cache/index*/{level,type,id,shared_cpu_list} > cacheinfo.txt 2>&1
sudo ls /sys/kernel/debug/energy_model/ > energy_model.txt 2>&1
grep . /sys/class/devfreq/*/governor /sys/class/devfreq/*/cur_freq > devfreq.txt 2>&1
```

## B. Install r279 beside 7.2.8 (non-default entry)

This is the same procedure as the r278 sheet, section B. Its modules are
plain `.ko` files.

```sh
K=7.3.0-rc5-sky1-ncz; S=<staging>/r279-7.3.0-rc5-sky1-ncz-20260929; T=~/r279-test/unpack
mkdir -p "$T" && tar -C "$T" -xzf "$S/modules-cixmini.tgz"
tar -C "$T" -I zstd -xf "$S/headers-cixmini.tar.zst"
ls "$T/lib/modules"                      # must list exactly: 7.3.0-rc5-sky1-ncz
find "$T" -name '*.ko.xz' | wc -l        # must be 0
[ ! -e /usr/lib/modules/$K ] || { echo "already present: stop and investigate"; exit 1; }
sudo cp -a "$T/lib/modules/$K" /usr/lib/modules/
sudo install -m0644 "$S/Image-cixmini.bin" /boot/vmlinuz-$K
sudo install -m0644 "$S/config-$K" /boot/config-$K
sudo mkdir -p /usr/lib/modules/$K/updates
for o in mali vpu npu; do sudo cp "$S/overlays/$o/$K/"*.ko /usr/lib/modules/$K/updates/; done
sudo depmod -a $K
sudo dracut --force --kver $K /boot/initrd.img-$K
sudo /usr/lib/cixmini/cixmini-update-bootloader   # prints stable=7.2.8-sky1-ncz edge=7.3.0-rc5-sky1-ncz
grep -n 'default_selection\|^menuentry' /boot/efi/EFI/BOOT/refind.conf
```

Stop if `default_selection` changed, or if the RESCUE entry or the 7.2.7
rescue kernel disappeared. If either happened, restore the ESP backup before
any reboot.

Then prove that the initramfs holds the r279 overlays (checklist 1c).
Compare these build IDs with `OVERLAYS.txt` in the staging dir:

```sh
for m in mali_kbase amvx aipu; do
  lsinitrd -f usr/lib/modules/$K/updates/$m.ko /boot/efi/initrd.img-$K > /tmp/$m.ko 2>/dev/null \
    && readelf -n /tmp/$m.ko | sed -n "s/.*Build ID: /$m initrd /p"
  readelf -n /usr/lib/modules/$K/updates/$m.ko | sed -n "s/.*Build ID: /$m rootfs /p"
done
```

## C. Supervised boot (default cmdline: `sky1_pcie_native=off`)

1. Reboot at the console and choose **7.3 Edge / Experimental Kernel (Console)**.
2. Log the serial console for the whole boot. A hang, a panic or a reboot
   loop is an immediate FAIL: go to section G.
3. Once logged in, run the capture block into `~/r279-test/r279-console/`.

## D. Checks on the default-cmdline r279 boot

| # | Check | Command | PASS | FAIL |
|---|---|---|---|---|
| D1 | Right kernel and cmdline | `uname -r; cat /proc/cmdline; head -1 /proc/version` | `7.3.0-rc5-sky1-ncz`; cmdline has `sky1_pcie_native=off pcie_pnp_en acpi_scmi_en=off`; the banner date is the v7.3-rc5 commit date | anything else |
| D2 | No crash | `grep -c -E 'Oops|BUG:|Call trace|panic' dmesg.txt` | 0 | >0 |
| D3 | PCIe root ports enumerate | `diff baseline-7.2.8/lspci-tree.txt r279-console/lspci-tree.txt` | same root ports and endpoints | missing port or endpoint |
| D4 | 17cd:0100 collision not reintroduced | `lspci -nnk -d 17cd:0100` | every root port shows `Kernel driver in use: pcieport` | `cdns3-pci-wrap`, `cdnsp-pci`, no driver, or `cdns3_pci` in dmesg |
| D5 | No driver-name clash | `grep "already registered" dmesg.txt` | **no output** (r279 renames the vendor driver to `sky1-pcie-cix`) | any line |
| D6 | NVMe | `sudo nvme list; lsblk` | same device and size as baseline; root is mounted | missing or read-only |
| D7 | USB3 (CDNSP over ACPI) | `lsusb -t; dmesg \| grep -i -E 'cdnsp|xhci'` | SuperSpeed buses as on baseline; a USB3 stick enumerates at 5000M | missing SuperSpeed bus |
| D8 | SCMI + mailbox | `dmesg \| grep -i -E 'scmi|mbox|CIXHA001'` | no `failed to setup channel` | SCMI channel failure |
| D9 | CIXHA010 bound, no new deferred devices | `cat devices_deferred.txt; grep CIXHA010 acpi-bound.txt` | CIXHA010 bound; deferred list no longer than baseline (known: CIXH5040/CIXH5041 eDP) | a new deferred CIX device |
| D10 | Clocks | diff the `clk_summary` clock names against the baseline | no clock present on 7.2.8 is missing | a clock is missing (record it) |
| D11 | Thermals | diff `thermal.txt` and `cooling.txt` against the baseline | same zones and cooling devices; sane temps | missing zone or cooling device |
| D12 | GPU (mali overlay) | `sudo modprobe mali_kbase; ls -l /dev/mali0; ls /sys/bus/platform/drivers/mali/` | `/dev/mali0`; bound to `CIXH5000:00` | modprobe error, `disagrees about version of symbol`, not bound |
| D13 | VPU | `sudo modprobe amvx; ls /dev/video*` | video nodes as on baseline | missing |
| D14 | NPU (overlay/DKMS, never in-tree) | `sudo modprobe aipu; ls -l /dev/aipu; modinfo -F filename aipu` | `/dev/aipu`; module under `updates/` | missing, or an in-tree `armchina` module |
| D15 | Display via linlon-dp | `lsmod \| grep -E 'linlon_dp|trilin_dpsub'; cat drm-connectors.txt; dmesg \| grep -i -E 'linlon|trilin|edp-panel'` | both loaded; a DP connector `connected`; picture on the monitor; no `invalid edp-panel`, `invalid drm_panel` or `Unknown symbol` | load failure, no card, black screen |
| D16 | Re-aimed eDP lookup | `dmesg \| grep 'edp-panel reference on a non-OF firmware node'` | absent, or present once per ACPI DP node naming an `edp-panel` while that port still appears under `/sys/class/drm` | that DP port is missing |
| D17 | Audio | `aplay -l` | same cards as baseline | missing HDMI/DP or analog card |
| D18 | Mali entry | reboot into **7.3 Edge / Experimental Kernel (Mali, Experimental)** and repeat D2, D12, D15, capturing into `r279-mali/` | desktop reaches login | llvmpipe fallback, or a crash |
| D19 | Runtime-PM gate restored | `dmesg \| grep 'cix_pm: system ready'` | exactly one line | absent |
| D20 | Uncompressed modules | `find /usr/lib/modules/$(uname -r) -name '*.ko.xz' \| wc -l` | 0 | >0 |
| D21 | Mali energy model (0172) | `cat energy_model.txt devfreq.txt; dmesg \| grep -i -E 'energy model|cix_scmi'` | the GPU has an EM entry and a devfreq governor, as on baseline | no EM for the GPU, or a `cix_scmi_register_em` error |
| D22 | Cache topology (0212 decision) | `diff baseline-7.2.8/cacheinfo.txt r279-console/cacheinfo.txt; dmesg \| grep -i cacheinfo` | identical level/type/id/sharing as 7.2.8; no cacheinfo warnings | any difference (record it; that re-opens 0212) |

## N. Native Sky1 PCIe (gated; run only after D1-D22 pass)

Native mode is what `sky1_pcie_native=off` has hidden on every kernel so
far. On the rc3 edge line (2026-09-16), an entry without that flag hard-reset
the board at USB bring-up. r279 repairs the three native-mode defects found
in the 7.3 port. Native mode has never been validated on any kernel, though,
so treat this as a first-ever test.

1. Make a **one-time** menu entry. Do not change `default_selection` and do
   not edit the generated entries.
   ```sh
   sudo cp /boot/efi/EFI/BOOT/refind.conf /root/refind.conf.pre-native
   ```
   Then append a stanza to `/boot/efi/EFI/BOOT/refind.conf` that copies the
   **7.3 Edge / Experimental Kernel (Console)** menuentry verbatim, with two
   changes: title it `7.3 NATIVE PCIe TEST`, and delete **only**
   `sky1_pcie_native=off` and `pcie_pnp_en` from its `options` line. Confirm
   with `grep -n 'default_selection' refind.conf` that the default is
   unchanged.
2. Reboot at the console and choose **7.3 NATIVE PCIe TEST**, with serial
   logging on. If the rootfs is on NVMe and native PCIe fails, the boot
   stops in the initramfs or the board resets. That is a FAIL: power-cycle
   and pick the default entry. The one-time entry cannot become the default.
3. Capture into `~/r279-test/r279-native/` and check:

| # | Check | PASS | FAIL |
|---|---|---|---|
| N1 | Cmdline has no `sky1_pcie_native=off` | as intended | flag still present (wrong entry) |
| N2 | Native path taken | `dmesg` shows `Sky1: blocking PNP0A08, CIXH2020 will handle` and `Sky1: created platform device` per controller | PNP0A08 host still used |
| N3 | Vendor driver bound | `ls /sys/bus/platform/drivers/sky1-pcie-cix/` lists the controllers; no `already registered` in dmesg | empty, or name clash |
| N4 | D3 with native on | the root ports and endpoints match the baseline (bus numbers may differ; the device set may not) | missing port or endpoint |
| N5 | D4 with native on | `lspci -nnk -d 17cd:0100` shows `pcieport` on every root port; no `cdns3`/`cdnsp` PCI binding | any other driver |
| N6 | D5 with native on | no `already registered`; no `Failed to get axi_clk` or `apb_clk` | clock-get errors or name clash |
| N7 | D6 with native on | NVMe present, root mounted read-write | missing |
| N8 | D7 with native on | USB3 SuperSpeed buses as on baseline | missing |
| N9 | No SError | `dmesg | grep -i -E 'SError|Asynchronous'` gives nothing | any hit |

4. Restore: `sudo cp /root/refind.conf.pre-native /boot/efi/EFI/BOOT/refind.conf`.
   The next kernel refresh would regenerate it without the stanza anyway.

Native mode stays **off** on every shipped cmdline, whatever N shows.
Turning it on is a separate operator decision.

## E. Overall verdict

- **PASS (edge):** D1-D17 and D19-D22 pass on the console entry, and D18
  passes on the Mali entry.
- **PASS (native):** N1-N9 also pass.
- **CONDITIONAL:** it boots but D10, D11 or D22 shows a difference. Record it.
  That is exactly the evidence that re-opens a queued port (CLKT, 0172,
  0212).
- **FAIL:** anything else. Record the item and roll back (section G).

## F. What to hand back

Archive `~/r279-test/` (baseline, r279-console, r279-mali, r279-native and
the serial log) next to the staging dir, and store a MNEMOS milestone with
the verdict.

## G. Rollback

1. Reboot into the default **7.2 Mali (Default)** entry, which is unchanged.
   If that fails, use **RESCUE** (7.2.7).
2. Remove r279:
   ```sh
   K=7.3.0-rc5-sky1-ncz
   sudo rm -f /boot/vmlinuz-$K /boot/initrd.img-$K /boot/config-$K
   sudo rm -rf /usr/lib/modules/$K
   [ -f /root/refind.conf.pre-native ] && sudo cp /root/refind.conf.pre-native /boot/efi/EFI/BOOT/refind.conf
   sudo /usr/lib/cixmini/cixmini-update-bootloader    # prints edge=<none>
   grep -n 'default_selection\|^menuentry' /boot/efi/EFI/BOOT/refind.conf   # matches step 0.2
   ```
3. If the ESP is damaged, restore it from `/root/esp-backup-<date>` in the
   RESCUE environment.
