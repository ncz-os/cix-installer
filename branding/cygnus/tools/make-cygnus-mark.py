#!/usr/bin/env python3
"""Draw the square NCZ-OS Cygnus mark as a vector and rasterise it.

usage: make-cygnus-mark.py OUT_DIR

The os-release LOGO name (ncz-os-cygnus) serves two different consumers. The
greeter, the boot splash and the session splash look for a file by path and
find the wide Cygnus wordmark in /usr/share/pixmaps first. GTK icon-theme
lookups (the Singularity About page, anything asking the theme for the LOGO
icon) read the sized hicolor directories, and squeezing a 696x52 wordmark into
a square icon slot is what MINOR-006 reported. This script draws the square
mark those icon lookups get instead.

The mark is Cygnus X-1: a black hole with a tilted accretion disc in the
Cygnus palette (magenta into cyan on the violet-black field), so it reads as
the same family as the Black Hole boot and desktop art. Every colour comes
from branding/cygnus/tokens.json. No text, so it renders the same without
fonts.

Writes OUT_DIR/ncz-os-cygnus-mark.svg and OUT_DIR/<size>.png for the sizes
55-greeter.sh installs (48 64 96 128 192 256). PNGs are rendered from the
vector with rsvg-convert, so run this where librsvg2-bin is installed (the
debian:forky build container), not by resampling a raster.
"""

import json
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TOK = json.loads((ROOT / "tokens.json").read_text())
S = TOK["scales"]
SIZES = (48, 64, 96, 128, 192, 256)

FIELD = S["violet"]["950"]
RIM = S["violet"]["800"]
HOLE = "#05030A"
MAGENTA = S["magenta"]["400"]
VIOLET = S["violet"]["400"]
CYAN = S["cyan"]["400"]


def svg() -> str:
    # 256-unit canvas, centred at (128, 128). The disc is an ellipse tilted
    # -18 degrees; its back half is drawn first, then the hole, then the
    # front half on top, so the disc passes in front of the hole.
    tilt = "rotate(-12 128 128)"
    rx, ry = 104, 22
    back = f"M {128 - rx} 128 A {rx} {ry} 0 0 1 {128 + rx} 128"
    front = f"M {128 - rx} 128 A {rx} {ry} 0 0 0 {128 + rx} 128"
    # Gravitational lensing: the far side of the disc is bent into a bright
    # arc hugging the top of the hole and a fainter one under it.
    lens_top = "M 74 128 A 54 54 0 0 1 182 128"
    lens_low = "M 80 128 A 48 48 0 0 0 176 128"
    return f"""<svg xmlns="http://www.w3.org/2000/svg" width="256" height="256" viewBox="0 0 256 256">
  <defs>
    <linearGradient id="disc" gradientUnits="userSpaceOnUse" x1="24" y1="96" x2="232" y2="160">
      <stop offset="0" stop-color="{MAGENTA}"/>
      <stop offset="0.5" stop-color="{VIOLET}"/>
      <stop offset="1" stop-color="{CYAN}"/>
    </linearGradient>
  </defs>
  <circle cx="128" cy="128" r="122" fill="{FIELD}" stroke="{RIM}" stroke-width="6"/>
  <g transform="{tilt}" fill="none" stroke-linecap="round">
    <path d="{back}" stroke="url(#disc)" stroke-width="8" stroke-opacity="0.6"/>
    <path d="{lens_top}" stroke="url(#disc)" stroke-width="14"/>
    <path d="{lens_low}" stroke="url(#disc)" stroke-width="5" stroke-opacity="0.6"/>
  </g>
  <circle cx="128" cy="128" r="38" fill="{HOLE}"/>
  <circle cx="128" cy="128" r="40" fill="none" stroke="{CYAN}" stroke-width="3"/>
  <g transform="{tilt}" fill="none" stroke-linecap="round">
    <path d="{front}" stroke="url(#disc)" stroke-width="12"/>
  </g>
</svg>
"""


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__.strip().splitlines()[2], file=sys.stderr)
        return 2
    out = Path(sys.argv[1])
    out.mkdir(parents=True, exist_ok=True)
    src = out / "ncz-os-cygnus-mark.svg"
    src.write_text(svg())
    for size in SIZES:
        subprocess.run(
            [
                "rsvg-convert",
                "-w",
                str(size),
                "-h",
                str(size),
                "-o",
                str(out / f"{size}.png"),
                str(src),
            ],
            check=True,
            env={**os.environ, "SOURCE_DATE_EPOCH": "0"},
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
