# cix-npu-driver-dkms 6.2.0 +ncz3 — the matched NPU stack, hardened

## The stack that actually works (26q2 SDK, all measured on cixmini 2026-08-17)

| deb | version | role |
|---|---|---|
| cix-npu-driver-dkms | 6.2.0-cixdeb13-260714**+ncz3** | KMD (this dir's patches applied) |
| cix-noe-umd | 3.1.4-cixdeb13-260714 | NOE UMD (libnoe 3.1.1) |
| cix-npu-umd | 3.2.0-cixdeb13-260714 | NPU UMD |
| cix-ai-engine | 2.0.0-cixdeb13-260714 | engine |
| cix-ai-test | 1.0.1-cixdeb13-260714 | noe_benchmark + models |

Vendor debs come from ARGONAS
`/mnt/argonas-archives/cix-vendor-sdk/2026q2/cix_noe_sdk_26_q2_release.tar.gz`.
Built artifacts staged on cixmini at `~/npu-stack-hardened/` (with install/verify README).
The older `packaging/cix-npu-kmd` ABI patch (for KMD 1.0 + UMD 2.0.x) is OBSOLETE
with this stack — do not wire it into any recipe.

## The +ncz patches

Root cause it fixes — measured, reproduced on demand, and healed on cixmini:

The three NPU cores are separate ACPI power devices (`\_SB.NPU0.CRE0-2`,
`_HID CIXH4010` via our NPUCRE SSDT), powered by ACPI PowerResources whose
`_ON/_OFF/_STA` toggle bit0 of phys `0x14250200/204/208` (+ a memory-repair
doorbell at `0x14250210-218` that never confirms and is silently ignored by
the ASL too). sky1.c powers them by calling `pm_runtime_get_sync()` on the
core platform devices from the parent's runtime-resume.

The wedge: if the module is removed while the NPU is runtime-PM-forbidden
(`power/control == on` — every debugging session does this), the PM core
unbinds while runtime-active, so `sky1_npu_runtime_suspend()` never runs and
the per-core refs leak; `pm_runtime_disable()` then freezes status "active"
on the CIXH4010 platform devices, which PERSIST across module reloads. The
next probe's `pm_runtime_resume_and_get()` is a silent no-op: ACPI `_ON`
never executes, the cores sit in D3cold, the TSM accepts every job (pool
BUSY forever), and userspace hangs in ppoll with IRQ 68 (GIC SPI 359) at 0.
This wedge — not a broken IRQ, not a broken KMD/UMD — was the "NPU dead"
condition. A clean boot has always worked with the matched stack.

`patches/0001-sky1-runtime-pm-hygiene-for-acpi-core-devices.patch`
(both directions validated):
- probe: normalize stale core PM state (drain leaked usage refs,
  `pm_runtime_set_suspended`) before re-enabling — heals an already-wedged
  system on module load.
- teardown: drain the refs runtime_suspend cannot balance on the
  forbidden-removal path and reset status to match hardware — prevents the
  wedge from forming.

`patches/0002-armchina-npu-use-irq-object-as-dev-id.patch` fixes the MS-R1
boot panic where an early `IRQF_PROBE_SHARED` callback entered the AIPU IRQ
upper half before `armchina_aipu_probe()` had replaced Sky1's temporary
driver data with `struct aipu_priv`.

`patches/0003-sky1-guard-missing-npu-core-platform-devices.patch` fixes the
ACTUAL MS-R1 boot panic root cause (root-caused 2026-08-22 on the live board):
the MS-R1 factory BIOS's DSDT has \_SB.NPU0.CRE0-2 but omits their
_HID="CIXH4010", so Linux creates NO platform devices for the cores unless
the NPUCRE SSDT override (assets/npu/, early-CPIO initrd prepend) is loaded.
`sky1_npu_probe()` then calls `pm_runtime_enable(NULL)` on the failed
`bus_find_device_by_fwnode()` lookup and oopses in `_raw_spin_lock_irqsave`
at `offsetof(struct device, power.lock)` (the photographed 0xcc). With
`oops=panic` every boot dies. O6N never reproduced this because its firmware
provides the _HID natively (CIXH4010:00-02 exist). Any `update-initramfs`
run strips the SSDT prepend (see post-install/80-npu.sh's post-update.d hook),
so the driver MUST survive the no-SSDT case: skip cores with no platform
device and fail probe with -ENODEV when the complement is short (NPU absent
beats a panic, and beats a job-wedging half-probe). The KMD 1.0 tree carried
an equivalent IS_ERR_OR_NULL guard; moving to the vendor 6.2.0 stack had
regressed it.

## Verify (from clean boot; must pass with NO manual power poking)

    sudo systemctl stop ncz-npu-embed; sudo fuser -k /dev/aipu
    mkdir -p /tmp/noeout && cd /usr/share/cix/testdata/npu/onnx_resnet50_3core
    LD_LIBRARY_PATH=/usr/share/cix/lib PATH=/usr/share/cix/bin:$PATH \
      timeout 60 noe_benchmark -b noe.cix -i input0.bin -c output.bin -d /tmp/noeout
    # exit must be 0, log shows 1000/1000 "Test Result Check PASS!",
    # and `grep aipu /proc/interrupts` (IRQ 68) must be >0 and growing.

Wedge regression test (must NOT hang with the NCZ-patched package):

    echo on | sudo tee /sys/devices/platform/CIXH4000:00/power/control
    sudo rmmod aipu && sudo modprobe aipu
    # then run the verify above; restore: echo auto > .../power/control

## Rebuild the +ncz2 deb

    dpkg-deb -R cix-npu-driver-dkms_6.2.0-cixdeb13-260714_arm64.deb pkg
    for p in patches/*.patch; do
      patch -p2 -d pkg/usr/src/aipu-6.2.0 --forward < "$p"
    done
    sed -i 's/^Version: .*/Version: 6.2.0-cixdeb13-260714+ncz3/' pkg/DEBIAN/control
    dpkg-deb --root-owner-group -Zxz -b pkg \
      cix-npu-driver-dkms_6.2.0-cixdeb13-260714+ncz3_arm64.deb

NOTE: the diff was produced against the cixtech `cix_opensource__npu_driver`
`cix_mainline_dev` tree (paths `driver/armchina-npu/...`); strip the leading
`driver/` when applying inside `/usr/src/aipu-6.2.0` (`patch -p2` from that
dir, or -p1 with the layout above).

MNEMOS: category=projects subcategory=ncz-npu (2026-08-17 root-cause memory).
