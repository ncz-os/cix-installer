#!/usr/bin/env python3
"""Generate every Cygnus theme consumer from branding/cygnus/tokens.json.

    branding/cygnus/tools/gen-cygnus.py            # write generated/
    branding/cygnus/tools/gen-cygnus.py --check    # exit 1 if generated/ is stale

tokens.json is the only file a person edits. Everything under generated/
is derived here, so a palette change is one edit plus one run, and the
contrast gate (tests/test_cygnus_contrast.py) runs --check to catch a
forgotten regeneration.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "generated"
HEADER = (
    "Generated from branding/cygnus/tokens.json by tools/gen-cygnus.py. Do not edit."
)


def rgb(h: str) -> tuple[int, int, int]:
    h = h.lstrip("#")
    return int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16)


def css_vars(t: dict) -> str:
    lines = [
        f"/* {HEADER} */",
        "/* NCZ-OS 26.10 Cygnus: CSS custom properties (web, docs, showcase). */",
        "",
    ]
    lines.append(":root {")
    for scale, vals in t["scales"].items():
        for k, v in vals.items():
            lines.append(f"  --cygnus-{scale}-{k}: {v};")
    lines.append("}")
    for mode in ("dark", "light"):
        sel = (
            ':root, :root[data-theme="dark"]'
            if mode == "dark"
            else ':root[data-theme="light"]'
        )
        lines.append(f"{sel} {{")
        lines.append(f"  color-scheme: {mode};")
        for k, v in t["modes"][mode].items():
            lines.append(f"  --cy-{k}: {v};")
        lines.append("}")
    lines.append("@media (prefers-color-scheme: light) {")
    lines.append('  :root:not([data-theme="dark"]) {')
    lines.append("    color-scheme: light;")
    for k, v in t["modes"]["light"].items():
        lines.append(f"    --cy-{k}: {v};")
    lines.append("  }")
    lines.append("}")
    return "\n".join(lines) + "\n"


# libadwaita / GTK4 named colors. Singularity's own widgets read these when
# they follow the platform style sheet; the mapping is the documented
# libadwaita set, so nothing upstream needs patching to consume it.
ADW_MAP = {
    "accent_color": "accent",
    "accent_bg_color": "accent-bg",
    "accent_fg_color": "accent-fg",
    "destructive_color": "error",
    "destructive_bg_color": "error",
    "destructive_fg_color": "on-status",
    "success_color": "success",
    "success_bg_color": "success",
    "success_fg_color": "on-status",
    "warning_color": "warning",
    "warning_bg_color": "warning",
    "warning_fg_color": "on-status",
    "error_color": "error",
    "error_bg_color": "error",
    "error_fg_color": "on-status",
    "window_bg_color": "bg",
    "window_fg_color": "text",
    "view_bg_color": "surface-1",
    "view_fg_color": "text",
    "headerbar_bg_color": "surface-1",
    "headerbar_fg_color": "text",
    "headerbar_border_color": "border",
    "headerbar_backdrop_color": "bg",
    "sidebar_bg_color": "surface-1",
    "sidebar_fg_color": "text",
    "sidebar_backdrop_color": "bg",
    "card_bg_color": "surface-2",
    "card_fg_color": "text",
    "dialog_bg_color": "surface-2",
    "dialog_fg_color": "text",
    "popover_bg_color": "surface-2",
    "popover_fg_color": "text",
    "thumbnail_bg_color": "surface-2",
    "thumbnail_fg_color": "text",
    "shade_color": "shadow",
}


def gtk_named(t: dict, mode: str) -> str:
    m = t["modes"][mode]
    lines = [f"/* {HEADER} */", f"/* Cygnus {mode}: libadwaita/GTK4 named colors. */"]
    for name, role in ADW_MAP.items():
        val = m[role]
        if name == "shade_color":
            r, g, b = rgb(val)
            lines.append(f"@define-color {name} rgba({r},{g},{b},0.36);")
        else:
            lines.append(f"@define-color {name} {val};")
    lines.append(f"@define-color cygnus_secondary_color {m['secondary']};")
    lines.append(f"@define-color cygnus_focus_color {m['focus-ring']};")
    return "\n".join(lines) + "\n"


def setvtrgb(pal: list[str]) -> str:
    cols = [rgb(c) for c in pal]
    return "\n".join(",".join(str(c[i]) for c in cols) for i in range(3)) + "\n"


def vt_cmdline(pal: list[str]) -> str:
    cols = [rgb(c) for c in pal]
    parts = []
    for i, name in enumerate(("red", "grn", "blu")):
        parts.append(f"vt.default_{name}=" + ",".join(f"0x{c[i]:02x}" for c in cols))
    return " ".join(parts) + "\n"


def newt_colors(t: dict) -> str:
    return ";".join(f"{k}={fg},{bg}" for k, (fg, bg) in t["newt"]["palette"].items())


def terminal_foot(t: dict) -> str:
    m, c = t["modes"]["dark"], t["console"]["tty"]
    lines = [f"# {HEADER}", "# foot.ini [colors] section, Cygnus dark.", "[colors]"]
    lines.append(f"foreground={m['text'][1:]}")
    lines.append(f"background={m['bg'][1:]}")
    lines.append(f"selection-foreground={m['selection-fg'][1:]}")
    lines.append(f"selection-background={m['selection-bg'][1:]}")
    lines.append(f"cursor={m['bg'][1:]} {m['secondary'][1:]}")
    for i in range(8):
        lines.append(f"regular{i}={c[i][1:]}")
    for i in range(8):
        lines.append(f"bright{i}={c[8 + i][1:]}")
    return "\n".join(lines) + "\n"


def terminal_alacritty(t: dict) -> str:
    m, c = t["modes"]["dark"], t["console"]["tty"]
    names = ["black", "red", "green", "yellow", "blue", "magenta", "cyan", "white"]
    out = [
        f"# {HEADER}",
        "# Alacritty colors, Cygnus dark.",
        "[colors.primary]",
        f'background = "{m["bg"]}"',
        f'foreground = "{m["text"]}"',
        "",
        "[colors.cursor]",
        f'cursor = "{m["secondary"]}"',
        f'text = "{m["bg"]}"',
        "",
        "[colors.selection]",
        f'background = "{m["selection-bg"]}"',
        f'text = "{m["selection-fg"]}"',
        "",
        "[colors.normal]",
    ]
    out += [f'{n} = "{c[i]}"' for i, n in enumerate(names)]
    out += ["", "[colors.bright]"]
    out += [f'{n} = "{c[8 + i]}"' for i, n in enumerate(names)]
    return "\n".join(out) + "\n"


def terminal_kitty(t: dict) -> str:
    m, c = t["modes"]["dark"], t["console"]["tty"]
    out = [
        f"# {HEADER}",
        "# kitty.conf color block, Cygnus dark.",
        f"foreground {m['text']}",
        f"background {m['bg']}",
        f"selection_foreground {m['selection-fg']}",
        f"selection_background {m['selection-bg']}",
        f"cursor {m['secondary']}",
        f"url_color {m['link']}",
        f"active_border_color {m['accent']}",
        f"inactive_border_color {m['border']}",
    ]
    out += [f"color{i} {v}" for i, v in enumerate(c)]
    return "\n".join(out) + "\n"


def terminal_vte_dconf(t: dict) -> str:
    """GNOME Terminal / Ptyxis-style palette as a dconf keyfile fragment."""
    m, c = t["modes"]["dark"], t["console"]["tty"]
    pal = ", ".join(f"'{v}'" for v in c)
    return (
        f"# {HEADER}\n# VTE palette (dconf keyfile syntax) for terminals that read one.\n"
        f"background-color='{m['bg']}'\nforeground-color='{m['text']}'\n"
        f"cursor-background-color='{m['secondary']}'\ncursor-foreground-color='{m['bg']}'\n"
        f"highlight-background-color='{m['selection-bg']}'\nhighlight-foreground-color='{m['selection-fg']}'\n"
        f"palette=[{pal}]\n"
    )


def plymouth_colors(t: dict) -> str:
    p = t["boot"]["plymouth"]
    out = [f"# {HEADER}", "# Plymouth script color constants (0..1 floats)."]
    for k, v in p.items():
        r, g, b = rgb(v)
        key = k.replace("-", "_")
        out.append(
            f"cygnus.{key}.r = {r / 255:.4f}; cygnus.{key}.g = {g / 255:.4f}; cygnus.{key}.b = {b / 255:.4f};"
        )
    return "\n".join(out) + "\n"


def screensaver_palette(t: dict) -> str:
    return (
        json.dumps({"$comment": HEADER, **t["screensaver-palettes"]}, indent=2) + "\n"
    )


def screensaver_glsl(t: dict) -> str:
    p = t["screensaver-palettes"]["cygnus"]
    out = [
        f"// {HEADER}",
        "// Cygnus ramp constants for GLSL ES 3.0 shaders (linear-ish sRGB, 0..1).",
    ]

    def v3(h):
        r, g, b = rgb(h)
        return f"vec3({r / 255:.4f}, {g / 255:.4f}, {b / 255:.4f})"

    out.append(f"const vec3 CYGNUS_FIELD = {v3(p['field'])};")
    out.append(
        f"const vec3 CYGNUS_HOT[{len(p['ramp'])}] = vec3[]("
        + ", ".join(v3(h) for h in p["ramp"])
        + ");"
    )
    out.append(
        f"const vec3 CYGNUS_COOL[{len(p['cool-ramp'])}] = vec3[]("
        + ", ".join(v3(h) for h in p["cool-ramp"])
        + ");"
    )
    out.append(f"const vec3 CYGNUS_PHOTON_RING = {v3(p['photon-ring'])};")
    return "\n".join(out) + "\n"


def tsv(t: dict) -> str:
    rows = ["group\ttoken\tvalue"]
    for scale, vals in t["scales"].items():
        rows += [f"scale.{scale}\t{k}\t{v}" for k, v in vals.items()]
    for mode, vals in t["modes"].items():
        rows += [f"mode.{mode}\t{k}\t{v}" for k, v in vals.items()]
    for name, pal in t["console"].items():
        if name.startswith("$"):
            continue
        rows += [f"console.{name}\t{i}\t{v}" for i, v in enumerate(pal)]
    return "\n".join(rows) + "\n"


def outputs(t: dict) -> dict[str, str]:
    return {
        "css/cygnus.css": css_vars(t),
        "gtk/cygnus-dark.css": gtk_named(t, "dark"),
        "gtk/cygnus-light.css": gtk_named(t, "light"),
        "console/cygnus-tty.setvtrgb": setvtrgb(t["console"]["tty"]),
        "console/cygnus-installer.setvtrgb": setvtrgb(t["console"]["installer"]),
        "console/cygnus-tty.cmdline": vt_cmdline(t["console"]["tty"]),
        "console/cygnus-installer.cmdline": vt_cmdline(t["console"]["installer"]),
        "newt/NEWT_COLORS": newt_colors(t) + "\n",
        "terminal/foot.ini": terminal_foot(t),
        "terminal/alacritty.toml": terminal_alacritty(t),
        "terminal/kitty.conf": terminal_kitty(t),
        "terminal/vte-palette.dconf": terminal_vte_dconf(t),
        "plymouth/cygnus-colors.script": plymouth_colors(t),
        "screensaver/cygnus-palette.json": screensaver_palette(t),
        "screensaver/cygnus_palette.glsl": screensaver_glsl(t),
        "tokens.tsv": tsv(t),
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="fail if generated/ differs")
    a = ap.parse_args()
    t = json.loads((ROOT / "tokens.json").read_text())
    stale = []
    for rel, text in outputs(t).items():
        p = OUT / rel
        if a.check:
            if not p.exists() or p.read_text() != text:
                stale.append(rel)
            continue
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text)
    if stale:
        print("stale:", *stale, sep="\n  ")
        return 1
    if not a.check:
        print(f"wrote {len(outputs(t))} files under {OUT.relative_to(ROOT.parents[1])}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
