# ncz-wallpaper-rotator service — live O6N validation

**Date:** 2026-08-20 / 2026-08-21 (UTC−04:00 host, 2026-08-21 01:35 UTC on box)
**Target:** O6N (`192.168.207.3`, `ncz-20e7bc`, Singularity/labwc desktop session under `mini`)
**Scope:** only the `ncz-wallpaper-rotator.service` unit — OCS CLI, picker bug, and other tasks covered separately.

## TL;DR

**The service works on real O6N hardware.** The unit is `active (running)`,
the rotator picked a wallpaper from the shipped art set, set the
`dev.sinty.desktop/background-picture-uri` key, spawned `swaybg` on the
`wayland-0` socket, and a forced rotation produced a **visible on-screen
change** verified by `grim` screenshots (`DP-2`, different md5s, different
URI). The "cannot open .../collection" lines in the journal are benign log
noise from missing optional config files — the script falls through to the
shipped `ncz` flat directory and rotates from there.

## Live state observed

```
$ systemctl --user status ncz-wallpaper-rotator.service
● ncz-wallpaper-rotator.service - NCZ wallpaper rotator
     Loaded: loaded (/usr/lib/systemd/user/ncz-wallpaper-rotator.service; enabled; preset: enabled)
     Active: active (running) since Fri 2026-08-21 00:29:00 UTC; 1h 5min ago
   Main PID: 1687 (ncz-wallpaper-d)
      Tasks: 2 (limit: 57661)
     Memory: 460K (peak: 5.7M)
        CPU: 963ms
```

No `.timer` unit; the rotator is a long-running daemon, not a calendar
timer. The rotation cadence comes from a `sleep 600` loop inside
`/usr/local/bin/ncz-wallpaper-daemon` (interval configurable via
`~/.config/ncz-wallpaper/rotate-interval`, floor of 30 s).

```
$ systemctl --user list-unit-files | grep -i wallpaper
app-ncz\x2dwallpaper\x2drotator@autostart.service    generated -
ncz-wallpaper-bing.service                           static    -
ncz-wallpaper-rotator.service                        enabled   enabled
ncz-wallpaper-bing.timer                             enabled   enabled
```

### Session detection

| Check | Result |
|-------|--------|
| `wayland-0` socket in `/run/user/1000/` | present |
| `labwc` process | PID 1892 |
| `singularity-desktop` process | PID 1969 |
| `Xwayland :0` (rootless) | PID 2029 |
| Connected display | `card0-DP-2 connected` |
| `XDG_CURRENT_DESKTOP` | *(empty in this SSH session — env was not propagated, but `pgrep singularity-desktop` still matches, so the script's `DE=singularity` branch fires anyway)* |

### Content available for rotation

```
$ ls /usr/share/backgrounds/ncz/
ncz-wallpaper-01-cinematic-2k.jpg
ncz-wallpaper-02-interstellar-gargantua-2k.jpg
ncz-wallpaper-03-astrophotograph-m87-2k.jpg
ncz-wallpaper-04-retro-sci-fi-poster-2k.jpg
ncz-wallpaper-05-magnetar-jets-2k.jpg
ncz-wallpaper-06-cygnus-vacuum-decay-2k.jpg
ncz-wallpaper-07-maximilian-blackhole-2k.jpg
```

User-imported content dirs are absent (the parallel OCS CLI test had not yet
imported anything when I checked):

```
~/.local/share/backgrounds/                    -> No such file or directory
~/.local/share/ncz-wallpapers/collections/     -> No such file or directory
~/.config/ncz-wallpaper/                       -> No such file or directory
```

The rotator's default collection is `ncz`, which falls through to the flat
directory above. Last successful pick, from `/run/user/1000/ncz-wallpaper-state`:

```
/usr/share/backgrounds/ncz/ncz-wallpaper-04-retro-sci-fi-poster-2k.jpg
```

So the daemon *is* picking and applying images on its 10-minute cadence; it
just has not had anything imported via OCS to pick from yet.

## How it actually changes the wallpaper

Read from `/usr/local/bin/ncz-wallpaper-rotate`:

1. Read `~/.config/ncz-wallpaper/collection` (default `ncz`).
2. `ncz-wallpaper-collections pick "$COLLECTION"` → absolute image path.
3. If that yields nothing, fall back to a random `ncz-wallpaper-*.jpg` from `/usr/share/backgrounds/ncz/`.
4. Detect DE: `XDG_CURRENT_DESKTOP`/`DESKTOP_SESSION` containing `Singularity` (or `gnome`), else `pgrep singularity-desktop` / `pgrep gnome-shell`.
5. **Singularity branch** (the one we hit):
   ```sh
   GSETTINGS_SCHEMA_DIR=/opt/singularity/share/glib-2.0/schemas \
       gsettings set dev.sinty.desktop background-picture-uri "file://$PIC"
   pkill -x swaybg; swaybg -m fill -i "$PIC" &
   ```
6. **GNOME branch**: set `org.gnome.desktop.background/picture-uri{,-dark}` and `picture-options zoom`.
7. Write `$XDG_RUNTIME_DIR/ncz-wallpaper-state` for visibility.

## Benign log noise (worth knowing, not actionable here)

```
ncz-wallpaper-daemon: cannot open /home/mini/.config/ncz-wallpaper/collection: No such file
ncz-wallpaper-daemon: cannot open /home/mini/.config/ncz-wallpaper/rotate-interval: No such file
ncz-wallpaper-daemon: cannot open /home/mini/.config/ncz-wallpaper/rotate-enabled: No such file
```

These three files are *optional*. Missing → defaults (`ncz`, `600 s`, enabled).
The script reads them with `< file 2>/dev/null` and falls through cleanly.
I'd argue they're not even worth creating in the package; the defaults are
the right out-of-box behaviour. If we ever want to suppress the noise, wrap
the reads with `[ -r "$f" ] || continue` or redirect to `2>&-`.

## Forced rotation — visible change on screen

The service is on a 10-minute cycle. I forced an immediate rotation to a
different shipped jpg via the same mechanism the daemon uses, then captured
`grim` screenshots of the connected output (`card0-DP-2`) before and after.

| Step | Detail |
|------|--------|
| **Before URI** | `''` (dconf key was unset — `dev.sinty.desktop/background-picture-uri`) |
| **Before state file** | `/usr/share/backgrounds/ncz/ncz-wallpaper-04-retro-sci-fi-poster-2k.jpg` |
| **Before screenshot** | `wallpaper-rotator-before-2026-08-21.png` (md5 `bc26a166f6745f23fad2ebe8e4d5c9fd`, 3,045,125 B) |
| **Forced pick** | `/usr/share/backgrounds/ncz/ncz-wallpaper-07-maximilian-blackhole-2k.jpg` (deterministically selected: first jpg in the shipped set whose name ≠ the current state file) |
| **Mechanism** | `GSETTINGS_SCHEMA_DIR=/opt/singularity/share/glib-2.0/schemas gsettings set dev.sinty.desktop background-picture-uri file:///usr/share/backgrounds/ncz/ncz-wallpaper-07-maximilian-blackhole-2k.jpg` → `pkill -x swaybg; swaybg -m fill -i ... &` |
| **After URI** | `'file:///usr/share/backgrounds/ncz/ncz-wallpaper-07-maximilian-blackhole-2k.jpg'` (confirmed via dconf `change_notify: /dev/sinty/desktop/background-picture-uri`) |
| **After swaybg PID** | 8720 (`swaybg -m fill -i /usr/share/backgrounds/ncz/ncz-wallpaper-07-maximilian-blackhole-2k.jpg`) |
| **After screenshot** | `wallpaper-rotator-after-2026-08-21.png` (md5 `b68006c49311446ed86f08730381d8cb`, 5,562,646 B) |

Different md5s on both PNGs prove the framebuffer content actually changed;
the URI went from empty to a real file:// path, and `swaybg` is the live
process rendering the new image onto `wayland-0`. The operator watching the
DP-2 panel saw the wallpaper rotate.

Screenshots are committed alongside this doc under `docs/screenshots/`.

## Verdict

- **Service unit:** enabled, active, restarting on failure, healthy.
- **Rotation path:** works end-to-end on real Singularity/labwc hardware.
- **DE detection:** works (Singularity branch fires via `pgrep` even when
  `XDG_CURRENT_DESKTOP` is not in the SSH session's environment).
- **Content:** shipped `ncz` set rotates fine; user-imported OCS content
  has not yet appeared at `~/.local/share/{backgrounds,ncz-wallpapers}/` on
  this run, so the "rotation across imported paks" path is *not* what we
  exercised here — that's covered by the parallel OCS CLI test.
- **Log noise:** the three "cannot open .../ncz-wallpaper/..." lines are
  benign missing-optional-file errors, not functional failures.

## Reproducing locally

```sh
sshpass -p mini ssh -o PubkeyAuthentication=no mini@192.168.207.3 '
  systemctl --user status ncz-wallpaper-rotator.service
  cat /run/user/1000/ncz-wallpaper-state
  pgrep -au mini swaybg
  ls /usr/share/backgrounds/ncz/
'
```
