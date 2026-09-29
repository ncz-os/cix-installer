# Bing wallpapers: first-boot prefetch and preferred market

Date: 2026-09-29. Branch `feat/wallpapers-bing-prefetch-2026-09-29`; the
matching plugin branch is `feat/wallpapers-bing-market-prefetch-2026-09-29`
in singularity-plugins. Design and settings semantics for the plugin side are in
that branch's `docs/wallpapers-bing-market-prefetch.md`.

## Why the Bing source was empty after first boot

Measured on CHIMERA, MEDUSA and PEGASUS (journals of the old
`ncz-wallpaper-bing.timer`):

1. **The login fetch was delayed by the daily jitter.** The timer had
   `OnBootSec=2min` and `RandomizedDelaySec=30m`. The random delay applies to
   every trigger of a timer, so the "2 minute" run happened 14 min (CHIMERA:
   21:27:01 to 21:41:15), 14 min (MEDUSA: 22:00:51 to 22:14:44) and 26 min
   (PEGASUS: 21:45:14 to 22:11:24) after the user manager started. For that
   long `/var/cache/ncz-wallpapers/bing` was empty, the Bing collection had no
   images and the rotator's `pick` failed.
2. **No retry when the network was not up.** The service was a plain oneshot
   with `After=network-online.target`, which a user unit cannot order against.
   A failed run (offline install, Wi-Fi not yet associated) waited for the next
   daily slot, up to 24 hours.
3. **Nothing in the shell warmed the source.** The plugin only ran the helper
   from `choices()`/`browse()`, i.e. when the user opened Browse Online
   Sources; thumbnails were created by the first `list`, serially, inside its
   60 second limit. `~/.cache/singularity` and `~/.cache/ncz-wallpapers` stayed
   empty until then.
4. **The first fetch was heavy.** Every market was downloaded in UHD even when
   Bing served the same photo to several markets: 752 MB for 36 unique photos.
5. **A latent cache-ownership bug.** The greeter account (`_greetd`) has a user
   manager and the timer is enabled globally, so it could run the fetch before
   anyone logged in. Its files were created 0600 in directories it owned, which
   the real user could neither read nor replace. Reproduced on MEDUSA during
   this work (`PermissionError` while consolidating).

## What changed

`assets/wallpaper/ncz-wallpaper-bing` (installed by
`post-install/45-wallpaper-rotator.sh`; it used to be a heredoc there):

- `fetch [--if-stale] [--prefer M]`: preferred market first (newest batch is
  downloaded, consolidated and thumbnailed before the rest); a photo that
  another market already served (same `OHR.<Name>` within 4 days) is hard
  linked, so a full sync is about 128 MB and 5 seconds on this LAN;
  `--if-stale` exits at once when the last successful fetch is under 20 hours
  old; one run per user at a time; skips metered links (NetworkManager
  `Metered`) and low disk; exit 75 when the network is unreachable.
- `list --consolidated` and `consolidate` take `--prefer`; the combined view is
  rebuilt into a staging directory and swapped in; downloads are 0644, market
  directories 1777.
- Preferred market resolution: `--prefer`, `NCZ_BING_MARKETS`,
  `~/.config/singularity/wallpapers-bing/market`, the legacy
  `~/.config/ncz-wallpaper/bing-markets`, then the session locale
  (`LANGUAGE`, `LC_ALL`, `LC_MESSAGES`, `LANG`, `locale.conf`, then en-US). The
  literal `all` keeps the legacy "no preference" behavior.

User units (`ncz-wallpaper-bing.service`, `.timer`, `-daily.timer`):

- `fetch --if-stale` at every login (`OnStartupSec=15s`, no jitter) and daily
  (`OnCalendar=daily`, 30 min jitter, `Persistent=true`).
- `Restart=no` with `RestartForceExitStatus=75`, `RestartSec=30`,
  `RestartSteps=6`, `RestartMaxDelaySec=1h`: only "network unreachable"
  retries, with backoff from 30 seconds to an hour.
- `ConditionUser=!@system` so the greeter account never populates the cache.

Plugin patches (`assets/singularity/patches/singularity-plugins/`):
`0002-wallpapers-bing-preferred-market.patch` replaces
`0002-bing-preferred-region-picker.patch`, and
`0004-wallpapers-bing-prefetch.patch` is new. The plugin prefetches on
activation, which covers the login when the shell starts before the timer and
adds network-change and metered handling that a timer cannot; the timer covers
headless use and the rotator without the shell. Both call the same idempotent
helper, so they never duplicate work.

## Packaging

- Helper and units: `post-install/45-wallpaper-rotator.sh` installs
  `assets/wallpaper/ncz-wallpaper-bing` to `/usr/local/bin` and writes the
  units; `assets/wallpaper/` is already staged into the image by
  `build/build-squashfs-layers.sh` and `build/build-iso.sh`.
- Plugin: the two patches are applied by the existing overlay in
  `build/build-singularity.sh` (`/ncz-patches/singularity-plugins/`), so the
  next `ncz-singularity-desktop` build (both arches) ships the new
  `libwallpapers-bing.so`. Nothing else is needed. Checked: all four
  singularity-plugins patches apply in order on upstream `d255d47`.
- The old carried patch was tied to upstream PR singularity-plugins#3; that PR
  writes an NCZ-specific path and should be replaced, not merged.

## Verification (2026-09-29)

Plugin built on PROTEUS against the libsingularity installed on CHIMERA and
installed next to the other plugins. Cleared `/var/cache/ncz-wallpapers/bing`,
`~/.cache/ncz-wallpapers` and the plugin setting, restarted greetd and the user
manager, logged in through the greeter.

| Host | Result |
| --- | --- |
| MEDUSA | Login at 11:17:08; 103 MB and 8 thumbnails at +10 s, complete (128 MB, 36 unique photos, 36 thumbnails) at +15 s. With the timers disabled the plugin alone did the same. |
| CHIMERA | Complete 5 s after login. Helper wrapped to fail with 75 three times: plugin retried at +30 s, +60 s, +120 s and then populated. Service with a dead proxy: exit 75, auto-restart, recovered after the proxy was removed. |
| PEGASUS | Helper and service from a cleared cache: complete in 5 s, exit 0. (A full session restart was not possible while another test was using the desktop.) |

Preferred market on CHIMERA and MEDUSA: the row lists Automatic plus the 14
advertised markets; choosing Japan gave Japanese titles and credits in the
online browser (after its refresh button), Automatic gave English, Germany gave
German (`Aus Gletschern entstanden` for the en-US `Born of glaciers`).

## Open items

- The shell's online browser caches results for the session; a change to the
  row needs the browser's refresh button.
- Markets stay the 14 the helper advertises (no es-MX, en-NZ, etc.); adding
  markets is a one-line change to `MARKET_NAMES`.
- Several accounts on one machine share `/var/cache/ncz-wallpapers/bing`; the
  combined view can be replaced only by the account that owns it.
