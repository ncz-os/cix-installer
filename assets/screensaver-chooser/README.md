# NCZ-OS Screensaver Chooser

This is an NCZ-owned GTK4/Vala application. It is not part of Singularity
Desktop. It configures an NCZ user service that uses `swayidle` and the
compositor's `ext-idle-notify-v1` support, starts native GLES3 screensaver
binaries with no arguments, and hands locking to `singularity-lockscreen`.

## Catalog

`hacks.tsv` is the 140-target inventory from `ncz-screensavers` commit
`251bf22`. Source family comes directly from its Meson target groups: 92 base
and Round ports, 35 hyprsaver shaders, and 13 RSS-SDL2-GLES2 ports. Theme is a
separate NCZ editorial classification based on the validated captures, source
names, shader names, and upstream descriptions. The seven themes are:

- Abstract & Psychedelic
- Geometry & Fractals
- Nature & Organic
- Particles & Physics
- Space & Sci-Fi
- Machines & Objects
- Text & Data

The three packaged previews are real captures from the same repository. The
MVP uses static preview images because each current hack owns a Wayland
layer-shell surface; it does not expose a child-surface API that GTK can embed.
The `Preview now` action launches the selected real hack on the current display.

## Build

```sh
meson setup ~/build-tmp/ncz-screensaver-chooser
meson compile -C ~/build-tmp/ncz-screensaver-chooser
```

The application has no per-hack parameter UI. Every hack is launched as-is.
