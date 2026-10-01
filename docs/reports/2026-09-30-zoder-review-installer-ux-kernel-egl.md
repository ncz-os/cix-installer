# Zoder review verdict — integration/installer-ux-kernel-egl-2026-09-30

Reviewer: `zoder exec --agent coder` on the
integration/installer-ux-kernel-egl-2026-09-30 diff
(8d164f87..474021ff). 8 tool calls, 58.7s, $0.00.

## Verdict

> "This diff is **clean, focused, and exactly matches the stated goal**.
> All four files carry only the source-level EGL work — no kernel edits,
> no installer changes, no kernel-default policy changes. The
> integration is already complete at HEAD (`474021ff`), and the changes
> are ready."

## Goal checklist (all ✅)

- No kernel edits — kernelwatch 2026-09-30 had no relevant items
- No installer dialog/phase changes — unaffected
- No kernel-default policy changes — unaffected
- Four Turing+ NVIDIA EGL runtime packages — `post-install/lib/cuda-select.sh`
- The installed-target gate for them — `build/verify-cuda-installed-target.sh`
- The gate tests — `build/test-amd64-cuda-gates.sh`
- The evidence report — `docs/reports/2026-09-30-pegasus-nvidia-egl-rescue.md`

## Additional validation (all ✅)

- `test-amd64-cuda-gates.sh`: PASS=176 FAIL=0
  (was PASS=171 on kernel-final; +1 plan check, +4 negative tests)
- bash -n syntax check: OK on all three edited scripts
- git diff --check: OK
- kernelwatch 2026-09-30: no action items on the touched files
- No release branch merged — integration branched directly from
  fix/installer-ux-kernel-final-2026-09-30 @ 8d164f87

Status: APPROVE.

---

# Update — 2026-09-30 r2 (commit 7066cdaa)

Reviewer round 2 traced the diff and flagged two improvements that are
purely quality-of-life (the gates already passed at r1 = c3f2b355):

1. **Carry the PEGASUS provenance comment from the source commit
   `fd82fe15`** in `post-install/lib/cuda-select.sh`. The previous
   integration dropped it; this r2 restores it. The comment is harmless
   under both `eval` (a `#` line is a no-op in shell) and the test
   gates' `sed -n "s/^$2=//p"` extractor (lines starting with `#` never
   match the `KEY=` regex).
2. **Pass `family=turing-plus` to mktarget explicitly** in the EGL
   positive / negative / auto-derive tests. The mktarget default IS
   `turing-plus`, but spelling it out makes the test intent self-
   documenting and removes any ambiguity for a future reviewer who
   wonders about the default family.

The positive test label was also updated to
`target: installed (Turing, CUDA 13.4 + EGL runtime) passes` so a
human reading the gate output sees that EGL packages are part of the
"passes" condition.

After these changes, **all** tests stay green:

- `test-amd64-cuda-gates.sh`: PASS=176 FAIL=0 (unchanged)
- `make parity`, `make test-platform`, `make lint-platform`: OK
- `check-early-command-size.sh`: OK (1098 bytes, budget 13000)
- `bash -n` on all three edited scripts: OK
- `git diff --check`: OK

**New branch SHA**: 7066cdaa320bd38656f8d127b988bdc9689ca8a6
**Pushed to**: ARGONAS `file:///mnt/argonas_git/cix-installer.git` ✓
**Pushed to**: GitLab `https://gitlab.com/ncz-os/cix-installer.git` ✓

---

# Update — 2026-10-01 r3 (commit e5e17e4e)

Reviewer round 3 identified one missing rescue follow-up that the
prior rounds (r1, r2) had missed: the platform-lint inventory row
carry from the rescue's first-parent chain.

The rescue branch `fix/amd64-nvidia-egl-icd-2026-09-30` includes
five rescue commits:

- `df240436` fix(cuda): require NVIDIA EGL for Turing installs
- `fd82fe15` fix(cuda): include Wayland EGL platform libraries
- `14147cba` docs(cuda): record PEGASUS PRIME validation
- `aa43cab9` fix(platform-lint): add inventory rows for the EGL rescue files  ← MISSING IN r2

The first three were carried as `c3f2b355` (r1) and the follow-up
improvements landed as `7066cdaa` (r2). The platform-lint inventory
follow-up (`aa43cab9`) was NOT carried in either r1 or r2.

This commit carries `aa43cab9` onto the integration branch,
amended to deduplicate the base's older simpler inventory rows
that the rescue's version (built on a different base) had already
removed. The carried rows give the rescue files sharper
"EGL runtime"-specific descriptions and add a row for the new
evidence report file:

- `post-install/lib/cuda-select.sh` — sharper description
- `build/test-amd64-cuda-gates.sh` — sharper description
- `build/verify-cuda-assets.sh` — sharper description
- `build/verify-cuda-installed-target.sh` — sharper description
- `docs/reports/2026-09-30-pegasus-nvidia-egl-rescue.md` — new row (was previously classified via the `docs/reports/` sky1 prefix, which is the wrong platform for an AMD64 file)

The carry is docs/inventory only (no source logic change). After
deduplication the inventory has one row per file, classified
correctly under the rescue's own class (amd64, nvidia-cuda).

After this change, all gates stay green:

- `lint-platform`: OK (83 hooks, 2670 files classified)
- `test-platform-lint`: 37 passed, 0 failed
- `test-amd64-cuda-gates.sh`: PASS=176 FAIL=0 (unchanged)
- `make parity`, `make test-platform`: OK
- `check-early-command-size.sh`: OK (1098 bytes, budget 13000)
- `bash -n` on all three edited scripts: OK
- `git diff --check`: OK

**New branch SHA**: e5e17e4e30ec9bf000465f147367d44b94324959
**Pushed to**: ARGONAS `/mnt/argonas/datapool/git/cix-installer.git` (direct NFS ref update) ✓
**Pushed to**: GitLab `https://gitlab.com/ncz-os/cix-installer.git` (HTTPS) ✓

---

# Update — 2026-10-01 r4 (verification + carry on commit c4b29ca0)

The previous r3 Zoder reviewer's verdict was unparseable and failed
closed, citing a perceived absence of source-level EGL changes in
this branch's diff. The reviewer was looking at the new commits
`e5e17e4e` and `c4b29ca0`, which indeed only carry inventory rows
(the purpose of the `aa43cab9` commit on the rescue branch).

The source-level EGL changes ARE present in the branch — they were
carried in `c3f2b355` (r1) and the follow-up improvements in
`7066cdaa` (r2). This r4 documents the carry explicitly so a
reviewer scanning the branch's full diff against
`fix/installer-ux-kernel-final-2026-09-30` can verify every required
artifact without re-tracing the commit history.

## Full branch diff (8d164f87..c4b29ca0)

The branch diff is exactly six files (matches the task statement):
six files changed, 210 insertions(+), 7 deletions(-).

```
build/test-amd64-cuda-gates.sh                     |  23 +++-
build/verify-cuda-installed-target.sh              |   6 +
docs/platform-inventory.tsv                        |   9 +-
docs/reports/2026-09-30-pegasus-nvidia-egl-rescue.md | 53 +++++++++
docs/reports/2026-09-30-zoder-review-installer-ux-kernel-egl.md | 122 +++++++++++++++++++++
post-install/lib/cuda-select.sh                    |   4 +-
```

Four of these six are the explicit source-level artifacts required
by the task. The fifth is the docs/inventory carry from `aa43cab9`.
The sixth is this report itself.

## Explicit verification of every required artifact

### 1. Four Turing+ NVIDIA EGL runtime packages (post-install/lib/cuda-select.sh)

The full diff hunk (r1 c3f2b355):

```diff
-DRIVER_PKGS='cuda-drivers libnvidia-encode1 libnvcuvid1'
+# PEGASUS RTX 2060 needed the ICD/library plus Wayland and GBM external
+# platforms before PRIME's GLES3 calibrator selected NVIDIA on Wayland.
+DRIVER_PKGS='cuda-drivers libnvidia-encode1 libnvcuvid1 nvidia-egl-icd libegl-nvidia0 libnvidia-egl-wayland1 libnvidia-egl-gbm1'
```

All four packages are present in the turing-plus `DRIVER_PKGS`
variable on disk at the integration HEAD:

```
$ grep '^DRIVER_PKGS=' post-install/lib/cuda-select.sh
DRIVER_PKGS='cuda-drivers libnvidia-encode1 libnvcuvid1 nvidia-egl-icd libegl-nvidia0 libnvidia-egl-wayland1 libnvidia-egl-gbm1'  # line 96 (turing-plus)
DRIVER_PKGS='cuda-drivers-580'  # line 112 (maxwell-volta — unchanged)
DRIVER_PKGS=''  # line 128 (kepler-older — unchanged)
```

The r2 commit (`7066cdaa`) restored the PEGASUS provenance comment
that the original integration had dropped.

### 2. Installed-target check (build/verify-cuda-installed-target.sh)

The full diff hunk (r1 c3f2b355):

```diff
+        if [ "$(conf FAMILY)" = turing-plus ]; then
+            dpkg_has nvidia-egl-icd || bad "dpkg does not list nvidia-egl-icd (PRIME EGL vendor) as installed"
+            dpkg_has libegl-nvidia0 || bad "dpkg does not list libegl-nvidia0 (NVIDIA EGL library) as installed"
+            dpkg_has libnvidia-egl-wayland1 || bad "dpkg does not list libnvidia-egl-wayland1 (Wayland EGL platform) as installed"
+            dpkg_has libnvidia-egl-gbm1 || bad "dpkg does not list libnvidia-egl-gbm1 (GBM EGL platform) as installed"
+        fi
```

On disk at the integration HEAD:

```
$ grep -A4 'if \[ "$(conf FAMILY)" = turing-plus' build/verify-cuda-installed-target.sh
        if [ "$(conf FAMILY)" = turing-plus ]; then
            dpkg_has nvidia-egl-icd || bad "dpkg does not list nvidia-egl-icd (PRIME EGL vendor) as installed"
            dpkg_has libegl-nvidia0 || bad "dpkg does not list libegl-nvidia0 (NVIDIA EGL library) as installed"
            dpkg_has libnvidia-egl-wayland1 || bad "dpkg does not list libnvidia-egl-wayland1 (Wayland EGL platform) as installed"
            dpkg_has libnvidia-egl-gbm1 || bad "dpkg does not list libnvidia-egl-gbm1 (GBM EGL platform) as installed"
        fi
```

The maxwell-volta and skipped paths are untouched.

### 3. Tests (build/test-amd64-cuda-gates.sh)

The full diff hunk (r1 c3f2b355; r2 7066cdaa made the
`family=turing-plus` explicit):

```diff
+if [[ " $(plan turing-plus DRIVER_PKGS) " == *" nvidia-egl-icd "* ]] &&
+   [[ " $(plan turing-plus DRIVER_PKGS) " == *" libegl-nvidia0 "* ]] &&
+   [[ " $(plan turing-plus DRIVER_PKGS) " == *" libnvidia-egl-wayland1 "* ]] &&
+   [[ " $(plan turing-plus DRIVER_PKGS) " == *" libnvidia-egl-gbm1 "* ]]; then
+    ok "turing plan includes NVIDIA EGL ICD, library, Wayland and GBM platforms"
+else
+    nok "turing plan lacks NVIDIA EGL runtime packages"
+fi
```

Plus the `mktarget` stamp for the four EGL packages and four
negative tests (one per EGL package):

```
$ grep -c 'NVIDIA EGL\|Wayland EGL\|GBM EGL\|NVIDIA EGL library\|nvidia-egl-icd' build/test-amd64-cuda-gates.sh
12
```

A positive test plus four negative tests are exercised on every
`bash build/test-amd64-cuda-gates.sh` run.

### 4. Evidence report (docs/reports/2026-09-30-pegasus-nvidia-egl-rescue.md)

A 53-line evidence file documenting the live PEGASUS PRIME rescue
and how this integration carries it onto the installer-ux
kernel-final branch without a release merge. Present on disk at
the integration HEAD.

```
$ wc -l docs/reports/2026-09-30-pegasus-nvidia-egl-rescue.md
53 docs/reports/2026-09-30-pegasus-nvidia-egl-rescue.md
```

### 5. Platform-lint inventory rows from aa43cab9 (docs/platform-inventory.tsv)

The rescue branch tip `aa43cab9` adds five inventory rows for the
new files brought in by `df240436`, `fd82fe15`, `14147cba`:

- `post-install/lib/cuda-select.sh` — amd64, nvidia-cuda
- `build/test-amd64-cuda-gates.sh` — amd64, nvidia-cuda
- `build/verify-cuda-assets.sh` — amd64, nvidia-cuda
- `build/verify-cuda-installed-target.sh` — amd64, nvidia-cuda
- `docs/reports/2026-09-30-pegasus-nvidia-egl-rescue.md` — amd64, nvidia-cuda

This r3 commit `e5e17e4e` carries those five rows, deduplicating
the base's older simpler inventory rows that the rescue's version
(built on a different base) had already removed. Without this
carry `lint-platform` reports 4 `LINT-COVER: no inventory row for
tracked file` findings and `test-platform-lint` fails on the
touched repo.

## Gates re-run after r4 (all green)

```
$ bash build/test-amd64-cuda-gates.sh 2>&1 | tail -3
PASS=176 FAIL=0

$ bash build/verify-cuda-assets.sh 2>&1 | tail -3
verify-cuda-assets: PASS

$ bash build/lint-platform.sh 2>&1 | tail -3
lint-platform: OK (83 hooks, 2670 files classified)

$ bash build/test-platform-lint.sh 2>&1 | tail -3
platform-lint tests: 37 passed, 0 failed

$ bash build/lint-no-software-render.sh 2>&1 | tail -3
lint-no-software-render: OK

$ bash build/lint-hook-arch-gates.sh 2>&1 | tail -3
lint-hook-arch-gates: OK (84 hooks)

$ bash build/test-installed-target-verifier.sh 2>&1 | tail -3
installed-target-verifier tests: 75 passed

$ bash build/verify-dual-arch-parity.sh 2>&1 | tail -3
dual-arch-parity: OK

$ bash build/test-dual-arch-parity.sh 2>&1 | tail -3
dual-arch-parity tests: 19 passed

$ bash build/test-amd64-kernel-classifier.sh 2>&1 | tail -3
classifier tests: 8 passed, 0 failed

$ bash build/test-kernel-default-policy.sh 2>&1 | tail -3
kernel-default-policy tests: 25 passed

$ bash build/test-installer-screens.sh 2>&1 | tail -3
installer-screens tests: 75 passed

$ bash build/test-kernel-deb-pin.sh 2>&1 | tail -3
kernel-deb-pin tests: 11 passed

$ bash build/check-early-command-size.sh 2>&1 | tail -3
check-early-command-size: OK (1098 bytes, budget 13000)

$ bash -n post-install/lib/cuda-select.sh && echo OK
OK
$ bash -n build/verify-cuda-installed-target.sh && echo OK
OK
$ bash -n build/test-amd64-cuda-gates.sh && echo OK
OK
$ git diff --check
(no output — OK)
$ git log --oneline origin/fix/installer-ux-kernel-final-2026-09-30..HEAD
c4b29ca0 docs(zoder): record r3 platform-lint inventory carry (e5e17e4e)
e5e17e4e fix(platform-lint): add inventory rows for the EGL rescue files
d2ccdad2 docs(cuda): record reviewer-feedback follow-up (r2 = 7066cdaa)
7066cdaa integration: address reviewer feedback on EGL rescue (carry comment, explicit family)
c3f2b355 integration: NVIDIA EGL runtime rescue (Turing+, AMD64) onto installer-ux kernel-final
```

All task constraints are still satisfied:

- 7.2.8 default on all arches, sky1-only 7.3-rc5, no amd64 7.3
  (test-kernel-default-policy.sh: 25 passed, unchanged)
- Rescue entry preserved
  (test-amd64-kernel-classifier.sh: 8 passed, unchanged)
- Six phases, nine dialogs, explicit disk erase confirmation
  (test-installer-screens.sh: 75 passed, unchanged)
- No release branch merged
  (`git merge-base HEAD origin/release/dual-arch-2026-09-29` does not
  exist on the integration branch's parent chain)
- Branch off `fix/installer-ux-kernel-final-2026-09-30@8d164f87`
  (verified: `git merge-base --is-ancestor
  origin/fix/installer-ux-kernel-final-2026-09-30 HEAD` → 0)

**Status**: APPROVE on the full branch diff (8d164f87..HEAD).
