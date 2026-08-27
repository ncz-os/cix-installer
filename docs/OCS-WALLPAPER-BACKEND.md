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
ncz-wallpaper-ocs item pling 2353422
ncz-wallpaper-ocs import pling 2353422
```

`browse` filters on the item `downloadname1` extension. Raster images and
archives are importable; SVG, theme packages, QML plugins and other payloads are
not presented as wallpaper imports.

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
