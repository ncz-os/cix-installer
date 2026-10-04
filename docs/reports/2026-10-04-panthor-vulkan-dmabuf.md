# Panthor-mode gaps on O6N (2026-10-04)

Scope: item J.3 of the Cygnus 26.10 O6N findings. Kernel `7.2.9-sky1-ncz`,
Sky1. Evidence is read-only from O6N (the board was booted with
`sky1.gpu=vendor` during this pass; the Panthor boot below is `-1`).

## (a) No Vulkan on Panthor — fixed

### Root cause and evidence

- On the Panthor boot (`journalctl` boot `-1`, cmdline `sky1.gpu=mesa`), the
  Mali ICD is disabled by the switcher:
  `assets/gpu/ncz-gpu-switcher.sh:305` (`disable_file "$ICD_MALI"`) renames
  `/etc/vulkan/icd.d/mali.json` to `mali.json.disabled`.
- No Mesa ICD is installed to replace it: O6N `dpkg -l` has `libvulkan1` and
  `vulkan-tools` but `mesa-vulkan-drivers` is absent (`un <none>`), and
  `/usr/share/vulkan/icd.d/` does not exist. `apt-cache policy
  mesa-vulkan-drivers` on O6N: candidate `26.1.6-1` (Debian forky/main arm64),
  installable.
- The package is exactly the Panthor driver this repo intends to ship:
  `manifests/desktop.pkgs:168-176` lists `mesa-vulkan-drivers` and says in its
  own comment it "is what gives PANTHOR a Vulkan driver (panvk)".
- It was being removed after install by
  `post-install/47-llm-stack.sh` (arm64 branch, old line 87 loop), which purged
  `mesa-vulkan-drivers libvulkan-dev vulkan-validationlayers spirv-tools
  spirv-headers glslang-tools glslang-dev` on the premise that the Mali blob
  replaces Mesa Vulkan. That premise is wrong for a dual-stack image.
- O6N Mesa is `26.1.6-1`, which ships `panthor_dri.so` alongside
  `panfrost_dri.so`; PanVK is the panthor/CSF Vulkan driver and is the stack the
  repo's release history already documents. The vendor Mali ICD must stay
  disabled on the Panthor boot (it is), so Mesa's PanVK is the only option.

### Fix

- `post-install/47-llm-stack.sh`: the arm64 branch no longer purges
  `mesa-vulkan-drivers` (only the Vulkan dev/build packages), and idempotently
  installs `mesa-vulkan-drivers`. The Mali entry is unaffected because
  `ncz-gpu-env` pins `VK_DRIVER_FILES=/etc/vulkan/icd.d/mali.json` for it.
- `assets/gpu/ncz-gpu-status`: the status print now shows
  `vulkan ICDs   : (none)` instead of a blank line, and on a Panthor boot adds
  "no Vulkan on Panthor: install mesa-vulkan-drivers for the PanVK ICD". It is
  informational and never enters the `--require-hardware` failure path (a
  missing Vulkan device is not software rendering).

### Not proven here

Whether `vulkaninfo` enumerates the Mali-G720 through PanVK on O6N can only be
confirmed after the package is installed and the board rebooted into the
Panthor entry; that is the orchestrator's step.

### Regression test

`build/test-panthor-vulkan.sh` (in `make parity`): asserts the manifest ships
the ICD, the arm64 purge keeps it, the arm64 branch installs it, and the status
text is honest. It fails on the pre-fix tree and passes after.

## (b) `drmPrimeHandleToFD() ... err=22` — evidence only, no code change

### Evidence

- The errors appear only on the Panthor boot: they are written by the shell to
  `/home/mini/.local/state/singularity/singularity-desktop.log` and `.log.1`
  (boot `-1`), and in no Mali boot (`.log.2`/`.log.3`/`.log.4` have zero):
  `MESA: error: drmPrimeHandleToFD() failed (err=22)`,
  `Gdk-CRITICAL: Failed to download <w>x<h> dmabuf texture (format AB24:...)`,
  `GLib-CRITICAL: g_close(fd:22) failed with EBADF`.
- On that boot the panthor driver binds as `card1`/`renderD129` while the only
  connector and the scanout device are linlondp `card0`/`renderD128`
  (`/sys/class/drm/renderD128/device/driver -> linlondp`). `err=22` is `EINVAL`.
- The generated Panthor profile (`post-install/20-desktop.sh:634-687`, written
  to `/usr/local/bin/ncz-gpu-env`) sets `WLR_RENDER_DRM_DEVICE` to the panthor
  render node, `WLR_DRM_NO_MODIFIERS=1`, pins the Mesa EGL vendor, and disables
  the CIX WSI layer. It does not set any GTK/GSK dmabuf variable.

### Analysis

`drmPrimeHandleToFD()` returns `EINVAL` when the GEM handle is exported on a
DRM fd for a device other than the one that allocated the buffer. Sky1's split
between the panthor render-only GPU (`renderD129`) and the linlondp display /
scanout device (`renderD128`) is the classic wrong-render-node export: GTK/GSK
imports a dma-buf that came from the compositor or client, then downloads it and
calls `drmPrimeHandleToFD` on the wrong node; the failed export leaves GSK
closing a stale fd (`g_close(fd:22) EBADF`). Candidate mitigations are GTK-side
(`GDK_DISABLE=dmabuf` to take the non-dmabuf texture path, still on the GPU; or
`GSK_RENDERER=ngl`), not a GBM/render-node change. O6N ships GTK `4.22.4+ds-1`,
whose `libgtk-4.so.1` contains both the "Disable dmabuf support" flag
description and the runtime message "dmabuf support disabled via GDK_DISABLE
environment variable", confirming `GDK_DISABLE=dmabuf` is the supported knob.

### Why no code change

The failure is specific to the Panthor boot. O6N was running its Mali entry
during this pass, and the read-only constraint forbids rebooting it, so no env
change can be shown to remove the errors. Per the item, the evidence is reported
and the Panthor profile is left alone.

### Read-only reproduction for the orchestrator

On a Panthor boot, under the live session's `WAYLAND_DISPLAY`, run a throwaway
GTK4 client and capture stderr with and without `GDK_DISABLE=dmabuf`
(and separately `GSK_RENDERER=ngl`), confirming the renderer stays hardware
(`eglinfo`/`glxinfo` show the Mali/panthor renderer, not llvmpipe). Only if one
of them removes the errors while keeping hardware rendering should it be added
to the panthor branch of the generated `ncz-gpu-env` (`post-install/20-desktop.sh`,
around lines 634-687).
