#!/usr/bin/env python3
"""singularity-patch-reconcile.py -- track the upstream state of every
downstream Singularity patch and retire the ones that landed.

The unit of work is a patch FILE under assets/singularity/patches/<sub>/,
not a README block. Each file is matched to the README block that names it
and classified:

  RETIRE        PR MERGED, block not marked superseded, and the patch
                reverse-applies to upstream head (`git apply --check -R`),
                i.e. upstream really contains the change. Only these are
                ever deleted.
  MERGED-KEEP   PR MERGED but the patch does not reverse-apply: upstream
                differs from the patch, keep it and decide by hand.
  CLOSED        PR CLOSED unmerged: keep the patch, needs a decision.
  SUPERSEDED    README block says superseded: never deleted automatically.
  OPEN          PR open: keep.
  NO-PR         README entry with no upstream PR link: keep.
  ORPHAN        patch file with no README entry: keep, add an entry.

Nothing but RETIRE changes the tree. The caller commits and pushes.

Usage: build/singularity-patch-reconcile.py [--dry-run] [--upstream-cache DIR]
Exit: 0 normally, 2 on a real error.
"""

import json
import re
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
PATCH_ROOT = REPO_ROOT / "assets" / "singularity" / "patches"
UPSTREAM_URL = "https://github.com/singularityos-lab/{sub}.git"

PR_BLOCK_RE = re.compile(
    r"\*\*Upstream PR:\*\*\s*\[([^\]]+)\]\((https://github\.com/[^)]+)\)"
)
BLOCK_START_RE = re.compile(r"^\*\*(?:Upstream PR|No upstream PR):\*\*")
PATCH_NAME_RE = re.compile(r"`([0-9]{4}-[A-Za-z0-9._-]+\.patch)`")
SUPERSEDED_RE = re.compile(r"\bsuperseded\b", re.IGNORECASE)


class Block:
    def __init__(self, sub, start, end, text):
        self.sub = sub
        self.start = start
        self.end = end
        self.text = text
        m = PR_BLOCK_RE.search(text)
        self.pr_label = m.group(1) if m else None
        self.pr_url = m.group(2) if m else None
        self.patches = PATCH_NAME_RE.findall(text)
        self.superseded = bool(SUPERSEDED_RE.search(text))


def gh_pr_state(url):
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


def parse_readme(text):
    """Return the Blocks found in every '## <sub> -- active' section."""
    lines = text.split("\n")
    blocks = []
    sub = None
    cur_start = None

    def flush(end):
        nonlocal cur_start
        if sub is not None and cur_start is not None:
            blocks.append(Block(sub, cur_start, end, "\n".join(lines[cur_start:end])))
        cur_start = None

    for i, line in enumerate(lines):
        if line.startswith("## "):
            flush(i)
            if line.rstrip().endswith("active"):
                sub = re.sub(r"\s+[-—]+\s+active\s*$", "", line[3:]).strip()
            else:
                sub = None
        elif sub is not None and BLOCK_START_RE.match(line):
            flush(i)
            cur_start = i
    flush(len(lines))
    return blocks


def list_patches(patch_root):
    out = []
    if not patch_root.is_dir():
        return out
    for d in sorted(p for p in patch_root.iterdir() if p.is_dir()):
        for f in sorted(d.glob("*.patch")):
            out.append((d.name, f))
    return out


def reverse_applies(sub, patch, cache):
    """True if `patch` reverse-applies to the head of upstream <sub>."""
    clone = Path(cache) / sub
    url = UPSTREAM_URL.format(sub=sub)
    if (clone / ".git").is_dir():
        r = subprocess.run(
            ["git", "-C", str(clone), "fetch", "--quiet", "--depth", "1", "origin"],
            capture_output=True,
            text=True,
            timeout=300,
            check=False,
        )
        if r.returncode != 0:
            raise RuntimeError(
                f"fetch {url} failed, refusing to judge against a stale cache: {r.stderr.strip()}"
            )
        subprocess.run(
            ["git", "-C", str(clone), "reset", "--hard", "--quiet", "FETCH_HEAD"],
            capture_output=True,
            text=True,
            check=True,
        )
    else:
        clone.parent.mkdir(parents=True, exist_ok=True)
        r = subprocess.run(
            ["git", "clone", "--quiet", "--depth", "1", url, str(clone)],
            capture_output=True,
            text=True,
            timeout=600,
            check=False,
        )
        if r.returncode != 0:
            raise RuntimeError(f"clone {url} failed: {r.stderr.strip()}")
    chk = subprocess.run(
        ["git", "-C", str(clone), "apply", "--check", "-R", str(Path(patch).resolve())],
        capture_output=True,
        text=True,
        check=False,
    )
    return chk.returncode == 0


def classify(sub, patch, blocks, state_fn, reverse_fn):
    """Return (status, detail, block) for one patch file."""
    name = Path(patch).name
    block = next((b for b in blocks if b.sub == sub and name in b.patches), None)
    if block is None:
        return "ORPHAN", "no README entry", None
    if block.superseded:
        return (
            "SUPERSEDED",
            "README block says superseded; not deleting automatically",
            block,
        )
    if not block.pr_url:
        return "NO-PR", "no upstream PR", block
    try:
        state = state_fn(block.pr_url)
    except Exception as e:  # noqa: BLE001
        return "ERROR", f"could not check {block.pr_label}: {e}", block
    st = state.get("state")
    if st == "OPEN":
        return "OPEN", f"{block.pr_label} open", block
    if st == "CLOSED":
        return (
            "CLOSED",
            f"{block.pr_label} closed upstream, keep patch, needs decision",
            block,
        )
    if st == "MERGED":
        try:
            ok = reverse_fn(sub, patch)
        except Exception as e:  # noqa: BLE001
            return "ERROR", f"reverse-apply check failed: {e}", block
        if ok:
            return (
                "RETIRE",
                f"{block.pr_label} merged and the patch reverse-applies to upstream head",
                block,
            )
        return (
            "MERGED-KEEP",
            f"{block.pr_label} merged but the patch does not reverse-apply to upstream head, keep and decide",
            block,
        )
    return "ERROR", f"{block.pr_label} unknown state {st!r}", block


def reconcile(patch_root, readme_path, state_fn, reverse_fn, dry_run=False):
    """Run the whole pass. Returns (results, retired_files)."""
    text = readme_path.read_text() if readme_path.is_file() else ""
    blocks = parse_readme(text)
    results = []
    for sub, f in list_patches(patch_root):
        status, detail, block = classify(sub, f, blocks, state_fn, reverse_fn)
        results.append((sub, f, status, detail, block))

    # A block retires only when every patch it names is RETIRE and present.
    retire_blocks = []
    for b in blocks:
        mine = [r for r in results if r[4] is b]
        named = set(b.patches)
        present = {r[1].name for r in mine}
        if mine and named <= present and all(r[2] == "RETIRE" for r in mine):
            retire_blocks.append(b)

    retired_files = []
    for b in retire_blocks:
        for r in results:
            if r[4] is b:
                retired_files.append(r[1])

    if retired_files and not dry_run:
        state = {b: state_fn(b.pr_url) for b in retire_blocks}
        lines = text.split("\n")
        notes = []
        for b in retire_blocks:
            merged_at = (state[b].get("mergedAt") or "unknown-date")[:10]
            sha = (state[b].get("mergeCommitOid") or "unknown")[:40]
            notes.append(
                f"## {b.sub} — retired {merged_at}\n\n"
                f"**Upstream PR:** [{b.pr_label}]({b.pr_url})\n"
                f"— **MERGED** (`{sha}`, {merged_at}), auto-retired by "
                f"build/singularity-patch-reconcile.py after the patch reverse-applied "
                f"to upstream head. Patch(es) {', '.join(f'`{p}`' for p in b.patches)} deleted.\n"
            )
        for b in sorted(retire_blocks, key=lambda x: x.start, reverse=True):
            del lines[b.start : b.end]
        new_text = "\n".join(lines)
        new_text = re.sub(r"## ([^\n]+?) — active\n+(?=## |\Z)", "", new_text)
        marker = "## Previously landed"
        note_block = "\n".join(notes).strip("\n")
        if marker in new_text:
            new_text = new_text.replace(marker, note_block + "\n\n" + marker, 1)
        else:
            new_text = new_text.rstrip("\n") + "\n\n" + note_block + "\n"
        readme_path.write_text(new_text)
        for f in retired_files:
            f.unlink()
    return results, retired_files


def main(argv):
    dry_run = "--dry-run" in argv
    cache = None
    if "--upstream-cache" in argv:
        cache = argv[argv.index("--upstream-cache") + 1]
    if cache is None:
        import os

        cache = os.environ.get("NCZ_UPSTREAM_CACHE") or str(
            Path.home() / ".cache" / "ncz-singularity-upstream"
        )

    readme = PATCH_ROOT / "README.md"
    if not readme.is_file():
        print(f"[reconcile] no {readme} -- nothing to reconcile")
        return 0
    try:
        results, retired = reconcile(
            PATCH_ROOT,
            readme,
            gh_pr_state,
            lambda sub, p: reverse_applies(sub, p, cache),
            dry_run=dry_run,
        )
    except Exception as e:  # noqa: BLE001
        print(f"[reconcile] ERROR: {e}", file=sys.stderr)
        return 2

    for sub, f, status, detail, _ in results:
        print(f"[reconcile] {status}: {sub}/{f.name}: {detail}")
    if retired:
        verb = "would delete" if dry_run else "deleted"
        print(
            f"[reconcile] {verb} {len(retired)} file(s): "
            + ", ".join(str(f.relative_to(REPO_ROOT)) for f in retired)
        )
    else:
        print("[reconcile] nothing retired")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
