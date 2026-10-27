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

## Boot splash -> greeter ordering contract (DELL scanout race, 2026-10-27)

The KMS boot splash (`singularity-boot-splash.service`) and the greeter
(`greetd`) must NOT start in parallel. On the DELL Inspiron 5521 (Intel HD
4000, desktop build 4971507b) the greeter ran for 16 h with the panel black:
`seatd` logged `Could not make device fd drm master: Device or resource busy`
because `ncz-boot-splash` still owned DRM when labwc called `drmSetMaster`,
and a wlroots compositor does not retry the master after losing that race --
it lived with a dead pipeline (every plane `crtc=(null)`, `fb=0`) until a
manual `systemctl restart greetd`, after which the pipeline came up instantly
(`crtc[54] pipe A enable=1 active=1, primary fb=115`). The driver was fine;
the ordering was not.

The contract, enforced by `post-install/60-boot-splash.sh` and
`post-install/55-greeter.sh`:

* The splash's DRM ownership is bounded to a total of <= 8 s (`timeout 6s`
  + `--kill-after=2s`; `--max-life 5`). It is a `Type=oneshot` that owns DRM
  until its own cap expires; the `rc=124` timeout is a clean exit, as before.
* `greetd` is ordered `After= singularity-boot-splash.service` (a drop-in in
  `greetd.service.d`, not a splash unit rewrite) so the compositor starts
  only once DRM is released. This cannot deadlock: the splash no longer
  waits on the greeter past its cap (the greeter-ready marker is a fast
  handoff hint, the timeout is the hard bound) and the splash does not order
  itself after greetd, so the two ordering directions cannot cycle. A
  headless or splash-missing boot has nothing to wait on.
* A post-greetd gate (`ncz-greeter-scanout.service`, `After=greetd.service`)
  is the last line of defence against any other cause of a dead pipeline: it
  waits up to ~10 s for an active CRTC (the kernel debugfs
  `/sys/kernel/debug/dri/card*/state` -- a `crtc[N]` header followed by an
  `enable=1 active=1` line -- with the `/sys/class/drm/card*-*` connector
  `enabled`+`connected` sysfs attrs as the fallback when the file is
  unreadable). If the greeter is up with no active CRTC it logs a
  diagnostic, restarts greetd once, and if the pipeline is still dead falls
  back to the existing text console path (`ncz-greeter-fallback`: message +
  `getty@tty1`). The gate is a oneshot: nothing re-triggers it, so it cannot
  loop.
* On a laptop, the first boot raises the backlight to >= 40 % of max (the
  DELL panel persisted at 342/4882 = 7 %, masking a partial success as black)
  via `ncz-backlight-default.service` (`Before=greetd.service`), marked once
  in `/var/lib/ncz` so a user-set value from a later boot is never
  clobbered; desktop/VM chassis and `max<16` dummies are skipped.

Do not "optimise" the splash/greetd ordering back into parallel: the bounded
cap exists precisely so the `After=` wait terminates, and the gate exists
precisely because a compositor that loses the DRM race will not recover on
its own.
