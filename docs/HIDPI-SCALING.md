# HiDPI scaling policy

How NCZ-OS sizes the boot splash, the login screen and the desktop on high
density displays, and where each decision lives. Applies to both
architectures: amd64 laptops with internal panels, and Sky1 boards that are
usually connected to an external monitor.

## Output scale policy

One rule, implemented once in `assets/display/ncz-display-scale` (installed
as `/usr/local/bin/ncz-display-scale` by `post-install/20-desktop.sh`):

| pixel density of the mode in use | scale |
|---|---|
| 192 ppi or more (2 x the 96 dpi baseline) | 2 |
| 144 to 191 ppi | 1.5 |
| below 144 ppi | 1 |
| physical size missing, under ~6 in, or not matching the mode's aspect ratio | 1 |

Density comes from the EDID physical size (as reported by `wlr-randr`) and
the pixel size of the mode. Missing or implausible sizes are common on
projectors, TVs, KVM switches and EDIDs that only encode an aspect ratio, so
the fallback is always 1. The helper only uses whole and half steps; finer
steps make more XWayland applications blurry.

Examples: 16 in MacBookPro16,1 panel 3072x1920 (227 ppi) is 2; 27 in 4K
monitor (163 ppi) is 1.5; 24 in 4K (184 ppi) is 1.5; 27 in QHD (109 ppi),
32 in 4K (137 ppi) and any TV are 1.

## Desktop session

The Singularity shell already gives every output that has no saved setting a
density-derived default (`DisplayManager.dpi_default_scale()` in upstream
singularity-shell; on a MacBookPro16,1 it logged
`eDP-1 has no saved scale, defaulting to 2.00 (3072x1920 px, 340x220 mm)` on
first login, 2026-10-06). NCZ does not replace that. The user unit
`ncz-display-scale.service` (wanted by `singularity-session.target`) runs
`ncz-display-scale session` as a safety net for payloads or displays where the
shell leaves a high density output at 1:

* It does nothing if `~/.config/singularity/displays.json` exists. The shell
  writes that file only when the user saves display settings, so a choice the
  user made is never overridden.
* It waits for the shell to settle (8 s), then raises an output only when the
  output is still at scale 1 and the policy says more. Any other current
  scale is kept.
* Each display is handled once, keyed by make, model, serial and connector,
  and recorded in `$XDG_STATE_HOME/ncz/display-scale/` (default
  `~/.local/state/ncz/display-scale/`). A display plugged in later gets its own
  first-time decision. Delete the record to have it decided again.
* Text scaling (`org.gnome.desktop.interface text-scaling-factor`) stays at 1.
  Output scale already enlarges text, and changing both would double it.

## Login screen

`post-install/55-greeter.sh` keeps the rule that the greeter never
scans out above 1920x1200 (no 4K at the login screen). The greeter autostart
now asks `ncz-display-scale greeter` for the mode: the largest mode within
1920x1200 that has the panel's own aspect ratio, then the policy scale for that
mode. A 16:10 3072x1920 panel therefore gets 1920x1200 at scale 1 instead of
a letterboxed 1920x1080; a 4K monitor still gets 1920x1080. If the helper is
missing or cannot read the outputs, the previous fixed 1920x1080 loop runs.

## Boot splash and session splash

Both splashes draw through the upstream singularity-loginui renderer
(`loginui_render_splash()`). Upstream sized the logo from the screen height
alone (16 %), which makes the 696x52 Cygnus wordmark about 2.1 times the
screen height wide: cropped on every landscape display (about 4100 px wide on
3072x1920, about 2300 px on 1920x1080). The loading bar was a fixed 220x4 px.

`assets/singularity/patches/singularity-loginui/0001-splash-fit-logo-to-surface-and-scale-loading-bar.patch`
fits the logo inside 60 % of the width and 16 % of the height, keeping its
aspect ratio, and scales the bar with the surface height (1080 px is 1x,
clamped 1x to 4x, never wider than 60 % of the width). `build/build-singularity.sh`
applies it to the desktop tree's loginui (session splash) and to the boot
splash's own bundled loginui copy. It takes effect when the Singularity
payload is rebuilt.

### Evidence

* `build/test-splash-logo-fit.sh` links the real loginui sources and renders
  the frame at 3072x1920, 1920x1080, 1366x768, 1024x768 and 1080x1920. It
  passes with the patch (logo about 60 % wide, fully on screen) and flags all
  five resolutions without it (`PATCH=0 EXPECT=fail`).
* `build/hidpi/kvm-splash-stage.sh` and `build/hidpi/kvm-splash-shot.sh` boot
  the real `singularity-boot-splash` binary, built with and without the patch,
  in a KVM guest on a QEMU display of each resolution, and capture the
  scanout with `screendump`. Captured at 3072x1920, 1920x1080, 1368x768,
  1360x768 and 1024x768: unpatched cropped at every size, patched fully on
  screen. A 1366-wide mode comes out sheared on both QEMU display devices
  (stdvga and virtio-gpu) for the unpatched and the patched binary alike, so
  that one width is proven by the render harness only.

## Tests

* `build/test_display_scale.py`: policy table, greeter mode choice, and the
  session rules (saved settings respected, first login only, shell's choice
  kept, no EDID size, failed apply retried). Wired into `make parity`.
* `build/test-greeter-output-mode.sh`: runs the real greeter autostart against
  a fake `wlr-randr`, with and without the helper.
