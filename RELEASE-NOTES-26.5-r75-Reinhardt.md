# NCZ 26.5 "Reinhardt" — r75 build notes (UNATTENDED PREP, NOT YET INSTALL-VERIFIED)

**Build:** `ncz-installer-cixmini-26.5.r75-Reinhardt-thin.iso`
**Built:** 2026-05-06 16:15 UTC on ARGOS, by Claude in unattended mode
**Size:** 9.3 GB (was 3.9 GB on r74; questing mirror + rootfs.tar.zst dominate)
**SHA256:** `afaa4aaa636c53e4206dafb7bab370efdfa0d3a38deac7d752758b3660a3beda`
**Path on ARGOS:** `/home/jasonperlow/cix-installer-build/cix-installer/build/ncz-installer-cixmini-26.5.r75-Reinhardt-thin.iso`
**Status:** Bake completed, install + boot smoke NOT yet performed. Operator action required to flash + test.

---

## What landed (5 r75 patches — all in this ISO)

| Task | Item | Commit |
|---|---|---|
| K1 #66 | Pipeline support for `linux-headers` tarball asset (extract-kernel-headers.sh + build-iso-di.sh + 10-our-kernel.sh) — pipeline ready, asset production deferred to next sky1-linux-build kernel rebuild | `3664459` |
| K3 #113 | Default boot is now `cixmini-next` (Sky1 7.0.3 NEXT). LTS stays as fallback at sort-key 2-lts. Header comments + log lines refreshed. | `2f90c4b` |
| P1 #114 | Operator added to `render,video,audio,plugdev,input` groups via `usermod -aG`. Pattern matches 35-ssh.sh OPERATOR_USER discovery. Skips groups that don't yet exist. | `2f90c4b` |
| P2 #109 | MAC-derived hostname fallback: blank → `ncz-<MAC4hex>`. Ends Jeff Hunter's r74 wireless-only `Invalid hostname ""` failure. Skips wireless interfaces (random MACs). | `2f90c4b` |
| P3 #116 | cix-noe-umd Py3.13 compat. apt install attempts the deb; if iF state, replace `.postinst` with no-op stub, reconfigure, run `apt-get -f install` — C lib (which we use via ctypes) was already installed by data tar. | `2f90c4b` |
| P5 #115 | New `/usr/local/bin/ncz` CLI with `desktop {on|off|status}` subcommand. Frame for future `ncz install`, `ncz models pull`, `ncz agent` subcommands. Bash; smoke-checked at install time. | `706aced` |
| K4 (no task #) | Sky1-Linux Mesa 26 apt pin (preferences priority 1001) on 9 packages (mesa-vulkan-drivers + mesa-libgallium + libgl1-mesa-dri + libegl-mesa0 + libgbm1 + libglapi-mesa + libosmesa6 + libdisplay-info3 + libllvm21). Prevents apt-upgrade from regressing to questing's broken Mesa 25.2.8 panvk. | `a58164c` |
| P4 scope-1 #111 | `47-llm-stack.sh`: apt-installs the universal Vulkan + SPIR-V substrate (libvulkan-dev + glslang-tools + spirv-tools/headers + vulkan-tools + clinfo + glmark2). Best-effort with offline-mirror fallback. P4 scope-2 (llama.cpp Vulkan + npu_embed_v2.py + .cix model) deferred to `ncz install mnemos`. | `0fc98c0` |
| build-pipeline robustness | Replaced fragile `cd+pwd` absolute-path resolution with `readlink -f` in build-iso-di.sh. Two occurrences (lines 394, 531). The cd+pwd subshell was returning empty in nohup-detached mode, breaking `ar x` in unattended bakes. | `706aced` |

## What did NOT land in r75

| Task | Item | Why deferred |
|---|---|---|
| K2 #66 | n4hy v4 NPU patch into aipu module | Needs kernel rebuild; pipeline ready but build host (sky1-linux-build) hasn't been triggered yet. ~70-80 emb/sec NPU throughput target gated on this. |
| K5 verify | Dual-kernel rule (both 6.18 LTS + 7.0.3 NEXT shipped) | Verified by `cat assets/kernel/{lts,next}/KVER` showing both kernel versions present + the build log "NEXT kernel staged: 7.0.3-cix-sky1-next (62M image, 108M modules)". Default flipped per K3; LTS is fallback. ✓ |
| P4 scope-2 #98 | `ncz install mnemos` — embedder + cache + server + .cix model pull | Needs `ncz models pull` (P7 #99) to fetch from cixtech LFS. Out of scope for this unattended pass. |
| P6 #98 | MNEMOS server with NPU embedder backend at first boot | Same — depends on P4 scope-2 + P7. |
| P7 #99 | `ncz models pull` subcommand | New `ncz` CLI subcommand; frame is in place from P5, body deferred. |
| M1 #102 #108 | Magnetar Server build variant flag (`BUILD_VARIANT=server`) | New build mode; needs design pass — what gets stripped (XFCE/GNOME/browser) and what stays. Not autopilot-safe. |
| M2 #107 | Magnetar Pi image variant via pi-gen-nclawzero | Different repo; out of scope here. |
| M3 #118 | Magnetar Intel x86 deploy template | Different stack (Ubuntu Server 26.04 + OpenVINO); not in cix-installer. |
| F5 | Upstream Cix NPU embedder PR to mnemos-os/mnemos | Doc work; needs Codex review of the embedder pattern first. |

## ISO size note

r75 is 9.3 GB vs r74's 3.9 GB. The "thin" suffix is now misleading — needs a future pass to actually re-thin. The growth is the embedded questing-mirror (2.2 GB) + rootfs.tar.zst (3.0 GB) + bookworm pieces + dual kernels (~370 MB). Operator should flash to a 16 GB+ USB.

The `BUILD_MODE=thin|max` flag (#61) would address this with a real thin path (drop questing-mirror, install requires network).

## Next operator step

1. Pull ISO from ARGOS:
   ```
   scp argos:/home/jasonperlow/cix-installer-build/cix-installer/build/ncz-installer-cixmini-26.5.r75-Reinhardt-thin.iso .
   ```
2. Flash to USB (16 GB+):
   ```
   sudo dd if=ncz-installer-cixmini-26.5.r75-Reinhardt-thin.iso of=/dev/diskN bs=4m status=progress
   ```
3. Boot MS-R1 from the USB and verify:
   - K3: systemd-boot menu defaults to `cixmini-next [NEXT, default]`
   - P1: `groups mini` shows `render video audio plugdev` after first login
   - P2: hostname is `ncz-<MAC4hex>` if no operator-set value
   - P3: `dpkg -l cix-noe-umd` shows `ii` (not iF)
   - K4: `apt-cache policy mesa-vulkan-drivers` shows priority 1001 candidates
   - P4: `vulkaninfo --summary` lists Mali-G720 as a Vulkan device after first boot
   - P5: `ncz desktop status` works; `ncz desktop off` flips to multi-user.target on a test box

## Git state

- ARGOS commits 3664459..0fc98c0 on `main` of `~/cix-installer-build/cix-installer/`
- Pushed to ARGONAS bare `ssh://root@192.168.207.101/mnt/datapool/git/nclawzero/cix-installer.git`
- gitlab.com/nclawzero/cix-installer push deferred (auth token not on ARGOS — operator can sync via Mac when they return)

## Risks before declaring r75 ship-ready

- **Build size 9.3 GB** — flashable but not "thin." Real-thin pass needed before public release.
- **Install + boot not yet smoke-tested.** All patches passed `bash -n` syntactically; runtime behavior on real hardware unverified.
- **Codex review gate not yet run.** Per PRIMARY DIRECTIVE #4, should run `codex-companion adversarial-review --base 7ff5cdf` before promoting r75 from a build-server snapshot to a release-tag candidate.
- **K2 NPU n4hy v4 patch absent.** r75 ships with the same NPU performance envelope as r74 (no headers asset means no DKMS rebuild). The `~70-80 emb/sec` target is for r76+.
