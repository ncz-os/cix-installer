#!/usr/bin/env python3
"""reproducible.py -- the deterministic primitives for the NCZ-OS image build.

This module is the single implementation of every "derive a stable value from
the build pin" rule.  Both the shell helper (build/lib/reproducible.sh) and the
determinism test suite (build/test-build-determinism.sh) call it, so the rule
lives in exactly one place.

It is deliberately stdlib-only and runs under `python3 -I` (isolated: no
PYTHONPATH/site injection) so the build host's environment cannot change a
derived value.

Commands
--------
  pin-digest FILE                 sha256 of the canonical pin (comments/blank
                                  lines removed, rows sorted) -- the determinism
                                  root that seeds every derived UUID
  canonical FILE                  print the canonical pin (for diff/inspection)
  sde --pin FILE [--repo DIR]     print SOURCE_DATE_EPOCH: git commit time of
                                  --repo when it is a git work tree, else the
                                  pin's snapshot_epoch; NCZ_SOURCE_DATE_EPOCH
                                  overrides both (validated)
  uuid --kind K --pin FILE [--arch A]
                                  print a stable RFC-4122-formatted UUID derived
                                  from the pin digest + kind (+ arch)
  arch-pin --pin FILE --arch A    print the merged per-run pin (the committed
                                  base.pin plus the arch's substrate/kernel rows
                                  resolved at preflight); used by the entrypoint
  snapshot-epoch TS               convert a snapshot.debian.org stamp
                                  (YYYYMMDDTHHMMSSZ) to a Unix epoch
  selftest                        run the in-module invariant checks (exit 1 on
                                  any failure) -- used by the test suite

Exit codes: 0 ok, 1 invariant violation, 2 usage.
"""
from __future__ import annotations

import argparse
import hashlib
import os
import re
import subprocess
import sys
from pathlib import Path

# A UUID we derive is NOT a real RFC-4122 name-based UUID (which embeds a
# namespace UUID and uses SHA-1); it is a SHA-256-derived 128-bit value that we
# FORMAT as a UUID and tag version 5 / variant RFC-4122 so tools that parse it
# (mke2fs -U, sgdisk -U, mkfs.vfat -i accepts a hex id) are happy.  Determinism
# is the whole point: the same pin + kind + arch must always give the same
# value, and two different kinds must never collide.
_UUID_SEED = b"ncz-os/determinism/v1\x00"


def parse_pin(text: str) -> dict[str, str]:
    """Parse a key<TAB>value pin.  Comments (#) and blanks are ignored.

    A later row with the same key overwrites an earlier one; the generator
    never emits duplicates, so this is only a defensive rule."""
    out: dict[str, str] = {}
    for raw in text.splitlines():
        line = raw.rstrip("\n")
        if not line or line.lstrip().startswith("#"):
            continue
        if "\t" in line:
            key, _, val = line.partition("\t")
        else:
            # tolerate whitespace-only separators for hand inspection
            parts = line.split(None, 1)
            if len(parts) != 2:
                raise ValueError(f"pin row is not key<TAB>value: {line!r}")
            key, val = parts
        out[key.strip()] = val.strip()
    return out


def canonical_pin(text: str) -> str:
    """Canonical form: no comments, no blanks, rows sorted by key.

    A trailing newline is always present so the digest is stable."""
    rows = parse_pin(text)
    if not rows:
        raise ValueError("pin has no rows")
    body = "".join(f"{k}\t{rows[k]}\n" for k in sorted(rows))
    return body


def pin_digest(path: Path) -> str:
    canon = canonical_pin(path.read_text())
    return hashlib.sha256(canon.encode()).hexdigest()


def snapshot_epoch(stamp: str) -> int:
    """Convert a snapshot.debian.org stamp YYYYMMDDTHHMMSSZ to a Unix epoch.

    snapshot.debian.org stamps are always UTC with a literal Z.  We do the
    calendar math ourselves so the value does not depend on the host timezone
    database or on GNU vs BSD `date`."""
    m = re.fullmatch(r"(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})Z", stamp.strip())
    if not m:
        raise ValueError(f"not a snapshot stamp (YYYYMMDDTHHMMSSZ): {stamp!r}")
    y, mo, d, h, mi, s = (int(x) for x in m.groups())
    # days-from-civil (Howard Hinnant), no datetime/tz dependency
    y -= mo <= 2
    era = (y if y >= 0 else y - 399) // 400
    yoe = y - era * 400
    doy = (153 * (mo + (-3 if mo > 2 else 9)) + 2) // 5 + d - 1
    doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
    days = era * 146097 + doe - 719468
    return days * 86400 + h * 3600 + mi * 60 + s


def _git_commit_epoch(repo: Path) -> int | None:
    try:
        out = subprocess.run(
            ["git", "-C", str(repo), "log", "-1", "--format=%ct"],
            capture_output=True, text=True, check=True,
        ).stdout.strip()
    except (subprocess.CalledProcessError, FileNotFoundError, OSError):
        return None
    if out.isdigit():
        return int(out)
    return None


def source_date_epoch(pin: dict[str, str], repo: Path | None,
                      override: str | None) -> int:
    """Resolve SOURCE_DATE_EPOCH, first match wins:

       1. NCZ_SOURCE_DATE_EPOCH (validated int) -- an explicit operator pin,
       2. the git commit time of --repo (ties the artifact to the tree),
       3. pin git_commit_epoch,
       4. pin snapshot_epoch (the upstream archive state).

    A value <= 0 is rejected: SOURCE_DATE_EPOCH=0 is legal for tar but hides
    "unset" bugs, so we require a real post-1970 timestamp."""
    if override not in (None, ""):
        if not re.fullmatch(r"\d+", override):
            raise ValueError(f"NCZ_SOURCE_DATE_EPOCH must be an integer: {override!r}")
        val = int(override)
        if val <= 0:
            raise ValueError(f"NCZ_SOURCE_DATE_EPOCH must be > 0: {val}")
        return val
    if repo is not None:
        got = _git_commit_epoch(repo)
        if got:
            return got
    for key in ("git_commit_epoch", "snapshot_epoch"):
        if pin.get(key, "").isdigit():
            val = int(pin[key])
            if val > 0:
                return val
    raise ValueError(
        "cannot derive SOURCE_DATE_EPOCH: no --repo git history and no "
        "git_commit_epoch/snapshot_epoch in the pin")


def derive_uuid(kind: str, digest: str, arch: str = "") -> str:
    """Stable UUID-format value from (kind, pin digest, arch).

    The seed includes a fixed domain-separation prefix so this is a distinct
    derivation from any other SHA-256 use in the repo."""
    if not kind or not re.fullmatch(r"[A-Za-z0-9._-]+", kind):
        raise ValueError(f"bad uuid kind: {kind!r}")
    seed = _UUID_SEED + kind.encode() + b"\x00" + digest.encode()
    seed += b"\x00" + arch.encode()
    h = bytearray(hashlib.sha256(seed).digest()[:16])
    h[6] = (h[6] & 0x0F) | 0x50   # version 5
    h[8] = (h[8] & 0x3F) | 0x80   # RFC-4122 variant
    s = h.hex()
    return f"{s[0:8]}-{s[8:12]}-{s[12:16]}-{s[16:20]}-{s[20:32]}"


def merged_arch_pin(base: Path, arch: str, substrate_sha: str,
                    substrate_name: str = "", kernel_kver: str = "",
                    singularity_sha256: str = "") -> str:
    """Return the canonical per-run pin text for one arch.

    The committed manifests/base.pin is arch-independent except for keyed
    rows; the resolved substrate/kernel/singularity rows are added here so a run
    records exactly what it consumed."""
    rows = parse_pin(base.read_text())
    rows["arch"] = arch
    if substrate_sha:
        rows[f"substrate_sha256_{arch}"] = substrate_sha
    if substrate_name:
        rows[f"substrate_name_{arch}"] = substrate_name
    if kernel_kver:
        rows[f"kernel_kver_{arch}"] = kernel_kver
    if singularity_sha256:
        rows[f"singularity_payload_sha256_{arch}"] = singularity_sha256
    return canonical_pin_text(rows)


def canonical_pin_text(rows: dict[str, str]) -> str:
    return "".join(f"{k}\t{rows[k]}\n" for k in sorted(rows))


def selftest() -> int:
    fails = 0

    def check(cond: bool, what: str) -> None:
        nonlocal fails
        if cond:
            print(f"ok   {what}")
        else:
            print(f"FAIL {what}")
            fails += 1

    # canonicalisation is order- and comment-insensitive
    a = "# c\nb\t2\na\t1\n"
    b = "a\t1\n\n# other\nb\t2\n"
    check(canonical_pin(a) == canonical_pin(b), "canonical pin ignores order/comments")
    check(canonical_pin(a) == "a\t1\nb\t2\n", "canonical pin is sorted, trailing NL")

    # snapshot epoch matches a known date (2026-10-07T20:24:37Z)
    check(snapshot_epoch("20261007T202437Z") == 1791404677,
          "snapshot_epoch 20261007T202437Z")
    check(snapshot_epoch("19700101T000000Z") == 0, "snapshot_epoch epoch")

    # uuid derivation is stable and kind/arch-separated
    dg = "0" * 64
    u1 = derive_uuid("ext4", dg, "amd64")
    check(u1 == derive_uuid("ext4", dg, "amd64"), "uuid stable for same inputs")
    check(u1 != derive_uuid("ext4", dg, "arm64"), "uuid differs by arch")
    check(u1 != derive_uuid("vfat", dg, "amd64"), "uuid differs by kind")
    check(u1 != derive_uuid("ext4", "1" * 64, "amd64"), "uuid differs by digest")
    check(re.fullmatch(r"[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}",
                       u1) is not None, "uuid is v5-formatted")

    # no secret/randomness leaks: repeated derivation in-process is identical
    check(len({derive_uuid("x", dg) for _ in range(50)}) == 1, "uuid has no entropy")

    # sde precedence
    pin = {"snapshot_epoch": "100", "git_commit_epoch": "200"}
    check(source_date_epoch(pin, None, "300") == 300, "sde override wins")
    check(source_date_epoch(pin, None, None) == 200, "sde prefers git_commit_epoch")
    check(source_date_epoch({"snapshot_epoch": "100"}, None, None) == 100,
          "sde falls back to snapshot_epoch")
    try:
        source_date_epoch({}, None, None)
        check(False, "sde errors with no source")
    except ValueError:
        check(True, "sde errors with no source")
    try:
        source_date_epoch(pin, None, "0")
        check(False, "sde rejects 0")
    except ValueError:
        check(True, "sde rejects 0")

    print(f"\nreproducible.py selftest: {'PASS' if not fails else 'FAIL'} ({fails} failure(s))")
    return 1 if fails else 0


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("pin-digest")
    p.add_argument("pin", type=Path)

    p = sub.add_parser("canonical")
    p.add_argument("pin", type=Path)

    p = sub.add_parser("sde")
    p.add_argument("--pin", required=True, type=Path)
    p.add_argument("--repo", type=Path)
    p.add_argument("--override", default=os.environ.get("NCZ_SOURCE_DATE_EPOCH"))

    p = sub.add_parser("uuid")
    p.add_argument("--kind", required=True)
    p.add_argument("--pin", required=True, type=Path)
    p.add_argument("--arch", default="")

    p = sub.add_parser("arch-pin")
    p.add_argument("--pin", required=True, type=Path)
    p.add_argument("--arch", required=True)
    p.add_argument("--substrate-sha", default="")
    p.add_argument("--substrate-name", default="")
    p.add_argument("--kernel-kver", default="")
    p.add_argument("--singularity-sha256", default="")

    p = sub.add_parser("snapshot-epoch")
    p.add_argument("stamp")

    sub.add_parser("selftest")

    args = ap.parse_args(argv)
    try:
        if args.cmd == "pin-digest":
            print(pin_digest(args.pin))
        elif args.cmd == "canonical":
            sys.stdout.write(canonical_pin(args.pin.read_text()))
        elif args.cmd == "sde":
            sys.stdout.write(str(source_date_epoch(
                parse_pin(args.pin.read_text()), args.repo, args.override)) + "\n")
        elif args.cmd == "uuid":
            print(derive_uuid(args.kind, pin_digest(args.pin), args.arch))
        elif args.cmd == "arch-pin":
            sys.stdout.write(merged_arch_pin(
                args.pin, args.arch, args.substrate_sha, args.substrate_name,
                args.kernel_kver, args.singularity_sha256))
        elif args.cmd == "snapshot-epoch":
            print(snapshot_epoch(args.stamp))
        elif args.cmd == "selftest":
            return selftest()
    except (ValueError, OSError) as exc:
        print(f"reproducible.py: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
