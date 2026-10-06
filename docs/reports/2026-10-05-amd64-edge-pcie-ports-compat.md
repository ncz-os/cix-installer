# amd64 T2 default entry: `pcie_ports=compat`

Operator directive 2026-10-05: the amd64 T2 **default** boot entry runs with
`pcie_ports=compat`, the PCIe mode the T2 Linux community (T2 Discord) uses as its
baseline on T2 Macs. It is defence in depth, added on top of the AER ANFE revert in
the unified 7.3 kernel. It applies to the amd64 DEFAULT entry ONLY, and ONLY on
Apple T2 hardware. Under the unified 7.3 policy (operator 2026-10-05, same day) the
separate edge entry was retired, so the token moved from the old edge entry onto the
default entry; the console and rescue entries are unchanged, and so is every generic
PC (including non-T2 Intel Macs, VMs and servers).

The x86 kernel is UNIFIED: the same image installs onto T2 Macs and ordinary PCs, so the
parameter cannot be an image-build-time constant. It is decided on the target machine at
entry-generation time by `assets/refind/ncz-t2-detect.sh` (DMI `sys_vendor` "Apple Inc."
plus a `product_name` from the known T2 model set), which the refresh script sources. On a
generic PC `pcie_ports=compat` would needlessly switch off AER/PME/native PCIe hotplug for
no benefit, so detection fails closed to "no parameter" whenever it cannot prove T2.

## What `pcie_ports=compat` changes on T2

`pcie_ports=compat` selects the "compat" PCIe port-driver mode: the OS still assumes
control of the PCIe port services under the ACPI `_OSC` grant, but the native port
driver does not claim the ports. In practice:

- No native AER service is registered (the AER handler is not bound to the root/port
  devices).
- No native PME service and no native PCIe hotplug service are registered.
- ACPI hotplug (`_OSC`-granted `SHPCHotplug`) still works; the firmware handles it.
- Native Thunderbolt hotplug behaviour may differ (the Thunderbolt controller is a
  PCIe port service consumer).

So compat removes the kernel's own port-service machinery without blocking the
firmware's `_OSC` handshake.

## MEDUSA evidence (MacBookPro16,1)

The amd64 kernel `7.3.0-rc6-1-t2-edge-aerfix` (which already carries the AER
ANFE revert) was booted with `pcie_ports=compat`:

- Stayed up 30+ minutes with all four DKMS modules loaded (`t2smc`, `t2gmux`,
  `t2smp`, `t2thunderbolt`); screen and hwmon working.
- dmesg still showed the firmware grant:
  `_OSC: OS assumes control of [PCIeHotplug SHPCHotplug AER PCIeCapability LTR DPC]`.
- dmesg showed `pcie_portdrv_init returned -13` and `/sys/bus/pci_express/devices`
  was empty -- i.e. compat disabled the port services without blocking the grant.

## What is NOT tested

Whether `pcie_ports=compat` **alone** (without the AER ANFE revert) avoids the
original T2 power cut is untested. The revert therefore stays. compat is added only
as defence in depth and to match the community baseline, not as a replacement.

Default-7.3 + compat has been booted on MEDUSA (above); the kernel geometry is the
same as the edge build this token was originally validated on.

## Implementation

- `assets/refind/ncz-t2-detect.sh` is a small, separately testable helper. It defines
  `ncz_is_t2_hardware()` (DMI `sys_vendor` "Apple Inc." AND `product_name` in the T2 set
  MacBookPro15,1-4 / 16,1-4, MacBookAir8,1-2 / 9,1, iMac19,1-2 / 20,1-2, iMacPro1,1,
  Macmini8,1, MacPro7,1 -- source: T2 Linux wiki, which links Apple support HT208862), with
  `NCZ_DMI_ROOT` overridable for tests. It also defines an advisory
  `ncz_t2_pci_bridge_present()` ([106b:1801]/[106b:2005] via sysfs, no tools), used only in
  the diagnostic log. Detection fails closed: missing/unreadable DMI or an unknown model is
  "not T2". The same helper also drives the amd64 rescue accelerator blacklist.
- `assets/refind/ncz-refind-refresh-amd64.sh` sources that helper from its staged
  `assets/refind/` location (a missing helper also fails closed) and sets
  `NCZ_T2_DEFAULT_EXTRA_CMDLINE="pcie_ports=compat"` only when `ncz_is_t2_hardware`
  returns 0.
- The token is appended to `STABLE_OPTIONS` (the DEFAULT entry) only, guarded so it is
  never duplicated and any options already present are preserved. The script regenerates
  `refind.conf` from scratch on every run, so repeated refreshes cannot accumulate the
  token.
- The console and rescue option strings are not touched.
- The runtime classifier hook `assets/refind/zz1-ncz-refind-refresh-amd64` needs no
  command-line change: it derives the single default KVER and delegates to the refresh
  script, which owns the command line.
- Tests: `build/test-amd64-t2-detect.sh` and `build/test-amd64-t2-default-compat.sh`
  (registered in the Makefile `parity` target). They drive the shipped DMI detector with
  fake `/sys/class/dmi/id` trees: MacBookPro16,1 and the other T2 models -> yes;
  MacBookPro11,1 (pre-T2), an ASUS desktop, QEMU/KVM, an unlisted Apple model and missing
  DMI files -> no. They then run the shipped T2-cmdline and option-assembly blocks: token
  exactly once on the DEFAULT entry after one and after three refreshes on T2, never on
  console/rescue, never on a generic PC, operator options preserved, and never on arm64.

## T2 debug staging tool (out of scope)

`ncz-t2-debug-stage` does not live in this repo; it is in the `amd64-kernel-t2`
repo at `t2-debug/ncz-t2-debug-stage`. It does not share this source of truth: it
reads the generated Stable entry's root options and appends its own additive DEBUG
block of `menuentry`s, leaving the generated part byte-identical. Its debug entries
therefore do not inherit the edge entry's command line and will not carry
`pcie_ports=compat` unless a per-entry 4th-column extra token requests it. No change
was made there; if the debug entries need compat, add it in the spec, not here.
