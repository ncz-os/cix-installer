# Sky1 HDMI/DP audio investigation, September 17, 2026

## Result and confidence

O6N running `7.2.6-sky1-ncz`, PipeWire 1.6.8, display VP2488-4K:
the fallback Pulse ALSA sink closed its PCM immediately at playback boundaries.
Set its idle policy when loading `module-alsa-sink` so it continues streaming
silence across those boundaries. This removes a measured, repeated DP audio
shutdown/startup/reconfiguration cycle. No kernel change is justified by the
disconnected-port error evidence gathered here.

Confidence is high in the error caller identification and the before/after PCM
behavior. Confidence that idle teardown explains the reported audible engage
delay is moderate: testing used digital silence, without an acoustic recording
or an operator listening confirmation. Continuous-playback cutouts, initial
display acquisition latency, physical hotplug, system suspend/resume, and the
different cixmini topology are not certified fixed by these tests.

## The apparent periodic reprobe

The live journal contradicts the earlier interpretation of the 2428-second
burst as an unprompted periodic reprobe. With monotonic timestamps:

| Event | Uptime (seconds) |
| --- | ---: |
| Stop WirePlumber following a configuration edit | 2428.697909 |
| Start PipeWire | 2428.736650 |
| Start WirePlumber | 2428.741555 |
| Disconnected codec startup ENODEV | 2428.857816 |
| Start PipeWire after another edit | 2460.322655 |
| Start WirePlumber | 2460.324333 |
| Disconnected codec startup ENODEV | 2460.432321 |
| Start PipeWire after reverting the override | 2560.228169 |
| Start WirePlumber | 2560.229725 |
| Disconnected codec startup ENODEV | 2560.337760 |

The earlier 141-second burst also follows user audio service startup. The
178-second burst follows the greeter's audio service startup after a desktop
crash: `_greetd`'s user manager started PipeWire at 177.900474 and WirePlumber at
177.902545, before the ENODEV at 177.998222. Its exact process stack was not
traced retrospectively, but all the cited recurrences align with audio service
startup rather than a periodic kernel timer. The failed override also produced parse-error/empty-file
messages in the journal, in addition to targeting the wrong node creation path.

A dedicated ftrace instance filtering `snd_soc_dai_startup` with
`options/func_stack_trace=1` reproduced the same disconnected-port error pattern
on a controlled WirePlumber restart at uptime 3020.834 seconds:

```text
wireplumber-9522: snd_soc_dai_startup <-__soc_pcm_open
snd_soc_dai_startup
__soc_pcm_open
soc_pcm_open
snd_pcm_open_substream
snd_pcm_open
snd_pcm_playback_open
snd_open
chrdev_open
do_dentry_open
vfs_open
path_openat
do_file_open
do_sys_openat2
__arm64_sys_openat
```

This is a userspace PCM open during audio-device/profile enumeration. It is not
a DRM worker invoking codec startup. There were no DAI opens in the initial
passive trace interval before the controlled restart. The CIX connector uses
`DRM_CONNECTOR_POLL_HPD` in `trilin_drm.c`; the presence of
`drm_kms_helper_poll_init()` in linlondp does not by itself prove periodic PCM
opens or absence of hardware HPD interrupts.

## Hardware and clock path

Source was checked against the authoritative meta-cix 7.2 patch series at
`~/yocto-docker/yocto6-ncz-tydeus/meta-cix`, with the applied source in
`~/linux-port-v7.2.6` used to follow the complete call paths.

- Existing patch `0231-drm-cix-reject-disconnected-dp-audio-startup.patch`
  already makes `dptx_audio_startup()` return `-ENODEV` before writing
  `TRILIN_DPTX_SEC0_AUDIO_ENABLE` when no display is connected. Adding that check
  again or suppressing the error would not fix the connected output.
- `__soc_pcm_open()` performs component runtime-PM gets before DAI startup.
  Therefore a failed open is **not** entirely free of hardware side effects:
  `cdns_i2s_mc_runtime_resume()` enables that I2S instance's clocks, resets that
  instance, and restores its regmap before the codec rejects the open.
- `cdns_i2s_mc_hw_params()` selects a parent on the instance's I2S clock. It is
  not reached for a disconnected PCM rejected during open.
- `clk-sky1-audss.c` gives I2S instances distinct gate/mux bitfields. The reset
  controller uses a masked `regmap_update_bits()` for the selected reset ID.
  Sharing the clock controller does not mean every open reprograms all clocks.

Live clock-summary mappings on this O6N were:

| ALSA PCM | ACPI CPU | Clock | Display state |
| --- | --- | --- | --- |
| hw:0,0 | CIXH6011:02 | audss_i2s5 | disconnected |
| hw:0,1 | CIXH6011:03 | audss_i2s6 | connected |
| hw:0,2 | CIXH6011:06 | audss_i2s9 | disconnected |

During a 60-second silent stream to hw:0,1, a test process attempted 20 opens of
each disconnected PCM, every two seconds, using `O_WRONLY | O_NONBLOCK`. All 40
returned `ENODEV`. All 22 PCM status samples were `RUNNING`, with the same
`trigger_time: 3275.024489360` and advancing DMA pointers. The trace covering the
40 failed opens showed only their own `audss_i2s5`/`audss_i2s9` gate cycles, no
`clk_set_rate`/`clk_set_parent`, no disable of `audss_i2s6` or `audio_clk*`, no
connected DP shutdown, and no `snd_pcm_stop_xrun`. There was one connected
`hw_params` and one start trigger. This provides no support for the proposed
shared-clock glitch under these conditions; it cannot exclude every hardware
fault or an inaudible-to-software loss downstream of DMA.

A separate WirePlumber restart did shut down the idle connected PCM before
enumeration began. Service restarts are themselves disruptive and should not be
used to attribute that shutdown to the disconnected-port probes.

## Correct policy layer and before/after verification

The live sink was `ncz_sky1_hdmi_0_1`, `factory.name=api.alsa.pcm.sink`, with
`pulse.module.id=536870916`, created by `module-alsa-sink`. It was not an ALSA
monitor node to which a WirePlumber `monitor.alsa.rules` override would apply.
PipeWire's [1.6.8 module source](https://github.com/PipeWire/pipewire/blob/1.6.8/src/modules/module-protocol-pulse/modules/module-alsa-sink.c)
accepts `sink_properties` and defaults `node.suspend-on-idle` to true if absent.
The installed WirePlumber `scripts/node/suspend-node.lua` also sends Suspend
after five idle seconds unless `session.suspend-timeout-seconds=0`.

The helper now supplies:

```text
node.suspend-on-idle=false
node.pause-on-idle=false
session.suspend-timeout-seconds=0
```

Three cycles of three-second silent playback and eight-second idle gaps were
tested with `pw-play`, `/proc/asound/card0/pcm1p/sub0/status`, and ftrace:

| Measurement | Baseline | Candidate |
| --- | --- | --- |
| Connected DP startups / hw_params | 3 / 3 | 1 / 1 |
| Connected DP shutdowns | 3 | 0 |
| I2S runtime suspends | 3 | 0 |
| PCM through idle gaps | closed | RUNNING, DMA pointer advancing |
| Playback start time across all cycles | changed each cycle | unchanged |

Baseline startup times were 3121.950783, 3133.020840, and 3144.094867; shutdowns
were 3124.944214, 3136.015151, and 3147.098440. Candidate startup was
3185.190922 with no subsequent shutdown over the three cycles.

After installing the final helper, the normal autoswitch service recreated the
module with the quoted `sink_properties` argument. `wpctl inspect` confirmed all
three properties. Repeating all three cycles again produced exactly one startup
(3379.055241), one hw_params and one trigger, zero shutdowns/runtime suspends,
and the same PCM trigger timestamp through all gaps. Volume was restored to 76%.

The change applies to helper-created display sinks using discovered card/device
identities, with no O6N port mapping in production code. It leaves native
ACP/UCM/HDA/USB sinks untouched. It is not evidence of a fix for cixmini's
different audio configuration. A candidate address responded to SSH but did not
accept the available credentials, so its identity/audio state was not verified.

No kernel source was changed, so bitbake compile and KVM kernel boot gates were
not run or claimed. A kernel modification would still require those gates. The
global Claude kernel checklist was not present in this environment.

Raw investigation evidence and repeatable test scripts are retained on ULTRA in
`~/Projects/astra-sky1-audio/`. O6N's previous installed helper and packaged copy
were backed up as `/tmp/astra-audio-installed-before.py` and
`/tmp/astra-audio-asset-before.py` before installation. No reboot was needed.
