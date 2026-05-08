# Next public release — Reinhardt/Magnetar netinstall ISO

**Locked 2026-05-07** by operator. This file is the canonical definition of what ships next.

## What

A **single netinstall ISO** that installs either NCZ Reinhardt (Desktop) or NCZ Magnetar (Server) on Cix Sky1 hardware, picked at boot from a GRUB menu. Replaces all prior ISO variants (full / thin / slim).

| Property | Value |
|---|---|
| Distribution name | NCZ "Reinhardt" / "Magnetar" netinstall |
| ISO size | ~380 MB target (sub-500 MB hard ceiling) |
| Kernel | linux-cix-sky1-next 7.0.3 only — no LTS sibling shipped |
| Userspace | Ubuntu 25.10 questing arm64, debootstrap'd from `ports.ubuntu.com/ubuntu-ports` at install time |
| Cix proprietary userspace | `cix-noe-umd 2.0.2` + `libnoe` from `archive.cixtech.com` (post-bootstrap apt) |
| Boot flow | systemd-boot 7.0.3 NEXT default; auto-rollback after 3 wedges |
| GRUB chooser | Install Reinhardt — Desktop (XFCE) / Install Magnetar — Server / SAFE rescue |
| Variant capture | `ncz_variant=desktop\|server` on kernel cmdline -> `BUILD_VARIANT` sidecar -> `48-magnetar-variant.sh` reads it at first boot |
| embedkit | Baked: `/opt/ncz/embed-venv/` + mnemos-embedkit + libnoe binding + llama-cpp-python + `bge-small-zh-v1.5` GGUF + `.cix` (when available); installed via `post-install/47-embedkit.sh` |
| MNEMOS posture | NCZ is the exemplar way to run MNEMOS; first-boot has the NPU adapter live for `embedkit.Engine.auto()` |

## Why netinstall (not full or thin)

- **Public-OSS friendly**: anyone with internet can install; no Cix-internal infra dependency for the base bootstrap.
- **GitHub-distributable**: ~380 MB fits as a release artifact; full 9 GB does not.
- **Resilient**: canonical Ubuntu mirror tier is globally mirrored; cixtech archive is only consulted post-bootstrap for the Cix-specific layer.
- **Wired-Ethernet required at install** (`d-i netcfg` doesn't do wireless cleanly). Documented in the GRUB menu line text.

## What's NOT in this release

- No LTS 6.18.26 kernel sibling. NEXT 7.0.3 only. LTS rescue ships as a separate advanced ISO if/when needed.
- No embedded `questing-mirror/` (~2.2 GB).
- No `rootfs.tar.zst` (~3-4 GB).
- No bge-small-zh-v1.5 `.cix` model unless the build host has the cixtech ai_model_hub_25_Q3 LFS pull pre-staged (task #99). Without the .cix, the kit's NPU adapter sees no model and falls back to CPU; operator can drop the .cix into `/opt/ncz/models/` post-install. Documented in the release notes.
- No `--mode full` / `--mode thin` artifacts published. The build script keeps `full` mode internally (operator-only path) for development; only `netinstall` ships publicly.

## Implementation status

- ✅ GRUB Reinhardt/Magnetar chooser in `build/build-iso-di.sh` (commit `cfe7832`).
- ✅ `late.sh` ncz_variant capture (commit `cfe7832`).
- ✅ `47-embedkit.sh` post-install hook (commit `cfd93e4`).
- ✅ `assets/models/bge-small-zh-v1.5-q8_0.gguf` bundled (commit `cfd93e4`).
- 🟡 `--mode netinstall` flag in `build/build-iso-di.sh` — Codex agent `a1b77fdf37e4591ac` actively implementing per `docs/R76-NETINSTALL-DESIGN.md`.
- 🟡 mnemos-embedkit adapter implementations (cpu-llamacpp, cix-npu, gpu-cuda, apple-mlx) — Codex implementing in `~/embedkit/` repo (`mnemos-os/mnemos-embedkit` on GitHub). Additional adapters planned: AMD ROCm/XDNA, Intel OpenVINO (CPU/iGPU/NPU), Qualcomm Hexagon — vendor-agnostic, runtime auto-detect.

## When ready to ship

1. Codex lands `--mode netinstall` in `build/build-iso-di.sh`.
2. Bake on ARGOS: `bash build/build-iso-di.sh --mode netinstall --version 26.5-r77-Reinhardt-Magnetar --variant desktop ...`.
3. Verify ISO is < 500 MB.
4. Smoke-test boot in QEMU + flash to USB + boot on `.66`.
5. Verify post-install hooks land (especially `47-embedkit.sh` + the variant chooser writing `BUILD_VARIANT`).
6. Tag `v26.5-r77-Reinhardt-Magnetar` and push.
7. Upload ISO + sha256 to GitLab Release.
8. **Operator authorizes PRs** before any are fired.
9. PR sequence (drafts in `pr-drafts/`):
   - Sky1-Linux community announce — link the bench numbers + the ISO.
   - cixtech upstream — note PCIe-on-Orion-O6 follow-up if dmesg from zeldin (Sky1-Linux issue #29) lands actionable.
   - nclawzero/distro README pointer to v26.5-r77 release.
   - mnemos-embedkit adapter PRs (when Codex's adapter set is reviewed).

## What deleted r77 looks like in retrospect

The "first" r77 attempt (slim/full, baked at 19:02 UTC 2026-05-07 with sha `937f4176...`) was rolled back because the bake reused stale `iso-staging-di/` from r75-take10 and the new `cixmini/post-install/` tree never landed in the ISO. The `47-embedkit.sh` + `assets/models/` were absent at install time. Tag deleted. Release deleted. ISO deleted from ARGOS. Lesson: **netinstall mode forces a clean-staging path** because there's no rootfs to reuse — that's a feature, not just a size optimization.

## Cross-references

- `docs/R76-NETINSTALL-DESIGN.md` — full design.
- `docs/EMBEDKIT-DESIGN.md` — kit architecture (lives in mnemos-os/mnemos-embedkit).
- `RELEASE-NOTES-26.5-r77-Reinhardt-Magnetar.md` — release notes draft (will be revised when netinstall lands).
- `HANDOFF-r77-OPERATOR-RETURN.md` — handoff doc (updated post-pivot).
