# Handoff — cixmini installer end-to-end + distro-polish session

Date: 2026-05-02 evening → 2026-05-03 ~06:10 UTC. Unattended autonomous-mode work after first successful install on real MS-R1.

## TL;DR

- **First end-to-end install succeeded on real MS-R1 hardware earlier today.** Cixmini at 192.168.207.66 is up + ssh'able right now.
- **Display still dark on HDMI** — trilin_dpsub bridge↔monitor handoff bug, unchanged. simpledrm holds the GOP framebuffer if Cix DRM modules are blacklisted (now applied to installed-system bootloader). Real fix is Codex candidate-1 SOFT_RESET/SCRAMBLER_RESET pulse patch in trilin_dptx.c — not yet applied (needs kernel rebuild).
- **Installer source tree polished** through 9 commits this session — see "Source-tree changes shipped" below.
- **Latest USB on /dev/sda on ARGOS, md5 `58810ff0fbe28c76b5d2cb9e99bf9932`** — covers all fixes through commit `27e1b09`. Two more polish commits since (`1c90a78`, `526df8e`) — would warrant another reflash before the next test.
- **QEMU validation blocked** by Cix kernel's `__arm_smccc_smc` in `reboot_reason_init` initcall — SMC traps to undefined behavior on stock QEMU virt machine without ARM Trusted Firmware. Real-hardware test is the validation path.

## State of installed cixmini at session end

```
Linux cixmini 6.6.10-cix-build-cix-build-generic
PRETTY_NAME="nclawzero (cixmini) 2026.05"

systemctl is-system-running  → running
systemctl --failed           → (empty)
dpkg -l | iU/iF              → (empty after apt-fix-up + force-purge)

ip -br addr  enp1s0 UP at 192.168.207.66/24
             enp49s0 DOWN (no cable)
             wlp97s0 DOWN (no association)

Boot: 8.7s firmware + 2.8s loader + 0.8s kernel + 3.7s userspace = 16s total
gdm: active running (no HDMI yet, but service is up)
ssh: active running

Cix kernel modules loaded:
  - mali_kbase, memory_group_manager, protected_memory_allocator (GPU)
  - aipu (NPU)
  - amvx (VPU)
  - armcb_isp + csi_dma + csi_mipi_csi2 + csi_mipi_dphy_hw (camera)
  - cix_dsp_rproc (DSP — would loop without firmware on installer; works post-firmware-deploy)
  - rtl_btusb, rtl_wlan, wlan, wlan_cnss_core_pcie (WiFi/BT)
  (with .gnu.linkonce.this_module size mismatch warnings — see Outstanding Issues)

Branding deployed:
  - /etc/os-release: "nclawzero (cixmini) 2026.05"
  - /usr/share/nclawzero/branding/: gdm-background, wallpaper-default, ncz-icon (+ png), nclawzero-lockup
  - /etc/dconf/db/{gdm.d,local.d}/01-nclawzero*: GDM logo + login bg + user wallpaper
  - /etc/motd: branded ASCII box with operator-rotation hint
  - Plymouth theme: nclawzero (background.png + lockup.png + nclawzero.script)
  - Initrd has plymouth (etc/plymouth/, scripts/init-bottom/plymouth, etc.)

Default apps verified:
  - chromium 147.0.7727.137
  - claude-code 2.1.126
  - gnome-terminal, gnome-text-editor, eog, nautilus
  - podman 4.3.1 (no Quadlet — see shim hook)
  - openssh-server + sudo
  - All 33 cix-* userspace packages installed cleanly
```

## Source-tree changes shipped this session

| Commit | Subject |
|---|---|
| `c94abfa` | Minimum-prompt installer + clean kernel boot |
| `2be4c38` | nclawzero color theme for GRUB menu + d-i UI |
| `27e1b09` | Distillation of inline-repair learnings (70-bootloader single-line options, initrd, sudo, /etc/hosts, blacklist) |
| `1c90a78` | 20-desktop: skip gnome-initial-setup + dedupe XorgEnable |
| `eb75109` | New 32-quadlet-shim hook (.container → .service for podman 4.3) |
| `aec08b5` | 32-quadlet-shim v2: proper section extraction |
| `526df8e` | 32-quadlet-shim: skip empty Service= lines |

(plus the earlier `4e1fa03` console-fix that was the unblock)

## Resolved during this session

1. **systemd-boot loader entry parsing** — `bootctl` doesn't support backslash continuation in `.conf`. Multi-line `options` was silently dropping every cmdline tweak after the first line. **Fix**: 70-bootloader.sh writes single-line `options=`. (And the running cixmini was patched live.)

2. **Console order on installed system** — same bug we fixed for d-i. `console=tty0 console=ttyAMA0,115200` made `/dev/console=ttyAMA0` (serial). Userspace writes invisible on HDMI. **Fix**: swap order, tty0 last.

3. **Cix DRM blacklist for installed system** — Quick-unblock for the trilin handoff failure. simpledrm holds GOP, GNOME runs on llvmpipe (software). **Fix**: `module_blacklist=trilin_drm,trilin_dpsub,linlondp,linlondp_drv,cix_display` baked into 70-bootloader.

4. **/boot/config-$KVER missing** — Yocto kernel deploy doesn't ship the kconfig the way Debian's linux-image debs do, and initramfs-tools needs it to choose a compression. **Fix**: `zcat /proc/config.gz > /boot/config-$KVER` in 70-bootloader before `update-initramfs`.

5. **No initrd for our kernel** — Plymouth handover needs one. **Fix**: 70-bootloader runs `update-initramfs -c -k $KVER`, copies result to ESP, references it from loader entry.

6. **sudo missing** — Default Debian base doesn't include sudo. Without it, ncz operator can't elevate even though they're in the sudo group. **Fix**: 35-ssh.sh installs sudo alongside openssh-server.

7. **/etc/hosts hostname self-resolution** — Prevents "unable to resolve host" warnings on every sudo invocation. **Fix**: 50-brand.sh appends `127.0.1.1 <hostname>` after preseed picks the hostname.

8. **gnome-initial-setup wizard intercepts first login** — d-i already prompted for locale/user/password; running the wizard again is friction. **Fix**: 20-desktop.sh writes `/etc/skel/.config/gnome-initial-setup-done` so every new user skips it.

9. **Duplicate `XorgEnable=false` lines** — cix-debian-misc.postinst's known sed bug appends without checking. **Fix**: 20-desktop.sh dedupes via awk at end of hook.

10. **Quadlet missing on Bookworm's podman 4.3** — `/etc/containers/systemd/*.container` files silently don't generate any units. **Fix**: New 32-quadlet-shim.sh hook translates them to native systemd .service units (validated end-to-end on cixmini.66 — service starts cleanly, podman run with all flags, container image pulls, port binds).

## Outstanding issues for next iterations

### 1. trilin_dpsub bridge↔monitor handoff (HDMI dark)

EDID = 0 bytes on every DP connector despite link training succeeding. **Codex's candidate-1 patch** (pulse `TRILIN_DPTX_SOFT_RESET` and `TRILIN_DPTX_FORCE_SCRAMBLER_RESET` low after the post-training enable in `trilin_dptx.c:1694-1706`) is the most likely real fix. Requires Yocto kernel rebuild. See `codex-fb-deepdive-v2.md` for the source-cited 5 ranked candidates.

### 2. KERNEL_LOCALVERSION suffix doubling

Our `meta-cix/recipes-kernel/linux-cix-msr1_6.6.10.bb` sets `KERNEL_LOCALVERSION="-cix-build-generic"` but produces `uname -r = 6.6.10-cix-build-cix-build-generic` (doubled). Cix's prebuilt out-of-tree module debs install to `/lib/modules/6.6.10-cix-build-generic/extra/` — wrong path, modules invisible to udev. **Workaround**: 25-cix-proprietary.sh bridges by copying .ko's into our actual KVER tree + depmod. Real fix: figure out why Yocto's plain-kernel.bbclass doubles the suffix and stop it.

### 3. Out-of-tree module ABI warnings

`module aipu / mali_kbase: .gnu.linkonce.this_module section size must match the kernel's built struct module size at run time` — soft incompatibility from different module-struct-size between Cix's reference build and our Yocto build. Modules load anyway but may misbehave. Same root cause as #2 — fixing the recipe so KVER matches Cix's exactly resolves both.

### 4. systemd-boot in iU/iF after install

Postinst tries to register an EFI boot variable and fails. Apt reports `1 not upgraded`. Cosmetic but ugly. Real fix: `dpkg-divert` the postinst's NVRAM-write or use `systemd-boot-update.service`-only flow.

### 5. `cix-debian-misc.postinst` shell bug

`[: too many arguments` — already known. We force-purge it at end of 25-cix-proprietary. Cix-side bug to file upstream.

### 6. Quadlet → podman-4.4+ proper fix

Our 32-quadlet-shim is a stop-gap for Bookworm's old podman 4.3.1. Long-term: move to Trixie (podman 4.x newer), or build podman 4.7+ as a deb in our distro layer. The shim becomes a no-op when proper Quadlet is available.

### 7. Demo container's `/usr/local/bin/zeroclaw` doesn't exist

`ghcr.io/perlowja/nclawzero-demo@sha256:0d5306ff…` was pulled cleanly but its entrypoint binary is missing. Container exits 127 immediately. Agent-side image bug, not installer bug. Worth filing against the zeroclaw build pipeline.

## What's where

- **Latest USB** at `/dev/sda` on ARGOS, md5 `58810ff0fbe28c76b5d2cb9e99bf9932` (commit `27e1b09`)
- **Latest source** on `gitlab.com/nclawzero/cix-installer:main` HEAD `526df8e` — would need a fresh build+flash to capture commits 1c90a78/eb75109/aec08b5/526df8e
- **Running cixmini** at 192.168.207.66, ssh as `root` (key-based) or `ncz` with password `Gumbo@Kona1b` + `sudo`
- **Codex deep-dive reports**: `/Users/jperlow/cix-installer/codex-fb-deepdive-v2.md` and `codex-di-flow.md`
- **Earlier learnings**: `/Users/jperlow/cix-installer/LEARNINGS-FIRST-INSTALL.md`

## Next concrete steps for the user

1. **Fresh reflash** — ssh into ARGOS, `cd ~/cix-installer-build/cix-installer`, `git pull && make iso && ./build/qemu-test.sh build/nclawzero-installer-cixmini-2026.05.02.iso`. Or just dd the rebuilt ISO onto the Lexar in /dev/sda. Pulls in commits c94abfa→526df8e.

2. **Re-install MS-R1** with the new USB. Validation:
   - GRUB menu shows nclawzero ASCII banner + cyan/black theme
   - d-i UI (newt) renders in dark navy + cyan
   - d-i prompts for HOSTNAME + USERNAME+PASSWORD + ROOT-PASSWORD only
   - Install completes, reboots into installed system
   - Plymouth splash on first boot (tested via initrd contents)
   - GDM login on HDMI (only after candidate-1 SOFT_RESET kernel patch lands; today still dark)
   - `lsmod | grep mali_kbase` shows it loaded with no ABI warning (only after KERNEL_LOCALVERSION fix lands; today loads with warning)
   - Agent .service units present (`systemctl status zeroclaw openclaw hermes`)

3. **Apply Codex candidate-1 patch** to trilin_dptx.c, kernel rebuild via Yocto on ARGOS, redeploy. That unblocks HDMI on real hardware.

4. **Fix meta-cix recipe KERNEL_LOCALVERSION** so `uname -r = 6.6.10-cix-build-generic` matches Cix's prebuilt module debs. Eliminates KVER bridge + ABI warnings.

5. **systemd-boot postinst divert** — clean up the iU/iF state.

6. Optional polish: GNOME shell extensions baked in, custom GTK theme, NetworkManager defaults, default desktop apps association tuning.

---

## Vendor BSP survey results (added late session)

Surveyed Cix CP8180 ecosystem (Minisforum, Framework Desktop / MetaComputing, Radxa Orion O6, Orange Pi 6 Plus, Sky1-Linux community). Full report at `codex-vendor-bsp-survey.md`. **Headline: Sky1-Linux community tree (`github.com/Sky1-Linux/linux-sky1`) is the single highest-leverage source — 140 patches with direct fixes for our exact bugs.**

### Key direct hits

- **Patch 0127** *"prevents stale stream count from causing DP TX misconfiguration (black screen) after USB-C replug"* — identical to our HDMI handoff bug
- **Patch 0102** `cix_dsp_rproc` ACPI boot + `memremap(MEMREMAP_WB)` for the 0xcde00000 DSP firmware load area — exact match to our `rsv mem err: 0xCDE08000` dmesg
- **Patches 0022, 0052, 0097, 0117, 0124, 0126, 0130, 0134** — full DPTX/linlon-dp fix family
- **`build-debs.sh` LOCALVERSION pattern** — solves the doubled-suffix bug cleanly
- **TF-A in `cixtech/cix_opensource__arm-trusted-firmware`** branch `cix_p1_k6.6_2025q3_tfa_open_dev` has both Cix Sky1 SiP plat AND `plat/qemu/` — buildable with `PLAT=qemu` to unblock QEMU validation

### Plymouth — no vendor solver

No Cix-platform vendor publicly fixes Plymouth-on-Cix. Sky1-Linux sidesteps by not running cix-debian-misc.postinst (uses their own image-build flow). Cleanest path for us: dpkg-divert or otherwise neutralize the Cix-vendor init-rename, then update-initramfs works as on any Debian arm64 + Plymouth splash works.

### Multi-disk awareness already shipped

`preseed.cfg` `partman/early_command` was updated tonight (commit `7c6af62`) to detect disk count and only auto-target when single-disk (Minisforum). Multi-disk machines (Framework dual NVMe, Radxa Orion O6 dual NVMe, Orange Pi 6 Plus NVMe+microSD) get d-i's "Select disk to partition" prompt with `init_automatically_partition` pre-selected to "use entire disk".

### Next session game plan (tasks #12-#15 in the tracker)

1. Cherry-pick Sky1-Linux DPTX + DSP patches as SRC_URI files in `meta-cix/recipes-kernel/linux-cix-msr1/`. Yocto rebake on ARGOS. Validates on real cixmini — HDMI should light up.
2. Build TF-A `PLAT=qemu` → unblock QEMU validation (full installer test loops finally possible)
3. Strip cix-debian-misc init-rename → Plymouth splash works → re-enable initrd in 70-bootloader
4. Adopt Sky1 LOCALVERSION recipe → eliminates KVER bridge AND mali_kbase/aipu ABI warnings
