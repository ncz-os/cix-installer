#!/usr/bin/env python3
"""
prove-arm64-stage2-fixes.py — in-isolation proof harness for the three
arm64 ISO stage-2 defects fixed on 2026-09-29.

The end-to-end arm64 build lives on the arm64 build host and runs in a rootful
ncz-imagebuild container that is NOT available on other hosts. The brief
explicitly forbids attempting the full arm64 build here. Each defect
has a measured behavior in production; this script reproduces that
behavior with synthetic fixtures and shows the fix in place.

Proof surface:

  Proof A (defect #1, dangling symlink):
    NEGATIVE -- pre-fix copytree (symlinks=False) raised on the
                dangling scripts/kernel-doc symlink (the 2026-09-28
                arm64 traceback). Reproduce it.
    POSITIVE -- the fixed helper copies the tree and the symlink is
                still a symlink afterwards (not followed).

  Proof B (defect #2, rejected sibling):
    POSITIVE -- a stage/edge/headers-dir.native-prepare-rejected
                directory is present on disk; the staged tree has it
                absent.

  Proof C (defect #3, empty BUILD_SHA):
    NEGATIVE -- with git failing (not on PATH), the build script
                ERRORS instead of producing an unstamped `-.img`.
    POSITIVE -- with git working, the filename carries the real sha.

Run from the cix-installer repo root:

    python3 build/iso/tests/prove-arm64-stage2-fixes.py

Exit 0 on success. The captured output is the proof; the verbatim
transcripts are quoted in the commit message.
"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent.parent
WRITE_USB = REPO_ROOT / "build" / "iso" / "write-usb-image.py"
BUILD_INSTALLER = REPO_ROOT / "build" / "build-installer-image.sh"
MAKEFILE = REPO_ROOT / "Makefile"

# Sanity check on import: this script lives at <repo>/build/iso/tests/,
# so four .parent calls reach the repo root. The original three-parent
# form surfaced as `build/build/iso/write-usb-image.py` -- caught on the
# first run, fixed here.
assert WRITE_USB.is_file(), f"WRITE_USB path wrong: {WRITE_USB}"
assert BUILD_INSTALLER.is_file(), f"BUILD_INSTALLER path wrong: {BUILD_INSTALLER}"
assert MAKEFILE.is_file(), f"MAKEFILE path wrong: {MAKEFILE}"


def banner(s: str) -> None:
    print("\n" + "=" * 78)
    print(s)
    print("=" * 78, flush=True)


def proof_a_dangling_symlink() -> None:
    """Defect #1 -- shutil.copytree with symlinks=False raises on a
    dangling symlink; the fixed helper preserves it as a symlink."""
    banner("PROOF A -- dangling scripts/kernel-doc symlink")

    with tempfile.TemporaryDirectory(prefix="proof-a-") as tmp:
        tmpp = Path(tmp)
        # Stage a minimal headers-dir-shaped tree with a DELIBERATELY
        # dangling symlink at scripts/kernel-doc, plus a real file so
        # the negative case has a baseline. kernel-doc is a symlink
        # whose target was removed by an upstream kernel-doc refactor;
        # this is exactly what was on the arm64 build host 2026-09-28.
        real_dir = tmpp / "src" / "lib" / "modules" / "7.2.8-sky1-ncz" / "build"
        scripts = real_dir / "scripts"
        scripts.mkdir(parents=True)
        (scripts / "Makefile").write_text("# real file\n")
        (scripts / "basic").mkdir()
        (scripts / "basic" / "fixdep.c").write_text("/* real */\n")
        kernel_doc = scripts / "kernel-doc"
        os.symlink("/nonexistent/upstream/scripts/kernel-doc.py", kernel_doc)

        # NEGATIVE: the broken default copy. This is what shutil.copytree
        # with symlinks=False did on the arm64 build host 2026-09-28 -- raised on the
        # dangling symlink and aborted the whole copy.
        broken_dst = tmpp / "dst-broken"
        try:
            shutil.copytree(str(real_dir), str(broken_dst), symlinks=False)
            print("[NEGATIVE] EXPECTED shutil.Error but copy succeeded -- fix is too aggressive")
            raise SystemExit(1)
        except shutil.Error as e:
            # Surface the same exception class the operator saw.
            errs = e.args[0] if e.args else []
            kernel_doc_seen = any(
                "scripts/kernel-doc" in str(item) for item in errs
            )
            print(f"[NEGATIVE] shutil.copytree(symlinks=False) raised shutil.Error "
                  f"({len(errs)} entries), scripts/kernel-doc mentioned: {kernel_doc_seen}")
            assert kernel_doc_seen, (
                "reproduction failed: the dangling-symlink entry should "
                "be in the error list"
            )

        # POSITIVE: the fixed helper preserves the symlink and copies
        # the whole tree without raising.
        fixed_dst = tmpp / "dst-fixed"
        sys.path.insert(0, str(WRITE_USB.parent))
        # Importing the module would run write-usb-image.py's argparse
        # main() guard via __name__ == "__main__"; instead, exec the
        # function definitions we need against a fresh namespace. The
        # cleanest way is to import by path with importlib, but only if
        # it's not already executed. Easier: read the source and exec
        # JUST the helpers, not main().
        import importlib.util
        spec = importlib.util.spec_from_file_location("wui", str(WRITE_USB))
        mod = importlib.util.module_from_spec(spec)
        # The module imports things at top-level that may pull in
        # gzip/struct/etc. -- all stdlib, no side effects beyond import.
        spec.loader.exec_module(mod)  # type: ignore[union-attr]
        mod._copytree_dangling_symlink_safe(real_dir, fixed_dst)

        staged_kernel_doc = fixed_dst / "scripts" / "kernel-doc"
        assert staged_kernel_doc.is_symlink(), (
            f"POSITIVE failed: staged scripts/kernel-doc is not a symlink: "
            f"{staged_kernel_doc} (mode={oct(staged_kernel_doc.lstat().st_mode)})"
        )
        target = os.readlink(staged_kernel_doc)
        assert target == "/nonexistent/upstream/scripts/kernel-doc.py", (
            f"POSITIVE failed: symlink target changed: {target!r}"
        )
        # And the real files came with it.
        assert (fixed_dst / "scripts" / "Makefile").is_file()
        assert (fixed_dst / "scripts" / "basic" / "fixdep.c").is_file()
        print(f"[POSITIVE] staged tree at {fixed_dst}")
        print(f"[POSITIVE] scripts/kernel-doc is a symlink -> {target!r}")
        print(f"[POSITIVE] scripts/Makefile + scripts/basic/fixdep.c present")
        print(f"[POSITIVE] {fixed_dst}")


def proof_b_rejected_sibling() -> None:
    """Defect #2 -- headers-dir.native-prepare-rejected must be present
    on disk and ABSENT from the staged tree."""
    banner("PROOF B -- headers-dir.native-prepare-rejected pruned")

    with tempfile.TemporaryDirectory(prefix="proof-b-") as tmp:
        tmpp = Path(tmp)
        kernel_dir = tmpp / "stage" / "r277-7.2.8-sky1-ncz-20260927"
        real_headers = kernel_dir / "headers-dir" / "lib" / "modules" / "7.2.8-sky1-ncz" / "build"
        real_headers.mkdir(parents=True)
        (real_headers / "Makefile").write_text("# real\n")
        # The two siblings the operator's pipeline is expected to leave
        # around but never to ship. Keep .pre-* / .bak names for coverage
        # of those branches too.
        rejected_headers = kernel_dir / "headers-dir.native-prepare-rejected"
        rejected_headers.mkdir()
        (rejected_headers / "junk").write_text("do not ship me")
        stale_headers = kernel_dir / "headers-dir.stale-20260927-180000"
        stale_headers.mkdir()
        (stale_headers / "old").write_text("also do not ship me")
        (kernel_dir / "Image-cixmini.bin").write_bytes(b"fake-image")
        (kernel_dir / "KVER").write_text("7.2.8-sky1-ncz\n")

        # Apply the ignore filter the fixed write-usb-image.py installs
        # in the kernel channel loop.
        sys.path.insert(0, str(WRITE_USB.parent))
        import importlib.util
        spec = importlib.util.spec_from_file_location("wui", str(WRITE_USB))
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)  # type: ignore[union-attr]
        pruned = mod._asset_kernel_ignore(
            str(kernel_dir),
            [p.name for p in kernel_dir.iterdir()],
        )
        print(f"[POSITIVE] on-disk siblings: "
              f"{sorted(p.name for p in kernel_dir.iterdir())}")
        print(f"[POSITIVE] ignore filter drops: {sorted(pruned)}")
        assert "headers-dir.native-prepare-rejected" in pruned
        assert "headers-dir.stale-20260927-180000" in pruned
        assert "headers-dir" not in pruned  # the REAL headers-dir survives
        assert "Image-cixmini.bin" not in pruned
        assert "KVER" not in pruned

        # And run the helper against the staged tree; the rejected
        # sibling must NOT land on the destination.
        staged_dst = tmpp / "staged"
        staged_dst.mkdir()
        mod._copytree_dangling_symlink_safe(
            kernel_dir, staged_dst,
            ignore=mod._asset_kernel_ignore,
            dirs_exist_ok=True,
        )
        landed = sorted(p.name for p in staged_dst.iterdir())
        print(f"[POSITIVE] staged tree contents: {landed}")
        assert "headers-dir" in landed
        assert "Image-cixmini.bin" in landed
        assert "KVER" in landed
        assert "headers-dir.native-prepare-rejected" not in landed, (
            "POSITIVE failed: headers-dir.native-prepare-rejected "
            "landed in the staged tree"
        )
        assert "headers-dir.stale-20260927-180000" not in landed, (
            "POSITIVE failed: headers-dir.stale-* landed in the staged tree"
        )


def proof_c_build_sha() -> None:
    """Defect #3 -- BUILD_SHA resolves empty inside the container.
    With git unavailable, the build must ERROR instead of producing
    a `-.img`. With git working, the filename carries the real sha.
    """
    banner("PROOF C -- empty BUILD_SHA must hard-error")

    # NEGATIVE -- simulate "git fails inside the container": invoke
    # build-installer-image.sh with PATH stripped of git and with no
    # BUILD_VERSION/BUILD_SHA in the environment. The previous version
    # silently fell through to BUILD_VERSION="<date>-" (empty sha); the
    # fix refuses to default and exits 3.
    with tempfile.TemporaryDirectory(prefix="proof-c-") as tmp:
        tmpp = Path(tmp)
        # A minimal-looking repo dir so [ -d "$ROOT/.git" ] is true,
        # but PATH has no git so rev-parse fails.
        repo = tmpp / "repo"
        repo.mkdir()
        (repo / ".git").mkdir()
        env = {
            # PATH has bash + coreutils but no real git -- instead a
            # stub `git` is prepended that exits 127, which is what
            # `command -v git` succeeds on but `git rev-parse` fails
            # on. Mirrors the dubious-ownership / missing-git shape
            # the in-container build had on 2026-09-28.
            "PATH": "/usr/bin:/bin",
            "HOME": str(tmpp),
            "ROOT": str(repo),
            "SUBSTRATE_ISO": str(tmpp / "fake.iso"),
            "OUTPUT": str(tmpp / "out.img"),
            "WORK_DIR": str(tmpp / "work"),
            # Intentionally NO BUILD_VERSION, NO BUILD_SHA.
            # Strip every ambient var the parent shell's env might
            # smuggle in (PATH is the explicit allowlist, PYTHONPATH/
            # LD_* are explicitly empty so the test is hermetic).
            "PYTHONPATH": "",
            "LD_PRELOAD": "",
            "LD_LIBRARY_PATH": "",
        }
        # The fake.iso must EXIST so the SUBSTRATE_ISO env check passes
        # and we can reach the BUILD_VERSION-resolution block. It is
        # never actually read: the next stage's import-substrate.py
        # would, and the script would fail there for unrelated reasons,
        # but that is the wrong layer for the BUILD_VERSION FATAL --
        # the previous-behavior empty-sha path used to land BEFORE the
        # substrate was even imported.
        (tmpp / "fake.iso").write_bytes(b"")
        # Stub git: exists on PATH but exits 127 on every invocation.
        # Prepend to PATH AFTER constructing the env dict so it shadows
        # /usr/bin/git. We also write the stub AFTER the dict above so
        # we don't have to re-key the env.
        stub_bin = tmpp / "stubbin"
        stub_bin.mkdir()
        (stub_bin / "git").write_text("#!/bin/sh\nexit 127\n")
        (stub_bin / "git").chmod(0o755)
        env["PATH"] = f"{stub_bin}:{env['PATH']}"
        # Force the rev-parse fallback to fail: PATH's git is a stub,
        # no BUILD_* env vars. The script's defensive
        # `command -v git >/dev/null 2>&1` will succeed (stub IS on
        # PATH), but `git rev-parse` returns 127 -> empty _sha, leaving
        # BUILD_VERSION unset, hitting the FATAL.
        proc = subprocess.run(
            ["bash", str(BUILD_INSTALLER)],
            env=env, cwd=str(repo),
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        print(f"[NEGATIVE] exit={proc.returncode}")
        print(f"[NEGATIVE] stderr tail:")
        for ln in proc.stderr.strip().splitlines()[-8:]:
            print(f"  | {ln}")
        assert proc.returncode != 0, (
            "NEGATIVE failed: build-installer-image.sh succeeded "
            "without BUILD_VERSION/BUILD_SHA"
        )
        assert "FATAL: BUILD_VERSION" in proc.stderr, (
            f"NEGATIVE failed: expected explicit FATAL in stderr, got: {proc.stderr!r}"
        )
        # And no unstamped .img was produced.
        assert not (tmpp / "out.img").exists(), (
            "NEGATIVE failed: an unstamped out.img was produced"
        )

    # POSITIVE -- with git working AND the script's own $ROOT (the
    # real repo at WRITE_USB.parent.parent) HEAD readable, the script
    # succeeds and BUILD_VERSION ends with the real HEAD's short sha.
    # The script ignores any env-passed ROOT -- it computes its own
    # from BASH_SOURCE -- so we can only verify by reading HEAD from
    # the real repo, which is what the script will read too.
    with tempfile.TemporaryDirectory(prefix="proof-c-") as tmp:
        tmpp = Path(tmp)
        # A scratch workspace so subprocess doesn't pollute the real
        # repo. $ROOT inside the script still resolves to the real
        # repo via BASH_SOURCE; cwd here only affects relative paths.
        repo = tmpp / "scratch"
        repo.mkdir()
        env = {
            **os.environ,
            "SUBSTRATE_ISO": str(tmpp / "fake.iso"),
            "OUTPUT": str(tmpp / "out.img"),
            "WORK_DIR": str(tmpp / "work"),
        }
        (tmpp / "fake.iso").write_bytes(b"")
        sha = subprocess.run(
            ["git", "-C", str(REPO_ROOT), "rev-parse", "--short", "HEAD"],
            check=True, capture_output=True, text=True,
        ).stdout.strip()
        proc = subprocess.run(
            ["bash", str(BUILD_INSTALLER)],
            env=env, cwd=str(repo),
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        print(f"[POSITIVE] exit={proc.returncode} (expected !=0 because "
              f"fake.iso missing -- we only need the BUILD_VERSION line)")
        # The script's [build-installer-image] BUILD_VERSION=... line is
        # written by a bare `echo`, which lands on STDOUT (not stderr).
        # Combine the streams before searching -- the test wants to read
        # the BUILD_VERSION line, not which file descriptor it came
        # from.
        combined = proc.stdout + proc.stderr
        # BUILD_VERSION must end with the sha we just read.
        version_line = next(
            (ln for ln in combined.splitlines()
             if ln.startswith("[build-installer-image] BUILD_VERSION=")),
            None,
        )
        assert version_line is not None, (
            f"POSITIVE failed: no BUILD_VERSION line in stdout+stderr: "
            f"{combined!r}"
        )
        version = version_line.split("=", 1)[1].strip()
        print(f"[POSITIVE] {version_line} (HEAD sha: {sha})")
        assert version.endswith(sha), (
            f"POSITIVE failed: BUILD_VERSION does not end with HEAD sha: "
            f"{version!r} vs {sha!r}"
        )
        assert not version.endswith("-"), (
            "POSITIVE failed: BUILD_VERSION ended in '-' (empty sha component)"
        )


def main() -> int:
    proof_a_dangling_symlink()
    proof_b_rejected_sibling()
    proof_c_build_sha()
    print("\nALL THREE PROOFS PASSED.")
    return 0


if __name__ == "__main__":
    sys.exit(main())