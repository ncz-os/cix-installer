# AMD64 package audit — manifest design (2026-09-14)

Operator directive: audit the Sky1/arm64 package manifests
(`manifests/installer-base.pkgs`, `desktop.pkgs`, `mgmt.pkgs`, `rescue.pkgs`)
and produce the AMD64 equivalents. Full architectural context: MNEMOS
`mem_1789429924427_8b2ad1` (dual-kernel GRUB-selectable installer decision),
`~/.claude/rules/build-cluster-distribution.md` "Boot-validation targets" +
"Shared build storage" sections.

Two AMD64 kernels are building in parallel as of this audit (not yet landed
as real packages): **v7.2.6+T2, unified stable** on PROTEUS — serves both
real Apple T2 Macs (MEDUSA) and regular PCs (PEGASUS), confirmed safe because
t2linux's full 21-patch series is PCI/USB/ACPI-device-ID or DMI gated
throughout, including the one that looked riskiest
(`9001-ACPI-x86-Apple-T2-systems-need-early-CPU-offlining.patch`, verified
gated on `PCI_DEVICE_ID_APPLE_T2_BRIDGE`) — and **v7.3-rc3, edge** on
CERBERUS (broad Debian-installer-style hardware detection, no T2 patches).

Note on prior art: `docs/BUILD-HOSTS.md` (commit `3076d3a8`, never merged —
see "orphaned commits" below) designated ARGOS as "the designated x86 host
for a future amd64 NCZ-OS target." Tonight's actual build landed on
PROTEUS/CERBERUS instead — a real divergence from that doc's plan, noted
here rather than silently ignored. Whether ARGOS still has a role (e.g. as
the AMD64 build orchestrator, matching how it's scoped for arm64 per
`build-cluster-distribution.md`'s "ARGOS is origin/orchestrator, not a
worker") is not resolved by this audit.

## Manifests produced

- `manifests/installer-base-amd64.pkgs`
- `manifests/desktop-amd64.pkgs`
- `manifests/rescue-amd64.pkgs`
- **`mgmt.pkgs` has NO amd64 variant** — read in full, every package in it
  (systemd-sysv, dbus, systemd-resolved, openssh-server + sftp, rsync, curl,
  less, vim-tiny, ca-certificates, btrfs-progs, e2fsprogs, dosfstools) is
  ordinary Debian packaging with zero Sky1-specific content. Reuse as-is.

## Classification summary

Real counts, measured directly (`grep -vE '^\s*(#|$)' <file> | wc -l`) against
the actual committed files, not estimated:

| File | Real package lines | vs. Sky1 original |
|---|---|---|
| `installer-base-amd64.pkgs` | 59 | `installer-base.pkgs` has 60 (net: −3 dropped, +2 added) |
| `desktop-amd64.pkgs` | 172 | `desktop.pkgs` has 199 |
| `rescue-amd64.pkgs` | 100 | `rescue.pkgs` has 93 (net: +6 restored x86 tooling, −1 dropped) |

**The desktop delta (199 → 172, a drop of 27, not the ~8 the drop/add list
below would suggest) is NOT primarily package removal — it's
deduplication.** The Sky1 `desktop.pkgs` file accreted the same package name
more than once across several historical "buckets" (e.g. `vulkan-tools`,
`clinfo`, `glmark2-es2-wayland` and others each appear 2-3 times, added by
different r130.4/r178/r181-era commits that didn't check for an existing
entry). `desktop-amd64.pkgs` lists each real package once. Every package
name that should carry forward does — this is a real simplification, not
data loss, but stating it plainly here since a naive line-count diff would
otherwise look like ~19 unexplained silent drops.

Explicit drops/adds (these ARE real content changes, not dedup):

| Bucket | installer-base | desktop | rescue |
|---|---|---|---|
| Dropped (Sky1-only) | 3 (`gcc-aarch64-linux-gnu`, `linux-image-cixmini`, `cixmini-boot`) | 8 (`chromium-ncz-sky1`, `ncz-ffmpeg`, 5× arch-irrelevant `libdrm-*` transitive noise, `ncz-singularity-desktop` — commented out pending the orphaned arch-fix commit, see finding #1) | 1 (`device-tree-compiler`) |
| Added (AMD64-specific) | 2 (`grub-efi-amd64`, `grub-pc-bios`) | 2 seeded unconditionally (`intel-microcode`, `amd64-microcode`); GPU/T2 stacks are install-time-conditional via `post-install/54-gpu-accel.sh`, not seeded in the manifest — see below | 6 (`amd64-microcode`, `memtest86+`, `syslinux`, `syslinux-efi`, `ms-sys`, `intel-microcode` — rescue.pkgs' own header already documented these as excluded specifically for being "not applicable to a headless arm64 box") |

## Real findings, not obvious from a package-name diff alone

### 1. `build-singularity-deb.sh` hardcodes `Architecture: arm64` — fix exists, was never merged

Commit `39058bc5` ("fix(build-singularity-deb): derive package Architecture,
don't hardcode arm64", 2026-07-27, author Jason Perlow) does exactly the
right thing — defaults `ARCH` to `dpkg --print-architecture`, with an
`NCZ_SINGULARITY_ARCH` override. **`git merge-base --is-ancestor 39058bc5
HEAD` returns false — this commit is not on `master`.** It has been sitting
orphaned for seven weeks. This blocks building `ncz-singularity-desktop` for
AMD64 at all until merged/cherry-picked. Real, mergeable, zero-risk fix
(7 lines) — recommend landing it in the same session that starts real AMD64
package builds.

### 2. Two parallel Sky1-VPU-ffmpeg integration paths exist, neither portable

`desktop.pkgs` seeds a real `ncz-ffmpeg` **.deb package** (installs under
`/opt/ncz-ffmpeg`, symlinked onto PATH ahead of system ffmpeg). Separately,
`post-install/83-vpu-ffmpeg.sh` stages a **different, self-contained bundle**
(`assets/cix-mm/bundle.tgz` → `/opt/cix-ffmpeg`) with its own wrapper
binaries. Both exist in the current tree; whether they're redundant,
sequential, or serve genuinely different call sites was not fully resolved
by this audit (out of scope — this is a package-manifest audit, not a
build-script archaeology pass). What IS certain: **both are Linlon-VPU
V4L2-multiplane-specific** (`docs/upstream-patches/ffmpeg-v4l2-multiplane.patch`
is literally patching the plane-layout bug that only exists on this
hardware) — neither has an AMD64 equivalent, and building one means starting
from stock ffmpeg + VAAPI (Intel/AMD) and NVENC/NVDEC (NVIDIA) hwaccel APIs,
not forward-porting either existing artifact. **Not built this pass** —
real follow-on work, scope it as its own task before attempting it.

### 3. Vivaldi staging is hardcoded arm64-only

`post-install/52-vivaldi.sh` line 34: `ls "$VIV_DIR"/vivaldi-stable_*_arm64.deb`
— a literal arch-locked glob. Vivaldi genuinely ships real amd64 `.deb`
builds (this is not a "no Linux amd64 Vivaldi exists" gap), so the fix is
mechanical: stage the amd64 `.deb` alongside/instead of the arm64 one under
`assets/vivaldi/`, and generalize the glob (e.g.
`vivaldi-stable_*_$(dpkg --print-architecture).deb`). **Not built this
pass** — real, small, follow-on task.

### 4. `google-chrome-stable`'s apt-source wiring is already arch-generic

`post-install/53-chrome.sh` wires Google's own multi-arch apt repo
(`dl.google.com/linux/chrome-stable/deb/`) — Google's repo serves amd64
natively, no changes needed to that hook for the AMD64 line. Confirmed by
reading the hook in full; it never branches on architecture at all, which is
correct here (unlike Vivaldi's hardcoded glob above).

### 5. GPU/accelerator package names — verified live, not guessed

Checked directly against a real Debian 13 trixie host (CERBERUS,
`apt-cache search`, 2026-09-14) rather than assumed from general knowledge:

- **ROCm (AMD, PCI vendor `1002`/`1022`) IS in Debian's own archive** —
  `rocm-opencl-icd`, `rocm-smi`, `rocminfo`, `rocm-device-libs-17`,
  `rocm-cmake` all resolve from `main`. No third-party AMD repo needed for
  the core stack.
- **NVIDIA (PCI vendor `10de`)**: Debian ships `nvidia-driver` (metapackage,
  `non-free-firmware` component — already enabled fleet-wide, confirmed in
  `/etc/apt/sources.list`). The full CUDA *toolkit* is NOT in Debian's own
  archive; needs NVIDIA's own repo
  (`developer.download.nvidia.com/compute/cuda/repos/debian13/x86_64/`) —
  already precedented live: CERBERUS itself already has this exact repo
  configured (`/usr/share/keyrings/cuda-archive-keyring.gpg`).
- **Intel (PCI vendor `8086`)**: Debian ships `intel-media-va-driver`
  (VAAPI) directly. Full OpenVINO toolkit is confirmed ABSENT from Debian's
  archive (searched, not found) — needs Intel's own repo
  (`apt.repos.intel.com`), same class of gap as CUDA.

### 6. T2-specific WiFi/Bluetooth firmware — real source identified

T2 Macs need Apple's proprietary Broadcom WiFi/BT firmware blobs, separate
from the kernel itself. Real source:
**`github.com/AdityaGarg8/Apple-Firmware`**, which ships an actual
architecture-independent Debian package (`apple-firmware_14.5-1_all.deb`).
Independently cross-checked live on MEDUSA itself: it already has the AUR
equivalent (`apple-bcm-firmware`) installed, providing hundreds of real
firmware files at `/usr/lib/firmware/brcm/*apple*` — confirmed present on
real hardware, not a guess. This is **T2-conditional**, same
install-time-detection pattern as the GPU stack below — not shipped
unconditionally on every AMD64 install.

## Install-time hardware detection — GPU stack: IMPLEMENTED this pass

Operator correction mid-pass: "We are not a free only distro like Debian, we
install to make things work" — the GPU stack must pull each vendor's REAL
OFFICIAL driver repo (same posture `53-chrome.sh` already established for
Chrome, and `24-apt-sources.sh` for our own Buildkite repo), not rely on
Debian's own in-archive packages (older/incomplete — e.g. Debian's own
`nvidia-driver` gets you a driver but not the full CUDA toolkit without
NVIDIA's own repo anyway).

**`post-install/54-gpu-accel.sh` written this pass**, following
`53-chrome.sh`'s exact structural conventions (BUILD_VARIANT headless-skip
guard, `set +e`, idempotent keyring/source-file writing, graceful-absence
no-op, `[54]`-tagged logging). Detects GPU vendor(s) via `lspci -nn` PCI
class (`0300`/`0302`/`0380`) + vendor ID (`10de` NVIDIA, `1002`/`1022` AMD,
`8086` Intel) — additive per vendor found, not a single exclusive branch (a
laptop with Intel iGPU + NVIDIA dGPU gets both stacks). Real repo URLs
verified live via WebSearch 2026-09-14, not guessed:

- **NVIDIA**: `developer.download.nvidia.com/compute/cuda/repos/debian13/x86_64/`
  — `cuda-keyring_1.1-1_all.deb`, confirmed current for Debian 13 (trixie)
  specifically (not just "debianNN" generically — this exact path is live
  and matches our target release). `apt-get install cuda-drivers`.
- **AMD**: `repo.radeon.com/rocm/apt/<version>` (`7.2.4` current at time of
  writing) + `repo.radeon.com/rocm/rocm.gpg.key`. AMD's ROCm docs have a
  dedicated "Debian native installation" page, so this is a real supported
  path, not an Ubuntu-only one — though the apt suite component itself is
  still named by Ubuntu codename (`jammy`) even when targeting Debian; noted
  in the script's own comments as a real, deliberate quirk of AMD's repo
  layout, not a mistake in this hook.
- **Intel**: `apt.repos.intel.com/openvino`, component `ubuntu24` — same
  Ubuntu-codename-even-on-Debian quirk, confirmed via Intel's own current
  install docs (no `debianNN` component exists). `apt-get install openvino
  intel-opencl-icd intel-media-va-driver`.

**Not yet done**: the NVIDIA keyring `.deb` needs to actually be staged
under `assets/nvidia/` (the hook checks for it and warns+skips cleanly if
absent, matching the graceful-degradation pattern elsewhere in this repo,
but nobody has fetched+committed the real file yet). AMD/Intel fetch their
keys live at install time via `curl`, which requires network at build/
install time — unlike the rest of this offline-first pipeline. Whether that
needs to become a staged-asset pattern too (matching NVIDIA and everything
else in this repo's offline-closure design) is a real open question, not
resolved in this pass — flagged as follow-on below.

## Install-time hardware detection — T2 firmware: DONE (follow-up pass)

Implemented in `post-install/55-t2-firmware.sh`, same real-vendor-repo
posture as `54-gpu-accel.sh`/`53-chrome.sh`. T2 detection uses the same
`lspci -nn` mechanism the GPU hook uses — the T2 coprocessor is itself a PCI
device, `[106b:1801]` (Apple vendor ID + `PCI_DEVICE_ID_APPLE_T2_BRIDGE`),
confirmed directly in t2linux's own kernel patch (not guessed). The
**real, corrected source** is `AdityaGarg8/t2-ubuntu-repo`, NOT
`AdityaGarg8/Apple-Firmware` as an earlier pass cited — that repo does not
exist (confirmed 404 via GitHub API; the earlier WebSearch citation was
wrong). `t2-ubuntu-repo` is a real, verified apt repository (KEY.gpg and
t2.list both confirmed HTTP 200 with real content) with explicit Debian 13
(trixie) support. Only `apple-firmware-script` (provides `get-apple-firmware`)
and `apple-t2-audio-config` are installed — the repo's kernel-driver
packages (`apple-bce`, `applesmc-t2`, etc.) are deliberately NOT installed,
per the repo's own documented warning that they conflict with a
`linux-t2`-class kernel, which is exactly what our own v7.2.6+T2 build is.

**UPDATE 2026-09-15 — the PCI detection itself is now verified against
REAL T2 hardware**, closing the caveat below for the detection step
(the firmware-fetch step's own caveat still stands, see next paragraph).
The `[106b:1801]` check moved out of this hook into a shared, testable
`post-install/lib/hw-detect.sh` (`is_t2_hardware`/`t2_hardware_detail`),
gained a DMI fallback (Apple `sys_vendor` + a T2-era `product_name` list,
matching mainline Linux's own `x86_apple_machine` generic-Apple DMI test
narrowed to T2-generation models) for when `lspci` itself is unavailable,
and was read-only oracle-checked directly on MEDUSA (a real
MacBookPro16,1): `lspci -nn` shows
`04:00.1 ... Apple Inc. T2 Bridge Controller [106b:1801]`, and
`/sys/class/dmi/id/{sys_vendor,product_name}` read `Apple Inc.` /
`MacBookPro16,1` — both match this function's detection patterns exactly.
The negative case was verified live on PROTEUS (real amd64 HP hardware,
`sys_vendor=HP`): the hook runs end-to-end, logs
`T2 hardware: not detected`, and cleanly skips the firmware install with
no apt/network calls — confirmed via a real invocation, not by inspection.
55-t2-firmware.sh now also unconditionally logs
`T2 hardware: detected`/`not detected` on every amd64 run, before the
headless/server variant gate, so this is visible in install logs
regardless of SKU or whether it changes anything for that install.

**Real caveat, not glossed over — still open**: `get-apple-firmware` itself
(the actual macOS-firmware-CDN fetch, downstream of detection) fetches real
firmware packages from Apple's own CDN based on the detected Mac model at
real install time — this specific step has still NOT been exercised against
real T2 hardware (MEDUSA is a read-only boot-validation oracle, not a
target to install onto). Detection now IS verified; the firmware-fetch tool
itself is the remaining unverified piece.

## What's actually done vs. follow-on (honest accounting) — UPDATED after "fix all" pass

**Done in this follow-up pass** (all 6 items from the original follow-on
list below were addressed; see commit for this pass):

1. **Merged the orphaned commit `39058bc5`** directly into
   `build/build-singularity-deb.sh` (applied cleanly despite 7 weeks of
   drift, verified via `git apply --check` before applying) — `ncz-singularity-desktop`
   can now build correctly for amd64.
2. **Ffmpeg hwaccel — reassessed, not a straight port.** Real finding:
   Sky1's `ncz-ffmpeg` patch fixes a bug specific to Debian ffmpeg's V4L2
   multi-planar fourcc handling — unrelated to VAAPI/NVENC codec paths.
   Debian's stock `ffmpeg` package already ships VAAPI support compiled in,
   so **Intel/AMD hwaccel needs no custom build at all**. NVIDIA is
   different: Debian's ffmpeg excludes NVENC for licensing reasons
   (nonfree), so a custom `--enable-nonfree --enable-nvenc` build is
   genuinely still needed for NVIDIA — but this is a much narrower task
   than Sky1's patch (no plane-layout work) and a full from-source compile
   + hardware test is bigger than this pass's scope (no NVIDIA hardware
   available to verify against in this fork; CERBERUS has a real RTX 4500
   ADA — test there when attempting this). **Still follow-on, but rescoped**:
   only NVIDIA needs a custom `ncz-ffmpeg-amd64-nvenc`-class package; VAAPI
   needs nothing beyond the stock `ffmpeg` package already in the manifest.
3. **`post-install/52-vivaldi.sh`'s glob is now arch-aware** (same
   `NCZ_TARGET_ARCH`/`BUILD_ARCH`/`dpkg --print-architecture` pattern as
   `post-install/21-flatpak-arch-filter.sh`). Staging a real Vivaldi amd64
   `.deb` into `assets/vivaldi/` itself is still a separate, real follow-on
   (Vivaldi does publish a real amd64 `.deb` — just not fetched in this
   pass).
4. **T2 firmware hook implemented** — see section above.
5. **NVIDIA's `cuda-keyring_1.1-1_all.deb` staged** at `assets/nvidia/`
   (real file, 4182 bytes, downloaded and verified via `file`) and wired
   into `build/build-squashfs-layers.sh`'s asset-staging block, same
   pattern as the Vivaldi/branding/wallpaper staging blocks.
6. **Hook ordering — confirmed AND a real bug found+fixed.**
   `post-install/run-all.sh` runs hooks in numeric-sort order, and
   `10-our-kernel.sh` (kernel + headers) is in the REQUIRED phase, which
   always runs before any numbered hook above it — so DKMS ordering for
   `54`/`55` was never actually at risk. But a **real, separate bug** was
   found in the same file: `54-gpu-accel.sh` was missing from
   `MACHINE_HOOKS_RE`, meaning it would be **silently excluded and never
   run** on a baked-image install (`NCZ_BAKED=1`) — the exact orphan-hook
   bug class this same file's own comments describe for
   `12-sky1-firmware`/`33-network`. Fixed by adding both `54-gpu-accel` and
   `55-t2-firmware` to `MACHINE_HOOKS_RE` and `_SKIP_DESKTOP_RE`.

**Follow-on work, still not attempted:**
1. Actually stage a real Vivaldi amd64 `.deb` (the hook code is fixed, the
   binary asset isn't fetched yet).
2. Build the NVIDIA NVENC ffmpeg variant (rescoped smaller per above, but
   still a real from-source build + hardware test on CERBERUS).
3. Resolve the ARGOS-vs-PROTEUS/CERBERUS build-host divergence from
   `docs/BUILD-HOSTS.md`'s original amd64 plan (not this audit's scope).
4. **Still BLOCKING**: `installer-base-amd64.pkgs`'s "NCZ kernel channels"
   section has no real kernel package names yet — fill in once either
   in-flight AMD64 kernel build (v7.2.6+T2 on PROTEUS, v7.3-rc3 edge on
   CERBERUS) lands as a packaged `.deb`.
5. Verify `get-apple-firmware` against real T2 hardware (MEDUSA) — untested
   in this pass, no T2 machine available.
7. Stage the NVIDIA `cuda-keyring` `.deb` under `assets/nvidia/` to match
   this repo's offline-closure design, rather than leaving it as a
   build-time gap in `54-gpu-accel.sh`. Decide whether AMD's/Intel's
   live-`curl`-fetched keys (see finding #6 above) need the same offline
   staging treatment, or whether GPU-driver-repo access at install time is
   an acceptable, deliberate exception to the offline-first design — not
   decided in this pass.
8. Confirm hook ordering in `run-all.sh` actually installs kernel
   headers/the kernel package before `54-gpu-accel.sh` runs — the NVIDIA
   `cuda-drivers`/DKMS install depends on this (see the CAVEAT comment in
   the script itself).
