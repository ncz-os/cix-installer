#!/usr/bin/env python3
"""
stage-ncz-payload.py — Stage the real install-tree payload under
``build/iso-cache/v1/ncz-payload/`` for later verbatim copy into the
raw GPT image's ``/ncz-payload/`` directory (the ext4 NCZDATA partition,
mounted by d-i at ``/cdrom`` during the install).

Background (the 2026-09-22 port; history):

  * The legacy monolithic ISO builder (``build/build-iso-di.sh``, removed
    2026-10-06) shipped a real install-tree payload by replacing
    ``/usr/sbin/debootstrap`` inside the d-i installer's
    ``debootstrap-udeb`` with an NCZ "r159" stub. The stub, when invoked
    by base-installer at install time, looks for
    ``/cdrom/ncz-payload/{base.squashfs,<role>.squashfs,<role>.overlay-manifest}``
    and uses a bundled static ``unsquashfs`` (from ``build/sqtools-$ARCH/``)
    to extract them onto ``$TARGET`` (the real target disk d-i mounted),
    reproducing overlayfs-upperdir semantics without a kernel overlay
    mount.

  * The incremental pipeline consumes
    ``build/iso-cache/v1/nodes/<arch>/substrate/<key>/extract`` (the
    upstream Debian netinst extracted by ``import-substrate.py``) plus the
    rEFInd ESP image; ``write-usb-image.py`` writes them into the raw GPT
    image. Without this payload d-i would try a network install.

  * This script ports the r159 stub's payload-side half of the
    mechanism into the new pipeline. It stages
    ``build/iso-cache/v1/ncz-payload/{base.squashfs,desktop.squashfs,
    desktop.overlay-manifest,sqtools/}`` from the real, built
    ``assets/squashfs/*.squashfs`` (the same layers
    ``build/build-squashfs-layers.sh all`` produces via
    ``mmdebstrap``/``mksquashfs``) plus the architecture-matched static
    ``unsquashfs`` bundle from ``build/sqtools-$ARCH/``.

  * The OTHER half — patching ``/usr/sbin/debootstrap`` inside the
    installer's ``debootstrap-udeb`` to invoke this payload — is the job
    of ``patch-debootstrap-stub.py``. The two are intentionally separate
    scripts; this one is purely the payload-side, the other is purely
    the installer-side.

What this script does, line by line:

  1. Validates the required input squashfs assets exist on disk. Real
     assets only — no synthetic/toy layers (per the brief).
  2. Verifies the squashfs layer ROOT entries are mode ``drwxr-xr-x``
     (0755) using the host's ``unsquashfs -ll``. This is the
     ``assert_squashfs_root_mode`` gate the retired ISO builder
     enforced (the 2026-08-26 root-mode gate,
     documented in ``docs/IMAGE-BUILD-GUARDRAILS.md``) — without it,
     ``unsquashfs -f -d $TARGET`` would re-stamp ``$TARGET``'s OWN mode
     from each layer's root entry (last layer wins), and a layer built
     from a mktemp-0700 staging dir would ship ``/`` at 0700 and break
     greetd / NIC bring-up / RTC for every non-root UID. We refuse to
     stage a layer whose root entry isn't 0755.
  3. Verifies every delta overlay has a non-empty companion
     ``<role>.overlay-manifest`` (the r159 stub FATALs on a missing
     manifest — silent delta extraction without whiteout/opaque
     semantics reproduces the v15 DBus/network/greeter failure).
  4. Verifies the architecture-matched sqtools bundle exists. This
     matters because an ARM64 ``unsquashfs`` running on an AMD64
     installer fails SILENTLY (exit 1, no diagnostic, nothing extracted
     — confirmed 2026-09-15 by mounting a failed install's empty
     target disk directly). The r159 stub exec's ``$SQDIR/sqtools/unsquashfs``
     via the bundled loader, and the loader+libs MUST match the
     installer runtime's architecture.
  5. Stages the files into ``build/iso-cache/v1/ncz-payload/`` as
     a content-addressed, immutable tree (write-once; if you change
     inputs, the cache key changes and downstream consumers get a new
     path). This is the same shape as the substrate import cache.

What this script does NOT do:

  * It does NOT patch ``debootstrap-udeb``. That's
    ``patch-debootstrap-stub.py``'s job and is a separate concern (the
    installer-side, not the payload-side).
  * It does NOT touch the substrate tree. The substrate node under
    ``build/iso-cache/v1/nodes/<arch>/substrate/<key>/`` is the
    verbatim extracted mini.iso and is read-only from this script's
    perspective.
  * It does NOT build squashfs assets. If
    ``assets/squashfs/desktop.squashfs`` doesn't exist, the script
    reports what's missing and exits 1; it does not synthesize.

Output layout::

    build/iso-cache/v1/ncz-payload/<node-key>/
        base.squashfs                  (verbatim from assets/squashfs/)
        desktop.squashfs               (verbatim, optional)
        desktop.overlay-manifest       (verbatim, required iff desktop.squashfs)
        sqtools/                       (verbatim from build/sqtools-<arch>/)
            unsquashfs, ld-*, lib*.so.*
        receipts/stage-ncz-payload-receipt.json
        receipts/stage-ncz-payload-metadata.json
        receipts/node-key.json

The node-key formula is::

    sha256(canonical_encode({
        schema_version: "ncz-payload-stage/v1",
        arch: "amd64",
        base_sha256, desktop_sha256, overlay_sha256, sqtools_manifest_sha256,
        base_mtime_ns, desktop_mtime_ns, overlay_mtime_ns,
        tool_versions
    }))

Time/byte factors appear in the key so a clean rebuild on a different
host (different ``unsquashfs`` version, different ``mksquashfs``
compression parameters producing a bytewise different layer) produces a
fresh node instead of silently matching an older cached payload. The
key is for cache invalidation, NOT for content trust — content trust
comes from the per-file SHA256s and the receipt schema.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
DEFAULT_CACHE_ROOT = REPO_ROOT / "build" / "iso-cache" / "v1"
SQUASHFS_DIR = REPO_ROOT / "assets" / "squashfs"


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def sha256_bytes(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()


def canonical_encode(obj: dict) -> bytes:
    """RFC 8785-style: sorted keys, no whitespace. Stable across runs."""
    return json.dumps(obj, sort_keys=True, separators=(",", ":")).encode("utf-8")


def log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


def tool_version(tool: str) -> str:
    try:
        out = subprocess.check_output([tool, "--version"], text=True, stderr=subprocess.STDOUT)
    except (FileNotFoundError, subprocess.CalledProcessError):
        return f"{tool}-missing"
    return out.splitlines()[0].strip()


def assert_squashfs_root_mode(squashfs_path: Path, label: str) -> None:
    """Gate lifted verbatim from ``build/build-iso-di.sh`` ~line 3438.

    The 2026-08-26 root-mode gate (see
    ``docs/IMAGE-BUILD-GUARDRAILS.md``): ``unsquashfs -f -d $TARGET``
    re-stamps ``$TARGET``'s OWN mode from each layer's root entry at
    install time (last layer wins). A layer built from a mktemp -d
    staging dir (mode 0700) shipped ``/`` at 0700 and broke greetd /
    NIC / RTC for every non-root UID. We refuse to stage a layer
    whose root entry isn't 0755.

    The busybox-side check the stub itself uses (ls -ld) doesn't apply
    here (we're on the build host, not in the installer runtime), so we
    use the host's ``unsquashfs -ll`` and read the mode column of the
    first ``squashfs-root`` entry. Same semantics.

    Note: we deliberately capture ``unsquashfs``'s full output BEFORE
    greping it. ``set -o pipefail`` + ``unsquashfs -ll | grep -m1``
    SIGPIPEs unsquashfs when grep exits after the first match while
    unsquashfs still has buffered output, aborting the whole build
    with exit 141. The same race is documented in
    ``build/build-iso-di.sh`` ~line 3415. We follow the same fix
    pattern: capture-then-grep.
    """
    if shutil.which("unsquashfs") is None:
        raise RuntimeError(
            "unsquashfs not available — cannot verify squashfs layer root "
            "modes (squashfs-tools required)"
        )
    try:
        out = subprocess.check_output(
            ["unsquashfs", "-ll", str(squashfs_path)],
            stderr=subprocess.DEVNULL,
        ).decode("utf-8", errors="replace")
    except subprocess.CalledProcessError as e:
        raise RuntimeError(
            f"unsquashfs -ll failed for {squashfs_path}: {e}"
        ) from e
    # Find the first '... squashfs-root$' line. unsquashfs -ll on
    # modern squashfs-tools puts the root entry on the first line;
    # older versions may not, in which case the absence is itself
    # diagnostic (the layer is malformed).
    line = ""
    for ln in out.splitlines():
        if ln.rstrip().endswith(" squashfs-root"):
            line = ln
            break
    if not line:
        raise RuntimeError(
            f"{label} ({squashfs_path}) has no squashfs-root entry in "
            f"'unsquashfs -ll' output — malformed layer"
        )
    mode = line.split(" ", 1)[0]
    if mode != "drwxr-xr-x":
        raise RuntimeError(
            f"FATAL: {label} ({squashfs_path}) squashfs ROOT entry is "
            f"'{mode}' (expected drwxr-xr-x / 0755). "
            f"unsquashfs -f stamps this mode onto / at install time "
            f"(the 2026-08-26 0700-root incident). Rebuild the layer "
            f"from a 0755 staging dir:\n"
            f"    unsquashfs -d /tmp/fix {squashfs_path} && "
            f"chmod 0755 /tmp/fix && "
            f"mksquashfs /tmp/fix {squashfs_path}.new -comp zstd -noappend "
            f"&& mv {squashfs_path}.new {squashfs_path}"
        )
    log(f"    layer root mode OK (0755): {label}")


def verify_overlay_manifest(manifest_path: Path, role: str, layer_path: Path) -> None:
    """The r159 stub FATALs at install time if ``<role>.overlay-manifest``
    is missing or empty for a layer that is being applied as a delta.
    We mirror that gate here so a missing manifest is caught at BUILD
    time, not at install time. (See ``build/build-iso-di.sh`` ~line
    1255.)"""
    if not manifest_path.is_file():
        raise RuntimeError(
            f"FATAL: {role} layer {layer_path} has no overlay manifest: "
            f"{manifest_path} — rebuild with build/build-squashfs-layers.sh"
        )
    if manifest_path.stat().st_size == 0:
        raise RuntimeError(
            f"FATAL: {role} overlay manifest is EMPTY: {manifest_path} — "
            f"rebuild with build/build-squashfs-layers.sh"
        )
    # Smoke-check: every non-comment line is tab-separated kind<TAB>rel,
    # kind in {whiteout, opaque}. Don't validate rel paths here (the
    # stub does that at install time) but make sure the format is
    # parsable.
    bad = []
    for ln in manifest_path.read_text().splitlines():
        if not ln or ln.lstrip().startswith("#"):
            continue
        parts = ln.split("\t")
        if len(parts) < 2 or parts[0] not in ("whiteout", "opaque"):
            bad.append(ln)
    if bad:
        raise RuntimeError(
            f"FATAL: {role} overlay manifest {manifest_path} has "
            f"malformed lines (must be tab-separated kind<TAB>rel, kind "
            f"in {{whiteout,opaque}}): {bad[:3]}"
        )


def _chmod_r(p: Path) -> None:
    """Best-effort recursive chmod to writable so rmtree works on
    read-only xorriso-extracted or sudo-restricted trees."""
    try:
        subprocess.run(["chmod", "-R", "u+w", str(p)], check=False,
                       capture_output=True)
    except Exception:
        pass


def stage_payload(
    arch: str,
    squashfs_dir: Path,
    cache_root: Path,
    force: bool = False,
) -> Path:
    """Run the staging. Returns the staged node directory.

    Raises RuntimeError on any gate failure.
    """
    if arch not in ("amd64", "arm64"):
        raise RuntimeError(f"unsupported arch: {arch} (must be amd64 or arm64)")

    # --- 1. Validate base.squashfs (REQUIRED) ---------------------------
    base_layer = squashfs_dir / "base.squashfs"
    if not base_layer.is_file():
        raise RuntimeError(
            f"FATAL: required base layer missing: {base_layer}\n"
            f"  Build it with: NCZ_TARGET_ARCH={arch} "
            f"NCZ_SKIP_FRESHNESS_GATE=1 "
            f"ARTISTPACK_SOURCE_ROOT=/home/jasonperlow/Projects/artistpack/packs "
            f"sudo -E bash build/build-squashfs-layers.sh base"
        )
    assert_squashfs_root_mode(base_layer, "base")

    # --- 2. Validate desktop.squashfs + overlay-manifest (OPTIONAL) ------
    # If desktop is present, both it AND its manifest are required.
    # If desktop is absent, we still ship a working base-only flow —
    # the r159 stub's component-selector just won't trigger the desktop
    # overlay (it logs "skipping desktop overlay" with no manifest).
    desktop_layer = squashfs_dir / "desktop.squashfs"
    desktop_manifest = squashfs_dir / "desktop.overlay-manifest"
    desktop_present = desktop_layer.is_file()
    if desktop_present:
        assert_squashfs_root_mode(desktop_layer, "desktop")
        verify_overlay_manifest(desktop_manifest, "desktop", desktop_layer)
    else:
        if desktop_manifest.is_file():
            log(f"WARNING: {desktop_manifest} present without {desktop_layer} — "
                f"ignoring manifest (would never be applied at install time)")
        log(f"INFO: desktop layer absent; the r159 stub will skip the "
            f"desktop overlay and install base-only")

    # --- 2b. Validate desktop-hotfix.squashfs + overlay-manifest (OPTIONAL) --
    # The r159 install-time stub already looks for a "$ROLE-hotfix.squashfs"
    # layer (patch-debootstrap-stub.py's HOTFIX_ROLE="$ROLE-hotfix") and
    # applies it if present -- that logic was already wired. What was
    # missing until 2026-09-24 was this build-side staging step, so a real
    # hotfix.squashfs built by build/build-squashfs-layers.sh's `hotfix`
    # target sat in assets/squashfs/ and never made it onto the ISO.
    hotfix_layer = squashfs_dir / "desktop-hotfix.squashfs"
    hotfix_manifest = squashfs_dir / "desktop-hotfix.overlay-manifest"
    hotfix_present = hotfix_layer.is_file()
    if hotfix_present:
        assert_squashfs_root_mode(hotfix_layer, "desktop-hotfix")
        if hotfix_manifest.is_file():
            verify_overlay_manifest(hotfix_manifest, "desktop-hotfix", hotfix_layer)
        else:
            log(f"WARNING: {hotfix_layer} present without an overlay manifest — "
                f"staging it anyway; the stub applies it as a plain overlay")
    else:
        log(f"INFO: desktop-hotfix layer absent; skipping (not required)")

    # --- 2c. Validate the diag busybox (OPTIONAL, per-arch) ----------------
    # preseed/diag-console.sh looks for /cdrom/ncz-payload/busybox-$ARCH at
    # runtime (the diag console's static busybox + applet farm). It is a
    # committed binary at assets/diag/busybox-$ARCH, not something this
    # pipeline builds -- just copy it onto the ISO top-level ncz-payload/ dir,
    # matching where diag-console.sh actually looks.
    busybox_src = REPO_ROOT / "assets" / "diag" / f"busybox-{arch}"
    busybox_present = busybox_src.is_file()
    if not busybox_present:
        log(f"WARNING: {busybox_src} absent — diag console will have no "
            f"fallback busybox on this medium")

    # --- 3. Validate sqtools (REQUIRED — bundled static unsquashfs) ------
    sqtools_src = REPO_ROOT / "build" / f"sqtools-{arch}"
    if arch == "arm64" and not sqtools_src.is_dir():
        # Historical arm64 builds predate the suffixed directory; unlike the
        # amd64 bundle, build/sqtools is unambiguously AArch64 (its loader is
        # ld-linux-aarch64.so.1).  Retain that warm-cache compatibility while
        # still never allowing an amd64 bundle into an arm64 image.
        legacy = REPO_ROOT / "build" / "sqtools"
        if (legacy / "ld-linux-aarch64.so.1").is_file():
            sqtools_src = legacy
    sqtools_unsq = sqtools_src / "unsquashfs"
    if not sqtools_src.is_dir() or not sqtools_unsq.is_file():
        raise RuntimeError(
            f"FATAL: sqtools bundle missing or incomplete: {sqtools_src}\n"
            f"  An ARM64 unsquashfs running on an AMD64 installer fails "
            f"SILENTLY (exit 1, no diagnostic, nothing extracted — "
            f"confirmed 2026-09-15). The architecture-matched static "
            f"unsquashfs + loader is REQUIRED.\n"
            f"  Build it for {arch}: see build/build-sqtools.sh or the "
            f"build-squashfs-layers.sh packaging step."
        )

    # --- 4. Compute cache key ------------------------------------------
    sqtools_manifest_lines = []
    for p in sorted(sqtools_src.iterdir()):
        try:
            rel = p.name
            sha = sha256_file(p) if p.is_file() else ""
            mode = oct(p.stat().st_mode & 0o7777)
            sqtools_manifest_lines.append(f"{rel}\t{mode}\t{sha}")
        except OSError as e:
            sqtools_manifest_lines.append(f"{p.name}\t<error:{e}>\t")
    sqtools_manifest = "\n".join(sqtools_manifest_lines)

    def _stat(path: Path) -> dict:
        if not path.exists():
            return {"present": False}
        s = path.stat()
        return {
            "present": True,
            "sha256": sha256_file(path),
            "size": s.st_size,
            "mtime_ns": s.st_mtime_ns,
        }

    canonical_payload = canonical_encode({
        "schema_version": "ncz-payload-stage/v1",
        "arch": arch,
        "base": _stat(base_layer),
        "desktop": _stat(desktop_layer) if desktop_present else {"present": False},
        "desktop_overlay_manifest": _stat(desktop_manifest) if desktop_present else {"present": False},
        "desktop_hotfix": _stat(hotfix_layer) if hotfix_present else {"present": False},
        "desktop_hotfix_overlay_manifest": (
            _stat(hotfix_manifest) if hotfix_present and hotfix_manifest.is_file()
            else {"present": False}
        ),
        "busybox": _stat(busybox_src) if busybox_present else {"present": False},
        "sqtools_manifest": sqtools_manifest,
        "tool_versions": {
            "unsquashfs": tool_version("unsquashfs"),
            "mksquashfs": tool_version("mksquashfs"),
            "xorriso": tool_version("xorriso"),
        },
    })
    node_key = sha256_bytes(canonical_payload)
    # See patch-initrd-t2-kernel.py for the full note: a cache node created
    # empty and filled afterwards turns an interrupted run into a permanent
    # cache HIT on a half-built node. Build into .partial.<pid>, publish by
    # rename once the receipt exists, and treat a receipt-less node as
    # incomplete rather than trusting it.
    node_dir = cache_root / "ncz-payload" / node_key
    done_marker = node_dir / "receipts" / "stage-ncz-payload-receipt.json"
    if node_dir.exists() and not force:
        if done_marker.is_file():
            log(f"node exists: {node_dir}")
            log(f"node_key: {node_key}")
            return node_dir
        log(f"WARNING: incomplete cache node (no receipt): {node_dir} -- restaging")

    if node_dir.exists():
        _chmod_r(node_dir)
        shutil.rmtree(node_dir)
    build_dir = node_dir.parent / f"{node_key}.partial.{os.getpid()}"
    if build_dir.exists():
        _chmod_r(build_dir)
        shutil.rmtree(build_dir)
    build_dir.mkdir(parents=True)
    receipts = build_dir / "receipts"
    receipts.mkdir()

    # --- 5. Copy base.squashfs ------------------------------------------
    shutil.copy2(str(base_layer), str(build_dir / "base.squashfs"))
    log(f"    staged base.squashfs ({base_layer.stat().st_size} bytes)")

    # --- 6. Copy desktop.squashfs + manifest (if present) --------------
    if desktop_present:
        shutil.copy2(str(desktop_layer), str(build_dir / "desktop.squashfs"))
        shutil.copy2(str(desktop_manifest), str(build_dir / "desktop.overlay-manifest"))
        log(f"    staged desktop.squashfs ({desktop_layer.stat().st_size} bytes)")
        log(f"    staged desktop.overlay-manifest "
            f"({desktop_manifest.stat().st_size} bytes)")

    # --- 6b. Copy desktop-hotfix.squashfs + manifest (if present) ------
    if hotfix_present:
        shutil.copy2(str(hotfix_layer), str(build_dir / "desktop-hotfix.squashfs"))
        log(f"    staged desktop-hotfix.squashfs ({hotfix_layer.stat().st_size} bytes)")
        if hotfix_manifest.is_file():
            shutil.copy2(str(hotfix_manifest), str(build_dir / "desktop-hotfix.overlay-manifest"))
            log(f"    staged desktop-hotfix.overlay-manifest "
                f"({hotfix_manifest.stat().st_size} bytes)")

    # --- 6c. Copy the diag busybox (if present) -------------------------
    if busybox_present:
        shutil.copy2(str(busybox_src), str(build_dir / f"busybox-{arch}"))
        (build_dir / f"busybox-{arch}").chmod(0o755)
        log(f"    staged busybox-{arch} ({busybox_src.stat().st_size} bytes)")

    # --- 7. Copy sqtools/ (architecture-matched) ------------------------
    # cp -a to preserve permissions; the unsquashfs binary must remain
    # executable in the staged tree because xorriso preserves perms
    # when packing the ISO 9660 filesystem.
    subprocess.run(
        ["cp", "-a", str(sqtools_src) + "/.", str(build_dir / "sqtools")],
        check=True,
    )
    log(f"    staged sqtools/ from {sqtools_src}")

    # --- 8. Write receipts ----------------------------------------------
    metadata = {
        "schema_version": "ncz-payload-metadata/v1",
        "arch": arch,
        "node_key": node_key,
        "inputs": {
            "base": str(base_layer),
            "desktop": str(desktop_layer) if desktop_present else None,
            "desktop_overlay_manifest": str(desktop_manifest) if desktop_present else None,
            "desktop_hotfix": str(hotfix_layer) if hotfix_present else None,
            "desktop_hotfix_overlay_manifest": (
                str(hotfix_manifest) if hotfix_present and hotfix_manifest.is_file() else None
            ),
            "busybox": str(busybox_src) if busybox_present else None,
            "sqtools": str(sqtools_src),
        },
        "tool_versions": json.loads(canonical_payload)["tool_versions"],
        "files": [],
    }
    for p in sorted(build_dir.rglob("*")):
        if p.is_file():
            try:
                rel = p.relative_to(build_dir)
                size = p.stat().st_size
                mode = oct(p.stat().st_mode & 0o7777)
                sha = sha256_file(p)
                metadata["files"].append({
                    "path": str(rel), "size": size, "mode": mode, "sha256": sha,
                })
            except OSError as e:
                log(f"WARNING: could not stat {p}: {e}")
    receipts.joinpath("stage-ncz-payload-metadata.json").write_text(
        json.dumps(metadata, indent=2, sort_keys=True)
    )

    receipt = {
        "schema_version": "ncz-payload-receipt/v1",
        "node_key": node_key,
        "node_kind": "ncz-payload",
        "arch": arch,
        "inputs": {
            "base_sha256": sha256_file(base_layer),
            "base_size": base_layer.stat().st_size,
            "desktop_sha256": (sha256_file(desktop_layer)
                               if desktop_present else None),
            "desktop_size": (desktop_layer.stat().st_size
                             if desktop_present else None),
            "desktop_overlay_manifest_sha256": (
                sha256_file(desktop_manifest) if desktop_present else None
            ),
            "desktop_overlay_manifest_size": (
                desktop_manifest.stat().st_size if desktop_present else None
            ),
            "desktop_hotfix_sha256": (
                sha256_file(hotfix_layer) if hotfix_present else None
            ),
            "desktop_hotfix_size": (
                hotfix_layer.stat().st_size if hotfix_present else None
            ),
            "busybox_sha256": (
                sha256_file(busybox_src) if busybox_present else None
            ),
            "busybox_size": (
                busybox_src.stat().st_size if busybox_present else None
            ),
            "sqtools_dir": str(sqtools_src),
            "sqtools_manifest_sha256": sha256_bytes(sqtools_manifest.encode()),
        },
        "outputs": {
            "staged_dir": str(node_dir),
        },
    }
    receipts.joinpath("node-key.json").write_text(json.dumps({
        "node_key": node_key,
        "canonical_payload_hex": canonical_payload.hex(),
        "canonical_payload_sha256": sha256_bytes(canonical_payload),
    }, indent=2, sort_keys=True))

    # Atomic publish: written last, so a node without it is never served.
    receipts.joinpath("stage-ncz-payload-receipt.json").write_text(
        json.dumps(receipt, indent=2, sort_keys=True)
    )
    os.replace(build_dir, node_dir)

    log(f"node_key: {node_key}")
    log(f"node_dir: {node_dir}")
    return node_dir


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--arch", required=True, choices=["amd64", "arm64"],
                    help="target architecture (must match the substrate and "
                         "sqtools-$ARCH bundle)")
    ap.add_argument("--squashfs-dir", type=Path, default=SQUASHFS_DIR,
                    help=f"directory containing base.squashfs / desktop.* "
                         f"(default: {SQUASHFS_DIR})")
    ap.add_argument("--cache-root", type=Path, default=DEFAULT_CACHE_ROOT,
                    help=f"cache root (default: {DEFAULT_CACHE_ROOT})")
    ap.add_argument("--force", action="store_true",
                    help="re-stage even if the node already exists")
    args = ap.parse_args()

    try:
        node_dir = stage_payload(
            arch=args.arch,
            squashfs_dir=args.squashfs_dir.resolve(),
            cache_root=args.cache_root.resolve(),
            force=args.force,
        )
    except RuntimeError as e:
        log(f"FATAL: {e}")
        return 2
    log(f"OK: staged payload at {node_dir}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
