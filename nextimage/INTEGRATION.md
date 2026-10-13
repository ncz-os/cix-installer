# rc9 integration record (2026-10-13)

Branch: `release/rc9-20261013`
Created: 2026-10-12 (orchestrator: opencode, model: MiniMax-M3)
Base: `origin/main` = `39e5a2717318e2f374633f1b5489045a539a6e20` (Preview 1 release code + 4 prep fixes)

Tip: see `git rev-parse release/rc9-20261013` at the time of next image
build. Initial integration tip: `72b8840e...` (set after the four merges
listed below are pushed; later stages will add more merges as recorded
in the file history).

## Stage 1 merges (rc9int)

Merged in the brief-mandated order with `--no-ff`, one merge commit per
branch, conflicts resolved in favour of the branch tip.

| # | Branch | Brief-listed SHA | Actual SHA used | Subject | Merge commit |
|---|---|---|---|---|---|
| 1 | `fix/components-honor-20261013` | `e150cff3` | `e150cff3d1d1e64857e10fa2a88f6ebe56678d67` | installer: honour an all-unticked component answer | `b20a7f4c` |
| 2 | `fix/cyclops-video-20261013` | `fa0d94ce` | `fa0d94ce` | amd64: read the manifest kver defensively in the KVM gate | `6ca97375` |
| 3 | `fix/saver-kickin-20261013` | `003765a1` *(stale; see note)* | `c5f96b62f1e54e8cd007ec4c2a2076d720147da6` | singularity: yield to a concurrent lock instance instead of clobbering its socket | `d7d51bd5` |
| 4 | `fix/tour-sky1-chromium-vpu-20261012` | `58ecb6a5` | `58ecb6a5` | tourvpu: assert the first-login launcher on both arches in the slide test | `72b8840e` |

### SHA discrepancy in brief

The brief listed `003765a1` for branch 3 with subject "patch 0019 two-lock
race". `003765a1` does not exist in `cix-installer` (verified on both
remotes: GitLab `ncz-os/cix-installer` and ARGONAS bare repo
`192.168.207.101:/mnt/datapool/git/cix-installer.git`). Per
`STATE.md:21:32-21:39` the actual final tip is `c5f96b62` after the
zoder review rounds on the cyclops pin + saver-kickin branches. The
file added by the merge (`assets/singularity/patches/singularity-shell/0019-lockscreen-yield-to-a-concurrent-lock-instance.patch`)
matches the patch-0019 subject in the brief.

Use `c5f96b62` (= current tip on both remotes) as the canonical sha for
this branch in any future re-integration.

### Conflict resolution

All four merges auto-merged cleanly with the `ort` strategy on the
`release/rc9-20261013` branch created off `origin/main` (`39e5a271`).
Two auto-merges:
- `docs/platform-inventory.tsv` (after merge of components-honor
  and tour-sky1-chromium-vpu)
- `build/verify-installed-target.sh` (after merge of
  cyclops-video and tour-sky1-chromium-vpu)

No manual conflict resolution was required.

## Deterministic re-integration command

Re-running these merges from scratch on a clean `release/rc9-20261013`
branch off `origin/main` reproduces the integration tip
deterministically:

```bash
# Author/email per common rules: Jason Perlow <jperlow@gmail.com>
# (do NOT add AI attribution per common rules)
git config user.name 'Jason Perlow'
git config user.email 'jperlow@gmail.com'

# 0. Fetch the four branches and origin/main from gitlab (canonical)
git fetch origin main \
  fix/components-honor-20261013 \
  fix/cyclops-video-20261013 \
  fix/saver-kickin-20261013 \
  fix/tour-sky1-chromium-vpu-20261012

# 1. Create the integration branch off origin/main
git checkout -B release/rc9-20261013 origin/main

# 2-5. Merge in the brief-mandated order with --no-ff
git merge --no-ff origin/fix/components-honor-20261013 \
  -m "rc9: merge fix/components-honor-20261013 (e150cff3: unticked installer components must be honoured)"
git merge --no-ff origin/fix/cyclops-video-20261013 \
  -m "rc9: merge fix/cyclops-video-20261013 (fa0d94ce: gate that the installer and installed kernels are the Cyclops-fixed r2 build)"
git merge --no-ff origin/fix/saver-kickin-20261013 \
  -m "rc9: merge fix/saver-kickin-20261013 (c5f96b62: yield to a concurrent lock instance instead of clobbering its socket)"
git merge --no-ff origin/fix/tour-sky1-chromium-vpu-20261012 \
  -m "rc9: merge fix/tour-sky1-chromium-vpu-20261012 (58ecb6a5: arm64-only tour slide about NCZ Chromium with VPU acceleration)"
```

The four merge subjects and the branch/SHA pairs above (and the merge
order) are stable inputs; auto-merge results will reproduce bit-identical
commit SHAs assuming the four upstream branches do not change.

## Stage 2 additions (not yet merged in this commit)

The brief warned that later stages will add more merges. Slots reserved:

| # | Branch | SHA | Subject |
|---|---|---|---|
| 5 | `fix/ncz-agents-20261013` | _TBD_ | _ncz utility + MNEMOS + agents install_ |
| 6 | `fix/t2-saver-lock-20261013` | _TBD_ | _T2 MacBook saver/lock defects_ |
| 7 | _new payload/saver pins_ | _TBD_ | _ncz-screensavers 0.8.13 pin + plugin fix_ |

These three are added by stage 2 sessions (`nczutil`, `t2saver`, and the
payload-pin pass). They land on top of the tip recorded above without
rewriting any rc9int history (no force-push, no rebase).

## Verification re-run

After any push of `release/rc9-20261013`, verify the four merge commits
are present and match the SHAs in this file:

```bash
git rev-parse release/rc9-20261013                  # integration tip
git log --merges --first-parent release/rc9-20261013 -n 4 --oneline
# expect b20a7f4c, 6ca97375, d7d51bd5, 72b8840e
```

## Pinned sources (origin/main contents at 39e5a271)

| Component | Pinned value |
|---|---|
| Kernel (amd64 / Sky1) | cycle-current (cyclops r2 / sky1 r287) -- re-pinned by saver-kickin branch |
| Singularity payload | pinned by saver-kickin branch's RC6 merges (`7112a12a`) |
| Screensavers | 0.8.12 (floor reset in saver-kickin branch via `d129e801`) |
| Tour browser | arm64 NCZ Chromium with VPU acceleration (this branch adds the slide) |
| Installer component selector | rejects "all unticked" as nothing (this branch adds it) |
