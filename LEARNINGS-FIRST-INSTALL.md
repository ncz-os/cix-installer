# Learnings — first successful end-to-end install on MS-R1

Date: 2026-05-02 → 2026-05-03 ~05:50 UTC. Captured live via SSH after install completed and the cixmini booted into the installed nclawzero (HDMI was dark, but everything else worked — see "what worked", "what didn't").

## Summary

End-to-end install **succeeded** on MS-R1 hardware after ~30 source-tree iterations. Critical fixes already committed to source:

- depmod-generated modules.alias in d-i (`build-iso.sh` step 3.5)
- KERNEL_LOCALVERSION mismatch bridge in `25-cix-proprietary.sh`
- Cix DRM/audio/DSP/BT module blacklist in d-i kernel cmdline
- single `console=tty0` in d-i cmdline so `reopen-console` lands the UI on HDMI
- `anna/no_kernel_modules boolean true` preseed
- single-line `options` in systemd-boot loader entry (CRITICAL — backslash continuation silently drops the rest of the cmdline)
- `console=ttyAMA0,115200 console=tty0` (tty0 last) in installed-system loader entry

The MS-R1 booted into installed nclawzero, network up at 192.168.207.66, all Cix hardware drivers loaded (Mali GPU, NPU, VPU, ISP, CSI, WLAN, Bluetooth). Only HDMI is dark because of the trilin_dpsub bridge↔monitor handoff failure (separate Codex candidate-1 patch territory).

## State of installed system at 2026-05-02 ~22:50 PST

```
$ uname -a
Linux cixmini 6.6.10-cix-build-cix-build-generic #1 SMP PREEMPT Fri Mar 20 01:40:47 UTC 2026 aarch64 GNU/Linux

$ cat /etc/os-release
PRETTY_NAME="nclawzero (cixmini) 2026.05"
NAME="nclawzero"
VERSION_ID="2026.05"

$ ls /lib/modules/
6.1.0-42-arm64                           # Debian's stock kernel — leftover, harmless
6.6.10-cix-build-cix-build-generic       # our Yocto kernel
6.6.10-cix-build-generic                 # cix-debs original install path

$ ls /lib/modules/6.6.10-cix-build-cix-build-generic/extra/
aipu.ko amvx.ko armcb_isp.ko csi_dma.ko csi_mipi_csi2.ko csi_mipi_dphy_hw.ko
csi_mipi_dphy_rx.ko csi_rcsu_hw.ko mali_kbase.ko memory_group_manager.ko
                                         # KVER bridge worked — every cix-* .ko reachable

$ lsmod | grep -iE 'mali|aipu|amvx|wlan|trilin|cix|simpledrm|csi|isp'
cix_dsp_rproc          24576  0          # blacklist not yet applied (this install pre-dates blacklist commit)
trilin_dpsub          106496  0          # blacklist not yet applied
snd_hda_cix_ipbloq     20480  0
mali_kbase / aipu / amvx / wlan / etc — loaded but with ABI warning (see below)

$ ip -br addr
enp1s0  UP   192.168.207.66/24    # DHCP reservation honored
enp49s0 DOWN                       # second onboard NIC, no cable
wlp97s0 DOWN                       # Realtek WLAN visible, not associated

$ ls /sys/class/drm/
card0..card4  +  card{0..4}-DP-{1..4} + card2-eDP-1 + Writeback-{1..10}
                                   # full Linlon-D60 DPU + 4 trilin DP outputs

$ for e in /sys/class/drm/card*-DP-*/edid; do echo "$e: $(stat -c%s $e) bytes"; done
.../card0-DP-1/edid: 0 bytes
.../card1-DP-2/edid: 0 bytes
.../card3-DP-3/edid: 0 bytes
.../card4-DP-4/edid: 0 bytes
                                   # NO EDID being read despite link training success per
                                   # MNEMOS — that's why monitor is dark
```

## What worked

1. **Yocto kernel rebuild path** — meta-cix `linux-cix-msr1_6.6.10.bb` + console-fb.cfg fragment + USB-rootfs fragment built a clean kernel with simpledrm + DRM_FBDEV_EMULATION + CONFIG_FB_EFI baked in. simpledrm is in `modules.builtin`. Kernel boots fine on MS-R1 hardware via systemd-boot from NVMe (no initrd needed for boot itself; NVMe driver built-in).

2. **d-i runtime kernel swap** — replacing `install.a64/vmlinuz` with `Image-cixmini.bin` and concatenating a cpio of `lib/modules/$KVER/` into `install.a64/initrd.gz` gave d-i a kernel that knows Cix Sky1. Cix peripherals enumerated cleanly; ethernet, USB, console all worked under d-i.

3. **depmod-generated modules.alias** — generating index files in build-iso.sh before packing the cpio was THE fix that let udev autoload USB ethernet, integrated NICs, USB-storage, etc. Without it: kernel sees device, emits modalias uevent, udev finds no match, no modprobe, no driver. Yocto's `make modules_install` only ships `modules.builtin` + `modules.order` — depmod must generate the rest at build time on our side.

4. **Cix DRM blacklist for d-i** — `module_blacklist=trilin_drm,trilin_dpsub,linlondp,linlondp_drv,cix_display` keeps simpledrm holding the GOP framebuffer for the duration of the installer. Without this, trilin_dpsub probes early in udev coldplug, calls `drm_aperture_remove_conflicting_framebuffers()` against simpledrm's region, simpledrm dies, fbcon falls off, HDMI goes dark before d-i UI ever shows.

5. **Cix DSP/audio/BT blacklist** — `cix_dsp_rproc,cix_sfh_rproc,snd_hda_cix_ipbloq,snd_soc_sky1_sound_card,snd_soc_rt5682s,snd_soc_cdns_i2s_mc,snd_soc_cdns_i2s_sc,btusb,rtk_btusb` killed the -517 EPROBE_DEFER retry loop that was hanging kernel boot at ~7.26s. These drivers all reference firmware/DT properties that aren't satisfied during d-i runtime; in the installed system with the proper Cix-firmware blobs in `/lib/firmware/` they should resolve.

6. **`console=tty0` ALONE in d-i cmdline** — Codex source-walked d-i's `reopen-console` and found that in preseed mode it picks ONE preferred console for the d-i UI based on console=… cmdline order. With `console=ttyAMA0,115200 console=tty0` BOTH listed, ttyAMA0 was being picked → d-i UI ran silently on the unconnected serial port → HDMI showed only blinking cursor for hours. Single `console=tty0` made d-i UI land on HDMI immediately.

7. **`anna/no_kernel_modules boolean true` preseed** — d-i looks for `nic-modules-<KVER>-di` and `kernel-image-<KVER>-di` udebs in the CD pool. Those exist for Debian's stock 6.1 kernel; they don't exist for our 6.6.10 Cix kernel. Without preseeding this, d-i halts at a "[!!] Load installer components from installation media — Continue without loading kernel modules?" dialog. Our cpio-injected modules + depmod-generated alias make this safe to skip.

8. **systemd-boot loader entry SINGLE-LINE options** — `bootctl` does NOT support backslash line-continuation in `.conf` files. With multi-line options, bootctl silently logs "Unknown line ..." to stderr and only the first line of options reaches the kernel. Every cmdline tweak we made on the installed system was being silently dropped. Single-line options is mandatory.

9. **KERNEL_LOCALVERSION bridge in 25-cix-proprietary.sh** — Cix's prebuilt out-of-tree module debs (cix-bt-driver, cix-csidma-driver, cix-gpu-driver, cix-isp-driver, cix-npu-driver, cix-vpu-driver, cix-wlan) all install their .ko's to `/lib/modules/6.6.10-cix-build-generic/extra/`, but our Yocto-rebuilt kernel's `uname -r` is `6.6.10-cix-build-cix-build-generic` (doubled suffix from a meta-cix recipe bug). The bridge copies the .ko's into our actual KVER tree and re-runs depmod. Without this: no Mali GPU, no NPU, no VPU, no camera, no WiFi, no Bluetooth on the installed system. With it: all of those load and report present in `/sys/class/`.

## What didn't / outstanding issues

### 1. trilin_dpsub bridge↔monitor handoff (HDMI dark on installed system)

EDID reads as 0 bytes on every DP connector. Per MNEMOS prior diagnosis, link training succeeds and pixels scan out, but the monitor refuses the signal. **Codex's candidate-1 patch** (`SOFT_RESET` + `FORCE_SCRAMBLER_RESET` pulsed low after the post-training enable in `trilin_dptx.c:1694-1706`) is the most likely real fix. Quick workaround applied: blacklist Cix DRM modules in installed-system bootloader so simpledrm holds the framebuffer and GNOME runs on llvmpipe (software rendering).

### 2. Out-of-tree module ABI warnings

```
[ udev-worker] module aipu:    .gnu.linkonce.this_module section size must match the kernel's built struct module size at run time
[ udev-worker] module mali_kbase: .gnu.linkonce.this_module section size must match the kernel's built struct module size at run time
```

The cix-* .ko's were built against Cix's reference kernel build with slightly different struct module size than our Yocto build. They load anyway but may misbehave in certain code paths. The KERNEL_LOCALVERSION suffix-doubling bug in our meta-cix recipe is the upstream of this — fixing the recipe so KVER matches Cix's exactly (`6.6.10-cix-build-generic`, not `cix-build-cix-build-generic`) would also resolve this. Until then, the cix-debs run with a soft incompatibility.

### 3. systemd-boot postinst still leaves package in iU/iF

`apt-get install systemd-boot` reports `1 not upgraded` and dpkg shows it as half-configured. The postinst's NVRAM-write step fails (efivarfs limitations) and the package stays "iU". `dpkg --configure -a` doesn't fix it. The actual binaries are deployed and bootloader works. Cosmetic but ugly. Proper fix: a dpkg trigger or a divert that skips the NVRAM-write step.

### 4. /boot/config-$KVER missing from kernel deploy

Our Yocto recipe doesn't `cp` the kconfig file to /boot when installing the kernel binary. initramfs-tools needs this file to build an initrd. **Now extracted at install-time** in 70-bootloader.sh (`zcat /proc/config.gz > /boot/config-$KVER`), but the cleaner fix is to teach meta-cix's linux-cix-msr1 recipe to ship the kconfig as part of `do_install` along with `Image` and `modules.tgz`.

### 5. /usr/share/initramfs-tools/init missing during initrd build

```
cp: cannot stat '/usr/share/initramfs-tools/init': No such file or directory
```

Reported during `update-initramfs -c` despite the package being installed. Likely cix-debian-misc's postinst renamed it (we saw similar "mv: cannot stat /usr/share/initramfs-tools/init" earlier in 25-cix-proprietary). The initrd built anyway (221 MB), but Plymouth handover may not work cleanly without a sane init script. Worth investigating cix-debian-misc's postinst for over-eager renames.

### 6. `cix-debian-misc` package in iF state (already known)

Its postinst has `[: too many arguments` shell bug. We already force-purge it at end of 25-cix-proprietary.sh. Confirmed still happens on real hardware (matches QEMU validation).

## Inline fixes applied to the running cixmini

| Fix | Effect | Source counterpart |
|---|---|---|
| Patched `/boot/efi/loader/entries/nclawzero.conf` to single-line options + tty0-last + Cix-DRM-blacklist | HDMI will work after next reboot | 70-bootloader.sh updated |
| Generated `/boot/config-$KVER` from `/proc/config.gz` | initramfs-tools can run | 70-bootloader.sh updated |
| Built `/boot/initrd.img-$KVER` (221 MB) + copied to ESP | Plymouth splash gets a chance to render | 70-bootloader.sh updated |
| Added `127.0.1.1 cixmini` to `/etc/hosts` | sudo no-resolve-host warning gone | 50-brand.sh updated |
| `apt install sudo` | ncz can elevate | 35-ssh.sh updated |
| `apt install initramfs-tools` | initrd generation works | 70-bootloader.sh installs it |

## Things to verify on the next install (after the changes ship)

1. Reboot brings up HDMI showing Plymouth → GDM
2. `nmcli dev status` shows both onboard NICs + WLAN
3. `lsmod | grep mali_kbase` shows it loaded with no ABI warnings (= KERNEL_LOCALVERSION fix lands too)
4. `dpkg -l | grep -E '^iU|^iF'` shows nothing (no half-configured packages)
5. `bootctl status` shows no "Unknown line" warnings
6. `getent hosts $(hostname)` resolves cleanly

## Things still to fix in source for a polished installer

1. **meta-cix `linux-cix-msr1_6.6.10.bb`**: stop suffix doubling — set KERNEL_LOCALVERSION such that `uname -r` reports exactly `6.6.10-cix-build-generic`. Eliminates KVER bridge + ABI warnings.
2. **meta-cix kernel recipe**: ship `kconfig` to `/boot/config-${PV}` in `do_install` so initramfs-tools doesn't need a workaround.
3. **trilin_dptx.c candidate-1 patch**: pulse `TRILIN_DPTX_SOFT_RESET` and `TRILIN_DPTX_FORCE_SCRAMBLER_RESET` low after the post-training enable. Removes the bridge-monitor compat issue at its root.
4. **systemd-boot iU/iF**: add a divert or systemd-boot-update.service tweak so postinst's NVRAM-write doesn't fail apt.
5. **cix-debian-misc postinst**: file an upstream bug with Cix to fix the `[: too many arguments` shell bug. We already force-purge it at end of 25-cix-proprietary.

## Codex outputs already on disk

- `/Users/jperlow/cix-installer/codex-fb-deepdive-v2.md` — 5 ranked candidates for trilin display issue
- `/Users/jperlow/cix-installer/codex-di-flow.md` — d-i startup flow walkthrough that found the console-selection bug

Both are source-cited, both are actionable, both should ship as part of the project docs.
