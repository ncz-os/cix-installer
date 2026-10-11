# T2 boot-time left-over MCE — suppression policy (`mce=nobootlog` on the Default entry)

Date: 2026-10-11. Operator: *"I still want to eliminate or suppress this in the
kernel boot"* — a photo of CHIMERA (MacBookPro16,1, i9-9980HK, `PROCESSOR
0:906ed`) showing, at `t=0.287 s`:

```
mce: [Hardware Error]: CPU 0: Machine Check: 0 Bank 12: ee2000000040110a
mce: [Hardware Error]: TSC 0 ADDR ff7dda00 MISC 43880000086
mce: [Hardware Error]: PROCESSOR 0:906ed TIME ... SOCKET 0 APIC 0 microcode 0x104
mce: [Hardware Error]: CPU 0: Machine Check: 0 Bank 13: ee2000000040110a
mce: [Hardware Error]: TSC 0 ADDR ff7dda40 MISC 43880000086
```

Related: `docs/T2-CONSOLE-NOISE.md` (the broader T2 boot-noise classification),
`docs/T2-POWER-CAP.md` (the load-triggered SMC hard power cut, a plausible
source of a left-over record).

## 1. What the record is

These are two Machine Check records read out of MCA banks 12 and 13 on CPU 0 at
boot. Decoding the status `0xee2000000040110a`:

| field | value | meaning |
|---|---|---|
| bit 63 VAL | 1 | record is valid |
| bit 62 OVER | 1 | an overflow (a second event) occurred while this was pending |
| bit 61 UC | 1 | uncorrected |
| bit 60 EN | **0** | **not enabled for signalling** — this is a *polled* record, not a delivered exception |
| bit 59 MISCV | 1 | `MCi_MISC` is valid |
| bit 58 ADDRV | 1 | `MCi_ADDR` is valid |
| bit 57 PCC | 1 | processor-context-corrupt (this event would have lost CPU state) |
| bits 31:16 MSCOD | `0x0040` | model-specific error code |
| bits 15:0 MCACOD | `0x110a` | Intel generic cache/TLB code |
| `MISC` | `0x43880000086` | |
| `ADDR` | `0xff7dda00` / `0xff7dda40` | inside the firmware/MMIO window |
| `TSC` | **0** | **no timestamp was taken** → not collected during this boot |

`TSC 0` and `EN=0` together say this was collected by the kernel's boot-time
**poll** of the MCA banks (`machine_check_poll()`), not delivered as a runtime
`#MC`. The poll happens in `__mcheck_cpu_init_prepare_banks()` *before* the
bank's CMCI/control is armed, so a record that was already sitting in the bank
from a previous power event is read out with no timestamp. The bank is then
cleared. It is a **left-over from before this kernel booted**, not a fault in
this boot, and CHIMERA showed no further MCE in ~1 h of uptime.

The exact same status/MISC signature is reported on **unrelated Intel desktops**
that have no T2, no Apple firmware and no `MacBookPro16,1` — see §2. That is the
strongest argument that this is a generic Intel firmware/BIOS-reporting artifact,
not a T2-specific or machine-specific hardware failure.

> The operator's photo shows `ee2000000040110a`; earlier CHIMERA captures in
> `~/Projects/oc-mission-20261010/{t2noise,t2fixall}` show `ee0000000040110a`.
> The only difference is reserved `other_info` bit 53. `MCACOD 0x110a`,
> `MSCOD 0x0040`, `EN=0`, `UC/VAL/OVER/ADDRV/MISCV/PCC=1`, the `MISC
> 0x…3880000086` low pattern and the `0xFEF..`/`0xFF7..` address window are
> identical — i.e. the same class of record.

## 2. Prior art (what exists, and what does NOT)

### 2.1 The T2 Linux project does **not** document this

The operator recalled that "the T2 project documents it". It does **not**, in
any source we can cite:

* `t2linux/wiki` (the whole wiki that renders at <https://wiki.t2linux.org/>) —
  full-text searched: **no** occurrence of `mce`, `machine check`, `nobootlog`,
  `hardware error`, or `Bank <n>`. The rEFInd guide
  (`docs/guides/refind.md`) documents the recommended kernel parameters
  `intel_iommu=on iommu=pt pm_async=off quiet splash` but says nothing about MCE
  or boot-logged machine checks.
* `t2linux/linux-t2-patches` (the T2 patch set) — **no** MCE/machine-check patch.
* GitHub code search across the whole `t2linux` org — **no** hit for `nobootlog`
  or `machine check` (only `CONFIG_X86_MCE=y` in a Gentoo kernel config).

**Conclusion: the T2 project does not document this MCE.** If a page exists it
is not in the wiki or patch repos; do not claim a T2-project citation for it.
The supportable prior art is the cross-platform evidence below.

### 2.2 Cross-platform prior art (the real citation)

* Arch Linux forum **bbs.archlinux.org/viewtopic.php?id=266210** — i3-10320 /
  MSI B560, and later an i9-10900 / Gigabyte Z590: *"`mce: [Hardware Error]:
  CPU 0: Machine Check: 0 Bank 6: ee2000000040110a`"*, `TSC 0`, ADDR
  `fef20080`, MISC `3880000086`, at boot only, machine otherwise fine. The
  thread's resolution is exactly this: **`mce=nobootlog` suppressed the lines.**
  A similar thread is **id=267543**.
* The Linux Hardware Database dmesg corpus (`linuxhw/Dmesg`) contains the exact
  string `ee2000000040110a` on many **Dell and MSI desktops/laptops** (XPS,
  Inspiron, MS-7D09, …) on kernels from 4.10 to 5.10 — none of them Apple.
* Kernel documentation (`Documentation/admin-guide/kernel-parameters.txt`,
  `Documentation/arch/x86/x86_64/boot-options.rst`):

  ```
  mce=bootlog
        Enable logging of machine checks left over from booting.
        Disabled by default on AMD Fam10h and older because some BIOS
        leave bogus ones.
        If your BIOS doesn't do that it's a good idea to enable though
        to make sure you log even machine check events that result
        in a reboot. On Intel systems it is enabled by default.
  mce=nobootlog
        Disable boot machine check logging.
  ```

### 2.3 What the kernel actually does, in v7.3-rc6

Verified against `torvalds/linux` tag **`v7.3-rc6`**
(`a90ee4305c4a5df72c11b31dacfdc76e00fcf78a`),
`arch/x86/kernel/cpu/mce/core.c`:

* `__print_mce()` prints every field with **`pr_emerg`** (level 0, `KERN_EMERG`).
  The console prints a message when its level `< console_loglevel`; at
  `loglevel=3` an EMERG (0) still prints. **`quiet loglevel=3` cannot hide an
  MCE.** This is why the line reaches the panel at all.
* **Default is boot logging ON for Intel** ≥ Yonah: `mca_cfg.bootlog` starts at
  `-1` and only `intel_apply_global_quirks()` *clears* it for pre-Yonah CPUs. So
  a modern Intel T2 Mac logs boot records by default.
* At boot, `__mcheck_cpu_init_prepare_banks()` runs:

  ```c
  if (mca_cfg.bootlog) {
          mce_banks_t all_banks;
          bitmap_fill(all_banks, MAX_NR_BANKS);
          machine_check_poll(MCP_UC | MCP_QUEUE_LOG, &all_banks);
  }
  for (i = 0; i < this_cpu_read(mce_num_banks); i++) {
          ...
          wrmsrq(mca_msr_reg(i, MCA_CTL), b->ctl);
          wrmsrq(mca_msr_reg(i, MCA_STATUS), 0);      /* <-- CLEAR */
          ...
  }
  ```

  The polled records are queued (`MCP_QUEUE_LOG`) and printed asynchronously as
  the `mce: [Hardware Error]` lines. **The following loop writes `MCi_STATUS = 0`
  for every initialised bank whether or not the poll ran** — so the record is
  **cleared either way**.
* `mcheck_enable()` (`mce=` parsing):

  ```c
  else if (!strcmp(str, "bootlog") || !strcmp(str, "nobootlog"))
          cfg->bootlog = (str[0] == 'b');
  ```

  `mce=nobootlog` ⇒ `bootlog = 0` ⇒ the boot-time poll/log is skipped. Runtime
  machine checks are delivered and logged exactly as before.
* **There is no `MCP_DONTLOG` in v7.3-rc6.** `enum mcp_flags`
  (`arch/x86/include/asm/mce.h`) is only `MCP_TIMESTAMP | MCP_UC |
  MCP_QUEUE_LOG`. The nearest named knob is `mca_cfg.dont_log_ce`
  (`mce=dont_log_ce`, corrected errors only) — unrelated. Any reference to
  `MCP_DONTLOG` for this kernel is inaccurate.

## 3. What this change does

`assets/refind/ncz-refind-refresh-amd64.sh` (the script that regenerates the
**installed** rEFInd menu on the target) gains a T2-gated kernel parameter:

* the existing `NCZ-T2-CMDLINE` block (`ncz_is_t2_hardware` from
  `assets/refind/ncz-t2-detect.sh`, DMI — the same helper the rescue blacklist
  and the T2 DKMS hook use) sets `NCZ_T2_MCE_CMDLINE="mce=nobootlog"` **on a
  known T2 Mac only**, empty otherwise and when the helper is absent (fail
  closed);
* `STABLE_OPTIONS` (the **Default / graphical** entry) appends it.

| installed rEFInd entry | `mce=nobootlog`? |
|---|---|
| `7.3 (Default)` (graphical) | **yes** (T2 only) |
| `7.3 Console` | no — a technician must still see the raw record |
| `7.3 Rescue / No Accelerators (Console)` | no |
| `Rescue Partition (Console)` | no |
| operator-staged `RESCUE - <kver> known-good kernel` | no |

The Console and Rescue entries deliberately keep the record visible, matching
the project rule *never hide MCE/AER/EDAC/panic/oops* — the difference is
scoped to the everyday graphical boot, where the line is a known-benign
left-over.

### 3.1 Installer / live media entries: deliberately NOT changed

`build/iso/build-refind-esp.py` (`AMD64_INSTALL_OPTIONS`, `_PC_INSTALL_OPTIONS`)
is **left alone**. Reasons:

1. The installer is a text installer where the raw record is *useful*: it is the
   one place a technician installs/validates hardware and would want to see it.
2. The installer entries are built at ISO time and shared between amd64 and
   arm64 (`_PC_INSTALL_OPTIONS`); they cannot be T2-gated, because the ISO does
   not know the target until it boots. Adding an amd64-only, T2-only parameter
   would require a build-time arch split for no benefit.
3. The installed entries are generated **on the target**, which is exactly where
   T2 detection is possible — so the installed path is the correct and only place
   for this.

### 3.2 arm64 is unaffected

T2 is an amd64/Intel concept; `assets/refind/ncz-refind-refresh.sh` (Sky1) has no
T2 gate and is unchanged.

## 4. TRADE-OFF

* **What you lose:** a genuine MCE that occurred and was *not* cleared by a warm
  reboot (i.e. a real fault that a warm reset left in the bank) would no longer
  be logged on the **Default** entry. It would still be caught by:
  * `rasdaemon` (installed on the image by `docs/T2-POWER-CAP.md`'s hook) which
    persists and decodes **runtime** machine checks (`ras-mc-ctl --summary`);
  * the **Console** and **Rescue** entries, which still log it;
  * and the bank is cleared on every boot regardless, so nothing is "hidden in
    hardware".
* **What you keep:** runtime machine checks (delivered as `#MC`) are logged and
  handled exactly as before; `mce=nobootlog` only affects the boot-time
  left-over poll.
* **Open question (not proven here):** whether the CHIMERA record is *sticky*
  (cleared only by a full power loss, i.e. a battery-disconnected power cycle)
  or *regenerated by firmware on every boot*. `mce=nobootlog` suppresses it on
  the Default entry either way; the cold power-off test distinguishes the two
  for understanding (and would tell us whether the underlying power event is
  recurring). That test is the operator's.

## 5. ONE-BOOT verification recipe (no install, no rebuild)

The parameter only takes effect when the kernel is booted; reflexively, the
installed entry change lands with the next image, but you can test it **now** on
a running T2 Mac without changing anything on disk:

1. **rEFInd → F2 (or `+`) on the Default entry → edit the options** and append
   `mce=nobootlog` to the kernel command line, then boot. (At the rEFInd menu,
   highlight the Default entry and press `F2` to edit its options; this boot is
   one-shot and nothing is written to disk.)
2. After the graphical session is up, verify:
   ```sh
   cat /proc/cmdline                       # expect ... mce=nobootlog ...
   journalctl -k -b | grep -c 'mce: \[Hardware Error\]'   # expect 0
   ```
3. Confirm the record really was there on the previous (default) boot, and that
   the ban is still cleared:
   ```sh
   sudo journalctl -k -b -1 | grep -c 'mce: \[Hardware Error\]'   # expect 2 on CHIMERA
   ```
4. Optional — read the raw bank registers (they are zeroed after every boot, so
   this is only meaningful from a *live* session that has *not* been cleared, or
   to confirm they are zero now):
   ```sh
   sudo modprobe msr && sudo rdmsr 0x40D 0x40E      # MC12/MC13 STATUS (0 = clear)
   ```
   With `rasdaemon` installed, `ras-mc-ctl --summary` / `--errors` shows what it
   persisted for runtime events.

To test the **generated** menu without a rebuild, run the script by hand on a T2
Mac (root) and inspect the result; it regenerates `refind.conf` on the ESP:

```sh
sudo KVER_STABLE="$(sed -n 1p /usr/local/lib/cix-installer/KVER_LIST_AMD64)" \
     BUILD_VERSION="(manual-test)" /usr/local/sbin/ncz-refind-refresh-amd64
grep -n 'mce=nobootlog' /boot/efi/EFI/BOOT/refind.conf      # only the Default entry
```

## 6. Tests

* `build/test-t2-mce-nobootlog.sh` (new) — runs the shipped `NCZ-T2-CMDLINE`
  and `NCZ-DEFAULT-OPTIONS` blocks against fake DMI trees: the token is set and
  assembled into `STABLE_OPTIONS` on every known T2 model
  (MacBookPro16,1 / 15,4 / Air9,1 / Macmini8,1) and **only** there — never in
  `STABLE_CONSOLE_OPTIONS`, `RESCUE_OPTIONS` or `RESCUEPART_OPTIONS`; empty on a
  non-Apple PC, a QEMU VM, a pre-T2 Apple Mac, and when the helper is absent;
  the installer media carries no token.
* `build/test-amd64-t2-detect.sh` (updated) — the detection block now supplies
  `mce=nobootlog` on T2 only.
