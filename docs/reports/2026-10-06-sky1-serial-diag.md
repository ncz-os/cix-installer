# Sky1 installer serial diagnostics and fw_devlink=permissive (2026-10-06)

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

The same `-12` failures are present in the 7.3.0-rc3-sky1-ncz boot of
2026-09-13, where `r8169 0000:01:00.0 enp1s0` came up, so the `-12` is old; what
changed is that fw_devlink now holds the consumer on a supplier that never
binds. The controller that does probe logs `no vcc-pcie regulator found` and
works without one.

**Experiment:** `fw_devlink=permissive` on every arm64 installer entry
(Install, Install (expert), Rescue) and on every installed boot entry
(`assets/refind/ncz-refind-refresh.sh` `NEXT_CMDLINE_BASE`, from which the
default, Mali, Panthor, console, rescue and rescue-partition entries derive).
Permissive keeps the device links for ordering but stops them blocking probe.
To be confirmed on the O6N: `sky1-pcie-cix.2`/`.3` should reach
`sky1_pcie_really_probe end!` and `enp1s0`/`enP*` should appear.

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
   `dmesg | grep -E 'deferred probe|reg-fixed|sky1-pcie'`.

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
keep `/dev/console`). Both are now asserted on the installed root by
`build/verify-installed-target.sh` (section v-c), with negative cases in
`build/test-installed-target-verifier.sh`.

## Using it on the bench

On PROTEUS the serial capture already logs to
`~/o6n-debug-tools/o6n-serial-logs/o6n_persistent.log`; the kernel log and,
on a no-NIC boot, the `[ncz-noiface]` block land there with nobody attached.
An interactive login needs a second reader on `/dev/ttyUSB0`, which would
split bytes with the persistent `dd` logger; that is an operator decision.
With a terminal on the port at 115200, press Enter for `login:` and log in as
`root`.
