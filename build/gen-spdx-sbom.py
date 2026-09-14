#!/usr/bin/env python3
"""gen-spdx-sbom.py -- generate a real SPDX 2.3 JSON document from a built
dpkg-populated rootfs tree (a base layer, or a role delta layer that still
carries the base's dpkg database via BaseTrees=/Overlay=yes).

Replaces sbom/expected-packages.txt as the thing preflight checks trust.
That file only records package NAMES a human copied out of manifests/*.pkgs
by hand -- it never touches a real built artifact, so it can drift from
what actually got installed with nothing to catch it (confirmed empty:
`grep -rl expected-packages.txt build/` finds exactly one reader,
verify-packages.sh, and that script only compares expected-packages.txt
against manifests/*.pkgs -- manifest text vs manifest text, never against a
built tree). This script is the piece that was missing: it reads the RIGHT
things (the tree's own dpkg database, the tree's own copyright/md5sums
files) so a built artifact's actual package set can finally be verified
against what was supposed to ship.

Usage:
    gen-spdx-sbom.py --tree <rootfs-dir> --name <doc-name> [--out <file.spdx.json>]

Output: SPDX 2.3 JSON to stdout, or --out if given.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path


def dpkg_query(admindir: Path) -> list[dict[str, str]]:
    """Real installed-package data from the tree's own dpkg database.
    Status=installed only -- a purged/removed-but-still-configured entry
    must not appear in the SBOM as if it shipped."""
    fmt = r"${Package}\t${Version}\t${Architecture}\t${Status}\n"
    proc = subprocess.run(
        ["dpkg-query", f"--admindir={admindir}", "-W", "-f", fmt],
        capture_output=True, text=True, check=True,
    )
    pkgs = []
    for line in proc.stdout.splitlines():
        parts = line.split("\t")
        if len(parts) != 4:
            # Should not happen for well-formed dpkg output, but silently
            # dropping a package here would make the SBOM under-report
            # what's actually installed -- exactly the failure mode this
            # whole tool exists to catch elsewhere (caught in zoder
            # review, 2026-09-14). Fail loud instead of guessing.
            print(f"gen-spdx-sbom: ERROR: unparsable dpkg-query line, "
                  f"refusing to silently under-report: {line!r}", file=sys.stderr)
            sys.exit(2)
        name, version, arch, status = parts
        if not status.startswith("install ok"):
            continue
        pkgs.append({"name": name, "version": version, "arch": arch})
    return pkgs


def package_license(tree: Path, name: str) -> str:
    """Best-effort license from the package's own copyright file. Debian
    does not ship a machine-parseable SPDX license expression per package
    in the dpkg database itself -- the copyright file is free text. Take
    ONLY the first 'License:' field verbatim as a DeclaredLicense hint --
    a multi-licensed package's other License: stanzas are not captured
    here (noted in zoder review, 2026-09-14); this is a comment-only
    hint either way (licenseDeclared stays NOASSERTION below), so the
    gap affects SBOM fidelity, not correctness of the machine-checked
    fields. When
    absent or unparseable, SPDX's own answer for 'we don't know' is
    NOASSERTION, not a guess."""
    cpath = tree / "usr/share/doc" / name / "copyright"
    try:
        text = cpath.read_text(errors="replace")
    except OSError:
        return "NOASSERTION"
    m = re.search(r"^License:\s*(\S.*)$", text, re.MULTILINE)
    if not m:
        return "NOASSERTION"
    lic = m.group(1).strip()
    # dpkg copyright License: values are often not valid SPDX license IDs
    # verbatim (e.g. "GPL-3+" vs SPDX's "GPL-3.0-or-later"). Recording the
    # raw value in a LicenseComment alongside a conservative
    # LicenseConcluded=NOASSERTION is more honest than silently minting an
    # SPDX ID that was never actually verified against the license list.
    return lic


def package_verification_code(tree: Path, name: str) -> str | None:
    """SPDX PackageVerificationCode: sha1 of the sorted, concatenated list
    of file sha1 hashes shipped by the package. dpkg only ships md5sums
    per-package (not sha1), so hash the md5sums file's own content list
    (path\tmd5, sorted) instead -- same spirit (a single value that
    changes iff the package's file set or content changes), using the
    hashes dpkg actually gives us rather than re-hashing every file on
    disk (slow, and files can be missing from a delta layer's upperdir if
    unchanged from base -- see LAYER-COHERENCE RULE in the mkosi design
    doc). Packages with no .md5sums (some do not ship one) get None."""
    md5file = tree / "var/lib/dpkg/info" / f"{name}.md5sums"
    if not md5file.exists():
        return None
    lines = sorted(md5file.read_text(errors="replace").splitlines())
    h = hashlib.sha1()
    for line in lines:
        h.update(line.encode("utf-8", "replace"))
    return h.hexdigest()


def spdx_id(name: str) -> str:
    safe = re.sub(r"[^A-Za-z0-9.\-]", "-", name)
    return f"SPDXRef-Package-{safe}"


def build_document(tree: Path, doc_name: str) -> dict:
    admindir = tree / "var/lib/dpkg"
    if not (admindir / "status").exists():
        print(f"gen-spdx-sbom: ERROR: no dpkg database at {admindir} "
              f"-- not a real dpkg-populated tree", file=sys.stderr)
        sys.exit(2)

    pkgs = dpkg_query(admindir)
    if not pkgs:
        print("gen-spdx-sbom: ERROR: dpkg database present but reports "
              "zero installed packages", file=sys.stderr)
        sys.exit(2)

    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    doc_namespace = f"https://ncz-os.dev/spdx/{doc_name}-{uuid.uuid4()}"

    packages = []
    relationships = [{
        "spdxElementId": "SPDXRef-DOCUMENT",
        "relationshipType": "DESCRIBES",
        "relatedSpdxElement": "SPDXRef-Package-rootfs",
    }]
    packages.append({
        "SPDXID": "SPDXRef-Package-rootfs",
        "name": doc_name,
        "versionInfo": "NOASSERTION",
        "downloadLocation": "NOASSERTION",
        "filesAnalyzed": False,
        "licenseConcluded": "NOASSERTION",
        "licenseDeclared": "NOASSERTION",
        "copyrightText": "NOASSERTION",
        "comment": "Root package representing the built rootfs tree itself.",
    })

    for pkg in sorted(pkgs, key=lambda p: p["name"]):
        pid = spdx_id(pkg["name"])
        lic = package_license(tree, pkg["name"])
        verif = package_verification_code(tree, pkg["name"])
        entry = {
            "SPDXID": pid,
            "name": pkg["name"],
            "versionInfo": pkg["version"],
            "downloadLocation": "NOASSERTION",
            "filesAnalyzed": verif is not None,
            "licenseConcluded": "NOASSERTION",
            # dpkg's copyright "License:" value is not validated against the
            # SPDX license list (see the comment field below when known), so
            # licenseDeclared stays the conservative NOASSERTION rather than
            # asserting an SPDX license ID nobody actually verified.
            "licenseDeclared": "NOASSERTION",
            "copyrightText": "NOASSERTION",
            "supplier": "NOASSERTION",
            "sourceInfo": f"dpkg architecture={pkg['arch']}",
            "externalRefs": [{
                "referenceCategory": "PACKAGE-MANAGER",
                "referenceType": "purl",
                "referenceLocator": f"pkg:deb/debian/{pkg['name']}@{pkg['version']}?arch={pkg['arch']}",
            }],
        }
        if lic != "NOASSERTION":
            entry["comment"] = f"dpkg copyright file declares License: {lic} (not validated against the SPDX license list)"
        if verif is not None:
            entry["packageVerificationCode"] = {"packageVerificationCodeValue": verif}
        packages.append(entry)
        relationships.append({
            "spdxElementId": "SPDXRef-Package-rootfs",
            "relationshipType": "CONTAINS",
            "relatedSpdxElement": pid,
        })

    return {
        "spdxVersion": "SPDX-2.3",
        "dataLicense": "CC0-1.0",
        "SPDXID": "SPDXRef-DOCUMENT",
        "name": doc_name,
        "documentNamespace": doc_namespace,
        "creationInfo": {
            "created": now,
            "creators": ["Tool: cix-installer/gen-spdx-sbom.py"],
        },
        "packages": packages,
        "relationships": relationships,
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--tree", required=True, type=Path, help="built rootfs directory (contains var/lib/dpkg)")
    ap.add_argument("--name", required=True, help="SBOM document name, e.g. ncz-os-desktop-26.7")
    ap.add_argument("--out", type=Path, help="write JSON here instead of stdout")
    args = ap.parse_args()

    if not args.tree.is_dir():
        print(f"gen-spdx-sbom: ERROR: not a directory: {args.tree}", file=sys.stderr)
        return 2

    doc = build_document(args.tree, args.name)
    text = json.dumps(doc, indent=2, sort_keys=False)
    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(text + "\n")
        print(f"gen-spdx-sbom: wrote {len(doc['packages']) - 1} packages to {args.out}", file=sys.stderr)
    else:
        print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
