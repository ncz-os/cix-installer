# NCZ-OS 26.10 screensaver showcase

`index.html` is the public gallery. For each screensaver it shows a still and
a short loop, the name, a status (**Ships in 26.10**, **Approved**,
**Candidate**), the engine, the settings, and how the saver randomizes. At the
top of the page is the sizzle reel.

## Release notes section (paste-ready)

> ### Screensavers worth showing off
>
> NCZ-OS 26.10 ships 84 native Wayland screensavers, all on one GLES3 shader
> engine, with the old GL1 compatibility layer removed. You pick and configure
> them in Singularity's own settings, where they appear as a plugin. The
> launcher knows how capable your GPU is: heavy savers are flagged and
> filtered by GPU class. The default is **Black Hole**, a ray-traced black
> hole with a lensed accretion disk. Every run starts from a new random seed,
> so no two runs look the same. See the gallery (`docs/showcase/`) and the
> sizzle reel.

Before publishing, check each claim against the tagged build (see
`docs/releases/26.10-cygnus.md` section 3). Two of them are still pending:
PRIME offload on AC and the Black Hole scenes.

## What is in git and what is not

- **In git:** the page and the stills (`media/*.webp`, about 0.6 MB). The
  page falls back to these stills wherever a loop is missing.
- **Not in git:** the loops (`media/<id>.webm|mp4`) and the sizzle reel
  (`media/ncz-os-26.10-screensavers-sizzle.{mp4,webm}`, about 57 MB). They are
  staged with the page and a `SHA256SUMS` in the session store for 26.10,
  under `cygnus-26-10/showcase/`.
- **Rebuild:** `tools/build-showcase.py --sources <sources.json> --out <dir>`.
  The sources file maps each saver to its capture files. It is kept next to
  the captures rather than in git, because capture paths name test machines.

## Rules the build follows

- **Real footage only.** Every frame is a capture of the real saver running on
  NCZ-OS hardware. Nothing comes from a film, from photographs, or from AI
  image generators.
- **Only approved or candidate savers.** Only savers the operator has approved
  appear, plus clearly marked candidates (Neon Spacewar v2 and Ephemeris are
  still being iterated).
- **Public-safe output.** Media is re-encoded from pixels, container metadata
  is stripped, and captions carry only the saver name and status. There are
  no host names, addresses or secrets.
- **Comfortable to watch.** Every segment is limited to an average picture
  level of 30% with an exposure gain recorded in `build-report.json`. Every
  cut goes through black, so the reel has no flashes.
- **Original music.** The soundtrack is an ambient drone synthesized by
  ffmpeg's own sine and noise sources. It contains no recorded or licensed
  music.
