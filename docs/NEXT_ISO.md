# NEXT ISO — r139 staging tracker

> Living doc. **Do not bake a new ISO until the 7.1 kernel is fully fixed.**
> Track every change queued for r139 here; mint once, with the new kernel.

- **Last baked:** `r138` — `~/iso-releases/ncz-installer-cixmini-26.6-r138-combined.iso` (2026-06-25 20:19). **Not flashed.** Predates all fixes below.
- **Next:** `r139` — gated on the 7.1 kernel (see GATE). Build tree = `~/cix-installer-build/cix-installer` (authoritative; the public `argonas`/`codeberg` mirror is an unrelated, sanitized history — curate cherry-picks, never force-push the internal tree onto it).

---

## GATE — must be DONE before minting r139 (7.1 kernel)

The whole point of r139 is to ship the new **7.1 kernel**. Blockers (kernel/Yocto side, `meta-cix` `linux-cix-sky1-next_7.1.bb`):

- [ ] **USB** — `CONFIG_USB_CDNSP_SKY1=y` + reset-lookup `dev_id`-NULL fix (patch `0010-soc-cix-acpi-resource-lookup-resolve-dev_id-by-acpi`). `7.1.0-cix-sky1-next` Image built; needs **deploy + boot test** (keyboard/mouse enumerate).
- [ ] **Panthor GPU** — `DRM_PANTHOR=m` + Sky1 `gpu_core` clock/coherency (in squash patch). Needs boot test for `/dev/dri/*`.
- [ ] **DKMS** — `cix-npu-kmd` / `cix-vpu-kmd` retarget from LTS `virtual/kernel` to 7.1-next; rebuild + load.
- [ ] **Display color** — durable driver fix (resolve why `force_improc_rgb` is NULL at runtime) so we stop relying on the boot-time `devmem` poke of `IPS_CTRL` (clears `IPS_CTRL_YUV`).
- [ ] **Kernel handoff to installer** — stage final 7.1 `Image-cixmini.bin` + `modules-cixmini.tgz` + dtb into `assets/kernel/{stable,next}/`; bump `KVER_*` markers.

> cixmini (.66) is currently on **stable LTS 6.18.26** after the 2026-06-26 recovery (see MNEMOS `mem_1782513537405_9503a4`). `7.1.0-cix-sky1-next` is built but NOT safely deployed yet.

---

## STAGED for r139 — already committed to the build tree

Rescue / installer hardening (committed `b2ae4d8`, `179ee80`; rescue tarball regenerated 2026-06-26):

- [x] **Rescue auto-IP guaranteed.** Added real DHCP client (`isc-dhcp-client`/`dhclient`); split network bring-up into `ncz-rescue-net` (DHCP, carriers-only, time-capped) + **decoupled** `ncz-rescue-net-fallback` (static `192.168.207.66`, ordered `After=` not `Requires=` → always runs even if DHCP hangs/dies). Fixes "rescue partition came up with no IP and no DHCP client." (`b2ae4d8`)
- [x] **Rescue boot-repair toolset** added to `manifests/rescue.pkgs`: `kmod`, `initramfs-tools`, `cpio`, `lz4`, `device-tree-compiler`, `kpartx`, `binutils`, `picocom`. (`179ee80`)
- [x] **`build-rescue-rootfs.sh` hardened** — cleanup now unmounts EVERYTHING under `$CHROOT` (deepest-first) and **refuses `rm -rf` if any mount remains**. Prevents the chroot-teardown bug that wiped the build host ESP on 2026-06-26. (`179ee80`)
- [x] **ESP 1 GiB → 4 GiB** in `preseed/preseed-ubuntu.cfg` partman recipe — kernel-dev headroom (multiple `vmlinuz`+`initrd` + `.bak` sets on the ESP). Applies to NEW installs. (`179ee80`)
- [x] **`rescue-rootfs.tar.zst` regenerated** (2026-06-26, 190 MiB) with all of the above; verified contains `dhclient`/`depmod`/`dtc`/`picocom`/`readelf`/`update-initramfs` and both net units enabled.

---

## MINT PROCEDURE (when GATE is clear)

1. Stage final 7.1 kernel assets into `assets/kernel/*` (+ `KVER_*` markers).
2. If `manifests/rescue.pkgs` changed since last regen: `sudo bash build/build-rescue-rootfs.sh` (regenerates `assets/rescue/rescue-rootfs.tar.zst` — the ISO bake only STAGES the cached tarball, it does not rebuild it).
3. `bash build/build-iso-di.sh --variant <desktop|server|combined> --version r139 --bookworm-iso <PATH> --root <PATH> --output ~/iso-releases/ncz-installer-cixmini-26.6-r139-<variant>.iso`
4. Boot-test the ISO (KVM + a real cixmini flash) before announcing.

## OPEN / DON'T-FORGET

- [ ] Public-repo sync: cherry-pick the publishable subset (rescue auto-IP, ESP, builder hardening) onto `argonas`/`codeberg` `main` — sanitized, NOT a force-push of the internal tree.
- [ ] Reply to GitHub #32 with the Yocto 7.1-next tree + `kas` steps once packaged.
