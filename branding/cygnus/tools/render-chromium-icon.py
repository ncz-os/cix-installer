#!/usr/bin/env python3
"""Draw the NCZ Chromium icon in the Cygnus palette as a true vector and rasterise it.

usage: render-chromium-icon.py OUT_DIR

Writes OUT_DIR/chromium-ncz-sky1.svg (scalable) and OUT_DIR/<size>.png for the sizes the
chromium-ncz-sky1 package ships (16 22 24 32 48 64 128 256 512). The geometry is measured
from the shipped (orange Maximilian) 512 px icon: a black hole (r 0.211 of the width), a thin
accretion ring, three ring segments separated by constant 7.8 degree wedges centred at 90,
210 and 330 degrees, and a dark outer rim. Colours come from the Cygnus tokens: segments run
magenta (#EE3FB8) through violet to cyan (#2ED8F0) from top-left to bottom-right, the
accretion ring is solid Cygnus cyan, the rim and hole are the violet-black field.

Every size is rendered from the vector (rsvg-convert, falling back to ImageMagick), so edges
are anti-aliased from geometry instead of resampled from a raster. Below 33 px the thin ring and
the separators are thickened to at least one device pixel so they do not vanish.
"""
import math
import os
import shutil
import subprocess
import sys
import tempfile

SIZES = (16, 22, 24, 32, 48, 64, 128, 256, 512)
MAGENTA, VIOLET, CYAN = "#EE3FB8", "#8F55F7", "#2ED8F0"
FIELD, HOLE = "#120A22", "#05030A"


def polar(cx, cy, r, deg):
    a = math.radians(deg)
    return cx + r * math.cos(a), cy - r * math.sin(a)


def svg(px):
    """SVG for a canvas of `px` device pixels (viewBox 512); thickens fine detail when small."""
    c = 256.0
    # radii in viewBox units (512 wide), measured from the original icon
    r_rim_out, r_seg_out, r_seg_in = 245.0, 232.0, 120.0
    r_ring_out, r_ring_in, r_hole = 118.0, 108.0, 108.0
    gap = 7.8
    unit = 512.0 / px                       # viewBox units per device pixel
    if px <= 32:                            # keep hairlines at >= ~1 device pixel
        ring_w = max(r_ring_out - r_ring_in, 1.35 * unit)
        r_ring_in = r_ring_out - ring_w
        r_hole = r_ring_in
        gap = max(gap, math.degrees(1.1 * unit / ((r_seg_in + r_seg_out) / 2)))
        r_seg_in = r_ring_out + 1.0 * unit   # visible dark channel between ring and segments
    segs = []
    mid_r = (r_seg_in + r_seg_out) / 2
    width = r_seg_out - r_seg_in
    # separators at 90, 210, 330; segments run between them
    for start in (90, 210, 330):
        a0 = start + gap / 2
        a1 = start + 120 - gap / 2
        x0, y0 = polar(c, c, mid_r, a0)
        x1, y1 = polar(c, c, mid_r, a1)
        # counter-clockwise on screen (increasing math angle) => sweep-flag 0
        segs.append(f'<path d="M{x0:.3f} {y0:.3f} A{mid_r:.3f} {mid_r:.3f} 0 0 0 {x1:.3f} {y1:.3f}" '
                    f'fill="none" stroke="url(#seg)" stroke-width="{width:.3f}"/>')
    rim_mid = (r_rim_out + r_seg_out) / 2
    ring_mid = (r_ring_out + r_ring_in) / 2
    return f"""<svg xmlns="http://www.w3.org/2000/svg" width="{px}" height="{px}" viewBox="0 0 512 512">
  <defs>
    <linearGradient id="seg" gradientUnits="userSpaceOnUse" x1="120" y1="110" x2="400" y2="400">
      <stop offset="0.05" stop-color="{MAGENTA}"/>
      <stop offset="0.38" stop-color="{VIOLET}"/>
      <stop offset="0.80" stop-color="{CYAN}"/>
    </linearGradient>
    <radialGradient id="shade" cx="0.38" cy="0.32" r="0.75">
      <stop offset="0" stop-color="#ffffff" stop-opacity="0.16"/>
      <stop offset="0.6" stop-color="#ffffff" stop-opacity="0"/>
      <stop offset="1" stop-color="#000000" stop-opacity="0.22"/>
    </radialGradient>
  </defs>
  <circle cx="256" cy="256" r="{r_rim_out}" fill="{FIELD}"/>
  <circle cx="256" cy="256" r="{rim_mid:.3f}" fill="none" stroke="{FIELD}" stroke-width="{r_rim_out - r_seg_out:.3f}"/>
  {chr(10).join('  ' + s for s in segs).strip()}
  <circle cx="256" cy="256" r="{r_seg_out}" fill="url(#shade)" opacity="0.9"/>
  <circle cx="256" cy="256" r="{r_ring_out + 2:.3f}" fill="{FIELD}"/>
  <circle cx="256" cy="256" r="{ring_mid:.3f}" fill="none" stroke="{CYAN}" stroke-width="{r_ring_out - r_ring_in:.3f}"/>
  <circle cx="256" cy="256" r="{r_hole:.3f}" fill="{HOLE}"/>
</svg>
"""


def rasterise(svg_text, png_path, px):
    with tempfile.NamedTemporaryFile("w", suffix=".svg", delete=False) as f:
        f.write(svg_text)
        tmp = f.name
    try:
        if shutil.which("rsvg-convert"):
            subprocess.run(["rsvg-convert", "-w", str(px), "-h", str(px), "-o", png_path, tmp], check=True)
        else:
            subprocess.run(["magick", "-background", "none", "-density", "384", tmp,
                            "-resize", f"{px}x{px}", png_path], check=True)
    finally:
        os.unlink(tmp)


def main(out):
    os.makedirs(out, exist_ok=True)
    with open(os.path.join(out, "chromium-ncz-sky1.svg"), "w") as f:
        f.write(svg(512))
    for px in SIZES:
        rasterise(svg(px), os.path.join(out, f"{px}.png"), px)
        print("rendered", px)


if __name__ == "__main__":
    main(sys.argv[1])
