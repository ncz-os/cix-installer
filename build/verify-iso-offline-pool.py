#!/usr/bin/env python3
"""Reject lost or corrupt packages between the resolved mirror and ISO staging."""

import argparse
import hashlib
from pathlib import Path


def records(path):
    result = {}
    for stanza in path.read_text().strip().split("\n\n"):
        fields = dict(line.split(": ", 1) for line in stanza.splitlines()
                      if not line.startswith(" ") and ": " in line)
        key = tuple(fields[name] for name in ("Package", "Version", "Architecture"))
        if key in result:
            raise ValueError(f"duplicate package identity in {path}: {key}")
        result[key] = fields
    if not result:
        raise ValueError(f"empty package index: {path}")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-index", type=Path, required=True)
    parser.add_argument("--staging", type=Path, required=True)
    parser.add_argument("--index", required=True)
    args = parser.parse_args()
    source = records(args.source_index)
    staged = records(args.staging / args.index)
    missing = source.keys() - staged.keys()
    if missing:
        raise ValueError(f"ISO lost {len(missing)} resolved packages: {sorted(missing)}")
    for key, fields in staged.items():
        path = (args.staging / fields["Filename"]).resolve()
        if not path.is_relative_to(args.staging.resolve()):
            raise ValueError(f"package path escapes staging: {path}")
        with path.open("rb") as archive:
            digest = hashlib.file_digest(archive, "sha256").hexdigest()
        if path.stat().st_size != int(fields["Size"]) or digest != fields["SHA256"]:
            raise ValueError(f"staged package does not match index: {key}")
        if key in source and digest != source[key]["SHA256"]:
            raise ValueError(f"staged package differs from resolved mirror: {key}")
    print(f"verify-iso-offline-pool: PASS ({len(source)} resolved packages retained; "
          f"{len(staged)} staged archives SHA256-verified)")


if __name__ == "__main__":
    main()
