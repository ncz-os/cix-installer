# Driver fidelity — CIX Sky1 (Radxa Orion O6N)

This document records the measured state of each accelerator on the shipping
kernel, `7.2.0-sky1-ncz`. NCZ-OS 26.7 ships one kernel; the earlier 7.0.12
channel has been removed from the image. `DRIVER_FIDELITY_7012.md` is retained
as history for boards that received it.

Measurements were taken on **Radxa Orion O6N**. Each result is dated, because
driver behaviour changes between vendor SDK revisions.

> **The bar is function, not presence.** A device node, a clean probe and a
> printed banner are not evidence that an accelerator works. The NPU section
> below is the cautionary case: `/dev/aipu` existed, the driver probed, the
> ZHOUYI V3 banner printed, and the hardware could not run a single inference.
> Every claim here is backed by a workload.

> **Status (2026-08-18): the NPU works.** The board ships the 26Q2-SDK DKMS
> driver `aipu/6.2.0` (`cix-npu-driver-dkms`, source `npu-kmd-mainline`).
> Inference is confirmed on both an O6N and a Minisforum MS-R1:
>
> | | |
> |---|---|
> | model | `nomic-embed-text-v1.5_256.cix` (768-dim) |
> | latency | 95.5 ms per 256-token chunk |
> | interrupts | `aipu` IRQ 0 → 11,410 across the run |
> | determinism | bit-identical across repeated runs |
>
> **The earlier "query capability [fail]" fault was a userspace version
> mismatch, not a driver defect.** `/opt/ncz/noe-venv` held libnoe 2.0.0 and
> NOE-Engine 2.0.0 against a 6.2.0 kernel driver. An older user-mode driver
> cannot query a newer kernel driver's capabilities, so context init failed
> before any job was dispatched — which reads as a dead NPU. Re-syncing the
> venv to libnoe 3.1.3 / noe_engine 3.0.0 resolved it immediately.
>
> Two consequences for readers of the sections below:
>
> * **Do not treat `CONFIG_ARMCHINA_NPU=n` as a regression.** The DKMS driver
>   is the intended path and matches how the GPU and VPU are already shipped.
> * **Do not use the 2.0.1 panic evidence as a reason to avoid the current
>   driver.** It documents a different, older driver. It remains useful as
>   evidence that an out-of-tree NPU driver *can* fail badly, and the
>   boot-loop trap it describes is real.

## Contents

- [Summary](#summary)
- [GPU — Mali-G720-Immortalis (DKMS, working)](#gpu--mali-g720-immortalis-dkms-working)
- [VPU — Linlon / amvx (DKMS, working)](#vpu--linlon--amvx-dkms-working)
  - [Encoding requires an explicit `-pix_fmt`](#-encoding-requires-an-explicit--pix_fmt)
- [NPU — ArmChina Zhouyi V3](#npu--armchina-zhouyi-v3)
  - [Out-of-tree (DKMS) — 2026-08-04 sources, superseded](#out-of-tree-dkms--2026-08-04-sources-superseded)
  - [NPU userspace](#npu-userspace)
- [RTC — `rtc-efi`](#rtc--rtc-efi-working)
- [Boot time — `rootdelay=90`](#boot-time--rootdelay90)
- [DKMS prerequisites](#dkms-prerequisites)
- [Reproducing these results](#reproducing-these-results)

---

## Summary

| Accelerator | Ships as | Status | Evidence |
|---|---|---|---|
| GPU (Mali-G720-Immortalis) | **DKMS** | working | GLES 3.2 + Vulkan 1.3 bound to real HW, 1.0 GHz |
| VPU (Linlon / amvx) | **DKMS** | working | HW decode + HW encode, round-tripped |
| NPU (ArmChina Zhouyi V3), in-tree, `armchina_npu` | **in-tree** | working, but the OLD driver being migrated off | 62.6–62.8 inf/s sustained (2026-08-04) |
| NPU (ArmChina Zhouyi V3), 26Q2 SDK DKMS, `aipu.ko` | **DKMS** | intended path; context-init bug under investigation (2026-08-17) | see correction note above — NOT the 2.0.1 driver that panicked |
| panthor | DKMS | builds/installs | blacklisted on the Mali entry; not runtime-tested |
| RTC | in-tree (`rtc-efi`) | working | `/dev/rtc0`, `hctosys=1`, survives reboot |

Modules load from `/lib/modules/<KVER>/updates/dkms/`.

---

## GPU — Mali-G720-Immortalis (DKMS, working)

`cix-gpu-kmd/1.0` → `mali_kbase`, `memory_group_manager`,
`protected_memory_allocator`.

```
kbase sysfs : Mali-G720-Immortalis 10 cores r0p0 0x0C080700
devfreq     : CIXH5000:00 @ 1000000000 (max OPP)
GLES        : renderer Mali-G720-Immortalis, OpenGL ES 3.2, Valhall r53p0
Vulkan      : deviceName Mali-G720-Immortalis, apiVersion 1.3.296,
              46.70 GiB device-local heap
```

This is real hardware, not software rendering — the identity string and core
count are read back from the GPU through kbase sysfs.

**Not yet proven: a sustained render benchmark.** `glmark2` cannot run here
because the greeter session (`_greetd`) does not expose an EGL canvas to an
external caller, so `eglInitialize()` fails with `0x3001`. Device-level
interrogation is solid; a frame-rate figure is still outstanding. Do not quote
GPU throughput numbers until that gap is closed.

---

## VPU — Linlon / amvx (DKMS, working)

`cix-vpu-driver/1.0.2` → `amvx`. Nodes: `/dev/video0` mvxdec, `/dev/video1`
mvxenc, plus `mvxjpegdec` / `mvxjpegenc`.

```
decode : 90 frames H.264 → yuv420p
         driver 'mvx' on card 'Linlon Video device' in mplane mode
encode : 30 frames → valid H.264 640x480, decodes back clean (ffmpeg rc=0,
         ffprobe: codec_name=h264, 640x480, nb_read_frames=30)
```

### ⚠ Encoding requires an explicit `-pix_fmt`

**Symptom.** Hardware encode appears broken:

```
$ ffmpeg -f lavfi -i testsrc=... -c:v h264_v4l2m2m out.h264
Error submitting video frame to the encoder
Error encoding a frame: No such device
Task finished with error code: -19 (No such device)
```

Zero-byte output. `-19 ENODEV` strongly implies a missing or broken device, and
points nowhere near the real cause.

**Actual cause — an ffmpeg negotiation gap, NOT a driver defect.** With
`-v verbose`:

```
[h264_v4l2m2m] requesting formats: output=RGB3/rgb24 capture=H264/none
```

ffmpeg asked the encoder for packed 24-bit RGB. Two things combine:

1. `ffmpeg -h encoder=h264_v4l2m2m` lists **no pixel formats at all** — the
   v4l2m2m encoder declares an empty `pix_fmts` array, because it cannot know a
   device's formats until it opens one. Format negotiation therefore has no
   constraint to work against.
2. If the source emits RGB (e.g. `testsrc` produces rgb24), ffmpeg passes it
   straight through instead of inserting a scaler.

`mvxenc` advertises 17 input formats and does include `BA24` (32-bit ARGB) and
`RGB4` (32-bit A/XRGB) — but **not** packed 24-bit `RGB3`. The driver correctly
rejects a format it does not implement; ffmpeg reports it as `ENODEV`.

**Fix — always pass `-pix_fmt nv12`:**

```sh
ffmpeg -i input.mp4 -pix_fmt nv12 -c:v h264_v4l2m2m -b:v 4M out.h264
```

`nv12` is the best choice: it is the device's native semi-planar layout
(`NV12`, index 5) and avoids a conversion. `yuv420p` (`YU12`, index 7) and
`nv21` (`NV21`, index 9) also work.

**Full `mvxenc` input format list**, in device enumeration order:

```
[0] Y0A8  YUV420 AFBC 8 bit      [9]  NV21  Y/VU 4:2:0
[1] Y0AA  YUV420 AFBC 10 bit     [10] M010  YUV 4:2:0 P010 (Microsoft)
[2] Y2A8  YUV422 AFBC 8 bit      [11] P010  10-bit Y/UV 4:2:0
[3] Y2AA  YUV422 AFBC 10 bit     [12] YUYV  YUYV 4:2:2
[4] NM12  Y/UV 4:2:0 (N-C)       [13] UYVY  UYVY 4:2:2
[5] NV12  Y/UV 4:2:0             [14] Y210  10-bit YUYV packed
[6] YM12  Planar YUV 4:2:0 (N-C) [15] BA24  32-bit ARGB 8-8-8-8
[7] YU12  Planar YUV 4:2:0       [16] RGB4  32-bit A/XRGB 8-8-8-8
[8] NM21  Y/VU 4:2:0 (N-C)
```

Output (capture) side: `H264`, `HEVC`, `VP80`, `VP90`.

Note the first four entries are **AFBC** (ARM Frame Buffer Compression). That
is the zero-copy path from the Mali GPU and is where a GPU→VPU pipeline's real
performance lives — but nothing in the ffmpeg path can produce AFBC buffers.

---

## NPU — ArmChina Zhouyi V3

### In-tree (`armchina_npu`) — superseded by the DKMS driver

```
62.6–62.8 inf/s, 15.9 ms avg
model /opt/ncz/models/bge-small-zh-v1.5_256.cix, 3 inputs / 2 outputs
6 memory regions initialised, ASIDs 0–5 programmed
```

These figures were taken in 2026-08-04 against the in-tree driver. The
shipping configuration is now `CONFIG_ARMCHINA_NPU=n` with the DKMS driver
providing `/dev/aipu`; see the status note at the top of this document.

### Out-of-tree (DKMS) — 2026-08-04 sources, superseded

**Neither driver measured below is the one currently shipped.** As of
2026-08-17 the board ships the 26Q2-SDK `cix-npu-driver-dkms 6.2.0` (source
`npu-kmd-mainline`), a third, different out-of-tree driver not covered by
this section — see the correction note at the top of this document. This
section stays as historical evidence that out-of-tree NPU drivers CAN fail
badly (including a real kernel panic) and the boot-loop trap that follows
from one doing so is real and must be understood before staging ANY
out-of-tree NPU driver — but do not read "DO NOT ENABLE" as current guidance
for the driver actually shipping today.

Two separate out-of-tree sources were tried in 2026-08-04's pass; both fail, differently:

* **minisforum `cix_opensource__npu_driver`** — probes, then
  `driver mem management is disabled`: no memory regions, no ASIDs, and job
  dispatch fails (`[UMD ERR] aipu.cpp:208: schedule job [fail]` /
  `noe_job_infer_sync: Job dispatch fail`). The graph loads and the job is
  created; the hardware simply never runs it.
* **official `cix-npu-driver_2.0.1`** (`/usr/src/aipu-5.11.0`) — builds cleanly
  after four fixes (below), then **panics the kernel at probe**:

```
aipu_mm_reserved_iova_for_never_map+0x7c/0xc0 [aipu]
aipu_init_mm+0x3f0/0xb38 [aipu]
armchina_aipu_probe+0x140/0x160 [aipu]
Unable to handle kernel paging request at virtual address ffffb5e486711a58
```

Both point at the same thing: the out-of-tree memory-manager init does not work
on this platform. This is a **driver** problem, not packaging.

**Three properties turn that panic into an unrecoverable boot loop.** All three
must be understood before anyone stages this driver again:

1. The edge cmdline carries `oops=panic panic=6`, so a probe oops reboots the
   board.
2. The official `dkms.conf` sets `AUTOINSTALL="yes"`, which registers the driver
   for **every** kernel, not just the one targeted.
3. Blacklisting `armchina_npu` does **not** stop `aipu` loading — different
   module names. Blacklist `aipu` as well, or do not install it at all.

**Rule: never make an unproven accelerator driver the boot-time default.**
Build it, then `modprobe` it on an already-running system, so a crash costs one
reboot rather than a loop.

**Recovery**, from a console or rescue root, on the main rootfs:

```sh
find /lib/modules -name 'aipu.ko*' -path '*updates*' -delete
dkms remove -m aipu -v 5.11.0 --all
rm -rf /usr/src/aipu-5.11.0 /var/lib/dkms/aipu
rm -f /etc/modprobe.d/blacklist-armchina-npu.conf   # restore the WORKING driver
depmod -a
```

**Gate for ever flipping `CONFIG_ARMCHINA_NPU` to `n`:** an out-of-tree-only
boot that reproduces ~62 inf/s. Not a device node. `INTREE_ACCEL_POLICY` in
[`build/kernel-manifest.py`](../build/kernel-manifest.py) keeps this symbol at `warn` for exactly this reason.

### Build fixes for the official DKMS source (kept for future work)

The recipe below produces a correct `aipu.ko`; the driver is what is broken.

1. The vendor Makefile prefixes every object with `$(SRC_DIR)/` = `./`. kbuild
   cannot then match those paths to its build targets, so `KBUILD_MODNAME`
   falls back to each *file's* basename. `.modinfo` keys come out as
   `sky1.license=` and `aipu_dma_buf.import_ns=` instead of `license=` /
   `import_ns=`, and modpost fails with `missing MODULE_LICENSE() in aipu.o`
   plus a wall of `uses symbol dma_buf_* from namespace DMA_BUF, but does not
   import it`. **The symptoms look like missing macros; it is a path bug.**
   Fix: `sed -i 's|$(SRC_DIR)/armchina-npu/|armchina-npu/|g' Makefile`
2. Include paths are built from `$(PWD)`, which under `make -C <kernel> M=<dir>`
   is not the module directory. Pass `PWD=<dkms build dir>` explicitly. (The
   vendor also uses `EXTRA_CFLAGS`, which modern kbuild ignores — pass `-I`
   flags via `KCFLAGS`.)
3. The kernel config sets **both** `CONFIG_ARMCHINA_NPU_ARCH_V3` and `_V3_1`,
   and `autoconf.h` leaks into the out-of-tree build, so `aipu_priv.c`
   references `get_v3_1_priv_ops()` — but the Makefile's `BUILD_ZHOUYI_V3`
   branch only compiles `v3.o`/`v3_priv.o`. Override `AIPU_OBJ` to add
   `v3_1.o` and `v3_1_priv.o`.
4. 7.2 API churn in `armchina-npu/sky1/sky1.c`: `pm_runtime_put()` returns void
   (2 sites), and `platform_driver::remove` is
   `void (*)(struct platform_device *)` so `sky1_npu_remove` must return void.
   `MODULE_IMPORT_NS()` also needs a string literal since v6.13
   (`aipu_dma_buf.c`).

### NPU userspace

`cix-noe-umd`'s postinst runs `pip3 install <wheel> --break-system-packages`
against the **system** interpreter. Debian forky ships Python 3.14; the wheels
pin `Requires-Python >=3.11,<3.13`:

```
ERROR: Package 'libnoe' requires a different Python: 3.14.6 not in '<3.13,>=3.11'
```

dpkg then leaves the package half-configured (`iF`), which blocks later apt
transactions. forky has no python3.11/3.12 packages.

[`post-install/88-noe-umd-venv.sh`](../post-install/88-noe-umd-venv.sh) handles this: uv installs a standalone
CPython 3.12, builds `/opt/ncz/noe-venv`, installs the wheels **plus numpy**
(`NOE_Engine` imports numpy at module scope but does not declare it), and
completes dpkg's own postinst with `pip3` temporarily shimmed to that venv —
removed immediately after, since a permanent `/usr/local/bin/pip3` redirect
would capture every other pip3 user on the box. Wrapper: `ncz-npu-python`.

Import name is `NOE_Engine` (capitalised), not `noe_engine`.

---

## RTC — `rtc-efi` (working)

```
/dev/rtc0, driver rtc-efi, hctosys=1, RTC in local TZ: no
```

The O6N RTC is **firmware-owned**: ACPI `Device (ERTC)`, `_HID "ERTC0000"`,
`_STA = Zero` (so Linux never enumerates it), driving a Cadence I2C controller
at `0x04040000` that is not among the buses exposed to Linux. UEFI runtime
`GetTime`/`SetTime` is the only path to it.

`efi=noruntime` therefore removes the **only** route to the clock: it clears
`EFI_RT_SUPPORTED_TIME_SERVICES`, so `drivers/firmware/efi/efi.c` never
registers the `rtc-efi` platform device and the board boots with no RTC at all.

That flag is an **MS-R1** firmware workaround. It is gated on the board via
`ncz_efi_rt_workaround()` (DMI `product_name`/`sys_vendor`) rather than on the
kernel, which is the correct axis: the workaround tracks firmware behaviour,
not kernel version. Verified on O6N.

---

## Boot time — `rootdelay=90`

Boot is dominated by one cmdline parameter:

```
Startup finished in 1min 32.798s (kernel) + 8.914s (userspace) = 1min 41.712s
```

Userspace is fast. The kernel reaches `Freeing unused kernel memory` at
**1.7s**, then nothing happens until systemd starts at **93.2s**. The root
device is ready long before that — `nvme0n1: p1 p2 p3` appears at **1.2s**.

The initramfs consumes `ROOTDELAY` **twice**, and the two uses differ:

* `init:235` — an **unconditional `sleep "$ROOTDELAY"`**, paid on every boot
  whether or not the device is present. This is the ~90 seconds.
* `scripts/local:83` — the **timeout cap** on the root-device poll loop, which
  *is* load-bearing.

`rootdelay=90` was added by `7efb79a` ("fix(boot): add rootdelay=90 to all root= cmdlines (initramfs timeout)") to fix a real, root-caused panic loop:
`rootwait` is a kernel-level no-op when booting via initramfs-tools, whose
`scripts/local` has an independent timeout that reads only `ROOTDELAY`. With the
30s default, NVMe enumeration occasionally overran it and the board landed in
"Gave up waiting for root file system device" — observed across 443 POST cycles.

**So do not simply remove `rootdelay=90`.** The cap is needed; only the
unconditional sleep is waste. The fix is an initramfs hook that raises
`scripts/local`'s `slumber` directly while leaving `ROOTDELAY` unset, keeping
the 90s tolerance at ~10s boot cost. Not yet implemented.

---

## DKMS prerequisites

The shipped kernel headers cannot build anything until
[`post-install/79-dkms-prep.sh`](../post-install/79-dkms-prep.sh) repairs four defects. See that script's header
comment; the two most surprising:

* `scripts/basic/fixdep` and `scripts/mod/modpost` are Yocto **build-host**
  binaries linked against `/ybuild/tmp/sysroots-uninative/...`. That interpreter
  does not exist on target, so kbuild reports "not found" for a file that is
  plainly present. Detect by **trying to execute** (exit 126/127), never with
  `file(1)` — `file` is absent on a minimal system and gating on it makes the
  check silently pass.
* Yocto passes `KERNEL_LOCALVERSION` out-of-band, so the shipped `.config` has
  `CONFIG_LOCALVERSION=""` and no `localversion*` file. Anything regenerating
  the release string on target produces `7.2.0-rc6` instead of
  `7.2.0-rc6-sky1-ncz`, and **every** module built there is stamped with a
  vermagic that will not load.

---

## Reproducing these results

Every figure above comes from these commands, run on the target. They are listed
so the claims can be re-checked after a kernel bump rather than taken on trust.

```sh
# GPU — identity read back from hardware, not a driver string
cat /sys/class/misc/mali0/device/gpuinfo
cat /sys/class/devfreq/CIXH5000:00/cur_freq
EGL_PLATFORM=surfaceless eglinfo | grep -i "profile renderer"
vulkaninfo --summary | grep -m1 deviceName

# VPU decode
ffmpeg -f lavfi -i testsrc=size=640x480:rate=30:duration=3 \
       -c:v libx264 -pix_fmt yuv420p -y /tmp/t.h264
ffmpeg -c:v h264_v4l2m2m -i /tmp/t.h264 -f null -

# VPU encode — note the mandatory -pix_fmt
ffmpeg -f lavfi -i testsrc=size=640x480:rate=30:duration=1 \
       -pix_fmt nv12 -c:v h264_v4l2m2m -b:v 2M -y /tmp/e.h264
ffprobe -show_entries stream=codec_name,width,height,nb_read_frames \
        -count_frames /tmp/e.h264          # must decode back clean

# VPU format enumeration (the table above)
v4l2-ctl -d /dev/video1 --list-formats-out

# NPU — inference, NOT just /dev/aipu
ncz-npu-python -c '
import time, numpy as np
from NOE_Engine import EngineInfer
e = EngineInfer("/opt/ncz/models/bge-small-zh-v1.5_256.cix")
ins = [np.zeros(getattr(d,"size",1024)//np.dtype(e.input_type[i]).itemsize,
                dtype=e.input_type[i]) for i,d in enumerate(e.in_tensor_desc)]
e.forward(ins); t0=time.time()
for _ in range(30): e.forward(ins)
el=time.time()-t0
print(f"{el*1000/30:.2f} ms avg, {30/el:.1f} inf/s"); e.clean()'

# RTC
ls -la /dev/rtc0; cat /sys/class/rtc/rtc0/name /sys/class/rtc/rtc0/hctosys
timedatectl | grep -E "RTC time|local TZ"

# where every module actually came from
for m in mali_kbase memory_group_manager protected_memory_allocator amvx; do
    printf '%-28s %s\n' "$m" "$(modinfo -n $m)"
done

# boot-time breakdown
systemd-analyze; systemd-analyze blame | head
dmesg | grep -E "nvme0n1: p1|Freeing unused kernel|systemd\[1\]: Detected"
```

Vermagic of every staged module must equal `uname -r` exactly — a mismatch means
the module silently will not load:

```sh
for m in /lib/modules/$(uname -r)/updates/dkms/*.ko*; do
    printf '%-34s %s\n' "$(basename $m)" "$(modinfo -F vermagic $m)"
done
```

---

# Addendum 2026-08-04 — GPU driver decision, acceleration matrix, deploy gotchas

Everything below was measured on the O6N (`7.2.0-rc6-sky1-ncz`, Mali boot)
during the 2026-08-04 validation session.

## GPU driver decision: Mali is the default; Panthor ships as a supported option

**SUPERSEDED 2026-08-16.** This section previously read *"Mali only. There is no
panthor boot entry"* and stated Panthor was not shippable. That is no longer
true, and the correction matters: NCZ-OS 26.7 ships a Panthor boot entry.

### What the blocker was

Panthor died on the **first user `DRM_IOCTL_PANTHOR_VM_BIND`** (`err=110
ETIMEDOUT`). The Sky1 IDM (interconnect defense) revoked the GPU's non-secure
bus-master grant on the first user-address-space transaction and isolated the
GPU: the MCU stayed `ENABLED` but memory-blind, reset could not recover
(`AS_ACTIVE` stuck, L2 transition timeouts), and every trapped access made TF-A
print `IDM: GPU secure access` synchronously on the UART — enough of them
stalled every core. Filed as **cixtech/cix-linux-main#59**.

### Why it no longer happens

The GPU is now un-secured at probe through the ACPI power-supply `_PR0` method
(patch `0175-drm-panthor-sky1-acpi-power-supply-unsecure`), with an SMC
power-on fallback (patch `0176`). The probe log shows both steps:

```
panthor CIXH5000:00: GPU power domain 21 powered on via SMC SCMI
panthor CIXH5000:00: Sky1: GPU un-secured via ACPI power-supply (_PR0)
```

Because the grant is established before any user transaction, the IDM never
revokes it, so the failure the old text describes cannot arise. Note this is a
*driver-side* fix in our tree — it does not depend on new CIX secure firmware,
and the earlier warning against kernel-side **re-grant recovery after the fact**
still stands: recovering from a revocation is what triggered the EL3 print
storm. Preventing the revocation is a different thing and works.

### Evidence (O6N, 7.2.0-rc7-sky1-ncz, 2026-08-16)

Sustained real GPU work, not enumeration:

- full `glmark2-es2-drm` suites at native **4096x2160**, plus terrain, refract,
  shadow, buffer, texture and desktop scenes, and repeated windowed runs
- `panthor ERR: 0` in every bench, `0` panthor errors in the boot journal
- **`IDM: GPU secure access` — 0 occurrences across every boot on the box**
- `0` occurrences of `VM_BIND`, `ETIMEDOUT`, `AS_ACTIVE` failures
- the board stayed responsive throughout; no print storm, no power cycle needed

### What ships

| Boot entry | Driver | Status |
|---|---|---|
| `7.2 GUI (Mali, Default)` | `mali_kbase` + CIX proprietary userspace | default |
| `7.2 GUI (Panthor, Experimental)` | `panthor` + Mesa panfrost/PanVK | supported option |

Selection is the `sky1.gpu=vendor|mesa` kernel cmdline token, applied by
`ncz-gpu-switcher`, which also swaps the matching userspace half so the two can
never end up mismatched. `/etc/modprobe.d/ncz-panthor-deferred.conf` is retired;
both drivers are held in `ncz-gpu-drivers.conf` and the winner is loaded
explicitly.

Mali remains the default because it is faster on shader- and geometry-bound
work (terrain 4.0x, refract 4.3x, measured offscreen and compositor-free) and
exposes GLES 3.2 against Panthor's 3.1. The two are equal on bandwidth-bound
work. See `docs/DESIGN-RATIONALE.md` section 1 for the full comparison and the
four measurement confounds that had to be eliminated to get honest numbers.

Panthor also carries a Sky1 DVFS fix (patch `0177`): under ACPI it had been
voting the performance state on the wrong power domain, leaving the GPU at a
fixed clock. Fixed, it ramps to 1000 MHz under load — glmark2 1080p
**2030 -> 3641 (+79%)**.

## Acceleration matrix (all verified on metal)

| Consumer | Path | Result |
|---|---|---|
| mpv / ffmpeg / gst **decode** | CIX VAAPI (VPU) → dmabuf → Wayland → linlondp overlay, zero-copy | 1080p30 H.264 at **~7% CPU** (software: ~82%) |
| ffmpeg **encode** (`h264_vaapi`) | CIX VAAPI (VPU) | **13.2× realtime** at 1080p30, valid High profile |
| Chrome 151 rendering | ANGLE on libmali blob (GLES 3.2) | Canvas/Compositing/Raster/WebGL/**WebGPU** all hardware |
| Chrome 151 video decode | blocked: same `FillProfileInfo` probe failure — the chrome://gpu "Hardware accelerated" line is only the feature toggle; the Video Acceleration capability table is empty and no Chrome process opens an mvx node during playback (verified: ~2 cores of software VP9) | Software (cixtech#60) |
| Chrome 151 video encode | blocked: CIX VA driver fails Chrome's `FillProfileInfo` attribute probe | Software (cixtech#60) |
| Native GLES Wayland apps | blob wayland winsys via `ncz-gpu-env` | glmark2-es2-wayland score **7110** |
| LLM inference (llama.cpp) | **CPU only — never ship a GPU backend**, see below | gemma-4 E4B: 36.2 t/s prompt, 7.68 t/s generation |
| Embeddings | **NPU** (Zhouyi, via NOE) | nomic-embed-text-v1.5 768-dim, 8.9 inf/s, cosine 0.9953 vs x86 |
| Compositor (labwc/wlroots) | **GPU-accelerated**: wlroots GLES2 renderer on the libmali blob EGL, KMS/scanout on linlondp (`WLR_DRM_DEVICES=/dev/dri/card1`). labwc holds `/dev/mali0` open+mmapped, no pixman fallback in its log, and it advertises `zwp_linux_dmabuf_v1` + `wl_drm` so clients pass GPU buffers zero-copy | Hardware — measured 0% CPU over 10s of desktop animation |

The split-device architecture is worth stating plainly, because it is easy to
assume the opposite: `mali_kbase` exposes a misc char device (`/dev/mali0`,
major 10) rather than a DRM render node, so the *rendering* device and the
*scanout* device are different subsystems. wlroots is told to modeset on
linlondp (`/dev/dri/card1`) while its GLES2 renderer runs through the blob's
EGL/GBM shim on `/dev/mali0`. That combination works: the compositor, the
Singularity shell, Xwayland and Chrome all hold `/dev/mali0` concurrently.

The consequence that *is* real: **panvk/Mesa cannot drive this stack** — the
open Vulkan and GL drivers need a DRM render node, which kbase does not
provide. Vulkan on the Mali boot comes from the blob ICD
(`/etc/vulkan/icd.d/mali.json`, pinned via `VK_DRIVER_FILES` in
`ncz-gpu-env`), not from Mesa.

VA-API driver selection has a subtlety worth knowing: because `mali_kbase`
exposes no DRM render node, **every** render node on this SoC reports
`DRIVER=linlondp`, so libva's auto-detection computes `linlondp_drv_video.so`
— a display driver name, not a codec driver. `post-install/84-vpu-vaapi.sh`
installs a compat symlink to `libcix_va_drv_video.so`, which is the durable
fix: it works for sandboxed consumers that never inherit environment
variables. `LIBVA_DRIVER_NAME=libcix_va` is additionally exported by
`ncz-gpu-env` and `/etc/environment.d/60-ncz-vaapi.conf` (greetd's PAM stack
does not apply `/etc/environment`). mpv defaults live in `/etc/mpv/mpv.conf`
(`post-install/84-vpu-mpv.sh`).

Required vendor userspace (2026Q2 `cix-mm` bundle): `cix-vaapi`,
`cix-libva*`, `cix-libcme` (hard dlopen dependency of the VA driver),
`cix-vpu-firmware`. **Never install `cix-gstreamer`**: it puts GStreamer 1.22
core libraries into `/usr/share/cix/lib` — an ldconfig'd directory — and
silently shadows the distro GStreamer for every process. On trixie this broke
libgtk-4 (`undefined symbol: gst_video_info_dma_drm_to_video_info`) and
crash-looped the desktop shell at login. General rule: vendor debs must never
place libraries in an ldconfig'd directory shared with the distro.

## Boot time — rootdelay removed properly

The 7.x graphical/console entries no longer carry `rootdelay=90`; the
`ncz-rootdelay` initramfs hook provides a 90s **poll-timeout fallback**
(scripts/local) without the unconditional `init:235` sleep. Measured:
kernel-to-GPU-probe went from ~94s to **3.6s**. The rescue entry keeps an
explicit `rootdelay=90` because it must boot with pre-hook initramfs images.

## Deploy gotchas (each of these cost a debugging cycle — read before touching modules or initrds)

1. **`/lib/modules/<ver>/updates/` does not reach the initrd.** The
   initramfs hook set packs the `kernel/`-path module files; a module
   override staged in `updates/` wins at runtime depmod but the initrd keeps
   stock. To override a module that loads from the initrd, replace the
   `.ko.xz` at its canonical `kernel/...` path (keep a backup).
2. **rEFInd boots the initrd from the ESP** (`initrd=\initrd.img-<ver>`).
   `update-initramfs` writes `/boot/initrd.img-<ver>` only. Every initrd
   change MUST be followed by
   `cp /boot/initrd.img-<ver> /boot/efi/ && sync` or it silently does not
   take effect.
3. **In-kernel module decompression requires `xz --check=crc32`.** A module
   compressed with default CRC64 fails at load with
   `decompression failed with status 6` — and if it's the display driver,
   the greeter's exec-condition never passes (black screen, no obvious error).
4. **`systemctl restart greetd` does not clean the user session.** Orphaned
   labwc/greeter processes keep the Wayland socket while the new greetd
   spins → black screen with everything "active". Full sweep:
   `systemctl stop greetd; pkill -u _greetd; rm -f /run/user/989/wayland-0*;
   systemctl start greetd`.
5. Do not run fullscreen GL tests (glmark2 etc.) against the live greeter
   session — wedges the compositor. Use the user session windowed, or nested.

## Display / flicker triage notes

DP link on the SA350 (1080p60): trains RBR ×4 (`rate:162000 lanes:4`,
sink max is HBR2), standard CEA `148500` pixel clock, XR24. A 4-hour
instrumented soak (DPCD symbol-error counters every 2s, lane status, retrain
count, thermals, DPU clock; idle/mpv-overlay/Chrome-YouTube cycles) is the
tool of record for flicker reports — see MNEMOS `cix-sky1` notes for the lab
script. Sink-side symbol counters at zero while flicker is visible ⇒ the
pixels leaving the SoC are clean and the panel's own processing (dynamic
contrast) is the residual suspect.

## Inference engines: what to ship and what never to ship

Measured on O6N 2026-08-05. Every row below is a real benchmark on this
hardware, not a vendor claim.

| Engine / backend | bge-small (23.7M) tg | gemma-4 E4B (7.46B) pp / tg | Verdict |
|---|---|---|---|
| **llama.cpp CPU-only** | **2783 t/s** | **36.2 / 7.68 t/s** | **SHIP THIS** |
| llama.cpp + Vulkan (`ngl 99`) | 330 t/s | 2.41 / 3.43 t/s | never ship |
| llama.cpp + Vulkan (`ngl 0`, CPU) | 201 t/s | 2.30 / — | never ship |
| llama.cpp + OpenCL | n/a | n/a | backend rejects the device |
| ik_llama.cpp (CPU) | — | 13.1 / 3.49 t/s | slower here |

Three findings worth stating plainly, because each one is counter-intuitive:

**1. Compiling the Vulkan backend in costs 13.6x CPU performance even when
the GPU is unused.** The `ngl 0` row above is pure CPU work — 201 t/s against
2783 t/s from a GPU-free build of the same commit. Arm's own OpenCL guide
explains the mechanism: "OpenCL assumes that the memories are separate and
buffer allocation involves memory copies... The driver uses the application
processor to perform these copy operations, that are computationally
expensive" (Arm Immortalis/Mali GPU OpenCL Developer Guide, 101574 issue 28,
sections 8.2 and 8.2.2). The API is desktop-derived and assumes discrete VRAM;
this SoC has none, so the copies are pure waste, charged to the CPU.

**2. The Mali GPU loses to the CPU even when it is genuinely running.** Stock
llama.cpp has no Mali tuning at all, and its Vulkan backend enumerates the
G720 without ever opening `/dev/mali0`. With the unmerged G720 tuning from
llama.cpp PR #18493 (warptile configs for vendor 0x13b5, forced FP32,
capped suballocation) the device *is* opened — confirmed by an fd on
`/dev/mali0` — and it still loses: 492 t/s prompt against the CPU's 596, with
68% run-to-run variance on generation. The Radxa community reached the same
conclusion independently: onboard Vulkan is "significantly slower than CPU...
making it impractical", while an *external* AMD GPU on the same board hits
1698 t/s. Vulkan is fine; integrated Mali for inference is not.

Why: batch-1 decode is a matrix-vector product, ~2 FLOPs per weight, so it is
bandwidth-bound — and Mali shares the same LPDDR as the CPU (Arm guide 7.1.3:
global and local address spaces "are mapped to the same physical memory"), so
there is no bandwidth to win. Meanwhile the CPU has `i8mm`/`dotprod`, which is
exactly the hardware for Q4/Q8 dequantise-and-multiply. Our build enables
them (`-mcpu=...+dotprod+i8mm+bf16+sve2-*`); without those flags the community
measured a further 37% loss.

**3. ik_llama.cpp is not a general win.** It is 2.7x faster on Qwen3-30B-A3B
per the Radxa thread, but that fork targets MoE routing; on gemma-4 E4B it is
2.8x *slower* and misparses the MatFormer (8.13B/5.30GiB vs the correct
7.46B/4.79GiB), i.e. it appears to run every parameter. Worth revisiting only
for MoE models.

**Embeddings are the exception, and they belong on the NPU** — not because the
NPU is fast in absolute terms (8.9 inf/s for 768-dim nomic) but because it is
*dedicated*: on a 40-100W box it does the work while all 12 CPU cores stay
free. Every query is imperceptible at 112ms, and a full re-index of a
13k-memory corpus takes ~25 minutes. See `post-install/89-npu-embed-server.sh`.

