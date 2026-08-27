# Wallpaper packs, providers and the desktop UI — design

Status: DESIGN, not implemented. The backend pieces marked DONE are shipped and
verified; the DesktopPage UI is not written. Written 2026-08-19.

## Why this exists

Singularity has a wallpaper picker (`DesktopPage`, a two-column `FlowBox`), but
`populate_grid()` enumerates `/usr/share/backgrounds` **one level deep**. `ncz/`
is a directory, so its content-type is not `image/*` and it is skipped. The
practical consequence: **none of the NCZ wallpapers have ever appeared in the
picker**, let alone the artist packs one level below that, or the Bing cache,
which is not in the search path at all.

Fixing the scan is necessary but not sufficient — a flat pile of 17 images with
no grouping is what we already had on disk. The unit users care about is the
*pack*.

## 1. Pack format: JSON

Decided by the data, not taste:

* the shell already uses `Json.` in 8 files vs `KeyFile` in 2, so json-glib is
  available and idiomatic here;
* python3 is on the image (the Bing provider uses it) so shell tooling can parse
  it too — the original reason for the awk-friendly INI is gone;
* **an artist pack needs per-image metadata and ORDER.** In keyfile that means
  `[Image:foo.jpg]` sections with no inherent ordering. In JSON it is an array.

Prior art agrees: KDE Plasma uses `metadata.json` (KPackage). GNOME uses XML,
Windows uses INI `.theme` with a `[Slideshow]` section. All three separate the
images from the slideshow definition and all three have interval/shuffle — which
is what we are building.

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
  "license": "Distributed with NCZ-OS by permission; not separately redistributable",
  "rotation": { "scope": "pack", "order": "shuffle", "interval": 600 },
  "images": [
    { "file": "ncz-wallpaper-08-nimbus-i-4k.jpg", "title": "Nimbus I",
      "timeofday": ["day"] }
  ]
}
```

Decisions worth re-reading before changing:

* **`rotation.scope: "pack"`** — selecting a pack rotates *within* it. That is
  what "curated for rotation" means. `"global"` opts a pack into the shared pool.
* **`images` is a list, not a glob.** Curation means the artist chose these, in
  this order. Files present but unlisted do not rotate. The pak builder must
  therefore enumerate them.
* **`timeofday` is per-image**, which collapses the separate `Type=timeofday`
  collection into a property. A pack can be an artist pack *and* time-aware.
* **`schema`** so a format change is detectable rather than silently misparsed.
* Providers (Bing) are the same file shape with `"provider": "bing"` and no
  `images` array.

Steal from KDE: directory-as-package, and resolution variants (our set is
uniformly 3840×2160, wasteful on a 1080p panel). Do **not** steal KDE's
per-locale `Name[xx]` explosion — the real `Next` pack spends ~40 lines on a
translated author name.

Migration: three `.collection` files exist today, all emitted by
`build-wallpaper-contrib-deb.sh`. Change the generator to emit `.pack.json` and
have the reader accept both for one release.

## 2. Two tiers, deliberately distinct

| | Curated Artist Pack | Browsed (OCS) |
|---|---|---|
| source | our signed deb | store.kde.org / pling |
| attribution | explicit, in a copyright file | whatever the uploader set |
| licence | stated | **frequently absent** — verified |
| upgrades | apt | none |
| presented as | an artist pack, with our name on it | user-fetched art |

`license` was **absent** (not empty) on the OCS item inspected. An import must
never silently acquire the trappings of a curated pack. Show provenance
honestly: "from store.kde.org, licence not specified by the uploader".

## 3. OCS — feasible, no KDE dependency

Verified 2026-08-19, unauthenticated HTTP GET returning XML:

```
autoconfig.kde.org/ocs/providers.xml  -> api.kde-look.org/ocs/v1/ (content 1.6)
/content/categories                   -> statuscode 100
/content/data?categories=299          -> real listings
/content/data/<id>                    -> name, personid, downloadname/size/link, preview
```

libsoup is already in the GTK stack, so this is a REST client, not a dependency
decision. **KNewStuff is not required.**

Live providers (measured):

| provider | OCS | categories |
|---|---|---|
| `api.pling.com` | 100 | 538 |
| `api.opendesktop.org` | 100 | 538 (same backend as pling) |
| `api.kde-look.org` | 100 | 167 |
| `api.gnome-look.org` | 100 | 37 |
| `api.xfce-look.org` | — | dead |
| `api.store.kde.org` | — | dead |

**Auto-discovery is useless here**: `autoconfig.kde.org` returns exactly ONE
provider and `api.opendesktop.org` returns only itself. There is no global
directory. We ship our own list.

## 4. Meta index — the user browses content, not plumbing

The upstream taxonomy is historical sediment: by desktop (`Plasma Wallpaper
Plugin`), by resolution (`KDE Wallpaper 1024x768`), by distro (`Wallpapers
Arch`), by device (`Phone Wallpapers`), plus `Video-Wallpapers` and animated.
Nobody should see that.

**There is no subject taxonomy.** No "Space" or "Abstract" category exists;
subject lives in per-item `<tags>`, which is NOT yet verified as populated. Do
not promise a "Nature" tab before checking — it may be empty.

We ship a generated index that classifies and, crucially, marks what is usable:

```jsonc
{ "schema": 1,
  "providers": { "pling": {"base": "https://api.pling.com/ocs/v1/"},
                 "gnome-look": {"base": "https://api.gnome-look.org/ocs/v1/"} },
  "entries": [
    { "ref": "gnome-look:300", "name": "Wallpapers GNOME",
      "kind": "static", "usable": true },
    { "ref": "pling:419", "name": "Plasma Wallpaper Plugin",
      "kind": "plugin", "usable": false, "reason": "QML package, not an image" },
    { "ref": "pling:296", "name": "KDE Wallpaper 1024x768",
      "kind": "static", "usable": false, "reason": "below panel resolution" }
  ] }
```

**Filter on the ITEM's `downloadname1` extension, not the category.** Category is
a coarse hint; the extension is the truth. Sampled 2026-08-19:

```
295 Wallpapers (pling)   jpg 5, png 4, svg 1
299 KDE Wallpaper other  jpg 3, png 6, svg 1
300 Wallpapers GNOME     jpg 10        <- 100% clean
289 Wallpapers Arch      png 6, jpg 4
303 Wallpapers Debian    jpg 7, png 2, tar 1
```

Regenerating the index is a script run, not a shell release, so a new provider
or a dead endpoint is a data change.

## 5. Downloads are rebuilt into local packs

A download is not a loose file. On import we run the same normalisation the pak
builder does, so there is ONE code path for everything on disk:

1. fetch, follow the pling JWT redirect, unpack if it is an archive
2. sniff real image types, discard the rest
3. normalise to the panel resolution (cover-crop, Lanczos, never squash)
4. write `pack.json` with provenance: provider, author, source URL, licence if
   stated, `"origin": "ocs"`
5. land under `~/.local/share/backgrounds/<id>/`, where the picker already looks

The downloaded set then rotates, filters and attributes exactly like a curated
pack, while remaining honestly labelled as user-fetched.

## 6. Backend already shipped (DONE)

* collections + time-of-day + Bing provider — `f02e390`
* artist paks ship their own collection in their own directory — `60dec16`
* selectable Bing feeds and configurable rotation — `0d8eed0`
  * markets are a real feed selector: on one day en-US served Palmanova,
    en-GB/de-DE/zh-CN served Whyte Cliff, ja-JP/en-AU a Polish wildlife
    crossing — different photographs, not translations
  * cache is per market, because the rotator picks newest-by-name and a shared
    cache would keep serving the old feed's image
  * `rotate-enabled` / `rotate-interval`, re-read every cycle, clamped at 30s

## 6b. Bing is an ARCHIVE, not just today

Today the provider fetches `idx=0` only and prunes at 14 days. It should build a
browsable history the user can pick from.

The API supports backfill. Measured 2026-08-19:

```
idx=0&n=8  -> 20260818 .. 20260811   (8 per request is the cap)
idx=7&n=8  -> 20260811 .. 20260804
```

so chaining `idx` yields roughly **15 days**, which is as far back as Bing keeps
it. Implications:

* on first run, backfill the full window rather than starting from one image —
  a fresh install should not need two weeks of uptime to have a history;
* keep the archive instead of pruning to 14 (retention becomes a setting, and
  images already fetched are never re-downloaded — they are keyed `<date>.jpg`);
* **the archive is per market**, since each feed has its own images;
* the picker shows the history as a dated grid and the user can pin any day's
  image; that is a normal wallpaper selection, so it must not be clobbered by
  the next daily fetch.

Each image already has its `<date>.txt` sidecar with title and copyright, so the
history is self-describing.

## 6c. Attribution overlay, lower right

Bing/Spotlight on Windows shows the title and photographer over the wallpaper,
bottom right. We should do the same: the credit is the artist's, and for OCS
imports it is the only provenance the user ever sees.

* text comes from the pack: `artist.credit` for a curated pack, the `<date>.txt`
  title + copyright for Bing, uploader + provider for an OCS import;
* bottom-right, inset from the panel, drawn by the shell over the background
  layer — NOT burned into the image, which would survive into any copy the user
  makes and would be wrong on a different aspect ratio;
* off by default is the wrong call for contributed art: Brandon's images already
  carry a rendered signature precisely because attribution matters. Default ON,
  with a toggle;
* must remain legible over both bright and dark artwork — a subtle shadow or
  scrim, not a hard box.

Note Brandon's images have the signature and URLs rendered INTO the artwork, so
for that pack the overlay is duplicative. A pack should be able to declare
`"attribution": "in-image"` to suppress it.

## 7. Remaining work

1. `DesktopPage`: scan from the pack registry and recurse (this alone surfaces
   17 wallpapers + Bing for the first time)
2. pack selector, rotation controls, Bing feed picker
3. OCS browse + import-as-pack
4. generate the meta index

**Build note:** this needs the `debian:forky` container from
`build/build-singularity.sh`. Debian's `libgtk4-layer-shell` conflicts with NCZ's
patched one, so the shell cannot be built on the host — `libgtk4-layer-shell-dev`
fails with an unsatisfiable dependency on `libgtk4-layer-shell0`.
