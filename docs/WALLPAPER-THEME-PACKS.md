# Provider theme packs

OCS imports now use stable ids `pling`, `kde-look`, and `gnome-look`.
Each provider has one user registry entry and one growing directory under
`~/.local/share/backgrounds`. Filenames include provider, OCS id, and image
index; retries replace the same image rather than creating another collection.
Each JPEG has its own JSON attribution/provenance sidecar. Registry and sidecar
writes are atomic; images are normalized before atomic publication.

Bing already has one `bing.collection` and one archive root with market
subdirectories. Its fetch, pinning, retention and daily user timer continue
to manage that archive. `PackKind=theme` records the display taxonomy. Theme
packs and artist packs use the same collection registry and gallery path.
NCZ, Singularity, Brandon Perlow and Alex Jay Brady are artist packs.

## Existing installations

Install the updated OCS helper together with the shell change. The desktop
Debian package does not ship the installer-owned `/usr/local/bin` helper.
Old per-image collections and older `imported-ocs` sidecars remain readable.
They are not automatically moved or deleted: consolidation needs to handle
duplicate images, mixed-provider directories, saved selection and provenance.
New downloads accumulate in the provider theme pack. Existing imported items
remain marked Added until explicitly removed; this change is not a migration.

## Catalog caching gap

`ocs-category-index.json` is a shipped local category index. OCS `browse`
still calls `content/data` for every usable category each browser session;
there is no persistent item-response cache. Bing's list reads a disk archive
and downloads missing thumbnails, rather than crawling an OCS database.

Proposed follow-up: cache normalized browse responses under
`$XDG_CACHE_HOME/ncz-wallpapers/ocs/v1/<provider>/<category>/<page>.json`.
Use a six-hour freshness interval, immediate cached display, and bounded
background revalidation. Preserve stale valid results offline, showing their
age and any refresh error. Explicit Refresh should force revalidation. Validate
provider/category/schema before atomic replacement; use a per-key lock to
coalesce concurrent requests. Honor ETag/Last-Modified if the API supplies
them, cap total cache size, and version the cache format. Item/download detail
requests must remain fresh because download URLs may expire. Catalog caching
is not implemented by this theme-pack change.
