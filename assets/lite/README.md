# NCZ-OS lite profile (weak GPU / old PC)

The lite profile turns off the Singularity desktop, compositor and screensaver
features that cost the most on pre-2015 integrated GPUs (software GL, Intel
Gen 6/7/7.5), so an old laptop runs the stock desktop comfortably. It does not
change the desktop itself — only optional effects.

It is **amd64 only** and is **auto-selected once at first login** when a weak
GPU is detected. On every other GPU the stock settings are kept.

## Control it

    ncz-profile status     # what is set, what the rule would pick, and why
    ncz-profile lite       # apply lite now
    ncz-profile default    # restore the stock settings (exact prior values)
    ncz-profile auto       # re-arm the automatic first-login selection
    ncz-profile list       # show every setting lite changes

The preference lives in the GSettings key `dev.ncz.profile:profile`
(`auto` / `lite` / `default`). The automatic selector runs **once** and never
overrides a change you make afterwards; use `ncz-profile auto` to re-arm it.

## What it changes

Desktop (`dev.sinty.desktop`): background-effect off, blur 0, window
transparency 0, reduce-motion on, animation duration 0.3, rounded corners off,
idle dim off, tearing allowed for fullscreen.

Screensaver (`dev.ncz.screensaver`): weak GPU pool, render scale 0.5, max render
height 720, no PRIME offload.

Compositor (`~/.config/labwc/`): square corners, window animations off,
duration scale 0.30, shadow size 0. (The shell regenerates these from the
GSettings above; ncz-profile patches and backs up the files.)

Full design, the selection rule and the measured before/after: see
`docs/lite-profile.md` in the cix-installer source, or
`/usr/share/doc/ncz-lite-profile.md`.
