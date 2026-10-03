#!/usr/bin/env python3
"""CYGNUS 26.10 screensaver gates.

Asserts (job 2026-10-03 "black hole default + ship set"):

1. dev.ncz.screensaver schema defaults: mode = 'one' (screensaver turned on
   by default) and hack-id = 'blackhole_gles3' (Black Hole is the default).
2. Catalog membership: every id in hacks.tsv is in the approved ship set —
   Black Hole + every hyprsaver_* + every xshadertoy entry + the 12 classic
   shader ports (the 9 cs_* shader ports: voronoi, gravitywell, hexstrut,
   cubestorm, crackberg, cityflow, noof, geodesic, gibson — plus
   hypertorus, klein, projectiveplane). No GL1/gl4es, nothing unshipped
   (megacity, chitin, fractint, neonspacewar, magmasimplex, leviathan,
   genxvectorcade, ephemeris stay OUT).
3. Cross-check: no entry may carry a gl4es/gl1 suffix, and the Black Hole
   default hack-id must itself be present in the catalog.

Exit 0 on pass; exit 1 with diagnostics on any gate failure.
"""
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SCHEMA = ROOT / "assets" / "screensaver-chooser" / "dev.ncz.screensaver.gschema.xml"
CATALOG = ROOT / "assets" / "screensaver-chooser" / "hacks.tsv"

CLASSIC_SHADER_PORTS = {
    "voronoi_gles3", "gravitywell_gles3", "hexstrut_gles3", "cubestorm_gles3",
    "crackberg_gles3", "cityflow_gles3", "noof_gles3", "geodesic_gles3",
    "gibson_gles3", "hypertorus_gles3", "klein_gles3", "projectiveplane_gles3",
}
UNSHIPPED = {
    "megacity", "chitin", "fractint", "neonspacewar",
    "magmasimplex", "leviathan", "genxvectorcade", "ephemeris",
}


def die(msg: str) -> None:
    print(f"GATE FAIL: {msg}")
    sys.exit(1)


def read_schema_defaults() -> dict:
    try:
        tree = ET.parse(SCHEMA)
    except (ET.ParseError, OSError) as e:
        die(f"cannot parse {SCHEMA}: {e}")
    defaults = {}
    for key in tree.getroot().iter("key"):
        d = key.find("default")
        if d is not None and d.text is not None:
            defaults[key.get("name")] = d.text.strip().strip("'\"")
    return defaults


def read_catalog():
    try:
        lines = CATALOG.read_text().splitlines()
    except OSError as e:
        die(f"cannot read {CATALOG}: {e}")
    rows = []
    for line in lines:
        if not line.strip() or line.startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) < 2:
            die(f"malformed catalog row (need id<TAB>name): {line!r}")
        rows.append((parts[0], parts[1]))
    return rows


def in_ship_set(hack_id: str, rows_by_id) -> bool:
    if hack_id == "blackhole_gles3":
        return True
    if hack_id.startswith("hyprsaver_") and hack_id.endswith("_gles3"):
        return True
    if hack_id.startswith("xshadertoy_") and hack_id.endswith("_gles3"):
        return True
    if hack_id in CLASSIC_SHADER_PORTS:
        return True
    return False


def main() -> None:
    # ---- Gate 1: schema defaults -------------------------------------------
    defaults = read_schema_defaults()
    if defaults.get("mode") != "one":
        die(f"schema 'mode' default is {defaults.get('mode')!r}, expected 'one'")
    if defaults.get("hack-id") != "blackhole_gles3":
        die(f"schema 'hack-id' default is {defaults.get('hack-id')!r}, "
            f"expected 'blackhole_gles3'")
    print(f"gate1 OK: mode default = {defaults['mode']!r}, "
          f"hack-id default = {defaults['hack-id']!r}")

    # ---- Gate 2: catalog membership ----------------------------------------
    rows = read_catalog()
    if not rows:
        die("catalog is empty")
    rows_by_id = {r[0] for r in rows}
    if len(rows_by_id) != len(rows):
        dupes = {r for r in rows_by_id if sum(1 for x in rows if x[0] == r) > 1}
        die(f"duplicate catalog ids: {sorted(dupes)}")

    offenders = [hid for hid in rows_by_id if not in_ship_set(hid, rows_by_id)]
    if offenders:
        die(f"catalog ids outside the approved ship set: {sorted(offenders)}")

    bad_suffix = [hid for hid in rows_by_id
                  if re.search(r"gl4es|_gl1\b|\bgl1$", hid)]
    if bad_suffix:
        die(f"catalog entries with gl1/gl4es markers: {sorted(bad_suffix)}")

    leaks = [u for u in UNSHIPPED if any(u in hid for hid in rows_by_id)]
    if leaks:
        die(f"unshipped savers present in catalog: {sorted(leaks)}")

    missing_classics = CLASSIC_SHADER_PORTS - rows_by_id
    if missing_classics:
        die(f"classic shader ports missing from catalog: {sorted(missing_classics)}")
    if "blackhole_gles3" not in rows_by_id:
        die("blackhole_gles3 missing from catalog")

    print(f"gate2 OK: {len(rows_by_id)} catalog ids, all in the approved "
          f"ship set (blackhole + hyprsaver_* + xshadertoy_* + 12 classics); "
          f"no gl1/gl4es, no unshipped savers")

    # ---- Gate 3: default wired to catalog ----------------------------------
    if defaults["hack-id"] not in rows_by_id:
        die(f"default hack-id {defaults['hack-id']!r} not present in catalog")
    print(f"gate3 OK: default {defaults['hack-id']!r} is in the catalog")

    print("ALL SCREENSAVER GATES PASS")


if __name__ == "__main__":
    main()