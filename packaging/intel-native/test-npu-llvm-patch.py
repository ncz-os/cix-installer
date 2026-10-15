import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
HELPER = os.path.join(HERE, "APPLY-NPU-LLVM-PATCH.py")

PATCH = """diff --git a/mlir/tools/mlir-tblgen/AttrOrTypeFormatGen.cpp b/mlir/tools/mlir-tblgen/AttrOrTypeFormatGen.cpp
--- a/mlir/tools/mlir-tblgen/AttrOrTypeFormatGen.cpp
+++ b/mlir/tools/mlir-tblgen/AttrOrTypeFormatGen.cpp
@@ -1,2 +1,3 @@
 // header
+// patched
 // body
"""

COMPILER_PATCH = """diff --git a/src/vpux_compiler/src/dialect/VPUIP/transforms/passes/legalize_repeating_func_calls.cpp b/src/vpux_compiler/src/dialect/VPUIP/transforms/passes/legalize_repeating_func_calls.cpp
--- a/src/vpux_compiler/src/dialect/VPUIP/transforms/passes/legalize_repeating_func_calls.cpp
+++ b/src/vpux_compiler/src/dialect/VPUIP/transforms/passes/legalize_repeating_func_calls.cpp
@@ -1,2 +1,3 @@
 // header
+// compiler patched
 // body
"""

WRONG_PATCH = PATCH.replace("AttrOrTypeFormatGen.cpp", "Other.cpp")
WRONG_COMPILER_PATCH = COMPILER_PATCH.replace(
    "legalize_repeating_func_calls.cpp", "Other.cpp"
)


def sh(cmd, cwd=None, env=None, check=True):
    r = subprocess.run(
        cmd, cwd=cwd, env=env, capture_output=True, text=True, check=False
    )
    if check and r.returncode != 0:
        raise RuntimeError(f"cmd {cmd!r} failed: {r.stdout} {r.stderr}")
    return r


def git(args, cwd, env=None, check=True):
    return sh(["git"] + args, cwd=cwd, env=env, check=check)


def make_repo(path):
    os.makedirs(path)
    git(["init", "-q", "-b", "main"], path)
    git(["config", "user.email", "t@t"], path)
    git(["config", "user.name", "t"], path)
    return path


def commit_all(repo, msg):
    git(["add", "-A"], repo)
    git(["commit", "-q", "-m", msg], repo)
    return git(["rev-parse", "HEAD"], repo).stdout.strip()


def load_helper():
    spec = importlib.util.spec_from_file_location("npu_helper", HELPER)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class Fixture:
    def __init__(self, root):
        self.root = root
        self.llvm = os.path.join(root, "llvm")
        self.comp = os.path.join(root, "comp")
        make_repo(self.llvm)
        target = os.path.join(self.llvm, "mlir/tools/mlir-tblgen")
        os.makedirs(target)
        with open(os.path.join(target, "AttrOrTypeFormatGen.cpp"), "w") as f:
            f.write("// header\n// body\n")
        self.llvm_up = commit_all(self.llvm, "llvm base")
        make_repo(self.comp)
        with open(os.path.join(self.comp, "README"), "w") as f:
            f.write("x\n")
        comp_target = os.path.join(
            self.comp, "src/vpux_compiler/src/dialect/VPUIP/transforms/passes"
        )
        os.makedirs(comp_target)
        with open(
            os.path.join(comp_target, "legalize_repeating_func_calls.cpp"), "w"
        ) as f:
            f.write("// header\n// body\n")
        self.comp_up = commit_all(self.comp, "comp base")
        git(
            [
                "-c",
                "protocol.file.allow=always",
                "submodule",
                "add",
                "-q",
                self.llvm,
                "thirdparty/llvm-project",
            ],
            self.comp,
        )
        git(["commit", "-q", "-m", "add sub"], self.comp)
        self.comp_up = git(["rev-parse", "HEAD"], self.comp).stdout.strip()
        self.llvm = os.path.join(self.comp, "thirdparty/llvm-project")
        self.patch = os.path.join(root, "p.patch")
        with open(self.patch, "w") as f:
            f.write(PATCH)
        self.compiler_patch = os.path.join(root, "cp.patch")
        with open(self.compiler_patch, "w") as f:
            f.write(COMPILER_PATCH)
        self.report = os.path.join(root, "report.json")

    def detach_both(self):
        git(["checkout", "-q", "--detach", self.llvm_up], self.llvm)
        git(["checkout", "-q", "--detach", self.comp_up], self.comp)

    def run_inproc(
        self, patch=None, compiler_patch=None, epoch="1700000000", expect_ok=True
    ):
        mod = load_helper()
        mod.LLVM_UP = self.llvm_up
        mod.COMP_UP = self.comp_up
        argv = [
            HELPER,
            self.comp,
            patch or self.patch,
            compiler_patch or self.compiler_patch,
            self.report,
        ]
        env = {"SOURCE_DATE_EPOCH": epoch, "TMPDIR": self.root}
        with (
            mock.patch.object(sys, "argv", argv),
            mock.patch.dict(os.environ, env, clear=False),
        ):
            try:
                mod.main()
            except SystemExit as e:
                if expect_ok:
                    raise AssertionError(f"helper failed: {e}")
                return e
        if not expect_ok:
            raise AssertionError("expected SystemExit")
        return None


class TestApply(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="npu-test-", dir=os.environ["TMPDIR"])
        self.fx = Fixture(self.tmp)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_fresh_apply(self):
        self.fx.detach_both()
        self.fx.run_inproc()
        rep = json.loads(Path(self.fx.report).read_text())
        self.assertTrue(rep["clean"])
        self.assertNotEqual(rep["llvm_derived"], self.fx.llvm_up)
        self.assertNotEqual(rep["compiler_derived"], self.fx.comp_up)
        self.assertEqual(
            git(["rev-parse", "HEAD"], self.fx.llvm).stdout.strip(), rep["llvm_derived"]
        )
        self.assertEqual(
            git(["rev-parse", "HEAD"], self.fx.comp).stdout.strip(),
            rep["compiler_derived"],
        )
        self.assertTrue(status_clean(self.fx.llvm))
        self.assertTrue(status_clean(self.fx.comp))
        src = os.path.join(
            self.fx.llvm, "mlir/tools/mlir-tblgen/AttrOrTypeFormatGen.cpp"
        )
        with open(src, "rb") as f:
            data = f.read()
        self.assertIn(b"// patched", data)
        comp_src = os.path.join(
            self.fx.comp,
            "src/vpux_compiler/src/dialect/VPUIP/transforms/passes/legalize_repeating_func_calls.cpp",
        )
        with open(comp_src, "rb") as f:
            comp_data = f.read()
        self.assertIn(b"// compiler patched", comp_data)

    def test_idempotent(self):
        self.fx.detach_both()
        self.fx.run_inproc()
        rep1 = json.loads(Path(self.fx.report).read_text())
        mtime1 = os.path.getmtime(
            os.path.join(self.fx.llvm, "mlir/tools/mlir-tblgen/AttrOrTypeFormatGen.cpp")
        )
        self.fx.run_inproc()
        rep2 = json.loads(Path(self.fx.report).read_text())
        mtime2 = os.path.getmtime(
            os.path.join(self.fx.llvm, "mlir/tools/mlir-tblgen/AttrOrTypeFormatGen.cpp")
        )
        self.assertEqual(rep1["llvm_derived"], rep2["llvm_derived"])
        self.assertEqual(rep1["compiler_derived"], rep2["compiler_derived"])
        self.assertEqual(mtime1, mtime2)

    def test_wrong_initial_pin(self):
        self.fx.detach_both()
        with open(os.path.join(self.fx.llvm, "extra"), "w") as f:
            f.write("x")
        git(["add", "-A"], self.fx.llvm)
        git(["commit", "-q", "-m", "extra"], self.fx.llvm)
        bad = git(["rev-parse", "HEAD"], self.fx.llvm).stdout.strip()
        self.fx.run_inproc(expect_ok=False)
        self.assertEqual(git(["rev-parse", "HEAD"], self.fx.llvm).stdout.strip(), bad)
        self.assertEqual(
            git(["rev-parse", "HEAD"], self.fx.comp).stdout.strip(), self.fx.comp_up
        )

    def test_dirty_non_target(self):
        self.fx.detach_both()
        with open(os.path.join(self.fx.llvm, "dirty"), "w") as f:
            f.write("x")
        self.fx.run_inproc(expect_ok=False)
        self.assertEqual(
            git(["rev-parse", "HEAD"], self.fx.llvm).stdout.strip(), self.fx.llvm_up
        )
        self.assertEqual(
            git(["rev-parse", "HEAD"], self.fx.comp).stdout.strip(), self.fx.comp_up
        )

    def test_wrong_patch_path(self):
        self.fx.detach_both()
        p = os.path.join(self.tmp, "wrong.patch")
        with open(p, "w") as f:
            f.write(WRONG_PATCH)
        self.fx.run_inproc(patch=p, expect_ok=False)
        self.assertEqual(
            git(["rev-parse", "HEAD"], self.fx.llvm).stdout.strip(), self.fx.llvm_up
        )
        self.assertEqual(
            git(["rev-parse", "HEAD"], self.fx.comp).stdout.strip(), self.fx.comp_up
        )

    def test_wrong_compiler_patch_path(self):
        self.fx.detach_both()
        p = os.path.join(self.tmp, "wrong_compiler.patch")
        with open(p, "w") as f:
            f.write(WRONG_COMPILER_PATCH)
        self.fx.run_inproc(compiler_patch=p, expect_ok=False)
        self.assertEqual(
            git(["rev-parse", "HEAD"], self.fx.llvm).stdout.strip(), self.fx.llvm_up
        )
        self.assertEqual(
            git(["rev-parse", "HEAD"], self.fx.comp).stdout.strip(), self.fx.comp_up
        )

    def test_changed_patch_after_derived(self):
        self.fx.detach_both()
        self.fx.run_inproc()
        rep1 = json.loads(Path(self.fx.report).read_text())
        with open(self.fx.patch, "a") as f:
            f.write("\n")
        self.fx.run_inproc(expect_ok=False)
        rep2 = json.loads(Path(self.fx.report).read_text())
        self.assertEqual(rep1["patch_sha256"], rep2["patch_sha256"])
        self.assertEqual(
            git(["rev-parse", "HEAD"], self.fx.llvm).stdout.strip(),
            rep1["llvm_derived"],
        )
        self.assertEqual(
            git(["rev-parse", "HEAD"], self.fx.comp).stdout.strip(),
            rep1["compiler_derived"],
        )

    def test_changed_compiler_patch_after_derived(self):
        self.fx.detach_both()
        self.fx.run_inproc()
        rep1 = json.loads(Path(self.fx.report).read_text())
        with open(self.fx.compiler_patch, "a") as f:
            f.write("\n")
        self.fx.run_inproc(expect_ok=False)
        rep2 = json.loads(Path(self.fx.report).read_text())
        self.assertEqual(rep1["compiler_patch_sha256"], rep2["compiler_patch_sha256"])
        self.assertEqual(
            git(["rev-parse", "HEAD"], self.fx.llvm).stdout.strip(),
            rep1["llvm_derived"],
        )
        self.assertEqual(
            git(["rev-parse", "HEAD"], self.fx.comp).stdout.strip(),
            rep1["compiler_derived"],
        )

    def test_missing_epoch(self):
        self.fx.detach_both()
        mod = load_helper()
        mod.LLVM_UP = self.fx.llvm_up
        mod.COMP_UP = self.fx.comp_up
        argv = [
            HELPER,
            self.fx.comp,
            self.fx.patch,
            self.fx.compiler_patch,
            self.fx.report,
        ]
        env = {"TMPDIR": self.tmp}
        with (
            mock.patch.object(sys, "argv", argv),
            mock.patch.dict(os.environ, env, clear=True),
            self.assertRaises(SystemExit),
        ):
            mod.main()
        self.assertEqual(
            git(["rev-parse", "HEAD"], self.fx.llvm).stdout.strip(), self.fx.llvm_up
        )
        self.assertEqual(
            git(["rev-parse", "HEAD"], self.fx.comp).stdout.strip(), self.fx.comp_up
        )

    def test_invalid_epoch(self):
        self.fx.detach_both()
        self.fx.run_inproc(epoch="abc", expect_ok=False)
        self.assertEqual(
            git(["rev-parse", "HEAD"], self.fx.llvm).stdout.strip(), self.fx.llvm_up
        )
        self.assertEqual(
            git(["rev-parse", "HEAD"], self.fx.comp).stdout.strip(), self.fx.comp_up
        )

    def test_nonpositive_epoch(self):
        self.fx.detach_both()
        self.fx.run_inproc(epoch="0", expect_ok=False)
        self.assertEqual(
            git(["rev-parse", "HEAD"], self.fx.llvm).stdout.strip(), self.fx.llvm_up
        )
        self.assertEqual(
            git(["rev-parse", "HEAD"], self.fx.comp).stdout.strip(), self.fx.comp_up
        )

    def test_missing_tmpdir(self):
        self.fx.detach_both()
        mod = load_helper()
        mod.LLVM_UP = self.fx.llvm_up
        mod.COMP_UP = self.fx.comp_up
        argv = [
            HELPER,
            self.fx.comp,
            self.fx.patch,
            self.fx.compiler_patch,
            self.fx.report,
        ]
        env = {"SOURCE_DATE_EPOCH": "1700000000"}
        with (
            mock.patch.object(sys, "argv", argv),
            mock.patch.dict(os.environ, env, clear=True),
            self.assertRaises(SystemExit),
        ):
            mod.main()
        self.assertEqual(
            git(["rev-parse", "HEAD"], self.fx.llvm).stdout.strip(), self.fx.llvm_up
        )
        self.assertEqual(
            git(["rev-parse", "HEAD"], self.fx.comp).stdout.strip(), self.fx.comp_up
        )

    def test_compiler_other_dirty(self):
        self.fx.detach_both()
        with open(os.path.join(self.fx.comp, "other"), "w") as f:
            f.write("x")
        self.fx.run_inproc(expect_ok=False)
        self.assertEqual(
            git(["rev-parse", "HEAD"], self.fx.llvm).stdout.strip(), self.fx.llvm_up
        )
        self.assertEqual(
            git(["rev-parse", "HEAD"], self.fx.comp).stdout.strip(), self.fx.comp_up
        )

    def test_dirty_compiler_target(self):
        self.fx.detach_both()
        with open(
            os.path.join(
                self.fx.comp,
                "src/vpux_compiler/src/dialect/VPUIP/transforms/passes/legalize_repeating_func_calls.cpp",
            ),
            "a",
        ) as f:
            f.write("// dirty\n")
        self.fx.run_inproc(expect_ok=False)
        self.assertEqual(
            git(["rev-parse", "HEAD"], self.fx.llvm).stdout.strip(), self.fx.llvm_up
        )
        self.assertEqual(
            git(["rev-parse", "HEAD"], self.fx.comp).stdout.strip(), self.fx.comp_up
        )

    def test_llvm_dirty_with_compiler_gitlink(self):
        self.fx.detach_both()
        with open(os.path.join(self.fx.llvm, "dirty"), "w") as f:
            f.write("x")
        with open(
            os.path.join(self.fx.comp, "thirdparty/llvm-project", "dirty2"), "w"
        ) as f:
            f.write("x")
        self.fx.run_inproc(expect_ok=False)
        self.assertEqual(
            git(["rev-parse", "HEAD"], self.fx.llvm).stdout.strip(), self.fx.llvm_up
        )
        self.assertEqual(
            git(["rev-parse", "HEAD"], self.fx.comp).stdout.strip(), self.fx.comp_up
        )

    def test_exact_interrupted_materialization_resumes(self):
        self.fx.detach_both()
        self.fx.run_inproc()
        rep = json.loads(Path(self.fx.report).read_text())
        git(["checkout", "-q", "--detach", self.fx.comp_up], self.fx.comp)
        self.fx.run_inproc()
        self.assertEqual(
            git(["rev-parse", "HEAD"], self.fx.llvm).stdout.strip(), rep["llvm_derived"]
        )
        self.assertEqual(
            git(["rev-parse", "HEAD"], self.fx.comp).stdout.strip(),
            rep["compiler_derived"],
        )
        self.assertTrue(status_clean(self.fx.llvm))
        self.assertTrue(status_clean(self.fx.comp))


def status_clean(repo):
    r = git(["status", "--porcelain"], repo)
    return r.stdout.strip() == ""


if __name__ == "__main__":
    unittest.main()
