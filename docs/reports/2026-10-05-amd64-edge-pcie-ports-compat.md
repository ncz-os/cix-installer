# amd64 T2 edge entry: `pcie_ports=compat`

Operator directive 2026-10-05: the amd64 T2 edge boot entry runs with
`pcie_ports=compat`, the PCIe mode the T2 Linux community (T2 Discord) uses as its
baseline on T2 Macs. It is defence in depth, added on top of the AER ANFE revert,
and it applies to the amd64 EDGE entry ONLY. The stable (`7.2.9-2-t2-trixie`),
stable-console and rescue entries are unchanged.

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

The amd64 edge kernel `7.3.0-rc6-1-t2-edge-aerfix` (which already carries the AER
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

Stable + compat has not been tested on hardware either; that is a separate item and
the stable entry is deliberately untouched here.

## Implementation

- `assets/refind/ncz-refind-refresh-amd64.sh` gains one constant,
  `NCZ_T2_EDGE_EXTRA_CMDLINE="pcie_ports=compat"`.
- It is appended to `EDGE_OPTIONS` only, guarded so it is never duplicated and so
  any options already present are preserved. The script regenerates `refind.conf`
  from scratch on every run, so repeated refreshes cannot accumulate the token.
- The stable, stable-console and rescue option strings are not touched.
- The runtime classifier hook `assets/refind/zz1-ncz-refind-refresh-amd64` needs no
  change: it only derives `KVER_STABLE`/`KVER_EDGE` and delegates to the refresh
  script, which owns the command line.
- Test: `build/test-amd64-edge-compat.sh` (token exactly once on edge after one and
  after three refreshes; absent from stable/console/rescue; absent on arm64).

## T2 debug staging tool (out of scope)

`ncz-t2-debug-stage` does not live in this repo; it is in the `amd64-kernel-t2`
repo at `t2-debug/ncz-t2-debug-stage`. It does not share this source of truth: it
reads the generated Stable entry's root options and appends its own additive DEBUG
block of `menuentry`s, leaving the generated part byte-identical. Its debug entries
therefore do not inherit the edge entry's command line and will not carry
`pcie_ports=compat` unless a per-entry 4th-column extra token requests it. No change
was made there; if the debug entries need compat, add it in the spec, not here.
