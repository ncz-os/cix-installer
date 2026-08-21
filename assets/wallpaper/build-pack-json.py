#!/usr/bin/env python3
"""build-pack-json — generate pack.json for a first-party wallpaper pack.

Mirrors the schema ncz-wallpaper-ocs import writes, but with first-party
provenance instead of OCS provenance. Used for packs whose images are
shipped with NCZ-OS under /usr/share/backgrounds/<pack>/ or
/opt/singularity/share/backgrounds/<pack>/ and are not imported from pling
or any other OCS endpoint.

The schema:
    {
      "schema": 1,
      "id": "<pack-id>",
      "name": "<human-readable pack name>",
      "artist": {"name": "...", "credit": "...", "homepage": "..."},
      "origin": "first-party",
      "source": {
          "directory": "<abs path to the image directory on disk>",
          "format": "shipped",
          "license_note": "..." (when licence is not separately recorded)
      },
      "license": "<text or null>",
      "license_note": "<text or null>",
      "rotation": {"scope": "pack", "order": "shuffle", "interval": 600},
      "images": [
        {"file": "name.jpg", "title": "...", "is_animated": false}
      ]
    }

The OCS import schema's "source.{ocs_id,detailpage,download_url,...}" block
is replaced by "source.{directory,format}" because those OCS-specific
provenance fields do not apply to first-party packs. The image records
lose source_file/source_geometry/normalized_geometry for the same reason:
nothing was downloaded and nothing was re-encoded. file and title are
preserved.

Usage:
    build-pack-json.py --id <id> --name <name> --artist-name <name> \
        [--artist-homepage URL] [--artist-credit TEXT] \
        --dir <absolute-image-dir> [--license TEXT] [--license-note TEXT]
"""
from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

SCHEMA = 1


_ROMAN_RE = re.compile(r"^(I{1,3}|IV|V|VI{0,3}|IX|X)$")
_UPPER_KEEP = {"OGN", "NCZ"}


def _title_token(tok: str) -> str:
    """Per-token title casing. NCZ and OGN are kept as acronyms; roman
    numerals are upper-cased; everything else is title-cased."""
    upper = tok.upper()
    if upper in _UPPER_KEEP:
        return upper
    if _ROMAN_RE.fullmatch(upper):
        return upper
    # Title-case: first letter upper, rest lower, except we leave already-
    # mixed-case tokens (e.g. "Gargantua", "Magnetar") alone because the
    # filename stems are already in human-readable case.
    if tok and tok[0].isalpha() and tok.islower():
        return tok[0].upper() + tok[1:]
    return tok


def slugify(value: str) -> str:
    """Reverse the ncz-wallpaper-NN-slug-2k.jpg suffix to a human title.

    The ncz-wallpaper-ocs CLI uses slugify() too, but in the other direction
    (text -> filename slug). Here we want the title out of the filename,
    so the algorithm is the inverse: split on dashes, drop the leading
    numeric index (e.g. "01"), drop the leading "ncz"/"wallpaper" tokens,
    drop the trailing resolution marker ("2k"/"4k"/"8k"), keep the middle
    tokens, and title-case them while preserving known acronyms and Roman
    numerals.
    """
    stem = value.rsplit(".", 1)[0] if "." in value else value
    tokens = [t for t in stem.split("-") if t]

    seen_ncz = False
    seen_wallpaper = False
    index_dropped = False
    out: list[str] = []
    for tok in tokens:
        if not out and not index_dropped and re.fullmatch(r"\d{1,3}", tok):
            index_dropped = True
            continue
        if not seen_ncz and tok.lower() == "ncz":
            seen_ncz = True
            continue
        if not seen_wallpaper and tok.lower() == "wallpaper":
            seen_wallpaper = True
            continue
        if re.fullmatch(r"[0-9]+[kK]", tok):
            continue
        out.append(tok)

    if not out:
        return stem
    return " ".join(_title_token(t) for t in out)


def image_geometry(path: Path) -> tuple[int, int] | None:
    if shutil.which("magick"):
        cmd = ["magick", "identify", "-format", "%w %h", str(path)]
    elif shutil.which("identify"):
        cmd = ["identify", "-format", "%w %h", str(path)]
    else:
        return None
    try:
        out = subprocess.run(cmd, check=True, capture_output=True, text=True).stdout.strip().split()
    except subprocess.CalledProcessError:
        return None
    if len(out) != 2:
        return None
    try:
        return int(out[0]), int(out[1])
    except ValueError:
        return None


def sniff_mime(path: Path) -> str:
    if shutil.which("file"):
        return subprocess.run(
            ["file", "--brief", "--mime-type", str(path)],
            check=True, capture_output=True, text=True,
        ).stdout.strip()
    return ""


def collect_images(directory: Path) -> list[dict]:
    images: list[dict] = []
    # Sort by filename so iteration order is deterministic; matches what the
    # OCS CLI does (sorted() on the source paths).
    for path in sorted(directory.iterdir()):
        if not path.is_file():
            continue
        mime = sniff_mime(path)
        if not mime.startswith("image/"):
            continue
        # Static raster only for the packs this script generates. Animated
        # (gif/webp-with-animation) gets is_animated: true so the picker's
        # future is_animated-aware logic can distinguish it; we have no such
        # files in any of the 3 packs we are building, so this is a forward
        # hook, not a current code path.
        animated = mime in {"image/gif"} or path.suffix.lower() == ".gif"
        geom = image_geometry(path)
        rec: dict = {
            "file": path.name,
            "title": slugify(path.stem),
            "is_animated": animated,
        }
        if geom:
            rec["source_geometry"] = {"width": geom[0], "height": geom[1]}
        images.append(rec)
    return images


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--id", required=True, help="pack id; used as the on-disk identifier and the JSON 'id' field")
    p.add_argument("--name", required=True, help="human-readable pack name; the JSON 'name' field")
    p.add_argument("--artist-name", required=True, help="artist display name; the JSON 'artist.name' field")
    p.add_argument("--artist-homepage", default=None, help="optional artist URL; the JSON 'artist.homepage' field")
    p.add_argument("--artist-credit", default=None, help="optional artist credit line; the JSON 'artist.credit' field. Default: '<artist-name> (first-party)'")
    p.add_argument("--dir", required=True, type=Path, help="absolute path to the directory containing the pack's images")
    p.add_argument("--license", default=None, help="optional licence text; the JSON 'license' field. If unset, 'license' is null and 'license_note' is filled in instead")
    p.add_argument("--license-note", default=None, help="optional licence note; the JSON 'license_note' field. Default when --license is unset: 'distributed with NCZ-OS; not separately redistributable'")
    p.add_argument("--rotation-interval", type=int, default=600, help="rotation interval in seconds; the JSON 'rotation.interval' field. Default 600 (10 minutes, matches the existing rotator cadence)")
    p.add_argument("--out", type=Path, default=None, help="output path for the pack.json. Default: <dir>/pack.json")
    p.add_argument("--dry-run", action="store_true", help="print the JSON to stdout and do not write")
    return p


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    directory: Path = args.dir.resolve()
    if not directory.is_dir():
        print(f"ERROR: not a directory: {directory}", file=sys.stderr)
        return 2

    images = collect_images(directory)
    if not images:
        print(f"ERROR: no image/* files in {directory}", file=sys.stderr)
        return 2

    artist: dict = {"name": args.artist_name}
    if args.artist_homepage:
        artist["homepage"] = args.artist_homepage
    artist["credit"] = args.artist_credit or f"{args.artist_name} (first-party)"

    pack: dict = {
        "schema": SCHEMA,
        "id": args.id,
        "name": args.name,
        "artist": artist,
        "origin": "first-party",
        "source": {
            "directory": str(directory),
            "format": "shipped",
        },
        "license": args.license,
        "license_note": args.license_note if args.license_note is not None else (
            None if args.license else "distributed with NCZ-OS; not separately redistributable"
        ),
        "rotation": {
            "scope": "pack",
            "order": "shuffle",
            "interval": args.rotation_interval,
        },
        "images": images,
    }
    # Drop null leaves the same way the OCS CLI does, so an omitted license
    # is honest (absent, not empty-string). Also drop empty-string values for
    # the same reason -- "" carries no information and creates a key whose
    # presence is indistinguishable from "not yet decided".
    def _drop_empty(d):
        if isinstance(d, dict):
            return {k: _drop_empty(v) for k, v in d.items() if v is not None and v != ""}
        if isinstance(d, list):
            return [_drop_empty(v) for v in d]
        return d
    pack = _drop_empty(pack)

    rendered = json.dumps(pack, indent=2, sort_keys=True) + "\n"
    if args.dry_run:
        sys.stdout.write(rendered)
        return 0

    out: Path = args.out or (directory / "pack.json")
    out.write_text(rendered, encoding="utf-8")
    print(f"wrote {out} ({len(images)} images)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())