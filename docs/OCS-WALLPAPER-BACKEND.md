# OCS wallpaper backend

Status: implemented backend/tooling. The GTK browser is intentionally not part
of this task.

Design authority: `docs/WALLPAPER-PACKS.md`. This backend keeps curated artist
packs and browsed OCS imports distinct:

* curated packs are shipped by signed debs;
* OCS imports are user-fetched, written under `~/.local/share/backgrounds/`,
  marked `"origin": "ocs"`, and never get a synthesized licence.

## Installed files

`post-install/45-wallpaper-rotator.sh` installs:

* `/usr/local/bin/ncz-wallpaper-ocs`
* `/usr/share/ncz-wallpapers/ocs-category-index.json`

The index is generated from the shipped provider list, not provider
autodiscovery. The live providers are:

* `pling` -> `https://api.pling.com/ocs/v1/`
* `opendesktop` -> `https://api.opendesktop.org/ocs/v1/`
* `kde-look` -> `https://api.kde-look.org/ocs/v1/`
* `gnome-look` -> `https://api.gnome-look.org/ocs/v1/`

## Commands

All commands print JSON unless they fail.

```sh
ncz-wallpaper-ocs providers
ncz-wallpaper-ocs categories pling
ncz-wallpaper-ocs index -o assets/wallpaper/ocs-category-index.json
ncz-wallpaper-ocs browse pling 300
ncz-wallpaper-ocs browse pling 300 --pages 1 --page-size 50
ncz-wallpaper-ocs item pling 2353422
ncz-wallpaper-ocs import pling 2353422
```

`browse` filters on the item `downloadname1` extension. Raster images and
archives are importable; SVG, theme packages, QML plugins and other payloads are
not presented as wallpaper imports.

### Paging — the server default is 10, not 50

Measured 2026-09-12 against the shipped providers:

```
/content/data?categories=300              -> <itemsperpage>10</itemsperpage>
                                             <totalitems>1971</totalitems>
/content/data?categories=300&pagesize=50  -> 50 items
/content/data?categories=300&pagesize=100 -> 100 items
/content/data?categories=300&pagesize=101 -> statuscode 400 "Page size out of range"
```

`page` is 0-indexed, so omitting it is page 0. `--pages N` walks pages
`0..N-1`. `--page-size` maps to OCS `pagesize` and is clamped to 1-100, so a
caller can never trip the 400; `--page-size 0` (the default) leaves the
parameter off and takes the server's 10. Both values are part of the response
cache key, so changing either does not serve back the other's result.

**A caller that omits `--page-size` sees about half a percent of a category.**
The shell's aggregate crawl hit exactly this: one 10-item page across the 45
usable pling categories yielded 394 unique importable items against a browser
cap of 1500, which is where the "~400 wallpapers" ceiling came from. At
`--page-size 50` the same 45 requests yield 1772, so the cap becomes the real
limit. `api.kde-look.org` reports `totalitems=0` for category 300; only two of
its categories are marked usable in the index.

`import` fetches the item detail, downloads `downloadlink1` while following the
Pling JWT redirect, unpacks archives, sniffs real MIME type with `file`,
normalizes JPEG/PNG/WebP files to 3840x2160 by cover-cropping with Lanczos, and
writes:

* `~/.local/share/backgrounds/<pack-id>/pack.json`
* normalized `*.jpg` images in the same directory
* `~/.local/share/ncz-wallpapers/collections/<pack-id>.collection` for the
  current rotator compatibility path

The `pack.json` carries provenance:

* `origin: "ocs"`
* `provider`
* OCS item id and detail page
* original `downloadname1`, `downloadsize1`, source tags and resolved download
  URL
* `license` only if the OCS item has a `<license>` field
* `license_note: "not specified by the OCS item"` when no licence is present

## Category index

The generated index marks every category with `usable` and, when false, a
`reason`. It suppresses non-wallpaper categories, phone/mobile wallpaper
categories, animated/video wallpaper categories, plugin categories, and fixed
resolution categories below 1920x1080.

The category index does not invent subject tabs. OCS has some subject-like
category names under desktop wallpapers, and phone wallpaper categories also
contain names such as `Nature`; those are not a reliable desktop taxonomy.

Tags are exposed at item level. Verified 2026-08-19 against
`https://api.pling.com/ocs/v1/content/data?categories=300`: the first page had
populated `<tags>` fields including values such as `space`, `mountain`, and
`forest`. The UI may use tags as optional item metadata, but the backend does
not depend on them for category usability.
