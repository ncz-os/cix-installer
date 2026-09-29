"""Unit tests for build/singularity-patch-reconcile.py.

Run: python3 -m unittest build/tests/test_singularity_patch_reconcile.py
Uses real git (`git apply --check -R`) against throwaway repos; no network.
"""

import importlib.util
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "singularity-patch-reconcile.py"
spec = importlib.util.spec_from_file_location("reconcile", SCRIPT)
rc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rc)


def git(cwd, *args):
    subprocess.run(
        ["git", "-C", str(cwd), *args],
        check=True,
        capture_output=True,
        env={
            "GIT_AUTHOR_NAME": "t",
            "GIT_AUTHOR_EMAIL": "t@t",
            "GIT_COMMITTER_NAME": "t",
            "GIT_COMMITTER_EMAIL": "t@t",
            "PATH": "/usr/bin:/bin:/usr/local/bin",
        },
    )


def block(sub_pr, patch, extra=""):
    return (
        f"**Upstream PR:** [o/r#{sub_pr}](https://github.com/o/r/pull/{sub_pr})\n"
        f"open. Patch `{patch}`. {extra}\n\n"
    )


class Fixture:
    """A patch tree plus an 'upstream' repo per subproject."""

    def __init__(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.patches = self.root / "patches"
        self.patches.mkdir()
        self.readme = self.patches / "README.md"
        self.upstream = self.root / "upstream"
        self.upstream.mkdir()

    def make_upstream(self, sub, content):
        d = self.upstream / sub
        d.mkdir()
        git(d, "init", "-q")
        (d / "f.txt").write_text(content)
        git(d, "add", "f.txt")
        git(d, "commit", "-q", "-m", "init")
        return d

    def make_patch(self, sub, name, old, new):
        """Patch turning f.txt from `old` into `new`."""
        d = self.root / "scratch"
        d.mkdir(exist_ok=True)
        git(d, "init", "-q")
        (d / "f.txt").write_text(old)
        git(d, "add", "f.txt")
        git(d, "commit", "-q", "-m", "a")
        (d / "f.txt").write_text(new)
        diff = subprocess.run(
            ["git", "-C", str(d), "diff"], capture_output=True, text=True, check=False
        ).stdout
        subprocess.run(["rm", "-rf", str(d / ".git")], check=False)
        pd = self.patches / sub
        pd.mkdir(exist_ok=True)
        (pd / name).write_text(diff)
        return pd / name

    def reverse_fn(self):
        def fn(sub, patch):
            r = subprocess.run(
                [
                    "git",
                    "-C",
                    str(self.upstream / sub),
                    "apply",
                    "--check",
                    "-R",
                    str(patch),
                ],
                capture_output=True,
                check=False,
            )
            return r.returncode == 0

        return fn

    def close(self):
        self.tmp.cleanup()


def state(s):
    return lambda url: {
        "state": s,
        "mergedAt": "2026-09-30T00:00:00Z",
        "mergeCommitOid": "abc123",
    }


class ReconcileTests(unittest.TestCase):
    def setUp(self):
        self.fx = Fixture()
        self.addCleanup(self.fx.close)

    def run_pass(self, st, dry=False):
        return rc.reconcile(
            self.fx.patches,
            self.fx.readme,
            state(st),
            self.fx.reverse_fn(),
            dry_run=dry,
        )

    def statuses(self, results):
        return {f.name: s for _, f, s, _, _ in results}

    def test_closed_pr_is_kept_and_reported(self):
        p = self.fx.make_patch("sub", "0001-a.patch", "one\n", "two\n")
        self.fx.make_upstream("sub", "one\n")
        self.fx.readme.write_text("## sub — active\n\n" + block(1, "0001-a.patch"))
        results, retired = self.run_pass("CLOSED")
        self.assertEqual(self.statuses(results), {"0001-a.patch": "CLOSED"})
        self.assertIn("closed upstream, keep patch, needs decision", results[0][3])
        self.assertEqual(retired, [])
        self.assertTrue(p.exists())

    def test_orphan_patch_without_readme_entry_is_seen_and_kept(self):
        p = self.fx.make_patch("sub", "0002-orphan.patch", "one\n", "two\n")
        self.fx.make_upstream("sub", "two\n")
        self.fx.readme.write_text("## sub — active\n\n" + block(1, "0001-a.patch"))
        results, retired = self.run_pass("MERGED")
        self.assertEqual(self.statuses(results), {"0002-orphan.patch": "ORPHAN"})
        self.assertEqual(retired, [])
        self.assertTrue(p.exists())

    def test_merged_but_not_reverse_applicable_is_never_deleted(self):
        p = self.fx.make_patch("sub", "0001-a.patch", "one\n", "two\n")
        self.fx.make_upstream("sub", "three\n")  # upstream never got the change
        self.fx.readme.write_text("## sub — active\n\n" + block(1, "0001-a.patch"))
        results, retired = self.run_pass("MERGED")
        self.assertEqual(self.statuses(results), {"0001-a.patch": "MERGED-KEEP"})
        self.assertEqual(retired, [])
        self.assertTrue(p.exists())
        self.assertIn("0001-a.patch", self.fx.readme.read_text())

    def test_merged_and_reverse_applicable_is_retired(self):
        p = self.fx.make_patch("sub", "0001-a.patch", "one\n", "two\n")
        self.fx.make_upstream("sub", "two\n")  # upstream contains the change
        self.fx.readme.write_text(
            "## sub — active\n\n" + block(1, "0001-a.patch") + "## Previously landed\n"
        )
        results, retired = self.run_pass("MERGED")
        self.assertEqual(self.statuses(results), {"0001-a.patch": "RETIRE"})
        self.assertEqual([f.name for f in retired], ["0001-a.patch"])
        self.assertFalse(p.exists())
        text = self.fx.readme.read_text()
        self.assertIn("retired 2026-09-30", text)
        self.assertNotIn("sub — active", text)

    def test_superseded_block_is_never_deleted_even_if_merged(self):
        p = self.fx.make_patch("sub", "0001-a.patch", "one\n", "two\n")
        self.fx.make_upstream("sub", "two\n")
        self.fx.readme.write_text(
            "## sub — active\n\n"
            + block(3, "0001-a.patch", "Superseded by the patches below.")
        )
        results, retired = self.run_pass("MERGED")
        self.assertEqual(self.statuses(results), {"0001-a.patch": "SUPERSEDED"})
        self.assertEqual(retired, [])
        self.assertTrue(p.exists())

    def test_open_pr_and_no_pr_entries_kept(self):
        self.fx.make_patch("sub", "0001-a.patch", "one\n", "two\n")
        self.fx.make_patch("sub", "0002-b.patch", "one\n", "two\n")
        self.fx.make_upstream("sub", "two\n")
        self.fx.readme.write_text(
            "## sub — active\n\n"
            + block(1, "0001-a.patch")
            + "**No upstream PR:** branch x not filed. Patch `0002-b.patch`.\n"
        )
        results, retired = self.run_pass("OPEN")
        self.assertEqual(
            self.statuses(results), {"0001-a.patch": "OPEN", "0002-b.patch": "NO-PR"}
        )
        self.assertEqual(retired, [])

    def test_lookup_failure_never_deletes(self):
        p = self.fx.make_patch("sub", "0001-a.patch", "one\n", "two\n")
        self.fx.make_upstream("sub", "two\n")
        self.fx.readme.write_text("## sub — active\n\n" + block(1, "0001-a.patch"))

        def boom(url):
            raise RuntimeError("gh down")

        results, _ = rc.reconcile(
            self.fx.patches, self.fx.readme, boom, self.fx.reverse_fn()
        )
        self.assertEqual(self.statuses(results), {"0001-a.patch": "ERROR"})
        self.assertTrue(p.exists())

    def test_multi_patch_block_keeps_all_when_one_does_not_reverse_apply(self):
        pa = self.fx.make_patch("sub", "0001-a.patch", "one\n", "two\n")
        pb = self.fx.make_patch("sub", "0002-b.patch", "x\n", "y\n")
        self.fx.make_upstream("sub", "two\n")  # 0001 reverse-applies, 0002 does not
        self.fx.readme.write_text(
            "## sub \u2014 active\n\n"
            "**Upstream PR:** [o/r#1](https://github.com/o/r/pull/1)\n"
            "Patches `0001-a.patch` and `0002-b.patch`.\n"
        )
        results, retired = self.run_pass("MERGED")
        self.assertEqual(
            self.statuses(results),
            {"0001-a.patch": "RETIRE", "0002-b.patch": "MERGED-KEEP"},
        )
        self.assertEqual(retired, [])
        self.assertTrue(pa.exists() and pb.exists())
        self.assertIn("0001-a.patch", self.fx.readme.read_text())

    def test_two_blocks_retire_together(self):
        pa = self.fx.make_patch("sub", "0001-a.patch", "one\n", "two\n")
        self.fx.make_upstream("sub", "two\n")
        pb = self.fx.make_patch("other", "0001-b.patch", "x\n", "y\n")
        self.fx.make_upstream("other", "y\n")
        self.fx.readme.write_text(
            "## sub \u2014 active\n\n"
            + block(1, "0001-a.patch")
            + "## other \u2014 active\n\n"
            + block(2, "0001-b.patch")
            + "## Previously landed\n"
        )
        _, retired = self.run_pass("MERGED")
        self.assertEqual(
            sorted(f.name for f in retired), ["0001-a.patch", "0001-b.patch"]
        )
        self.assertFalse(pa.exists() or pb.exists())
        text = self.fx.readme.read_text()
        self.assertEqual(text.count("auto-retired"), 2)
        self.assertNotIn("\u2014 active", text)

    def test_stale_cache_fetch_failure_raises(self):
        import tempfile

        with tempfile.TemporaryDirectory() as cache:
            (Path(cache) / "sub" / ".git").mkdir(parents=True)
            p = self.fx.make_patch("sub", "0001-a.patch", "one\n", "two\n")
            with self.assertRaises(RuntimeError):
                rc.reverse_applies("sub", p, cache)


if __name__ == "__main__":
    unittest.main()
