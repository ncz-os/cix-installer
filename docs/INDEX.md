# Documentation index

A reader's map of the documentation in this repository, for NCZ-OS 26.10
"Cygnus". The [README](../README.md) is the starting point; the current release
notes are [26.10 "Cygnus" Preview 1](releases/26.10-cygnus-preview1.md).

Documents in the first part are maintained and describe the current code.
Documents under **Historical records** describe what was true when they were
written and are kept for provenance; they are not updated.

## Start here

| Document | What it covers |
|---|---|
| [README](../README.md) · [简体中文](../README.zh-CN.md) | What NCZ-OS is, hardware tested, installing an image, building, architecture |
| [releases/26.10-cygnus-preview1.md](releases/26.10-cygnus-preview1.md) | Release notes for 26.10 Preview 1: images, kernels, what is new, known limitations |
| [releases/26.10-cygnus.md](releases/26.10-cygnus.md) | Where the name "Cygnus" comes from, and the 26.10 identity and theme |
| [RELEASE-HISTORY.md](RELEASE-HISTORY.md) | Short release history; per-release archive up to 26.7 |
| [SOURCE-RELEASES.md](SOURCE-RELEASES.md) · [简体中文](SOURCE-RELEASES.zh-CN.md) | Everything we compile ourselves, its version and where the source is |
| [REMOTE-ACCESS.md](REMOTE-ACCESS.md) | Remote-access and recovery defaults (telnet, SSH, recovery container) and how to turn each off |
| [`tools/ncz-join-image.sh`](../tools/ncz-join-image.sh) | Joins, unpacks and checks the split release image parts |

## Hardware, kernel and boot

| Document | What it covers |
|---|---|
| [ONE-KERNEL.md](ONE-KERNEL.md) | One kernel per image: the default, installer and rescue entries all boot the NCZ kernel |
| [SUPPORTED-FIRMWARE.md](SUPPORTED-FIRMWARE.md) | Supported Sky1 board firmware (Radxa Orion EFI 1.3.1 and later) and firmware gaps |
| [REFIND-THEME.md](REFIND-THEME.md) | The Cygnus rEFInd boot-menu theme and why it uses one 1080p background |
| [INSTALLER-BOOT-UX.md](INSTALLER-BOOT-UX.md) | What the installer console shows and why |
| [GPU-INSTALL-PROGRESS.md](GPU-INSTALL-PROGRESS.md) | GPU driver install progress on the installer screen |
| [HIDPI-SCALING.md](HIDPI-SCALING.md) | How the boot splash, login screen and desktop are scaled on high-density displays |
| [CUDA-DYNAMIC-INSTALL.md](CUDA-DYNAMIC-INSTALL.md) | NVIDIA driver and CUDA installed per GPU family on amd64 |
| [T2-GMUX.md](T2-GMUX.md), [T2-SMP.md](T2-SMP.md), [T2-THUNDERBOLT.md](T2-THUNDERBOLT.md) | Which Apple T2 driver owns what, and which T2 modules are not loaded |
| [T2-POWER-CAP.md](T2-POWER-CAP.md) | CPU package power cap that stops load-triggered power cuts on MacBookPro16,1 |
| [HW-VIDEO-DECODE-STATUS.md](HW-VIDEO-DECODE-STATUS.md) | Hardware video decode on Sky1 (VA-API route) |
| [NPU-USAGE-GUIDE.md](NPU-USAGE-GUIDE.md) | Using the Sky1 Zhouyi NPU from Python, with a worked example |
| [`assets/kernel/patches/PATCHES.md`](../assets/kernel/patches/PATCHES.md) | NCZ-authored Sky1 kernel patches |
| [`assets/kernel/t2smc/README.upstream.md`](../assets/kernel/t2smc/README.upstream.md) | The t2smc SMC driver for T2 Macs (upstream README) |
| [`assets/kernel/vpu/src/README.md`](../assets/kernel/vpu/src/README.md) | CIX VPU DKMS source |
| [`assets/kernel/npu/README.md`](../assets/kernel/npu/README.md) | NPU kernel driver notes and how it was verified |
| [`assets/sinty-nm/README.md`](../assets/sinty-nm/README.md) | The `sinty-nmd` network daemon staged into the base layer |
| [`assets/regreet/README.md`](../assets/regreet/README.md) | The superseded regreet greeter (historical note) |

## Desktop, theme and screensavers

| Document | What it covers |
|---|---|
| [`branding/cygnus/INTEGRATION.md`](../branding/cygnus/INTEGRATION.md) | How the Cygnus theme is wired in as the default |
| [`branding/cygnus/singularity/UPSTREAM-NOTE.md`](../branding/cygnus/singularity/UPSTREAM-NOTE.md) | What a theme can and cannot set in Singularity today |
| [`assets/branding/README.md`](../assets/branding/README.md) | Branding assets and the hooks that install them |
| [showcase/README.md](showcase/README.md) | The 26.10 screensaver showcase gallery |
| [SCREENSAVER-CATALOGUE-RETIREMENT.md](SCREENSAVER-CATALOGUE-RETIREMENT.md) | Why the old screensaver chooser was retired in favour of the settings page |
| [`tests/lockscreen-framesrc/README.md`](../tests/lockscreen-framesrc/README.md) | How the lock screen shows a live screensaver behind it (headless test) |
| [WALLPAPER-SAFE-AREA.md](WALLPAPER-SAFE-AREA.md) | Wallpaper cover scaling, safe area and aspect variants |
| [WALLPAPER-PACKS.md](WALLPAPER-PACKS.md) | Wallpaper packs and providers (design; parts implemented) |
| [OCS-WALLPAPER-BACKEND.md](OCS-WALLPAPER-BACKEND.md) | Backend for artist wallpaper packs |

## Design and building

| Document | What it covers |
|---|---|
| [DESIGN-RATIONALE.md](DESIGN-RATIONALE.md) | Why the stack is built the way it is, with the measurements (26.7 era) |
| [PLATFORM-SPLIT-DESIGN.md](PLATFORM-SPLIT-DESIGN.md) | What is common to both architectures and what is platform-specific |
| [SID-EXCEPTIONS.md](SID-EXCEPTIONS.md) | Generated report of reviewed installer packages taken from sid |
| [IMAGE-BUILD-PROCESS.sid-exceptions.md](IMAGE-BUILD-PROCESS.sid-exceptions.md) | How the sid-exception ledger plugs into the image build |
| [AI-ML-STACK.md](AI-ML-STACK.md) · [简体中文](AI-ML-STACK.zh-CN.md) | The AI/ML stack on Sky1: CPU, NPU, GPU and VPU and what runs where |
| [INFERENCE_LIMITS.md](INFERENCE_LIMITS.md) | Measured per-engine inference capability and limits on Sky1 (earlier kernels) |
| [MODELSCOPE-MODELS.md](MODELSCOPE-MODELS.md) | Pulling and compiling `.cix` NPU models from the CIX model hub |

## Upstream work

| Document | What it covers |
|---|---|
| [upstream-patches/firefox/README.md](upstream-patches/firefox/README.md) | Firefox V4L2-M2M hardware video decode patches |
| [upstream-patches/ffmpeg/README.md](upstream-patches/ffmpeg/README.md) | FFmpeg V4L2 M2M patches for Sky1 |
| [upstream-patches/amvx/README.md](upstream-patches/amvx/README.md) | VPU driver (amvx) patches |
| [upstream-patches/cix-vaapi/README.md](upstream-patches/cix-vaapi/README.md) | CIX VA-API driver patches |
| [upstream-patches/gtk/GTK-BUG-DRAFT.md](upstream-patches/gtk/GTK-BUG-DRAFT.md) | Draft GTK bug report (GLES on Mali) |
| [`packaging/singularity/landed-upstream/README.md`](../packaging/singularity/landed-upstream/README.md) | Singularity changes that have landed upstream |

## Historical records

Kept for provenance; not maintained. They describe earlier releases (26.5 to
26.7) or a decision at the time it was made, and may name kernels, boards or
procedures that no longer apply.

| Document | What it records |
|---|---|
| [HOW-DID-WE-GET-HERE.md](HOW-DID-WE-GET-HERE.md) · [简体中文](HOW-DID-WE-GET-HERE.zh-CN.md) | Schedule post-mortem of the Sky1 bring-up |
| [VARIETY-FEATURE-DIFF-2026-09-25.md](VARIETY-FEATURE-DIFF-2026-09-25.md) | Variety wallpaper-tool feature comparison (2026-09-25) |
| [SINGULARITY-MALI-SHADER-GATE.md](SINGULARITY-MALI-SHADER-GATE.md) | A Mali shader regression in the desktop payload and the gate that catches it |
| [showcase/draft-v0/README.md](showcase/draft-v0/README.md) | First draft of the screensaver showcase |
