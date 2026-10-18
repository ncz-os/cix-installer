# MS-R1 NPU ACPI SSDT — delivery mechanism

## The defect

Minisforum MS-R1 (Sky1 / CIX P1) firmware does not describe the NPU compute
cores. `\_SB_.NPU0` exists and enumerates as `CIXH4000:00`, but `CRE0/1/2`
carry no `_HID`, so no platform device is created for them and `aipu` logs:

```
armchina CIXH4000:00: only 0 of 3 NPU cores usable - disabling NPU
```

`assets/npu/ssdt-npucre.asl` fixes this by adding `_HID = "CIXH4010"` (and
`_STA = 0x0F`) to the three cores. Radxa Orion O6/O6N firmware already
describes them correctly; injecting the same SSDT there risks
`AE_ALREADY_EXISTS`, so application is gated.

## Why the override must come from the initramfs

`CONFIG_ACPI_TABLE_UPGRADE=y` (verified in the r290 config,
`7.3.0-rc7-sky1-ncz`) makes the kernel instaload ACPI tables found in an
**uncompressed CPIO archive** as if they came from firmware. The kernel
scans `kernel/firmware/acpi/*.aml` in archives that are:

* **uncompressed** — a gzip/zstd member is skipped, not decompressed;
* **early** — at the front of the initrd, or inside the initramfs root.

An `.aml` that merely sits on the filesystem is never read. There is no
`/sys/kernel/config/acpi` path that would avoid the initrd.

## The mechanism

The override is produced **by the initramfs generator, on every regeneration**:

| Builder | Installed as | Actually does |
|---|---|---|
| dracut (**this image**) | `/usr/lib/dracut/modules.d/91ncz-npu-ssdt/module-setup.sh` | `install()` stages the `.aml` into the image root and builds the early CPIO |
| initramfs-tools (fallback) | `/etc/initramfs-tools/hooks/ncz-npu-ssdt` | stages `kernel/firmware/acpi/ssdt-npucre.aml` into the image root |
| initramfs-tools (safety net) | `/etc/initramfs-tools/post-update.d/zz-ncz-npu-ssdt` | verifies the table survived; re-prepends the CPIO if not |

Both builders source **one** decision helper,
`post-install/lib/npu-ssdt.sh`:

* `ncz_npu_ssdt_decision <meta>` → `apply` or `skip`
* `ncz_npu_ssdt_build_early_cpio <out.cpio> <meta>` → writes the newc archive

They are installed by `post-install/80-npu.sh` (step 3), which also rebuilds
each initrd immediately so a fresh install boots with the override rather than
waiting for the next kernel upgrade.

### Why not `acpi_override=yes` + `acpi_table_dir=` alone

dracut supports that, and it is the mechanism we want. But `acpi_table_dir`
is version-dependent, and when it is absent the setting is ignored **with no
diagnostic** — an initrd without the table, an MS-R1 with no NPU, and nothing
in the logs. The module therefore does not trust the knob: it stages the
payload itself and builds the archive from source.

### Why the previous attempt failed

The r289/r290 images shipped a pre-built CPIO and a `post-update.d` hook that
`cat`'d it in front of `initrd.img-$KVER`. That cannot work:

* `post-update.d` is an **initramfs-tools** path; the image uses **dracut**,
  so the hook never ran;
* even under initramfs-tools it repaired the artifact *after* the generator
  wrote it, so the next regeneration dropped the prepend again.

That is why the mechanism moved *inside* the generator.

## Board gating

Modelled on `ncz_efi_rt_workaround()` (`build/70-bootloader.sh`,
`assets/refind/ncz-refind-refresh.sh`): **known-good boards are checked first
and always win.**

| Priority | Signal | Result |
|---|---|---|
| 0 | `<meta>/NPU_SSDT` = `force` / `skip` | operator override wins |
| 1 | DMI `product_name` matches `Orion O6` / `Orange Pi 6`, or `sys_vendor`/`board_vendor` matches Radxa / Xunlong | **skip** (allow-list) |
| 2 | ≥3 `CIXH4010:*` cores enumerate | **skip** (firmware is fine) |
| 3 | `CIXH4000:00` present with <3 cores | **apply** (the MS-R1 gap) |
| 4 | DMI matches `MS-R1` or `Micro Computer (HK)` | **apply** |
| 5 | anything else | **skip** + warn |

An unreadable DMI with no ACPI signal is a **skip**, not an apply: injecting an
SSDT that scopes `\_SB.NPU0.CRE0..2` into firmware that has no such scope is
itself a boot risk.

The decision runs at *initrd build time*, not at install time — so an image
built on an O6N still applies the override when it is later installed on an
MS-R1, and an MS-R1 that takes a kernel upgrade keeps it.

## Build-time compilation

Only the **source** is committed:

```
assets/npu/ssdt-npucre.asl          committed (ASL)
assets/npu/ssdt-npucre.aml          gitignored — compiled by iasl
assets/npu/npu-acpi-override.cpio   gitignored — packed from the .aml
```

`build/build-npu-ssdt.sh` compiles the ASL with `iasl` (`acpica-tools`) and
packs both outputs reproducibly (`--reproducible`, epoch-0 mtimes). It runs
automatically during `build/stage-canonical-assets.sh`. Nothing binary is ever
committed; `build/npu-ssdt-gate.sh` (`make npu-ssdt-check`) fails the build if
the artifacts are missing or malformed.

## Tests

```bash
make test-npu-ssdt-delivery      # 25 assertions, no root, no hardware
make npu-ssdt-selftest           # gate self-test
```

`build/test-npu-ssdt-delivery.sh` covers: iasl compilation, CPIO layout
(uncompressed newc, exact entry), the DMI gate in both directions including an
adversarial O6N whose vendor string also matches the MS-R1 rule, the ACPI-signal
branches, the operator override, byte-for-byte idempotency, and that both
builders act only on an MS-R1 fixture.

## What is *not* proven here

The archive format and the gate are proven by test; the kernel actually
consuming it is not. Confirmation requires an MS-R1 reboot and:

```bash
dmesg | grep -i 'NPU core num is 3'    # aipu sees 3 cores
ls /sys/bus/acpi/devices/CIXH4010:0*   # CIXH4010:00 .. :02
ls /dev/aipu
```

The orchestrator hardware-tests on `cixmini`; this change does not touch any
test host.
