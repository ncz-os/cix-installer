# Cix MS-R1 Framebuffer/DP Black-Screen Deep Dive

Date: 2026-05-02

## Status

This report is not a completed root-cause analysis against the ARGOS kernel
source. The required source tree on ARGOS could not be read from this Codex
environment.

Blocking facts:

- `ssh -o BatchMode=yes -o ConnectTimeout=10 jasonperlow@192.168.207.22 ...`
  failed before authentication with `ssh: connect to host 192.168.207.22 port
  22: Operation not permitted`.
- Local shell network/DNS is also blocked; `curl` to GitLab failed with
  `Could not resolve host: gitlab.com`.
- Computer Use access to Terminal, Screen Sharing, and Chrome was denied, so I
  could not use an already-running desktop session to reach ARGOS.
- No local mirror of the kernel source was found under `/Users/jperlow`; only
  the local Yocto recipe tree was available.

Because of that, I cannot honestly provide the requested file:line citations
from:

`/home/jasonperlow/yocto-tmp/build-cixmini-tmp/work/cixmini-nclawzero-linux/linux-cix-msr1/6.6.10+cix/build/source/`

Per the grounding rule, I am not claiming HDCP presence/absence, EDID behavior,
module parameters, DT properties, stream programming, colorimetry, or PHY
sequencing from source that I could not inspect.

## Local Evidence Actually Read

The local recipe identifies the intended downstream source and exact revision:

- `/Users/jperlow/cixmini-msr1-rebake/meta-cix/recipes-kernel/linux-cix-msr1/linux-cix-msr1_6.6.10.bb:38`
  sets `KBRANCH = "a0fb5/5cf6e/cix_p1_mg_dev"`.
- `/Users/jperlow/cixmini-msr1-rebake/meta-cix/recipes-kernel/linux-cix-msr1/linux-cix-msr1_6.6.10.bb:43`
  pins `SRCREV = "cc636a675f7926846f04d31524c17b591955acca"`.
- `/Users/jperlow/cixmini-msr1-rebake/meta-cix/recipes-kernel/linux-cix-msr1/linux-cix-msr1_6.6.10.bb:45`
  to `:47` fetches
  `github.com/minisforum-cix-p1-repo/cix_opensource__linux.git` plus
  `usb-rootfs.cfg`.
- `/Users/jperlow/cixmini-msr1-rebake/meta-cix/recipes-kernel/linux-cix-msr1/linux-cix-msr1_6.6.10.bb:50`
  to `:52` says this recipe carries no kernel-side patches diverging from the
  Minisforum tree.
- `/Users/jperlow/cixmini-msr1-rebake/meta-cix/recipes-kernel/linux-cix-msr1/linux-cix-msr1_6.6.10.bb:58`
  to `:62` says MS-R1 boot hardware discovery uses ACPI loaded by UEFI; DTBs
  are built for diagnostics/fallback, and `KERNEL_DEVICETREE` is informational
  for `cixmini`.

The only local display-relevant config fragment says:

- `/Users/jperlow/cixmini-msr1-rebake/meta-cix/recipes-kernel/linux-cix-msr1/files/usb-rootfs.cfg:41`
  to `:49` documents a prior symptom where `fbcon` switches from `efifb` to the
  Cix DRM driver framebuffer and the screen goes dark even though getty is
  active.
- `/Users/jperlow/cixmini-msr1-rebake/meta-cix/recipes-kernel/linux-cix-msr1/files/usb-rootfs.cfg:50`
  sets `CONFIG_FRAMEBUFFER_CONSOLE_DEFERRED_TAKEOVER=y`.

Those local files do not contain the trilin DP encoder implementation, EDID
code, HDCP hooks, module parameters, or Cix DP DT nodes requested for this
investigation.

## Ranked Source-Derived Root Causes

None. The ARGOS source files required to cite source-backed root causes were
not accessible.

Any ranked "root cause" below would be a guess and would violate the requested
grounding rules.

## Ranked Hypotheses To Test After Source Access

These are not confirmed by source inspection. They are listed only to preserve
forward progress once ARGOS/source access is restored.

### 1. Hypothesis: DP stream attribute / MSA programming mismatch after training

Why it still fits the known facts:

- Link training succeeds.
- The framebuffer scans out.
- The monitor remains black after the bridge takes over.
- A mismatch in stream attributes after successful training can leave the sink
  with valid link state but unusable video.

Source inspection required before claiming:

- `drivers/gpu/drm/cix/dptx/*`
- Encoder enable path, especially functions matching names observed in public
  Cix logs such as `trilin_dp_pm_prepare` and the stream enable path.
- Register writes after link training, especially MSA, color depth, pixel
  encoding, lane count, TU size, synchronous/asynchronous clock mode, and main
  stream enable order.

Concrete fix to try only after confirming in source:

```diff
--- a/drivers/gpu/drm/cix/dptx/...
+++ b/drivers/gpu/drm/cix/dptx/...
@@
- /* current stream format */
+ /* Force conservative DP stream format for MS-R1 bring-up */
+ bpc = 8;
+ color_format = RGB_444;
+ colorspace = DRM_MODE_COLORIMETRY_DEFAULT;
```

Next-boot test if a module parameter exists after inspection:

```text
trilin_dpsub.force_bpc=8 trilin_dpsub.force_rgb=1
```

No such parameters were confirmed because the module source could not be read.

### 2. Hypothesis: HDCP/content-protection gating video after stream-on

Why it still fits the known facts:

- `cix-hdcp2` being present in the image was part of the prompt context.
- A content-protection path can black video while link training and modeset
  appear successful.

Source inspection required before claiming:

- Search the actual ARGOS source for `hdcp`, `hdcp2`, `content_protection`,
  `DRM_MODE_CONTENT_PROTECTION`, and any secure monitor/TEE calls in the
  `trilin_dpsub` enable path.
- Check whether HDCP is enabled by default, by DT property, by ACPI property,
  or only by userspace request.

Concrete fix to try only after confirming in source:

```diff
--- a/drivers/gpu/drm/cix/dptx/...
+++ b/drivers/gpu/drm/cix/dptx/...
@@
- hdcp_enable(...);
+ /* Bring-up: never block clear video on HDCP authentication. */
+ if (false)
+     hdcp_enable(...);
```

Next-boot test if a parameter/property exists after inspection:

```text
trilin_dpsub.hdcp=0
```

No such parameter was confirmed because the module source could not be read.

### 3. Hypothesis: EDID/mode fallback or connector mode validation ignores sink limits

Why it still fits the known facts:

- The monitor accepts GOP framebuffer before handoff.
- The downstream driver may select or force a mode/encoding that GOP did not
  use.
- A black screen with active scanout can result from a sink-rejected timing or
  a bad fallback path.

Source inspection required before claiming:

- Connector `get_modes`, EDID read path, AUX/DDC transactions, mode validation,
  and fallback mode handling in the actual `trilin_dpsub` source.
- Confirm whether `drm_add_edid_modes()` is used and whether fallback modes are
  added on EDID failure.

Concrete fix to try only after confirming in source:

```diff
--- a/drivers/gpu/drm/cix/dptx/...
+++ b/drivers/gpu/drm/cix/dptx/...
@@
- /* current fallback */
+ /* Bring-up fallback: force 1024x768@60 RGB 8bpc if EDID is bad/missing. */
+ drm_mode_probed_add(connector, drm_cvt_mode(dev, 1024, 768, 60, false, false, false));
```

Next-boot test if supported by DRM command line:

```text
video=DP-1:1024x768@60e
```

Connector name must be confirmed from `/sys/class/drm` or source; I could not
verify it from ARGOS.

## Top Recommendation

Restore source access and rerun the inspection against ARGOS. The first command
set should be:

```bash
ssh jasonperlow@192.168.207.22 '
set -eu
SRC=/home/jasonperlow/yocto-tmp/build-cixmini-tmp/work/cixmini-nclawzero-linux/linux-cix-msr1/6.6.10+cix/build/source
cd "$SRC"
find drivers/gpu/drm -type f \( -iname "*trilin*" -o -iname "*dptx*" -o -iname "*dpsub*" -o -iname "*linlon*" \) -print
grep -RIn --include="*.c" --include="*.h" --include="*.dts" --include="*.dtsi" \
  -e stream_on -e encoder_enable -e hdcp -e hdcp2 -e content_protection \
  -e colorimetry -e colorspace -e YCBCR -e ycbcr -e edid -e drm_add_edid_modes \
  -e module_param -e "main link training" \
  drivers/gpu/drm arch/arm64/boot/dts/cix
'
```

Then produce the requested ranked report from actual lines in those files. Until
that succeeds, the only source-backed statement I can make is that the local
Yocto recipe pins Minisforum's downstream 6.6.10 source and carries no local
kernel patches beyond the config fragment cited above.

## Next-Boot Items Actually Supported By Read Evidence

Source-confirmed DP module parameters: none discovered; source not readable.

DT properties to try: none discovered; source not readable, and the local recipe
says MS-R1 uses ACPI for boot hardware discovery while `KERNEL_DEVICETREE` is
informational for `cixmini`.

Kernel config already present locally:

```text
CONFIG_FRAMEBUFFER_CONSOLE_DEFERRED_TAKEOVER=y
```

That config is cited in `usb-rootfs.cfg:50`, but it does not address the bridge-
to-monitor failure described in the prompt; it only preserves the firmware
framebuffer until a DRM client takes over.
