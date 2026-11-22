<p align="center">
  <img src="../assets/branding/wallpaper/ncz-wallpaper-04-retro-sci-fi-poster-2k.jpg" alt="" width="880">
</p>

# NCZ-OS Design Rationale

> **Scope.** Sections 0 to 7 record the decisions and measurements behind the first, Arm-only releases (26.7, Linux
> 7.2, a Radxa Orion O6N unless stated). They are kept for what still shapes Preview 4, and where a part was removed
> since, the text says so. NCZ-OS now also targets AMD64 (Intel and AMD PCs, and Apple T2 Macs) from the same
> pipeline. Section 8 applies to every target.

Why this distribution is built the way it is: the GPU stack, the media and codec path, the desktop, networking, the
base distribution and the initramfs.

The through-line: **NCZ-OS aims to be an exemplar of a modern Linux distribution.** It began on ARM-based systems,
and it has expanded to AMD64 and x86. It specializes in older systems that their maker no longer supports well, such
as PCs that ran Windows 10 and Apple T2 Macs, and it aims to support NVIDIA, AMD and Intel GPUs and NPUs fully. It is
not a board-support layer with a desktop bolted on, and not a lightweight desktop ported to new silicon: it builds
the stack the hardware needs.

What that means today (**MEASURED** in the README's hardware section): NCZ-OS 26.10 ships drivers for AMD, NVIDIA and
Intel GPUs on amd64, Arm Mali on CIX Sky1, and the CIX Sky1 NPU and VPU. GPU compute (ROCm, CUDA, oneAPI) has tighter
hardware floors than the base system, and NPU support on x86 is best-effort. The README lists which machines have
been tested; the aim is wider than that list.

Every decision here looks arbitrary from the outside and several look wrong. Each was made against a measurement on
real hardware, and the measurements are recorded with the decisions so a reader can re-litigate them on evidence
rather than taste. Claims are tagged:

- **MEASURED**: observed on hardware, with the numbers or log lines quoted.
- **DECIDED**: a judgement call. The reasoning is given; reasonable people could choose differently.
- **OPEN**: a known unknown, written down so it is not mistaken for settled.

---

## 0. The modernization doctrine

**NCZ-OS has no legacy userbase to protect.** Nobody runs a decade-old workflow on a CIX Sky1 board, so the usual
reason distributions carry old subsystems forward (someone still depends on it) does not apply. That is why much of
the stack is newer than convention: Wayland rather than X11, `sinty-nm` rather than NetworkManager, dbus-broker
rather than dbus-daemon, journald alone rather than journald plus rsyslog, GStreamer rather than the FFmpeg-backed
players, dracut rather than initramfs-tools.

The rule has a second half, and it is the important one:

> **Remove legacy that is REDUNDANT. Keep legacy that is a FALLBACK.**

Dropping everything old throws out the fallbacks with the cruft and leaves a system that is modern and
unrecoverable. The test is whether the old thing is a second copy of something we already have, or the thing that
saves the board when the new thing breaks.

| Dropped: redundant | Kept: fallback |
|---|---|
| rsyslog (journald already stores it) | `initramfs-tools`, in the rescue environment only (the tool for rebuilding a target's initrd by hand) |
| dbus-daemon (dbus-broker supersedes it) | telnet on the LAN (lockout recovery beats a theoretical plaintext concern) |
| mpv, VLC, Celluloid (cannot reach the VPU) | the `ffmpeg` CLI (a tool other packages depend on, not a shipped player) |
| Epiphany/WebKit (structurally cannot accelerate here) | software codecs (the path when the VPU cannot take a stream) |
| XFCE/X11 desktop session | Google Chrome (second engine, and the Widevine/DRM path) |

`ifupdown` proves the rule. It was purged as a Debian tasksel leftover, and the purge was technically safe: nothing
in the tree calls `ifup`/`ifdown` and `/etc/network/interfaces` is loopback-only. It was reverted anyway, because
when `sinty-nm` is broken by a bad config, a vendor userspace regression or a bus-permission problem, the recovery
path is exactly `ifup <iface>`. Safe to remove and correct to keep are different questions, and only the second one
matters.

---

## 1. GPU: the vendor Mali stack

**DECIDED.** Sky1 uses the vendor Mali stack: the `mali_kbase` kernel driver with CIX's proprietary GLES and OpenCL
userspace. The open alternative, `panthor` with Mesa panfrost and PanVK, is **not shipped** in Preview 4 (the 7.4
kernel is built with `CONFIG_DRM_PANTHOR` off). It was the second choice in 26.7, selectable at boot, and the
measurement below is why it lost.

**MEASURED.** Same hardware and harness, each driver with its matching userspace, offscreen with no compositor and
no vsync (`glmark2-es2-drm --off-screen`, native 4096x2160):

| scene | Mali | Panthor | ratio |
|---|---|---|---|
| terrain (geometry-heavy) | 159 | 40 | 4.0x |
| refract (shader-heavy) | 358 | 83 | 4.3x |
| shadow | 1234 | 411 | 3.0x |
| desktop (blur/fill) | 533 | 320 | 1.7x |
| texture | 2320 | 1290 | 1.8x |
| **buffer (bandwidth-bound)** | 996 | **1045** | **1.0x** |
| default suite score | 2001 | 1938 | 1.03x |

Mali also exposes **OpenGL ES 3.2** against Panthor's 3.1. The gap is not bandwidth (the two match on `buffer`), not
CPU submission overhead (Mali wins the heavy scenes on less CPU, 3% against 9%) and not clock. **DECIDED
(inference, not proof):** what remains is shader and geometry throughput, which fits Mesa's compiler maturity
against ARM's DDK, but no shader disassembly or perf counter has proved it.

The result needed care to get right, and the care is the part worth keeping. Measured through the live Wayland
compositor the suite read Mali 6068 against Panthor 2192; compositor-free it reads 2001 against 1938. Rendering to
KMS capped every Mali scene at the 119-120 FPS display refresh. `clk_summary` reports a cached rate that does not
track the SCMI performance state, so throughput, not that file, is the arbiter. Mali is noisy (4486-6068 within a
boot, 6991-9448 across boots), so quote its range, never a single number.

---

## 2. Media and codecs: everything follows from one hardware fact

**MEASURED.** The Linlon VPU accepts every codec on its output side but emits **only AFBC formats on capture**
(`Y0A8`, `Y0AA`, `Y2A8`, `Y2AA`). GStreamer 1.28 negotiates dmabuf with DRM format modifiers and lets the sink
resolve them. FFmpeg's `v4l2_m2m` wants plain NV12/YUV420 and answers `v4l2 output format not supported` on every
node. That single incompatibility decides which players can use the hardware.

### Players: GStreamer only

**MEASURED**, by checking which processes hold an open fd on `/dev/video*`:

| | reaches the VPU |
|---|---|
| clapper, showtime, singularity-videos, `gst playbin` | **yes** |
| mpv, VLC, ffplay, Celluloid | no, software |

NCZ-OS ships **clapper** and **showtime** and purges vlc, mpv and celluloid. A shipped `/etc/mpv/mpv.conf` with
`hwdec=v4l2m2m-copy` ("the HW video floor") never engaged the VPU once: mpv lists `h264_v4l2m2m`, logs "Using
software decoding" and picks software even when named with `--vd`. The config was removed and video MIME types
routed to Clapper.

**DECIDED.** A colorimetry patch restores hardware VP8/VP9 autoplug, which stock GStreamer silently degrades to
software. It is deliberately not upstreamed: GStreamer needs a freedesktop GitLab account plus a verification issue
before a merge request, and its docs reject patches mailed to gstreamer-devel. The patch header records the
decision so the path is not re-derived.

### Our own FFmpeg

**MEASURED.** Stock ffmpeg 8.0's `h264_v4l2m2m` fails at real resolutions (1080p) on the Linlon. The vendor
`cix-ffmpeg 7.1.2` carries patched `*_v4l2m2m` codecs that drive the VPU. It ships as a self-contained bundle at
`/opt/cix-ffmpeg` with its own ffmpeg-7.1 libraries, because the system carries ffmpeg 8.0 with different sonames,
and **the system ffmpeg is left untouched.** Validated on the board: hardware decode H.264 (89x realtime), hardware
encode, and full hardware transcode H.264 to HEVC including 1920x1080. Decode: H264/HEVC/VP9/AV1/MPEG2/4/VC1/VP8/H263.
Encode: H264/HEVC/MJPEG/VP8/MPEG4/H263. The stock `ffmpeg` CLI is kept: it is a tool, not a player, and kdenlive,
imagemagick and libsox depend on it.

### Browsers: why we build our own Chromium

**MEASURED.** New VPU (MVX) kernel sessions per run, same box, same clips:

| browser | H.264 | VP9 | YouTube | crashes |
|---|---|---|---|---|
| `chromium-ncz-sky1` | 1 | 1 | 2 | 0 |
| Google Chrome 151 | 0 | n/a | n/a | n/a |
| Epiphany / WebKit | 0 | n/a | n/a | crashes |

`chromium-ncz-sky1` is built with `use_v4l2_codec` and `use_av1_hw_decoder` and is the default browser. WebKit's
failure is structural: its web process has no Wayland connection, so it renders through the DMABUF/GBM path, which
needs a DRM render node. On the Mali backend the GPU is `/dev/mali0`, not a DRM device, and the only Sky1 render
nodes belong to `linlondp`, the display controller, which cannot render. Epiphany was purged. Google Chrome is kept
as the engine with Widevine for DRM-protected content; it decodes in software (H.264 = 0 new MVX sessions).
**OPEN.** That Chrome result was measured on an earlier build, so re-test it before a release note repeats it.

---

## 2b. Inference: the CPU beats the GPU

NCZ-OS ships llama.cpp with the **Vulkan** backend, which works on the vendor Mali Vulkan (1.3). On this hardware
the GPU path is the slower one.

**MEASURED** (`gemma-4-E4B_q4_0-it.gguf`, 7.46 B params, 4.79 GiB Q4_0, llama-bench):

| backend | prompt processing | token generation |
|---|---|---|
| Vulkan, all layers on GPU (`-ngl 99`) | 7.0 t/s | 9.4 t/s |
| **CPU, 8 big cores** | **44.8-47.1 t/s** | **12.0-12.1 t/s** |

The CPU is about 6.4x faster at prompt processing and 1.3x at generation. Sky1's Cortex-A720 cores carry `i8mm`,
`sve2`, `svei8mm` and `bf16`, which a Q4_0 GEMM wants. On the GPU, prompt processing is slower than generation
(7.0 against 9.4), which points at the Vulkan matmul path, not the hardware. Generation is close on both because it
is memory-bandwidth bound (4.79 GiB x 9.4 tok/s is about 45 GB/s). **Practical guidance:** run text generation on
the CPU; keep the Vulkan path, which works and improves as the drivers mature.

**Measurement trap.** On a Vulkan-enabled build, `-ngl 0` does not select the CPU backend. It keeps Vulkan and
offloads no layers, which measured 0.24 t/s, an artefact. Hide the device (`GGML_VK_VISIBLE_DEVICES=""` or
`-dev none`) to measure the CPU; the backend column prints "Vulkan" either way.

**OPEN.** The NPU (ArmChina Zhouyi V3, in-tree `armchina_npu`, 62.6-62.8 inf/s on its own workloads) is not wired
into llama.cpp, the largest unrealised inference capability on the board.

---

## 2c. Two positions we took deliberately

### libopenh264: we inherit Debian's position

**DECIDED (2026-08-16).** `libopenh264-8` ships because it is a hard `Depends` of `gstreamer1.0-plugins-bad`, which
our accelerated media path needs (h264parse, h265parse, tsdemux, waylandsink and several hundred more). **MEASURED:**
`apt-get remove -s libopenh264-8` also removes `kooha`, `kdenlive` and `gstreamer1.0-plugins-bad`. So the options
are to accept it (our exposure is then identical to Debian's, which compiles OpenH264 itself), to drop
`plugins-bad` (it breaks VPU playback, the reason we ship GStreamer players), or to fork `plugins-bad` without it
(a fork to maintain). We accept it. Diverting `libgstopenh264.so` to hide the elements was rejected as cosmetic:
`libopenh264-8` stays installed either way.

### Secure Boot and UKIs: deferred

**DECIDED (2026-08-16): ship without them.** **MEASURED** at the time on the O6N: `SecureBoot = 0`, `SetupMode = 1`,
rEFInd with no shim, `CONFIG_MODULE_SIG` and `CONFIG_SECURITY_LOCKDOWN_LSM` not set, no signed modules. "Secure Boot
breaks DKMS" does not apply, because the kernel enforces no module signing. What would break is the boot chain:
rEFInd and the kernel are unsigned and there is no shim. Doing it properly is a project (build UKIs, sign them and
the loader with our own keys, enroll PK/KEK/db, enable `CONFIG_MODULE_SIG` with signed DKMS modules); anything less
is boot-chain integrity on top of an open module path. This section has not been re-measured for Preview 4.

---

## 3. Desktop: Wayland and Singularity, not X and XFCE

**DECIDED**, and section 2 is the reason. This hardware's working graphics path is GLES on a Wayland compositor.
X11 clients on Sky1 land on the DMABUF/GBM path that has no usable DRM render node under the Mali backend, the same
wall that makes WebKit unusable. Consequences we accept: X11 applications run under Xwayland without the accelerated
path, GL screensavers (`xscreensaver-gl`) need a real user session rather than a greeter-only one, and benchmarks
run in the greeter's minimal compositor are valid for A/B comparison but not representative of a desktop.

---

## 4. Networking: sinty-nm replaces NetworkManager

**DECIDED.** `sinty-nm` (github.com/singularityos-lab/sinty-nm) is the native network daemon for the Singularity
desktop: a static Go binary at `/usr/bin/sinty-nmd` that owns `org.freedesktop.NetworkManager` on the system bus and
serves the same object tree. It is a replacement, not a frontend, so `nmcli`, libnm, xdg portals and the panel
network indicator keep working. WiFi runs through **iwd**, L2/L3 through **rtnetlink**, IPv4 through a built-in DHCP
client and VPN through **WireGuard**. NetworkManager is purged and masked, because two daemons cannot own one bus
name. The trade is a smaller desktop-native daemon in place of a large C stack, at the cost of depending on a young
external project.

---

## 5. Base distribution: Debian Forky

**DECIDED.** NCZ-OS builds on **Debian Forky**, having previously built on Ubuntu, for two reasons:

1. **ARM is first-class in Debian and second-class in Ubuntu.** Ubuntu has thin ARM mirror coverage and treats arm64
   as a port. For a distribution whose premise is being an exemplar ARM distro, that shows up as mirror
   availability, package currency and how quickly arm64 breakage gets attention.
2. **Ubuntu's `chromium-browser` is snap-only, and NCZ-OS does not ship snapd.** A snap-only browser is not viable
   for an image that must install and work offline from a local mirror.

**MEASURED trap**, kept because it recurs: build containers must match the target. `build-singularity.sh` once built
in `ubuntu:26.04` for a Forky target; Ubuntu carries `libsodium.so.23` and Forky `.26`, so the payload died on the
board with `error while loading shared libraries`.

---

## 6. Initramfs: dracut

**DECIDED, and done.** Installed images build their initramfs with dracut, and the build does not install
`initramfs-tools` into the system (`manifests/installer-base.pkgs`). It stays in the rescue environment, as the tool
for rebuilding a target's initrd by hand. Debian is making the same move during the Forky cycle (Debian bug
#1114857), so we arrive with a configuration we measured rather than inherit a default we did not.

**MEASURED, and this is why the configuration is load-bearing.** A stock `dracut` run on the O6N omits 24 modules
that initramfs-tools ships, while producing the same module count (45 against 45), so a superficial comparison reads
as equivalent. The omissions include `linlon-dp` and `trilin-dpsub`, **the only video console on the board** (an
initrd without them is a permanent black screen); the USB-ethernet recovery set (`r8152`, `ax88179_178a`, `asix`,
`cdc_ether`, `lan78xx`, `smsc95xx` and others), which removes network recovery on a headless board; and `squashfs`
and `dm-mod`. With `assets/dracut/10-ncz-sky1.conf` applied, the comparison against initramfs-tools reads 45 modules
against 69 (the extras are hostonly bloat, kept because a superset that boots beats a lean image that might not),
with **0 missing**.

The config also forces bounded failure. **MEASURED:** with no root device, initramfs-tools panics and reboots, but
dracut stops at a sulogin prompt and waits forever, an indefinite hang on a headless board. Hence
`rd.shell=0 rd.emergency=reboot rd.timeout=30`, and `hostonly=no` so a shipped image boots on any Sky1 board rather
than only the one that built it.

---

## 7. Recurring lessons

- **A benchmark that measures the wrong thing is worse than no benchmark.** Compositor, vsync, governor and cached
  sysfs values each moved the GPU numbers by more than the effect being measured.
- **"Configured" is not "working".** The mpv `hwdec` config, and a `/etc/dracut.conf.d` that was never populated,
  both looked correct and did nothing.
- **Empty output is not evidence of absence.** `journalctl -k` returns nothing unprivileged, and `hwclock` and
  `ldconfig` vanish from an unprivileged PATH. Each produced a confident wrong conclusion before being caught.

## 8. Beta, two kernels, two filesystems, and the legacy we dropped

Everything above explains individual choices. This section explains the situation they add up to.

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

**Which releases.** Preview 4 predates this decision and ships Linux 7.4 only (`7.4.0-rc3`), one kernel per image.
The next preview carries both kernels. Only 7.3.5 and later come back; earlier 7.3 builds stay retired.

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

*Maintained in `docs/DESIGN-RATIONALE.md`.*
