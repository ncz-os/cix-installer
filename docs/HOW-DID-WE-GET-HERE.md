# How Did We Get Here — NCZ / Reinhardt 26.6 on Cix Sky1

### A schedule post-mortem: why a June 1 release shipped on June 19

> The honest story of the 18-day slip. Short version: we were building a
> product on top of **two simultaneously-moving targets** — an upstream
> kernel that went from 6.6 → 6.18 → 7.0 → (and a 7.1 we're now porting)
> during the release window, and a **vendor (CIX) userspace that was itself
> a moving target** with no stable ABI, undocumented quirks, and a factory
> BIOS bug. Neither was under our control, and both changed *after* we'd
> already validated against the prior version.
>
> This document is for anyone asking "what took so long?" It is written so
> the level of effort, and *why* each delay was unavoidable, is legible to
> someone who wasn't in the room. Deep technical detail lives in
> `ENGINEERING-EFFORT.md`; this is the timeline and the root causes.

---

## 1. The one-paragraph answer

We committed to June 1 assuming the kernel was a fixed foundation we'd build
a distribution on. It wasn't. We actually **shipped working images in early
May** — Reinhardt r74 (6.18.26-cix-sky1-lts + 7.0.3-cix-sky1-next) and the
first Magnetar r78 (7.0.3-next, no LTS sibling) — but those early builds did
**not** have inference-validated GPU, had only **partially-working NPU**, and
**no working VPU**. "Done" meant "boots and installs," not "full driver
fidelity." Closing that fidelity gap required tracking a kernel that
**iterated almost daily through May and June**: the 7.0.x edge advanced
continuously, a **7.1-rc cycle ran in parallel**, and **CIX was actively
submitting patches the whole time** — so effectively every day was a new
target. Each iteration changed driver behavior we'd just validated. The two
external catalysts that let us call it done — CIX's **official** patch set
(June 17) and **Mesa 26.1.3** (June 18) — only existed at the very end. We
shipped within ~48 hours of the last one landing. The slip wasn't idle time;
it was chasing a target that moved every day.

---

## 2. The kernel chase (the spine of the slip)

We did not change kernels because we wanted to. Each move was **forced** by
a hardware-fidelity gap that the older tree couldn't close.

| Date (2026) | Kernel(s) shipped | Reality at that point |
|---|---|---|
| (start) | **6.6.10-cix-build-generic** (vendor) | Cix factory kernel. Drivers shipped as **prebuilt `.ko` locked to one vermagic**. Audio non-functional, NPU couldn't run inference, display black-screened. Closed, unrebuildable. |
| **May 3** | **6.18.14/.26-cix-sky1-lts** (Sky1-Linux fork) | Forced move to get **in-tree drivers** (panthor GPU, armchina-npu, amvx VPU, drm/cix). Side effect: **every vendor 6.6 `.ko` became vermagic-incompatible** — we ripped all `cix-*-driver` debs out and re-derived each subsystem on in-tree drivers. |
| **~May 5 (r74)** | **6.18.26-lts (default) + 7.0.3-cix-sky1-next (BETA)** | **First Reinhardt.** NEXT 7.0.3 logged SCMI transition warnings on MS-R1 BIOS. *GPU not inference-validated, NPU partial, VPU not working* (see §2.1). |
| **~May 7–8 (r78)** | **7.0.3-cix-sky1-next — NEXT-only, no LTS sibling** | **First Magnetar** (headless server SKU). Single-kernel — a known single-point-of-failure we later reversed. |
| **May → June** | **7.0.3 → … → 7.0.12-cix-sky1-next** (edge) | The fork's "next" branch advanced through the **entire 7.0.x series, iterating almost daily**. Tracked for STR, thermal, display — but beta and shifting constantly, so it could only ever be the *edge* slot. |
| **June (parallel)** | **7.1-rc track** | A 7.1 release-candidate cycle ran *concurrently* with 7.0.x and **also iterated**. Shipped as honest `[BETA]` because its **SCMI mailbox transport times out on MS-R1 firmware** (FAST channel 0 never returns a TX-ack IRQ; firmware wants the CIXHA001:06 doorbell channel 8). Self-rolls-back to LTS. |
| **June 17** | **7.0.12-cix-sky1-main** (official CIX) | CIX published `cixtech/cix-linux-main` — 76 authoritative patches (STR, thermal/energy model, proper `linlondp` display, PCIe, pinctrl ACPI, RTC). Rebased via `git am --3way`. The real foundation we'd been waiting on **the entire window**. |
| (now) | **7.1 track** | Porting v7.0 → v7.1 (first conflict at `drivers/clk/Kconfig`); SCMI-on-7.1 still open. The target is *still* moving. |

### 2.1 What actually worked at the first ship (early May) vs now

The early-May images **installed and booted** — that's what let us call a
milestone — but driver fidelity was far from complete. This is the honest
gap that the rest of the slip was spent closing:

| Subsystem | First ship (r74/r78, early May) | Now (7.0.12-main, June 19) |
|---|---|---|
| Boot / install | ✅ working | ✅ working |
| CPU / memory | ✅ working | ✅ working |
| NPU (Zhouyi) | ⚠️ **partial** — probed but inference flaky/unvalidated | ✅ ResNet50 ~1.9k img/s, embeddings in mnemos |
| GPU (Mali-G720) | ⚠️ display only — **compute/inference not validated** | ✅ Vulkan+OpenCL, llama.cpp/LiteRT/clpeak validated (Mesa 26.1.3) |
| VPU (amvx) | ❌ **not working** | ⚠️/✅ in-tree amvx present on the new tree |
| Audio | ⚠️ partial (HDMI only) | ✅ analog HDA + HDMI/DP |
| SCMI / power | ⚠️ warnings on NEXT | ✅ on LTS/main; ❌ still times out on 7.1 |

### Why tracking 7.x specifically cost so much time

1. **A major-version bump is not a point upgrade.** Going 6.18 → 7.0 changed
   in-kernel APIs the out-of-tree NPU driver depends on. Examples we had to
   fix by hand on the new tree: `pm_runtime_put` became `void` (broke the
   driver's error-checking assignments), `IRQF_ONESHOT` on a non-threaded
   IRQ started throwing a probe-time `WARN`, and the ACPI override path
   needed re-prepending. Each was a silent break discovered only by building
   and booting on metal.

2. **The NPU module is out-of-tree and must be rebuilt per kernel.** It
   isn't in the official patch set, so every kernel rev = recompile the
   `armchina_npu.ko` against the exact new headers/vermagic, re-sign,
   re-prepend the ACPI SSDT, re-stage the initrd. On the new `main` kernel
   this meant standing up a **DKMS-style rebuild** because the prebuilt
   module no longer matched.

3. **Cross-compilation kept failing.** The cross toolchain choked on the
   7.x tree (`Makefile:2110 Error 2`), so we **abandoned cross-compile and
   built natively on the Sky1 board itself**, inside a Podman container we
   then had to back up as a quadlet so a re-image wouldn't lose the build
   environment. That pivot was necessary but cost days.

4. **Two (really three) kernels in parallel.** To never ship a regression,
   we maintain LTS (6.18, default), NEXT/edge (7.0.x beta), and a rescue
   target — all A/B-bootable from one systemd-boot menu with **3-try
   automatic rollback**. Sibling kernels can't share `vermagic` or module
   trees, so the Yocto recipes had to be made truly sibling-installable.
   Every kernel move multiplied across all of these.

5. **Boot-handoff archaeology.** Sky1 needs an undocumented command line
   (`acpi=force arm-smmu-v3.disable_bypass=0 clk_ignore_unused …`); we also
   learned the hard way that `efi=noruntime` silently disables
   `bootctl set-oneshot` (read-only EFI vars), which killed our rollback
   logic. Every kernel rev had to be re-validated against this.

6. **The ESP is tiny.** Staging multiple kernels + initrds repeatedly filled
   the 512 MB / 600 MB EFI partition, forcing initramfs minimization
   (`MODULES=dep`) and old-kernel purges before each test could even boot.

---

## 3. CIX as a moving target (the second axis)

The kernel was only half of it. The **CIX userspace was equally unstable**,
and crucially had **no documentation** for any of this — every issue below
was diagnosed from first principles on the board.

- **NPU UMD has no stable ABI.** The userspace driver (`libnoe`) must match
  the kernel driver exactly. We burned builds matching `libnoe`
  0.5.0 / 0.6.0 / 3.1.2 before pinning **`cix-noe-umd 2.0.2`** as the only
  version that submits jobs successfully on our in-tree KMD. UMD 1.1.1 and
  3.1.2 both fail. There was no way to know this except to try each one.

- **NPU Python bindings are ABI-locked to CPython 3.11/3.12.** The distro
  ships Python 3.14, on which `import libnoe` simply fails. We had to
  provision a **relocatable CPython 3.11 + `uv` venv** purely for the NPU
  runtime. The vendor `NOE_Engine.py` also ships with an ABI mismatch
  (`tuple indices…`) and had to be bypassed.

- **The factory BIOS is buggy.** Minisforum's MS-R1 BIOS **omits the
  `_HID="CIXH4010"` on the NPU cores**, so they never enumerate — the NPU
  is invisible to Linux out of the box. Fix: inject a corrected ACPI **SSDT
  override** via an initramfs CPIO prepend. This is a hardware/firmware bug
  we had to work around in software, per kernel, forever.

- **SMMU 32-bit DMA constraint.** Without forcing `bus_dma_limit=0xc0000000`
  / `dma_mask=32`, the IOMMU hands the NPU 35-bit addresses its 32-bit bus
  truncates → SMMU faults on every access. Undocumented; found by fault
  analysis.

- **Vendor `.deb` postinst scripts actively break the system.** Example:
  `cix-debian-misc` unconditionally renames initramfs scripts that **aren't
  in the package**, deleting Debian's working `/init` and producing a 221 MB
  initrd that kernel-panics into an **infinite reboot loop**. We extract,
  patch out the bad block, and repack every affected vendor deb.

- **GPU/Mesa churn, three layers deep.**
  - Vendor `cix-mesa 24.0.4` + proprietary `libmali`/`libOpenCL` are built
    for the closed kernel driver and **don't work with panthor** — disabled.
  - Stock distro Mesa **26.0.3** panvk **couldn't run GPU compute**
    (`VK_ERROR_OUT_OF_DEVICE_MEMORY`, a 16-entry buffer cap) and shipped
    **no GPU OpenCL at all** (rusticl package removed).
  - The fix — **Mesa 26.1.3** — was released **June 18**. We
    built it from source on the board, A/B-validated +20% prefill / +13%
    decode, and restored GPU OpenCL. We were chasing a dependency that
    literally did not exist until the day we shipped.

- **The official CIX patch set arrived on June 17.** The authoritative
  display/STR/thermal fixes we'd been hand-rolling for weeks only became
  available 2 days before ship. Because our pipeline, mirrors, and A/B
  harness were already built, we absorbed all 76 patches in ~an afternoon —
  but we could not have absorbed them any earlier than they existed.

---

## 4. What we were NOT doing during the slip

It's worth being explicit: the 18 days were not spent on the kernel alone.
In parallel we built the **95% that CIX never shipped** — and that work is
done and carries across every kernel rev:

- A **graphical installer**: patched debootstrap, embedded offline mirror,
  fatal/best-effort post-install hook pipeline, a self-destructing
  diagnostic account, and rescue/recovery paths.
- The **A/B boot program**: 3 kernels, boot-counting, automatic rollback,
  integrity-manifested kernel staging.
- The **on-device AI runtime**: NPU embeddings in `mnemos`, a real shipped
  `.cix` model + tokenizer, embedkit auto-selection across CPU/NPU/GPU,
  llama.cpp/MNN/whisper.cpp wired up, and the full **CPU/NPU/GPU/VPU
  performance + routing guide** (`AI-ML-STACK.md`).
- **Desktop fidelity**: XFCE/LightDM (the stock GDM/Wayland path
  black-screens on Mali), a full root-cause + fix for the xscreensaver EGL
  bug, branding, Plymouth, fonts, audio, networking.
- **~r75 → r112+ ISO build iterations**, each validated on real metal.

---

## 5. Lessons / what we'd change

1. **Never commit a ship date against a pre-1.0 vendor kernel you don't
   control.** The June 1 date assumed a stable foundation; the foundation
   moved three times. Future dates should be quoted **relative to an upstream
   freeze**, not the calendar.
2. **Treat the vendor userspace as untrusted and unversioned.** Pin exact
   UMD/wheel versions, and budget time for ABI archaeology on every bump.
3. **The distro is the asset, not the kernel.** Kernel patches were ~5% of
   the effort. Because the other 95% (installer, AI runtime, A/B program,
   hardware knowledge) was solid, we absorbed the official kernel **the day
   after it dropped** and the Mesa fix **the day it released**. That
   resilience is exactly what the schedule bought.
4. **Build natively, mirror everything, automate staging.** The native
   build + local git mirrors + manifested asset pipeline are what turned
   "major kernel rebase" from a multi-week event into an afternoon.

---

## 6. Bottom line

The product wasn't late because of inefficiency — it was late because it was
the **first full Linux distribution for this silicon**, built on a kernel
and a vendor stack that were *both still being written* during the release
window. We shipped within 48 hours of the final external dependency (the
official CIX kernel on June 17 and Mesa 26.1.3 on June 18) becoming
available. Everything we built to survive that churn — the A/B kernel
program, the native build pipeline, the version-pinned AI runtime, the
installer — is now the foundation that makes the *next* release a matter of
days, not months.
