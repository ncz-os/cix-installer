#!/usr/bin/env python3
"""Build the Cygnus boot and desktop art from Black Hole engine renders.

Every image here starts from a frame rendered by the NCZ Black Hole engine
(ncz-screensavers blackhole_gles3); this script only crops, scales, adds
the menu scrim and draws the small UI pieces (selection rings, progress
bar, wordmark). No external or film imagery is used anywhere.

    make-cygnus-art.py refind    --src hero.png --out DIR
    make-cygnus-art.py plymouth  --src hero.png --out DIR
    make-cygnus-art.py wallpaper --src a.png [--src b.png ...] --out DIR
    make-cygnus-art.py mockup    --src wallpaper.png --out FILE

Colors come from branding/cygnus/tokens.json.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parents[1]
TOK = json.loads((ROOT / "tokens.json").read_text())
DARK = TOK["modes"]["dark"]
FONT_DIRS = [
    "/usr/share/fonts/truetype/noto",
    "/usr/share/fonts/truetype/dejavu",
    "/usr/share/fonts",
]


def hexrgb(h: str) -> tuple[int, int, int]:
    h = h.lstrip("#")
    return int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16)


def font(size: int, bold: bool = False) -> ImageFont.FreeTypeFont:
    names = (
        ["NotoSans-Bold.ttf", "DejaVuSans-Bold.ttf"]
        if bold
        else ["NotoSans-Regular.ttf", "DejaVuSans.ttf"]
    )
    for d in FONT_DIRS:
        for n in names:
            for p in Path(d).rglob(n):
                return ImageFont.truetype(str(p), size)
    return ImageFont.load_default()


# --- linear-light image pipeline -------------------------------------------
# Renders are resampled only in linear light with an area (box) filter, never
# Lanczos (ringing around the photon ring), and quantized back to 8 bits with
# TPDF dither so dark gradients do not band.


def srgb_to_linear(a: np.ndarray) -> np.ndarray:
    return np.where(a <= 0.04045, a / 12.92, ((a + 0.055) / 1.055) ** 2.4)


def linear_to_srgb(a: np.ndarray) -> np.ndarray:
    a = np.clip(a, 0.0, 1.0)
    return np.where(a <= 0.0031308, a * 12.92, 1.055 * np.power(a, 1 / 2.4) - 0.055)


def load_linear(path: str) -> tuple[np.ndarray, bytes | None]:
    im = Image.open(path)
    icc = im.info.get("icc_profile")
    arr = np.asarray(im.convert("RGB"), dtype=np.float32) / 255.0
    return srgb_to_linear(arr), icc


def resize_linear(lin: np.ndarray, w: int, h: int) -> np.ndarray:
    chans = [
        np.asarray(Image.fromarray(lin[..., c], "F").resize((w, h), Image.BOX))
        for c in range(3)
    ]
    return np.dstack(chans)


def cover_linear(
    lin: np.ndarray, w: int, h: int, focus: tuple[float, float] = (0.5, 0.5)
) -> np.ndarray:
    """Scale (area filter, linear light) to cover w x h, crop at the focus."""
    sh, sw = lin.shape[:2]
    if (sw, sh) == (w, h):
        return lin
    s = max(w / sw, h / sh)
    nw, nh = max(w, round(sw * s)), max(h, round(sh * s))
    lin = resize_linear(lin, nw, nh)
    x = int(min(max(focus[0] * nw - w / 2, 0), nw - w))
    y = int(min(max(focus[1] * nh - h / 2, 0), nh - h))
    return lin[y : y + h, x : x + w]


def to_8bit(lin: np.ndarray, seed: int = 26_10) -> Image.Image:
    rng = np.random.default_rng(seed)
    v = linear_to_srgb(lin) * 255.0
    tpdf = rng.random(v.shape, dtype=np.float32) - rng.random(v.shape, dtype=np.float32)
    return Image.fromarray(np.clip(np.round(v + tpdf), 0, 255).astype(np.uint8))


def luma(lin: np.ndarray) -> np.ndarray:
    return lin[..., 0] * 0.2126 + lin[..., 1] * 0.7152 + lin[..., 2] * 0.0722


def menu_metrics(lin: np.ndarray) -> dict:
    """rEFInd readability numbers: mean Y in the icon band (rows 35-62%)
    and p95 Y of the left third (where long labels start)."""
    h, w = lin.shape[:2]
    y = luma(lin)
    band = y[int(0.35 * h) : int(0.62 * h)]
    return {
        "band_mean_Y": float(band.mean()),
        "left_third_p95_Y": float(np.percentile(y[:, : w // 3], 95)),
        "corner_Y": float(y[:8, :8].mean()),
    }


def scrim_linear(
    lin: np.ndarray, band: tuple[float, float], alpha: float, color: str
) -> np.ndarray:
    """Darken a feathered horizontal band toward the scrim color (linear light)."""
    h = lin.shape[0]
    y0, y1 = band[0] * h, band[1] * h
    feather = 0.08 * h
    ys = np.arange(h, dtype=np.float32)
    a = (
        np.clip(
            np.minimum(
                (ys - (y0 - feather)) / feather, ((y1 + feather) - ys) / feather
            ),
            0,
            1,
        )
        * alpha
    )
    c = srgb_to_linear(np.array(hexrgb(color), dtype=np.float32) / 255.0)
    return lin * (1 - a[:, None, None]) + c * a[:, None, None]


def pin_corner(lin: np.ndarray, color: str, px: int = 8) -> np.ndarray:
    """rEFInd reads its menu background pixel from the banner's top-left
    pixel (it fills any uncovered screen area and text boxes with it, and
    picks white or black text from its brightness), so pin that corner to
    the violet-black field."""
    out = lin.copy()
    out[:px, :px] = srgb_to_linear(np.array(hexrgb(color), dtype=np.float32) / 255.0)
    return out


def cover(im: Image.Image, w: int, h: int, focus=(0.5, 0.5)) -> Image.Image:
    arr = srgb_to_linear(np.asarray(im.convert("RGB"), dtype=np.float32) / 255.0)
    return to_8bit(cover_linear(arr, w, h, focus))


def ring(size: int, stroke: float, color: str, glow: str) -> Image.Image:
    """Rounded-square selection frame: magenta stroke, soft cyan glow, clear center."""
    ss = 4
    S = size * ss
    base = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(base)
    pad = int(S * 0.08)
    rad = int(S * 0.18)
    gl = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(gl).rounded_rectangle(
        (pad, pad, S - pad, S - pad),
        rad,
        outline=hexrgb(glow) + (200,),
        width=int(stroke * ss * 2.2),
    )
    gl = gl.filter(ImageFilter.GaussianBlur(stroke * ss * 1.4))
    base.alpha_composite(gl)
    d = ImageDraw.Draw(base)
    d.rounded_rectangle(
        (pad, pad, S - pad, S - pad),
        rad,
        fill=hexrgb(DARK["surface-2"]) + (70,),
        outline=hexrgb(color) + (255,),
        width=int(stroke * ss),
    )
    return base.resize((size, size), Image.LANCZOS)


# The shipped rEFInd theme is ONE 1920x1080 background drawn with
# banner_scale fillscreen; rEFInd stretches it to the firmware GOP mode, so no
# higher-resolution exports are shipped (the 2K/4K masters stay in the project artifact store).
REFIND_SIZES = ((1920, 1080),)
BAND_MAX_Y, LEFT_P95_MAX_Y = 0.04, 0.06


def cmd_refind(a) -> None:
    """Background for the single rEFInd theme export (1920x1080, fillscreen).

    The largest source is area-downscaled in linear light. The menu scrim is
    applied only as far as needed to meet the readability targets (band mean
    Y < 0.04, left third p95 Y < 0.06)."""
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    b = TOK["boot"]["refind"]
    srcs = [load_linear(s) for s in a.src]
    report = {}
    for w, h in REFIND_SIZES:
        native = [lin for lin, _ in srcs if lin.shape[1] == w and lin.shape[0] == h]
        if native:
            lin, how = native[0], "native"
        else:
            big = max((x for x, _ in srcs), key=lambda x: x.shape[0] * x.shape[1])
            how = (
                "area-downscaled"
                if big.shape[1] >= w
                else "UPSCALED (supply a native render)"
            )
            lin = cover_linear(big, w, h, (0.5, a.focus_y))
        before = menu_metrics(lin)
        alpha = 0.0
        if a.scrim != "off":
            # Only the icon band is scrimmed; the left-third target is a
            # composition property of the render and is reported, not forced.
            while alpha < 0.9 and menu_metrics(lin)["band_mean_Y"] >= BAND_MAX_Y:
                lin = scrim_linear(lin, (0.35, 0.62), 0.1, b["menu-scrim"])
                alpha += 0.1
        lin = pin_corner(lin, b["menu-scrim"])
        after = menu_metrics(lin)
        name = f"background-{w}x{h}.png"
        im = to_8bit(lin)
        if a.wordmark:
            # Product line under the menu, above rEFInd's two help lines
            # (the same place the 26.7 banner carried its title).
            wm = wordmark(int(w * 0.30), int(h * 0.085), a.wordmark)
            im.paste(wm, ((w - wm.width) // 2, int(h * 0.80)), wm)
        im.save(out / name, optimize=True)
        report[name] = {
            "source": how,
            "scrim_steps": round(alpha, 1),
            "before": before,
            "after": after,
            "meets_targets": after["band_mean_Y"] < BAND_MAX_Y
            and after["left_third_p95_Y"] < LEFT_P95_MAX_Y,
        }
    ring(144, 5, b["selection-ring"], b["selection-glow"]).save(
        out / "selection_big.png"
    )
    ring(64, 3, b["selection-ring"], b["selection-glow"]).save(
        out / "selection_small.png"
    )
    (out / "metrics.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


def wordmark(w: int, h: int, sub: str = "26.10  \u00b7  CYGNUS") -> Image.Image:
    im = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    f1, f2 = font(int(h * 0.46), True), font(int(h * 0.20))
    t1 = "NCZ-OS"
    x1 = (w - d.textlength(t1, font=f1)) / 2
    d.text((x1, h * 0.02), t1, font=f1, fill=hexrgb(DARK["text"]) + (255,))
    x2 = (w - d.textlength(sub, font=f2)) / 2
    d.text((x2, h * 0.62), sub, font=f2, fill=hexrgb(DARK["secondary"]) + (255,))
    return im


def cmd_plymouth(a) -> None:
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    p = TOK["boot"]["plymouth"]
    lin, _ = load_linear(a.src)
    lin = cover_linear(lin, 1920, 1080, (0.5, a.focus_y)) * 0.30  # calm boot splash
    to_8bit(lin).save(out / "background.png", optimize=True)
    wordmark(720, 200, a.wordmark).save(out / "wordmark.png")
    W, H = 480, 6
    Image.new("RGBA", (W, H), hexrgb(p["progress-track"]) + (255,)).save(
        out / "progress-track.png"
    )
    g = np.linspace(0, 1, W, dtype=np.float32)[None, :, None]
    c0, c1 = (
        np.array(hexrgb(p["progress-fill-start"]), np.float32),
        np.array(hexrgb(p["progress-fill-end"]), np.float32),
    )
    fill = (c0 * (1 - g) + c1 * g).repeat(H, axis=0)
    Image.fromarray(
        np.dstack([fill, np.full((H, W, 1), 255, np.float32)]).astype(np.uint8), "RGBA"
    ).save(out / "progress-fill.png")
    box = Image.new("RGBA", (560, 64), (0, 0, 0, 0))
    ImageDraw.Draw(box).rounded_rectangle(
        (0, 0, 559, 63),
        12,
        fill=hexrgb(p["prompt-bg"]) + (235,),
        outline=hexrgb(DARK["accent"]) + (255,),
        width=2,
    )
    box.save(out / "entry.png")
    dot = Image.new("RGBA", (14, 14), (0, 0, 0, 0))
    ImageDraw.Draw(dot).ellipse((1, 1, 12, 12), fill=hexrgb(DARK["secondary"]) + (255,))
    dot.save(out / "bullet.png")


def cmd_wallpaper(a) -> None:
    """Desktop wallpapers: 3840x2160 and 2560x1440 JPEG, sRGB, ICC kept.
    A native render of the target size is used unchanged apart from the
    8-bit encode; other sizes are area-downscaled in linear light."""
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    for i, s in enumerate(a.src, 1):
        lin, icc = load_linear(s)
        stem = Path(s).stem if not a.names else a.names[i - 1]
        for w, h, tag in ((3840, 2160, "4k"), (2560, 1440, "2k")):
            kw = {
                "quality": 92,
                "subsampling": 0,
                "optimize": True,
                "progressive": True,
            }
            if icc:
                kw["icc_profile"] = icc
            to_8bit(cover_linear(lin, w, h)).save(out / f"{stem}-{tag}.jpg", **kw)


def cmd_mockup(a) -> None:
    """Static desktop mockup: panel, a window and a dialog in Cygnus dark,
    over a Cygnus wallpaper. It shows the token roles in use; it is not a
    screenshot of a running session."""
    W, H = 1920, 1080
    bg = cover(Image.open(a.src).convert("RGB"), W, H).convert("RGBA")
    d = ImageDraw.Draw(bg)
    C = {k: hexrgb(v) for k, v in DARK.items()}
    f, fb, fs = font(18), font(20, True), font(15)
    # top panel
    d.rectangle((0, 0, W, 40), fill=C["surface-1"] + (235,))
    d.text((18, 9), "NCZ-OS", font=fb, fill=C["text"])
    d.text((W / 2 - 40, 10), "Tue 20:41", font=f, fill=C["text-secondary"])
    for i, lab in enumerate(("CPU 12%", "GPU 41 C", "AC")):
        d.text(
            (W - 330 + i * 105, 10),
            lab,
            font=fs,
            fill=C["secondary"] if i == 2 else C["text-secondary"],
        )
    # window
    x0, y0, x1, y1 = 180, 150, 1080, 760
    d.rounded_rectangle((x0 + 8, y0 + 12, x1 + 8, y1 + 12), 16, fill=(0, 0, 0, 110))
    d.rounded_rectangle(
        (x0, y0, x1, y1),
        16,
        fill=C["bg"] + (250,),
        outline=C["border"] + (255,),
        width=1,
    )
    d.rounded_rectangle((x0, y0, x1, y0 + 52), 16, fill=C["surface-1"] + (255,))
    d.rectangle((x0, y0 + 36, x1, y0 + 52), fill=C["surface-1"])
    d.text((x0 + 24, y0 + 14), "Settings  -  Appearance", font=fb, fill=C["text"])
    # sidebar
    d.rectangle((x0, y0 + 52, x0 + 230, y1 - 16), fill=C["surface-1"])
    for i, it in enumerate(
        ("Appearance", "Wallpaper", "Screensaver", "Displays", "Sensors", "Network")
    ):
        yy = y0 + 76 + i * 44
        if i == 0:
            d.rounded_rectangle(
                (x0 + 12, yy - 8, x0 + 218, yy + 28), 10, fill=C["selection-bg"]
            )
        d.text(
            (x0 + 28, yy), it, font=f, fill=C["text"] if i == 0 else C["text-secondary"]
        )
    # content
    cx = x0 + 260
    d.text((cx, y0 + 76), "Theme", font=fb, fill=C["text"])
    d.text(
        (cx, y0 + 108),
        "Cygnus is the default for NCZ-OS 26.10.",
        font=f,
        fill=C["text-secondary"],
    )
    for i, (lab, col) in enumerate(
        (("Magenta", "accent-bg"), ("Cyan", "secondary"), ("Violet", "surface-3"))
    ):
        xx = cx + i * 190
        d.rounded_rectangle(
            (xx, y0 + 150, xx + 170, y0 + 250),
            14,
            fill=C["surface-2"],
            outline=C["accent"] if i == 0 else C["border"],
            width=3 if i == 0 else 1,
        )
        d.ellipse((xx + 60, y0 + 166, xx + 110, y0 + 216), fill=C[col])
        d.text(
            (xx + 85 - d.textlength(lab, font=fs) / 2, y0 + 222),
            lab,
            font=fs,
            fill=C["text"],
        )
    d.text((cx, y0 + 290), "Style", font=fb, fill=C["text"])
    d.rounded_rectangle((cx, y0 + 325, cx + 280, y0 + 365), 20, fill=C["surface-2"])
    d.rounded_rectangle((cx + 4, y0 + 329, cx + 140, y0 + 361), 16, fill=C["accent-bg"])
    d.text((cx + 50, y0 + 335), "Dark", font=f, fill=C["accent-fg"])
    d.text((cx + 186, y0 + 335), "Light", font=f, fill=C["text-secondary"])
    # toggles
    for i, lab in enumerate(
        (
            "Screensaver on AC: Black Hole (Cygnus palette)",
            "Use high-contrast text on panels",
        )
    ):
        yy = y0 + 400 + i * 56
        d.text((cx, yy + 6), lab, font=f, fill=C["text"])
        d.rounded_rectangle((x1 - 110, yy, x1 - 40, yy + 34), 17, fill=C["accent-bg"])
        d.ellipse((x1 - 76, yy + 3, x1 - 44, yy + 31), fill=C["accent-fg"])
    d.text((cx, y0 + 520), "Learn more about Cygnus", font=f, fill=C["link"])
    d.line((cx, y0 + 544, cx + 236, y0 + 544), fill=C["link"], width=1)
    # buttons
    d.rounded_rectangle((x1 - 330, y1 - 70, x1 - 190, y1 - 28), 10, fill=C["surface-3"])
    d.text((x1 - 290, y1 - 60), "Cancel", font=f, fill=C["text"])
    d.rounded_rectangle((x1 - 176, y1 - 70, x1 - 36, y1 - 28), 10, fill=C["accent-bg"])
    d.text((x1 - 136, y1 - 60), "Apply", font=f, fill=C["accent-fg"])
    # notification toast
    tx, ty = W - 470, 70
    d.rounded_rectangle(
        (tx, ty, tx + 440, ty + 96),
        14,
        fill=C["surface-2"] + (245,),
        outline=C["secondary"],
        width=2,
    )
    d.text((tx + 20, ty + 16), "Update ready", font=fb, fill=C["text"])
    d.text((tx + 20, ty + 52), "NCZ-OS 26.10 Cygnus", font=f, fill=C["secondary"])
    # dock
    dw = 520
    d.rounded_rectangle(
        ((W - dw) / 2, H - 84, (W + dw) / 2, H - 18),
        20,
        fill=C["surface-1"] + (225,),
        outline=C["border"],
    )
    for i in range(7):
        xx = (W - dw) / 2 + 26 + i * 70
        d.rounded_rectangle(
            (xx, H - 72, xx + 44, H - 30),
            12,
            fill=C["accent-bg"] if i == 0 else C["surface-3"],
        )
    d.ellipse(
        (W / 2 - dw / 2 + 44, H - 26, W / 2 - dw / 2 + 52, H - 18), fill=C["secondary"]
    )
    bg.convert("RGB").save(a.out, quality=92)


def main() -> None:
    ap = argparse.ArgumentParser()
    sp = ap.add_subparsers(dest="cmd", required=True)
    for name in ("refind", "plymouth"):
        s = sp.add_parser(name)
        s.add_argument(
            "--src", required=True, action="append" if name == "refind" else "store"
        )
        s.add_argument("--scrim", choices=("auto", "off"), default="auto")
        s.add_argument(
            "--wordmark",
            default="26.10  \u00b7  CYGNUS",
            help="subtitle under NCZ-OS; empty string for none",
        )
        s.add_argument("--out", required=True)
        s.add_argument("--focus-y", type=float, default=0.5)
    s = sp.add_parser("wallpaper")
    s.add_argument("--src", action="append", required=True)
    s.add_argument("--names", nargs="*")
    s.add_argument("--out", required=True)
    s = sp.add_parser("mockup")
    s.add_argument("--src", required=True)
    s.add_argument("--out", required=True)
    a = ap.parse_args()
    {
        "refind": cmd_refind,
        "plymouth": cmd_plymouth,
        "wallpaper": cmd_wallpaper,
        "mockup": cmd_mockup,
    }[a.cmd](a)


if __name__ == "__main__":
    main()
