#!/usr/bin/env python3
"""Build the NCZ-OS screensaver showcase: gallery media, the gallery page
and the sizzle reel.

    build-showcase.py --sources SOURCES.json --out DIR [--only gallery|sizzle]

SOURCES.json lists each saver (name, status, blurb, settings, randomization)
with paths to its captured stills and clips, relative to "footage_root". It
is kept next to the captures, not in git, because capture paths name test
machines. Everything written to DIR is public-safe: files are re-encoded
from pixels only (no EXIF/PNG text chunks, container metadata stripped),
and captions contain only saver names and status.

Sizzle rules (Fable + Astra capture consult, 2026-09-30): 60-75 s, average
picture level kept low, no flashes (every cut goes through black with
0.4 s fades), captions small. Music: an original ambient bed synthesized
here with ffmpeg's own sine and noise sources; no recorded music is used.
"""

from __future__ import annotations

import argparse
import html
import json
import shutil
import subprocess
import tempfile
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

HERE = Path(__file__).resolve()
REPO = HERE.parents[3]
TOK = json.loads((REPO / "branding/cygnus/tokens.json").read_text())
D = TOK["modes"]["dark"]
W, H, FPS = 1920, 1080, 30
STATUS_LABEL = {
    "ships": "Ships in 26.10",
    "approved": "Approved",
    "candidate": "Candidate",
}
STATUS_ROLE = {"ships": "secondary", "approved": "accent", "candidate": "warning"}
TARGET_APL = 0.30  # mean luma ceiling for any sizzle segment (code value / 255)


def hexrgb(h: str) -> tuple[int, int, int]:
    h = h.lstrip("#")
    return int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16)


def font(size: int, bold: bool = False) -> ImageFont.FreeTypeFont:
    names = (
        ["NotoSans-Bold.ttf", "DejaVuSans-Bold.ttf"]
        if bold
        else ["NotoSans-Regular.ttf", "DejaVuSans.ttf"]
    )
    for d in (
        "/usr/share/fonts/truetype/noto",
        "/usr/share/fonts/truetype/dejavu",
        "/usr/share/fonts",
    ):
        for n in names:
            for p in Path(d).rglob(n):
                return ImageFont.truetype(str(p), size)
    return ImageFont.load_default()


def ff(*args: str) -> None:
    subprocess.run(
        ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", *args], check=True
    )


def mean_luma(path: Path, start: float, dur: float) -> float:
    out = subprocess.run(
        [
            "ffmpeg",
            "-hide_banner",
            "-ss",
            str(start),
            "-t",
            str(dur),
            "-i",
            str(path),
            "-vf",
            "scale=320:-2,signalstats,metadata=print:key=lavfi.signalstats.YAVG:file=-",
            "-f",
            "null",
            "-",
        ],
        capture_output=True,
        text=True,
        check=True,
    ).stdout
    vals = [float(x.split("=")[1]) for x in out.splitlines() if "YAVG" in x]
    return (sum(vals) / len(vals)) / 255.0 if vals else 0.0


# --- cards and captions ------------------------------------------------------


def card(path: Path, title: str, sub: str, foot: str = "") -> None:
    im = Image.new("RGB", (W, H), hexrgb(D["bg"]))
    d = ImageDraw.Draw(im)
    # a thin magenta-to-cyan rule, the only ornament
    for x in range(560):
        t = x / 559
        c = tuple(
            int(a * (1 - t) + b * t)
            for a, b in zip(hexrgb(D["accent-bg"]), hexrgb(D["secondary"]))
        )
        d.line((W / 2 - 280 + x, 600, W / 2 - 280 + x, 603), fill=c)
    f1, f2, f3 = font(96, True), font(40), font(28)
    d.text(
        ((W - d.textlength(title, font=f1)) / 2, 430),
        title,
        font=f1,
        fill=hexrgb(D["text"]),
    )
    d.text(
        ((W - d.textlength(sub, font=f2)) / 2, 630),
        sub,
        font=f2,
        fill=hexrgb(D["secondary"]),
    )
    if foot:
        d.text(
            ((W - d.textlength(foot, font=f3)) / 2, 720),
            foot,
            font=f3,
            fill=hexrgb(D["text-secondary"]),
        )
    im.save(path)


def caption(path: Path, name: str, status: str) -> None:
    im = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    f1, f2 = font(40, True), font(24, True)
    label = STATUS_LABEL[status]
    tw = d.textlength(name, font=f1)
    lw = d.textlength(label, font=f2)
    x, y = 72, H - 150
    d.rounded_rectangle(
        (x - 24, y - 18, x + max(tw, lw + 40) + 24, y + 96),
        18,
        fill=hexrgb(D["bg"]) + (190,),
    )
    d.text((x, y), name, font=f1, fill=hexrgb(D["text"]))
    col = hexrgb(D[STATUS_ROLE[status]])
    d.rounded_rectangle(
        (x, y + 56, x + lw + 28, y + 88), 16, outline=col + (255,), width=2
    )
    d.text((x + 14, y + 58), label, font=f2, fill=col)
    im.save(path)


# --- segments ----------------------------------------------------------------


def seg_card(tmp: Path, png: Path, dur: float, out: Path) -> None:
    ff(
        "-loop",
        "1",
        "-t",
        str(dur),
        "-i",
        str(png),
        "-vf",
        f"fps={FPS},format=yuv420p,fade=t=in:st=0:d=0.6,fade=t=out:st={dur - 0.6}:d=0.6",
        "-c:v",
        "libx264",
        "-crf",
        "16",
        "-preset",
        "medium",
        str(out),
    )


def seg_still(still: Path, cap: Path, dur: float, out: Path) -> None:
    n = int(dur * FPS)
    vf = (
        f"[0:v]scale={W * 2}:{H * 2}:flags=bicubic,zoompan=z='1+0.05*on/{n}':d={n}:"
        f"x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':s={W}x{H}:fps={FPS}[v];"
        f"[v][1:v]overlay=0:0,format=yuv420p,fade=t=in:st=0:d=0.4,fade=t=out:st={dur - 0.4}:d=0.4"
    )
    ff(
        "-loop",
        "1",
        "-t",
        str(dur),
        "-i",
        str(still),
        "-loop",
        "1",
        "-t",
        str(dur),
        "-i",
        str(cap),
        "-filter_complex",
        vf,
        "-frames:v",
        str(n),
        "-c:v",
        "libx264",
        "-crf",
        "16",
        "-preset",
        "medium",
        str(out),
    )


def seg_clip(clip: Path, cap: Path, start: float, dur: float, out: Path) -> float:
    apl = mean_luma(clip, start, dur)
    gain = min(1.0, TARGET_APL / apl) if apl > 0 else 1.0
    lut = f"lutyuv=y='16+(val-16)*{gain:.3f}'" if gain < 0.999 else "null"
    vf = (
        f"[0:v]fps={FPS},scale={W}:{H}:flags=bicubic,{lut}[v];[v][1:v]overlay=0:0,"
        f"format=yuv420p,fade=t=in:st=0:d=0.4,fade=t=out:st={dur - 0.4}:d=0.4"
    )
    ff(
        "-ss",
        str(start),
        "-t",
        str(dur),
        "-i",
        str(clip),
        "-loop",
        "1",
        "-t",
        str(dur),
        "-i",
        str(cap),
        "-filter_complex",
        vf,
        "-an",
        "-c:v",
        "libx264",
        "-crf",
        "16",
        "-preset",
        "medium",
        str(out),
    )
    return gain


def ambient_bed(dur: float, out: Path) -> None:
    """Original generated drone: open fifths on A with slow tremolo and a
    little filtered pink noise. Nothing sampled, nothing recorded."""
    tones = [(55.0, 0.30), (82.41, 0.22), (110.0, 0.18), (164.81, 0.10), (220.0, 0.05)]
    inputs, labels = [], []
    for i, (f, v) in enumerate(tones):
        inputs += [
            "-f",
            "lavfi",
            "-i",
            f"sine=frequency={f}:sample_rate=48000:duration={dur}",
        ]
        labels.append(f"[{i}:a]volume={v},tremolo=f={0.11 + 0.04 * i}:d=0.35[t{i}]")
    n = len(tones)
    inputs += [
        "-f",
        "lavfi",
        "-i",
        f"anoisesrc=color=pink:amplitude=0.05:duration={dur}:sample_rate=48000",
    ]
    labels.append(f"[{n}:a]lowpass=f=500,volume=0.5[nz]")
    mix = "".join(f"[t{i}]" for i in range(n)) + "[nz]"
    fc = ";".join(labels) + (
        f";{mix}amix=inputs={n + 1}:normalize=0,aecho=0.6:0.5:900|1400:0.25|0.18,"
        f"lowpass=f=2400,afade=t=in:st=0:d=4,afade=t=out:st={dur - 5}:d=5,"
        "loudnorm=I=-24:TP=-3:LRA=7,aformat=channel_layouts=stereo[a]"
    )
    ff(
        *inputs,
        "-filter_complex",
        fc,
        "-map",
        "[a]",
        "-c:a",
        "aac",
        "-b:a",
        "192k",
        str(out),
    )


def build_sizzle(src: dict, out: Path, tmp: Path) -> dict:
    root = Path(src["footage_root"])
    segs, notes = [], []
    card(tmp / "title.png", "NCZ-OS 26.10", "Cygnus", "The screensavers")
    seg_card(tmp, tmp / "title.png", 5.0, tmp / "s000.mp4")
    segs.append(tmp / "s000.mp4")
    k = 1
    for s in src["savers"]:
        cap = tmp / f"cap-{s['id']}.png"
        caption(cap, s["name"], s["status"])
        if s.get("clip"):
            o = tmp / f"s{k:03d}.mp4"
            g = seg_clip(root / s["clip"], cap, 3.0, 5.5, o)
            notes.append(
                {
                    "saver": s["id"],
                    "kind": "clip",
                    "seconds": 5.5,
                    "exposure_gain": round(g, 3),
                }
            )
            segs.append(o)
            k += 1
        else:
            for st in s["stills"][: 4 if s["id"] == "blackhole" else 2]:
                o = tmp / f"s{k:03d}.mp4"
                seg_still(root / st, cap, 3.5, o)
                notes.append(
                    {"saver": s["id"], "kind": "still (slow push-in)", "seconds": 3.5}
                )
                segs.append(o)
                k += 1
    card(
        tmp / "outro.png",
        "84 screensavers",
        "Every run is different",
        "NCZ-OS 26.10 Cygnus",
    )
    seg_card(tmp, tmp / "outro.png", 5.0, tmp / "s999.mp4")
    segs.append(tmp / "s999.mp4")
    (tmp / "list.txt").write_text("".join(f"file '{p}'\n" for p in segs))
    ff(
        "-f",
        "concat",
        "-safe",
        "0",
        "-i",
        str(tmp / "list.txt"),
        "-c",
        "copy",
        str(tmp / "video.mp4"),
    )
    dur = float(
        subprocess.run(
            [
                "ffprobe",
                "-v",
                "error",
                "-show_entries",
                "format=duration",
                "-of",
                "csv=p=0",
                str(tmp / "video.mp4"),
            ],
            capture_output=True,
            text=True,
            check=True,
        ).stdout.strip()
    )
    ambient_bed(dur, tmp / "bed.m4a")
    common = [
        "-i",
        str(tmp / "video.mp4"),
        "-i",
        str(tmp / "bed.m4a"),
        "-map",
        "0:v",
        "-map",
        "1:a",
        "-map_metadata",
        "-1",
        "-map_chapters",
        "-1",
        "-shortest",
    ]
    ff(
        *common,
        "-vf",
        "noise=alls=2:allf=t,format=yuv420p",
        "-c:v",
        "libx264",
        "-crf",
        "18",
        "-preset",
        "slow",
        "-profile:v",
        "high",
        "-color_primaries",
        "bt709",
        "-color_trc",
        "bt709",
        "-colorspace",
        "bt709",
        "-c:a",
        "copy",
        "-movflags",
        "+faststart",
        str(out / "ncz-os-26.10-screensavers-sizzle.mp4"),
    )
    ff(
        *common,
        "-c:v",
        "libvpx-vp9",
        "-crf",
        "32",
        "-b:v",
        "0",
        "-row-mt",
        "1",
        "-c:a",
        "libopus",
        "-b:a",
        "128k",
        str(out / "ncz-os-26.10-screensavers-sizzle.webm"),
    )
    return {"duration_s": round(dur, 2), "segments": notes, "target_apl": TARGET_APL}


# --- gallery ----------------------------------------------------------------


def build_gallery_media(src: dict, media: Path) -> None:
    root = Path(src["footage_root"])
    media.mkdir(parents=True, exist_ok=True)
    for s in src["savers"]:
        for i, st in enumerate(s["stills"][:3]):
            im = Image.open(root / st).convert(
                "RGB"
            )  # pixels only: no EXIF/text chunks survive
            im.thumbnail((1600, 900))
            im.save(media / f"{s['id']}-{i + 1}.webp", quality=86, method=6)
        if s.get("clip"):
            base = [
                "-ss",
                "2",
                "-t",
                "6",
                "-i",
                str(root / s["clip"]),
                "-an",
                "-map_metadata",
                "-1",
                "-vf",
                "fps=30,scale=1280:-2:flags=bicubic",
            ]
            ff(
                *base,
                "-c:v",
                "libvpx-vp9",
                "-crf",
                "36",
                "-b:v",
                "0",
                "-row-mt",
                "1",
                str(media / f"{s['id']}.webm"),
            )
            ff(
                *base,
                "-c:v",
                "libx264",
                "-crf",
                "26",
                "-pix_fmt",
                "yuv420p",
                "-movflags",
                "+faststart",
                str(media / f"{s['id']}.mp4"),
            )


def gallery_html(src: dict, media_names: set[str]) -> str:
    cards = []
    for s in src["savers"]:
        sid = s["id"]
        poster = f"media/{sid}-1.webp"
        if f"{sid}.webm" in media_names:
            vis = (
                f'<video autoplay muted loop playsinline preload="metadata" poster="{poster}">'
                f'<source src="media/{sid}.webm" type="video/webm">'
                f'<source src="media/{sid}.mp4" type="video/mp4"></video>'
            )
        else:
            vis = f'<img src="{poster}" alt="{html.escape(s["name"])} screensaver still" loading="lazy">'
        extra = "".join(
            f'<img class="thumb" src="media/{sid}-{i}.webp" alt="" loading="lazy">'
            for i in (2, 3)
            if f"{sid}-{i}.webp" in media_names
        )
        cards.append(f"""
      <article class="card">
        <div class="vis">{vis}</div>
        <div class="body">
          <div class="head"><h2>{html.escape(s["name"])}</h2>
            <span class="pill {s["status"]}">{STATUS_LABEL[s["status"]]}</span></div>
          <p>{html.escape(s["blurb"])}</p>
          <dl>
            <dt>Engine</dt><dd>{html.escape(s["engine"])}</dd>
            <dt>Settings</dt><dd>{html.escape(s["settings"])}</dd>
            <dt>Randomization</dt><dd>{html.escape(s["randomization"])}</dd>
          </dl>
          {f'<div class="thumbs">{extra}</div>' if extra else ""}
        </div>
      </article>""")
    css = (REPO / "branding/cygnus/generated/css/cygnus.css").read_text()
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>NCZ-OS Screensavers</title>
<meta name="description" content="The NCZ-OS 26.10 Cygnus screensaver showcase: stills, loops, settings and randomization notes.">
<style>
{css}
body {{ margin: 0; background: var(--cy-bg); color: var(--cy-text);
  font: 16px/1.55 "Noto Sans", "DejaVu Sans", system-ui, sans-serif; }}
header {{ padding: 56px 16px 24px; max-width: 1200px; margin: 0 auto; }}
header h1 {{ font-size: clamp(28px, 5vw, 48px); margin: 0 0 8px; letter-spacing: .01em; }}
header p {{ color: var(--cy-text-secondary); max-width: 70ch; margin: 0; }}
.rule {{ height: 3px; width: 220px; margin: 18px 0; background: linear-gradient(90deg, var(--cy-accent-bg), var(--cy-secondary)); }}
.sizzle {{ max-width: 1200px; margin: 0 auto 32px; padding: 0 16px; }}
.sizzle video {{ width: 100%; border-radius: 14px; background: #000; border: 1px solid var(--cy-border); }}
main {{ max-width: 1200px; margin: 0 auto; padding: 0 16px 64px; display: grid; gap: 20px;
  grid-template-columns: repeat(auto-fill, minmax(min(100%, 360px), 1fr)); }}
.card {{ background: var(--cy-surface-1); border: 1px solid var(--cy-border); border-radius: 16px; overflow: hidden; }}
.vis {{ aspect-ratio: 16 / 9; background: #000; }}
.vis video, .vis img {{ width: 100%; height: 100%; object-fit: cover; display: block; }}
.body {{ padding: 16px 18px 18px; }}
.head {{ display: flex; align-items: center; justify-content: space-between; gap: 12px; }}
h2 {{ font-size: 20px; margin: 0; }}
.pill {{ font-size: 12px; font-weight: 700; padding: 3px 10px; border-radius: 999px; border: 1.5px solid; white-space: nowrap; }}
.pill.ships {{ color: var(--cy-secondary); }}
.pill.approved {{ color: var(--cy-accent); }}
.pill.candidate {{ color: var(--cy-warning); }}
p {{ color: var(--cy-text-secondary); }}
dl {{ display: grid; grid-template-columns: max-content 1fr; gap: 4px 12px; font-size: 14px; margin: 0; }}
dt {{ color: var(--cy-text-muted); }} dd {{ margin: 0; color: var(--cy-text); }}
.thumbs {{ display: flex; gap: 8px; margin-top: 12px; }}
.thumb {{ width: calc(50% - 4px); aspect-ratio: 16/9; object-fit: cover; border-radius: 8px; }}
footer {{ max-width: 1200px; margin: 0 auto; padding: 0 16px 48px; color: var(--cy-text-muted); font-size: 14px; }}
a {{ color: var(--cy-link); }}
</style>
</head>
<body>
<header>
  <h1>NCZ-OS screensavers</h1>
  <div class="rule"></div>
  <p>Captured from the real screensavers running on NCZ-OS. Nothing here is a mock-up, a film still or a photograph.
  <strong>Ships in 26.10</strong> means the saver is in the 84-saver set. <strong>Approved</strong> means it has been approved and is on its way into that set.
  <strong>Candidate</strong> means it is shown for feedback and is not approved yet.</p>
</header>
<section class="sizzle" aria-label="Sizzle reel">
  <video controls preload="metadata" poster="media/blackhole-1.webp">
    <source src="media/ncz-os-26.10-screensavers-sizzle.webm" type="video/webm">
    <source src="media/ncz-os-26.10-screensavers-sizzle.mp4" type="video/mp4">
  </video>
</section>
<main>{"".join(cards)}
</main>
<footer>NCZ-OS 26.10 "Cygnus". All imagery is rendered by NCZ-OS screensaver code. The sizzle soundtrack is an original ambient bed generated for this page.</footer>
</body>
</html>
"""


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--sources", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--only", choices=("gallery", "sizzle"))
    a = ap.parse_args()
    src = json.loads(Path(a.sources).read_text())
    out = Path(a.out)
    media = out / "media"
    media.mkdir(parents=True, exist_ok=True)
    report = {}
    if a.only in (None, "gallery"):
        build_gallery_media(src, media)
    if a.only in (None, "sizzle"):
        tmp = Path(tempfile.mkdtemp(prefix="sizzle.", dir=out))
        try:
            report["sizzle"] = build_sizzle(src, media, tmp)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
    (out / "index.html").write_text(
        gallery_html(src, {p.name for p in media.iterdir()})
    )
    (out / "build-report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
