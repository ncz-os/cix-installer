# NCZ-OS 26.10 "Cygnus" — Preview 4

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

NCZ-OS 26.10 "Cygnus" is a Debian-based OS for **CIX Sky1 boards (arm64)** and **Intel/AMD PCs and Apple T2 Macs (amd64)**. Each image is a raw GPT disk image: write it to a drive of at least 16 GB (this erases the drive), boot it and follow the installer.

**Status: preview.** <one sentence on what "preview" means for this release>

## Screenshots

<!-- Placeholder: one line per screenshot, files in docs/screenshots/26.10/ on main.
![<what it shows>](https://gitlab.com/ncz-os/cix-installer/-/raw/main/docs/screenshots/26.10/<NN-name>.png)
-->

## What's new

- <feature or fix, user-visible terms>

<!-- Use one section per architecture, amd64 first. Include the raw image
sha256 and the join command in each Desktop and Server subsection. -->

Download the listed parts, both flavor checksum files and `ncz-join-image.sh`
into one folder. Run the command for your image. It verifies the parts and
unpacks and verifies the raw image. Write the resulting `.img` to a drive
of at least 16 GB (this erases the drive), then boot it and follow the installer.

## amd64 — Intel/AMD PCs and Apple T2 Macs

### Desktop

- Image SHA-256: `<raw hash from SHA256SUMS-amd64-desktop>`
- Files: the parts listed in [PARTS-amd64-desktop.sha256](https://gitlab.com/ncz-os/cix-installer/-/releases/permalink/latest/downloads/amd64/PARTS-amd64-desktop.sha256) and [SHA256SUMS-amd64-desktop](https://gitlab.com/ncz-os/cix-installer/-/releases/permalink/latest/downloads/amd64/SHA256SUMS-amd64-desktop)
- Join: `sh ncz-join-image.sh amd64 desktop`

### Server

- Image SHA-256: `<raw hash from SHA256SUMS-amd64-server>`
- Files: the parts listed in [PARTS-amd64-server.sha256](https://gitlab.com/ncz-os/cix-installer/-/releases/permalink/latest/downloads/amd64/PARTS-amd64-server.sha256) and [SHA256SUMS-amd64-server](https://gitlab.com/ncz-os/cix-installer/-/releases/permalink/latest/downloads/amd64/SHA256SUMS-amd64-server)
- Join: `sh ncz-join-image.sh amd64 server`

Hardware:

| Machine | CPU | GPU (driver) | Status |
|---|---|---|---|
| <machine model> | <cpu> | <gpu> | <status> |

## arm64 — CIX Sky1

### Desktop

- Image SHA-256: `<raw hash from SHA256SUMS-arm64-desktop>`
- Files: the parts listed in [PARTS-arm64-desktop.sha256](https://gitlab.com/ncz-os/cix-installer/-/releases/permalink/latest/downloads/arm64/PARTS-arm64-desktop.sha256) and [SHA256SUMS-arm64-desktop](https://gitlab.com/ncz-os/cix-installer/-/releases/permalink/latest/downloads/arm64/SHA256SUMS-arm64-desktop)
- Join: `sh ncz-join-image.sh arm64 desktop`

### Server

- Image SHA-256: `<raw hash from SHA256SUMS-arm64-server>`
- Files: the parts listed in [PARTS-arm64-server.sha256](https://gitlab.com/ncz-os/cix-installer/-/releases/permalink/latest/downloads/arm64/PARTS-arm64-server.sha256) and [SHA256SUMS-arm64-server](https://gitlab.com/ncz-os/cix-installer/-/releases/permalink/latest/downloads/arm64/SHA256SUMS-arm64-server)
- Join: `sh ncz-join-image.sh arm64 server`

Hardware:

| Machine | CPU | GPU (driver) | Status |
|---|---|---|---|
| <machine model> | <cpu> | <gpu> | <status> |

## Checksums

[SHA256SUMS](https://gitlab.com/ncz-os/cix-installer/-/releases/permalink/latest/downloads/SHA256SUMS)
lists all four images in amd64, arm64 order, with desktop before server
within each architecture.

## Known limitations

- <limitation>

## Source

Built from `cix-installer` at commit `<sha>`; the source is tagged [`<tag>`](https://gitlab.com/ncz-os/cix-installer/-/tree/<tag>). The source of every component we build is listed in [SOURCE-RELEASES.md](https://gitlab.com/ncz-os/cix-installer/-/blob/main/docs/SOURCE-RELEASES.md).
