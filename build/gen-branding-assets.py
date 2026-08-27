#!/usr/bin/env python3
"""
gen-branding-assets.py — multi-provider NCZ/nclawzero brand asset farm.

Two-phase workflow:

  Phase 1 (`--phase logo`):
    Each of OpenAI gpt-image-2, Together FLUX, Gemini nano-banana-pro
    generates 4 logo variants for the canonical 'NCZ over nclawzero'
    lockup → 12 candidates. Operator picks ONE.

  Phase 2 (`--phase derivatives --logo PATH`):
    Reference the operator-picked logo as input image to each provider
    for the OTHER prompts (icon-only, dark background, wallpaper).
    All providers see the exact logo glyphs and produce derivative
    assets that *inherit* it instead of inventing their own.

Outputs to assets/branding/_candidates/<prompt-id>/<provider>-<n>.png.

Reads keys from env: OPENAI_API_KEY, TOGETHER_API_KEY, GEMINI_API_KEY.
"""

import argparse
import base64
import concurrent.futures as cf
import json
import os
import pathlib
import sys
import time
import urllib.request
import urllib.error

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "assets" / "branding" / "_candidates"
OUT.mkdir(parents=True, exist_ok=True)


LOGO_PROMPT = (
    "Design a minimalist OS logo lockup. "
    "PRIMARY MARK: the three letters 'NCZ' in large clean uppercase. "
    "WORDMARK: 'nclawzero' in lowercase, smaller, tracked-out (letter-spaced), "
    "centered directly below the NCZ mark. "
    "Stacked composition. Light/white text on a deep charcoal-blue (#0b0f14) background. "
    "Geometric, intentional, restrained — like Tailscale, Fly.io, Linear, HashiCorp aesthetic. "
    "The 'N' may have a subtle claw-mark accent (a small diagonal slash or tick). "
    "1024x1024, centered composition, generous negative space. "
    "NO extra ornaments, NO photorealism, NO numbers, NO additional text beyond 'NCZ' and 'nclawzero'."
)

DERIVATIVE_PROMPTS = {
    "ncz-icon": (
        "Use the reference image's 'NCZ' lettermark exactly — same type, same proportions, "
        "same color treatment. Render it alone (without the 'nclawzero' wordmark) as a "
        "square 1:1 OS launcher icon, suitable for use at sizes 16x16 through 512x512. "
        "Centered on a deep charcoal-blue (#0b0f14) rounded-square tile. No other text, "
        "no ornament. Single icon, not a grid."
    ),
    "dark-bg": (
        "Atmospheric dark abstract background, 16:9 widescreen 1920x1080. Same color "
        "palette as the reference (deep charcoal-blue base, cyan-teal accents). "
        "Subtle topographic-mesh / circuit-trace pattern fading from upper-left to lower-right. "
        "DO NOT include the NCZ logo itself — leave a clear visual safe-zone in the center "
        "40% with no busy detail (Plymouth/GDM will overlay the logo there at runtime). "
        "Mood: edge-AI infrastructure, serious. NOT photorealistic, no objects, no text."
    ),
    "wallpaper": (
        "Default desktop wallpaper for an edge-AI Linux distro. 16:9 widescreen 1920x1080. "
        "Use the SAME color palette as the reference: deep charcoal-blue (#0b0f14) base "
        "transitioning through steel-blue to a faint cyan-teal (#21d4fd) ambient glow in "
        "the lower-left quadrant. Less busy than circuit-mesh — more painterly abstract "
        "gradient with a hint of geometric structure. Should sit comfortably behind GNOME "
        "windows. NOT photorealistic, no objects, no people, no text, no logo."
    ),
}


def _fetch(url, headers=None, body=None, method="POST", timeout=240):
    h = dict(headers or {})
    # Together AI rejects requests without a User-Agent (returns 403).
    # Default Python urllib doesn't include one — set explicitly.
    h.setdefault("User-Agent", "cix-installer/1.0 (+https://gitlab.com/nclawzero/cix-installer)")
    req = urllib.request.Request(url, data=body, method=method, headers=h)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()


# ---------------------------------------------------------------------------
# OpenAI gpt-image-2
# ---------------------------------------------------------------------------
def gen_openai_logo(prompt_id, prompt, n):
    key = os.environ["OPENAI_API_KEY"]
    # gpt-image-1: no org verification required, supports n>1, b64 response.
    # gpt-image-2 needs platform.openai.com/settings/organization verification.
    body = json.dumps({
        "model": "gpt-image-1",
        "prompt": prompt,
        "size": "1024x1024",
        "n": n,
        "quality": "high",
    }).encode()
    headers = {
        "Authorization": f"Bearer {key}",
        "Content-Type": "application/json",
    }
    raw = _fetch("https://api.openai.com/v1/images/generations", headers, body)
    d = json.loads(raw)
    out = []
    for i, item in enumerate(d.get("data", []), 1):
        b64 = item.get("b64_json")
        if not b64 and item.get("url"):
            b64 = base64.b64encode(_fetch(item["url"], method="GET")).decode()
        if b64:
            path = OUT / prompt_id / f"openai-{i}.png"
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(base64.b64decode(b64))
            out.append(str(path))
    return out


def gen_openai_with_ref(prompt_id, prompt, ref_path, n):
    """Use OpenAI's edits endpoint to bias toward the reference image."""
    key = os.environ["OPENAI_API_KEY"]
    boundary = "----nczbrandboundary"
    body_parts = []
    def field(name, value):
        body_parts.append(f"--{boundary}\r\nContent-Disposition: form-data; name=\"{name}\"\r\n\r\n{value}\r\n".encode())
    def file_field(name, filename, mime, data):
        body_parts.append(
            f"--{boundary}\r\nContent-Disposition: form-data; name=\"{name}\"; filename=\"{filename}\"\r\nContent-Type: {mime}\r\n\r\n".encode()
            + data + b"\r\n"
        )
    field("model", "gpt-image-2")
    field("prompt", prompt)
    field("size", "1024x1024")
    field("n", str(n))
    file_field("image[]", os.path.basename(ref_path), "image/png", pathlib.Path(ref_path).read_bytes())
    body_parts.append(f"--{boundary}--\r\n".encode())
    body = b"".join(body_parts)
    headers = {
        "Authorization": f"Bearer {key}",
        "Content-Type": f"multipart/form-data; boundary={boundary}",
    }
    raw = _fetch("https://api.openai.com/v1/images/edits", headers, body)
    d = json.loads(raw)
    out = []
    for i, item in enumerate(d.get("data", []), 1):
        b64 = item.get("b64_json")
        if not b64 and item.get("url"):
            b64 = base64.b64encode(_fetch(item["url"], method="GET")).decode()
        if b64:
            path = OUT / prompt_id / f"openai-{i}.png"
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(base64.b64decode(b64))
            out.append(str(path))
    return out


# ---------------------------------------------------------------------------
# Together AI FLUX (logo: FLUX.2-dev. derivatives: FLUX.1-kontext-pro for ref-image input.)
# ---------------------------------------------------------------------------
def gen_together_logo(prompt_id, prompt, n):
    key = os.environ["TOGETHER_API_KEY"]
    out = []
    for i in range(1, n + 1):
        body = json.dumps({
            "model": "black-forest-labs/FLUX.2-dev",
            "prompt": prompt,
            "width": 1024,
            "height": 1024,
            "steps": 28,
            "n": 1,
            "response_format": "b64_json",
        }).encode()
        headers = {
            "Authorization": f"Bearer {key}",
            "Content-Type": "application/json",
        }
        try:
            raw = _fetch("https://api.together.xyz/v1/images/generations", headers, body)
        except urllib.error.HTTPError:
            body2 = json.dumps({
                "model": "black-forest-labs/FLUX.1-schnell",
                "prompt": prompt,
                "width": 1024, "height": 1024, "steps": 4, "n": 1,
                "response_format": "b64_json",
            }).encode()
            raw = _fetch("https://api.together.xyz/v1/images/generations", headers, body2)
        d = json.loads(raw)
        item = d.get("data", [{}])[0]
        b64 = item.get("b64_json")
        if not b64 and item.get("url"):
            b64 = base64.b64encode(_fetch(item["url"], method="GET")).decode()
        if b64:
            path = OUT / prompt_id / f"together-{i}.png"
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(base64.b64decode(b64))
            out.append(str(path))
    return out


def gen_together_with_ref(prompt_id, prompt, ref_path, n):
    """FLUX.1-kontext-pro accepts a reference image via image_url for editing."""
    key = os.environ["TOGETHER_API_KEY"]
    ref_b64 = base64.b64encode(pathlib.Path(ref_path).read_bytes()).decode()
    image_data_url = f"data:image/png;base64,{ref_b64}"
    out = []
    for i in range(1, n + 1):
        body = json.dumps({
            "model": "black-forest-labs/FLUX.1-kontext-pro",
            "prompt": prompt,
            "width": 1024,
            "height": 1024,
            "image_url": image_data_url,
            "n": 1,
            "response_format": "b64_json",
        }).encode()
        headers = {
            "Authorization": f"Bearer {key}",
            "Content-Type": "application/json",
        }
        raw = _fetch("https://api.together.xyz/v1/images/generations", headers, body)
        d = json.loads(raw)
        item = d.get("data", [{}])[0]
        b64 = item.get("b64_json")
        if not b64 and item.get("url"):
            b64 = base64.b64encode(_fetch(item["url"], method="GET")).decode()
        if b64:
            path = OUT / prompt_id / f"together-{i}.png"
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(base64.b64decode(b64))
            out.append(str(path))
    return out


# ---------------------------------------------------------------------------
# Gemini nano-banana-pro-preview (handles both pure-text + reference image)
# ---------------------------------------------------------------------------
def gen_gemini_logo(prompt_id, prompt, n):
    return _gen_gemini_inner(prompt_id, prompt, ref_path=None, n=n)


def gen_gemini_with_ref(prompt_id, prompt, ref_path, n):
    return _gen_gemini_inner(prompt_id, prompt, ref_path=ref_path, n=n)


def _gen_gemini_inner(prompt_id, prompt, ref_path, n):
    key = os.environ["GEMINI_API_KEY"]
    out = []
    for i in range(1, n + 1):
        parts = []
        if ref_path:
            ref_b64 = base64.b64encode(pathlib.Path(ref_path).read_bytes()).decode()
            parts.append({"inline_data": {"mime_type": "image/png", "data": ref_b64}})
        parts.append({"text": prompt})
        body = json.dumps({
            "contents": [{"parts": parts}],
            "generationConfig": {
                "responseModalities": ["IMAGE"],
                "imageConfig": {"aspectRatio": "1:1"},
            },
        }).encode()
        headers = {"Content-Type": "application/json"}
        url = f"https://generativelanguage.googleapis.com/v1beta/models/nano-banana-pro-preview:generateContent?key={key}"
        try:
            raw = _fetch(url, headers, body)
        except urllib.error.HTTPError as e:
            print(f"[gemini] {prompt_id} #{i} primary failed ({e.code}); falling back to gemini-2.5-flash-image", file=sys.stderr)
            url2 = f"https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash-image:generateContent?key={key}"
            raw = _fetch(url2, headers, body)
        d = json.loads(raw)
        b64 = None
        for cand in d.get("candidates", []):
            for part in cand.get("content", {}).get("parts", []):
                blob = part.get("inline_data") or part.get("inlineData")
                if blob and blob.get("data"):
                    b64 = blob["data"]
                    break
            if b64:
                break
        if not b64:
            for pred in d.get("predictions", []):
                if pred.get("bytesBase64Encoded"):
                    b64 = pred["bytesBase64Encoded"]
                    break
        if b64:
            path = OUT / prompt_id / f"gemini-{i}.png"
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(base64.b64decode(b64))
            out.append(str(path))
        else:
            print(f"[gemini] {prompt_id} #{i}: no image in response: {raw[:300]!r}", file=sys.stderr)
    return out


PROVIDERS_LOGO = [
    ("openai",   gen_openai_logo),
    ("together", gen_together_logo),
    ("gemini",   gen_gemini_logo),
]
PROVIDERS_REF = [
    ("openai",   gen_openai_with_ref),
    ("together", gen_together_with_ref),
    ("gemini",   gen_gemini_with_ref),
]


def run_one(prompt_id, prompt, provider_name, fn, ref_path=None, n=2):
    t0 = time.time()
    try:
        if ref_path:
            paths = fn(prompt_id, prompt, ref_path, n=n)
        else:
            paths = fn(prompt_id, prompt, n=n)
        elapsed = time.time() - t0
        return f"  {provider_name:<8} {prompt_id:<14} {len(paths)} files ({elapsed:.1f}s)"
    except Exception as e:
        elapsed = time.time() - t0
        return f"  {provider_name:<8} {prompt_id:<14} FAIL  ({elapsed:.1f}s) {type(e).__name__}: {e}"


def cmd_logo():
    print(f"=== Phase 1: logo lockup ({len(PROVIDERS_LOGO)} providers × 4 variants = {len(PROVIDERS_LOGO)*4} candidates) ===")
    print(f"OUT: {OUT / 'logo-lockup'}")
    print()
    futures = []
    with cf.ThreadPoolExecutor(max_workers=6) as ex:
        for name, fn in PROVIDERS_LOGO:
            futures.append(ex.submit(run_one, "logo-lockup", LOGO_PROMPT, name, fn, n=4))
        for fut in cf.as_completed(futures):
            print(fut.result(), flush=True)
    print()
    d = OUT / "logo-lockup"
    if d.exists():
        files = sorted(d.iterdir())
        print(f"--- {len(files)} candidates ready ---")
        for f in files:
            print(f"  {f.relative_to(OUT)}  ({f.stat().st_size//1024} KB)")
        print()
        print("Next: review candidates, pick ONE canonical logo, then run:")
        print(f"  ./build/gen-branding-assets.py --phase derivatives --logo {d}/<chosen-file>.png")


def cmd_derivatives(logo_path):
    p = pathlib.Path(logo_path)
    assert p.exists(), f"logo path doesn't exist: {p}"
    print(f"=== Phase 2: derivatives w/ canonical logo ===")
    print(f"Logo: {p}  ({p.stat().st_size//1024} KB)")
    print(f"Prompts: {len(DERIVATIVE_PROMPTS)}, providers: {len(PROVIDERS_REF)}")
    print()
    futures = []
    with cf.ThreadPoolExecutor(max_workers=8) as ex:
        for prompt_id, prompt in DERIVATIVE_PROMPTS.items():
            for name, fn in PROVIDERS_REF:
                futures.append(ex.submit(run_one, prompt_id, prompt, name, fn, ref_path=str(p), n=2))
        for fut in cf.as_completed(futures):
            print(fut.result(), flush=True)
    print()
    for prompt_id in DERIVATIVE_PROMPTS:
        d = OUT / prompt_id
        if d.exists():
            files = sorted(d.iterdir())
            print(f"  {prompt_id}: {len(files)} files")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--phase", choices=["logo", "derivatives"], required=True)
    parser.add_argument("--logo", help="(phase=derivatives) path to canonical logo PNG")
    args = parser.parse_args()

    for var in ("OPENAI_API_KEY", "TOGETHER_API_KEY", "GEMINI_API_KEY"):
        if not os.environ.get(var):
            print(f"ERROR: {var} not set", file=sys.stderr); sys.exit(1)

    if args.phase == "logo":
        cmd_logo()
    else:
        if not args.logo:
            print("ERROR: --logo PATH required for phase=derivatives", file=sys.stderr); sys.exit(1)
        cmd_derivatives(args.logo)


if __name__ == "__main__":
    main()
