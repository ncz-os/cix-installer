# Provider theme packs

OCS browsing unifies Pling, KDE Look and GNOME Look. New OCS imports use
one stable id `ocs`, one user registry entry and one growing directory under
`~/.local/share/backgrounds`. Filenames include provider, OCS id, and image
index; retries replace the same image rather than creating another collection.
Each JPEG has its own JSON attribution/provenance sidecar. Registry and sidecar
writes are atomic; images are normalized before atomic publication.

Bing has one `bing.collection` and one permanent archive root with market
subdirectories. Its daily user timer accumulates unseen feed entries forever.
`PackKind=theme` records the display taxonomy. Theme
packs and artist packs use the same collection registry and gallery path.
NCZ, Singularity, Brandon Perlow and Alex Jay Brady are artist packs.

## Existing installations

Install the updated OCS helper together with the shell change. The desktop
Debian package does not ship the installer-owned `/usr/local/bin` helper.
Old per-image collections and older `imported-ocs` sidecars remain readable.
They are not automatically moved or deleted: consolidation needs to handle
duplicate images, mixed-provider directories, saved selection and provenance.
Previously created `pling`, `kde-look` and `gnome-look` collections are also
preserved. New downloads accumulate in the OCS theme pack. Existing imported items
remain marked Added until explicitly removed; this change is not a migration.

## Catalog caching

`ocs-category-index.json` is a shipped local category index. OCS `browse`
caches normalized responses by network, category and page count under
`$XDG_CACHE_HOME/ncz-wallpapers/ocs/v1`. Fresh responses are reused for six
hours, with per-key locks and atomic replacement. Explicit Refresh bypasses
freshness; failed refreshes retain cached results and report stale use. Import
detail/download requests remain fresh because their URLs may expire.
Bing's list reads a disk archive
and downloads missing thumbnails, rather than crawling an OCS database.

This is a cache of requested catalog pages, not a complete mirror of all
network databases. Background revalidation and HTTP conditional requests are
future improvements. The browser still requests one page per usable category.

## Openverse

`ncz-wallpaper-openverse` is a separate non-OCS helper, installed by the same
post-install script. Anonymous search is fully supported; the provider settings
offer optional email registration. Every registration belongs to that user,
not a shared embedded application. Credentials and expiring Bearer tokens are
stored in `$XDG_CONFIG_HOME/ncz-wallpaper/credentials/openverse.json` (0600,
parent directory 0700). This is owner-only file storage, not encrypted keyring
storage; the current wallpaper code had no existing keyring integration.
The email is sent over stdin, not process arguments, and is not retained.
Verify the email using Openverse's link. There is no verification-status polling.

Search uses `/v1/images/` with `q`, `aspect_ratio=wide`, `size=large`, `page`,
`page_size=20`, `mature=false` and `filter_dead=true`. The supplied OpenAPI file
defines `expires_in` in seconds; token renewal uses that returned value, not a
hard-coded lifetime. Registration includes name, email and description (the
schema marks all three required). Search cache entries live under
`$XDG_CACHE_HOME/ncz-wallpapers/openverse`, use six-hour freshness, retain stale
results on failure, and are bounded to 128 queries/pages. Search is explicit,
not triggered on every keystroke. No numeric Openverse rate limits are assumed.

Imports fetch current image details, save original JPEG/PNG/WebP bytes without
resizing, and retain creator, source page, license/version/URL and the actual
per-item attribution in adjacent JSON. One `openverse.collection` grows over
time. The browse card and current-picture chooser expose attribution and links.
Openverse metadata is plain label text; it is never trusted as Pango markup.

Local tests: `python3 assets/wallpaper/test_openverse.py` and
`python3 assets/wallpaper/test_theme_packs.py`. Registration/token tests mock
the network to avoid creating unwanted real accounts or verification emails.
Live anonymous search and import were checked from O6N in an isolated temporary
directory, including image `c6a260ef-8a37-43df-939e-f3d662403fcc`:
“Transantarctic mountain hg,” Hannes Grobe, Alfred Wegener Institute, CC BY-SA 2.5.
