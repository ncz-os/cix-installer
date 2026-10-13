# NCZ-OS 26.10 "Cygnus" — Preview 2

<!--
Release page template (docs/IMAGE-HOSTING.md, "Release pages").
Copy this file to NOTES.md in the staged release folder and fill it in.
Rules:
  * Links use the stable forms only: the GitLab project's
    -/releases/permalink/latest and -/releases/permalink/latest/downloads/<file>,
    -/raw/main/<path> for images, -/blob/main/<path> for documents,
    -/tree/<tag> for the source of a tag. tools/sync-release-pages.sh
    publishes this text on GitLab as it is and on GitHub with the same links
    in their GitHub form. tools/check-release-links.sh refuses links to a
    specific release page, tag download or package file.
  * Images are absolute raw URLs on main of files in docs/screenshots/<release>/;
    relative image paths do not render on a release page.
  * Name image files by the image tag only: the build id, never a host.
Delete this comment before publishing.
-->

NCZ-OS 26.10 "Cygnus" is a Debian-based desktop OS for **CIX Sky1 boards (arm64)** and **Intel/AMD PCs and Apple T2 Macs (amd64)**. Each image is a raw GPT disk image: write it to a drive of at least 16 GB (this erases the drive), boot it and follow the installer.

**Status: preview.** <one sentence on what "preview" means for this release>

| Image | Architecture | Kernel | sha256 of the `.img` |
|---|---|---|---|
| `<ncz-os-arm64-YYYYMMDD-build>` | arm64, CIX Sky1 | `<kernel>` | `<sha256>` |
| `<ncz-os-amd64-YYYYMMDD-build>` | amd64 (Intel/AMD PCs, Apple T2 Macs) | `<kernel>` | `<sha256>` |

## Screenshots

<!-- Placeholder: one line per screenshot, files in docs/screenshots/26.10/ on main.
![<what it shows>](https://gitlab.com/ncz-os/cix-installer/-/raw/main/docs/screenshots/26.10/<NN-name>.png)
-->

## What's new

- <feature or fix, user-visible terms>

## Supported GPUs and hardware

<table of machines and their status>

## Installing

1. Download `ncz-join-image.sh`, `SHA256SUMS`, `PARTS.sha256` and the `…img.zst.part-*` files for your architecture into one folder. The part names are listed in `PARTS.sha256` (GitHub limits each file to 2 GiB, so each image is split).
2. Run `sh ncz-join-image.sh arm64` (or `amd64`). It checks every part, joins and unpacks them, and checks the finished image. It never writes to a disk.
3. Write the resulting `.img` to a drive of at least 16 GB (this erases the drive), then boot it and follow the installer.

The small files always have the same address on the latest release, for example
<https://gitlab.com/ncz-os/cix-installer/-/releases/permalink/latest/downloads/SHA256SUMS>.

## Known limitations

- <limitation>

## Source

Built from `cix-installer` at commit `<sha>`; the source is tagged [`<tag>`](https://gitlab.com/ncz-os/cix-installer/-/tree/<tag>). The source of every component we build is listed in [SOURCE-RELEASES.md](https://gitlab.com/ncz-os/cix-installer/-/blob/main/docs/SOURCE-RELEASES.md).
