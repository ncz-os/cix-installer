#!/usr/bin/env python3
"""make-secret-hashes.py -- turn a key-master JSON into the gate's hash list.

RUN THIS ON A TRUSTED MACHINE (the operator's workstation, not a build host).
It reads the plaintext values, writes ONLY salted SHA-256 digests, and never
writes, copies or echoes a value.  The output file is the only thing that
travels to the build host:

    build/make-secret-hashes.py --master ~/private/ncz-keymaster.json \\
        --out ~/.config/ncz/secret-hashes.json   (on the build host)

Key-master format (JSON):

    {"secrets": ["<value>", {"value": "<value>", "label": "gitlab-pat"}, ...]}

`label` is carried into the hash file so the gate's receipt can say WHICH
value matched without ever holding it.  Every value is expanded with
build/scan-shipped-secrets.secret_variants (the same function the gate looks
values up with -- the two can never disagree about coverage):

    raw, urlenc (quote / quote_plus / quote_plus(safe='')), base64
        at offsets 0, 1, 2 (a secret embedded mid-token)
    b64[p:s]
        the base64 of a value found at byte phase p, looked up s characters in

Values shorter than 8 bytes or longer than 256 bytes are refused: a 3-byte
window occurs by chance in shipped binaries, and a >256-byte "secret" is a
key file, not a secret (hash the file's content yourself if that is what you
mean to catch).

The output must live OUTSIDE every git tree (the tool refuses a path inside
this repository; .gitignore also lists the old *.local names as a backstop),
and the gate refuses to run without one.  NEVER commit real content.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


def _load_gate():
    """Import the gate module by path: its file name is not an identifier."""
    path = os.path.join(HERE, "scan-shipped-secrets.py")
    spec = importlib.util.spec_from_file_location("scan_shipped_secrets", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def main(argv=None) -> int:
    gate = _load_gate()
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--master", required=True, help="key-master JSON (plaintext)")
    ap.add_argument("--out", required=True, help="hash file to write")
    ap.add_argument("--salt", help=f"hash salt (default: {gate.DEFAULT_SALT})")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args(argv)

    try:
        with open(args.master, "r", encoding="utf-8") as fh:
            doc = json.load(fh)
    except OSError as exc:
        print(f"make-secret-hashes: cannot read {args.master}: {exc}", file=sys.stderr)
        return 2
    except ValueError as exc:
        print(f"make-secret-hashes: {args.master} is not valid JSON: {exc}",
              file=sys.stderr)
        return 2
    entries = doc.get("secrets") if isinstance(doc, dict) else None
    if not isinstance(entries, list):
        print("make-secret-hashes: the key-master needs a \"secrets\" list",
              file=sys.stderr)
        return 2

    repo = os.path.dirname(HERE)
    if (os.path.realpath(args.out) + os.sep).startswith(os.path.realpath(repo) + os.sep):
        print("make-secret-hashes: refusing to write the hash list inside the "
              "repository; use ~/.config/ncz/secret-hashes.json", file=sys.stderr)
        return 2
    salt = args.salt or gate.DEFAULT_SALT
    out: list[dict] = []
    lengths: set[int] = set()
    prefixes: set[str] = set()
    for i, item in enumerate(entries, 1):
        label = f"secret-{i}"
        if isinstance(item, dict):
            label = str(item.get("label") or label)
            raw = item.get("value")
        else:
            raw = item
        if not isinstance(raw, str):
            print(f"make-secret-hashes: entry {i} has no string value",
                  file=sys.stderr)
            return 2
        value = raw.encode("utf-8")
        if len(value) < gate.HASH_MIN_LEN:
            print(f"make-secret-hashes: entry {i} ({label}) is shorter than "
                  f"{gate.HASH_MIN_LEN} bytes; a window that short matches "
                  "ordinary shipped text, so it cannot be gated this way",
                  file=sys.stderr)
            return 2
        if len(value) > gate.MAX_SECRET_LEN:
            print(f"make-secret-hashes: entry {i} ({label}) is longer than "
                  f"{gate.MAX_SECRET_LEN} bytes; gate the file's own digest "
                  "instead", file=sys.stderr)
            return 2
        for v in gate.secret_variants([value], salt):
            out.append({"label": label, "kind": v["kind"], "sha256": v["sha256"]})
            lengths.add(v["length"])
            prefixes.add(v["prefix"])

    doc_out = {
        "format": "ncz-secret-hashes",
        "version": gate.GATE_VERSION,
        "salt": salt,
        "entries": len(entries),
        "hashes": out,
        # window lengths only (no values): lets the gate skip impossible
        # window sizes instead of hashing every length at every offset
        "lengths": sorted(lengths),
        # domain-separated digests of each window's first 8 bytes: the gate's
        # one-lookup-per-offset prefilter (no more revealing than the digests)
        "prefixes": sorted(prefixes),
        "note": "Salted SHA-256 only. Never commit this file with real content.",
    }
    tmp = args.out + ".tmp"
    try:
        os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(doc_out, fh, indent=2, sort_keys=True)
            fh.write("\n")
        os.chmod(tmp, 0o600)
        os.replace(tmp, args.out)
    except OSError as exc:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        print(f"make-secret-hashes: cannot write {args.out}: {exc}", file=sys.stderr)
        return 2
    if not args.quiet:
        print(f"make-secret-hashes: {len(entries)} values -> {len(out)} digests "
              f"in {args.out} (mode 0600, no plaintext)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
