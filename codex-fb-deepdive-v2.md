## Top 5 Root Cause Candidates

### Candidate 1: Post-training source/scrambler reset left asserted
- **Source citation**: /Users/jperlow/cix-installer/.kernel-source-readonly/drivers/cix-drm/dptx/trilin_dptx.c:1694, /Users/jperlow/cix-installer/.kernel-source-readonly/drivers/cix-drm/dptx/trilin_dptx.c:1701, /Users/jperlow/cix-installer/.kernel-source-readonly/drivers/cix-drm/dptx/trilin_dptx.c:1703, /Users/jperlow/cix-installer/.kernel-source-readonly/drivers/cix-drm/dptx/trilin_dptx.c:1706, /Users/jperlow/cix-installer/.kernel-source-readonly/drivers/cix-drm/dptx/trilin_dptx.c:1756, /Users/jperlow/cix-installer/.kernel-source-readonly/drivers/cix-drm/dptx/trilin_dptx_reg.h:44, /Users/jperlow/cix-installer/.kernel-source-readonly/drivers/cix-drm/dptx/trilin_dptx_reg.h:52
- **Why this matches**: Confirmed: after `trilin_dp_train()` succeeds, `trilin_dp_core_on()` writes `TRILIN_DPTX_SOFT_RESET = enable_sources`, `TRILIN_DPTX_SOURCE_ENABLE = enable_sources`, and `TRILIN_DPTX_FORCE_SCRAMBLER_RESET = enable_sources`, then logs main-link training success. Those reset-looking registers are not written back to zero until `trilin_dp_core_off()`. Hypothesis: if either register is level-sensitive rather than a write-one pulse/release bit, the DP link can train while the main-stream payload remains reset or its scrambler remains forced, producing exactly a trained link plus active scanout plus black monitor.
- **Concrete fix**: Patch-test by pulsing reset/scrambler reset low after the post-training enable sequence while leaving `SOURCE_ENABLE` high.

```diff
--- a/drivers/cix-drm/dptx/trilin_dptx.c
+++ b/drivers/cix-drm/dptx/trilin_dptx.c
@@ -1698,9 +1698,13 @@ static int trilin_dp_core_on(struct trilin_dp *dp, bool shallow)
 
        enable_sources |= 1;
        trilin_dp_write(dp, TRILIN_DPTX_SOFT_RESET, enable_sources);
+       usleep_range(10, 20);
+       trilin_dp_write(dp, TRILIN_DPTX_SOFT_RESET, 0);
        trilin_dp_write(dp, TRILIN_DPTX_SOURCE_ENABLE, enable_sources);
        trilin_dp_write(dp, TRILIN_DPTX_FORCE_SCRAMBLER_RESET, enable_sources);
+       usleep_range(10, 20);
+       trilin_dp_write(dp, TRILIN_DPTX_FORCE_SCRAMBLER_RESET, 0);
        trilin_dp_write(dp, TRILIN_DPTX_MST_ENABLE,
                        dp->link_config.mst_support);
```

- **How to test**: Boot one patched kernel with `drm.debug=0xff log_buf_len=16M video=DP-1:1024x768@60e`; verify the same training-success line appears, then read `register_info` or add temporary `drm_info()` reads for `SOFT_RESET`, `SOURCE_ENABLE`, `FORCE_SCRAMBLER_RESET`, and `VIDEO_STREAM_ENABLE`. Pass condition: reset registers read zero, source/video stream read one, and the monitor lights.

### Candidate 2: Hard-coded sync-polarity inversion and mode mutation
- **Source citation**: /Users/jperlow/cix-installer/.kernel-source-readonly/drivers/cix-drm/dptx/trilin_drm.c:45, /Users/jperlow/cix-installer/.kernel-source-readonly/drivers/cix-drm/dptx/trilin_drm.c:46, /Users/jperlow/cix-installer/.kernel-source-readonly/drivers/cix-drm/dptx/trilin_drm.c:650, /Users/jperlow/cix-installer/.kernel-source-readonly/drivers/cix-drm/dptx/trilin_drm.c:670, /Users/jperlow/cix-installer/.kernel-source-readonly/drivers/cix-drm/dptx/trilin_dptx.c:936, /Users/jperlow/cix-installer/.kernel-source-readonly/drivers/cix-drm/dptx/trilin_dptx.c:943
- **Why this matches**: Confirmed: `ADJUST_BACKPORCH` is compiled on and can alter `htotal` and pixel clock when horizontal back porch is below 12. `INVERSE_VSYNC` is also compiled on, but the code toggles both `DRM_MODE_FLAG_PVSYNC` and `DRM_MODE_FLAG_PHSYNC` for every adjusted mode. Confirmed: the DP main-stream polarity registers are programmed from `mode->flags`. Hypothesis: a sink can keep link lock while rejecting or blanking a stream whose MSA sync polarity/timing no longer matches the EDID mode it advertised.
- **Concrete fix**: Patch-test without the hard-coded timing and polarity mutation.

```diff
--- a/drivers/cix-drm/dptx/trilin_drm.c
+++ b/drivers/cix-drm/dptx/trilin_drm.c
@@ -42,8 +42,8 @@
 #include "trilin_dptx_reg.h"
 #include "trilin_dptx_audio.h"
 
-#define ADJUST_BACKPORCH 1
-#define INVERSE_VSYNC 1
+#define ADJUST_BACKPORCH 0
+#define INVERSE_VSYNC 0
 #define GET_EDID_RETRY_MAX 50
```

- **How to test**: Boot the patch with `drm.debug=0xff log_buf_len=16M video=DP-1:1024x768@60e`; confirm the adjusted mode flags are not inverted, link training still succeeds, and the monitor shows the forced mode. If this works, re-enable only `ADJUST_BACKPORCH` to isolate polarity from back-porch mutation.

### Candidate 3: DPU and DPTX pixel-per-cycle mismatch
- **Source citation**: /Users/jperlow/cix-installer/.kernel-source-readonly/drivers/cix-drm/dptx/trilin_dptx.c:2881, /Users/jperlow/cix-installer/.kernel-source-readonly/drivers/cix-drm/dptx/trilin_drm.c:787, /Users/jperlow/cix-installer/.kernel-source-readonly/drivers/cix-drm/dptx/trilin_dptx.c:973, /Users/jperlow/cix-installer/.kernel-source-readonly/drivers/cix-drm/linlon-dp/linlondp_dev.c:515, /Users/jperlow/cix-installer/.kernel-source-readonly/drivers/cix-drm/linlon-dp/linlondp_crtc.c:603, /Users/jperlow/cix-installer/.kernel-source-readonly/drivers/cix-drm/linlon-dp/linlondp_crtc.c:625, /Users/jperlow/cix-installer/.kernel-source-readonly/drivers/cix-drm/linlon-dp/hw/dp_component.c:1355
- **Why this matches**: Confirmed: both sides have separate `pixel_per_cycle` paths. DPTX reads a firmware property and otherwise auto-selects 2 pixels/clock for very high adjusted clocks; it writes `SRC0_USER_PIXEL_COUNT`. Linlon DPU also reads a firmware property, stores `pipeline->pixelPerClk`, divides CRTC horizontal timings/clock when ppc is 2, and writes timing-block PPC hardware. Hypothesis: on the ACPI MS-R1 path, a property on only one device, or divergent auto-selection from adjusted versus CRTC timing, can make the DPU emit one pixel packing while the DP TX expects another. Link training and DRM scanout would still look healthy, but the main stream would be malformed.
- **Concrete fix**: For a controlled boot, force both sides to one pixel/clock by firmware override if available: set ACPI `_DSD` or DT `pixel_per_cycle = <1>` consistently on the Linlon DPU pipeline device and the matching DPTX device. If firmware override is not practical, patch-test both drivers to force `pixel_per_cycle = 1` and boot a low-clock mode.

```diff
--- a/drivers/cix-drm/dptx/trilin_drm.c
+++ b/drivers/cix-drm/dptx/trilin_drm.c
@@ -787,7 +787,7 @@ static void trilin_dp_encoder_atomic_mode_set(struct drm_encoder *encoder,
-       if (dp->force_pixel_per_cycle)
+       if (false && dp->force_pixel_per_cycle)
                dp->pixel_per_cycle = dp->force_pixel_per_cycle;
        else if (adjusted_mode->clock > 600000 && adjusted_mode->clock < 1200000)
                dp->pixel_per_cycle = 2;
```

- **How to test**: Boot with `video=DP-1:1024x768@60e drm.debug=0xff log_buf_len=16M`; verify DPTX `SRC0_USER_PIXEL_COUNT` is one and Linlon timing-block PPC is the one-pixel setting. Pass condition: low-clock forced mode displays; failure condition: black remains with both sides forced to one pixel/clock.

### Candidate 4: RGB/YCbCr/VSC colorimetry mismatch
- **Source citation**: /Users/jperlow/cix-installer/.kernel-source-readonly/drivers/cix-drm/dptx/trilin_drm.c:702, /Users/jperlow/cix-installer/.kernel-source-readonly/drivers/cix-drm/dptx/trilin_drm.c:704, /Users/jperlow/cix-installer/.kernel-source-readonly/drivers/cix-drm/dptx/trilin_dptx.c:1088, /Users/jperlow/cix-installer/.kernel-source-readonly/drivers/cix-drm/dptx/trilin_dptx.c:1104, /Users/jperlow/cix-installer/.kernel-source-readonly/drivers/cix-drm/dptx/trilin_dptx.c:1141, /Users/jperlow/cix-installer/.kernel-source-readonly/drivers/cix-drm/dptx/trilin_dptx.c:1261, /Users/jperlow/cix-installer/.kernel-source-readonly/drivers/cix-drm/dptx/dptx_infoframe.c:199
- **Why this matches**: Confirmed: `trilin_dp_encoder_compute_config()` chooses the first EDID `display_info.color_formats` bit, maps it to RGB/YCbCr, and programs MISC/VSC state. Confirmed: YCbCr420 and BT.2020/SYCC/OPYCC paths use VSC SDP override, while RGB/YCbCr444/422 are represented through MISC0 format bits. Confirmed: AVI SDP is compiled off by `TRILIN_AVI_SDP_ENABLE`, so ordinary HDMI-style AVI infoframes are not sent. Hypothesis: if the driver chooses a YCbCr or VSC path while the upstream DPU scanout is RGB, some monitors can black-screen despite a valid link and CRTC.
- **Concrete fix**: Patch-test forced RGB 8bpc default colorimetry for the DP stream.

```diff
--- a/drivers/cix-drm/dptx/trilin_drm.c
+++ b/drivers/cix-drm/dptx/trilin_drm.c
@@ -699,8 +699,8 @@ int trilin_dp_encoder_compute_config(struct drm_encoder *encoder,
        bool is_ycbcr = false;
        int min_bpc;
        int ret;
-       int colorspace = connector_state->colorspace;
-       int color_format = BIT(__ffs(info->color_formats));
+       int colorspace = DRM_MODE_COLORIMETRY_DEFAULT;
+       int color_format = DRM_COLOR_FORMAT_RGB444;
 
        switch (color_format) {
```

- **How to test**: Boot patched with `drm.debug=0xff log_buf_len=16M`; check the existing `Note: ... color_format ... colorspace ... bpc ... bpp ...` log reports RGB444/default/8bpc/24bpp and no VSC override is programmed. Pass condition: display appears only in the forced-RGB build.

### Candidate 5: Side-band blocks: HDCP userspace cipher or stale audio/secondary stream
- **Source citation**: /Users/jperlow/cix-installer/.kernel-source-readonly/drivers/cix-drm/dptx/trilin_dptx.c:1484, /Users/jperlow/cix-installer/.kernel-source-readonly/drivers/cix-drm/dptx/trilin_dptx.c:1491, /Users/jperlow/cix-installer/.kernel-source-readonly/drivers/cix-drm/dptx/trilin_dptx.c:1495, /Users/jperlow/cix-installer/.kernel-source-readonly/drivers/cix-drm/dptx/trilin_dptx.c:2748, /Users/jperlow/cix-installer/.kernel-source-readonly/drivers/cix-drm/dptx/hdcp/cix_hdcp.c:358, /Users/jperlow/cix-installer/.kernel-source-readonly/drivers/cix-drm/dptx/hdcp/cix_hdcp.c:127, /Users/jperlow/cix-installer/.kernel-source-readonly/drivers/cix-drm/dptx/hdcp/cix_hdcp_ioctl.c:123, /Users/jperlow/cix-installer/.kernel-source-readonly/drivers/cix-drm/dptx/hdcp/hdcp2_tx_state.c:51, /Users/jperlow/cix-installer/.kernel-source-readonly/drivers/cix-drm/dptx/trilin_dptx_audio.c:82, /Users/jperlow/cix-installer/.kernel-source-readonly/drivers/cix-drm/dptx/trilin_dptx_audio.c:97
- **Why this matches**: Confirmed: normal DPTX modeset calls HDCP init, but source shows no `DRM_MODE_CONTENT_PROTECTION` property and no default modeset cipher enable. HDCP is exposed through a misc device; actual HWINIT/CIPHER_ENABLE work is ioctl-driven and gated by `CONFIG_TRILIN_DP_HDCP_VALIDATION`. Hypothesis: the shipped `cix-hdcp2` userspace could open the misc device and enable a bad cipher path after modeset. Confirmed: the audio path enables `SECONDARY_STREAM_ENABLE` at video stream-on even before audio is running; audio startup writes `SEC0_AUDIO_ENABLE=1`, while shutdown only clears the software `running` flag and does not clear the hardware audio-enable register. Hypothesis: a stale or malformed secondary/audio packet path can blank fragile sinks.
- **Concrete fix**: First no-source test: boot with the `cix-hdcp2` service/process and all display-audio userspace disabled. Patch-test: leave video enabled but disable secondary/audio stream hardware.

```diff
--- a/drivers/cix-drm/dptx/trilin_dptx.c
+++ b/drivers/cix-drm/dptx/trilin_dptx.c
@@ -1488,8 +1488,8 @@ static int trilin_dp_ctrl_stream_on(struct trilin_dp *dp, bool enable)
        trilin_dp_ctrl_mst_stream_setup(dp, dp_panel, true);
 
        trilin_dp_write(dp, TRILIN_DPTX_VIDEO_STREAM_ENABLE + regs_off, 1);
-       trilin_dp_write(dp, TRILIN_DPTX_SECONDARY_STREAM_ENABLE + regs_off, 1);
+       trilin_dp_write(dp, TRILIN_DPTX_SECONDARY_STREAM_ENABLE + regs_off, 0);
```

```diff
--- a/drivers/cix-drm/dptx/trilin_dptx_audio.c
+++ b/drivers/cix-drm/dptx/trilin_dptx_audio.c
@@ -102,6 +102,7 @@ static void dptx_audio_shutdown(struct device *dev, void *data)
 
        dp_audio->running = false;
+       trilin_dp_write(dp, TRILIN_DPTX_SEC0_AUDIO_ENABLE, 0);
 }
```

- **How to test**: Boot once with HDCP userspace disabled and no PulseAudio/PipeWire/ALSA client opening the DP audio codec; verify dmesg lacks `succeed to open hdcp file`, HDCP event reports, and `Re-config and enable dptx audio`. If still black, boot the secondary/audio-disable patch and verify `SECONDARY_STREAM_ENABLE=0` and `SEC0_AUDIO_ENABLE=0`.

## Module Parameter Inventory

| parameter name | type | default | controls | cmdline syntax |
|---|---|---:|---|---|
| `aux_timeout_ms` | `uint` | `50` | DP AUX transfer timeout budget; declared in /Users/jperlow/cix-installer/.kernel-source-readonly/drivers/cix-drm/dptx/trilin_dptx.c:56 and used when computing AUX retry iterations at /Users/jperlow/cix-installer/.kernel-source-readonly/drivers/cix-drm/dptx/trilin_dptx.c:745 | `trilin_dpsub.aux_timeout_ms=<ms>` |
| `power_on_delay_ms` | `uint` | `4` | Delay after DPCD `DP_SET_POWER_D0`; declared in /Users/jperlow/cix-installer/.kernel-source-readonly/drivers/cix-drm/dptx/trilin_dptx.c:60 and slept at /Users/jperlow/cix-installer/.kernel-source-readonly/drivers/cix-drm/dptx/trilin_dptx.c:1615 | `trilin_dpsub.power_on_delay_ms=<ms>` |
| `enable_fb` | `bool` | `false` | Linlon DRM fbdev helper setup; declared in /Users/jperlow/cix-installer/.kernel-source-readonly/drivers/cix-drm/linlon-dp/linlondp_drv.c:19 and consumed at /Users/jperlow/cix-installer/.kernel-source-readonly/drivers/cix-drm/linlon-dp/linlondp_drv.c:80 | `linlon_dp.enable_fb=1` |

Confirmed absent: no `hdcp`, `audio`, `pixel_per_cycle`, `lane`, or `max_rate` `module_param()` was found in `drivers/cix-drm/dptx/trilin_*.c`; those controls are firmware properties, userspace behavior, or patch-only experiments.

Relevant firmware properties confirmed in source: DPTX reads `cix,platform-id`, `cix,dp-lane-number`, `cix,dp-max-rate`, `cix,aux-clock-divider`, `pixel_per_cycle`, `cix,delay_after_hpd`, and `enabled_by_gop` at /Users/jperlow/cix-installer/.kernel-source-readonly/drivers/cix-drm/dptx/trilin_dptx.c:2876. Linlon ACPI reads parent `pixel_per_cycle` at /Users/jperlow/cix-installer/.kernel-source-readonly/drivers/cix-drm/linlon-dp/linlondp_dev.c:515 and `enabled_by_gop` at /Users/jperlow/cix-installer/.kernel-source-readonly/drivers/cix-drm/linlon-dp/linlondp_dev.c:640.

## Single Highest-Confidence Next-Boot Experiment

Use a conservative forced mode plus longer sink-power settle and full DRM tracing before rebuilding: `drm.debug=0xff log_buf_len=16M video=DP-1:1024x768@60e trilin_dpsub.power_on_delay_ms=250`.

## Further Questions

- Did EDID read succeed, or did `trilin_dp_connector_get_modes()` fall back to `drm_add_modes_noedid(..., 1920, 1080)` after 50 retries?
- What exact connector name, mode, adjusted mode, and flags appear in the `drm.debug=0xff` modeset log, especially before and after `trilin_dp_encoder_atomic_adjust_mode()`?
- What are the logged `Note: ... bpc ... bpp ... colorspace ... color_format ... info->color_formats` values from `trilin_dp_encoder_compute_config()`?
- What sink caps were logged for `max_lanes`, `max_rate`, TPS3/TPS4, VSC, MST, and downstream mode support?
- After black-screen, what are DPTX `register_info` values for `SOFT_RESET`, `SOURCE_ENABLE`, `FORCE_SCRAMBLER_RESET`, `VIDEO_STREAM_ENABLE`, `MAIN_STREAM_MISC0/1`, `MAIN_STREAM_OVERRIDE`, `SRC0_TU_CONFIG`, `SRC0_USER_PIXEL_COUNT`, `SRC0_DATA_CONTROL`, `SECONDARY_STREAM_ENABLE`, and `SEC0_AUDIO_ENABLE`?
- Are there any HDCP logs after boot such as `succeed to open hdcp file`, HDCP event reports, or `HWINIT`/cipher ioctl activity from the shipped `cix-hdcp2` process?
- Are there any audio logs such as `dp audio plugin status` or `Re-config and enable dptx audio` before or after the display turns black?
- Does the black-screen reproduce with the same monitor when forcing `video=DP-1:1024x768@60e`, and does the forced mode show up as the active DRM mode?

## Section 4: Cix Factory Image vs Our Yocto Build - What's Missing

### Evidence limits

- Could not read: `kernel-source/arch/arm64/configs/cix.config`. The Yocto recipe explicitly expects this file at `${S}/arch/arm64/configs/cix.config`, but the local `.kernel-source-readonly/` snapshot does not include `arch/arm64/configs/`; the recipe's config flow is `defconfig`, append `cix.config`, append `usb-rootfs.cfg`, then `olddefconfig` (/Users/jperlow/cixmini-msr1-rebake/meta-cix/recipes-kernel/linux-cix-msr1/linux-cix-msr1_6.6.10.bb:68, /Users/jperlow/cixmini-msr1-rebake/meta-cix/recipes-kernel/linux-cix-msr1/linux-cix-msr1_6.6.10.bb:75, /Users/jperlow/cixmini-msr1-rebake/meta-cix/recipes-kernel/linux-cix-msr1/linux-cix-msr1_6.6.10.bb:78, /Users/jperlow/cixmini-msr1-rebake/meta-cix/recipes-kernel/linux-cix-msr1/linux-cix-msr1_6.6.10.bb:82, /Users/jperlow/cixmini-msr1-rebake/meta-cix/recipes-kernel/linux-cix-msr1/linux-cix-msr1_6.6.10.bb:83).
- Could not read/extract: `/Users/jperlow/cix-installer/assets/cix-debs/cix-firmware*.deb`, `cix-dpu-ddk*.deb`, `cix-libdrm*.deb`, `cix-mesa*.deb`, `cix-cpipe*.deb`. The installer design expects Cix proprietary debs under `assets/cix-debs/`, but this checkout's directory has no `.deb` payloads; the build script warns and skips the proprietary layer when that directory is empty (/Users/jperlow/cix-installer/README.md:50, /Users/jperlow/cix-installer/README.md:63, /Users/jperlow/cix-installer/build/build-iso.sh:206, /Users/jperlow/cix-installer/build/build-iso.sh:211).
- Tool note: `dpkg-deb` is not in this builder's `PATH`; `ar` is available, but no fallback extraction was possible because there were no `.deb` inputs to unpack.
- Could not read: `kernel-source/drivers/gpu/drm/`. The local kernel snapshot has `drivers/cix-drm/` and `drivers/arm-drm/`, but not the requested `drivers/gpu/drm/` subtree. A search of the available display driver files found no `request_firmware()` call to cross-reference against Cix firmware deb contents.

### Kernel Config Baseline

- The local Yocto recipe pins the same downstream kernel commit used for this investigation, `SRCREV = cc636a675f7926846f04d31524c17b591955acca`, and documents that it matches the shipping `6.6.10-cix-build-generic` MS-R1 kernel source line (/Users/jperlow/cixmini-msr1-rebake/meta-cix/recipes-kernel/linux-cix-msr1/linux-cix-msr1_6.6.10.bb:7, /Users/jperlow/cixmini-msr1-rebake/meta-cix/recipes-kernel/linux-cix-msr1/linux-cix-msr1_6.6.10.bb:36, /Users/jperlow/cixmini-msr1-rebake/meta-cix/recipes-kernel/linux-cix-msr1/linux-cix-msr1_6.6.10.bb:43).
- The only readable local kernel config fragment found under the requested trees is `usb-rootfs.cfg`; it sets USB XHCI/storage/UAS/HID/VFAT built-in and `CONFIG_FRAMEBUFFER_CONSOLE_DEFERRED_TAKEOVER=y`, but it does not provide readable values for `CONFIG_DRM*`, `CONFIG_DRM_TRILIN*`, `CONFIG_DRM_CIX*`, or broad `CONFIG_FB*` beyond deferred fbcon takeover (/Users/jperlow/cixmini-msr1-rebake/meta-cix/recipes-kernel/linux-cix-msr1/files/usb-rootfs.cfg:24, /Users/jperlow/cixmini-msr1-rebake/meta-cix/recipes-kernel/linux-cix-msr1/files/usb-rootfs.cfg:27, /Users/jperlow/cixmini-msr1-rebake/meta-cix/recipes-kernel/linux-cix-msr1/files/usb-rootfs.cfg:32, /Users/jperlow/cixmini-msr1-rebake/meta-cix/recipes-kernel/linux-cix-msr1/files/usb-rootfs.cfg:39, /Users/jperlow/cixmini-msr1-rebake/meta-cix/recipes-kernel/linux-cix-msr1/files/usb-rootfs.cfg:50).
- The display Kconfig symbols that must be enabled are visible in source: `CONFIG_DRM_CIX` depends on `DRM && ARCH_CIX`, `CONFIG_DRM_LINLONDP` depends on `DRM && OF && COMMON_CLK && DRM_CIX`, `CONFIG_DRM_TRILIN_DP_CIX` depends on `DRM_CIX`, and `CONFIG_DRM_TRILIN_DPSUB` depends on `COMMON_CLK && DRM && OF` while selecting DP/HDMI helpers and the DP AUX chardev (kernel-source/drivers/cix-drm/Kconfig:2, kernel-source/drivers/cix-drm/Kconfig:7, kernel-source/drivers/cix-drm/Kconfig:11, kernel-source/drivers/cix-drm/Kconfig:15, kernel-source/drivers/cix-drm/Kconfig:38, kernel-source/drivers/cix-drm/Kconfig:40, kernel-source/drivers/cix-drm/dptx/Kconfig:2, kernel-source/drivers/cix-drm/dptx/Kconfig:4, kernel-source/drivers/cix-drm/dptx/Kconfig:9).

### Deb and Firmware Findings

- The installer post-install hook is written to install all non-kernel `*.deb` files from `/usr/local/lib/cix-installer/assets/cix-debs`, then run `apt-get install -fy` and `dpkg --configure -a`; therefore an empty deb directory is not factory-parity for the installed system (/Users/jperlow/cix-installer/post-install/25-cix-proprietary.sh:13, /Users/jperlow/cix-installer/post-install/25-cix-proprietary.sh:27, /Users/jperlow/cix-installer/post-install/25-cix-proprietary.sh:38, /Users/jperlow/cix-installer/post-install/25-cix-proprietary.sh:41, /Users/jperlow/cix-installer/post-install/25-cix-proprietary.sh:45, /Users/jperlow/cix-installer/post-install/25-cix-proprietary.sh:49).
- Yocto-side Cix userspace recipes fetch prebuilt proprietary payloads from `cix_proprietary__cix_proprietary` and `ext_debs`, copying their component trees verbatim via `bin_package` (/Users/jperlow/cixmini-msr1-rebake/meta-cix/recipes-bsp/cix-userspace/cix-userspace.inc:24, /Users/jperlow/cixmini-msr1-rebake/meta-cix/recipes-bsp/cix-userspace/cix-userspace.inc:34, /Users/jperlow/cixmini-msr1-rebake/meta-cix/recipes-bsp/cix-userspace/cix-userspace.inc:40, /Users/jperlow/cixmini-msr1-rebake/meta-cix/recipes-bsp/cix-userspace/cix-userspace.inc:44, /Users/jperlow/cixmini-msr1-rebake/meta-cix/recipes-extended/cix-ai-tools/cix-ai-tools.inc:33, /Users/jperlow/cixmini-msr1-rebake/meta-cix/recipes-extended/cix-ai-tools/cix-ai-tools.inc:42, /Users/jperlow/cixmini-msr1-rebake/meta-cix/recipes-extended/cix-ai-tools/cix-ai-tools.inc:54).
- The readable recipes cover `cix-audio-dsp`, `cix-gpu-umd`, `cix-noe-umd`, `cix-vpu-umd`, `cix-libdrm`, `cix-libglvnd`, and `cix-mesa`; I did not find readable local recipes or debs for `cix-dpu-ddk` or `cix-cpipe`, so their file payloads could not be compared. Relevant covered paths include `/lib/firmware` for audio/VPU, `/opt/cixgpu-*`, `/usr/share/cix`, `/usr/lib/aarch64-linux-gnu`, `/usr/share/glvnd`, and `/usr/share/vulkan` (/Users/jperlow/cixmini-msr1-rebake/meta-cix/recipes-bsp/cix-userspace/cix-audio-dsp_1.0.0.bb:34, /Users/jperlow/cixmini-msr1-rebake/meta-cix/recipes-bsp/cix-userspace/cix-gpu-umd_2.0.0.bb:22, /Users/jperlow/cixmini-msr1-rebake/meta-cix/recipes-bsp/cix-userspace/cix-gpu-umd_2.0.0.bb:33, /Users/jperlow/cixmini-msr1-rebake/meta-cix/recipes-bsp/cix-userspace/cix-noe-umd_1.0.0.bb:49, /Users/jperlow/cixmini-msr1-rebake/meta-cix/recipes-bsp/cix-userspace/cix-vpu-umd_1.0.0.bb:22, /Users/jperlow/cixmini-msr1-rebake/meta-cix/recipes-extended/cix-ai-tools/cix-libdrm_1.0.0.bb:40, /Users/jperlow/cixmini-msr1-rebake/meta-cix/recipes-extended/cix-ai-tools/cix-libglvnd_1.7.0.bb:34, /Users/jperlow/cixmini-msr1-rebake/meta-cix/recipes-extended/cix-ai-tools/cix-mesa_24.0.4.bb:32).
- The only firmware installed by the first-pass `cix-sky1-firmware` recipe is `dsp_fw.bin` at `/lib/firmware/cix/dsp_fw.bin` plus a `/lib/firmware/dsp_fw.bin` symlink; DTS names `dsp_fw.bin` for the audio DSP and `sfh_fw.bin` for the sensor hub, while the local display driver source has no readable `request_firmware()` calls (/Users/jperlow/cixmini-msr1-rebake/meta-cix/recipes-bsp/cix-sky1-firmware/cix-sky1-firmware_2025.4.bb:10, /Users/jperlow/cixmini-msr1-rebake/meta-cix/recipes-bsp/cix-sky1-firmware/cix-sky1-firmware_2025.4.bb:16, /Users/jperlow/cixmini-msr1-rebake/meta-cix/recipes-bsp/cix-sky1-firmware/cix-sky1-firmware_2025.4.bb:18, /Users/jperlow/cixmini-msr1-rebake/meta-cix/recipes-bsp/cix-sky1-firmware/cix-sky1-firmware_2025.4.bb:22, kernel-source/arch/dts-cix/sky1.dtsi:1087, kernel-source/arch/dts-cix/sky1.dtsi:1364).

### DT/ACPI and Bootloader Hand-Off

- The recipe states MS-R1 boots through UEFI/ACPI and that the DTB list is informational for cixmini; therefore factory-vs-ours display differences can live in firmware ACPI tables even with identical kernel source (/Users/jperlow/cixmini-msr1-rebake/meta-cix/recipes-kernel/linux-cix-msr1/linux-cix-msr1_6.6.10.bb:58, /Users/jperlow/cixmini-msr1-rebake/meta-cix/recipes-kernel/linux-cix-msr1/linux-cix-msr1_6.6.10.bb:62, /Users/jperlow/cixmini-msr1-rebake/meta-cix/conf/machine/cixmini.conf:15, /Users/jperlow/cixmini-msr1-rebake/meta-cix/conf/machine/cixmini.conf:21, /Users/jperlow/cixmini-msr1-rebake/meta-cix/conf/machine/cixmini.conf:23).
- The DPTX driver consumes fwnode properties for platform ID, lane count, max rate, AUX divider, pixel packing, HPD delay, and GOP hand-off; the Linlon DPU consumes ACPI/DT graph links, `pixel_per_cycle`, `enabled_by_gop`, fixed/smart clock properties, and pipeline nodes (kernel-source/drivers/cix-drm/dptx/trilin_dptx.c:2876, kernel-source/drivers/cix-drm/dptx/trilin_dptx.c:2885, kernel-source/drivers/cix-drm/linlon-dp/linlondp_dev.c:503, kernel-source/drivers/cix-drm/linlon-dp/linlondp_dev.c:519, kernel-source/drivers/cix-drm/linlon-dp/linlondp_dev.c:571, kernel-source/drivers/cix-drm/linlon-dp/linlondp_dev.c:587, kernel-source/drivers/cix-drm/linlon-dp/linlondp_dev.c:640).
- The local DT path wires DP0-DP4 to DPU0-DPU4 and enables USB-C DP PHYs on the EVB, but the MS-R1 ACPI tables were not present to compare against these DT graph links (kernel-source/arch/dts-cix/sky1-evb.dts:1070, kernel-source/arch/dts-cix/sky1-evb.dts:1087, kernel-source/arch/dts-cix/sky1-evb.dts:1108, kernel-source/arch/dts-cix/sky1-evb.dts:1126, kernel-source/arch/dts-cix/sky1-evb.dts:1166, kernel-source/arch/dts-cix/sky1-evb.dts:1344, kernel-source/arch/dts-cix/sky1-evb.dts:1428, kernel-source/arch/dts-cix/sky1-evb.dts:1573).
- Bootloader/GOP state is observable in the driver: DPTX and Linlon both read GOP state via SMC and can override `enabled_by_gop`; `cix_display` also has a `core_initcall()` ACPI reset path that hard-codes `control = 4` and toggles display reset bits before the platform driver binds (kernel-source/drivers/cix-drm/dptx/trilin_dptx.c:2885, kernel-source/drivers/cix-drm/dptx/trilin_dptx.c:2889, kernel-source/drivers/cix-drm/linlon-dp/linlondp_dev.c:594, kernel-source/drivers/cix-drm/linlon-dp/linlondp_dev.c:647, kernel-source/drivers/cix-drm/cix_display.c:136, kernel-source/drivers/cix-drm/cix_display.c:157, kernel-source/drivers/cix-drm/cix_display.c:170, kernel-source/drivers/cix-drm/cix_display.c:199).

### Ranked Gap Table

| Rank | Gap | Category | Likely impact on black screen | Source citation |
|---:|---|---|---|---|
| 1 | No readable `cix.config` baseline in the local kernel snapshot, even though the Yocto recipe appends it before `olddefconfig`. | config | High. A single missing or module-vs-built-in DRM/PHY/fb option can change whether Linlon/DPTX binds, when fbcon hands off, or whether DP AUX/PHY helpers exist. | /Users/jperlow/cixmini-msr1-rebake/meta-cix/recipes-kernel/linux-cix-msr1/linux-cix-msr1_6.6.10.bb:68, /Users/jperlow/cixmini-msr1-rebake/meta-cix/recipes-kernel/linux-cix-msr1/linux-cix-msr1_6.6.10.bb:78, kernel-source/drivers/cix-drm/Kconfig:2, kernel-source/drivers/cix-drm/Kconfig:38, kernel-source/drivers/cix-drm/dptx/Kconfig:2 |
| 2 | No captured MS-R1 factory ACPI tables or `_DSD` property dump to compare against the local DT display graph and driver property reads. | DT/ACPI | High. Identical source can behave differently if ACPI omits or changes DP/DPU graph links, lane count, max rate, pixel packing, clock, HPD delay, or GOP hand-off. | /Users/jperlow/cixmini-msr1-rebake/meta-cix/recipes-kernel/linux-cix-msr1/linux-cix-msr1_6.6.10.bb:58, kernel-source/drivers/cix-drm/dptx/trilin_dptx.c:2876, kernel-source/drivers/cix-drm/dptx/trilin_dptx.c:2885, kernel-source/drivers/cix-drm/linlon-dp/linlondp_dev.c:503, kernel-source/drivers/cix-drm/linlon-dp/linlondp_dev.c:519 |
| 3 | Proprietary Cix deb payloads are absent from current `assets/cix-debs/`, so the factory userspace layer cannot be reproduced or inspected from this checkout. | deb | Medium-to-high for installed-system display parity; lower for a pre-userspace d-i black screen unless HDCP/audio/GBM/Mesa userspace starts after modeset. | /Users/jperlow/cix-installer/README.md:50, /Users/jperlow/cix-installer/README.md:63, /Users/jperlow/cix-installer/build/build-iso.sh:206, /Users/jperlow/cix-installer/build/build-iso.sh:211, /Users/jperlow/cix-installer/post-install/25-cix-proprietary.sh:38 |
| 4 | Bootloader/GOP hand-off is not captured. The kernel reads GOP state via SMC, overrides `enabled_by_gop`, and has an early ACPI display reset path. | bootloader | Medium-to-high. If factory UEFI leaves DPU/DP/GOP/reset state different from our boot path, the DRM driver may inherit or reset display blocks differently before modeset. | kernel-source/drivers/cix-drm/dptx/trilin_dptx.c:2885, kernel-source/drivers/cix-drm/dptx/trilin_dptx.c:2889, kernel-source/drivers/cix-drm/linlon-dp/linlondp_dev.c:594, kernel-source/drivers/cix-drm/linlon-dp/linlondp_dev.c:647, kernel-source/drivers/cix-drm/cix_display.c:136, kernel-source/drivers/cix-drm/cix_display.c:199 |
| 5 | Firmware parity is not inspectable from local debs; the Yocto first-pass firmware recipe installs only `dsp_fw.bin`, while DTS also names `sfh_fw.bin`, and the available display source has no firmware requests. | firmware | Medium for whole-platform parity; currently unproven for DP/DPU because no display `request_firmware()` call is readable in the local source. | /Users/jperlow/cixmini-msr1-rebake/meta-cix/recipes-bsp/cix-sky1-firmware/cix-sky1-firmware_2025.4.bb:10, /Users/jperlow/cixmini-msr1-rebake/meta-cix/recipes-bsp/cix-sky1-firmware/cix-sky1-firmware_2025.4.bb:22, kernel-source/arch/dts-cix/sky1.dtsi:1087, kernel-source/arch/dts-cix/sky1.dtsi:1364 |
| 6 | `cix-dpu-ddk` and `cix-cpipe` package contents could not be read because neither matching local debs nor matching local recipes were available. | deb | Unknown. Do not assign them a display-boot role until package contents or services are available. | could not read: `/Users/jperlow/cix-installer/assets/cix-debs/cix-dpu-ddk*.deb`; could not read: `/Users/jperlow/cix-installer/assets/cix-debs/cix-cpipe*.deb` |

## Section 5: Ethernet / d-i Module Loading - Why No DHCP After Kernel Boots

### Initrd and d-i Sequence Evidence

- Could not read: `/Users/jperlow/cix-installer/build/iso-staging/install.a64/initrd.gz`, `/Users/jperlow/cix-installer/build/iso-staging/install.a64/gtk/initrd.gz`, and `/tmp/di-initrd/init`. There is no built ISO staging tree or initrd in the current checkout; therefore the actual `/init`, `/sbin/debian-installer`, installed udeb list, `netcfg` binary, and initrd `/lib/modules` tree could not be inspected.
- The configured build sequence is readable: extract upstream ISO into `build/iso-staging`, expect text-mode `install.a64/initrd.gz`, append a tiny cpio containing `/preseed.cfg`, optionally replace `install.a64/vmlinuz`, append a cpio containing `/lib/modules/$KVER`, and boot that initrd from GRUB (/Users/jperlow/cix-installer/build/build-iso.sh:47, /Users/jperlow/cix-installer/build/build-iso.sh:55, /Users/jperlow/cix-installer/build/build-iso.sh:60, /Users/jperlow/cix-installer/build/build-iso.sh:79, /Users/jperlow/cix-installer/build/build-iso.sh:91, /Users/jperlow/cix-installer/build/build-iso.sh:120, /Users/jperlow/cix-installer/build/build-iso.sh:161, /Users/jperlow/cix-installer/build/build-iso.sh:263).
- The script documents why module indexes matter in d-i: the initramfs gets no first-boot depmod pass, so missing `modules.alias` prevents udev from matching hardware modaliases to `.ko` files, including USB Ethernet dongles (/Users/jperlow/cix-installer/build/build-iso.sh:139, /Users/jperlow/cix-installer/build/build-iso.sh:145, /Users/jperlow/cix-installer/build/build-iso.sh:147, /Users/jperlow/cix-installer/build/build-iso.sh:153, /Users/jperlow/cix-installer/build/build-iso.sh:155).
- The configured d-i boot command uses `interface=auto`, `netcfg/dhcp_timeout=60`, `DEBCONF_DEBUG=developer`, and `BOOT_DEBUG=3`; the preseed also sets `netcfg/choose_interface` to `auto` and chooses the `network-console` udeb via anna (/Users/jperlow/cix-installer/build/build-iso.sh:261, /Users/jperlow/cix-installer/preseed/preseed.cfg:21, /Users/jperlow/cix-installer/preseed/preseed.cfg:31, /Users/jperlow/cix-installer/preseed/preseed.cfg:33, /Users/jperlow/cix-installer/preseed/preseed.cfg:48).

### Network Driver and Module Evidence

- Could not read: `/tmp/di-initrd/var/lib/dpkg/info/`, `/tmp/di-initrd/lib/modules/`, `hw-detect.udeb`, `ethdetect.udeb`, and `nic-modules-*.udeb`. No initrd or udebs are present under the current `assets/` or `build/` directories, so no per-NIC-family udeb could be confirmed or ruled out.
- Could not read: `/Users/jperlow/cix-installer/assets/kernel/modules-cixmini.tgz` and `/Users/jperlow/cix-installer/assets/kernel/Image-cixmini.bin`. The build script only injects the Cix kernel/modules when both files exist; otherwise it warns that d-i will run Debian's stock 6.1 arm64 kernel and expects Ethernet autodetect failure on MS-R1 (/Users/jperlow/cix-installer/build/build-iso.sh:115, /Users/jperlow/cix-installer/build/build-iso.sh:116, /Users/jperlow/cix-installer/build/build-iso.sh:164, /Users/jperlow/cix-installer/build/build-iso.sh:166).
- The module path is hard-coded as `KVER="6.6.10-cix-build-cix-build-generic"` in both the d-i injection script and target post-install hook, while the kernel recipe documents the shipping suffix as `6.6.10-cix-build-generic` and sets `KERNEL_LOCALVERSION = "-cix-build-generic"` (/Users/jperlow/cix-installer/build/build-iso.sh:118, /Users/jperlow/cix-installer/build/build-iso.sh:133, /Users/jperlow/cix-installer/post-install/10-our-kernel.sh:14, /Users/jperlow/cix-installer/post-install/10-our-kernel.sh:15, /Users/jperlow/cixmini-msr1-rebake/meta-cix/recipes-kernel/linux-cix-msr1/linux-cix-msr1_6.6.10.bb:7, /Users/jperlow/cixmini-msr1-rebake/meta-cix/recipes-kernel/linux-cix-msr1/linux-cix-msr1_6.6.10.bb:36).
- Could not read: `kernel-source/drivers/net/usb/ax88179_178a.c`, `kernel-source/drivers/net/ethernet/`, `kernel-source/drivers/net/ethernet/realtek/r8169*`, and any `r8125` source. The local kernel source snapshot does not include `drivers/net/`, so NIC driver `request_firmware()` calls could not be audited.
- The only readable local built-in override fragment forces USB host/storage/UAS/HID and fbcon behavior; no readable local fragment sets `CONFIG_USB_NET_AX88179_178A`, `CONFIG_R8169`, or `CONFIG_R8125` (/Users/jperlow/cixmini-msr1-rebake/meta-cix/recipes-kernel/linux-cix-msr1/files/usb-rootfs.cfg:24, /Users/jperlow/cixmini-msr1-rebake/meta-cix/recipes-kernel/linux-cix-msr1/files/usb-rootfs.cfg:27, /Users/jperlow/cixmini-msr1-rebake/meta-cix/recipes-kernel/linux-cix-msr1/files/usb-rootfs.cfg:32, /Users/jperlow/cixmini-msr1-rebake/meta-cix/recipes-kernel/linux-cix-msr1/files/usb-rootfs.cfg:50).
- Interface naming is a lower-probability cause from local evidence because both the GRUB command line and preseed use `auto`, not an `eth*`-only selector; however the actual `netcfg` binary could not be inspected without the initrd (/Users/jperlow/cix-installer/build/build-iso.sh:261, /Users/jperlow/cix-installer/preseed/preseed.cfg:21).

### Ranked Root-Cause List and Next-Boot Experiments

1. **Hard-coded kernel version path mismatch prevents d-i from seeing any injected modules.**  
   Evidence: the d-i and target scripts use `6.6.10-cix-build-cix-build-generic`, but the kernel recipe comments and localversion point at `6.6.10-cix-build-generic`; d-i only sees modules under `/lib/modules/<uname -r>` and the script validates the hard-coded path before appending the module cpio (/Users/jperlow/cix-installer/build/build-iso.sh:110, /Users/jperlow/cix-installer/build/build-iso.sh:118, /Users/jperlow/cix-installer/build/build-iso.sh:133, /Users/jperlow/cix-installer/post-install/10-our-kernel.sh:15, /Users/jperlow/cixmini-msr1-rebake/meta-cix/recipes-kernel/linux-cix-msr1/linux-cix-msr1_6.6.10.bb:7, /Users/jperlow/cixmini-msr1-rebake/meta-cix/recipes-kernel/linux-cix-msr1/linux-cix-msr1_6.6.10.bb:36).  
   Next boot: at a d-i shell or serial console, run `uname -r; find /lib/modules -maxdepth 2 -type f -name modules.alias -o -name modules.dep; ls /lib/modules/$(uname -r)`; pass is matching `uname -r` and module indexes under that exact directory.

2. **The booted ISO may not contain the Cix kernel/modules at all if it was built from the current asset state.**  
   Evidence: the build script swaps the d-i kernel only if both `Image-cixmini.bin` and `modules-cixmini.tgz` exist, and otherwise explicitly warns that d-i will run Debian's stock 6.1 arm64 kernel with expected Ethernet autodetect failure; those assets are expected under `assets/kernel/` by the README (/Users/jperlow/cix-installer/build/build-iso.sh:115, /Users/jperlow/cix-installer/build/build-iso.sh:116, /Users/jperlow/cix-installer/build/build-iso.sh:164, /Users/jperlow/cix-installer/build/build-iso.sh:166, /Users/jperlow/cix-installer/README.md:63, /Users/jperlow/cix-installer/README.md:64).  
   Next boot: run `uname -r` before netcfg; if it reports Debian `6.1.0-*arm64`, rebuild with populated `assets/kernel/Image-cixmini.bin` and `assets/kernel/modules-cixmini.tgz`.

3. **NIC driver `.ko` files may be absent from the injected module tarball even if `modules.alias` exists.**  
   Evidence: the build script appends whatever `modules-cixmini.tgz` contains and generates aliases for that staged tree; no current tarball or initrd is readable to confirm `r8169`, `r8125`, or `ax88179_178a` paths (/Users/jperlow/cix-installer/build/build-iso.sh:132, /Users/jperlow/cix-installer/build/build-iso.sh:153, /Users/jperlow/cix-installer/build/build-iso.sh:158, /Users/jperlow/cix-installer/build/build-iso.sh:161; could not read: `/Users/jperlow/cix-installer/assets/kernel/modules-cixmini.tgz`; could not read: `/tmp/di-initrd/lib/modules/`).  
   Next boot: run `find /lib/modules/$(uname -r) -name 'r8169*.ko*' -o -name 'r8125*.ko*' -o -name 'ax88179_178a*.ko*'; modprobe -v ax88179_178a; modprobe -v r8169; dmesg | tail -200`.

4. **USB-C AX88179 path may be missing the USB Ethernet class driver, even though USB host/storage/HID are built in.**  
   Evidence: the local override fragment explicitly builds XHCI, USB storage, UAS, USB HID, and HID generic into the kernel, but the readable fragment has no USB Ethernet driver setting; that leaves AX88179 dependent on the unseen `cix.config` or module tarball (/Users/jperlow/cixmini-msr1-rebake/meta-cix/recipes-kernel/linux-cix-msr1/files/usb-rootfs.cfg:24, /Users/jperlow/cixmini-msr1-rebake/meta-cix/recipes-kernel/linux-cix-msr1/files/usb-rootfs.cfg:25, /Users/jperlow/cixmini-msr1-rebake/meta-cix/recipes-kernel/linux-cix-msr1/files/usb-rootfs.cfg:26, /Users/jperlow/cixmini-msr1-rebake/meta-cix/recipes-kernel/linux-cix-msr1/files/usb-rootfs.cfg:32).  
   Next boot: plug only the AX88179 dongle and run `lsusb; cat /sys/bus/usb/devices/*/modalias; modprobe -v ax88179_178a; ip -br link`; pass is a new interface and RX/TX counters after `udhcpc` or `dhclient`.

5. **d-i udeb/hw-detect path is unverified and may not be replaying coldplug or loading NIC modules before netcfg.**  
   Evidence: the initrd could not be extracted because no initrd exists in the current tree; the only explicit anna selection in preseed is `network-console`, and the build script relies on d-i modprobe/hotplug once matching `/lib/modules/<uname -r>` is appended (/Users/jperlow/cix-installer/preseed/preseed.cfg:48, /Users/jperlow/cix-installer/build/build-iso.sh:108, /Users/jperlow/cix-installer/build/build-iso.sh:113; could not read: `/tmp/di-initrd/init`; could not read: `/tmp/di-initrd/var/lib/dpkg/info/`).  
   Next boot: use `BOOT_DEBUG=3` shell breakpoints, then run `ps; udevadm trigger --action=add; udevadm settle; logread || dmesg; anna-install nic-modules-$(uname -r)-di ethdetect hw-detect` if those udebs are present.

6. **NIC firmware absence is possible but unconfirmed.**  
   Evidence: the current firmware recipe installs only `dsp_fw.bin`; no initrd `/lib/firmware` and no NIC driver source are readable, so firmware requirements for `r8169`, `r8125`, or `ax88179_178a` cannot be checked locally (/Users/jperlow/cixmini-msr1-rebake/meta-cix/recipes-bsp/cix-sky1-firmware/cix-sky1-firmware_2025.4.bb:16, /Users/jperlow/cixmini-msr1-rebake/meta-cix/recipes-bsp/cix-sky1-firmware/cix-sky1-firmware_2025.4.bb:23; could not read: `/tmp/di-initrd/lib/firmware`; could not read: `kernel-source/drivers/net/usb/ax88179_178a.c`).  
   Next boot: after manual `modprobe`, run `dmesg | grep -i firmware` and `find /lib/firmware -maxdepth 3 -type f | sort`; if firmware is requested and missing, append those blobs to the d-i initrd next.

7. **Interface naming is less likely than module loading, but still worth one forced-name test.**  
   Evidence: both configured entry points select `auto` rather than `eth0`, but the actual `netcfg` binary and its interface enumeration code were not readable without the initrd (/Users/jperlow/cix-installer/build/build-iso.sh:261, /Users/jperlow/cix-installer/preseed/preseed.cfg:21; could not read: `/tmp/di-initrd/bin/netcfg`; could not read: `/tmp/di-initrd/sbin/netcfg`).  
   Next boot: add one test entry with `net.ifnames=0 interface=eth0`, and another with `interface=<actual-name>` captured from `ip -o link`; if DHCP starts only under a forced interface, keep `net.ifnames=0` or preseed the actual interface name.
