# NCZ-OS Screensaver Chooser Plugin

This libpeas-2 plugin provides the Singularity settings surface for the NCZ-OS
screensaver runner and idle manager. It uses GTK4 and libsingularity. The
existing GSettings schema remains the persistent configuration interface.

## Catalogue

`hacks.tsv` is generated from the real target lists in the ncz-screensavers
`meson.build`. Regenerate it with:

```sh
tools/generate-catalog.py /path/to/ncz-screensavers/meson.build hacks.tsv
```

The shipping groups are Black Hole Simulation, hyprsaver, xshadertoy, and
Classics. The generator fails if any selected entry has no build target.

The packaged captures predate this catalogue. `hyprsaver_snowfall_gles3` is
still present. `dangerball_gles3` and `hypnowheel_gles3` are no longer shipped.

## Build

The Singularity SDK is installed under `/opt/singularity` in NCZ-OS:

```sh
PKG_CONFIG_PATH=/opt/singularity/lib/pkgconfig \
VALAFLAGS=--vapidir=/opt/singularity/share/vala/vapi \
meson setup build --prefix=/opt/singularity
ninja -C build
```
