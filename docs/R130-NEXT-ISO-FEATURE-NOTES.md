# R130 — Next ISO Feature & Build Notes

Status: **open / accumulating** — do not mint until the 7.1.2 NCZ kernel is fully
validated (USB + display + DKMS). Tracking everything that must land in the next
("fat") r130 ISO. Living doc; add items as they surface, check them off as fixed.

Target: NCZ OS r130 for CIX Sky1 (arm64), d-i based, BTRFS default, 7.1.2 NCZ kernel.
Author: Jason Perlow. Created 2026-06-27; updated 2026-06-27 (7.1.2 bump, self-build).

---

## Confirmed bugs to fix (field-reported)

### 1. apt sources — post-install bug (HIGH, field-confirmed by segabor on O6)
- Symptom: after install, apt only has the **ncz CDROM** sources; **no network apt
  sources** are configured. User cannot `apt install vim zsh` etc.
- Field workaround used: remove the ncz cdrom sources, add standard Ubuntu
  **resolute** sources by hand.
- Intended behavior: CDROM install is **intentional** (server edition ships as a
  CDROM install in the current ISO). But the post-install **must leave working
  network apt sources** pointing at **standard Ubuntu universe** (resolute) so users
  can install custom binaries out of the box.
- Fix: post-install orchestration writes a valid `/etc/apt/sources.list(.d)` with
  Ubuntu universe (resolute), and either removes or de-prioritizes the cdrom entry
  (keep cdrom as a fallback, network as primary). Verify `apt update` works on a
  fresh install with network.

### 2. Both editions → CDROM install (MED)
- Convert **both** editions (server + desktop) to a **CDROM install** so the slow
  Ubuntu **ports** servers don't wedge the install (current cause of install hangs).
- Rationale: ports mirrors are slow/flaky for arm64; bundling packages on the ISO
  removes the network dependency during install.

---

## Feature requests

### 3. Filesystem choice at install ("select your FS") (MED — requested by Tenkawa)
- Offer **ext4 / btrfs (current default) / zfs** at install time.
- **ZFS root**: d-i *can* support ZFS root (note: Ubuntu's subiquity **dropped** ZFS
  support a release or two ago; d-i is the path forward for it).
- Needs: `zfsutils` + ZFS kernel module/driver in both the **installer** environment
  and the **target**, plus d-i partitioning logic for a zfs root. ZFS root does
  **not** require RAID (single-disk zfs root is fine).
- Keep install logic minimal: this slots into the existing "choose disk" step as a
  filesystem selector.

### 4. Multi-chip targeting — stay on d-i (strategic)
- NCZ OS is intended to run on **all ARM** targets: CIX Sky1 now; Radxa **O6N** and a
  **Qualcomm** board "coming soon"; **Thor** arriving mid-July; aspirationally Apple
  **M-series** Macs.
- Decision: **stick with debian-installer (d-i)**, not subiquity/casper.
  - casper was broken when this project started; Ubuntu later fixed subiquity, but
    d-i is **simpler, straightforward, and multi-arch friendly** — least breaking
    install logic across many chips.
  - Already added a "choose disk" step; FS selector (#3) extends the same d-i flow.

### 5. Self-build / DIY distribution — recipe-first (strategic — requested by Tenkawa)
- There is a meaningful **DIY / from-source** contingent in the community who prefer
  building over consuming a prebuilt image.
- Decision: NCZ OS is a **Yocto-built distro**. The `cix-installer` repo
  (https://gitlab.com/ncz-os/cix-installer; mirror chain gitlab → argonas → github)
  ships **full self-build recipes**, and what we hand DIY users is the **full Yocto
  recipe / meta layer(s)** so a third party can reproduce the ISO from scratch.
- Action item for r130: ensure the published `cix-installer` tree has documented,
  runnable self-build instructions + the `meta-cix` layer(s) so an outside builder
  can `bitbake` the image themselves (open, reproducible, recipe-first).

---

## Kernel / DKMS gate (must be green before minting r130)
- **7.1.2 NCZ kernel** (this is an *NCZ* kernel — we built/patched it, not CIX;
  bumped 7.1.1 → 7.1.2 on 2026-06-27 for the latest stable point release):
  - USB ACPI reset patch (9007) added to the recipe; do_patch verified clean.
  - **7.1.2 bump VALIDATED** (build-cix-ncz71): all 74 CIX patches apply clean on
    v7.1.2 (do_patch EXIT 0); full kernel build EXIT 0; `kernel-abiversion=7.1.2-ncz`;
    work-shared populated. NPU module `aipu.ko vermagic=7.1.2-ncz` — binds the new ABI,
    not the 6.18.26 LTS. SRCREV 03e2778d. See MNEMOS mem_1782580428391.
  - **DKMS** (cix-npu / cix-gpu / cix-vpu): NPU green on 7.1.2. Root cause of earlier
    mis-binding was twofold — shared SSTATE_DIR across build trees (fixed with isolated
    `build-cix-ncz71` + dedicated `sstate-cache-ncz71`) AND the recipe's non-default
    `KERNEL_PACKAGE_NAME` forcing a WORKDIR-local kernel-source (fixed to default
    `KERNEL_PACKAGE_NAME="kernel"` so OOT modules use shared work-shared). See MNEMOS
    mem_1782573631130.
  - **GPU = Panthor** (in-tree open Mali, `CONFIG_DRM_PANTHOR=m`) as default, with the
    proprietary Mali **kbase** (cix-gpu-kmd) switchable as an optional DKMS — adopt the
    `sky1-gpu-switcher` / amazingfate toggle (`sky1.gpu=vendor|mesa`). kbase needs a
    7.1 API port (version_compat_defs.h) before it can ship.
  - **VPU** cix-vpu-kmd: 7.1 API porting (strscpy/vmalloc.h/d_children/v4l2_fh)
    pending, then package as DKMS.
- Open hardware symptoms to clear before mint: USB dead, magenta/purple display with
  non-functional GUI (mouse/keyboard unresponsive — suspected framebuffer-only, no
  live compositor). Headless boot + ethernet confirmed working on 7.1.1.

## Rescue / install hardening (carry-over)
- Rescue partition must ship a **full tool set** (dhcp client, editors, net tools) —
  prior rescue image lacked tools and DHCP, blocking recovery.
- **Auto IP / DHCP on boot** must work out of the box (failed in last build).
- Consider a **4 GB ESP** on next install to accommodate kernel development
  (multiple kernels + initrds).
