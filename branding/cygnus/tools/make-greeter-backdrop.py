#!/usr/bin/env python3
"""Make the Cygnus greeter backdrop from the approved no-text clean field.

usage: make-greeter-backdrop.py greeter-clean-1920x1080.png OUT.png

singularity-greeter downscales its background to 960 px wide and applies two
box blurs, so only broad colour survives. This applies a soft elliptical
darkening (multiply, smooth in both directions, no hard edge) so white UI
text keeps >= 4.5:1 over the whole central login area AFTER that blur, while
the magenta/cyan composition stays recognisable. Prints the measured result
and exits non-zero if the target is missed.
"""
import sys
import numpy as np
from PIL import Image, ImageFilter

TARGET = 4.5


def greeter_view(im):
    im = im.convert("RGB").resize((960, 540), Image.BILINEAR)
    for _ in range(2):
        im = im.filter(ImageFilter.BoxBlur(12))
    return im


def lum(img):
    a = np.asarray(img) / 255.0
    a = np.where(a <= 0.04045, a / 12.92, ((a + 0.055) / 1.055) ** 2.4)
    return 0.2126 * a[..., 0] + 0.7152 * a[..., 1] + 0.0722 * a[..., 2]


def centre_worst(img):
    L = lum(img)
    h, w = L.shape
    r = L[int(h * .25):int(h * .75), int(w * .30):int(w * .70)]
    return 1.05 / (np.percentile(r, 99) + 0.05), 1.05 / (np.median(r) + 0.05)


def apply(src, centre, edge):
    w, h = src.size
    y, x = np.mgrid[0:h, 0:w]
    d = np.sqrt(((x - w / 2) / (w * 0.42)) ** 2 + ((y - h / 2) / (h * 0.50)) ** 2)
    t = np.clip(d, 0, 1)
    t = t * t * (3 - 2 * t)                      # smoothstep: C1 at both ends
    m = centre + (edge - centre) * t
    a = np.asarray(src.convert("RGB")).astype(np.float32) * m[..., None]
    return Image.fromarray(np.clip(a, 0, 255).astype(np.uint8))


def main(src_path, out_path):
    src = Image.open(src_path).convert("RGB")
    centre = 0.80
    while True:
        out = apply(src, centre, 0.90)
        p99, med = centre_worst(greeter_view(out))
        if p99 >= TARGET or centre < 0.30:
            break
        centre -= 0.02
    out.save(out_path, "PNG", optimize=True)
    print(f"centre multiplier {centre:.2f}: white contrast p99 {p99:.2f}:1, median {med:.2f}:1 (target {TARGET})")
    sys.exit(0 if p99 >= TARGET else 1)


if __name__ == "__main__":
    main(*sys.argv[1:3])
