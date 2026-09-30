# NCZ-OS 26.10 Showcase Draft v0

L20 Black Hole Scenes + Branding Wiring

## Contents

- **manifest.tsv** — source handoff tracking from L20 test session, component status, and integration notes
- **branding/** — symlinked design system components (Cygnus theme):
  - `tokens.json` — design tokens and color palette
  - `css/` — CSS generated from tokens for web/documentation
  - `screensaver/` — screensaver palette and presets
  - `terminal/` — terminal colorscheme (kitty, foot, alacritty, vte)
  - `singularity/` — desktop environment GTK theme
  - `newt/` — newt-based installer theme colors
  - `wallpaper/` — primary and blackhole-themed background assets
  - `plymouth/` — boot splash theme and colors
  - `refind/` — rEFInd boot menu appearance and binaries
- **artist-pack/** — symlinked artist-pack browser integration
  - `singularity-artist-pack-inventory` — artist pack catalog
  - `singularity-artist-pack-install` — installation script
  - `dev.sinty.desktop.artist-pack-install.policy` — install authorization policy

## L20 Black Hole Scenes

Captured stills and clips from L20 test session:

| Scene | File | Status |
|-------|------|--------|
| Director camera (main) | best-v2-director_t60.jpg | Included |
| Binary merger | best-v2-merger_t53.6.jpg | Included |
| Binary pair | best-v2-binary_t45.jpg | Included |
| Three-body dance | best-v2-three-body_t45.jpg | Included |
| Full clip (MP4) | clip.mp4 | Staged (outside git) |

Staged location: `cygnus-26-10/showcase/` (session store, with SHA256SUMS).

## Build & Integration

**Sizzle Reel:**
- `tools/build-showcase.py --sources showcase.json --out <dir>`
- Builds 75s v0 draft with L20 captures, original ambient bed, fades through black
- Encodes to MP4 and WebM, APL capped at 30%, no flashes

**Branding Handoff:**
All symbolic links point to canonical locations in the repo. Update symtargets only; draft-v0 is a read-only overlay.

**Next Phase:**
Once operator approves the sizzle v0, integrate into main release pipeline under `cygnus-26-10/release/`.

---

*L20 handoff from screensaver validation session 2026-09-29*
