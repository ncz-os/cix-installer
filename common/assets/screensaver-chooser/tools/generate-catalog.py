#!/usr/bin/env python3
import argparse
import pathlib
import re

CLASSICS = [
    "voronoi", "projectiveplane", "klein", "hypertorus", "cubestorm",
    "hexstrut", "crackberg", "cityflow", "geodesic", "gravitywell",
    "noof", "gibson",
]


def variable_values(source, name):
    match = re.search(rf"{name}\s*=\s*\[(.*?)\]", source, re.S)
    if match is None:
        raise SystemExit(f"missing Meson list: {name}")
    return re.findall(r"['\"]([^'\"]+)['\"]", match.group(1))


def title(name):
    words = name.replace("-", " ").replace("_", " ").split()
    return " ".join(word.capitalize() for word in words)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("meson_build", type=pathlib.Path)
    parser.add_argument("output", type=pathlib.Path)
    args = parser.parse_args()
    source = args.meson_build.read_text()
    targets = set(re.findall(r"['\"]([A-Za-z0-9_-]+_gles3)['\"]", source))
    generated_names = re.findall(r"['\"]name['\"]\s*:\s*['\"]([A-Za-z0-9_-]+)['\"]", source)
    targets.update(f"{name}_gles3" for name in generated_names)
    groups = [
        ("Black Hole Simulation", ["blackhole_gles3"]),
        ("hyprsaver", [f"hyprsaver_{name}_gles3" for name in variable_values(source, "hyprsaver_shaders")]),
        ("xshadertoy", [f"xshadertoy_{name}_gles3" for name in variable_values(source, "xshadertoy_shaders")]),
        ("Classics", [f"{name}_gles3" for name in CLASSICS]),
    ]
    missing = [target for _, entries in groups for target in entries if target not in targets]
    if missing:
        raise SystemExit("missing build targets: " + ", ".join(missing))
    lines = ["# Generated from ncz-screensavers meson.build by tools/generate-catalog.py"]
    for group, entries in groups:
        for target in entries:
            stem = target.removesuffix("_gles3")
            if group == "hyprsaver":
                stem = stem.removeprefix("hyprsaver_")
            elif group == "xshadertoy":
                stem = stem.removeprefix("xshadertoy_")
            lines.append(f"{target}\t{title(stem)}\t{group}\t{group}")
    args.output.write_text("\n".join(lines) + "\n")
    print(" ".join(f"{group}={len(entries)}" for group, entries in groups))


if __name__ == "__main__":
    main()
