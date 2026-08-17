# cix-npu-kmd — the NPU ioctl ABI fix (NOT sufficient on its own)

## What this patch does

`0001-abi-add-is_coredump_en-to-aipu_job_desc.patch` appends one field to
`struct aipu_job_desc` in the 1.0 KMD header:

    __u32 is_coredump_en;

## Why

The userspace driver (`cix-noe-umd 2.0.2`, `libnoe.so.0.6.0`) encodes

    AIPU_IOCTL_SCHEDULE_JOB = _IOW('A', 6, struct aipu_job_desc)

with `sizeof == 136 (0x88)`. The 1.0 KMD's struct is **128 (0x80)**, so the
`_IOC` numbers differ and the kernel answers every schedule with `ENOTTY`.
Measured directly with strace on cixmini, 2026-08-17:

    ioctl(3, _IOC(_IOC_WRITE, 0x41, 0x6, 0x88), ...) = -1 ENOTTY

The UMD reports that as `Job dispatch fail` / `schedule job [fail]`, and
`NOE_Engine.forward()` then reports it as `noe_get_tensor failed` because it
never checks the return of `noe_job_infer_sync` — so the logged error names
the wrong call.

The vendor's 2.0.1 KMD header differs from 1.0 by exactly this one field
(plus an `AIPU_JOB_STATE_COREDUMP` constant and a `core_id`→`partition_id`
rename in another struct, neither of which changes any ioctl size).

## Status: NECESSARY BUT NOT SUFFICIENT

With this patch the ioctl is ACCEPTED and the job dispatches — a real change
from outright rejection. But inference then HANGS: `noe_job_infer_sync` never
returns, and `/proc/interrupts` shows the `aipu` IRQ (68, GICv3 359) with
**zero** interrupts on every CPU. The NPU accepts work and never completes it.

**There is currently nothing demonstrable on the NPU.** Do not enable the
MNEMOS `cix-npu` backend (see assets/agent-stack/mnemos.container) — its
availability check only tests for `/dev/aipu` plus the model file, so
enabling it makes MNEMOS select a backend that hangs rather than fall back
to the working CPU path.

## Where the fix must eventually live

This patch is applied by hand to `/usr/src/cix-npu-kmd-1.0` on cixmini and is
recorded here so it is not stranded. It still needs wiring into whatever
builds `cix-npu-kmd` (meta-cix `recipes-kernel/cix-modules/cix-npu-kmd_1.0.bb`)
before it can ship.
