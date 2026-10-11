# Wallpaper safe area and aspect variants

NCZ-OS draws the desktop wallpaper with **cover** scaling. The Singularity
shell uses `ContentFit.COVER` for its background picture, and under GNOME the
rotator sets `picture-options 'zoom'`, which does the same thing. The image is
scaled until it fills the output and whatever overhangs is cut off, centred.
Nothing is stretched, so anything placed near the edge of a 16:9 image is lost
on any output that is not 16:9.

| Output | Aspect | A 3840x2160 (16:9) image loses |
|---|---|---|
| 1920x1080, 2560x1440, 3840x2160 | 16:9 | nothing |
| 1366x768 | 1.779 | nothing measurable |
| 3072x1920, 2880x1800, 2560x1600, 1920x1200 | 16:10 | 192 px at each side (5% per side) |
| 1600x1200, 1024x768 | 4:3 | 480 px at each side (12.5% per side) |

On 2026-10-06 the 26.10 Cygnus pack showed this on a 16:10 laptop panel
(3072x1920, scale 2): the mark `CYGNUS . NCZ-OS 26.10` sat 130 px from the
right edge of the 16:9 frame and read `NCZ-OS 26` on screen. About 11% of the
mark's glyph pixels were cut on every 16:10 resolution, and the subjects lost
up to 15% of their light (hero-reveal-64ss, whose subject sits on the right
edge).

## The rule for new wallpapers

For a 3840x2160 master (scale the numbers for other sizes):

1. **Branding and text** (marks, signatures, URLs, captions) stay inside the
   central 16:10 area, which is x = 192 to 3648 at full height, and at least
   64 px inside that area's edges. A mark placed there is visible on 16:9 and
   16:10 outputs without a variant.
2. **The subject** (the part that makes the picture) should also sit in that
   central 16:10 area. Light, haze and background may run to the edges.
3. A 4:3 output keeps only x = 480 to 3360. Nothing that has to be readable
   should depend on surviving that.
4. Text baked into a JPEG cannot be moved afterwards. Keep the unbranded
   master and apply the text with a script (for Cygnus,
   `branding/cygnus/tools/brand-wallpapers.py`), so a new layout is a re-run
   and never hand edits.

Artist-contributed packs whose signature is part of the artwork (for example
Brandon Perlow's) must not be cropped or re-composed by us. Ask the artist for
16:10 versions instead.

## Aspect variants

When an image cannot follow the rule, or already shipped without it, the pack
can carry pre-composed variants for other aspect ratios:

* **Source:** a `<W>x<H>/` subdirectory of the pack source holding one file per
  original, with the same basename. For Cygnus this is
  `assets/branding/wallpaper/contrib/cygnus-2610/16x10/`.
* **Composition:** each variant is a 3456x2160 window of the same unbranded
  master. It is never a stretch and never a crop of the branded 16:9 JPEG,
  because that would cut the old mark in half. The window is centred unless
  centring would clip the subject's bright core while a shifted window holds
  all of it. hero-reveal-64ss and single-eht use the rightmost window
  (x = 384). The mark is re-rendered 130 px from the right and 213 px from the
  bottom, which is 108 px higher than on the original. Shown with cover
  scaling on a 16:9 output, the variant loses exactly those 108 px top and
  bottom, so the mark lands at the original 105 px bottom margin there. On a
  16:10 output nothing is cut. `VARIANTS.json` records each window and the
  checksum of each variant. JPEG quality is 88.
* **Install:** `build/build-wallpaper-contrib-deb.sh` installs the variants to
  `/usr/share/ncz-wallpapers/aspect/<W>x<H>/<pack>/` and adds the following
  to the pack's `.collection`:

      [Variants]
      16x10=/usr/share/ncz-wallpapers/aspect/16x10/cygnus-2610

  Variants live outside every collection `Dir` on purpose. The Singularity
  shell's own rotator and its gallery scan a collection `Dir` recursively (to
  depth 3), so a subdirectory there would list every image twice. The build
  fails if a variant has no original or an original has no variant.
* **Selection:** `ncz-wallpaper-fit` (from `assets/wallpaper/`, installed by
  `post-install/45-wallpaper-rotator.sh`) reads the primary output's size.
  It tries `wlr-randr --json` first (the output that Singularity's
  `displays.json` names as `shell_monitor`, with rotation applied), then
  `displays.json`, then DRM sysfs. It picks the original or the variant whose
  aspect ratio is closest. A tie, an unknown output, or any error keeps the
  original.
* **When it is applied:** `ncz-wallpaper-rotate` fits every image it picks.
  `ncz-wallpaper-daemon` runs `ncz-wallpaper-rotate --refit` every 15 s. That
  keeps the current image but swaps it for the fitting file, and only writes
  GSettings when the result differs. This covers three cases:
  * a mode, rotation or monitor change;
  * the Singularity shell's own built-in rotator, which writes the 16:9 file;
  * a choice in the Settings wallpaper chooser, which also writes the 16:9
    file.

  The shell is upstream code and is not changed. While a 16:9 file it chose
  is on screen, it can stay cropped for up to one tick.

## Rotation is not a login action (2026-10-11)

`ncz-wallpaper-daemon` is (re)started on every login: the systemd `--user` unit
is pulled in by `singularity-session.target`, `ncz-wallpaper-session-ready`
restarts it once the live session environment is exported, and the XDG
autostart fallback starts it too. Before 2026-10-11 it ran
`ncz-wallpaper-rotate` as its very first action, so every login, every session
restart and every spin of a crash loop (the O6N shell crash loop) changed the
wallpaper.

It now persists the time of the last rotation, atomically, to

    $XDG_STATE_HOME/ncz-wallpaper/last-rotate
    (default ~/.local/state/ncz-wallpaper/last-rotate)

and on start rotates only when that record is absent (a brand-new user still
gets one wallpaper) or the configured interval has genuinely elapsed. A record
in the future (the clock stepped back), a non-numeric or leading-zero record,
and a missing record all count as "elapsed", so bad state can never block
rotation forever. `rotate-enabled=0` still suppresses the start-up rotation,
and the start-up `--refit` above is unchanged (it fits the *current* image and
is a no-op when nothing changed). Nothing changes once the interval has
elapsed while the daemon is running.

## Checks

`python3 build/test_wallpaper_fit.py` (part of `make parity`) checks:

* selection by aspect ratio against stubbed `wlr-randr`, `displays.json` and
  sysfs;
* the real rotator heredoc against a stub `gsettings`;
* the deb layout and its `[Variants]` section;
* that every Cygnus image has a variant, and that each variant is 16:10
  within 0.5%;
* with Pillow, a pixel test that finds each variant's mark and requires all
  of it inside the 16:10, 16:9 and 1366x768 cover views, 64 px clear of every
  edge.

`bash build/test-wallpaper-rotator-interval.sh` (part of `make parity`) runs
the real daemon heredoc against a fake clock and a counting fake rotator: a
restart inside the interval rotates 0 times, after the interval 1, missing /
corrupt / future state 1, and `rotate-enabled=0` 0. A negative self-check runs
the pre-fix start action and shows it rotates inside the interval, so the test
would have caught the login-time regression.

## Known limits

* 4:3 and 5:4 outputs still get the 16:10 variant, the closest available. On
  1600x1200 about 25% of the mark is cut, down from 60% with the 16:9
  original. A 4:3 variant would fix this if such panels matter.
* The greeter backdrop (`post-install/55-greeter.sh`) and the Singularity
  Default, Bing and contributed packs are separate images and are not covered
  here.
