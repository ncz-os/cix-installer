#!/usr/bin/env python3
"""Render the Cygnus Artist Pack wallpapers with a small corner mark.

usage: brand-wallpapers.py SRC_DIR OUT_DIR [--aspect 16x10]
  SRC_DIR holds <name>-3840x2160.png masters (cygnus-26.10 pack on ARGONAS).
  OUT_DIR receives cygnus-<id>.jpg (4K, q95), the files committed under
  assets/branding/wallpaper/contrib/cygnus-2610.

  --aspect 16x10 writes the 16:10 variants instead (committed under
  assets/branding/wallpaper/contrib/cygnus-2610/16x10/): each is a
  3456x2160 window of the SAME unbranded master -- never a stretch and never
  a crop of the branded 16:9 JPEG -- with the mark re-rendered inside the
  safe area of docs/WALLPAPER-SAFE-AREA.md, q88. The window is centred unless
  centring would clip the subject's bright core and a shifted window holds
  all of it (hero-reveal's subject sits on the right edge). The chosen offset is recorded in
  OUT_DIR/VARIANTS.json, which build/test_wallpaper_fit.py reads.

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
FONT = os.environ.get("CYGNUS_BRAND_FONT", FONT)
TEXT = "CYGNUS   ·   NCZ-OS 26.10"
W, H = 3840, 2160
SIZE, TRACK = 40, 7           # px at 4K
RIGHT, BOTTOM = 130, 105      # margins at 4K

# 16:10 variant. A 3456x2160 window of the 3840x2160 master: the full height,
# 90% of the width. Shown with cover/zoom on a 16:9 output the variant itself
# loses 108 px at the top and bottom, so its mark sits 108 px higher than the
# original's: on a 16:9 output it then lands exactly at the original 105 px
# bottom margin, and on a 16:10 output nothing is cropped at all.
V_W, V_H = 3456, 2160
V_RIGHT, V_BOTTOM = RIGHT, BOTTOM + (V_H - V_W * 9 // 16) // 2
V_QUALITY = 88


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


def brand(im, right=RIGHT, bottom=BOTTOM):
    w, h = im.size
    font = ImageFont.truetype(FONT, SIZE)
    mask, pad, tw = text_layer(font)
    bbox = mask.getbbox()
    ox = w - right - (bbox[2] - pad)
    oy = h - bottom - (bbox[3] - pad)
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


def subject_core(im):
    """x range of the subject's bright core: blurred light above the frame
    median, thresholded at a quarter of its peak. None for a flat frame."""
    g = im.convert("L").resize((im.width // 4, im.height // 4), Image.BOX)
    g = g.filter(ImageFilter.GaussianBlur(3))
    hist = g.histogram()
    half, acc, med = g.width * g.height // 2, 0, 0
    for med, c in enumerate(hist):
        acc += c
        if acc > half:
            break
    e = g.point(lambda v: max(0, v - med - 8))
    peak = e.getextrema()[1]
    if peak == 0:
        return None
    box = e.point(lambda v: 255 if v > peak * 0.25 else 0).getbbox()
    return (box[0] * 4, box[2] * 4) if box else None


def variant_offset(im):
    """x offset of the 16:10 window. Centred, which is what cover/zoom does
    anyway, unless that clips the subject's bright core while a shifted window
    would hold all of it; then shift by the minimum that does. A core wider
    than the window (an edge-on disk spanning the frame) stays centred."""
    centre = (im.width - V_W) // 2
    core = subject_core(im)
    if core is None:
        return centre
    left, right = core
    if left >= centre and right <= centre + V_W:
        return centre
    if right - left > V_W:
        return centre
    # Move only as far as needed: left edge to the core's left when it sticks
    # out on the left, right edge to the core's right when it sticks out on
    # the right, clamped to the frame.
    x0 = left if left < centre else right - V_W
    return min(max(x0, 0), im.width - V_W)


def main_variants(src, out):
    os.makedirs(out, exist_ok=True)
    names = sorted({re.sub(r"-3840x2160\.png$", "", f) for f in os.listdir(src) if f.endswith("-3840x2160.png")})
    res, meta = [], {}
    for n in names:
        im = Image.open(f"{src}/{n}-3840x2160.png").convert("RGB")
        assert im.size == (W, H), (n, im.size)
        fid = re.sub(r"-\d{3}$", "", re.sub(r"-s\d-(?:L[\d.]+-)?\d{3}$", "", n))
        x0 = variant_offset(im)
        crop = im.crop((x0, 0, x0 + V_W, V_H))
        branded, cr = brand(crop, V_RIGHT, V_BOTTOM)
        name = f"cygnus-{fid}.jpg"
        path = f"{out}/{name}"
        branded.save(path, "JPEG", quality=V_QUALITY, optimize=True)
        with open(path, "rb") as fh:
            h = hashlib.sha256(fh.read()).hexdigest()
        print(f"{fid:22s} x0 {x0:4d}  contrast {cr:5.2f}:1  {os.path.getsize(path)} {h[:12]}")
        res.append((n, fid, cr))
        meta[name] = {"source": f"{n}-3840x2160.png", "crop": [x0, 0, x0 + V_W, V_H],
                      "mark_right": V_RIGHT, "mark_bottom": V_BOTTOM,
                      "quality": V_QUALITY, "sha256": h}
    with open(os.path.join(out, "VARIANTS.json"), "w") as f:
        json.dump({"aspect": "16x10", "size": [V_W, V_H], "files": meta}, f, indent=1, sort_keys=True)
        f.write("\n")
    bad = [r[1] for r in res if r[2] < 3.0]
    if bad:
        sys.exit("contrast below 3:1: " + ", ".join(bad))


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
    args = sys.argv[1:]
    if len(args) == 4 and args[2] == "--aspect" and args[3] == "16x10":
        main_variants(args[0], args[1])
    elif len(args) == 2:
        main(*args)
    else:
        sys.exit(__doc__)
