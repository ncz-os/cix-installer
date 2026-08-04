# CIX 7.2 Driver Fidelity — Validated State (Orion O6N)

Companion to `DRIVER_FIDELITY_7012.md`, which covers the 7.0.12 legacy channel.
This one covers the **7.2 primary channel** and records what has actually been
*measured* on hardware, not what merely enumerates.

All results below were taken on **Radxa Orion O6N**, kernel
**7.2.0-rc6-sky1-ncz**, 2026-08-04.

> **The bar is function, not presence.** A device node, a clean probe and a
> printed banner are not evidence that an accelerator works. The NPU section
> below is the cautionary case: `/dev/aipu` existed, the driver probed, the
> ZHOUYI V3 banner printed, and the hardware could not run a single inference.
> Every claim here is backed by a workload.

## Contents

- [Summary](#summary)
- [GPU — Mali-G720-Immortalis (DKMS, working)](#gpu--mali-g720-immortalis-dkms-working)
- [VPU — Linlon / amvx (DKMS, working)](#vpu--linlon--amvx-dkms-working)
  - [Encoding requires an explicit `-pix_fmt`](#-encoding-requires-an-explicit--pix_fmt)
- [NPU — ArmChina Zhouyi V3](#npu--armchina-zhouyi-v3)
  - [Out-of-tree (DKMS) — DO NOT ENABLE](#out-of-tree-dkms--do-not-enable)
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
| NPU (ArmChina Zhouyi V3) | **in-tree** | working | 62.6–62.8 inf/s sustained |
| NPU out-of-tree (DKMS) | — | **DO NOT ENABLE** | panics the kernel at probe |
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

### In-tree (`armchina_npu`) — the only one that works

```
62.6–62.8 inf/s, 15.9 ms avg
model /opt/ncz/models/bge-small-zh-v1.5_256.cix, 3 inputs / 2 outputs
6 memory regions initialised, ASIDs 0–5 programmed
```

`CONFIG_ARMCHINA_NPU=m` must stay. See below.

### Out-of-tree (DKMS) — **DO NOT ENABLE**

Two separate out-of-tree sources were tried; both fail, differently:

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

That flag is an **MS-R1** firmware workaround and is now gated on the board via
`ncz_efi_rt_workaround()` (DMI `product_name`/`sys_vendor`), not on the kernel
channel — every Sky1 board runs both 7.2 and 7.0.12, so a per-channel split
would be wrong in both directions. Verified on O6N under **both** kernels.

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
