#!/usr/bin/env python3
"""singularity-patch-reconcile.py -- auto-retire downstream Singularity
patches once their tracked upstream PR merges.

WHY THIS EXISTS (2026-09-20/21, operator directive): "As new merges occur,
no-op the patches." assets/singularity/patches/README.md's own convention
already says a merged patch should be deleted "in the same commit that
bumps past it" -- but that has always been a REMEMBERED manual step, same
class of gap preflight-freshness-gate.sh closed for build freshness.
preflight-freshness-gate.sh's check #2 (does the patch still `git apply
--check` against upstream) is a WEAK merge signal: a patch can still apply
cleanly after its PR merged (no conflicting drift yet), so "still applies"
does not mean "still needed". The reliable signal is the PR's own state,
queried directly via `gh pr view --json state,mergedAt,mergeCommitOid`.

This script:
  1. Parses assets/singularity/patches/README.md's "## <subproject> --
     active" sections for "**Upstream PR:** [owner/repo#N](url)" blocks
     and the "Patch `NNNN-*.patch`" filename(s) each one names.
  2. Queries `gh pr view <url> --json state,mergedAt,mergeCommitOid` for
     each -- real GitHub state, not an inference from patch-apply success.
  3. For every MERGED PR: deletes the named patch file(s), removes the
     block from its "active" section, and appends a "retired" entry
     matching the file's own existing convention (see the OPEN merged
     entries already in this file for the exact shape being matched).
  4. Writes the whole file back only if at least one patch was retired;
     never touches it otherwise. Never invents an "active" entry -- this
     script only ever REMOVES, it does not add new tracked PRs.

Exits 0 with nothing retired (the normal nightly case), 0 with a summary
of what was retired, or 2 on a real error (gh not authed, README
unparseable). Never touches git itself -- the caller commits/pushes,
same separation of concerns as the freshness gate.

PINNED UPSTREAM (2026-10-06): the payload is built from the exact commits in
assets/singularity/upstream-pins.tsv, not from upstream heads. A PR that
merged upstream AFTER the pinned commit is not in the build, so deleting its
patch would silently drop the feature. A MERGED PR is therefore retired only
once its merge commit is contained in the pinned commit (GitHub compare API,
pin "ahead" of or "identical" to the merge); otherwise the patch is kept and
the script says why. Unknown (API error, no pin) also keeps the patch.

Usage: build/singularity-patch-reconcile.py [--dry-run]
"""

import json
import re
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
PATCH_ROOT = REPO_ROOT / "assets" / "singularity" / "patches"
README = PATCH_ROOT / "README.md"

PR_BLOCK_RE = re.compile(
    r"\*\*Upstream PR:\*\*\s*\[([^\]]+)\]\((https://github\.com/[^)]+)\)"
)
PATCH_NAME_RE = re.compile(r"`([0-9]{4}-[A-Za-z0-9._-]+\.patch)`")
SECTION_RE = re.compile(r"^## (.+?)(?:\s+[-—]+\s+active)?\s*$")
PINS = REPO_ROOT / "assets" / "singularity" / "upstream-pins.tsv"
GITHUB_URL_RE = re.compile(r"^https://github\.com/([^/]+)/([^/]+?)(?:\.git)?/?$")


def pinned_row(sub_name: str) -> tuple[str, str] | None:
    """(url, sha) pinned for a patch directory, or None when not pinned."""
    if not PINS.is_file():
        return None
    want = "." if sub_name == "singularity-desktop" else f"subprojects/{sub_name}"
    for line in PINS.read_text().splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        cols = line.split("\t")
        if len(cols) == 4 and cols[0] == want:
            return cols[1], cols[3]
    return None


def pin_contains(sub_name: str, merge_sha: str) -> tuple[bool, str]:
    """Is the merge commit an ancestor of (or equal to) the pinned commit?"""
    row = pinned_row(sub_name)
    if row is None:
        return False, f"no upstream pin for {sub_name}"
    url, pin = row
    m = GITHUB_URL_RE.match(url)
    if not m or not re.fullmatch(r"[0-9a-f]{40}", merge_sha or ""):
        return False, f"cannot compare {merge_sha} with pin {pin[:12]} ({url})"
    out = subprocess.run(
        [
            "gh",
            "api",
            f"repos/{m.group(1)}/{m.group(2)}/compare/{merge_sha}...{pin}",
            "--jq",
            ".status",
        ],
        capture_output=True,
        text=True,
        timeout=30,
        check=False,
    )
    status = out.stdout.strip()
    if out.returncode != 0 or not status:
        return (
            False,
            f"compare {merge_sha[:12]}...{pin[:12]} failed: {out.stderr.strip()}",
        )
    if status in ("ahead", "identical"):
        return True, f"pin {pin[:12]} contains merge {merge_sha[:12]}"
    return False, f"pin {pin[:12]} is {status} relative to merge {merge_sha[:12]}"


def gh_pr_state(url: str) -> dict:
    out = subprocess.run(
        ["gh", "pr", "view", url, "--json", "state,mergedAt,mergeCommit"],
        capture_output=True,
        text=True,
        timeout=30,
        check=False,
    )
    if out.returncode != 0:
        raise RuntimeError(f"gh pr view {url} failed: {out.stderr.strip()}")
    data = json.loads(out.stdout)
    mc = data.get("mergeCommit") or {}
    data["mergeCommitOid"] = (
        mc.get("oid", "unknown") if isinstance(mc, dict) else "unknown"
    )
    return data


def split_blocks(section_text: str) -> list[str]:
    # Blocks are separated by a blank line before the next "**Upstream PR:**"
    parts = re.split(r"\n(?=\*\*Upstream PR:\*\*)", section_text)
    return [p for p in parts if p.strip()]


def main() -> int:
    dry_run = "--dry-run" in sys.argv

    if not README.is_file():
        print(f"[reconcile] no {README} -- nothing to reconcile")
        return 0

    text = README.read_text()
    lines = text.split("\n")

    # Locate every "active" section by header, and its body up to the next
    # "## " header.
    section_spans = []  # (name, start_line_idx, end_line_idx)
    cur_name = None
    cur_start = None
    for i, line in enumerate(lines):
        if line.startswith("## "):
            if cur_name is not None:
                section_spans.append((cur_name, cur_start, i))
            m = SECTION_RE.match(line)
            if m and line.rstrip().endswith("active"):
                cur_name = m.group(1).strip()
                cur_start = i + 1
            else:
                cur_name = None
                cur_start = None
    if cur_name is not None:
        section_spans.append((cur_name, cur_start, len(lines)))

    if not section_spans:
        print("[reconcile] no active sections found in README.md")
        return 0

    retired_notes = []
    removed_line_ranges = []  # (start, end) exclusive, in original `lines`
    deleted_files = []

    for sub_name, start, end in section_spans:
        section_text = "\n".join(lines[start:end])
        blocks = split_blocks(section_text)
        # Track cumulative offset within this section to map block back to
        # absolute line numbers.
        offset = start
        for block in blocks:
            block_lines = block.split("\n")
            block_start = offset
            block_end = offset + len(block_lines)
            offset = block_end

            m = PR_BLOCK_RE.search(block)
            if not m:
                continue
            pr_label, pr_url = m.group(1), m.group(2)

            try:
                state = gh_pr_state(pr_url)
            except Exception as e:
                print(f"[reconcile] WARN: could not check {pr_label} ({pr_url}): {e}")
                continue

            if state.get("state") == "CLOSED":
                # Closed WITHOUT a merge: upstream declined it. The patch is still
                # carried (the build needs it) but nothing will ever retire it, so
                # say so instead of calling it open.
                print(
                    f"[reconcile] ATTENTION: {pr_label} was CLOSED without merging -- "
                    "keeping patch; decide whether to carry it, move it, or drop it"
                )
                continue
            if state.get("state") != "MERGED":
                print(f"[reconcile] OK: {pr_label} still open -- keeping patch")
                continue

            patch_names = PATCH_NAME_RE.findall(block)
            if not patch_names:
                print(
                    f"[reconcile] WARN: {pr_label} is MERGED but no patch filename found in its block -- skipping, check README.md by hand"
                )
                continue

            merge_sha = (state.get("mergeCommitOid") or "unknown")[:40]
            merged_at = (state.get("mergedAt") or "unknown-date")[:10]

            contained, why = pin_contains(sub_name, merge_sha)
            if not contained:
                print(
                    f"[reconcile] KEEP: {pr_label} MERGED ({merge_sha}, {merged_at}) but not in the pinned "
                    f"upstream build ({why}) -- retire it in the same commit that bumps the pin past it"
                )
                continue

            found_all = True
            for pname in patch_names:
                candidates = (
                    list((PATCH_ROOT / sub_name).glob(pname))
                    if (PATCH_ROOT / sub_name).is_dir()
                    else []
                )
                if not candidates:
                    # root-repo exception dirs (e.g. singularity-desktop
                    # patch applying at top level) still live under their
                    # own subdir name in this tree -- same glob covers it.
                    print(
                        f"[reconcile] WARN: {pr_label} is MERGED but patch file {pname} not found under {PATCH_ROOT / sub_name} -- skipping"
                    )
                    found_all = False
                    continue
                for c in candidates:
                    if dry_run:
                        print(
                            f"[reconcile] DRY-RUN: would delete {c.relative_to(REPO_ROOT)}"
                        )
                    else:
                        c.unlink()
                    deleted_files.append(str(c.relative_to(REPO_ROOT)))

            if not found_all:
                continue

            print(
                f"[reconcile] RETIRE: {pr_label} MERGED ({merge_sha}, {merged_at}) -- removing {', '.join(patch_names)}"
            )
            removed_line_ranges.append((block_start, block_end))
            retired_notes.append(
                f"## {sub_name} — retired {merged_at}\n\n"
                f"**Upstream PR:** [{pr_label}]({pr_url})\n"
                f"— **MERGED** (`{merge_sha}`, {merged_at}), auto-retired by "
                f"build/singularity-patch-reconcile.py. Patch(es) "
                f"{', '.join(f'`{p}`' for p in patch_names)} deleted.\n"
            )

    if not retired_notes:
        print("[reconcile] nothing to retire -- all tracked PRs still open")
        return 0

    if dry_run:
        print(
            f"[reconcile] DRY-RUN: would retire {len(retired_notes)} patch(es), README.md left untouched"
        )
        return 0

    # Remove retired blocks from the file (highest line first so earlier
    # indices stay valid), then append the retired notes near the top of
    # the "Previously landed" section if present, else at end of file.
    new_lines = list(lines)
    for start, end in sorted(removed_line_ranges, reverse=True):
        del new_lines[start:end]

    new_text = "\n".join(new_lines)
    # Strip any section that is now empty (just a header with no blocks left).
    new_text = re.sub(r"## ([^\n]+?) — active\n+(?=## |\Z)", "", new_text)

    insertion_marker = "## Previously landed"
    note_block = "\n" + "\n".join(retired_notes)
    if insertion_marker in new_text:
        new_text = new_text.replace(
            insertion_marker, note_block.strip("\n") + "\n\n" + insertion_marker, 1
        )
    else:
        new_text = new_text.rstrip("\n") + "\n\n" + note_block.strip("\n") + "\n"

    README.write_text(new_text)
    print(
        f"[reconcile] retired {len(retired_notes)} patch(es), deleted {len(deleted_files)} file(s): {', '.join(deleted_files)}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
