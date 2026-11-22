<p align="center">
  <img src="../assets/branding/wallpaper/ncz-wallpaper-04-retro-sci-fi-poster-2k.jpg" alt="" width="880">
</p>

# NCZ-OS 26.7 — Design Rationale

> Measurements below are from 26.7. Preview 4 ships one Linux 7.4 kernel per architecture. Sky1 uses Mali only. See
> [releases/26.10-cygnus-preview4.md](releases/26.10-cygnus-preview4.md).
>
> **Scope.** Sections 0 to 7 were written for the first, Arm-only releases and their measurements come from CIX Sky1
> hardware. NCZ-OS now also targets AMD64 (Intel and AMD PCs, and Apple T2 Macs) from the same pipeline. Section 8
> applies to every target: why NCZ-OS is beta software, why it provides two kernels, and why it drops so much of
> the older Linux stack.

Why this distribution is built the way it is: the GPU stack, the media and
codec path, the desktop, networking, the base distribution, and the initramfs.

The through-line: **NCZ-OS aims to be an exemplar of a modern Linux
distribution for ARM-based systems.** Not a board-support layer with a desktop
bolted on, and not a lightweight-desktop project ported to new silicon — a
distribution that treats ARM with an integrated GPU, VPU and NPU as the primary
target and builds the stack that hardware actually needs. Most of what follows
is that goal meeting the hardware and losing arguments to it.

This document exists because every one of these decisions looks arbitrary from
the outside and several look wrong. Each was made against a measurement on real
Sky1 hardware, and the measurements are recorded here with the decisions so a
future reader can re-litigate them on evidence rather than taste.

**How to read this.** Claims are tagged:

- **MEASURED** — observed on hardware, with the numbers or log lines quoted.
- **DECIDED** — a judgement call. The reasoning is given; reasonable people
  could choose differently.
- **OPEN** — known unknown. Written down so it is not mistaken for settled.

---

## 0. The modernization doctrine

This is cutting-edge SoC hardware, and it deserves a distribution willing to
shed legacy baggage — because **NCZ-OS has no legacy userbase to protect.**
Nobody is running a decade-old workflow on a CIX Sky1 board. There is no
installed base whose habits constrain the design, which means the usual reason
distributions carry old subsystems forward — someone somewhere still depends on
it — simply does not apply.

That freedom is the single biggest advantage this project has, and it is why so
much of the stack is newer than convention would suggest: Wayland rather than
X11, `sinty-nm` rather than NetworkManager, dbus-broker rather than dbus-daemon,
journald alone rather than journald plus rsyslog, GStreamer rather than the
FFmpeg-backed players, dracut rather than initramfs-tools.

**But the rule has a second half, and it is the important one:**

> **Remove legacy that is REDUNDANT. Keep legacy that is a FALLBACK.**

Dropping everything old is the failure mode on the other side — throwing out
the fallbacks along with the cruft, and ending up with a system that is modern
and unrecoverable. The distinction is whether the old thing is a second copy of
something we already have, or the thing that saves the board when the new thing
breaks.

Worked examples of each:

| Dropped — redundant | Kept — fallback |
|---|---|
| rsyslog (journald already stores it) | `initramfs-tools` (dracut's fallback; pinned so apt cannot silently substitute it) |
| dbus-daemon (dbus-broker supersedes it) | telnet on the LAN (lockout recovery beats a theoretical plaintext concern) |
| mpv/VLC/Celluloid (cannot reach the VPU at all) | the `ffmpeg` CLI (a tool other packages depend on, not a shipped player) |
| Epiphany/WebKit (structurally cannot accelerate here) | software codecs (the path when the VPU cannot take a stream) |
| XFCE/X11 desktop session | Google Chrome (second engine, and the Widevine/DRM path) |

`ifupdown` is the case that proves the rule. It was purged as a Debian tasksel
leftover, and the purge was **technically safe** — nothing in the tree invokes
`ifup`/`ifdown`, and `/etc/network/interfaces` is loopback-only. It was reverted
anyway, on doctrine: when `sinty-nm` is broken by a bad config, a vendor
userspace regression or a bus-permission problem, the recovery path is exactly

    ifup <iface>

Removing it deletes the fallback for the very subsystem that replaced it. Safe
to remove and correct to keep are different questions, and only the second one
matters here.

---

## 1. GPU: Mali is the default, Panthor is the open alternative

NCZ-OS ships **both** GPU stacks and lets the boot entry choose:

| Boot entry | Kernel driver | Userspace |
|---|---|---|
| `7.2 GUI (Mali, Default)` | `mali_kbase` (vendor DDK r53p0) | CIX proprietary GLES/OpenCL |
| `7.2 GUI (Panthor, Experimental)` | `panthor` (mainline DRM) | Mesa panfrost + PanVK |

Selection is a single kernel cmdline token, `sky1.gpu=vendor|mesa`, applied at
boot by `ncz-gpu-switcher`. Both drivers are blacklisted in modprobe.d so udev
can never autoload the loser; the switcher loads the winner explicitly and swaps
the matching userspace half in the same step. The two halves are not independent
choices — blob userspace over a panthor node, or Mesa over kbase, is a machine
that boots and cannot render.

### Why Mali is the default

**MEASURED.** On identical hardware, identical harness, each driver with its
matching userspace, rendering offscreen with no compositor and no vsync
(`glmark2-es2-drm --off-screen`, native 4096x2160):

| scene | Mali | Panthor | ratio |
|---|---|---|---|
| terrain (geometry-heavy) | 159 | 40 | 4.0x |
| refract (shader-heavy) | 358 | 83 | 4.3x |
| shadow | 1234 | 411 | 3.0x |
| desktop (blur/fill) | 533 | 320 | 1.7x |
| texture | 2320 | 1290 | 1.8x |
| **buffer (bandwidth-bound)** | 996 | **1045** | **1.0x** |
| default suite score | 2001 | 1938 | 1.03x |

Mali also exposes **OpenGL ES 3.2** against Panthor's **3.1**.

### How we benchmarked, and what that cost

This comparison was wrong four times before it was right. Each correction is
worth recording, because each is a trap that will catch the next person.

1. **The compositor dominated the result.** Measured through the live Wayland
   compositor, the default suite read Mali 6068 vs Panthor 2192 — nearly 3x.
   Compositor-free, the same suite reads 2001 vs 1938 — 3%. Most of the
   "difference" was compositor overhead interacting differently with the two
   drivers. Fill-bound work lost roughly half its throughput to compositing
   (Panthor desktop@4K: 139 windowed vs 320 direct).

2. **Vsync silently capped one side.** Rendering to KMS, every Mali scene
   returned 119-120 FPS at 8.39 ms — the display refresh, not the GPU. Panthor
   was not capped. Comparing those columns would have been meaningless.
   `--off-screen` removes presentation and vsync from both.

3. **The two ran under different DVFS governors** for part of the work — one
   pinned to `performance`, one on `simple_ondemand`. Controlled test: Panthor
   pinned at 1000 MHz scored 61 on terrain; on ondemand, 61. The governor was
   never the limiter, but the confound had to be eliminated rather than assumed
   away.

4. **`clk_summary` is not a clock readout on this platform.** It reports a
   cached rate that does not track the SCMI performance state: booted on Mali,
   demonstrably fast (glmark2 6068), it read `gpu_core=350000000` through 36
   seconds of sustained load. Any conclusion resting on that file is unsound.
   Throughput is the arbiter here.

Two further cautions for anyone repeating this:

- **Trivial scenes measure the driver, not the GPU.** `clear`@4K returns 17843
  FPS on Mali at 14% CPU and 948 on Panthor — an 18.8x "win" that reflects a
  fast path, not capability. Frame times under ~0.3 ms are submission overhead.
  Use terrain, refract and desktop.
- **Mali is noisy, Panthor is not.** Mali spans 4486-6068 within a boot and
  6991-9448 across boots (~30%). Panthor repeats within ~2% (2012, 2014, 2030,
  2042, 2048, 2192). Never quote a single Mali number as fact; quote the range.

### What the gap actually is

**MEASURED.** Not bandwidth: the two are identical on `buffer` (996 vs 1045),
and Panthor is marginally ahead. Not CPU submission overhead: Mali wins the
heavy scenes while using *less* CPU (3% vs 9%). Not clock: eliminated above.

**DECIDED (inference, not proof).** What remains is shader and geometry
throughput — the compiler and feature enablement in Mesa panfrost versus ARM's
mature DDK on a v12 Immortalis part panfrost only recently gained support for.
This is consistent with the data but has not been proven by shader disassembly
or GPU perf counters.

**OPEN.** Mesa's new Rust shader compiler for Mali (**Kraid**) is the most
likely thing to move this number. It currently sits behind the
`-Dpanfrost-rust` Meson flag, is not in standard Mesa releases, and has passed
only a first basic compliance test — multiple release cycles from daily-driver
quality. Worth re-measuring when it lands; not actionable now.

### A DVFS bug fixed along the way

**MEASURED.** Panthor ran the GPU at a fixed clock and never scaled it, because
under ACPI it voted the performance state on the wrong power domain. Its
by-name domain lookup is Device-Tree-only:

```c
if (IS_ENABLED(CONFIG_OF) && dev->of_node) {          /* NULL on ACPI Sky1 */
        index = of_property_match_string(dev->of_node, "power-domain-names", "perf");
```

Sky1 boots ACPI, so it fell through to voting on the GPU device itself. The vote
succeeded — a legitimate genpd accepted it — while the hardware ignored it, and
Panthor then cached the requested frequency and suppressed every later attempt,
turning one silent no-op into a permanent one. The vendor driver instead
attaches the firmware-named `"perf"` domain and polls a PM-firmware response
register until the level lands.

Fixed in `assets/kernel/panthor/patches/0177-*`: attach `"perf"` by name, vote
through the returned virtual device, and verify against the firmware response
before caching success. Result on Radxa Orion O6N: the clock now ramps and holds 1000 MHz
under load, and glmark2 at 1080p went **2030 -> 3641 (+79%)**.

---

## 2. Media and codecs: everything follows from one hardware fact

**MEASURED, and it explains the entire media stack:** the Linlon VPU accepts
every codec on its output side but emits **only AFBC formats on capture**
(`Y0A8`, `Y0AA`, `Y2A8`, `Y2AA`).

GStreamer 1.28 negotiates dmabuf with DRM format modifiers and lets the sink
resolve them. FFmpeg's `v4l2_m2m` wants plain NV12/YUV420 and answers
`v4l2 output format not supported` on every node.

That single incompatibility decides which players can use the hardware.

### Players: GStreamer only

**MEASURED** by checking which processes hold an open fd on `/dev/video*`:

| | reaches the VPU |
|---|---|
| clapper, showtime, singularity-videos, `gst playbin` | **yes** |
| mpv, VLC, ffplay, Celluloid | no — software |

So NCZ-OS ships **clapper** and **showtime** and purges vlc, mpv and celluloid.
They were never able to reach the VPU on this hardware.

A related correction worth keeping: `/etc/mpv/mpv.conf` shipped for several
releases with `hwdec=v4l2m2m-copy`, described as "the HW video floor for the
appliance". **It never engaged the VPU once.** mpv lists `h264_v4l2m2m`, then
logs "Using software decoding" and picks software anyway — even when named
explicitly with `--vd`, and even against our own ffmpeg build. The config was
removed and video MIME types routed to Clapper.

### GStreamer: one patch carried downstream

**DECIDED.** A colorimetry patch restores hardware VP8/VP9 autoplug, which stock
GStreamer silently degrades to software. It is **deliberately not upstreamed**:
GStreamer requires a gitlab.freedesktop.org account plus a separate user
verification issue to grant fork rights before a merge request can be opened,
and their docs explicitly reject patches mailed to gstreamer-devel. The friction
was judged not worth the return. The patch header records that decision so the
submission path is not re-derived later; the diff applies cleanly to 1.28.5 and
the reproduction is an ffmpeg stream copy of Big Buck Bunny — identical
bitstream, muxer only — so it is demonstrable without the hardware.

### Our own FFmpeg

**MEASURED.** Stock ffmpeg 8.0's `h264_v4l2m2m` fails at real resolutions
(1080p) on the Linlon. The vendor `cix-ffmpeg 7.1.2` carries patched
`*_v4l2m2m` codecs that actually drive the VPU.

It ships as a **self-contained bundle** at `/opt/cix-ffmpeg` with
`cix-ffmpeg`/`cix-ffprobe`/`cix-ffplay` wrappers and its own ffmpeg-7.1 runtime
libraries, because the system carries ffmpeg 8.0 with different sonames. **The
system ffmpeg is left untouched.**

Metal-validated on Radxa Orion O6N: hardware decode H.264 (89x realtime), hardware encode
raw->H.264, and full hardware->hardware transcode H.264->HEVC including
1920x1080. Decode: H264/HEVC/VP9/AV1/MPEG2/4/VC1/VP8/H263. Encode:
H264/HEVC/MJPEG/VP8/MPEG4/H263.

The stock `ffmpeg` CLI package is **deliberately kept** — it is a tool, not a
shipped player, and kdenlive, imagemagick and libsox depend on it.

### Browsers: why we build our own Chromium

**MEASURED.** New VPU (MVX) kernel sessions per run, same box, same clips:

| browser | H.264 | VP9 | YouTube | crashes |
|---|---|---|---|---|
| `chromium-ncz-sky1` | 1 | 1 | 2 | 0 |
| Google Chrome 151 | 0 | — | — | — |
| Epiphany / WebKit | 0 | — | — | crashes |

`chromium-ncz-sky1` is built with `use_v4l2_codec` and `use_av1_hw_decoder` and
is the default browser.

**WebKit's failure is structural, not a tuning problem.** Its web process has no
Wayland connection, so it renders through the DMABUF/GBM path, which requires a
DRM render node. On the Mali backend the GPU is `/dev/mali0` (mali_kbase), not a
DRM device, and the only Sky1 render nodes (`renderD128-130`) belong to
`linlondp` — the display controller, which cannot render. Software GL plus
software decode is exactly the reported "slow, and crashes on YouTube".
Epiphany was purged.

**Google Chrome is installed by default and kept** — it is the engine with
Widevine, so it is the path for DRM-protected streaming content. **It decodes in
software** (H.264 = 0 new MVX sessions).

**OPEN.** The Chrome software-decode result should be re-tested on the current
stack before the release notes repeat it — it was measured on an earlier build,
and both the browser and our VPU userspace have moved since.

---

## 2b. Inference: the CPU beats the GPU, and that is not a bug in our setup

NCZ-OS ships llama.cpp with the **Vulkan** backend, which works on both GPU
stacks — the vendor Mali Vulkan (1.3) and PanVK (1.4). It is worth knowing that
on this hardware **the GPU path is the slower one.**

**MEASURED** (Radxa Orion O6N, `gemma-4-E4B_q4_0-it.gguf`, 7.46 B params, 4.79 GiB Q4_0,
llama-bench):

| backend | prompt processing | token generation |
|---|---|---|
| Vulkan, all layers on GPU (`-ngl 99`) | 7.0 t/s | 9.4 t/s |
| **CPU, 8 big cores** | **44.8-47.1 t/s** | **12.0-12.1 t/s** |

The CPU is **~6.4x faster at prompt processing** and ~1.3x faster at
generation. Sky1's Cortex-A720 cores carry `i8mm`, `sve2`, `svei8mm` and `bf16`
— exactly the instructions a Q4_0 GEMM wants — and llama.cpp's CPU backend uses
them well. The Vulkan compute path does not reach parity.

The giveaway is that on the GPU, **prompt processing is slower than generation**
(7.0 vs 9.4). Prefill is batched and compute-bound and should be many times
faster than generation, not slower. That inversion points at the Vulkan matmul
path, not at the hardware.

Token generation is close between the two because it is **memory-bandwidth
bound**, not compute bound: generation re-reads the whole model per token, and
4.79 GiB x 9.4 tok/s is roughly 45 GB/s — near what LPDDR5 on this class of SoC
delivers. No backend change moves that number much; only a smaller model or a
smaller quantisation does.

**Practical guidance:** for text generation on Sky1, run on the CPU. The GPU
Vulkan path is worth keeping (it works, it frees the CPU for other work, and it
is the path that improves as PanVK and Mesa mature) but it is not the fast one
today.

**MEASUREMENT TRAP, recorded because it produced a badly wrong number first.**
On a Vulkan-enabled llama.cpp build, `-ngl 0` does **not** select the CPU
backend. It keeps the Vulkan backend and offloads no layers, which measured
**0.24 t/s** generation — 50x worse than either real backend, and pure artefact.
The Vulkan device has to be hidden (`GGML_VK_VISIBLE_DEVICES=""`, or `-dev
none`) to measure the CPU backend. Both methods agree with each other, which is
what makes the result trustworthy; the backend column still prints "Vulkan"
either way, so it cannot be used to tell which path ran.

**OPEN.** The NPU (ArmChina Zhouyi V3, in-tree `armchina_npu`, 62.6-62.8 inf/s
on its own workloads) is not wired into llama.cpp at all. That remains the
largest unrealised inference capability on the board.

---

## 2c. Two codec/boot positions we took deliberately

### libopenh264: we inherit Debian's position, and cannot cheaply do otherwise

**DECIDED (2026-08-16).** `libopenh264-8` ships in the image. It is
**not** something we chose: it arrives as a hard `Depends` of
`gstreamer1.0-plugins-bad`, which is the package our accelerated media path
needs (h264parse, h265parse, tsdemux, waylandsink and several hundred more).

**MEASURED.** Removing it is not a local change:

```
# apt-get remove -s libopenh264-8
Remv kooha
Remv kdenlive
Remv gstreamer1.0-plugins-bad     <-- the accelerated media path
Remv libopenh264-8
```

So the choice is not "keep or remove". It is:

1. accept it — our exposure is then **identical to Debian's**;
2. drop `plugins-bad` — unacceptable, it breaks VPU playback, which is the
   entire reason we ship GStreamer players rather than the FFmpeg-backed ones;
3. fork and rebuild `plugins-bad` without openh264 support — the only route that
   genuinely removes the dependency, at the cost of maintaining a fork.

We take (1).

Worth knowing what other distributions do, because the split is real: **Debian
and Ubuntu compile OpenH264 themselves** and ship it in the archive, which is
what we inherit. **Fedora and openSUSE deliberately do not** — they route users
to a separate repo that installs **Cisco's prebuilt binary**, because Cisco's
patent grant covers Cisco's own binaries rather than third-party builds.

Rejected on purpose: diverting the GStreamer plugin (`libgstopenh264.so`) to
hide the two elements. That would be **cosmetic** — `libopenh264-8` itself
remains installed either way, so it changes what is reachable, not what we
ship, while creating the impression the question had been addressed.

### Secure Boot and UKIs: deferred, and it is a deferral not an oversight

**DECIDED (2026-08-16): ship 26.7 without them.**

**MEASURED on Radxa Orion O6N**, so the cost is known rather than assumed:

```
firmware : SecureBoot = 0    SetupMode = 1     (no PK enrolled)
loader   : rEFInd BOOTAA64.EFI, no shim
kernel   : CONFIG_MODULE_SIG            not set
           CONFIG_MODULE_SIG_FORCE      not set
           CONFIG_SECURITY_LOCKDOWN_LSM not set
           signed modules: 0    taint 4100 (out-of-tree + unsigned)
```

The usual objection — "Secure Boot breaks DKMS" — **does not apply to us**. The
kernel has no signing enforcement compiled in at all, so even under Secure Boot
it would load unsigned `mali_kbase`, `amvx`, `aipu` and `panthor` exactly as it
does now.

What would actually break is the **boot chain**: rEFInd and the kernel are
unsigned and there is no shim, so the firmware would refuse to load them. That
is a board that will not boot until Secure Boot is turned off again — recoverable,
not fatal, and `SetupMode=1` means nothing is locked and our own keys could be
enrolled.

Doing it properly is a project, not a flag: build UKIs (dracut makes this
possible, which is why it was gated on the dracut migration), sign the UKI and
loader with our own keys, enroll PK/KEK/db, and enable `CONFIG_MODULE_SIG` with
signed DKMS modules — otherwise the result is boot-chain integrity sitting on
top of a wide-open module path, which is a half-measure worth less than it
looks.

---

## 3. Desktop: Wayland and Singularity, not X and XFCE

**DECIDED**, and the GPU section above is the reason. This hardware's working
graphics path is GLES on a Wayland compositor. X11 clients on Sky1 land on the
DMABUF/GBM path that has no usable DRM render node under the Mali backend —
the same structural wall that makes WebKit unusable.

Practical consequences we accept:

- X11 applications run under Xwayland and do not get the accelerated path for
  free. GL screensavers (`xscreensaver-gl`) are X11 and need a real user session
  with a compositor-managed Xwayland; they do not work from a greeter-only
  session.
- The greeter session is a minimal compositor. Benchmarks and GPU tests run
  there are valid for A/B comparison but are not representative of a desktop.

See also the README section "Why we moved off X/XFCE to Singularity".

---

## 4. Networking: sinty-nm replaces NetworkManager

**DECIDED.** `sinty-nm` (github.com/singularityos-lab/sinty-nm) is the native
network daemon for the Singularity desktop: a static Go binary at
`/usr/bin/sinty-nmd` that **owns `org.freedesktop.NetworkManager` on the system
bus** and serves the same object tree.

It is a **replacement, not a frontend** — so `nmcli`, libnm, xdg portals and the
panel network indicator keep working unchanged:

- WiFi via **iwd** (`net.connman.iwd`)
- L2/L3 via **rtnetlink**
- IPv4 via a **built-in DHCP client**
- VPN via **WireGuard**

NetworkManager is purged and masked, because two daemons cannot own the same bus
name. The trade is a smaller, statically-linked, desktop-native daemon in place
of a large C stack — at the cost of depending on a young external project.

---

## 5. Base distribution: Debian Forky

**DECIDED.** NCZ-OS 26.7 targets **Debian Forky**, having previously built on
Ubuntu. Three reasons, in order of weight:

1. **ARM is a first-class citizen in Debian and a second-class one in Ubuntu.**
   Ubuntu lacks sufficient ARM mirror coverage, and the ecosystem around it
   treats arm64 as a port rather than a primary target. For a distribution whose
   entire premise is being an exemplar ARM distro, building on a base that
   treats ARM as secondary is a structural handicap — it shows up as mirror
   availability, package currency, and how quickly arm64-specific breakage gets
   attention.

2. **Once XFCE was dropped, mapping to Xubuntu's package set bought nothing.**
   The Ubuntu lineage was largely inherited through the XFCE desktop. With the
   move to Wayland and Singularity (section 3), that shared package surface
   stopped being an asset, and with it went the main practical argument for
   staying.

3. **Ubuntu's `chromium-browser` is snap-only, and NCZ-OS does not ship
   snapd.** A snap-only browser is not viable for an appliance image that must
   install and work offline from a local mirror. We build our own Chromium in
   any case (section 2), but the packaging model was a standing obstacle.

Debian's move to dracut during the Forky cycle (section 6) is a transition we
would rather arrive at deliberately than inherit.

**MEASURED trap from the migration**, kept because it will recur: build
containers must match the target. `build-singularity.sh` built in `ubuntu:26.04`
while the target was Forky; Ubuntu carries `libsodium.so.23` and Forky carries
`.26`, so the payload linked against the wrong soname and died on the board with
`error while loading shared libraries`.

## 6. Initramfs: moving to dracut, carefully

> **Status, 26.10.** The move is done: installed images build their initramfs with dracut, and the build no longer
> installs `initramfs-tools` into the system (`manifests/installer-base.pkgs`). `initramfs-tools` stays in the
> rescue environment as a recovery tool for rebuilding a target's initrd. The text below is the 26.7 reasoning and
> measurements, kept as written.

**Context.** Debian is switching the default initramfs builder to dracut during
the Forky cycle (Debian bug #1114857): the kernel dependency becomes
`dracut | initramfs-tools | linux-initramfs-tool` and new installs are expected
to include dracut. We will land on dracut whether or not we choose it, so we
would rather arrive with a configuration we measured than inherit a default we
did not.

**MEASURED, and this is why the configuration is load-bearing.** A stock
`dracut` run on Radxa Orion O6N omits **26 modules** that initramfs-tools ships — while
producing a similar module count, so a superficial comparison reads as
equivalent. The omissions include:

- `linlon-dp` and `trilin-dpsub` — **the only video console on the Radxa Orion O6N**. An
  initrd without them is a permanent black screen.
- the entire USB-ethernet recovery set (`r8152`, `ax88179_178a`, `asix`,
  `cdc_ether`, `lan78xx`, `smsc95xx`, ...), which removes the network recovery
  path on a headless board.
- `squashfs` and `dm-mod`.

With `assets/dracut/10-ncz-sky1.conf` applied and regenerated:

```
initramfs-tools modules : 45
dracut modules          : 69
missing vs initramfs-tools : 0
```

The config also forces bounded failure behaviour. **MEASURED:** with no root
device, initramfs-tools panics and reboots, but dracut stops at a sulogin prompt
and waits forever — an indefinite hang on a headless board. Hence
`rd.shell=0 rd.emergency=reboot rd.timeout=30`, and `hostonly=no` so a shipped
image boots on any Sky1 board rather than only the one that built it.

**How the migration is gated.** initramfs-tools remains the default and the
fallback; it is **not** to be purged, because it is a fallback rather than
redundancy. Two guards enforce that:

- An **apt pin** (`Pin-Priority: -1`) makes dracut ineligible for automatic
  selection, so `apt remove initramfs-tools` cannot silently substitute dracut
  to satisfy the kernel's alternation. Removing initramfs-tools now fails
  loudly, which is the correct outcome.
- A **separate boot entry**, `7.2 GUI (Mali, dracut initrd — EXPERIMENTAL)`,
  loads a dracut initrd built alongside the normal one under a distinct
  filename. It differs from the default entry in exactly one way — which initrd
  it loads — so a failure indicts dracut and nothing else.

---

## 7. Recurring lessons

These cost real time and appear across several sections above.

- **A benchmark that measures the wrong thing is worse than no benchmark.**
  Compositor, vsync, governor and cached sysfs values each moved the GPU numbers
  by more than the effect being measured.
- **"Configured" is not "working".** The mpv `hwdec` config, and a
  `/etc/dracut.conf.d` that was never populated, both looked correct and did
  nothing.
- **Empty output is not evidence of absence.** `journalctl -k` returns nothing
  unprivileged; `hwclock` and `ldconfig` live in `/sbin` and vanish from an
  unprivileged PATH. Each produced a confident wrong conclusion before being
  caught.
- **A silent success is the expensive failure mode.** The Panthor DVFS bug
  survived because a failed vote returned zero and was then cached forever.

## 8. Beta, two kernels, two filesystems, and the legacy we dropped

Everything above explains individual choices. This section explains the situation they add up to, so nobody is
surprised by it.

### 8.1 NCZ-OS is beta software

**DECIDED.** Treat every NCZ-OS release as beta. That is not modesty. It follows from what the system is built from
(8.2), and from the pace at which those parts change.

What it means for you:

- **You may need to reinstall every few months.** Between previews, a major change in one of the parts can be
  easier to ship as a new image than as an upgrade. Back up what you care about before you install, and again
  before you move to a new preview.
- **In-place upgrades between previews are not promised yet.** **OPEN.** We aim to make NCZ-OS an updateable
  distribution by January 2027, with an upgrade path from one release to the next. Until it is shipped and tested,
  assume a reinstall.
- **Things will be rough.** Each preview lists its known issues in its release notes. Read them before you install.

### 8.2 It is built from young parts

**DECIDED.** NCZ-OS is a deliberate combination of several fast-moving projects. Each one is current, and none of
them has had the years of use that a long-settled distribution has.

| Part | State today | What follows from that |
|---|---|---|
| **Linux 7.4** | The current mainline kernel. No major distribution ships it yet. Preview 4 uses a release candidate, `7.4.0-rc3`. | The kernel itself is still being fixed upstream, so our patches are re-applied to each new candidate. |
| **Debian Forky** | The Debian release now in development ("testing"). Debian has not released it. We expect the Debian part of NCZ-OS to stabilize by June 2027. **OPEN:** Debian sets its own release date. | Packages change underneath us until then. |
| **Singularity desktop** | Also beta quality, and in ongoing development. NCZ-OS contributes to the project as well as using it. | Features and behaviour are still changing and bugs are still being found. We fix what we hit and carry the fixes as patches. |
| **CIX Sky1 patches** | Maintained by hand at present: Sky1 boards need patches and vendor drivers that are not in mainline Linux. We expect upstream integration by mid-2027, with some patches reaching mainline earlier. **OPEN:** that depends on the upstream maintainers. | Until they land we re-apply and re-test them on every new kernel candidate. Some have already landed: the PHY maintainer applied part of the Sky1 DisplayPort PHY series on 2026-11-19 (lore.kernel.org, `20261116073800.2396894-1-Luo.Liu@cixtech.com`). |
| **Apple T2 patches** | Still largely maintained independently of mainline Linux, by the T2 Linux community (the t2linux project) and by us. | Same: carried and re-ported when the kernel moves. A few have gone upstream, and each one that does is dropped from our set. |

**How we carry the device patches.** NCZ-OS makes a best effort to bring the latest CIX Sky1 and Apple T2 driver and
fix patches into its kernels. We apply them, we forward-port them to each new kernel as we test it, and we send the
fixes we find to the kernel project that owns the code, as we meet them. Some of this has already reached the kernel projects, all of it public on the mailing lists and in the kernel
history:

- **Broadcom Wi-Fi: merged, and in stable kernels.** A regression report about an IOMMU fault on the Broadcom Wi-Fi
  adapter of a T2 Mac (regressions list, 2026-10-20, `7A444F17-F81B-4A33-A7AF-9E30B3EEFA67@gmail.com`). The fix is a mainline commit authored by us,
  `wifi: brcmfmac: map msgbuf RX packet IDs bidirectional` (`7ed5dce55fa8`): forwarded by a T2 Linux developer,
  acked by Broadcom's brcmfmac maintainer and applied by the wireless maintainer on 2026-10-22 for Linux 7.4-rc2. It
  is marked for stable, and Greg Kroah-Hartman has backported it to several stable kernels. The stable 6.12, 6.18 and 7.3
  branches carry it as of 2026-11-22.
- **PCIe error handling (AER and DPC).** A report that an Apple T2 MacBook Pro powered itself off about 20 seconds
  after boot (regressions list, 2026-10-05), and a patch that stops the kernel advertising DPC on ports without
  AER (linux-pci, 2026-11-16, `9ed2d8fb-fad5-44b3-82a2-0021edb405f4@gmail.com`). Lukas Wunner answered with a seven-patch series, which we tested and
  answered with a Tested-by (linux-pci, 2026-11-18, `20261119010335.84545-1-jperlow@gmail.com`).
- **Bluetooth.** A patch that names the BCM4364B3 controller (linux-bluetooth, first posted 2026-11-16, version 2 on
  2026-11-22, `20261122165132.14015-1-jperlow@gmail.com`, with a reviewer's tag).
- **Singularity desktop.** NCZ-OS is a contributor to the Singularity project, not only a user. As of 2026-11-22
  the NCZ-OS maintainer's account has 41 merged pull requests across the Singularity repositories (shell, libsingularity,
  plugins, session and others), and more are open.

The PCIe error-handling, Wi-Fi and Bluetooth fixes all matter to Apple T2 Macs, and the lead T2 Linux maintainer
encouraged us to send them upstream.

**OPEN:** the Wi-Fi fix is merged; whether the PCIe and Bluetooth patches are merged is for their maintainers to decide.

The combination is the point: a current kernel, a current Debian, a modern Wayland desktop and current hardware
support, in one image. It is also why this is beta.

### 8.3 Why there are two kernel lines

**DECIDED.** NCZ-OS provides both kernels, **Linux 7.4 and Linux 7.3**:

- **7.4 is the default on the desktop.**
- **7.3 is the default on the server.**
- The desktop also offers 7.3 as a **Stable** boot entry. 7.3 is the recovery kernel on both editions. The server
  offers 7.4 as an **Edge** entry.

Why two. Linux 7.4 is mainline today, but whether it becomes a long-term-support kernel is not decided, and a
distribution that bets on one line pays for a wrong guess. So we build, patch and test both. We expect to have a long-term-support kernel in place by January 2027.

Why that split. A desktop is where new hardware support matters most, so it follows 7.4. A server and a recovery
environment value predictability, so they follow the line most likely to be maintained for years.

**Which releases.** Preview 4 predates this decision. It ships Linux 7.4 only (`7.4.0-rc3`), as one kernel per
image, and its release notes record that the 7.3 line was dropped for that release. That decision was reversed
afterwards, and the next preview carries both kernels. Only 7.3.5 and later are brought back; earlier 7.3 builds
stay retired.

What two lines cost us. Our patch set has to apply to both. When a stable 7.3 update changes code our patches
touch, the patches are re-ported. That has already happened once: a stable update changed the same PCIe
error-handling lines that one of our patch series edits.

### 8.4 The legacy we dropped, and the legacy we kept

**DECIDED.** NCZ-OS has no installed base of old workflows to protect (section 0), so it drops an older part
whenever a newer one already does the job:

| Older part | What NCZ-OS uses instead |
|---|---|
| X11 session, XFCE | Wayland (labwc) and the Singularity desktop (section 3) |
| NetworkManager | `sinty-nm`, a native daemon that serves the same bus interface (section 4) |
| `initramfs-tools` | dracut, which Debian is moving to during the Forky cycle (section 6) |
| `dbus-daemon` | `dbus-broker` |
| `rsyslog` next to journald | journald alone |
| snap packaging | not shipped; there is no `snapd` (section 5) |
| mpv, VLC and similar players | GStreamer-based players (section 2) |

The rule that goes with it (section 0): **remove legacy that is redundant, keep legacy that is a fallback.** For
example, `initramfs-tools` is gone from the installed system but kept in the rescue environment, because that is
the tool you reach for when an initrd has to be rebuilt by hand.

**OPEN: speed.** The aim of dropping this much is a smaller, simpler and faster system. We have not yet published
a boot-time or install-time comparison against stock Debian, so this document makes no speed claim. Where we
did measure something, the number is next to the decision (sections 1 to 2c and 6).

### 8.5 Two root filesystems: btrfs and ext4

**DECIDED.** NCZ-OS provides both, and the installer asks which one you want for the root (`/`) partition:

- **btrfs is the default.** It gives snapshots and transparent compression, which suit a system that changes often
  and may need to be rolled back.
- **ext4 is the simple choice.** It is long established and has no extra features to go wrong, which is why some
  people will want it for a server or a machine they leave alone.

The rescue partition is always ext4, whichever you choose for the system, so the way back does not depend on the
feature set of the filesystem it is meant to repair.

### 8.6 What we do so beta is survivable

**MEASURED**, each of these is in the build and its gates today:

- **Every image is installed and booted in a virtual machine before release.** The build installs the image onto a
  blank disk unattended, boots the installed system, and fails on a missing boot entry, a failed unit, a kernel
  that does not start, or an installer screen that does not match what the installer is meant to show.
- **There is always a way back.** The boot menu carries a rescue entry, a previous-kernel entry and a console
  entry, and the default install adds a rescue partition. The Stable 7.3 entry in 8.3 adds a second kernel.
- **Inputs are pinned and checked.** The Debian snapshot, the kernel packages and the build inputs are pinned by
  hash and every package in an image has to be accounted for, so an image cannot quietly pick up a different one.

None of this makes the system finished. It makes the failures visible before an image goes out, and recoverable
after.

### 8.7 What we expect, and when

**OPEN.** These are targets, not promises. Each one depends on projects we do not control, and each will be
restated here when it is met or moved.

| Target | When | What it depends on |
|---|---|---|
| A long-term-support kernel | January 2027 | The kernel lines in 8.3, and which one upstream maintains for the long term |
| NCZ-OS as an updateable distribution, with in-place upgrades between releases | January 2027 | The upgrade path in 8.1 being built, shipped and tested |
| The Debian part of NCZ-OS stabilized | June 2027 | Debian Forky, which Debian has not released |
| CIX Sky1 patches integrated upstream | Mid-2027, some earlier | Review by the upstream kernel maintainers |
| The Singularity desktop | Ongoing development | The upstream project, and the fixes we carry for it |

---

*Maintained in `docs/DESIGN-RATIONALE.md`. Measurements are from a Radxa Orion O6N (CIX
Sky1, kernel 7.2.0-rc7-sky1-ncz) unless stated otherwise.*
