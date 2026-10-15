#!/usr/bin/env python3
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile

LLVM_PATH = "thirdparty/llvm-project"
TARGET = "mlir/tools/mlir-tblgen/AttrOrTypeFormatGen.cpp"
COMPILER_TARGET = "src/vpux_compiler/src/dialect/VPUIP/transforms/passes/legalize_repeating_func_calls.cpp"
LLVM_UP = "8f3977c01be0f24be98b67ef2c911fd82657f30c"
COMP_UP = "0b38f7d42113ff329ac2bdd33583d123de4ccf2f"
AUTHOR_NAME = "Jason Perlow"
AUTHOR_EMAIL = "jperlow@gmail.com"


def run(cmd, cwd=None, env=None, check=True):
    r = subprocess.run(
        cmd, cwd=cwd, env=env, capture_output=True, text=True, check=False
    )
    if check and r.returncode != 0:
        raise SystemExit(f"cmd failed: {cmd}\n{r.stdout}\n{r.stderr}")
    return r


def git(args, cwd, env=None, check=True):
    return run(["git"] + args, cwd=cwd, env=env, check=check)


def status_clean(repo):
    r = git(["status", "--porcelain"], repo)
    return r.stdout.strip() == ""


def status_lines(repo):
    return [l for l in git(["status", "--porcelain"], repo).stdout.splitlines() if l]


def patch_sha(patch_file):
    h = hashlib.sha256()
    with open(patch_file, "rb") as f:
        h.update(f.read())
    return h.hexdigest()


def check_patch_paths(patch_file, expected_target):
    r = run(["git", "apply", "--numstat", patch_file], check=False)
    if r.returncode != 0:
        raise SystemExit("patch numstat failed: " + r.stderr)
    paths = []
    for line in r.stdout.splitlines():
        parts = line.split("\t")
        if len(parts) >= 3:
            paths.append(parts[2])
    if paths != [expected_target]:
        raise SystemExit(f"patch paths not exactly {expected_target}: {paths!r}")


def commit_env(epoch):
    e = os.environ.copy()
    e["GIT_AUTHOR_NAME"] = AUTHOR_NAME
    e["GIT_AUTHOR_EMAIL"] = AUTHOR_EMAIL
    e["GIT_COMMITTER_NAME"] = AUTHOR_NAME
    e["GIT_COMMITTER_EMAIL"] = AUTHOR_EMAIL
    e["GIT_AUTHOR_DATE"] = f"@{epoch} +0000"
    e["GIT_COMMITTER_DATE"] = f"@{epoch} +0000"
    return e


def derive_llvm_commit(llvm_repo, patch_file, epoch, tmpdir):
    idx = os.path.join(tmpdir, "llvm.idx")
    if os.path.exists(idx):
        os.remove(idx)
    env = os.environ.copy()
    env["GIT_INDEX_FILE"] = idx
    git(["read-tree", LLVM_UP], llvm_repo, env=env)
    git(["apply", "--cached", "--check", patch_file], llvm_repo, env=env)
    git(["apply", "--cached", patch_file], llvm_repo, env=env)
    tree = git(["write-tree"], llvm_repo, env=env).stdout.strip()
    msg = f"npu_compiler: apply canonical patch {patch_sha(patch_file)}"
    cenv = commit_env(epoch)
    cenv["GIT_INDEX_FILE"] = idx
    commit = git(
        ["commit-tree", tree, "-p", LLVM_UP, "-m", msg], llvm_repo, env=cenv
    ).stdout.strip()
    os.remove(idx)
    return commit


def derive_compiler_commit(comp_repo, llvm_commit, compiler_patch_file, epoch, tmpdir):
    idx = os.path.join(tmpdir, "comp.idx")
    if os.path.exists(idx):
        os.remove(idx)
    env = os.environ.copy()
    env["GIT_INDEX_FILE"] = idx
    git(["read-tree", COMP_UP], comp_repo, env=env)
    git(
        [
            "update-index",
            "--add",
            "--cacheinfo",
            f"160000,{llvm_commit},{LLVM_PATH}",
        ],
        comp_repo,
        env=env,
    )
    git(["apply", "--cached", "--check", compiler_patch_file], comp_repo, env=env)
    git(["apply", "--cached", compiler_patch_file], comp_repo, env=env)
    tree = git(["write-tree"], comp_repo, env=env).stdout.strip()
    msg = (
        f"npu_compiler: materialize llvm {llvm_commit} "
        f"compiler_patch {patch_sha(compiler_patch_file)}"
    )
    cenv = commit_env(epoch)
    cenv["GIT_INDEX_FILE"] = idx
    commit = git(
        ["commit-tree", tree, "-p", COMP_UP, "-m", msg], comp_repo, env=cenv
    ).stdout.strip()
    os.remove(idx)
    return commit


def head_of(repo):
    return git(["rev-parse", "HEAD"], repo).stdout.strip()


def is_detached(repo):
    r = git(["symbolic-ref", "-q", "HEAD"], repo, check=False)
    return r.returncode != 0


def assert_detached(repo):
    if not is_detached(repo):
        raise SystemExit(f"HEAD not detached in {repo}")


def checkout_detached(repo, commit):
    git(["checkout", "--quiet", "--detach", commit], repo)


def main():
    if len(sys.argv) != 5:
        raise SystemExit(
            "usage: APPLY-NPU-LLVM-PATCH.py COMPILER_SOURCE LLVM_PATCH COMPILER_PATCH REPORT_JSON"
        )
    comp_repo, patch_file, compiler_patch_file, report_path = (
        sys.argv[1],
        sys.argv[2],
        sys.argv[3],
        sys.argv[4],
    )

    epoch_s = os.environ.get("SOURCE_DATE_EPOCH")
    if not epoch_s or not re.match(r"^[0-9]+$", epoch_s):
        raise SystemExit("SOURCE_DATE_EPOCH required (integer)")
    epoch = int(epoch_s)
    if epoch <= 0:
        raise SystemExit("SOURCE_DATE_EPOCH must be positive")

    tmpbase = os.environ.get("TMPDIR")
    if not tmpbase or not os.path.isdir(tmpbase):
        raise SystemExit("TMPDIR must be set to an existing directory")

    llvm_repo = os.path.join(comp_repo, LLVM_PATH)
    if not os.path.isdir(llvm_repo):
        raise SystemExit(f"missing llvm submodule at {llvm_repo}")
    if not os.path.isfile(patch_file):
        raise SystemExit("missing patch file")
    if not os.path.isfile(compiler_patch_file):
        raise SystemExit("missing compiler patch file")
    check_patch_paths(patch_file, TARGET)
    check_patch_paths(compiler_patch_file, COMPILER_TARGET)
    psha = patch_sha(patch_file)
    cpsha = patch_sha(compiler_patch_file)

    tmpdir = tempfile.mkdtemp(prefix="npu-patch-", dir=tmpbase)
    try:
        llvm_derived = derive_llvm_commit(llvm_repo, patch_file, epoch, tmpdir)
        comp_derived = derive_compiler_commit(
            comp_repo, llvm_derived, compiler_patch_file, epoch, tmpdir
        )

        llvm_head = head_of(llvm_repo)
        comp_head = head_of(comp_repo)
        llvm_lines = status_lines(llvm_repo)
        comp_lines = status_lines(comp_repo)

        if llvm_head == LLVM_UP:
            if llvm_lines:
                raise SystemExit(f"llvm repo dirty before apply: {llvm_lines!r}")
            llvm_state = "base"
        elif llvm_head == llvm_derived:
            if llvm_lines:
                raise SystemExit(f"llvm repo dirty at derived state: {llvm_lines!r}")
            llvm_state = "derived"
        else:
            raise SystemExit(f"llvm HEAD {llvm_head} not base or derived")

        if comp_head == COMP_UP:
            allowed = [" M " + LLVM_PATH]
            if comp_lines and comp_lines != allowed:
                raise SystemExit(f"compiler repo unexpected dirty: {comp_lines!r}")
            comp_state = "base"
        elif comp_head == comp_derived:
            if comp_lines:
                raise SystemExit(
                    f"compiler repo dirty at derived state: {comp_lines!r}"
                )
            comp_state = "derived"
        else:
            raise SystemExit(f"compiler HEAD {comp_head} not base or derived")

        if llvm_state == "base" and comp_state == "derived":
            raise SystemExit("invalid initial pair: llvm base with compiler derived")

        assert_detached(llvm_repo)
        assert_detached(comp_repo)

        if llvm_state == "base":
            checkout_detached(llvm_repo, llvm_derived)
            if not status_clean(llvm_repo):
                raise SystemExit("llvm repo dirty after apply")
        else:
            if not status_clean(llvm_repo):
                raise SystemExit("llvm repo dirty at derived state")

        if comp_state == "base":
            checkout_detached(comp_repo, comp_derived)
            if not status_clean(comp_repo):
                raise SystemExit("compiler repo dirty after apply")
        else:
            if not status_clean(comp_repo):
                raise SystemExit("compiler repo dirty at derived state")

        src_file = os.path.join(llvm_repo, TARGET)
        with open(src_file, "rb") as f:
            src_sha = hashlib.sha256(f.read()).hexdigest()
        comp_src_file = os.path.join(comp_repo, COMPILER_TARGET)
        with open(comp_src_file, "rb") as f:
            comp_src_sha = hashlib.sha256(f.read()).hexdigest()

        report = {
            "llvm_upstream": LLVM_UP,
            "llvm_derived": llvm_derived,
            "compiler_upstream": COMP_UP,
            "compiler_derived": comp_derived,
            "patch_sha256": psha,
            "compiler_patch_sha256": cpsha,
            "source_file_sha256": src_sha,
            "compiler_source_file_sha256": comp_src_sha,
            "clean": True,
            "compiler_status": status_lines(comp_repo),
        }
        tmp_report = report_path + ".tmp"
        with open(tmp_report, "w") as f:
            json.dump(report, f, indent=2, sort_keys=True)
        os.replace(tmp_report, report_path)
    finally:
        for name in os.listdir(tmpdir):
            try:
                os.remove(os.path.join(tmpdir, name))
            except OSError:
                pass
        try:
            os.rmdir(tmpdir)
        except OSError:
            pass


if __name__ == "__main__":
    main()
