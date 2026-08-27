# ncz-wallpaper-ocs CLI Test — 2026-08-21

**Host:** argos (`.66/cixmini`, local) — `/home/jasonperlow`
**Repo:** `~/work/cix-installer` (branch `master`)
**Script under test:** `assets/wallpaper/ncz-wallpaper-ocs` (479 lines, Python 3)
  — installed by `post-install/45-wallpaper-rotator.sh` (line 52–53) as
  `/usr/local/bin/ncz-wallpaper-ocs`. Repo source is `assets/wallpaper/ncz-wallpaper-ocs`.
**Date:** 2026-08-20 (local) / 2026-08-21 UTC, executed live against the public
  OCS endpoints. Filename uses 2026-08-21 per task brief.
**Interpreter:** `python3` (system). Script self-identifies as
  `#!/usr/bin/env python3`; no third-party deps.

## TL;DR

All five subcommands exercised against the live `pling` OCS endpoint
(`https://api.pling.com/ocs/v1/`) returned real data. `import` downloaded a
single PNG (484 KiB), normalized it to a 3840x2160 JPEG, wrote `pack.json`
with full OCS provenance, and emitted a `.collection` file. No errors, no
rate limiting, no API failures.

## 1. `ncz-wallpaper-ocs providers` — exit 0

This subcommand is **offline** (returns the script's hard-coded
`PROVIDERS` table). It enumerates the four OCS provider hosts the script
knows about:

```json
{
  "providers": {
    "gnome-look":     {"base": "https://api.gnome-look.org/ocs/v1/",     "web": "https://www.gnome-look.org/p/{id}"},
    "kde-look":       {"base": "https://api.kde-look.org/ocs/v1/",       "web": "https://www.kde-look.org/p/{id}"},
    "opendesktop":    {"base": "https://api.opendesktop.org/ocs/v1/",    "web": "https://www.opendesktop.org/p/{id}"},
    "pling":          {"base": "https://api.pling.com/ocs/v1/",          "web": "https://www.pling.com/p/{id}"}
  },
  "schema": 1
}
```

## 2. `ncz-wallpaper-ocs categories pling` — exit 0 (real network call #1)

Returns the full category tree from `https://api.pling.com/ocs/v1/...`. The
response is a flat array of ~700 category objects with `id`, `name`,
`display_name`, `parent_id`, `xdg_type`. Verified subtrees: `Wallpapers`
(id 295) contains `Wallpapers Gnome` (id 300), `Wallpapers KDE Plasma`
(id 299), `Wallpapers Ubuntu` (id 286), etc. The chosen test category
**300 (Wallpapers Gnome)** sits under parent 295, xdg_type `wallpapers`.

Sample first/last entries (full output is hundreds of lines, abbreviated):

```json
[
  {"display_name":"App Addons","id":"152","name":"App Addons","parent_id":null,"xdg_type":null},
  ...
  {"display_name":"Wallpapers","id":"295","name":"Wallpapers","parent_id":null,"xdg_type":null},
  {"display_name":"Wallpapers Gnome","id":"300","name":"Wallpapers Gnome","parent_id":"295","xdg_type":"wallpapers"},
  ...
  {"display_name":"Wallpaper Other","id":"58","name":"Wallpaper Other","parent_id":"295","xdg_type":"wallpapers"}
]
```

stderr: empty. API was responsive, no rate limiting observed.

## 3. `ncz-wallpaper-ocs browse pling 300` — exit 0 (real network call #2)

Returns 10 items (page size) for category 300. Each item has `id`, `name`,
`author`, `detailpage`, `preview`, `tags`, `typeid`, `typename`, and a
nested `download` block (`url`, `name`, `extension`, `size_kib`, `md5`,
`mime_hint`). The download URLs are JWT-signed and time-limited (typical
OCS pattern).

Items (id, size KiB, name, author, ext):

| id       | size | name                                              | author | ext     |
|----------|------|---------------------------------------------------|--------|---------|
| 2364582  | 2920 | Gnome 2 Backgrounds.                              | ann-8  | .tar.gz |
| 2363882  |    4 | Solid Color Backgrounds For Gnome.                | ann-8  | .tar.gz |
| 2353422  | 6048 | Gnome - Astronaut                                 | riinii | .png    |
| 2353166  | 3043 | Open Source - Digital binary globe                | riinii | .png    |
| 2353164  | 1126 | Gnome - Green and blue shapes                     | riinii | .png    |
| 2353141  | 1133 | Gnome - Leaves on white background                | riinii | .png    |
| 2353140  |  484 | Gnome - Open Source - Free software Free Society  | riinii | .png    |
| 2352872  | 2120 | Gnome - Mountains and sunlight                    | riinii | .png    |
| 2352864  | 4813 | Gnome - Moon and bambi in the forest digital art  | riinii | .png    |
| 2352863  | 1487 | Gnome - Black and white mountain                  | riinii | .png    |

stderr: empty.

**Chosen for `import` test:** id **2353140** — smallest single PNG (484 KiB),
CC0-tagged (`tags: ["cc0","wallpaper","gnome","artwork"]`), authored by
`riinii`.

## 4. `ncz-wallpaper-ocs item pling 2353140` — exit 0 (real network call #3)

Returns full metadata for one item:

```json
{
  "author": "riinii",
  "detailpage": "https://www.pling.com/p/2353140",
  "download": {
    "extension": ".png",
    "md5": "1acced4c4a61c529642cd1b73dd73192",
    "mime_hint": "data##mimetype=image/png",
    "name": "gnome-os-2400x1350.png",
    "size_kib": 484,
    "url": "https://files06.pling.com/api/files/download/j/eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9..."
  },
  "id": "2353140",
  "name": "Gnome - Open Source - Free software Free Society",
  "preview": "https://images.pling.com/cache/770x540-4/img/00/00/76/60/24/2353140/gnome56-ts.png",
  "provider": "pling",
  "tags": ["cc0","wallpaper","gnome","artwork"],
  "typeid": "300",
  "typename": "Wallpapers Gnome"
}
```

stderr: empty.

## 5. `ncz-wallpaper-ocs import pling 2353140` — exit 0 (real network call #4 — full download + normalize)

Tool response:

```json
{
  "collection": "/home/jasonperlow/.local/share/ncz-wallpapers/collections/ocs-pling-2353140-gnome-open-source-free-software-free-society.collection",
  "destination": "/home/jasonperlow/.local/share/backgrounds/ocs-pling-2353140-gnome-open-source-free-software-free-society",
  "images": [
    {
      "file": "01-gnome-os-2400x1350.jpg",
      "normalized_geometry": {"height": 2160, "width": 3840},
      "source_file": "gnome-os-2400x1350.png",
      "source_geometry": {"height": 1350, "width": 2400},
      "title": "Gnome - Open Source - Free software Free Society"
    }
  ],
  "pack_id": "ocs-pling-2353140-gnome-open-source-free-software-free-society",
  "pack_json": "/home/jasonperlow/.local/share/backgrounds/ocs-pling-2353140-gnome-open-source-free-software-free-society/pack.json"
}
```

stderr: empty.

### 5a. pack.json — provenance verified

Path: `~/.local/share/backgrounds/ocs-pling-2353140-gnome-open-source-free-software-free-society/pack.json`

Key provenance fields (verbatim):

- `"origin": "ocs"` ✅
- `"provider": "pling"` ✅
- `"source.ocs_id": "2353140"` ✅
- `"source.detailpage": "https://www.pling.com/p/2353140"` ✅
- `"source.download_url"` (JWT-signed `files06.pling.com` URL) ✅
- `"source.resolved_download_url"` (pre-signed CDN URL on
  `ocs-dl.fra1.cdn.digitaloceanspaces.com`) ✅
- `"source.downloadsize1_kib": 484`, `"source.downloadname1": "gnome-os-2400x1350.png"` ✅
- `"source.tags": ["cc0","wallpaper","gnome","artwork"]` ✅
- `"license_note": "not specified by the OCS item"` ✅ (the OCS API does not
  surface a structured license field for this item, so the script records the
  absence rather than fabricating one)
- `"artist.name": "riinii"`, `"artist.credit": "riinii from pling"` ✅
- `"id"`, `"name"`, `"images[]"`, `"rotation{interval:600,order:shuffle,scope:pack}"`,
  `"schema": 1` ✅

### 5b. Normalized image — verified on disk

`file(1)` reports:

```
01-gnome-os-2400x1350.jpg: JPEG image data, JFIF standard 1.01, resolution (DPCM),
density 47x47, segment length 16, baseline, precision 8, 3840x2160, components 3
```

Source was a 2400x1350 PNG; the tool upscaled/cropped (per its default
3840x2160) to a 831025-byte JPEG (≈812 KiB). The image renders cleanly in
the terminal preview (black background, "Open Source gnome — Free software,
free society", cyan wireframe globe + mountain motif).

### 5c. `.collection` file — verified

Path: `~/.local/share/ncz-wallpapers/collections/ocs-pling-2353140-gnome-open-source-free-software-free-society.collection`

Contents (INI-style, 320 bytes):

```ini
[Collection]
Id=ocs-pling-2353140-gnome-open-source-free-software-free-society
Name=Gnome - Open Source - Free software Free society
Comment=User-fetched OCS wallpaper pack
Artist=riinii
Type=static
Dir=/home/jasonperlow/.local/share/backgrounds/ocs-pling-2353140-gnome-open-source-free-software-free-society
Origin=ocs
```

(Note: there's a small typo in the `Name=` value emitted by the script —
the source title is "Free software Free **S**ociety" (capital S) but the
emitted Name says "free society". The pack.json `name` field is correct
("Free software Free Society"); only the collection file's Name= line is
mangled. Cosmetic, not load-bearing.)

## Provider-API health

- **pling** (`api.pling.com`, `files06.pling.com`,
  `ocs-dl.fra1.cdn.digitaloceanspaces.com`): all four subcommands succeeded
  end-to-end. No rate-limiting observed in this session.
- **kde-look / gnome-look / opendesktop**: not exercised this round (task
  brief asked for `pling` specifically). Listed as available via
  `providers` but otherwise untested — same SDK, same code path, but
  separate endpoints.

## Defects observed

1. **Minor**: collection file `Name=` line lowercases the "S" in "Free
   Society" (probably a `.lower()` somewhere in the collection-emit path).
   Worth fixing but does not block wallpaper display.
2. None observed in network handling, JSON parsing, download, normalization,
   provenance capture, or file-layout.

## Files written by `import`

```
/home/jasonperlow/.local/share/backgrounds/ocs-pling-2353140-gnome-open-source-free-software-free-society/
├── 01-gnome-os-2400x1350.jpg   831025 bytes   (JPEG 3840x2160)
└── pack.json                    2089 bytes   (schema 1, full OCS provenance)

/home/jasonperlow/.local/share/ncz-wallpapers/collections/
└── ocs-pling-2353140-gnome-open-source-free-software-free-society.collection   320 bytes
```

## Reproducer (copy/paste)

```bash
cd ~/work/cix-installer
CLI=assets/wallpaper/ncz-wallpaper-ocs

python3 "$CLI" providers
python3 "$CLI" categories pling | head -40
python3 "$CLI" browse pling 300 | head -80
python3 "$CLI" item pling 2353140
python3 "$CLI" import pling 2353140

cat ~/.local/share/backgrounds/ocs-pling-2353140-gnome-open-source-free-software-free-society/pack.json
cat ~/.local/share/ncz-wallpapers/collections/ocs-pling-2353140-gnome-open-source-free-software-free-society.collection
file ~/.local/share/backgrounds/ocs-pling-2353140-gnome-open-source-free-software-free-society/01-gnome-os-2400x1350.jpg
```

## Verdict

The `ncz-wallpaper-ocs` CLI works end-to-end against live OCS provider
APIs. The `import` subcommand produces a complete, well-provenanced pack
(`pack.json` with origin/provider/ocs_id/license_note), correctly normalized
images, and the expected `.collection` registration file. Ready to ship as
the default wallpaper-fetch path for `45-wallpaper-rotator.sh`.
