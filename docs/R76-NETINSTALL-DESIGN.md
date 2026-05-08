# R76 — Netinstall ISO design (Reinhardt + Magnetar selector)

**Status:** IMPLEMENTED in r78.
**Targets:** r75 task #60 (netinstall ISO ~500 MB) + #61 (BUILD_MODE flag) + a head/headless selector at install time so one ISO covers both SKUs.
**Strategic frame:** This is the bridge between r75's "ship-something-that-works-on-Sky1" forked-d-i path and a future Subiquity-based unified arm64/x86 installer (gated on the upstream Casper-on-Sky1 fix — see `docs/UPSTREAM-CASPER-SKY1-PANIC.md`).

---

## What the netinstall ISO becomes

Single ISO, ~380 MB, bootable from USB. GRUB menu offers:

```
Install NCZ Reinhardt — Desktop (XFCE)
Install NCZ Magnetar — Server (headless)
[ Advanced options ] (rescue, expert mode, etc.)
```

Operator picks one. d-i runs `debootstrap` from `ports.ubuntu.com/ubuntu-ports` (canonical Ubuntu arm64 archive — public, well-mirrored, doesn't depend on cixtech archive availability for the base bootstrap). Cix-specific packages get added post-bootstrap by `25-cix-ppa.sh` against `archive.cixtech.com`.

Both menu entries route through the **same** post-install pipeline. The only difference is a kernel cmdline `ncz_variant=desktop|server` that propagates through to `/usr/local/lib/cix-installer/BUILD_VARIANT`, which `48-magnetar-variant.sh` reads at first boot to apply (or skip) the headless toggle.

## Why canonical mirrors, not our own

- Public-OSS friendly: anyone with internet can install. No Cix-internal infrastructure dependency.
- Github-distributable: matches r75 task #60 framing of a netinstall ISO that lives on the public release page.
- Doesn't depend on `archive.cixtech.com` uptime for the base bootstrap; cixtech archive is only consulted post-bootstrap by `25-cix-ppa.sh` for the Cix-specific layer (cix-noe-umd, sky1 firmware, etc).
- Resilient: the canonical Ubuntu mirror tier is mirrored globally; rate-limits are generous; HTTPS-default.

A `--variant fleet` opt-in (separate from `--variant {desktop|server}`) could later target our ARGOS-hosted apt at `192.168.207.22:8081` for fleet-internal deploys, but that's not the public-OSS path.

## Single kernel: 7.0.3 NEXT only

Per operator direction (2026-05-06): netinstall ships **only** linux-cix-sky1-next 7.0.3 (or whatever the current NEXT minor is at bake time). Reasoning:

- Kernel 7.x is the strategic forward path; the NEXT/LTS dual-ship was a transitional safety net.
- LTS-as-fallback was driven by SCMI freezes that have since been documented as non-fatal warnings on most MS-R1 BIOS revisions. Empirically the rollback never fired on the .66 reference deploy.
- Saves ~170 MB of ISO budget (image + modules cpio).
- Sky1-Linux community is investing in 7.x patches; LTS 6.18.x is frozen.

For operators who want LTS as an emergency rollback, ship a separate `*-rescue` or LTS-only ISO variant — small ISO, advanced-users-only. Not in the default netinstall path.

The boot-counting auto-rollback machinery (cixmini-next+3-0.conf) STAYS — if NEXT wedges three times, systemd-boot drops the entry. With no LTS sibling to fall back to, the rescue path is "boot from another USB to recover" which is acceptable for the cohort that picks netinstall.

## ISO size budget (NEXT-only)

| Component | Size |
|---|---|
| bookworm d-i busybox initrd + vmlinuz (substrate, until casper-on-Sky1 fix) | ~80 MB |
| Sky1 NEXT kernel (Image + modules cpio) | ~170 MB |
| sky1-firmware + NPU SSDT cpio | ~10 MB |
| post-install hooks + assets/cix-py + assets/branding | ~50 MB |
| bookworm `pool/main/d/` udebs (subset for d-i) | ~30 MB |
| EFI bootloader + grub.cfg + isolinux | ~10 MB |
| ISO metadata, padding | ~30 MB |
| **Total target** | **~380 MB** |

## Pipeline changes

### `build/build-iso-di.sh`

New `--mode {full|thin|netinstall}` flag (sibling to `--variant`):

| Mode | rootfs.tar.zst | resolute-mirror | r40 debootstrap stub | Single kernel | Size |
|---|---|---|---|---|---|
| `full` | yes | yes | yes (bypasses real debootstrap) | LTS+NEXT | 9.3 GB |
| `thin` | no | yes | no — real debootstrap reads embedded mirror | LTS+NEXT | ~5 GB |
| `netinstall` | no | no | no — real debootstrap reads ports.ubuntu.com | NEXT only | ~380 MB |

The `--variant` flag stays orthogonal:
- For all modes: the GRUB chooser writes `ncz_variant=desktop|server` at install time.
- `--variant` writes the bake-time default `BUILD_VARIANT` sidecar for direct/non-chooser boots. Default for the canonical netinstall ISO is "desktop" so a no-pick boot lands at Reinhardt.

### `preseed/preseed-ubuntu.cfg`

Add mirror configuration:

```
d-i mirror/protocol string http
d-i mirror/http/hostname string ports.ubuntu.com
d-i mirror/http/directory string /ubuntu-ports
d-i mirror/http/proxy string
d-i mirror/http/suite string resolute
d-i mirror/country string manual
```

Ubuntu pinned to current resolute release. When resolute goes EOL we cut a fresh netinstall ISO bound to the next non-LTS or to the next LTS — ISO is per-release.

### `preseed/late.sh` (runs in d-i context, before chroot post-install)

Add early in the script, before the rootfs population path:

```bash
# r76 netinstall: capture install-time variant choice from kernel cmdline.
# GRUB menu for netinstall ships two entries differing only in
# ncz_variant=desktop|server. The choice writes the BUILD_VARIANT sidecar
# the existing 48-magnetar-variant.sh reads at first boot.
ncz_variant=$(sed -n 's/.*\(^\| \)ncz_variant=\([a-z]*\).*/\2/p' /proc/cmdline)
case "$ncz_variant" in
    desktop|server) ;;
    *) ncz_variant=desktop ;;   # default if cmdline absent (full/thin path)
esac
mkdir -p /target/usr/local/lib/cix-installer
echo "$ncz_variant" > /target/usr/local/lib/cix-installer/BUILD_VARIANT
echo "[late.sh] BUILD_VARIANT = $ncz_variant (from kernel cmdline)"
```

### `48-magnetar-variant.sh`

**Zero changes.** Already reads `/usr/local/lib/cix-installer/BUILD_VARIANT` and applies the headless toggle when value is `server`. The sidecar's *source* changes (kernel cmdline vs. `--variant` build flag) but the hook's contract is unchanged.

### GRUB cfg

The d-i GRUB menu uses the same two-entry Reinhardt/Magnetar chooser in all modes. In netinstall mode, the menu text adds "wired link required" and the installer kernel is NEXT only:

```
menuentry "Install NCZ Reinhardt — Desktop (XFCE)" {
    set gfxpayload=keep
    linux  /install.a64/vmlinuz auto=true priority=critical \
           preseed/file=/cdrom/cixmini/preseed.cfg \
           ncz_variant=desktop \
           console=tty0 console=ttyAMA0,115200 ---
    initrd /install.a64/initrd.gz
}
menuentry "Install NCZ Magnetar — Server (headless)" {
    set gfxpayload=keep
    linux  /install.a64/vmlinuz auto=true priority=critical \
           preseed/file=/cdrom/cixmini/preseed.cfg \
           ncz_variant=server \
           console=tty0 console=ttyAMA0,115200 ---
    initrd /install.a64/initrd.gz
}
menuentry "Rescue / Advanced" {
    # existing rescue path
}
```

The menu emission gets a conditional in `build-iso-di.sh` for netinstall text/kernel details, but the chooser contract stays the same across modes.

## Risk surface

1. **First real run of the trixie debootstrap-udeb graft.** The `r40 stub` shipped with `full` mode bypassed debootstrap. Netinstall is the first end-to-end test of trixie's `debootstrap-udeb 1.0.141` + `libzstd1-udeb` + `liblzma5-udeb` graft. Could surface bugs the offline path masked. Mitigation: bake + flash + test on `.66` after Magnetar smoke confirms; rollback path is "use the full or thin ISO" if netinstall flow breaks.

2. **`d-i netcfg` hard-fails on no network.** Netinstall *requires* a working link before debootstrap can run. `.66`'s wired ethernet on `enp1s0` is reliable; wireless support in d-i is patchy. Mitigation: GRUB menu line text says "wired link required"; netinstall ISO is documented as Ethernet-only. Wireless installers go through the `full` ISO.

3. **Cixtech archive at install time.** `25-cix-ppa.sh` adds `archive.cixtech.com`. Codex round-3 hardened the cix-noe-umd recovery path against archive flakiness — net result is a warn-not-fail with libnoe.so post-check. Acceptable.

4. **Mirror suite drift.** preseed pins `resolute`. When Ubuntu cuts the next non-LTS, we either cut a new netinstall ISO bound to it or accept that the resolute ISO becomes vintage. Standard Ubuntu install lifecycle.

5. **Kernel cmdline parsing.** The `sed` regex assumes `ncz_variant=` is space-delimited or at start. If GRUB injects extra params before/after, the regex still works. Tested mentally; should add a unit test (or shell test harness) when the patch lands.

## Phasing

1. **Phase 1 — netinstall + variant selector.** Land all the changes above on `r75-review` (or a new `r76-netinstall` branch). Bake + flash + install both Reinhardt and Magnetar from a single USB. Smoke-test each path on `.66`.
2. **Phase 2 — Re-evaluate `thin` mode utility.** With netinstall working, `thin` mode (5 GB, embedded mirror, no rootfs) may be redundant — `full` covers offline-air-gapped cases, `netinstall` covers everything else. Could drop `thin` from the `--mode` enum.
3. **Phase 3 — Casper-on-Sky1 upstream campaign.** Surface the underlying problem so Subiquity becomes viable on Sky1 (see `docs/UPSTREAM-CASPER-SKY1-PANIC.md`). When that lands, retire the bookworm-d-i fork entirely.

## Long-term destination

The netinstall ISO is the **bridge**, not the **destination**. The destination is **Subiquity-based unified arm64/x86 installer**:

- Subiquity is Ubuntu's modern installer (replaces d-i for server installs since Focal).
- It boots via casper (Ubuntu's live-system substrate; runs from squashfs).
- One installer, identical across arm64/x86, identical UX.
- Ships in every Ubuntu release; we'd just point at it.

The blocker: **casper kernel-panics on Sky1 USB boot** (r17-r24 of cix-installer documented this bootloader-independent — rEFInd, GRUB, systemd-boot all panic). Bookworm d-i busybox-init *doesn't* panic. So we forked.

When upstream casper boots cleanly on Sky1, the cix-installer fork retires. r76 netinstall + variant selector is the holdover until that day.

---

*Living doc. Update inline as Phase 1 patch lands.*
