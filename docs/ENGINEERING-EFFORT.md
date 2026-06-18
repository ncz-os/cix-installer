# Bringing up NCZ / Reinhardt 26.6 on CIX Sky1 — Engineering Effort & Driver-Fidelity Log

> Scope: what it actually took to turn a bare CIX Sky1 (CP8180 / Minisforum
> MS‑R1, "cixmini") board into a shippable, full‑fidelity Linux distribution —
> **Magnetar** (server) and **Reinhardt** (desktop) — with working NPU, GPU,
> audio, display, networking, an on‑device AI stack, a graphical installer, and
> an A/B‑bootable kernel program.
>
> This is written so a reader who wasn't in the room can see the level of
> effort, the dead‑ends, and *why* each fix exists. Most of these problems had
> no documentation anywhere when we hit them.

---

## 0. TL;DR of the effort

- **2 kernels maintained side‑by‑side**: `6.18.26-cix-sky1-lts` (production
  default) and `7.0.12-cix-sky1-next` (beta/edge), plus a stripped
  `…-lts-rescue` target — all selectable from a single systemd‑boot menu with
  **3‑try automatic rollback**.
- **~40+ kernel patches** curated/hand‑merged across the two trees (Sky1‑Linux
  community track + our own validated fixes) before CIX published an official
  patch set.
- **A complete NPU AI runtime brought up from nothing**: kernel driver →
  matched userspace UMD → Python 3.11 ABI‑correct venv → real `.cix` models →
  automatic embeddings in mnemos.
- **~100+ ISO build iterations** (tracked builds r75 → r112) to converge the
  installer, drivers, desktop, and documentation.
- **A graphical installer** with offline mirror, patched debootstrap, post‑install
  hook pipeline, diagnostic/rescue paths, and a self‑destructing diag account.
- Every fix below was validated on **real metal** (the `.66` board), not just
  in a VM.

---

## 1. The starting problem

CIX Sky1 is an ACPI‑first arm64 SoC with a Mali‑G720 (panthor) GPU, an ArmChina
Zhouyi NPU, a Cadence/Trilin/Linlon display pipeline, a CIX i‑p‑bloq HDA + SOF
audio complex, and an MT7922 Wi‑Fi/BT. At the time we started:

- Mainline did **not** boot cleanly on the board without a specific, undocumented
  kernel command line.
- The community kernel fork (`Sky1-Linux/linux-sky1`) booted but shipped
  **non‑functional audio**, an NPU that probed but couldn't run inference, and a
  display path that black‑screened under the stock desktop.
- There was **no distribution** — no installer, no driver packaging, no AI
  userspace, no desktop integration.

Everything below is the gap between "a kernel that boots" and "a product."

---

## 2. Kernel: two tracks, A/B bootable

### 2.1 The command line nobody documents
Getting Sky1 to boot reliably required discovering (by trial, board bricking,
and serial‑console archaeology) this base cmdline:

```
acpi=force arm-smmu-v3.disable_bypass=0 audit_backlog_limit=8192 \
clk_ignore_unused keep_bootcon panic=30 module_blacklist=typec_rts5453,rts5453
```

- `acpi=force` — the SoC is ACPI‑described; without it, drivers don't bind.
- `arm-smmu-v3.disable_bypass=0` — required or DMA‑capable peripherals fault.
- `clk_ignore_unused` — the SCMI/clock tree gates clocks the BSP still needs.
- `module_blacklist=typec_rts5453,rts5453` — the stock Type‑C PD driver wedges
  boot on this board.
- We learned the hard way that **`efi=noruntime` breaks `bootctl set-oneshot`**
  (EFI vars go read‑only), which silently disabled our rollback logic — so it
  had to be removed from the edge entry.

### 2.2 Sibling kernels without collisions
We ship **two** kernels from one image. The Yocto recipes had to be made
truly sibling‑installable (distinct `KERNEL_PACKAGE_NAME`, distinct work‑shared
dirs) so `do_patch` wouldn't collide, and so `/lib/modules/<KVER>` trees never
overwrite each other. LOCALVERSION (`-cix-sky1-lts` vs `-cix-sky1-next`) is the
only thing that keeps module `vermagic` from clashing.

### 2.3 Rebuilding a single out‑of‑tree module correctly
Several fixes required rebuilding *one* `.ko` with the exact `vermagic` of the
shipped kernel. `bitbake -c compile -f` does **not** reliably rebuild kernel
modules; the working incantation is:

```
bitbake -c compile_kernelmodules -f linux-cix-sky1-next
```

with `CONFIG_LOCALVERSION` set so the resulting module's `vermagic` matches the
deployed kernel exactly (MODVERSIONS is off, so vermagic is the *only* gate).

---

## 3. Driver fidelity — the long war

### 3.1 NPU (ArmChina Zhouyi) — brought up end to end
This was the single hardest subsystem, because it spans kernel **and** a closed
userspace, and the two must match exactly.

Kernel side (hand‑rolled fixes layered on the community driver):
- **IOVA / SMMU 32‑bit DMA constraint** — the NPU on MS‑R1 must be capped to a
  32‑bit bus or DMA faults (`2009-…msr1-smmu-32bit-dma-constraint`,
  `2014-…cap-iova-region-32bit-bus`).
- **ACPI `_STA` quirks** — the NPU cores are hidden ACPI devices; we had to
  force‑enable the `cixh4010` NPU child devices (`2007`, `2011`).
- **Power state** — force the device to D0 before probe (`2008`), and guard a
  null power‑domain core pointer (`2006`) that otherwise oopses.

Userspace side (the part with zero documentation):
- The NPU UMD (`libnoe`) version **must match** the kernel driver ABI. We
  burned multiple builds matching `libnoe` 0.5.0 / 0.6.0 / 3.1.2 to the running
  kernel.
- The vendor's `cix-noe-umd` `.deb` `postinst` **fails on modern Python**
  (built for 3.x, breaks on the distro's newer interpreter). Fix: bypass the
  packaged maintainer script and `dpkg-deb -x` the payload directly, then wire
  `ld.so.conf.d` by hand.
- The Python bindings (`libnoe` / `NOE_Engine` wheels) are **ABI‑pinned to
  CPython 3.11**. The distro ships a newer Python, so we provision a
  **relocatable CPython 3.11 + `uv` venv** at `/opt/python3.11` purely for the
  NPU runtime.
- `NOE_Engine.py` as shipped has an ABI mismatch (`tuple indices…`); the
  working path is to import `EngineInfer` directly from the installed wheel.

Result: **automatic NPU embeddings in mnemos**, validated on metal with a real
`bge-small-zh-v1.5_256.cix` model (shipped with the distro, with tokenizer,
provenance, and ModelScope pull instructions).

### 3.2 Audio — made functional from "TODO"
The community kernel listed audio as non‑functional. We:
- Enabled HDMI/DP audio (`snd_soc_hdmi_codec` path) so the distro can claim
  full driver fidelity.
- Diagnosed and patched the **analog HDA reset probe failure**
  (`error -ENOENT: failed to get reset`): the `cix-ipbloq-hda` driver requested
  an *unnamed* reset while ACPI exposed it as `"hda"`. Fix:
  `2017-ALSA-hda-cix-ipbloq-Fix-ACPI-reset-clock-resource-name`. Both cards
  (`cix-ipbloq-hda` analog + `cix_sky1` HDMI/DP) now enumerate.

### 3.3 GPU / compute — honest limits, documented
- `panthor` (Mali‑G720) + full DRM stack comes up; `/dev/dri/renderD128` works.
- We evaluated the whole GPU compute matrix: llama.cpp Vulkan (`panvk`),
  rusticl OpenCL, CIX proprietary `libmali`, KRAID — and documented the real
  numbers (≈1.9 TFLOPS FP32 raw; no cooperative‑matrix).
- Critically, we learned that **desktop GL is software‑only (llvmpipe)** and
  Mesa here exposes **no X11 EGL platform** — a fact that later explained the
  screensaver failure (see §6).

### 3.4 Display / framebuffer
The Cadence/Trilin/Linlon display path needed HPD/replug hardening and an
fbdev‑restore fix to survive the desktop. This is the area the new CIX release
most improves (proper `linlondp` fbdev/KMS ops), which is why we're rebasing.

---

## 4. The installer — a distribution, not a tarball

- **Patched debootstrap / `gutsy` script** at build time to force `dbus` into
  the base set (the desktop dead‑locks without it) and to make the real
  debootstrap run in `--mode thin` with an **embedded offline mirror**.
- **Post‑install hook pipeline** (`run-all.sh`) with required (fatal) Phase‑1
  hooks and best‑effort Phase‑2 hooks — networking is now a fatal hook so a
  box never boots half‑connected.
- **systemd‑boot menu** generated with three entries (stable / edge / rescue),
  **boot counting + 3‑try rollback** on edge, and a clean rescue target that
  blacklists NPU/GPU/VPU/display for recovery.
- **Kernel manifest + integrity** (`kernel-manifest.py`) so the staged
  Image/modules/config can't silently drift from what was validated.
- **Diagnostic account that self‑destructs on first successful boot** — present
  for installer‑time rescue/telemetry, gone the moment the system boots
  cleanly, so no known credentials persist on a running appliance.
- A recurring failure mode — copying multi‑GB ISOs to macOS — was worked around
  with `dd` over SSH after `scp` repeatedly stalled past 2 GB.

---

## 5. On‑device AI userspace (independent of any kernel patch)

- Relocatable **Python 3.11 + `uv`** runtime for the NPU bindings.
- `mnemos-embedkit` staged with the NPU runtime; **embeddings run automatically**
  via `embedkit.Engine.auto()` (CPU/GPU/NPU selected at runtime).
- Shipped a real prebuilt `.cix` embedding model + offline tokenizer + a full
  **inference limits & capabilities matrix**, plus MODELSCOPE pull docs.
- Benchmarked embeddings on metal across CPU and GPU paths.

None of this depends on where the kernel patches come from — it is wholly our
work and is fully retained.

---

## 6. Desktop polish (the parts users actually see)

- **XFCE on LightDM** (the stock GDM/Wayland path black‑screens on Mali
  panthor). Curated session, branding, wallpapers, Plymouth theme.
- **The "no GL visuals" screensaver bug — a full root‑cause.** xscreensaver
  6.x *always* runs an EGL probe (`xscreensaver-gl-visual`) at blank time; on
  this board the probe fails (`eglGetDisplay failed`, no X11 EGL platform) and
  that failure **blocks the entire hack‑launch pipeline** — even 2‑D hacks
  never start. Fix shipped: (a) a `dpkg-divert`'d shim that reports the default
  X visual so gfx proceeds, and (b) removal of the GL hack packages so `random`
  can only ever pick a 2‑D hack. Verified: 7 distinct 2‑D hacks run, zero
  aborts.
- **Fuller desktop** added after an audit found the base `xubuntu-core` shipped
  with *no sound server, no removable‑media mounting, no network applet, no
  CJK/emoji fonts, and no archive/PDF/media apps* — all now included.
- **Boot experience**: the edge cmdline still carried debug flags
  (`loglevel=7 earlycon=efifb keep_bootcon`) from when we needed to *see* boot
  messages; switching to `quiet splash` + a correctly‑registered Plymouth
  `nclawzero` theme (the initramfs hook keys off the `default.plymouth`
  *alternative*, not `plymouthd.conf`) is the in‑progress polish.

---

## 7. Then CIX published an official patch set (2026‑06‑17)

Mid‑polish, CIX released `cixtech/cix-linux-main` — their own, authoritative
mainline patch set (v7.0 + v6.18 LTS), adding full Suspend‑to‑RAM, thermal IPA
+ GPU energy model, a proper `linlondp` fbdev/KMS path (the exact display
handoff we were chasing), a PCIe vendor driver, pinctrl ACPI, RTC, and BSP
serial.

**Why our prior work made this usable in an afternoon, not a month:**
- We already had the build pipeline, local kernel git mirrors, asset staging,
  and manifesting — so applying **all 76 official patches onto 7.0.12 via
  `git am --3way`** and cross‑compiling took ~1 hour.
- We had a **known‑good baseline** (our `7.0.12-cix-sky1-next`) to A/B against,
  and the hardware expertise to tell whether the official kernel actually fixes
  the boot handoff and STR — or regresses NPU/audio.
- A handful of our hand‑rolled patches are now superseded (display fbdev, some
  STR guards); everything else — installer, desktop, AI stack, the *knowledge* —
  carries straight over. CIX shipped kernel patches; they did **not** ship a
  distro, an installer, an AI runtime, or a validation harness.

The official kernel is built as a **new sibling** (`7.0.12-cix-sky1-main`) so
the proven edge stays bootable as fallback while we validate. A forward **7.1
track** is scaffolded (patches need porting from v7.0 → v7.1; first conflict at
`drivers/clk/Kconfig`).

---

## 8. Effort, in numbers

| Dimension | Magnitude |
| --- | --- |
| Kernels maintained concurrently | 3 (LTS, NEXT, rescue) |
| Tracked ISO build iterations | ~r75 → r112 (and counting) |
| Curated/hand‑merged kernel patches (pre‑official) | ~40+ |
| Official CIX patches integrated (7.0.12, `--3way`) | 76 |
| Distinct driver subsystems brought to fidelity | NPU, GPU, HDMI+analog audio, display, net, USB |
| Userspace stacks stood up from scratch | NPU AI runtime (Py3.11/uv/.cix/mnemos) |
| Validation surface | full metal install, both variants, every boot |

The kernel patches are roughly **5%** of the total effort. The other 95% —
the distribution, the AI runtime, the installer, the desktop, and the hard‑won
hardware knowledge — is what turns "a kernel that boots" into a product, and is
exactly what let us absorb the official release the day after it dropped.
