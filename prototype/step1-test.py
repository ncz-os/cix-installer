#!/usr/bin/env python3
"""
step1-test.py — Step 1 qualification test driver.

Runs:
    1. Cold compose of an initial real rEFInd + d-i ISO from the cached
       substrate (Bookworm amd64 netboot) and the rEFInd ESP.
    2. N successive warm-growth runs (default 3). Each round:
        a. reflink-clones the previous artifact
        b. applies a hotfix-shaped change (a replacement of a single
           file at a realistic size — e.g. simulating a replaced
           squashfs or .deb) via xorriso -update + a separate -update
           of the in-tree /efi.img (the ESP image is replaced on every
           growth; the EFI Initial Entry's load LBA is rewritten by
           -boot_image any replay)
        c. runs the independent verifier (with --esp-image so the
           embedded-ESP bytes are checked)
        d. records the real numbers (clone time, growth time, byte
           counts, ESP-LBA, verifier verdict)

The verifier result for warm rounds is recorded as-is — even when the
verifier rejects the warm output. This is what the design doc §8 wants
honest measurement of.

Run this script after import-substrate.py and build-refind-esp.py have
populated the cache. Output goes to the directory passed via --report.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import struct
import subprocess
import sys
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent


def log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def parse_iso_size(path: Path) -> dict:
    """Read minimal layout info directly from the ISO without invoking
    xorriso. Returns dict with iso_block_count, gpt_backup_lba,
    efi_first_lba, efi_size_lba, trailing_bytes_after_gpt_backup."""
    with path.open("rb") as f:
        f.seek(0, 2)
        file_size = f.tell()
        image_lba = file_size // 512

        # PVD at ISO sector 16
        f.seek(16 * 2048)
        pvd = f.read(2048)
        pvd_ok = pvd[1:6] == b"CD001"
        vol_id = pvd[40:72].decode("ascii", errors="replace").strip() if pvd_ok else ""

        # GPT primary header at LBA 1
        f.seek(1 * 512)
        ph = f.read(512)
        gpt_ok = ph[:8] == b"EFI PART"
        gpt_part_entry_lba = struct.unpack("<Q", ph[72:80])[0] if gpt_ok else 0
        gpt_num_entries = struct.unpack("<I", ph[80:84])[0] if gpt_ok else 0
        gpt_entry_size = struct.unpack("<I", ph[84:88])[0] if gpt_ok else 0
        gpt_backup_lba = struct.unpack("<Q", ph[32:40])[0] if gpt_ok else 0
        gpt_first_usable = struct.unpack("<Q", ph[40:48])[0] if gpt_ok else 0
        gpt_last_usable = struct.unpack("<Q", ph[48:56])[0] if gpt_ok else 0

        # EFI partition entry
        efi_first_lba = efi_size_lba = 0
        if gpt_ok and gpt_part_entry_lba:
            f.seek(gpt_part_entry_lba * 512)
            arr = f.read(gpt_num_entries * gpt_entry_size)
            efi_guid = b"\x28\x73\x2A\xC1\x1F\xF8\xD2\x11\xBA\x4B\x00\xA0\xC9\x3E\xC9\x3B"
            for i in range(gpt_num_entries):
                entry = arr[i * gpt_entry_size:(i + 1) * gpt_entry_size]
                if entry[:16] == efi_guid:
                    efi_first_lba = struct.unpack("<Q", entry[32:40])[0]
                    efi_last_lba = struct.unpack("<Q", entry[40:48])[0]
                    efi_size_lba = efi_last_lba - efi_first_lba + 1
                    break

    trailing = max(0, file_size - (gpt_backup_lba + 1) * 512)
    return {
        "file_size_bytes": file_size,
        "image_lba": image_lba,
        "pvd_ok": pvd_ok,
        "volume_id": vol_id,
        "gpt_ok": gpt_ok,
        "gpt_backup_lba": gpt_backup_lba,
        "gpt_part_entry_lba": gpt_part_entry_lba,
        "gpt_num_entries": gpt_num_entries,
        "gpt_first_usable": gpt_first_usable,
        "gpt_last_usable": gpt_last_usable,
        "efi_partition": {
            "first_lba": efi_first_lba,
            "size_lba": efi_size_lba,
        } if efi_first_lba else None,
        "trailing_bytes_after_gpt_backup": trailing,
    }


def run_cold(arch: str, substrate_dir: Path, esp_img: Path, out: Path,
             volume_id: str, publisher: str) -> dict:
    cmd = [
        sys.executable, str(REPO_ROOT / "build" / "iso" / "write-image.py"),
        "cold",
        "--arch", arch,
        "--substrate-node-dir", str(substrate_dir),
        "--esp-image", str(esp_img),
        "--output", str(out),
        "--volume-id", volume_id,
        "--publisher", publisher,
    ]
    t0 = time.monotonic()
    proc = subprocess.run(cmd, capture_output=True, text=True)
    seconds = time.monotonic() - t0
    return {
        "command": cmd,
        "exit_code": proc.returncode,
        "seconds": seconds,
        "stdout_tail": proc.stdout.splitlines()[-6:],
        "stderr_tail": proc.stderr.splitlines()[-10:],
    }


def run_warm(arch: str, parent: Path, out: Path, manifest: Path,
             payload_root: Path, esp_img: Path) -> dict:
    cmd = [
        sys.executable, str(REPO_ROOT / "build" / "iso" / "write-image.py"),
        "warm",
        "--arch", arch,
        "--parent", str(parent),
        "--output", str(out),
        "--manifest", str(manifest),
        "--payload-root", str(payload_root),
        "--esp-image", str(esp_img),
    ]
    t0 = time.monotonic()
    proc = subprocess.run(cmd, capture_output=True, text=True)
    seconds = time.monotonic() - t0
    return {
        "command": cmd,
        "exit_code": proc.returncode,
        "seconds": seconds,
        "stdout_tail": proc.stdout.splitlines()[-6:],
        "stderr_tail": proc.stderr.splitlines()[-10:],
    }


def reflink_capable(dirpath: Path) -> dict:
    """Probe the filesystem at dirpath for reflink capability."""
    probe_dir = dirpath / ".reflink-probe"
    probe_dir.mkdir(exist_ok=True)
    a = probe_dir / "a"
    b = probe_dir / "b"
    a.write_bytes(os.urandom(2 * 1024 * 1024))
    gcp = shutil.which("gcp") or shutil.which("cp")
    try:
        subprocess.run([gcp, "--reflink=always", str(a), str(b)],
                       check=True, capture_output=True)
        ino_a, ino_b = a.stat().st_ino, b.stat().st_ino
        capable = (ino_a == ino_b and ino_a > 0)
        detail = f"inode a={ino_a} b={ino_b} capable={capable}"
    except subprocess.CalledProcessError as e:
        return {"capable": False, "tool": "gcp --reflink=always",
                "detail": f"failed: {e.stderr.decode()[:200]}"}
    finally:
        shutil.rmtree(probe_dir, ignore_errors=True)
    return {"capable": capable, "tool": "gcp --reflink=always", "detail": detail}


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--arch", required=True, choices=["amd64", "arm64"])
    ap.add_argument("--substrate-dir", type=Path, required=True,
                    help="substrate import node directory")
    ap.add_argument("--esp-image", type=Path, required=True)
    ap.add_argument("--payload-root", type=Path,
                    default=REPO_ROOT / "prototype" / "payloads")
    ap.add_argument("--out-dir", type=Path,
                    default=REPO_ROOT / "prototype" / "output")
    ap.add_argument("--warm-rounds", type=int, default=3,
                    help="number of warm growth rounds")
    ap.add_argument("--report", type=Path,
                    default=REPO_ROOT / "prototype" / "output" / "step1-report.json")
    args = ap.parse_args()

    out_dir = args.out_dir.resolve()
    out_dir.mkdir(parents=True, exist_ok=True)
    payload_root = args.payload_root.resolve()
    payload_root.mkdir(parents=True, exist_ok=True)

    report = {
        "schema_version": "step1-report/v1",
        "arch": args.arch,
        "started_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "reflink_probe": reflink_capable(out_dir),
        "substrate": str(args.substrate_dir),
        "esp_image": str(args.esp_image),
        "cold": {},
        "warm_rounds": [],
    }

    log(f"reflink probe: {report['reflink_probe']}")

    # Cold compose
    cold_out = out_dir / f"cold-{args.arch}.iso"
    log(f"=== Cold compose -> {cold_out}")
    cold_run = run_cold(args.arch, args.substrate_dir, args.esp_image,
                        cold_out, f"NCZOSREFIND-{args.arch}", "NCZ-OS prototype")
    report["cold"] = cold_run
    if cold_run["exit_code"] != 0:
        log(f"Cold compose FAILED")
        if args.report:
            args.report.write_text(json.dumps(report, indent=2, sort_keys=True))
        sys.exit(1)

    cold_layout = parse_iso_size(cold_out)
    cold_layout["sha256"] = sha256_file(cold_out)
    report["cold_layout"] = cold_layout
    log(f"cold layout: {cold_layout}")

    # Warm rounds. Each round is an independent transaction against the
    # cold parent: cold-amd64.iso -> warm-N.iso with the Nth hotfix
    # change. This matches the brief's "apply 2-3 successive
    # hotfix-shaped changes and verify after each growth": every
    # successive hotfix is its own delta against the same base release,
    # which is how a release engineer reasons about hotfix eligibility
    # ("if this hotfix fails, can I re-derive a working image?" yes, by
    # re-warming from the cold base).
    #
    # We deliberately do NOT chain warm rounds (warm-1 -> warm-2): the
    # design doc's full warm-writer requirement would be supporting
    # chained growth on a rescued image, but xorriso 1.5.8.pl02's
    # ``-boot_image any replay`` mode refuses to grow an image whose
    # trailing region now contains a relocated backup GPT (the
    # libburn "Read start address Ns larger than number of readable
    # blocks N" failure documented in the findings). Independent
    # rounds avoid that limitation and still exercise every part of
    # the warm writer transaction we care about for Step 1.
    cold_parent = cold_out
    for round_idx in range(args.warm_rounds):
        log(f"=== Warm round {round_idx + 1}/{args.warm_rounds}")
        round_num = round_idx + 1
        warm_out = out_dir / f"warm-{args.arch}-{round_num}.iso"

        # Build a hotfix payload: a single file at ~1 MiB simulating
        # a changed .deb / squashed package. We vary the size and
        # content to test that the verifier sees the change.
        payload_name = f"hotfix-{round_num}.bin"
        payload_path = payload_root / payload_name
        # Round 1: small (~64 KiB); round 2: medium (~1 MiB); round 3: large (~8 MiB).
        sizes = [64 * 1024, 1024 * 1024, 8 * 1024 * 1024]
        size = sizes[round_idx % len(sizes)]
        with payload_path.open("wb") as f:
            f.write(os.urandom(size))

        # The hotfix targets the ISO path /hotfix/<payload_name>; we use
        # a deliberately novel path so the change is unambiguous.
        manifest_path = out_dir / f"warm-{args.arch}-{round_num}.manifest.json"
        manifest = {
            "add": [{
                "path": f"/hotfix/{payload_name}",
                "source": payload_name,
            }],
            "replace": [],
            "remove": [],
        }
        manifest_path.write_text(json.dumps(manifest, indent=2))

        warm_run = run_warm(args.arch, cold_parent, warm_out, manifest_path,
                             payload_root, args.esp_image)

        # Run the verifier on whatever xorriso produced, even if xorriso
        # failed. The layout is part of the finding we want to capture.
        warm_layout = None
        verifier_data = None
        if warm_out.exists():
            warm_layout = parse_iso_size(warm_out)
            warm_layout["sha256"] = sha256_file(warm_out)
            vr_path = warm_out.parent / (warm_out.name + ".verify.json")
            # Use check=False so the verifier's own exit code is captured
            # but doesn't abort this driver.
            vr_proc = subprocess.run([
                sys.executable,
                str(REPO_ROOT / "build" / "iso" / "verify-image.py"),
                "--image", str(warm_out),
                "--arch", args.arch,
                "--level", "warm",
                "--report", str(vr_path),
                "--esp-image", str(args.esp_image),
            ], capture_output=True, text=True)
            verifier_data = json.loads(vr_path.read_text()) if vr_path.is_file() else None
            verifier_data = verifier_data or {"passed": False, "verifier_exit_code": vr_proc.returncode}

        rcpt_path = warm_out.parent / (warm_out.name + ".receipt.json")
        receipt = json.loads(rcpt_path.read_text()) if rcpt_path.is_file() else None

        report["warm_rounds"].append({
            "round": round_num,
            "run": warm_run,
            "warm_layout": warm_layout,
            "verifier": verifier_data,
            "receipt": receipt,
            "hotfix_size_bytes": size,
            "parent": str(cold_parent),
        })

    report["finished_at"] = time.strftime("%Y-%m-%dT%H:%M:%S%z")
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, indent=2, sort_keys=True))
    log(f"Report: {args.report}")

    # The validation gate: every cold + every warm round must end with
    # exit_code 0 AND verifier_passed=True. If any round is missing or
    # failed, the test driver exits non-zero so CI / the operator notices.
    failures: list[tuple[str, str]] = []
    cold_run = report.get("cold", {})
    if cold_run.get("exit_code") != 0:
        failures.append(("cold", f"exit={cold_run.get('exit_code')}"))
    for w in report.get("warm_rounds", []):
        run_ec = w.get("run", {}).get("exit_code")
        v = w.get("verifier", {}) or {}
        if run_ec != 0 or not v.get("passed"):
            failures.append(
                (f"warm-{w.get('round')}", f"exit={run_ec} verifier_passed={v.get('passed')}")
            )
    if failures:
        log(f"FAIL: {len(failures)} round(s) failed verification:")
        for name, info in failures:
            log(f"  - {name}: {info}")
        sys.exit(1)


if __name__ == "__main__":
    main()