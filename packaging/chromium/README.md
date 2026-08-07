# Chromium NCZ Sky1 Edition — build and packaging

Weekly snapshot build of Chromium with CIX Sky1 hardware video decode.

## Why we carry this

No upstream or distribution build works on this hardware:

- **Debian** ships a real arm64 `.deb` (150.0.7871.181-1) built
  `use_vaapi=false use_v4l2_codec=true`, whose V4L2 path dies on the Arm
  proprietary `Y0A8` capture format (`GPU process exited unexpectedly:
  exit_code=133`).
- **Ubuntu** ships no Chromium package at all — `chromium-browser` is a
  transitional stub (`2:1snap1-0ubuntu4`) that redirects to the snap, and
  `chromium` has no candidate. That has been their position since 20.04 and is
  unchanged for 26.04. Snap confinement also complicates `/dev/video*` access.

So a working arm64 Chromium on Sky1 exists nowhere else. AV1 in particular is
only available through V4L2-M2M, which means prebuilt VA-API browsers (Chrome,
Vivaldi) cannot reach it at all.

## Files

| File | Purpose |
|---|---|
| `build-snapshot.sh` | sync to a release tag, apply patch series, build arm64 |
| `make-deb.sh` | package the built tree as `chromium-ncz-sky1` |
| `verify-decode.sh` | bit-exact decode check on real Sky1 hardware |
| `.buildkite/pipeline.yml` | weekly stable build + beta canary |

## Channels

**Stable is what we ship.** Chromium runs a ~4-week release train plus security
respins; branding a browser means signing up for that cadence.

**Beta runs as a canary and is never published.** Its job is to fail early when
an upstream change makes one of our patches stop *doing* anything. That is not
hypothetical — entrpi's Firefox V4L2 patches applied cleanly across a version
bump and silently did nothing, which is how we discovered Firefox had never been
accelerated at all.

## Fuzz policy

`build-snapshot.sh` treats a patch applying **with fuzz as a hard failure**
(exit 3), not a warning. Fuzz means upstream moved the surrounding code, and a
hunk can land somewhere that no longer gates anything. Two of our four patches
are exactly the fragile kind: a one-line boolean in `media/gpu/args.gni`, and
profile tables in `v4l2_utils.cc` that gain entries as codecs land.

Exit codes are distinct so a scheduler can tell "upstream moved" (2, 3) from
"our build broke" (4, 5, 6).

## What counts as verification

Only byte-for-byte comparison against software decode, with **byte counts
checked as well as checksums**. Everything else has produced a false pass
during this work:

- a build that compiles proves nothing
- an open `/dev/video*` fd proves nothing — it accompanied flat green frames
- a player's "using hardware decoding" line proves nothing — mpv printed it for
  HEVC while producing zero output
- md5 alone proves nothing — two empty files share
  `d41d8cd98f00b204e9800998ecf8427e`, which already produced one false pass

Publishing is gated on `verify-decode.sh` passing on hardware, not on the build
succeeding.

## Dependencies

The `.deb` `Depends:` on `cix-vaapi-driver` and `Recommends:` `ncz-ffmpeg`.
Without the driver the browser still runs but decodes in software — the
dependency is declared so another distribution consuming this package gets the
whole stack rather than a browser that quietly does nothing special.

## Prerequisites on a build agent

- `depot_tools` on `PATH`
- modern kernel UAPI headers (`v4l2-controls.h`, `videodev2.h` from >= 6.0) in
  `$NCZ_UAPI_DIR` — Chromium's bundled Bullseye sysroots predate the V4L2 AV1
  controls, and **all three** sysroots (amd64, arm64, i386) need them: the
  `clang_x64_v8_arm64` host toolchain builds against amd64, so patching only
  arm64 fails late in the build
