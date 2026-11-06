# amd64 boot-log noise that is not T2-specific

`post-install/55-t2-firmware.sh` used to write its modprobe.d fixes only after
confirming Apple T2 hardware. Two of the errors it targets also appear on other
amd64 machines; this page records which ones are now fixed on every host, and
which one stays an operator opt-in. Code: `post-install/lib/amd64-boot-noise.sh`
(called by hook 55 before its variant and T2 gates). Test:
`build/test-amd64-boot-noise.sh`.

## pcspkr / snd_pcsp: automatic on every amd64 host

Measured on PEGASUS (ASUS GU502LV, not a T2 Mac), 2026-11-02:

```
Error: Driver 'pcspkr' is already registered, aborting...
```

`pcspkr` (input beeper) and `snd_pcsp` (ALSA PCM) both register a platform
driver named `pcspkr` and both carry `MODULE_ALIAS("platform:pcspkr")`, so udev
loads both for the one PC-speaker device and the second fails. Rule: when any
installed kernel under `/lib/modules` ships **both** drivers (as `.ko*` modules
in either spelling, or listed in `modules.builtin`), hook 55 writes
`/etc/modprobe.d/ncz-pcspkr.conf`:

```
blacklist snd_pcsp
install snd_pcsp /bin/true
```

The input `pcspkr` driver stays, so the terminal bell keeps working. The write
is idempotent (rewritten only when the bytes differ). T2 Macs keep their older
`ncz-t2-pcspkr.conf` too; the two files say the same thing.

## ucsi_ccg on an NVIDIA dGPU: opt-in only

Measured on PEGASUS (RTX 2060 Mobile TU106; UCSI function `01:00.3`,
`10de:1adb`, driver `i2c_nvidia_gpu`):

```
nvidia-gpu 0000:01:00.3: i2c timeout error e0000000
ucsi_ccg 5-0008: i2c_transfer failed -110
ucsi_ccg 5-0008: probe with driver ucsi_ccg failed with error -110
```

On that laptop no USB-C port is wired to the dGPU: firmware `_UPC` marks every
port of the dGPU xHCI (`01:00.2`) as not used, the only Type-C port is the
PCH/Thunderbolt one driven by `ucsi_acpi` (`USBC000`), and nothing answers at
`0x08` on the NVIDIA GPU I2C adapter. Blacklisting `ucsi_ccg` there removes the
error and loses nothing; `i2c_nvidia_gpu` stays bound so the function keeps
runtime PM.

Detection rule for when the blacklist is safe, all three required:

1. the `ucsi_ccg` client sits on the adapter named `NVIDIA GPU I2C adapter`
   (the dGPU's function `.3`, PCI class `0x0c80`, vendor `10de`);
2. after a boot of the installed kernel, its probe failed with `-110`
   (no CCGx controller answering);
3. no USB-C port is wired to the dGPU (`_UPC` of every dGPU xHCI port says
   not connectable, and every `/sys/class/typec` port belongs to another
   controller).

There is **no safe automatic rule**: (2) is only observable after the installed
system has booted, a single timeout can be transient, and (3) needs `_UPC`
parsing of the dGPU xHCI ports. Desktop Turing/Ampere cards with a VirtualLink
USB-C port use the same function and driver for a real port, and blacklisting
`ucsi_ccg` there disables its USB-C PD/alt-mode handling. So the installer does
not do it by itself:

* the hook logs every NVIDIA UCSI function it sees and says the fix is opt-in;
* opt in at install time with `UCSI_CCG_BLACKLIST` containing `yes` in the
  installer meta directory (`/usr/local/lib/cix-installer/`); hook 55 then
  writes `/etc/modprobe.d/ncz-nvidia-ucsi-ccg.conf` (`blacklist ucsi_ccg`);
* on an installed host that meets the three conditions, the same one-line file
  can be dropped in by an agent. Undo: remove the file.
