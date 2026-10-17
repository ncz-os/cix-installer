# Documentation index

Every Markdown document in this repository, for NCZ-OS 26.10 "Cygnus". The
[README](../README.md) is the starting point; the current release notes are
[26.10 "Cygnus"](releases/26.10-cygnus-20261013.md) (images of 2026-10-13). Documents from
earlier releases (dated reports, plans and evidence) were removed from the tree
for 26.10; they remain in the git history and in the `v26.10-preview1` tag.

## Start here

| Document | What it covers |
|---|---|
| [README](../README.md) · [简体中文](../README.zh-CN.md) | What NCZ-OS is, hardware tested, installing an image, building, architecture, screenshots |
| [releases/26.10-cygnus-20261013.md](releases/26.10-cygnus-20261013.md) | Release notes for 26.10 (images of 2026-10-13): images and checksums, kernels, what is in the release, changes since Preview 1, tested hardware |
| [releases/26.10-cygnus-preview1.md](releases/26.10-cygnus-preview1.md) | Release notes for 26.10 Preview 1 (2026-10-12), kept for reference |
| [releases/26.10-cygnus.md](releases/26.10-cygnus.md) | Where the name "Cygnus" comes from, and the 26.10 identity and theme |
| [RELEASE-HISTORY.md](RELEASE-HISTORY.md) | Short release history; per-release archive up to 26.7 |
| [SOURCE-RELEASES.md](SOURCE-RELEASES.md) · [简体中文](SOURCE-RELEASES.zh-CN.md) | Everything we compile ourselves, its version and where the source is |
| [REMOTE-ACCESS.md](REMOTE-ACCESS.md) | Remote-access and recovery defaults (telnet, SSH, recovery container) and how to turn each off |
| [ACCESSIBILITY.md](ACCESSIBILITY.md) | Braille displays: the installer has no braille support; install `brltty` with apt on the installed system, and why |
| [RECOVERY-LOGINS.md](RECOVERY-LOGINS.md) | The installer diagnostics login (installer only, shown in the boot banner) and the rescue partition login: where each is shown, how to connect, change and reset it, troubleshooting |
| [`tools/ncz-join-image.sh`](../tools/ncz-join-image.sh) | Joins, unpacks and checks the split release image parts (safe to re-run; never writes to a disk) |
| [IMAGE-HOSTING.md](IMAGE-HOSTING.md) | Where release images are hosted (GitHub Releases, GitLab release + package registry, fallback storage), the one-release-page rule, stable latest-release links, release page parity and the release checklist |
| [`tools/check-release-parity.sh`](../tools/check-release-parity.sh) | Read-only check that the GitHub and GitLab release pages show the same release |
| [`tools/refresh-release-links.sh`](../tools/refresh-release-links.sh) | Moves the GitHub release links in README/docs to a new release tag at release time |
| [`tools/sync-release-pages.sh`](../tools/sync-release-pages.sh) | Publishes a staged release to both release pages and retires the old ones (dry run unless approved) |
| [releases/release-page-template.md](releases/release-page-template.md) | Template for a release page's NOTES.md |

## Hardware, kernel and boot

| Document | What it covers |
|---|---|
| [ONE-KERNEL.md](ONE-KERNEL.md) | One kernel per image: the default, installer and rescue entries all boot the NCZ kernel |
| [MAGNETAR-SERVER-VARIANT.md](MAGNETAR-SERVER-VARIANT.md) | `NCZ_VARIANT=server`: which parts of the install medium move online (measured), the pinned-manifest fetch at install time, and what stays on the medium because d-i reads it before the debootstrap stub |
| [SUPPORTED-FIRMWARE.md](SUPPORTED-FIRMWARE.md) | Supported Sky1 board firmware (Radxa Orion EFI 1.3.1 and later) and firmware gaps |
| [REFIND-THEME.md](REFIND-THEME.md) | The Cygnus rEFInd boot-menu theme and why it uses one 1080p background |
| [INSTALLER-BOOT-UX.md](INSTALLER-BOOT-UX.md) | What the installer console shows and why |
| [GPU-INSTALL-PROGRESS.md](GPU-INSTALL-PROGRESS.md) | GPU driver install progress on the installer screen |
| [GPU-COMPAT-SWITCHER-DECISION.md](GPU-COMPAT-SWITCHER-DECISION.md) | Why ncz-gpu-switcher never re-enables 01-cixgpu-compat.conf, and why the old unmerged fix is superseded |
| [HIDPI-SCALING.md](HIDPI-SCALING.md) | How the boot splash, login screen and desktop are scaled on high-density displays |
| [APT-SEPARATION.md](APT-SEPARATION.md) | How NCZ-OS package updates are kept separate from Debian ones (apt pin, one repository, labelled updates) |
| [CUDA-DYNAMIC-INSTALL.md](CUDA-DYNAMIC-INSTALL.md) | NVIDIA driver and CUDA installed per GPU family on amd64 |
| [T2-GMUX.md](T2-GMUX.md), [T2-SMP.md](T2-SMP.md), [T2-THUNDERBOLT.md](T2-THUNDERBOLT.md) | Which Apple T2 driver owns what, and which T2 modules are not loaded |
| [T2-POWER-CAP.md](T2-POWER-CAP.md) | CPU package power cap for MacBookPro16,1 under sustained load |
| [T2-CONSOLE-NOISE.md](T2-CONSOLE-NOISE.md) | Why T2 boot "hardware error" lines appear, and the console policy |
| [HW-VIDEO-DECODE-STATUS.md](HW-VIDEO-DECODE-STATUS.md) | Hardware video decode on Sky1 (VA-API route) |
| [NCZ-SKY1-AUDIO-AUTOSWITCH.md](NCZ-SKY1-AUDIO-AUTOSWITCH.md) | Automatic HDMI/DP audio switching on Sky1 boards |
| [NPU-USAGE-GUIDE.md](NPU-USAGE-GUIDE.md) | Using the Sky1 Zhouyi NPU from Python, with a worked example |
| [`assets/kernel/patches/PATCHES.md`](../assets/kernel/patches/PATCHES.md) | NCZ-authored Sky1 kernel patches |
| [`assets/kernel/npu/README.md`](../assets/kernel/npu/README.md) | NPU kernel driver notes and how it was verified |
| [`assets/kernel/t2smc/README.upstream.md`](../assets/kernel/t2smc/README.upstream.md) | The t2smc SMC driver for T2 Macs (upstream README) |
| [`assets/kernel/vpu/src/README.md`](../assets/kernel/vpu/src/README.md) | CIX VPU DKMS source |
| [`assets/sinty-nm/README.md`](../assets/sinty-nm/README.md) | The `sinty-nmd` network daemon staged into the base layer |
| [`assets/rescue/AGENTS.md`](../assets/rescue/AGENTS.md) | Recovery notes installed on the rescue partition (`/AGENTS.md`) |
| [`kernel-source/SOURCE.md`](../kernel-source/SOURCE.md), [`CORRESPONDING-SOURCE.md`](../kernel-source/linux-cix-sky1-ncz/CORRESPONDING-SOURCE.md) | Corresponding source for the 7.2 Sky1 kernel shipped in 26.7 (GPL records) |

## Desktop, theme, wallpapers and screensavers

| Document | What it covers |
|---|---|
| [`branding/cygnus/INTEGRATION.md`](../branding/cygnus/INTEGRATION.md) | How the Cygnus theme is wired in as the default |
| [`branding/cygnus/singularity/UPSTREAM-NOTE.md`](../branding/cygnus/singularity/UPSTREAM-NOTE.md) | What a theme can and cannot set in Singularity today |
| [`assets/branding/README.md`](../assets/branding/README.md) | Branding assets and the hooks that install them |
| [showcase/README.md](showcase/README.md) | The 26.10 screensaver showcase gallery |
| [SCREENSAVER-CATALOGUE-RETIREMENT.md](SCREENSAVER-CATALOGUE-RETIREMENT.md) | Why the old screensaver chooser was retired in favour of the settings page |
| [`tests/lockscreen-framesrc/README.md`](../tests/lockscreen-framesrc/README.md) | How the lock screen shows a live screensaver behind it (headless test) |
| [WALLPAPER-SAFE-AREA.md](WALLPAPER-SAFE-AREA.md) | Wallpaper cover scaling, safe area and aspect variants |
| [WALLPAPER-PACKS.md](WALLPAPER-PACKS.md) | Wallpaper packs, Artist Packs and providers (design; parts implemented) |
| [OCS-WALLPAPER-BACKEND.md](OCS-WALLPAPER-BACKEND.md) | Backend for OCS wallpaper sources |
| [`assets/singularity/patches/README.md`](../assets/singularity/patches/README.md) | The NCZ patch set applied to the Singularity desktop, per subproject, with upstream status |
| [`packaging/singularity/landed-upstream/README.md`](../packaging/singularity/landed-upstream/README.md) | Singularity changes that have landed upstream |

## Design, AI/ML and building

| Document | What it covers |
|---|---|
| [REGISTRY-CLEANUP.md](REGISTRY-CLEANUP.md) | Package registry retention: what is kept, what is removed, the cleanup policy and the weekly cleanup run |
| [BUILD-SITE-CONFIG.md](BUILD-SITE-CONFIG.md) | Per-build-host settings (store mount points, build hosts, publish targets) as environment variables or `~/.config/ncz/` files |
| [DESIGN-RATIONALE.md](DESIGN-RATIONALE.md) | Why the stack is built the way it is, with the measurements (26.7 era) |
| [PLATFORM-SPLIT-DESIGN.md](PLATFORM-SPLIT-DESIGN.md) | What is common to both architectures and what is platform-specific |
| [SID-EXCEPTIONS.md](SID-EXCEPTIONS.md) | Generated report of reviewed installer packages taken from sid |
| [FORKY-ONLY-REMEDIATION-PROPOSAL.md](FORKY-ONLY-REMEDIATION-PROPOSAL.md) | Proposal (not adopted): where Ubuntu still appears, and a staged path to a forky-only base with no Ubuntu repository usage |
| [AI-ML-STACK.md](AI-ML-STACK.md) · [简体中文](AI-ML-STACK.zh-CN.md) | The AI/ML stack on Sky1: CPU, NPU, GPU and VPU and what runs where |
| [INFERENCE_LIMITS.md](INFERENCE_LIMITS.md) | Measured per-engine inference capability and limits on Sky1 (earlier kernels) |
| [MODELSCOPE-MODELS.md](MODELSCOPE-MODELS.md) | Pulling and compiling `.cix` NPU models from the CIX model hub |
| [`assets/models/MODELS-README.md`](../assets/models/MODELS-README.md) | The embedding models directory and how its models were built |

## Upstream work

| Document | What it covers |
|---|---|
| [upstream-patches/firefox/README.md](upstream-patches/firefox/README.md) | Firefox V4L2-M2M hardware video decode patches |
| [upstream-patches/ffmpeg/README.md](upstream-patches/ffmpeg/README.md) | FFmpeg V4L2 M2M patches for Sky1 |
| [upstream-patches/amvx/README.md](upstream-patches/amvx/README.md) | VPU driver (amvx) patches |
| [upstream-patches/cix-vaapi/README.md](upstream-patches/cix-vaapi/README.md) | CIX VA-API driver patches |
| [upstream-patches/gtk/GTK-BUG-DRAFT.md](upstream-patches/gtk/GTK-BUG-DRAFT.md) | Draft GTK bug report (GLES on Mali) |

`assets/docs/INFERENCE_LIMITS.md` and `assets/docs/MODELSCOPE-MODELS.md` are
symlinks to the documents above, installed to `/usr/share/doc/ncz/`. Two
Markdown files under `build/` are test fixtures, not documentation.
