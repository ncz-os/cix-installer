#!/usr/bin/env python3
"""Render the Cygnus Artist Pack wallpapers with a small corner mark.

usage: brand-wallpapers.py SRC_DIR OUT_DIR
  SRC_DIR holds <name>-3840x2160.png masters (cygnus-26.10 pack on ARGONAS).
  OUT_DIR receives cygnus-<id>.jpg (4K, q95), the files committed under
  assets/branding/wallpaper/contrib/cygnus-26.10.

The mark ("CYGNUS  .  NCZ-OS 26.10") sits in the bottom-right corner: the
Singularity dock defaults to bottom-centre and the top panel spans the top
edge, so neither covers it. It is small (cap height ~1.1% of frame height),
white at 80% over a soft shadow. Prints the measured white-on-local contrast
for each image; fails below 3:1.
"""
import hashlib, json, os, re, sys
from PIL import Image, ImageDraw, ImageFilter, ImageFont

FONT = "/usr/share/fonts/julietaula-montserrat-fonts/Montserrat-SemiBold.otf"
if not os.path.exists(FONT):
    FONT = "/usr/share/fonts/julietaula-montserrat-fonts/Montserrat-Bold.otf"
TEXT = "CYGNUS   ·   NCZ-OS 26.10"
W, H = 3840, 2160
SIZE, TRACK = 40, 7           # px at 4K
RIGHT, BOTTOM = 130, 105      # margins at 4K


def lin(c):
    c /= 255.0
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def lum(rgb):
    r, g, b = rgb
    return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)


def text_layer(font):
    widths = [font.getlength(ch) + TRACK for ch in TEXT]
    tw = int(sum(widths) - TRACK)
    pad = 40
    m = Image.new("L", (tw + 2 * pad, SIZE * 2 + 2 * pad), 0)
    d = ImageDraw.Draw(m)
    x = pad
    for ch, w in zip(TEXT, widths):
        d.text((x, pad), ch, font=font, fill=255)
        x += w
    return m, pad, tw


def brand(im):
    font = ImageFont.truetype(FONT, SIZE)
    mask, pad, tw = text_layer(font)
    bbox = mask.getbbox()
    ox = W - RIGHT - (bbox[2] - pad)
    oy = H - BOTTOM - (bbox[3] - pad)
    shadow = mask.filter(ImageFilter.GaussianBlur(7)).point(lambda v: int(v * 0.55))
    out = im.convert("RGBA")
    black = Image.new("RGBA", mask.size, (0, 0, 0, 255))
    out.paste(black, (ox - pad, oy - pad), shadow)
    white = Image.new("RGBA", mask.size, (255, 255, 255, 255))
    out.paste(white, (ox - pad, oy - pad), mask.point(lambda v: int(v * 0.80)))
    # contrast: white text (80% opacity) vs the mean local background, after the
    # shadow darkens it by roughly a quarter around the glyphs
    box = (ox - 30, oy - 20, ox + (bbox[2] - bbox[0]) + 30, oy + (bbox[3] - bbox[1]) + 20)
    local = im.convert("RGB").crop(box).resize((1, 1), Image.BOX).getpixel((0, 0))
    bg = tuple(c * 0.73 for c in local)
    L1 = lum(tuple(255 * 0.8 + c * 0.2 for c in bg))
    L2 = lum(bg)
    return out.convert("RGB"), (L1 + 0.05) / (L2 + 0.05)


def main(src, out):
    os.makedirs(out, exist_ok=True)
    names = sorted({re.sub(r"-3840x2160\.png$", "", f) for f in os.listdir(src) if f.endswith("-3840x2160.png")})
    res = []
    for n in names:
        im = Image.open(f"{src}/{n}-3840x2160.png").convert("RGB")
        assert im.size == (W, H), (n, im.size)
        fid = re.sub(r"-\d{3}$", "", re.sub(r"-s\d-(?:L[\d.]+-)?\d{3}$", "", n))
        branded, cr = brand(im)
        path = f"{out}/cygnus-{fid}.jpg"
        branded.save(path, "JPEG", quality=95, subsampling=0, optimize=True)
        h = hashlib.sha256(open(path, "rb").read()).hexdigest()
        print(f"{fid:22s} contrast {cr:5.2f}:1  {os.path.getsize(path)} {h[:12]}")
        res.append((n, fid, os.path.basename(path), os.path.getsize(path), h, round(cr, 2)))
    bad = [r[1] for r in res if r[5] < 3.0]
    json.dump(res, open(os.path.join(out, ".manifest.json"), "w"))
    if bad:
        sys.exit("contrast below 3:1: " + ", ".join(bad))


if __name__ == "__main__":
    main(*sys.argv[1:3])
