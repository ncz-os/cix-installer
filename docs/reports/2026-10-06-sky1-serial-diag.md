# Sky1 installer serial diagnostics and ACPI PCIe mode (2026-10-06)

Branch `feat/sky1-serial-diag-20261006`, arm64 (Sky1 / Orion O6N) only. amd64
installer entries, refresh script and runtime behaviour are unchanged (pinned by
`build/test-sky1-serial-diag.sh`).

## Problem

On the r199 installer (`ncz-os-arm64-20261006-d7ab4948.img`, kernel
7.3.0-rc6-sky1-ncz) the O6N saw only `lo`: netcfg waited 60 s and the diag
banner showed `IP=<none>`. The on-screen installer entries carry
`console=tty0` only, so the serial capture on PROTEUS (`/dev/ttyUSB0`,
115200 8N1, board UART `ttyAMA0`) showed nothing and the failure could not be
read remotely until the operator dumped `dmesg` to the UART by hand.

## Root cause of the missing NICs (from that dump)

Of the three Sky1 PCIe controllers only `sky1-pcie-cix.1` (NVMe, bus 90)
probes. All twelve ACPI `PRP0001` fixed regulators fail at 0.2386 s:

    reg-fixed-voltage PRP0001:11: probe with driver reg-fixed-voltage failed with error -12

and at 11.7 s the two NIC controllers are still parked:

    platform sky1-pcie-cix.2.auto: deferred probe pending: platform: supplier PRP0001:11 not ready
    platform sky1-pcie-cix.3.auto: deferred probe pending: platform: supplier PRP0001:10 not ready

The 7.3 port dropped CIX patch 0028 "regulator: add acpi support", so
`reg_fixed_voltage_probe()` returns `-ENOMEM` (`fixed.c`: `if (!config) return
-ENOMEM`) for every ACPI regulator. The supplier links are explicit
`device_link_add()` calls from the Sky1 ACPI resource lookup; the supplier
check honours them regardless of `fw_devlink`, so `fw_devlink=permissive` would
not release the controllers (an earlier commit on this branch added it; it is
removed). The kernel fix is meta-cix `fix/sky1-pcie-reg-fixed-defer-20261006`
(patch 0005) and needs an r285 kernel rebuild, outside this change.

**Experiment:** boot the installer in the installed system's own PCIe mode,
`sky1_pcie_native=off pcie_pnp_en`, on every arm64 installer entry (Install,
Install (expert), Rescue). The installed entries already carry it
(`assets/refind/ncz-refind-refresh.sh` `NEXT_CMDLINE_EXTRA`, appended to every
installed entry), and the 7.2.6 installed boots that had a working NIC used
this mode. With native mode off the Sky1 native PCIe platform devices are not
created, so the firmware-created links have nothing to hold back and the
standard ACPI PCIe host path takes over. Both parameters are present in the
r284 `Image-cixmini.bin`. Unproven on 7.3.0-rc6 metal: on the O6N, look for
the NIC functions in the `[ncz-noiface]` PCI list (or, better, no such block)
and `enp1s0`/`enP*` in d-i.

## Why the serial side is not `console=ttyAMA0`

d-i's `reopen-console` takes a UART from the kernel console list and moves the
newt UI onto it; the monitor goes blank. Both orders did this on real O6N
hardware: `console=ttyAMA0,115200 console=tty0` (0871d09f/65c91e3e; 91060aca
found `ttyAMA0::respawn:/sbin/debian-installer` in `/etc/inittab`) and the
reverse (disproven in 4f262f4c). Ordering cannot fix it, so the on-screen
entries keep `console=tty0` only (now asserted by the test) and the serial
side is provided by `preseed/diag-console.sh`, independent of `/dev/console`.
No `earlycon`: without `keep_bootcon` the early console is dropped when `tty0`
registers at ~0.0001 s, and with it the change to the O6N boot path is
unproven (the UART is the ARMH0011 SBSA device; no SPCR line in the captures).

## What the installer now does on the UART (arm64, diag module enabled)

Started from the baked preseed's early_command, before ethdetect/netcfg, and
kept alive by the module's respawn loop:

1. **Kernel log**: `/dev/kmsg` is replayed from the start of the ring buffer
   and followed onto `ttyAMA0` at every log level, formatted like `dmesg`
   (`quiet loglevel=3` filters printk consoles, not `/dev/kmsg` readers).
2. **Root shell**: busybox `getty` + `login` on `ttyAMA0` at 115200; user
   `root`, password from `ncz_diag_pw` (default `diags`), the same credential
   as telnet. The login shell gets the full static busybox applet farm on
   `PATH` (`dmesg`, `ifconfig -a`, and the PCI list under `/sys/bus/pci/devices`).
3. **Self-documenting no-NIC failure**: when only `lo` exists while netcfg or
   ethdetect runs (or after 120 s of uptime), a one-shot summary is written to
   the UART and to `/var/log/ncz-noiface.txt`: kernel and cmdline, every PCI
   function (`bdf vendor:device class driver`),
   `dmesg | grep -i -E 'pcie|r8169|eth'` and
   `dmesg | grep -E 'deferred probe|reg-fixed|sky1-pcie|r8169'`.

None of it runs when `reopen-console` gave `ttyAMA0` to d-i (the Rescue entry,
which names the UART, or a QEMU boot whose firmware makes it the preferred
console): d-i owns the line and extra writers would land on its dialogs. The
mirror is also skipped when `ttyAMA0` is already a kernel console. Switches:
`ncz_diag=0` disables the whole diag module including this; `ncz_diag_serial=0`
disables only the serial part.

## Installed system

`post-install/36-telemetry.sh` already enables `serial-getty@ttyAMA0` on arm64
only, and the installed entries already carry
`console=ttyAMA0,115200 console=tty0` (tty0 last, so plymouth and the greeter
keep `/dev/console`) plus `sky1_pcie_native=off pcie_pnp_en`. All three are now
asserted on the installed root by `build/verify-installed-target.sh` (section
v-c), with negative cases in `build/test-installed-target-verifier.sh`.

## Using it on the bench

On PROTEUS the serial capture already logs to
`~/o6n-debug-tools/o6n-serial-logs/o6n_persistent.log`; the kernel log and,
on a no-NIC boot, the `[ncz-noiface]` block land there with nobody attached.
An interactive login needs a second reader on `/dev/ttyUSB0`, which would
split bytes with the persistent `dd` logger; that is an operator decision.
With a terminal on the port at 115200, press Enter for `login:` and log in as
`root`.
