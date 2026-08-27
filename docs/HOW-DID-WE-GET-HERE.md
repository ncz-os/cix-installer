<p align="center">
  <img src="../assets/branding/wallpaper/ncz-wallpaper-06-cygnus-vacuum-decay-2k.jpg" alt="" width="880">
</p>

# How did we get here

> **🌐 Language:** English · [简体中文](HOW-DID-WE-GET-HERE.zh-CN.md)

NCZ-OS 26.7 "Maximilian" looks little like the release before it. Three
changes account for nearly all of the difference: the kernel moved from 7.0.12
to 7.2, the base distribution moved from Ubuntu to Debian Forky, and the
desktop moved from XFCE on X11 to Singularity on Wayland.

Each was expensive. This document explains what each one cost and why it was
still the right call, so that a reader who arrives at the current tree does not
have to reconstruct the reasoning from commit archaeology.

---

## Why do any of this

The short answer: **a Sky1 board has a GPU, a VPU and an NPU, and none of them
were usable.**

Not missing — *unusable*. That distinction is the whole reason this release
exists. A vendor BSP will happily give you a `/dev/aipu`, a clean probe, and a
banner in `dmesg` announcing a Zhouyi V3 NPU. It will give you a DRM device for
the Mali. It will enumerate `/dev/video0`. Every box on the spec sheet ticks.
Then you try to run an inference and the context fails to initialise, or you
try to decode a frame and there is no firmware, or you check what your
"accelerated" desktop is actually running on and find software rendering
behind a compositor that never got a GLES context.

The three changes each removed one of those walls, and none of them worked
alone:

- **The kernel had to move to 7.2**, because that is where the `mali_kbase`
  Mali-G720 driver port and the DisplayPort link-training fix live. On 7.0.12
  the only GPU path was in-tree panthor with Mesa panvk, which on this
  hardware landed on OpenGL 2.1 through zink. You cannot ship a GPU-first
  distribution on a stack that tops out at GL 2.1 on silicon capable of
  GLES 3.2.
- **The base had to move to Debian**, because ARM is a first-class
  architecture there and a second-class one in Ubuntu. Thin ARM mirror
  coverage is not a cosmetic problem when every package you need is arm64 and
  half your build is fighting the archive.
- **The desktop had to move to Wayland**, because the accelerated path on this
  silicon *is* GLES on a Wayland compositor. X11 clients reach it through
  Xwayland, slower, when they reach it at all. Keeping XFCE would have meant
  shipping hardware whose entire selling point is its GPU, on a display stack
  that structurally cannot get to it.

Fix the kernel but keep X11 and the GPU is still out of reach. Fix the desktop
but stay on 7.0.12 and there is no `mali_kbase` to reach. Fix both but stay on
Ubuntu and you spend the time you saved fighting for arm64 packages. The three
were load-bearing together, which is exactly why they had to land together —
and exactly why it felt insane while it was happening.

## 1. The kernel: 7.0.12 to 7.2

<p align="center">
  <img src="../assets/branding/wallpaper/ncz-wallpaper-02-interstellar-gargantua-2k.jpg" alt="" width="780">
</p>

This was the hardest of the three by a wide margin, and it is the reason the
release took as long as it did.

### The problem

Mainline Linux does not yet boot a usable Sky1 desktop. That is not the same as
saying Sky1 is absent from mainline: CIX is actively upstreaming the platform,
and core SoC enablement has been posted and is landing. What is still missing
upstream is the rest of what a desktop needs -- display, GPU, NPU, VPU and much
of the SoC glue -- and that lives in a vendor patch series maintained against a
specific upstream base. Rebasing that series is not a routine operation:

- **176 patches** are wired into the build recipe's `SRC_URI`, out of **197**
  patch files present in the tree. The extra 21 are superseded or experimental
  and deliberately unreferenced.
- The patches are applied **in `SRC_URI` order, not filename order**. Several
  later fixups are interleaved earlier in the series. Applying them
  numerically produces a tree that does not build.
- The upstream base moved four times during the port:
  `v7.2-rc4` → `rc5` → `rc6` → `rc7`, each a different SRCREV. Every move
  required re-validating the whole series.

Of the 170 patches carried across the rc4→rc5 rebase, **169 applied
byte-identically**. That single exception is the shape of the work: most of a
rebase is mechanical, and the value is entirely in finding the part that is
not.

### What made it worse

The series had drifted from the recipe. At one point the tree carried patches
the recipe did not wire, and the recipe wired patches whose files were absent —
**171 wired against 176 expected, with five patch files missing entirely.** A
source drop in that state cannot rebuild the shipping kernel, which is a
licence problem as much as an engineering one.

The fix was not a one-time repair. `build/port-series.sh` now parses the
recipe's `SRC_URI`, applies the series in recipe order, and fails if any wired
patch does not apply. Drift is caught at build time rather than discovered by
someone trying to reproduce a binary months later.

### Why do it at all

7.2 carries the current Sky1 enablement: the DisplayPort link-training fix, the
full `mali_kbase` Mali-G720 driver port, and the boot-warning cleanup. Staying
on 7.0.12 meant staying on an EOL kernel and forgoing all of it.

**26.7 ships one kernel, `7.2.0-sky1-ncz`. The 7.0.12 channel has been removed
from the image** — it is not a fallback and not a rescue kernel.

---

## 2. The base: Ubuntu to Debian Forky

### Why

**ARM is a first-class architecture in Debian and a second-class one in
Ubuntu.** Ubuntu's ARM mirror coverage is thinner and the ecosystem around it
assumes x86. For a distribution whose entire premise is ARM silicon with an
integrated GPU, VPU and NPU, that is the wrong foundation.

The second reason is a consequence of the third change below: **the Ubuntu
lineage was inherited through the XFCE desktop.** NCZ-OS mapped onto Xubuntu's
package set because that is where XFCE came from. Once XFCE was dropped, that
mapping bought nothing, and the argument for staying on Ubuntu went with it.

### What it cost

Every assumption about package names, versions and archive layout had to be
re-checked against Forky. Forky is Debian *testing*, so it also moves — a
choice made deliberately, because current ARM enablement matters more here than
frozen stability.

The installer now removes `/etc/apt/sources.list` and deletes any Ubuntu or
resolute source files during installation, so Ubuntu Ports is never left as a
live fallback on a Debian-profiled image.

---

## 3. The desktop: XFCE on X11 to Singularity on Wayland

### Why

The accelerated graphics path on Sky1 is **GLES on a Wayland compositor**. X11
clients do not get that path for free — they run under Xwayland and land on a
slower route, when they work at all.

Keeping XFCE would have meant shipping hardware whose main selling point is its
GPU, on a display stack that cannot reach it properly.

### What it cost

**X11 is fully removed, not deprecated-but-present.** That is a harder position
than it sounds, because it breaks anything that assumed an X session — GL
screensavers being the obvious example, since `xscreensaver-gl` is an X11
program that expects a real user session.

Singularity is labwc/wlroots with native Mali GLES. The network stack moved to
`sinty-nm` rather than NetworkManager, and the message bus to `dbus-broker`
rather than `dbus-daemon`.

---

## What it took

26.6 shipped on 2026-07-20. 26.7 "Maximilian" shipped on 2026-08-18.

| | |
|---|---|
| Calendar time | 29 days |
| Active days | 24 |
| Commits | 422 |
| Files changed | 1,792 |
| Insertions | 788,459 |
| Kernel patch files touched | 286 |
| Post-install hooks touched | 65 |
| Build scripts touched | 41 |

All three changes above landed inside that window.

That is worth stating plainly, because it is also the main risk this release
carried. A distribution normally schedules a base-distribution change **or** a
desktop change **or** a kernel rebase — not all three at once. Each one
invalidates the test surface of the other two, so while they are in flight
there is no fixed point to debug against: an installer failure could be the
kernel, the new base, the new desktop, or the interaction of any two.

The cost showed up at the end. A build shipped with an installer that aborted
on every machine at the finish step, and it reached hardware because there was
no automated install gate to catch it — the ground under such a gate had been
moving for a month. That gate now exists
(`build/kvm-install-gate.sh`), which is the correct lesson to take from it:
when the foundations must all move at once, the acceptance test has to be the
last thing standing still, not the first thing deferred.

## Both GPU drivers ship

NCZ-OS does not pick a winner between the vendor driver and the open one. It
ships **both**, and lets the operator choose:

| Driver | Package | Role |
|---|---|---|
| `mali_kbase` | `cix-gpu-kmd` (DKMS) | **Default.** CIX vendor DDK. GLES 3.2 and OpenCL via `libmali`. This is what the desktop runs on. |
| `panthor` | `panthor-cix` (DKMS) | **Selectable.** Mainline open-source driver, the Vulkan path via Mesa PanVK. |

Both are installed and **both are blacklisted** in
`/etc/modprobe.d/ncz-gpu-drivers.conf`, so neither loads by accident — they
would otherwise both claim the same device. One is bound explicitly, and
`ncz-gpu-select` switches between them.

The reason for carrying both is that they are good at different things.
`mali_kbase` is the proven path today: it delivers the GLES 3.2 the desktop
needs and the OpenCL the compute stack uses. `panthor` is where the ecosystem
is going — it is in mainline, it is open, and it is the route to Vulkan — but
on Sky1 it is still working through enumeration issues, because the board
boots via ACPI rather than device tree and mainline panthor has no
`.acpi_match_table`.

Shipping only the vendor driver would tie the distribution to a blob with no
open successor. Shipping only panthor would mean shipping a desktop that does
not accelerate today. Carrying both costs one DKMS build and a blacklist file,
and it means the open path can be tested on real hardware by anyone, on the
shipping image, without a rebuild.

## Was it worth it

<p align="center">
  <img src="../assets/branding/wallpaper/ncz-wallpaper-07-maximilian-blackhole-2k.jpg" alt="" width="780">
</p>

Yes, and the evidence is that all three accelerators now do work, measured on
hardware rather than inferred from a probe:

| | Before | After (measured on O6N) |
|---|---|---|
| **GPU** | GL 2.1 via zink-over-panvk | **Mali-G720-Immortalis, GLES 3.2**, 10 cores, desktop genuinely accelerated — with panthor still shipped alongside, see below |
| **NPU** | enumerated, no working inference | **95.5 ms** per 256-token embed, deterministic across runs, IRQ count moves |
| **VPU** | no codec firmware present | **8 decode formats**; H.264 and HEVC hardware encode confirmed at 720p and 1080p |

That is the return. Not "the drivers load" — three accelerators you can
actually call, from one offline installer image, on a board that ships with
none of it working.

The bar this project holds itself to is stated in the driver-fidelity doc and
is worth repeating here, because it is what made the difference between the
before column and the after column:

> A device node, a clean probe and a printed banner are not evidence that an
> accelerator works.

Every entry in the "after" column above is backed by a workload, not a banner.

### Before and after

| | Before | Now |
|---|---|---|
| Kernel | 7.0.12 (EOL) | `7.2.0-sky1-ncz`, one channel |
| Base | Ubuntu | Debian Forky |
| Desktop | XFCE on X11 | Singularity on Wayland, native GLES |
| GPU | in-tree panthor | `mali_kbase` DDK, Mali-G720-Immortalis, GLES 3.2 |
| NPU | — | Zhouyi V3, ~95 ms per 256-token embed |
| VPU | — | Linlon v5276, 8 decode formats, H.264/HEVC encode |

Validated on Radxa Orion O6N and Minisforum MS-R1. Orange Pi 6 is in progress.

For the reasoning behind individual decisions, with measurements, see
[DESIGN-RATIONALE.md](DESIGN-RATIONALE.md). For the corresponding kernel
source, see [`kernel-source/SOURCE.md`](../kernel-source/SOURCE.md).
