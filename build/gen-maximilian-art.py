#!/usr/bin/env python3
# gen-maximilian-art.py — procedural RETRO DIGITAL ART for NCZ-OS 26.7 "Maximilian".
# Theme: Disney's The Black Hole (1979). Original homage art (not a copy).
#   1) maximilian-robot-splash.png  — menacing red robot head (rEFInd banner)
#   2) ncx-wallpaper-07-maximilian-2k.jpg — red scary black hole (desktop wallpaper)
# Deterministic (fixed seed). Requires Pillow + numpy. No AI, no external assets.
import math, numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont, ImageChops

BG   = (11, 15, 20)        # #0b0f14 deep charcoal-blue (brand base)
REDC = (255, 42, 42)       # core red
REDD = (120, 12, 16)       # deep red
AMBER= (255, 120, 40)      # accretion amber
np.random.seed(1979)

def radial(w, h, cx, cy, inner, outer, c_in, c_out):
    """radial gradient RGB array"""
    yy, xx = np.mgrid[0:h, 0:w]
    d = np.sqrt((xx - cx) ** 2 + (yy - cy) ** 2)
    t = np.clip((d - inner) / max(1, (outer - inner)), 0, 1)
    out = np.zeros((h, w, 3), np.float32)
    for i in range(3):
        out[..., i] = c_in[i] * (1 - t) + c_out[i] * t
    return out

def scanlines(img, gap=3, dark=0.72):
    a = np.array(img).astype(np.float32)
    a[::gap, :, :] *= dark
    return Image.fromarray(np.clip(a, 0, 255).astype(np.uint8))

def add_noise(img, amt=6):
    a = np.array(img).astype(np.float32)
    a += np.random.normal(0, amt, a.shape)
    return Image.fromarray(np.clip(a, 0, 255).astype(np.uint8))

def vignette(img, strength=0.55):
    w, h = img.size
    v = radial(w, h, w/2, h/2, min(w, h)*0.25, max(w, h)*0.75, (255,255,255), (255*(1-strength),)*3)
    v = (v[..., 0] / 255.0)
    a = np.array(img).astype(np.float32)
    for i in range(3):
        a[..., i] *= v
    return Image.fromarray(np.clip(a, 0, 255).astype(np.uint8))

def synth_grid(draw, w, h, horizon, color, step=46, glow=1):
    # perspective floor grid (synthwave)
    for gx in range(-w, 2*w, step):
        draw.line([(gx, h), (w/2, horizon)], fill=color, width=glow)
    y = horizon; d = 6
    while y < h:
        draw.line([(0, y), (w, y)], fill=color, width=glow)
        d *= 1.28; y += d

def font(sz):
    for p in ("/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf",
              "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"):
        try: return ImageFont.truetype(p, sz)
        except Exception: pass
    return ImageFont.load_default()

def glow_text(base, xy, txt, fnt, col, blur=8, anchor="mm"):
    w, h = base.size
    lay = Image.new("RGB", (w, h), (0, 0, 0)); d = ImageDraw.Draw(lay)
    d.text(xy, txt, font=fnt, fill=col, anchor=anchor)
    g = lay.filter(ImageFilter.GaussianBlur(blur))
    base = ImageChops.screen(base, g)
    d2 = ImageDraw.Draw(base); d2.text(xy, txt, font=fnt, fill=(255, 235, 235), anchor=anchor)
    return base

# ---------------------------------------------------------------- ROBOT SPLASH
def robot_splash(W=1920, H=1080):
    base = Image.fromarray(radial(W, H, W/2, H*0.42, 80, W*0.8,
                                  (26, 16, 20), BG).astype(np.uint8))
    gl = Image.new("RGB", (W, H), (0, 0, 0)); gd = ImageDraw.Draw(gl)
    synth_grid(gd, W, H, int(H*0.72), (70, 12, 16), step=64, glow=2)
    base = ImageChops.screen(base, gl.filter(ImageFilter.GaussianBlur(1)))

    d = ImageDraw.Draw(base, "RGBA")
    cx, cy = W/2, H*0.44; rw, rh = W*0.16, H*0.30   # helmet half-extents
    # ---- head: rounded industrial dome (dark chromed metal) ----
    metal = Image.new("RGB", (W, H), (0, 0, 0)); md = ImageDraw.Draw(metal)
    for i, shade in enumerate([(54, 40, 44), (40, 28, 32), (28, 18, 22)]):
        pad = i * 10
        md.rounded_rectangle([cx-rw+pad, cy-rh+pad, cx+rw-pad, cy+rh*0.9-pad],
                             radius=int(rw*0.5), fill=shade)
    metal = metal.filter(ImageFilter.GaussianBlur(2))
    mask = Image.new("L", (W, H), 0)
    ImageDraw.Draw(mask).rounded_rectangle([cx-rw, cy-rh, cx+rw, cy+rh*0.9],
                                           radius=int(rw*0.5), fill=255)
    base.paste(metal, (0, 0), mask)
    d = ImageDraw.Draw(base, "RGBA")
    # rim light (red)
    d.rounded_rectangle([cx-rw, cy-rh, cx+rw, cy+rh*0.9], radius=int(rw*0.5),
                        outline=(150, 20, 24, 255), width=5)
    # panel seams + rivets
    for yy in (cy-rh*0.55, cy+rh*0.35):
        d.line([(cx-rw*0.85, yy), (cx+rw*0.85, yy)], fill=(20, 12, 14, 220), width=3)
    for rx in np.linspace(cx-rw*0.8, cx+rw*0.8, 7):
        d.ellipse([rx-4, cy-rh*0.78-4, rx+4, cy-rh*0.78+4], fill=(90, 60, 62, 255))
    # ---- the menacing glowing red VISOR (Maximilian's eye-slit) ----
    vy = cy - rh*0.08; vh = rh*0.13
    visor = Image.new("RGB", (W, H), (0, 0, 0)); vd = ImageDraw.Draw(visor)
    vd.rounded_rectangle([cx-rw*0.82, vy-vh, cx+rw*0.82, vy+vh], radius=int(vh),
                         fill=REDD)
    vd.rounded_rectangle([cx-rw*0.78, vy-vh*0.5, cx+rw*0.78, vy+vh*0.5],
                         radius=int(vh*0.5), fill=REDC)
    vd.rounded_rectangle([cx-rw*0.6, vy-vh*0.18, cx+rw*0.6, vy+vh*0.18],
                         radius=int(vh*0.2), fill=(255, 180, 170))
    vg = visor.filter(ImageFilter.GaussianBlur(26))
    base = ImageChops.screen(base, vg)          # bloom
    base = ImageChops.screen(base, visor)       # crisp core
    d = ImageDraw.Draw(base, "RGBA")
    # ---- vertical mouth grille ----
    gy0, gy1 = cy+rh*0.18, cy+rh*0.62
    for gx in np.linspace(cx-rw*0.4, cx+rw*0.4, 9):
        d.line([(gx, gy0), (gx, gy1)], fill=(150, 20, 24, 255), width=4)
    d.rectangle([cx-rw*0.46, gy0-6, cx+rw*0.46, gy1+6], outline=(60, 16, 18, 255), width=3)
    # two red status dots
    for sx in (cx-rw*0.62, cx+rw*0.62):
        d.ellipse([sx-7, cy+rh*0.5-7, sx+7, cy+rh*0.5+7], fill=(255, 60, 50, 255))

    base = scanlines(base, gap=3, dark=0.74)
    base = add_noise(base, 5)
    base = vignette(base, 0.5)
    # wordmark
    base = glow_text(base, (W/2, H*0.86), "N C Z - O S", font(84), (255, 60, 55), blur=10)
    base = glow_text(base, (W/2, H*0.925), "26.7  ·  MAXIMILIAN", font(38), (200, 40, 40), blur=6)
    return base

# ---------------------------------------------------------------- BLACK HOLE WP
def blackhole(W=2560, H=1440):
    # starfield
    a = np.full((H, W, 3), BG, np.float32)
    sx = np.random.randint(0, W, 900); sy = np.random.randint(0, H, 900)
    sb = np.random.uniform(40, 200, 900)
    for x, y, b in zip(sx, sy, sb):
        a[y, x] = (b, b*0.9, b*0.95)
    base = Image.fromarray(a.astype(np.uint8)).filter(ImageFilter.GaussianBlur(0.4))

    cx, cy = W*0.5, H*0.46
    R = H*0.17                       # event horizon radius
    # accretion disk: red/amber ring with lensing (draw as rotated ellipses + glow)
    disk = Image.new("RGB", (W, H), (0, 0, 0)); dd = ImageDraw.Draw(disk)
    for i in range(80):
        t = i/80.0
        rr = R*(1.15 + t*1.7)
        col = tuple(int(REDC[k]*(1-t) + AMBER[k]*t) for k in range(3))
        col = tuple(int(c*(0.25+0.75*(1-t))) for c in col)
        dd.ellipse([cx-rr, cy-rr*0.32, cx+rr, cy+rr*0.32], outline=col, width=4)
    # top gravitational-lensing arc (light bent over the hole)
    for i in range(60):
        t = i/60.0; rr = R*(1.2+t*1.6)
        col = tuple(int(AMBER[k]*(1-t*0.7)) for k in range(3))
        dd.arc([cx-rr, cy-rr*1.15, cx+rr, cy+rr*0.2], 200, 340, fill=col, width=3)
    disk_glow = disk.filter(ImageFilter.GaussianBlur(20))
    base = ImageChops.screen(base, disk_glow)
    base = ImageChops.screen(base, disk.filter(ImageFilter.GaussianBlur(2)))
    # photon ring (hot red rim) + black event horizon
    d = ImageDraw.Draw(base, "RGBA")
    ring = Image.new("RGB", (W, H), (0, 0, 0)); rd = ImageDraw.Draw(ring)
    rd.ellipse([cx-R*1.06, cy-R*1.06, cx+R*1.06, cy+R*1.06], outline=(255, 70, 50), width=10)
    base = ImageChops.screen(base, ring.filter(ImageFilter.GaussianBlur(14)))
    base = ImageChops.screen(base, ring.filter(ImageFilter.GaussianBlur(2)))
    d = ImageDraw.Draw(base, "RGBA")
    d.ellipse([cx-R, cy-R, cx+R, cy+R], fill=(2, 2, 4, 255))          # the void
    d.ellipse([cx-R, cy-R, cx+R, cy+R], outline=(255, 90, 70, 255), width=3)

    base = scanlines(base, gap=4, dark=0.82)
    base = add_noise(base, 4)
    base = vignette(base, 0.6)
    base = glow_text(base, (W*0.5, H*0.9), "MAXIMILIAN", font(60), (210, 40, 38), blur=9)
    return base

if __name__ == "__main__":
    import sys
    out = sys.argv[1] if len(sys.argv) > 1 else "."
    robot_splash().save(f"{out}/maximilian-robot-splash.png")
    print("wrote maximilian-robot-splash.png")
    blackhole().convert("RGB").save(f"{out}/ncx-wallpaper-07-maximilian-2k.jpg", quality=90)
    print("wrote ncx-wallpaper-07-maximilian-2k.jpg")
