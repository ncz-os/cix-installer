# NCZ-OS Cygnus rEFInd theme: one 1080p background, `banner_scale fillscreen`

## The bug (Radxa Orion O6N, 2026-10-04)

A photo of the installed rEFInd menu showed it cropped/zoomed. The Radxa Orion O6N
was on a 4K panel: the DRM connector `card0-DP-2` reports a `3840x2160` mode. The old
theme ran `pick-theme.sh`, which read *that* mode and installed
`background-3840x2160.png` with `banner_scale noscale`, while `refind.conf` said
`resolution max`.

`resolution max` selects the highest **firmware GOP** mode, not the DRM mode.
On that board the GOP mode rEFInd actually gets is ~1920 wide. A 3840x2160 image drawn
`noscale` does not fit, so rEFInd keeps only part of it:

- `refind/screen.c` `BltClearScreen()` calls `egCropImage(Banner, 0, 0, UGAWidth, UGAHeight)`
  when a `noscale` banner is larger than the screen -- a **top-left crop**.
- The OS cannot read the GOP mode rEFInd will use; probing `/sys/class/drm`
  measures a different display pipeline, which is exactly how the two sizes got
  out of sync.

Measured in the QEMU harness: the shipped 4K background at a 1920x1080 GOP is
the top-left crop (mean-absolute-difference ~1.0 from the crop, ~45 from a
stretch), i.e. the menu is cut off. Decoding a 3840x2160 PNG in firmware is also
slower than a 1920x1080 one, which matches the operator's "longer boot" report.

## The design

One background, `assets/refind/cygnus/background-1920x1080.png`, drawn with:

```
banner themes/cygnus/background-1920x1080.png
banner_scale fillscreen
```

`banner_scale fillscreen` makes rEFInd scale the banner to the **exact** GOP
size at boot:

- `refind/screen.c` `BltClearScreen()` calls
  `egScaleImage(Banner, UGAWidth, UGAHeight)` whenever the banner size differs
  from the screen size.
- `libeg/image.c` `egScaleImage()` writes every output pixel from a bilinear
  sample of the source at `NewWidth x NewHeight` -- a true stretch to fill, with
  **no crop** and no uncovered border, at any GOP mode.

There is deliberately no `resolution` line in the theme. The generated
`refind.conf` keeps `resolution max`, so rEFInd still picks the mode the
firmware offers; the theme just covers whatever it gets.

### Why not the alternatives

- **`banner_scale noscale` + a single background** -- at a GOP mode smaller
  than 1920x1080 (e.g. 1280x800) `noscale` crops the top-left corner (above).
  It cannot be right at every mode.
- **Pinning `resolution 1920 1080`** -- on a UEFI system where 1920x1080 is not
  a GOP mode, `libeg/screen.c` `egSetScreenSize()` prints
  `Error setting graphics mode 1920 x 1080; ... Available modes are:` and uses
  the default mode. On a T2 Mac with only 16:10 modes that is boot-screen error
  text. It is not correct at *any* GOP mode.

### Accepted trade-off: aspect stretch on non-16:9 panels

The single background is 16:9. `fillscreen` scales width and height
independently, so on a 16:10 GOP (1280x800, 1920x1200, a T2 Mac at 16:10) the
art is stretched vertically by ~11% and on a 5:4/4:3 panel by more. That is
accepted explicitly: it is uniform, only affects the background art (selection
art, icons and text keep their own proportions), and no menu content is ever cut
off or hidden behind an error screen. Panels in the field are 16:9 or 16:10.

## Assets

`assets/refind/cygnus/` (and the mirrored source `branding/cygnus/refind/` for
the configs) ships only what this design needs:

| File | Role |
|---|---|
| `background-1920x1080.png` | the single 1920x1080 export (approved blob) |
| `theme.conf` | `banner` + `banner_scale fillscreen` + selection art |
| `refind.conf.snippet` | the `include themes/cygnus/theme.conf` line |
| `selection_big.png` / `selection_small.png` | rEFInd selection tiles (144/64 px, unchanged) |
| `os_ncz.png` | the NCZ entry icon (installed as `ncz.png`, unchanged) |

`pick-theme.sh`, `theme-{1920x1080,2560x1440,3840x2160}.conf` and
`background-{2560x1440,3840x2160}.png` were removed; the 2K/4K masters are kept
outside the repository. `branding/cygnus/tools/make-cygnus-art.py refind` now exports only
1920x1080.

Both `assets/refind/ncz-refind-refresh.sh` (arm64) and
`assets/refind/ncz-refind-refresh-amd64.sh` copy the theme directory verbatim and
add `include themes/cygnus/theme.conf` after the generated banner lines, so the
theme overrides the fallback `banner ncz-banner.png` / `banner_scale noscale`
pair. Every default/rescue/entry/icon path is unchanged.

## The INSTALLER ESP (`build/iso/build-refind-esp.py`)

Until 2026-10-17 the theme reached only the **installed** system: the installer
ESP is built by a separate script, and it never referenced
`assets/refind/cygnus/` at all, so the live/installation medium booted stock,
unbranded rEFInd (MINOR-004).

The ESP builder now stages the theme too, controlled by `NCZ_REFIND_THEME`:

| `NCZ_REFIND_THEME` | Result |
|---|---|
| unset (release default) | theme staged (same as `1`) |
| `1` | `themes/cygnus/` written under **both** SelfDir candidates -- `EFI/BOOT/` (the El Torito fallback launch) and `EFI/REFIND/` (the installed path) -- and the tracked `refind.conf.snippet` appended to `refind.conf`, so the include is the last line and its banner directives win |
| `0` | not staged; `refind.conf` is exactly the pre-change file (no `include`, no trailing blank line), i.e. the previous bytes |

`--refind-theme 0|1` overrides the environment for a single run; with no flag
the environment decides. The theme is staged identically on **amd64 and arm64**:
both arches read the same `themes/` loading rules from the same rEFInd, and the
arm64 ESP had the same gap (its `refind.conf` does keep `textonly`, which is
about the UART, not about branding -- rEFInd's banner art is not drawn in
text mode, so the arm64 ESP gains the include and the tree and will show the
theme anywhere its d-i screen is graphical).

Where the ESP puts things, and why it mirrors `icons/`:

- rEFInd resolves `include`, `banner` and `selection_*` paths **relative to the
  running binary's directory (SelfDir)**, the same way it finds `refind.conf`.
  Writing the tree at only one of the two candidate paths leaves the other
  launch unbranded, so both get a full copy.
- The snippet is read from the repository, not restated in the builder: a
  missing snippet with the theme enabled is a **build failure**, never a
  silently unbranded medium.
- The include goes at the **end** of `refind.conf`. rEFInd's last-wins parsing
  is what lets `theme.conf`'s `banner`/`banner_scale fillscreen` override
  anything generated above it; putting it first would make the theme inert
  without any error.
- `theme.conf` and its `banner_scale fillscreen` rationale are copied verbatim;
  the ESP never pins a `resolution` (the generated config keeps
  `resolution max`).

Verified by `build/iso/tests/test_refind_esp_theme.py` (via
`build/test-installer-esp-theme.sh`, also in `make parity`): it builds the ESP
tree both ways for both arches and asserts the theme files and config lines
exist only when enabled -- and that the disabled tree is byte-identical to the
pre-theme output.


## Proof

`branding/cygnus/tests/test-refind-theme.sh` boots the real shipped rEFInd
binaries in QEMU and screenshots the menu at each resolution, then checks each
frame against the 1080p background stretched to that size. A crop or a bright
letterbox band fails the run.

Static design assertions live in
`branding/cygnus/tests/test-refind-theme-config.sh` (also run by `make parity`).

QEMU results (2026-10-04, mean-absolute-difference over a 160x90 BOX downsample;
correct render `<3.3`, top-left crop `>46`):

| Mode | aa64 MAD (stretch) | x64 MAD (stretch) | MAD (top-left crop) |
|---|---|---|---|
| 1920x1080 | 1.23 | 1.42 | n/a (bg == screen) |
| 2560x1440 | 2.91 | 3.24 | n/a (bg < screen) |
| 1280x800 (16:10) | 2.78 | 3.07 | 46.2 / 46.4 |
| 1920x1200 (16:10) | 1.42 | 1.59 | n/a (bg == screen height) |

No crop, and the only distortion is the explicitly accepted uniform 16:9 -> 16:10
stretch. Selection art and icons are unchanged.
