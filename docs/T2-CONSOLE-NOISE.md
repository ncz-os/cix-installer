# T2 boot "hardware error" noise — classification and policy

Date: 2026-10-11. Question: can the multiple T2 kernel "hardware errors" shown
at boot be suppressed on the console, or explained?

Scope of the evidence: two MacBookPro16,1 (T2) units on the kernel of the time
(`7.3.0-rc6-4-t2-edge-aer9010`), with a non-T2 ASUS ROG laptop as the control.
Read-only (`dmesg`, `journalctl -k`, `/proc`, `/sys`).

## The console rule (why most "errors" never reach the console)

`Documentation/core-api/printk-basics`: a message is printed to the console only
when its level is **numerically less than** `console_loglevel`:

| console_loglevel | reaches the console |
|---|---|
| 3 (our Default entry / `99-ncz-quiet-console.conf`) | 0 EMERG, 1 ALERT, 2 CRIT |
| 2 | 0 EMERG, 1 ALERT (**hides CRIT**) |

Every observed benign T2 line is `KERN_ERR` (level 3) — see the level buckets
below — so at `loglevel=3` it is **already off the console** and exists only in
`dmesg` / `journalctl -k` (the ring buffer always keeps everything). The rEFInd
**"…Console"** entry deliberately carries no `loglevel=`, which is why it shows
ERR/WARN.

```
MacBookPro16,1 (A)  /proc/sys/kernel/printk = 3 4 1 3   -> dmesg --level=crit  = (empty)
MacBookPro16,1 (B)  /proc/sys/kernel/printk = 3 4 1 3   -> dmesg --level=crit  = mce [Hardware Error] x2
ASUS ROG (control)  /proc/sys/kernel/printk = 3 4 1 3   -> dmesg --level=crit  = (empty)
```

## Why we do NOT lower the console to 2

The only way to hide a `KERN_ERR` line from the console with the printk knobs is
to drop `console_loglevel` below 3. That also hides `KERN_CRIT` (2). Real
machine-check records are logged at CRIT: MacBookPro16,1 (B) logged, on this exact kernel,

```
mce: [Hardware Error]: CPU 0: Machine Check: 0 Bank 12: ee0000000040110a
mce: [Hardware Error]: CPU 0: Machine Check: 0 Bank 13: ee0000000040110a
```

and those lines are level `crit` (they do not appear in `dmesg --level=err`,
only in `--level=crit`). Lowering to 2 would silence them from the console,
violating the rule *never hide MCE/AER/EDAC/panic/oops*. So **3 is the
floor**; the benign noise is fixed at its source instead (below).

> The boot-time record on MacBookPro16,1 (B) itself is a **left-over from before the kernel
> booted** (TSC 0, EN=0 = polled, not delivered) and is now suppressed on the
> everyday graphical (Default) rEFInd entry with a T2-gated `mce=nobootlog`,
> while the Console/Rescue entries deliberately keep it visible. Evidence (the
> same status is reported on unrelated Intel desktops), the exact v7.3-rc6
> kernel behaviour and the trade-off are in the commit history of
> `assets/refind/ncz-refind-refresh-amd64.sh`. (Note: `__print_mce()` emits these at
> `KERN_EMERG`, level 0, so `loglevel=3` cannot hide them and `dmesg --level=crit`
> lists them too.)

## What actually was changed here (root-cause fixes, level 3 kept)

1. **brcmfmac P2P -52** — `options brcmfmac feature_disable=0x10` (clear bit 4,
   `BRCMF_FEAT_P2P`); the BCM4364 firmware rejects `p2p_da_override` so the P2P
   Device interface can never be created. Removes the 3-line `brcmf_p2p_*`
   error cluster every boot and stops advertising a feature that does not work.
2. **pcspkr duplicate registration** — `blacklist snd_pcsp`; the input `pcspkr`
   and ALSA `snd_pcsp` modules both register a platform driver named `pcspkr`
   (`MODULE_ALIAS platform:pcspkr`), so udev autoloads both and one fails with
   *"Error: Driver 'pcspkr' is already registered, aborting..."*.
3. **hid_sensor_rotation probe failure** — `blacklist hid_sensor_rotation`
   (plus `install hid_sensor_rotation /bin/true`). Apple's T2 HID sensor hub
   (05AC:8104) declares an orientation collection (usage 0x20008a) but omits the
   generic sensor common-attributes report, so `hid_sensor_parse_common_attributes()`
   asks for report id `0xffffffff`, gets nothing and fails the probe. The sensor
   is non-functional and unused; not binding the driver removes the failed probe
   *and* the `No report with id 0xffffffff found` warning together. This is a
   driver blacklist rather than a kernel patch on purpose: a kernel quirk would
   either leave a broken IIO device registered or merely relocate the messages.
4. **Bluetooth firmware reporting** — `55-t2-firmware.sh` verifies BT firmware
   by chip class: BCM4377 models (MacBookPro15,4 / 16,3 / Air9,1) must have
   `brcmbt*.bin`; every other T2 model is a UART chip on ROM firmware where the
   absent `brcm/BCM.hcd` is expected, so it is reported as such instead of as a
   fixable gap. (No Apple firmware is shipped.)
5. **Console-loglevel floor guard** — `58-boot-hygiene.sh` documents the floor
   and warns if a drop-in leaves the console below 3.

## What was fixed in the kernel (companion branch)

The two lines that cannot be fixed from userspace are handled by kernel
patches (`9101` and `9102` in the Preview 1 series, see
[`ncz-os/linux-t2-ncz`](https://gitlab.com/ncz-os/linux-t2-ncz)), not by
anything in the installer:

* T2 `Secure Boot Certs` `pr_err` → `pr_info` (`security/integrity/.../load_uefi.c`,
  patch `9101`): taking the T2 cert-skip quirk is the designed path, not a fault.
* BT BCM4364B3 UART chip → identify LMP subver `0x3032` and, on the Apple-T2 DMI
  set, demote the expected missing-patchram report to info (patch `9102`): the
  controller runs on ROM firmware and Apple's patchram is not redistributable.
* dpc `-524` spurious-probe line — patch `9013`.

Left untouched, confirmed benign: `SGX disabled` (`pr_err_once`, mainline, also
on non-T2), the amdgpu `Fence fallback timer` / `CG_TACH` warns (missed-IRQ
recovery path / no dGPU tach on this chassis), and the BT baudrate/A-CPI-GPIO
warns (Apple ACPI describes no reset GPIO).

## Level buckets (MacBookPro16,1 (A), `7.3.0-rc6-4-t2-edge-aer9010`)

* `KERN_ERR` (dmesg-only; **not** on the console at `loglevel=3`):
  `ACPI Error: AE_ALREADY_EXISTS` (+8 `Aborting method`), `Unable to locate
  IOAPIC for GSI 34`, `dpc … failed with error -524` (x2), `integrity: Reading
  UEFI Secure Boot Certs…`, `intel-lpss INT34BA:00 … -22`, `Driver 'pcspkr' is
  already registered`, `Bluetooth: … baudrate (-16)` / `Failed to set baudrate`
  / `Patch file not found brcm/BCM.hcd`, `hid_sensor_rotation … -22`,
  `brcmf_p2p_* -52` (x3), `SGX disabled or unsupported by BIOS`.
* `KERN_WARNING` (dmesg-only): `thunderbolt device links…`, `intel_pch_thermal
  … INT A`, `t2smc`/`t2bce` taint notices, `amdgpu Fence fallback…`.
* `KERN_CRIT` (console): MacBookPro16,1 (B) `mce: [Hardware Error]` only.
