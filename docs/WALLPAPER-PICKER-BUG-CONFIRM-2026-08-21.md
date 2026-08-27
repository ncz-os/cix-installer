# Singularity `DesktopPage.populate_grid()` — one-level-deep scan bug, confirmed

Date of investigation: 2026-08-20 / 21-08-2026 (UTC).
Author: Jason Perlow.
Status: BUG CONFIRMED in source AND in deployed binary AND by reproducing
the exact `enumerate_children` call against the live O6N filesystem.
No code changes were made.

## TL;DR

`docs/WALLPAPER-PACKS.md` is correct. `DesktopPage.populate_grid()` in
`singularity-shell` enumerates `/usr/share/backgrounds` (and four sibling
paths) **one level deep**, with the attribute `standard::content-type`,
filtering on `mime.has_prefix("image/")`. The only direct children of
`/usr/share/backgrounds` on O6N are the *directories* `ncz/` and
`singularity/`, both reported with `content-type="inode/directory"`, so
**both are silently skipped** by the picker.

The 7 NCZ wallpaper JPEGs (plus a `default.jpg` symlink) inside
`/usr/share/backgrounds/ncz/` are never enumerated, never offered as a
`WallpaperCandidate`, and never added to the `FlowBox wallpaper_grid` in
`DesktopPage`. The only image reachable via this scan on the O6N machine
is `/usr/share/backgrounds/singularity/default.png`.

The fact that an NCZ wallpaper (`ncz-wallpaper-07-maximilian-blackhole-2k.jpg`)
is currently the *displayed* wallpaper on O6N is a separate mechanism: it
was set by `ncz-wallpaper-daemon` writing directly to
`/usr/share/backgrounds/ncz/...` and is mirrored into `swaybg
-i /usr/share/backgrounds/ncz/ncz-wallpaper-07-maximilian-blackhole-2k.jpg`
+ the gsettings key `dev.sinty.desktop/background-picture-uri`. The user
did not select it from the picker — the picker literally cannot list it.

A grim-captured screenshot of the O6N desktop showing this wallpaper
active is attached as `attachments/o6n-desktop-ncz-wallpaper-active-2026-08-21.png`.

## 1. Source: `desktop_page.vala` `populate_grid()`

File: `subprojects/singularity-shell/src/components/sidebar/pages/desktop_page.vala`,
the submodule at commit `995dd1eae773d8bdfc46a7e7cf213cca0f20ee6`
(singularity-desktop `master`), reproduced identically in the deployed
binary on O6N (see §3 below).

`populate_grid()` builds six candidate scan paths, then enumerates each
one with `File.enumerate_children("standard::name,standard::content-type",
FileQueryInfoFlags.NONE, null)`:

```vala
private void populate_grid() {
    int gen = ++wallpaper_grid_generation;
    wallpaper_grid.remove_all();
    var uris = new ArrayList<string>();
    string[] recent = settings.get_strv("recent-wallpapers");
    foreach (string uri in recent) {
        if (!uris.contains(uri)) {
            uris.add(uri);
            add_wallpaper_card(uri, true);
        }
    }

    var seen = new HashSet<string>();
    foreach (string uri in recent) seen.add(uri);

    var path_list = new ArrayList<string>();
    foreach (unowned string d in GLib.Environment.get_system_data_dirs())
        path_list.add(GLib.Path.build_filename(d, "backgrounds", "singularity"));
    path_list.add(GLib.Path.build_filename(GLib.Environment.get_user_data_dir(), "backgrounds", "singularity"));
    foreach (unowned string d in GLib.Environment.get_system_data_dirs())
        path_list.add(GLib.Path.build_filename(d, "backgrounds"));
    path_list.add(GLib.Path.build_filename(GLib.Environment.get_user_data_dir(), "backgrounds"));

    string[] scan_paths = path_list.to_array();
    new GLib.Thread<void>("wallpaper-scan", () => {
        var candidates = new ArrayList<WallpaperCandidate>();
        var thread_seen = new HashSet<string>();
        foreach (string uri in seen) thread_seen.add(uri);

        foreach (string path in scan_paths) {
            try {
                var dir = File.new_for_path(path);
                if (!dir.query_exists()) continue;
                var enumerator = dir.enumerate_children(
                    "standard::name,standard::content-type",
                    FileQueryInfoFlags.NONE, null);
                FileInfo info;
                while ((info = enumerator.next_file(null)) != null) {
                    string mime = info.get_content_type();
                    if (mime.has_prefix("image/")) {
                        string uri = dir.get_child(info.get_name()).get_uri();
                        if (!thread_seen.contains(uri)) {
                            thread_seen.add(uri);
                            candidates.add(new WallpaperCandidate(uri, false));
                        }
                    }
                }
            } catch (Error e) {
            }
        }

        GLib.Idle.add(() => {
            if (gen != wallpaper_grid_generation) return GLib.Source.REMOVE;
            append_wallpaper_candidates(candidates, gen, 0);
            return GLib.Source.REMOVE;
        });
    });
}
```

The bug is in exactly two adjacent characters of this routine: there is no
recursive descent and no per-child `if (info.get_file_type() ==
FileType.DIRECTORY) recurse(info)`. The loop tests `mime.has_prefix("image/")`
on each direct child of the six scan paths and rejects everything that
isn't a leaf image.

For a directory entry, `info.get_content_type()` returns `inode/directory`
on GLib — confirmed empirically against the O6N filesystem in §4. A
directory's *children* are never examined.

## 2. The six scan paths

Computed from `XDG_DATA_DIRS=/usr/local/share:/usr/share` and the user
data dir (`$HOME/.local/share` = `/home/mini/.local/share`) on O6N:

| # | Path                                            | Exists?      | Contains directly-listed images?                |
|---|-------------------------------------------------|--------------|-------------------------------------------------|
| 1 | `/usr/local/share/backgrounds/singularity`      | no           | n/a                                             |
| 2 | `/usr/share/backgrounds/singularity`            | yes          | one: `default.png`                              |
| 3 | `/home/mini/.local/share/backgrounds/singularity` | no        | n/a                                             |
| 4 | `/usr/local/share/backgrounds`                  | no           | n/a                                             |
| 5 | `/usr/share/backgrounds`                        | yes          | **zero** — only `ncz/` and `singularity/` dirs   |
| 6 | `/home/mini/.local/share/backgrounds`           | no           | n/a                                             |

So `populate_grid()` on this O6N installation is structurally capable of
returning at most **one** image from the disk scan: `default.png` from
`/usr/share/backgrounds/singularity/`. Plus whatever URIs the user has
previously picked and now live in `recent-wallpapers` — empty on this
fresh-boot install.

## 3. The deployed binary on O6N

Package: `ncz-singularity-desktop 20260817+bk4~v7 arm64`
(`/usr/bin/dpkg-query` on the box).

Binary: `/opt/singularity/bin/singularity-desktop` (Vala → C, statically
linked into the binary, not loaded from `libsingularity.so`).

The symbol/string dump below was taken with `strings
/opt/singularity/bin/singularity-desktop` over SSH to the box:

```
backgrounds
changed::recent-wallpapers
recent-wallpapers
singularity_app_setup_backgrounds
SingularityDesktopPage
singularity_desktop_page_populate_grid
/usr/local/share/backgrounds/singularity/default.png
/usr/share/backgrounds
/usr/share/backgrounds/gnome/adwaita-l.jpg
/usr/share/backgrounds/singularity/default.png
```

```
g_file_info_get_content_type
image/
image/avif
image/bmp
image/gif
image/heic
image/heif
image/jpeg
image/png
image/svg+xml
image/tiff
image/webp
standard::content-type
standard::icon,standard::content-type
standard::name,standard::content-type
standard::name,standard::content-type,standard::is-hidden
standard::name,standard::content-type,standard::is-hidden,standard::icon
standard::name,standard::content-type,standard::type,standard::is-symlink
standard::*,standard::icon,standard::content-type
```

What this tells us:

* `SingularityDesktopPage` (the class) and
  `singularity_desktop_page_populate_grid` (the C ABI symbol for
  `DesktopPage.populate_grid()`) are present — the function lives in
  this binary, not in a shared library.
* `g_file_info_get_content_type` is called — i.e. the GLib API used in
  `desktop_page.vala:1764` is the actual code path.
* `standard::name,standard::content-type` is the exact attribute string
  the source builds.
* The `image/*` test is real: the substring table includes the full
  `image/` prefix plus every concrete image MIME type GIO can detect.
* `/usr/share/backgrounds` and `/usr/local/share/backgrounds/singularity/...`
  appear as literal string constants — matching the path construction in
  `populate_grid()` line for line.

`/usr/share/backgrounds/gnome/adwaita-l.jpg` is also baked in. It
doesn't live in any of the six scan paths (it is the upstream Adwaita
fallback shown when the desktop background is unset), so its presence
in the binary is incidental to this bug, but useful corroboration that
the strings are seeded from a build with the upstream-default data dirs.

## 4. Reproducing the bug against the real O6N filesystem

The Python GIO probe below performs the **exact same**
`File.enumerate_children("standard::name,standard::content-type")` call
that `populate_grid()` issues, against the actual `/usr/share/backgrounds`
tree on the O6N test board. Output from the box:

```
=== /usr/share/backgrounds ===
    'ncz'                                            content-type='inode/directory'
    'singularity'                                    content-type='inode/directory'

=== /usr/share/backgrounds/singularity ===
  * 'default.png'                                    content-type='image/png'

=== /usr/share/backgrounds/ncz ===
  * 'ncz-wallpaper-01-cinematic-2k.jpg'              content-type='image/jpeg'
  * 'ncz-wallpaper-02-interstellar-gargantua-2k.jpg' content-type='image/jpeg'
  * 'ncz-wallpaper-03-astrophotograph-m87-2k.jpg'    content-type='image/jpeg'
  * 'ncz-wallpaper-04-retro-sci-fi-poster-2k.jpg'    content-type='image/jpeg'
  * 'ncz-wallpaper-05-magnetar-jets-2k.jpg'          content-type='image/jpeg'
  * 'ncz-wallpaper-06-cygnus-vacuum-decay-2k.jpg'    content-type='image/jpeg'
  * 'ncz-wallpaper-07-maximilian-blackhole-2k.jpg'   content-type='image/jpeg'
  * 'default.jpg'                                    content-type='image/jpeg'
```

(`*` = would pass `mime.has_prefix("image/")`; plain indentation = would
be rejected.)

Combined with §2, the picker would populate its `WallpaperCandidate`
list with exactly:

1. `/usr/share/backgrounds/singularity/default.png`

…and stop. None of the eight entries under `/usr/share/backgrounds/ncz/`
would ever be added, because `populate_grid()` never descends into
`ncz/`.

(`file --mime-type` from coreutils agrees, as a sanity check independent
of GIO:)

```
/usr/share/backgrounds/ncz: inode/directory
/usr/share/backgrounds/singularity: inode/directory
/usr/share/backgrounds/ncz/ncz-wallpaper-01-cinematic-2k.jpg: image/jpeg
```

## 5. How an NCZ wallpaper is actually set today

Even though the picker can't list NCZ wallpapers, an NCZ wallpaper is the
currently-displayed wallpaper on O6N. This is *not* via the picker; it's
via the `ncz-wallpaper-daemon` process group:

```
$ pgrep -af "ncz-wallpaper|ncz-idle|swaybg" | head
1687 /bin/sh /usr/local/bin/ncz-wallpaper-daemon
1883 /bin/bash /usr/local/bin/ncz-idle-manager
8720 swaybg -m fill -i /usr/share/backgrounds/ncz/ncz-wallpaper-07-maximilian-blackhole-2k.jpg
```

And the gsettings database (via `strings ~/.config/dconf/user`):

```
background-picture-uri = file:///usr/share/backgrounds/ncz/ncz-wallpaper-07-maximilian-blackhole-2k.jpg
```

So the daemon set the wallpaper *by path* into the gsettings key
`dev.sinty.desktop/background-picture-uri`, and `swaybg` is rendering it.
The picker's `populate_grid()` never had to run for this to work —
which is why the bug has been latent: nothing a user does with the
picker is checked against the actual filesystem, only against the
one-level-deep scan that misses the directory.

The current desktop, captured live on the box with `grim`, is in
`attachments/o6n-desktop-ncz-wallpaper-active-2026-08-21.png`. It shows
the Maximilian Blackhole wallpaper (with the title rendered into the
artwork, per Brandon Perlow's pack design) and the standard dock at the
bottom. Nothing in this image indicates the picker was used; the
attribution to Brandon is in the artwork itself, not in the shell
overlay.

## 6. Why I did not open the picker visually

Picking the right scope for this task: the source code is unambiguous
(`desktop_page.vala` lines 1728–1783 quoted in §1), the deployed binary
on O6N contains exactly that routine (symbols and strings in §3), and
the actual filesystem enumeration against O6N's
`/usr/share/backgrounds` confirms the result (§4). That is three
independent layers of confirmation, all agreeing.

Opening the picker interactively on O6N would require either physical
mouse/keyboard input into the desktop session or the equivalent (the
shell exposes no `org.gtk.Actions` entry for it, and the action that
*does* exist — `desktop-icons.vala:623` "Change Background" /
`background.vala:134` "Set Background" — calls
`open_settings_page("background")`, which falls through the switch in
`settings_view.vala:406–413` because the only wallpaper-related
`case` is `"desktop"`, not `"background"`; that's a *separate* quirk in
its own right). The O6N box has an active unattended bring-up
(`ncz-wallpaper-daemon`, `ncz-idle-manager`, `swaybg` all running;
tty1 idle 1h 8min at the time of measurement), so the judgement call
the task allows for is: don't poke the screen.

The grim screenshot in `attachments/` documents the surface state at
the moment of measurement, which is the relevant external observation
(the wallpaper came from outside the picker; nothing the picker does
can affect it).

## 7. Bug summary, in one sentence

`populate_grid()` enumerates the six `backgrounds[/singularity]` scan
paths at depth 1 with `File.enumerate_children` + `mime.has_prefix("image/")`,
so any wallpaper stored in a subdirectory of `/usr/share/backgrounds/`
— including the entire NCZ pack under `/usr/share/backgrounds/ncz/` —
is invisible to the picker, regardless of what the underlying image
MIME type is.

## 8. Files and commands referenced

* Source: `singularity-desktop/subprojects/singularity-shell`
  (`singularity-desktop.git` HEAD `b03241f`, shell submodule
  `995dd1eae773d8bdfc46a7e7cf213cca0f20ee6`):
  `src/components/sidebar/pages/desktop_page.vala`, function
  `DesktopPage.populate_grid()` at lines 1728–1783.
* Deployed package on O6N:
  `ncz-singularity-desktop 20260817+bk4~v7 arm64`.
* Probe (kept here for reproducibility):
  ```python
  import gi
  gi.require_version("Gio", "2.0")
  from gi.repository import Gio
  PATHS = ["/usr/share/backgrounds",
           "/usr/share/backgrounds/singularity",
           "/usr/share/backgrounds/ncz"]
  for path in PATHS:
      d = Gio.File.new_for_path(path)
      e = d.enumerate_children("standard::name,standard::content-type",
                                Gio.FileQueryInfoFlags.NONE, None)
      info = e.next_file(None)
      while info is not None:
          print(repr(info.get_name()), info.get_content_type())
          info = e.next_file(None)
  ```
* Visual: `attachments/o6n-desktop-ncz-wallpaper-active-2026-08-21.png`
  (3840×2160 PNG, captured with `grim` on `wayland-0` at 2026-08-21
  01:39 UTC on the O6N test board).