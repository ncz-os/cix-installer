# R130 — Next ISO Feature & Build Notes

Status: **open / accumulating** — do not mint until the 7.1.1 NCZ kernel is fully
validated (USB + display + DKMS). Tracking everything that must land in the next
("fat") r130 ISO. Living doc; add items as they surface, check them off as fixed.

Target: NCZ OS r130 for CIX Sky1 (arm64), d-i based, BTRFS default, 7.1.1 NCZ kernel.
Author: Jason Perlow. Created 2026-06-27.

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

---

## Kernel / DKMS gate (must be green before minting r130)
- **7.1.1 NCZ kernel** (this is an *NCZ* kernel — we built/patched it, not CIX):
  - USB ACPI reset patch (9007) added to the recipe; do_patch verified clean.
  - **DKMS** (cix-npu / cix-gpu / cix-vpu): in progress. ABI must bind to 7.1.1, not
    the 6.18.26 LTS. Root cause of mis-binding = shared SSTATE_DIR across build trees
    skipping the kernel's work-shared population; fix = isolated sstate tree
    (`build-cix-ncz71` + dedicated `sstate-cache-ncz71`). See MNEMOS mem_1782573631130.
  - **GPU = Panthor** (in-tree open Mali, `CONFIG_DRM_PANTHOR=m`), not the proprietary
    cix-gpu-kmd kbase path.
  - **VPU** cix-vpu-kmd: 7.1 API porting (strscpy/vmalloc.h/d_children/v4l2_fh)
    deferred.
- Open hardware symptoms to clear before mint: USB dead, magenta/purple display with
  non-functional GUI (mouse/keyboard unresponsive — suspected framebuffer-only, no
  live compositor). Headless boot + ethernet confirmed working on 7.1.1.

## Rescue / install hardening (carry-over)
- Rescue partition must ship a **full tool set** (dhcp client, editors, net tools) —
  prior rescue image lacked tools and DHCP, blocking recovery.
- **Auto IP / DHCP on boot** must work out of the box (failed in last build).
- Consider a **4 GB ESP** on next install to accommodate kernel development
  (multiple kernels + initrds).
