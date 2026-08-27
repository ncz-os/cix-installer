# CIX Sky1 HDMI/DP Audio Autoswitch

## Decision

This ships a user-session fallback daemon, not an ALSA UCM2 profile.

UCM2 prior art exists for fixed PCM mappings and real jack controls:

- `/usr/share/alsa/ucm2/Intel/broxton-rt298/Hdmi.conf` declares HDMI devices with `PlaybackPCM "hw:${CardId},N"` and `JackControl "HDMI/DP,pcm=N Jack"`.
- `/usr/share/alsa/ucm2/Rockchip/max98090/HiFi.conf` combines analog devices and an HDMI device with a jack control.
- `/usr/share/alsa/ucm2/Rockchip/rk3399-gru-sound/HiFi.conf` uses `JackControl "Headphones Jack"` for analog headphone routing.

Sky1 DTS and ACPI support can create `HDMI/DP,pcm=N` jack objects, but the confirmed O6N failure is that WirePlumber ACP currently collapses the Sky1 card to one exposed sink bound to PCM device 0. A UCM profile alone is therefore not a safe complete fix until the running kernel and WirePlumber combination is proven to expose all UCM devices as ports. The fallback daemon directly covers the missing sink-exposure behavior while avoiding static PipeWire configuration.

## Installed Pieces

- `/usr/local/bin/ncz-sky1-audio-autoswitch`
- `/etc/systemd/user/ncz-sky1-audio-autoswitch.service`
- global user-service enablement via `systemctl --global enable ncz-sky1-audio-autoswitch.service`
- `pulseaudio-utils`, because `pipewire-pulse` only suggests it and does not install `pactl`

The daemon is intentionally a user service. It talks to the active user's PipeWire Pulse server with `pactl`; a failure to load a sink logs an error and does not participate in `pipewire.service` startup.

## Runtime Behavior

1. Find ALSA cards whose `/proc/asound/cards` identity contains `cix,sky1`, `cix_sky1`, or `cixsky1`.
2. Enumerate whatever `/proc/asound/cardX/eld#N` files the running kernel exposes.
3. Treat `sad_count > 0` as a connected audio-capable display.
4. For connected HDMI/DP ELD devices, first reuse any existing PipeWire sink
   that already advertises the same `alsa.card` and `alsa.device` properties.
   If none exists, load a PipeWire Pulse ALSA sink:

   ```sh
   pactl load-module module-alsa-sink sink_name=ncz_sky1_hdmi_X_N device=hw:X,N namereg_fail=false
   ```

   `module-alsa-sink`, `device`, and `sink_name` are documented by `pipewire-pulse-module-alsa-sink(7)`. The module family and `load-module` command format are documented by `pipewire-pulse-modules(7)` and `/usr/share/pipewire/pipewire-pulse.conf`.

5. Set the default sink with `pactl set-default-sink` and move current sink inputs.
6. If no display ELD is connected, leave normal desktop/analog fallback alone. If the current default is one of this daemon's sinks, restore the first non-`ncz_sky1_hdmi_*` sink.

## Board Evidence

- Radxa Orion O6N: live evidence from 2026-08-26 showed card 0 `cix,sky1` with `eld#1` connected to `VP2488-4K` and `eld#0`/`eld#2` disconnected. This is the only board with live ELD evidence for this issue.
- Radxa Orion O6: `meta-cix` contains a distinct `sky1-orion-o6.dts`; its sound node wires DP audio links with `jack-det,dpout`.
- Radxa Orion O6 (real hardware, live evidence gathered 2026-08-26): confirms the
  ASoC `sky1-asoc-card` (`CIXH6070:00`) architecture is present on O6 too, same three
  DP audio links (`dp[0]`/`dp[1]`/`dp[2]`) as O6N -- but on this specific unit the card
  never fully registers: `dp[2]`'s codec stays `codec[(null)]` through dozens of probe
  retries from boot (t=6s) through t=138s, and the deferred-probe loop never resolves.
  As a result `/proc/asound/cards` shows NO `cix,sky1`-named card on this board at
  all -- only `0 [HDA]: cix-ipbloq-hda - CIX SKY1 ORION O6 HDA` (a real ALC256 codec
  with genuine hardware jack-sense kcontrols: `Headphone Jack`, `Front Mic Jack`,
  `Rear Mic Jack`, `Front Line Out Jack`, `Speaker Phantom Jack` -- all live-readable
  booleans, confirmed `Headphone Jack: on` with a headphone actually plugged in) and
  `1 [BRIO]` (a USB webcam mic, irrelevant here).
  This is a useful confirming case for the daemon design, not a contradiction: because
  it only matches ALSA cards whose `/proc/asound/cards` identity contains `cix,sky1`/
  `cix_sky1`/`cixsky1`, it correctly finds nothing to manage on this board as currently
  booted, and leaves the HDA card's own native ACP/UCM jack detection (which already
  works via upstream ALC256 support) untouched. Whether O6's ASoC HDMI path ever
  successfully probes on other units/firmware revisions is unconfirmed -- this is one
  real unit's boot state, not proof the DTS-declared HDMI path is universally
  nonfunctional on O6.
- Radxa Orion O6N: `meta-cix` contains a distinct `sky1-orion-o6n.dts`; its sound node separately wires DP audio links with `jack-det,dpout`.
- Orange Pi 6 Plus: `meta-cix` contains a distinct `sky1-orangepi-6-plus.dts` in `0020-arm64-dts-cix-Add-Orange-Pi-6-Plus-device-tree.patch`; it wires DP audio links with `jack-det,dpout`, and an `alc269_codec` HDA node is present but the `hda` sound link is disabled.
- MS-R1: `meta-cix/conf/machine/cixmini.conf` identifies the target as `ms-r1`, but no MS-R1 DTS/DSDT audio source was found in this tree. MS-R1 appears to be ACPI-described.
- Orange Pi 6 non-Plus: no separate non-Plus DTS was found in this tree. Do not infer Orange Pi 6 behavior from Orange Pi 6 Plus.

No enabled analog headphone path was found in the checked DTS sound nodes. The fallback daemon therefore detects only digital-display ELD state and leaves any future analog sink exposed by ACP/UCM untouched when no display audio ELD is connected.

## Validation Performed Off Target

- Local PipeWire examples confirm the safe static factory syntax is `factory = adapter` with `factory.name = api.alsa.pcm.sink`; this is not used by the shipped fix.
- `pipewire-pulse-modules(7)` confirms `load-module` syntax and the built-in `module-alsa-sink`.
- `pipewire-pulse-module-alsa-sink(7)` confirms `device` and `sink_name` module options.
- The daemon compiles with Python bytecode validation:

  ```sh
  python3 -m py_compile assets/audio/ncz-sky1-audio-autoswitch.py
  ```

- The systemd user unit verifies off-target by substituting an equivalent
  temporary executable path, because the checkout host does not have the final
  `/usr/local/bin/ncz-sky1-audio-autoswitch` install path populated:

  ```sh
  tmp=$(mktemp -d)
  cp assets/audio/ncz-sky1-audio-autoswitch.py "$tmp/ncz-sky1-audio-autoswitch"
  chmod 0755 "$tmp/ncz-sky1-audio-autoswitch"
  sed "s|/usr/local/bin/ncz-sky1-audio-autoswitch|$tmp/ncz-sky1-audio-autoswitch|" \
    assets/audio/ncz-sky1-audio-autoswitch.service > "$tmp/ncz-sky1-audio-autoswitch.service"
  systemd-analyze --user verify "$tmp/ncz-sky1-audio-autoswitch.service"
  rm -rf "$tmp"
  ```

There is no safe `pipewire --dry-run` equivalent used here because no static PipeWire configuration is installed.

## Live O6N Deployment Procedure

Do not restart PipeWire, WirePlumber, or the desktop session as a first step.

1. Copy or install the new files onto O6N through the normal package/image path.
2. Confirm prerequisites:

   ```sh
   command -v pactl
   command -v wpctl
   pactl info
   cat /proc/asound/cards
   for f in /proc/asound/card0/eld#*; do echo "== $f =="; cat "$f"; done
   ```

3. Start only the autoswitch user service for the logged-in user:

   ```sh
   systemctl --user daemon-reload
   systemctl --user start ncz-sky1-audio-autoswitch.service
   systemctl --user status --no-pager ncz-sky1-audio-autoswitch.service
   ```

4. Verify a connected-display sink appears and becomes default:

   ```sh
   pactl list short sinks
   pactl get-default-sink
   wpctl status
   ```

   On the 2026-08-26 O6N setup with `eld#1` connected, expect a sink named `ncz_sky1_hdmi_0_1`.

5. Run audible tests without restarting the audio stack:

   ```sh
   speaker-test -D pulse -c 2 -t wav
   pactl list short sink-inputs
   ```

6. Hotplug test:

   - unplug the display audio path and watch `sad_count` become `0`;
   - reconnect it and watch `sad_count` become nonzero;
   - confirm `pactl get-default-sink` returns the matching `ncz_sky1_hdmi_*` sink.

7. If anything misbehaves, stop only the autoswitch service:

   ```sh
   systemctl --user stop ncz-sky1-audio-autoswitch.service
   ```

   Do not restart `pipewire.service`, `pipewire-pulse.service`, or `wireplumber.service` unless a human has separately decided that is necessary.
