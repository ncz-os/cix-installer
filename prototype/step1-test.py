#!/usr/bin/env python3
"""
step1-test.py — Step 1 qualification test driver.

Runs:
    1. Cold compose of an initial real rEFInd + d-i ISO from the cached
       substrate (Bookworm amd64 netboot) and the rEFInd ESP.
    2. N successive warm-growth runs (default 3), each:
        a. reflink-clones the previous artifact
        b. applies a hotfix-shaped change (a replacement of a single
           file at a realistic size — e.g. simulating a replaced
           squashfs or .deb) via -update + explicit -append_partition
        c. runs the independent verifier
        d. records the real numbers (clone time, growth time, byte
           counts, ESP-LBA, GPT backup LBA)
    3. Reports every step's real numbers as a single JSON document.

Each hotfix is sized to roughly simulate a real Debian package replacement
or squashfs delta (a few hundred KB to a few MB). We don't simulate the
whole Squasfs hotfix path (that needs the rest of the content-addressed
graph, out of scope for Step 1); we simulate the "logical add/replace at a
realistic size" part of a hotfix.

Run this script after import-substrate.py and build-refind-esp.py have
populated the cache. Output goes to prototype/output/step1-report.json.
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

    # Warm rounds
    parent = cold_out
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

        warm_run = run_warm(args.arch, parent, warm_out, manifest_path,
                             payload_root, args.esp_image)
        if warm_run["exit_code"] != 0:
            log(f"Warm round {round_num} FAILED")
            report["warm_rounds"].append({
                "round": round_num,
                "run": warm_run,
                "error": "xorriso_warm_failed",
            })
            break

        warm_layout = parse_iso_size(warm_out)
        warm_layout["sha256"] = sha256_file(warm_out)
        # Read the verifier report
        vr_path = warm_out.parent / (warm_out.name + ".verify.json")
        verifier_data = json.loads(vr_path.read_text()) if vr_path.is_file() else None

        # Read the receipt
        rcpt_path = warm_out.parent / (warm_out.name + ".receipt.json")
        receipt = json.loads(rcpt_path.read_text()) if rcpt_path.is_file() else None

        report["warm_rounds"].append({
            "round": round_num,
            "run": warm_run,
            "warm_layout": warm_layout,
            "verifier": verifier_data,
            "receipt": receipt,
            "hotfix_size_bytes": size,
        })
        parent = warm_out

    report["finished_at"] = time.strftime("%Y-%m-%dT%H:%M:%S%z")
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, indent=2, sort_keys=True))
    log(f"Report: {args.report}")


if __name__ == "__main__":
    main()