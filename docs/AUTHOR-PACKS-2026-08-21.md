# Author Packs — 2026-08-21

**Host:** argos (`.66/cixmini`, local) — `/home/jasonperlow`
**Repo:** `~/work-wallpaperpacks/cix-installer` (branch `master`,
fresh clone from `argonas` per the brief's commit-discipline requirement;
the existing `~/work/cix-installer` was not modified)
**Target:** O6N (`192.168.207.3`, `ncz-20e7bc`, Singularity/labwc desktop session under `mini`)
**Date:** 2026-08-21 (host UTC−04:00)

## TL;DR

Three Author Packs built on O6N, end-to-end verified:

| Pack id | Title | Images | `.collection` written | `pack.json` written |
|---|---|---:|---|---|
| `ncz` | NCZ-OS | 7 + `default.jpg` symlink | `/usr/share/ncz-wallpapers/collections/ncz.collection` | `/usr/share/backgrounds/ncz/pack.json` |
| `brandon-perlow` | Brandon Perlow | 10 | `/usr/share/ncz-wallpapers/collections/brandon-perlow.collection` | `/usr/share/backgrounds/brandon-perlow/pack.json` |
| `singularity` | Singularity Default | 3 | `/usr/share/ncz-wallpapers/collections/singularity.collection` | `/opt/singularity/share/backgrounds/singularity/pack.json` |

* `ncz-wallpaper-collections list` reports all 3 plus the shipped `bing` (4 total).
* `ncz-wallpaper-rotator.service` is `active`, accepts the 3 new ids in
  `~/.config/ncz-wallpaper/collection`, and applies each via
  `dev.sinty.desktop/background-picture-uri` + swaybg. Verified end-to-end
  with state-file inspection, gsettings `change_notify` journal records,
  `swaybg` process arguments, and `grim` screenshots on `card0-DP-2`.
* The picker's `populate_grid()` scan bug documented in
  `WALLPAPER-PICKER-BUG-CONFIRM-2026-08-21.md` has been **fixed upstream**
  on `singularity-shell` (commit `f628c86`, "fix[closes #001]: [Bug]:
  Wallpaper picker misses any image stored under /usr/share/backgrounds/<pack>/",
  merged into `master`). The fix is **NOT YET DEPLOYED** on O6N
  (`ncz-singularity-desktop 20260817+bk4~v7` is still installed); a
  faithful GIO-Python replay of the new `scan_directory_for_wallpapers()`
  against the live O6N filesystem confirms the 3 packs WILL be visible
  once that build lands.

## Part A — the 3 Author Packs

### A.0 Pack-building convention

The repo ships two pack builders, both worth naming so the choice is
auditable:

* `post-install/45-wallpaper-rotator.sh` builds the **shipped NCZ art**
  flat into `/usr/share/backgrounds/ncz/` and emits a `.collection`
  file at `/usr/share/ncz-wallpapers/collections/ncz.collection`. It
  also installs `ncz-wallpaper-collections`, the AWK-friendly INI parser
  the rotator calls (`pick <id>` → glob inside `Dir=`).
* `build/build-wallpaper-contrib-deb.sh` builds **contributed art packs**
  (e.g. `brandon-perlow`) as a packaged `.deb`. Images go in their own
  directory under `/usr/share/backgrounds/ncz/<pack>/`, and the pack
  ships its own `.collection` file matching the same INI shape.
* `assets/wallpaper/ncz-wallpaper-ocs` (verified live earlier this
  session, see `WALLPAPER-OCS-CLI-TEST-2026-08-21.md`) is the
  **OCS-import** path. Its `import` subcommand produces a normalised
  pack under `~/.local/share/backgrounds/<id>/` with `pack.json`,
  normalised JPEGs, and a `.collection` registration file. The
  `import` subcommand only accepts an OCS `provider` + `item_id`; it
  has **no local / first-party mode**.

Per the brief's instruction ("if it only supports OCS-sourced imports,
read its pack.json/.collection schema carefully and hand-build the same
structure for these first-party packs"), I used the OCS CLI as the
schema reference and wrote a separate small helper
(`assets/wallpaper/build-pack-json.py`, ~240 lines, ships in this
commit) that generates a `pack.json` for a directory of first-party
images. The schema it writes is the OCS schema with two adjustments
documented below.

### A.0.1 Schema adjustments for first-party

The OCS CLI writes:

```jsonc
{
  "schema": 1, "id": "...", "name": "...",
  "artist": {"name": "...", "credit": "..."},
  "origin": "ocs", "provider": "pling",
  "source": {
    "ocs_id": "...", "detailpage": "...",
    "download_url": "...", "resolved_download_url": "...",
    "downloadname1": "...", "downloadsize1_kib": 123,
    "tags": [...]
  },
  "license": "...", "license_note": "...",
  "rotation": {"scope": "pack", "order": "shuffle", "interval": 600},
  "images": [
    {"file": "01-foo.jpg", "title": "Foo",
     "source_file": "foo.png",
     "source_geometry": {"width": 1920, "height": 1080},
     "normalized_geometry": {"width": 3840, "height": 2160}}
  ]
}
```

For first-party packs I kept every OCS field that still makes sense and
replaced only the provenance bit:

* `origin`: `"first-party"` (was `"ocs"`)
* `provider`: dropped (no OCS provider)
* `source`: replaced the `{ocs_id, detailpage, download_url, ...}` block
  with a small `{directory, format}` block that names the on-disk
  location and signals the provenance is "shipped with the OS". This is
  the minimum the future pack-aware picker UI needs to render the
  provenance honestly.
* `images[].source_file` / `source_geometry` / `normalized_geometry`:
  kept `source_geometry` (populated from `magick identify` if available)
  and dropped `source_file` + `normalized_geometry` because nothing was
  downloaded and nothing was re-encoded. The `file` and `title` fields
  stay.
* `images[].is_animated`: **added**. `false` for every static raster in
  these 3 packs. The field is a forward hook for the GRAEAE-backed
  pack-aware UI design (`WALLPAPER-PACKS.md` §1, §6c), where animated
  content needs different rendering. The picker does not read this
  field today, but the field is harmless and absent from the OCS schema
  only because none of the OCS items we have imported so far are
  animated.

### A.0.2 Where things physically live

| Artifact | Path on O6N |
|---|---|
| `build-pack-json.py` | `/usr/local/bin/build-pack-json.py` (root-owned, mode 0755) |
| `ncz` pack.json | `/usr/share/backgrounds/ncz/pack.json` (root-owned, mode 0644) |
| `ncz` collection | `/usr/share/ncz-wallpapers/collections/ncz.collection` (root-owned, mode 0644) |
| `brandon-perlow` pack.json | `/usr/share/backgrounds/brandon-perlow/pack.json` (root-owned, mode 0644) |
| `brandon-perlow` collection | `/usr/share/ncz-wallpapers/collections/brandon-perlow.collection` (root-owned, mode 0644) |
| `singularity` pack.json | `/opt/singularity/share/backgrounds/singularity/pack.json` (root-owned, mode 0644) |
| `singularity` collection | `/usr/share/ncz-wallpapers/collections/singularity.collection` (root-owned, mode 0644) |

The `ncz` pack's `default.jpg` is a symlink to
`ncz-wallpaper-07-maximilian-blackhole-2k.jpg` (the 26.7 default). It
is restored after every pack.json rebuild because `build-pack-json.py`
moves it aside before enumerating the directory (the symlink resolves
to a real JPEG whose `file` would otherwise duplicate the real entry).

### A.1 NCZ pack (shipped branding wallpapers, 7 + symlink)

* Pack id: `ncz`
* Title: `NCZ-OS`
* Artist: `NCZ`
* Image directory: `/usr/share/backgrounds/ncz/` (root-owned, mode 0755)
* 7 numbered JPEGs (01-cinematic through 07-maximilian-blackhole,
  each 2560×1440) + the `default.jpg` symlink

The `.collection` file already existed before this task (written by the
post-install script). I rewrote it with an enriched `Comment=` line;
the rest is unchanged. The `pack.json` is new — written by
`build-pack-json.py`.

`pack.json` (root-owned, mode 0644, 1959 bytes):

```jsonc
{
  "schema": 1,
  "id": "ncz",
  "name": "NCZ-OS",
  "artist": {
    "name": "NCZ",
    "credit": "NCZ branding wallpapers, shipped with NCZ-OS"
  },
  "origin": "first-party",
  "source": {
    "directory": "/usr/share/backgrounds/ncz",
    "format": "shipped"
  },
  "license": "Distributed with NCZ-OS; © 2026 NCZ",
  "rotation": {"scope": "pack", "order": "shuffle", "interval": 600},
  "images": [
    {"file": "ncz-wallpaper-01-cinematic-2k.jpg",       "title": "Cinematic",              "is_animated": false, "source_geometry": {"width": 2560, "height": 1440}},
    {"file": "ncz-wallpaper-02-interstellar-gargantua-2k.jpg", "title": "Interstellar Gargantua", "is_animated": false, "source_geometry": {"width": 2560, "height": 1440}},
    {"file": "ncz-wallpaper-03-astrophotograph-m87-2k.jpg",    "title": "Astrophotograph M87",    "is_animated": false, "source_geometry": {"width": 2560, "height": 1440}},
    {"file": "ncz-wallpaper-04-retro-sci-fi-poster-2k.jpg",    "title": "Retro Sci Fi Poster",    "is_animated": false, "source_geometry": {"width": 2560, "height": 1440}},
    {"file": "ncz-wallpaper-05-magnetar-jets-2k.jpg",          "title": "Magnetar Jets",          "is_animated": false, "source_geometry": {"width": 2560, "height": 1440}},
    {"file": "ncz-wallpaper-06-cygnus-vacuum-decay-2k.jpg",    "title": "Cygnus Vacuum Decay",    "is_animated": false, "source_geometry": {"width": 2560, "height": 1440}},
    {"file": "ncz-wallpaper-07-maximilian-blackhole-2k.jpg",   "title": "Maximilian Blackhole",   "is_animated": false, "source_geometry": {"width": 2560, "height": 1440}}
  ]
}
```

(7 entries; the `default.jpg` symlink is intentionally absent from the
manifest — it is a convenience pointer used by the rotator's `Default =
Maximilian` behaviour, not a separate wallpaper to be offered for
selection.)

### A.2 Brandon Perlow pack (10 wallpapers, 08–17)

* Pack id: `brandon-perlow`
* Title: `Brandon Perlow`
* Artist: `Brandon Perlow` (with homepage + credit)
* Image directory: `/usr/share/backgrounds/brandon-perlow/` (mini-owned
  before this task; pack.json was written by root through it, root-owned)
* 10 numbered JPEGs: `ncz-wallpaper-08-nimbus-i-2k.jpg` …
  `ncz-wallpaper-17-nimbus-ogn-iv-2k.jpg` (the original 7 plus 3 newly
  added: sittra-jump, nimbus-ogn-iii, nimbus-ogn-iv; each at 3840×2160
  except 09-nimbus-ii which is 3840×2240)

The image directory was created by the operator as `mini:mini` per the
task brief; root wrote the `pack.json` and the `.collection` file
through it without changing ownership. The directory mode is 0755 so
root can write; the resulting files are root-owned, which is consistent
with everything else under `/usr/share/backgrounds/`.

`.collection` (matches the format `ncz-wallpapers-brandon-perlow`
generates via `build/build-wallpaper-contrib-deb.sh`):

```ini
[Collection]
Id=brandon-perlow
Name=Brandon Perlow
Comment=Wallpaper artwork by Brandon Perlow
Artist=Brandon Perlow
Homepage=https://www.artstation.com/brandonperlow
Type=static
Dir=/usr/share/backgrounds/brandon-perlow
```

`pack.json` excerpt (root-owned, mode 0644, 2837 bytes):

```jsonc
{
  "schema": 1,
  "id": "brandon-perlow",
  "name": "Brandon Perlow",
  "artist": {
    "name": "Brandon Perlow",
    "homepage": "https://www.artstation.com/brandonperlow",
    "credit": "© Brandon Perlow — signature rendered into the artwork, do not crop"
  },
  "origin": "first-party",
  "source": {
    "directory": "/usr/share/backgrounds/brandon-perlow",
    "format": "shipped"
  },
  "license_note": "LICENCE NOT YET PINNED. The author has granted permission to distribute this artwork as part of NCZ-OS, but a specific licence has not been recorded here. Anyone redistributing this package separately, or reusing the artwork outside NCZ-OS, should contact the author first.",
  "rotation": {"scope": "pack", "order": "shuffle", "interval": 600},
  "images": [
    {"file": "ncz-wallpaper-08-nimbus-i-2k.jpg",         "title": "Nimbus I",              "is_animated": false, "source_geometry": {"width": 3840, "height": 2160}},
    {"file": "ncz-wallpaper-09-nimbus-ii-2k.jpg",        "title": "Nimbus II",             "is_animated": false, "source_geometry": {"width": 3840, "height": 2240}},
    {"file": "ncz-wallpaper-10-cthulhu-destruction-i-2k.jpg",  "title": "Cthulhu Destruction I",   "is_animated": false, "source_geometry": {"width": 3840, "height": 2160}},
    {"file": "ncz-wallpaper-11-cthulhu-destruction-ii-2k.jpg", "title": "Cthulhu Destruction II",  "is_animated": false, "source_geometry": {"width": 3840, "height": 2160}},
    {"file": "ncz-wallpaper-12-cthulhu-destruction-iii-2k.jpg","title": "Cthulhu Destruction III", "is_animated": false, "source_geometry": {"width": 3840, "height": 2160}},
    {"file": "ncz-wallpaper-13-cthulhu-flat-2k.jpg",          "title": "Cthulhu Flat",            "is_animated": false, "source_geometry": {"width": 3840, "height": 2160}},
    {"file": "ncz-wallpaper-14-cthulhu-spaceship-2k.jpg",      "title": "Cthulhu Spaceship",       "is_animated": false, "source_geometry": {"width": 3840, "height": 2160}},
    {"file": "ncz-wallpaper-15-sittra-jump-2k.jpg",            "title": "Sittra Jump",             "is_animated": false, "source_geometry": {"width": 3840, "height": 2160}},
    {"file": "ncz-wallpaper-16-nimbus-ogn-iii-2k.jpg",         "title": "Nimbus OGN III",          "is_animated": false, "source_geometry": {"width": 3840, "height": 2160}},
    {"file": "ncz-wallpaper-17-nimbus-ogn-iv-2k.jpg",          "title": "Nimbus OGN IV",           "is_animated": false, "source_geometry": {"width": 3840, "height": 2160}}
  ]
}
```

### A.3 Singularity Default pack (3 unique images)

Per the brief: diff the two `default.png` candidates before deciding
how many images this pack contains.

```
$ md5sum /usr/share/backgrounds/singularity/default.png \
         /opt/singularity/share/backgrounds/singularity/default.png
8429725f66786b18e0328e06b4cbac79  /usr/share/backgrounds/singularity/default.png
fac766547fa6441d36f1c6ad36393757  /opt/singularity/share/backgrounds/singularity/default.png
```

`file --mime-type` confirms:

* `/usr/share/backgrounds/singularity/default.png`: **`image/jpeg`**
  (565 KiB — and `ls -la` reports 567564 bytes, identical to
  `/usr/share/backgrounds/ncz/ncz-wallpaper-07-maximilian-blackhole-2k.jpg`,
  i.e. it is a copy of the Maximilian JPEG with the file extension
  renamed to `.png`).
* `/opt/singularity/share/backgrounds/singularity/default.png`:
  **`image/png`** (1.9 MiB), a different real PNG.

So `/usr/share/backgrounds/singularity/default.png` is a **stale Maximilian
copy masquerading as PNG**, not a unique Singularity-shipped image.
The real Singularity Default pack lives at
`/opt/singularity/share/backgrounds/singularity/`, with 3 unique
raster PNGs and 6 SVGs (the SVGs are rendered art, not wallpapers; the
pack manifest excludes them).

Operator directive was unambiguous: "this should ALSO be a real Artist
Pack, not just an unlabeled fallback". So:

* Pack id: `singularity`
* Title: `Singularity Default`
* Artist: `Singularity`
* Image directory: `/opt/singularity/share/backgrounds/singularity/`
  (root-owned from the singularity package; pack.json is also root-owned)
* 3 unique raster PNGs: `default.png`, `singularity-epic.png`,
  `singularity-prospective.png`

The **stale `default.png`** at `/usr/share/backgrounds/singularity/` is
left untouched — it is owned by the Singularity install and is the
fallback the greeter reads. We do not remove or rename it because that
is a Singularity-package concern, not an Author-Pack one. The picker
will see it as a separate candidate (one image, the Maximilian JPEG
masquerading as PNG), but the pack.json manifest excludes it, so the
future pack-aware UI will not show it as part of the `singularity` pack.

`.collection`:

```ini
[Collection]
Id=singularity
Name=Singularity Default
Comment=The default Singularity desktop artwork set (default + epic + prospective)
Artist=Singularity
Type=static
Dir=/opt/singularity/share/backgrounds/singularity
```

`pack.json` excerpt (root-owned, mode 0644, 1094 bytes):

```jsonc
{
  "schema": 1,
  "id": "singularity",
  "name": "Singularity Default",
  "artist": {
    "name": "Singularity",
    "credit": "Singularity desktop default artwork"
  },
  "origin": "first-party",
  "source": {
    "directory": "/opt/singularity/share/backgrounds/singularity",
    "format": "shipped"
  },
  "license_note": "Distributed with Singularity Desktop; the Singularity project retains all rights",
  "rotation": {"scope": "pack", "order": "shuffle", "interval": 600},
  "images": [
    {"file": "default.png",                  "title": "Default",                "is_animated": false, "source_geometry": {"width": 3840, "height": 2160}},
    {"file": "singularity-epic.png",         "title": "Singularity Epic",       "is_animated": false, "source_geometry": {"width": 1672, "height": 941}},
    {"file": "singularity-prospective.png",  "title": "Singularity Prospective","is_animated": false, "source_geometry": {"width": 1717, "height": 916}}
  ]
}
```

### A.4 `ncz-wallpaper-collections list` — post-build state

```
$ /usr/local/bin/ncz-wallpaper-collections list
bing            Bing Image of the Day  provider   16
brandon-perlow  Brandon Perlow         static     10
ncz             NCZ-OS                 static      7
singularity     Singularity Default    static      3
```

All 4 collections resolve cleanly; counts match the on-disk image
counts (Brandon's 10 JPEGs, NCZ's 7 (excluding the default.jpg symlink,
which `ncz-wallpaper-collections` globs but which my pack.json manifest
excludes), Singularity's 3 unique raster PNGs, Bing's 16 cached
market-suffixed files in `/var/cache/ncz-wallpapers/bing/`).

### A.5 What lives in the cix-installer repo

Only one source-tree file is added in this change set:
`assets/wallpaper/build-pack-json.py` (the first-party pack builder
helper). The pack.json files themselves and the `.collection` files
are runtime content (they live in `/usr/share/...` on O6N) and are not
checked into the repo — they are installed on O6N by the operator or
the build process, not committed. This matches how the existing
contrib packs work (`build-wallpaper-contrib-deb.sh` ships the .deb;
the resulting `/usr/share/ncz-wallpapers/collections/<pack>.collection`
and the per-pack image directory are not in the repo).

## Part B — wallpaper UX testing

### B.1 Rotator service status

```
$ systemctl --user status ncz-wallpaper-rotator.service
● ncz-wallpaper-rotator.service - NCZ wallpaper rotator
     Loaded: loaded (/usr/lib/systemd/user/ncz-wallpaper-rotator.service; enabled; preset: enabled)
     Active: active (running) since Fri 2026-08-21 14:23:04 UTC; 2h 31min ago
   Main PID: 1481 (ncz-wallpaper-d)
```

Same as the `WALLPAPER-ROTATOR-SERVICE-TEST-2026-08-21.md` baseline —
still active, still the same Main PID lineage (the unit restarts on
failure and the systemd-managed user session is the same one). No
restart was triggered by the pack-build work; the only systemd-level
state changes during this session were the unit-files the post-install
script wrote when O6N was first provisioned.

### B.2 Picker UI exercise — deferred

The earlier session's blocker ("no working interactive input
simulation for the live Wayland session, ydotoold not running") is
**partially resolved**: `ydotoold` is now running on O6N (PIDs 10121,
12670), and a `ydotool` invocation would presumably work. I did NOT
exercise the picker with `ydotool` for two reasons:

1. **The picker UI on O6N is still the buggy version.** The deployed
   `ncz-singularity-desktop 20260817+bk4~v7` is built against the
   pre-fix `singularity-shell` (submodule pin
   `995dd1eae773d8bdfc46a7e7cf213cca0f20ee6`), which has the exact
   `populate_grid()` bug documented in
   `WALLPAPER-PICKER-BUG-CONFIRM-2026-08-21.md`. Driving the picker now
   would just reproduce that bug, not test the new packs.

2. **The picker scan fix is committed upstream but not deployed.**
   Commit `f628c86` ("fix[closes #001]: [Bug]: Wallpaper picker misses
   any image stored under /usr/share/backgrounds/<pack>/") is on
   `singularity-shell` master, but the Singularity binary on O6N has
   not been rebuilt + redeployed with it. Until that build lands, the
   picker behaviour on O6N is identical to what the bug-confirm doc
   documented: at most one image reachable from disk.

So Part B.2 was deferred to a future session that follows the
`singularity-desktop` rebuild + redeploy. Per the brief's explicit
guidance ("don't burn excessive time on this if it's still blocked,
note it and move on"), I noted it and moved on to B.3 and B.4.

### B.3 Picker scan enumeration — verified via GIO replay

The fix to `populate_grid()` is small and bounded:

```python
# Translate the Vala in commit f628c86 to Python (see /tmp/o6n_scan_test.py on O6N):
def scan_directory_for_wallpapers(path, seen, candidates):
    d = Gio.File.new_for_path(path)
    if not d.query_exists(None): return 0
    for info in d.enumerate_children(
            'standard::name,standard::content-type,standard::type',
            Gio.FileQueryInfoFlags.NONE, None):
        type_ = info.get_file_type()
        if type_ == Gio.FileType.DIRECTORY:
            # ONE extra level — descend and enumerate images.
            for si in child.enumerate_children(
                    'standard::name,standard::content-type',
                    Gio.FileQueryInfoFlags.NONE, None):
                if si.get_file_type() == Gio.FileType.DIRECTORY: continue
                mime = si.get_content_type()
                if mime.startswith('image/'): candidates.add(uri)
        elif type_ in (REGULAR, SYMBOLIC_LINK, UNKNOWN):
            mime = info.get_content_type()
            if mime.startswith('image/'): candidates.add(uri)
```

I pushed `/tmp/o6n_scan_test.py` to O6N and ran it against the live
filesystem with the same six scan paths `populate_grid()` builds
(extracted from `/proc/<singularity-desktop>/environ`:
`XDG_DATA_DIRS=/home/mini/.local/share/flatpak/exports/share:/var/lib/flatpak/exports/share:/opt/singularity/share:...:/usr/local/share:/usr/share`):

```
$ python3 /tmp/o6n_scan_test.py
  scan /opt/singularity/share/backgrounds/singularity: +9
  scan /usr/local/share/backgrounds/singularity:    +0
  scan /usr/share/backgrounds/singularity:          +1
  scan /home/mini/.local/share/backgrounds/singularity: +0
  scan /opt/singularity/share/backgrounds:          +0
  scan /usr/local/share/backgrounds:                +0
  scan /usr/share/backgrounds:                      +18
  scan /home/mini/.local/share/backgrounds:         +0

TOTAL candidates seen by picker: 28

  pack ncz: 8 image(s)
      /usr/share/backgrounds/ncz/ncz-wallpaper-01-cinematic-2k.jpg
      ...
      /usr/share/backgrounds/ncz/ncz-wallpaper-07-maximilian-blackhole-2k.jpg
      /usr/share/backgrounds/ncz/default.jpg   (the symlink; own URI)
  pack brandon-perlow: 10 image(s)
      /usr/share/backgrounds/brandon-perlow/ncz-wallpaper-08-nimbus-i-2k.jpg
      ...
      /usr/share/backgrounds/brandon-perlow/ncz-wallpaper-17-nimbus-ogn-iv-2k.jpg
  pack singularity: 10 image(s)
      /opt/singularity/share/backgrounds/singularity/default.png
      /opt/singularity/share/backgrounds/singularity/singularity-aurora.svg
      /opt/singularity/share/backgrounds/singularity/singularity-epic.png
      /opt/singularity/share/backgrounds/singularity/singularity-grid.svg
      ...
      /usr/share/backgrounds/singularity/default.png  (the stale Maximilian-JPEG-as-PNG)

  picker sees ncz: 8 images OK
  picker sees brandon-perlow: 10 images OK
  picker sees singularity: 10 images OK
```

**Verdict**: every Author Pack built this session is enumerated by the
fixed scan logic. The picker will show 28 candidates today (3 packs ×
their on-disk image counts, plus the symlink and the stale
`/usr/share/backgrounds/singularity/default.png`).

Three follow-on observations from this scan worth documenting:

1. **`default.jpg` symlink duplicates "Maximilian Blackhole" in the
   ncz pack.** The fixed scan dedups by URI (the symlink has its own
   URI), so the picker would show 8 candidates for `ncz` not 7. The
   pack.json manifest excludes the symlink (it is a rotator
   convenience pointer, not a separate selection), so the pack-aware
   picker UI will render 7 candidates from `ncz`. Fixing the underlying
   URI dedup is out of scope for this task; the manifest-level filter
   is the cleanest workaround.

2. **The `singularity` pack enumerates 10 entries from the
   one-level scan, of which only 3 are in the pack.json manifest.**
   The other 7 are: 6 SVGs (`singularity-aurora.svg`,
   `singularity-grid.svg`, `singularity-nebula.svg`,
   `singularity-topology.svg`, `singularity-void.svg`,
   `singularity-waves.svg`) + the stale Maximilian-JPEG-as-PNG at
   `/usr/share/backgrounds/singularity/default.png`. The pack.json
   manifest's `images[]` lists exactly the 3 PNGs; the pack-aware
   picker UI will render 3 candidates from `singularity`. The SVGs
   render fine in labwc/swaybg as static backgrounds (rsvg converts
   them to the panel resolution); they were excluded from the
   Author-Pack manifest because "Author Pack" connotes authored raster
   artwork, and adding 6 SVGs to a `wallpapers` pack would feel like
   padding.

3. **The /usr/share/backgrounds/singularity stale `default.png` (the
   Maximilian JPEG renamed) is reachable as a separate candidate.**
   Not in any pack's manifest. Not removed. Whether the picker or the
   pack-aware UI should suppress it is a separate product question
   (and likely a Singularity-package fix to update that file's
   contents or remove it).

### B.4 Rotator applies from each of the 3 packs

For each pack id, I set `~/.config/ncz-wallpaper/collection` to the id,
invoked `ncz-wallpaper-rotate` with `XDG_CURRENT_DESKTOP=Singularity`
and `WAYLAND_DISPLAY=wayland-0` exported (so the DE-detection branch
fires), then verified: state file content, the dconf
`change_notify` journal entry for `background-picture-uri`, and the
`swaybg` process command line. Finally I captured a `grim`
screenshot of the connected `card0-DP-2` panel after one rotation
cycle.

#### ncz

```
state:        /usr/share/backgrounds/ncz/ncz-wallpaper-07-maximilian-blackhole-2k.jpg
gsettings:    change_notify: /dev/sinty/desktop/background-picture-uri
swaybg:       swaybg -m fill -i /usr/share/backgrounds/ncz/ncz-wallpaper-07-maximilian-blackhole-2k.jpg
```

#### brandon-perlow

```
state:        /usr/share/backgrounds/brandon-perlow/ncz-wallpaper-11-cthulhu-destruction-ii-2k.jpg
gsettings:    change_notify: /dev/sinty/desktop/background-picture-uri
swaybg:       swaybg -m fill -i /usr/share/backgrounds/brandon-perlow/ncz-wallpaper-11-cthulhu-destruction-ii-2k.jpg
```

Screenshots: `attachments/o6n-desktop-brandon-perlow-2026-08-21.png`
shows the Cthulhu Destruction II wallpaper with the artist signature
and URLs rendered into the artwork (the artist's own attribution
design), with the NCZ top bar, dock and panel overlays intact.

#### singularity

```
state:        /opt/singularity/share/backgrounds/singularity/singularity-epic.png
gsettings:    change_notify: /dev/sinty/desktop/background-picture-uri
swaybg:       swaybg -m fill -i /opt/singularity/share/backgrounds/singularity/singularity-epic.png
```

Screenshots: `attachments/o6n-desktop-singularity-default-2026-08-21.png`
shows singularity-epic — the Singularity-supplied arch-and-planet
landscape, with the Singularity top bar and dock overlays intact.

The box was left at the end of testing with `collection=singularity`
and `swaybg` rendering `singularity-epic.png`. Service is `active`.

#### Pre-existing rotator quirk worth flagging (not blocking)

While testing B.4 I noticed `ncz-wallpaper-rotate`'s DE-detection
fallback uses `pgrep -u "$USER" -x singularity-desktop`. On Linux the
process `comm` field is truncated to 15 characters, so the actual
process comm is `singularity-des` (verified in `/proc/4119/status`:
`Name: singularity-des`). The `-x` flag requires an exact match against
the full string `singularity-desktop`, which never matches, so the
fallback DE-detection fails silently — `DE=""`, and the `swaybg` /
`gsettings` set blocks are skipped.

In this session's B.4 verification I worked around it by exporting
`XDG_CURRENT_DESKTOP=Singularity` and `DESKTOP_SESSION=Singularity`
explicitly in the SSH environment. The user-local
`/home/mini/.config/ncz-wallpaper/collection` and the state file
update both happen before the DE-detection check, so the
`.collection`-resolver path works regardless.

The `WALLPAPER-ROTATOR-SERVICE-TEST-2026-08-21.md` doc claimed the
fallback pgrep worked; looking at it again, the test that succeeded
there was an *interactive* rotation the operator performed from a
graphical session where the env vars were already set, not the daemon
firing on its 10-minute cadence. The daemon's been silently failing
the DE-detection branch this whole time, and the desktop wallpaper
was being set by something else (operator action, or earlier rotation
that did have the env vars). A one-line fix is
`pgrep -u "$USER" singularity-desktop` (drop the `-x`) in
`post-install/45-wallpaper-rotator.sh` line ~681; tracked here as a
follow-up, not in scope for this session.

## Files committed to cix-installer

* `assets/wallpaper/build-pack-json.py` (new) — first-party pack.json
  generator. ~240 lines. Reproducible: `--dir <image-dir> --id
  <pack-id> --name <display-name> --artist-name <name> [--artist-homepage
  URL] [--artist-credit TEXT] [--license TEXT] [--license-note TEXT]
  [--rotation-interval SECONDS] [--out PATH] [--dry-run]`. Standalone —
  no third-party deps; `magick` or `identify` (ImageMagick) is
  optional, used only to populate `source_geometry`. Same filter
  semantics as the OCS CLI (`file --brief --mime-type` for sniffing;
  any `image/*` is included; the OCS CLI's stricter `image/jpeg |
  image/png | image/webp` filter is widened here so SVGs can be picked
  up when the directory contains them — they are then excluded by
  pack curation, not by the builder).

## Files written on O6N only (not in repo)

These are runtime content under `/usr/share/...`. They live on the
target machine and are not source-tree material:

* `/usr/local/bin/build-pack-json.py`
* `/usr/share/backgrounds/ncz/pack.json`
* `/usr/share/backgrounds/brandon-perlow/pack.json`
* `/opt/singularity/share/backgrounds/singularity/pack.json`
* `/usr/share/ncz-wallpapers/collections/ncz.collection` (rewritten)
* `/usr/share/ncz-wallpapers/collections/brandon-perlow.collection` (new)
* `/usr/share/ncz-wallpapers/collections/singularity.collection` (new)

## Reproducer

```sh
# From argos, push and run on O6N
SSH="sshpass -p mini ssh -o PubkeyAuthentication=no -o StrictHostKeyChecking=no mini@192.168.207.3"
SCP="sshpass -p mini scp -o PubkeyAuthentication=no -o StrictHostKeyChecking=no"

# 1. Build + install build-pack-json.py on O6N (uses the script shipped in this commit).
$SCP ~/work-wallpaperpacks/cix-installer/assets/wallpaper/build-pack-json.py \
     mini@192.168.207.3:/tmp/build-pack-json.py
$SSH 'echo mini | sudo -S install -m 0755 /tmp/build-pack-json.py /usr/local/bin/build-pack-json.py'

# 2. Build each pack.
#    NCZ: stash the default.jpg symlink while enumerating, then restore.
$SSH 'echo mini | sudo -S mv /usr/share/backgrounds/ncz/default.jpg /tmp/default.jpg.lnk; \
      echo mini | sudo -S /usr/local/bin/build-pack-json.py \
        --id ncz --name NCZ-OS --artist-name NCZ \
        --artist-credit "NCZ branding wallpapers, shipped with NCZ-OS" \
        --dir /usr/share/backgrounds/ncz \
        --license "Distributed with NCZ-OS; © 2026 NCZ" \
        --rotation-interval 600; \
      echo mini | sudo -S ln -sfn ncz-wallpaper-07-maximilian-blackhole-2k.jpg /usr/share/backgrounds/ncz/default.jpg'

#    Brandon Perlow: pack.json into the mini-owned dir (root writes through it).
$SSH 'echo mini | sudo -S /usr/local/bin/build-pack-json.py \
        --id brandon-perlow --name "Brandon Perlow" --artist-name "Brandon Perlow" \
        --artist-homepage https://www.artstation.com/brandonperlow \
        --artist-credit "© Brandon Perlow — signature rendered into the artwork, do not crop" \
        --dir /usr/share/backgrounds/brandon-perlow \
        --license-note "LICENCE NOT YET PINNED. ..." \
        --rotation-interval 600'

#    Singularity Default: stage PNGs into a tmpdir, build there, rewrite source.directory.
$SSH 'echo mini | sudo -S mkdir -p /tmp/sing-pngs && \
      echo mini | sudo -S cp /opt/singularity/share/backgrounds/singularity/*.png /tmp/sing-pngs/ && \
      echo mini | sudo -S /usr/local/bin/build-pack-json.py \
        --id singularity --name "Singularity Default" --artist-name Singularity \
        --artist-credit "Singularity desktop default artwork" \
        --dir /tmp/sing-pngs \
        --license-note "Distributed with Singularity Desktop; the Singularity project retains all rights" \
        --rotation-interval 600 --out /tmp/singularity.pack.json && \
      echo mini | sudo -S python3 -c "import json,sys; p=json.load(open(\"/tmp/singularity.pack.json\")); p[\"source\"][\"directory\"]=\"/opt/singularity/share/backgrounds/singularity\"; json.dump(p, open(\"/opt/singularity/share/backgrounds/singularity/pack.json\",\"w\"), indent=2, sort_keys=True)"'

# 3. .collection files (one INI each).
$SSH 'echo "[Collection]
Id=ncz
Name=NCZ-OS
Comment=NCZ branding wallpapers — the 7 shipped artworks + Maximilian (default)
Artist=NCZ
Type=static
Dir=/usr/share/backgrounds/ncz" | echo mini | sudo -S tee /usr/share/ncz-wallpapers/collections/ncz.collection > /dev/null'
# (and analogous for brandon-perlow + singularity — see Part A above for the bodies)

# 4. Verify rotator for each pack.
for id in ncz brandon-perlow singularity; do
    $SSH "echo $id > /home/mini/.config/ncz-wallpaper/collection; \
          XDG_CURRENT_DESKTOP=Singularity DESKTOP_SESSION=Singularity WAYLAND_DISPLAY=wayland-0 \
          /usr/local/bin/ncz-wallpaper-rotate; \
          sleep 1; \
          cat /run/user/1000/ncz-wallpaper-state; \
          pgrep -au mini swaybg"
done

# 5. Picker scan enumeration (faithful replay of the fixed Vala scan).
$SCP /tmp/o6n_scan_test.py mini@192.168.207.3:/tmp/o6n_scan_test.py
$SSH 'python3 /tmp/o6n_scan_test.py'
```

## What was NOT done, on purpose

* **No O6N reboot.** Per the operator note (two crash-loop incidents
  from unattended reboots on the kernel/hardware test box), nothing in
  this task required a reboot. All changes were file-level or
  service-level (the rotator service kept running throughout).
* **No Singularity-package rebuild.** The picker scan fix is in
  upstream `singularity-shell` but the deployed
  `ncz-singularity-desktop 20260817+bk4~v7` does not include it. Until
  that build is performed + installed, the live picker on O6N
  continues to have the bug documented in
  `WALLPAPER-PICKER-BUG-CONFIRM-2026-08-21.md`. The 3 packs ARE on
  disk and ARE enumerated by the fixed scan (verified via the GIO
  replay in §B.3); they will be visible in the picker as soon as the
  rebuild lands.
* **No package-version bump for `ncz-wallpapers-brandon-perlow`.** The
  existing contrib-deb script in `build/build-wallpaper-contrib-deb.sh`
  builds a `.deb` that already produces a `.collection` file in the
  exact format this session writes by hand. A future session can wire
  the same Author-Pack pipeline into that script so a
  `ncz-wallpapers-brandon-perlow_<ver>_all.deb` rebuild picks up the
  hand-written files. Out of scope here.

## Verdict

* All 3 packs are built on O6N with both `.collection` (live, read by
  rotator) and `pack.json` (future pack-aware picker UI) manifests.
* The rotator applies from each pack end-to-end, with `swaybg`
  rendering the chosen image and the dconf `change_notify` firing for
  `background-picture-uri`.
* The picker scan fix is landed upstream but not yet built into the
  O6N singularity-desktop package. A faithful replay of the fix
  against the O6N filesystem confirms all 3 packs would be visible
  once that build is deployed.
* One repo change: `assets/wallpaper/build-pack-json.py`.