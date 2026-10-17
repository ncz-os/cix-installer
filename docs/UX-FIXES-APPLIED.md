# UX Minor-Issues Inventory — EASY fixes applied

Companion to the read-only inventory in `docs/UX-MINOR-ISSUES.md`.
Scope: EASY rows only, grouped into focused commits. MEDIUM and LARGE rows
were NOT touched.

## Commits

| commit | group | findings |
|--------|-------|----------|
| a5a21677 | A1 — functional installer UI | S1-4, S1-5, S1-6 |
| 0a7a92a4 | A2 — installer dialog clarity | S2-1, S2-2, S2-4 |
| 432f93e6 | B1 — dead 26.7 art tooling | S3-3, S3-4 |
| 0786dfa1 | B2 — branding cosmetics | S3-1, S3-2, S3-5 |
| 8bdedab3 | B3 — stale 26.7/Maximilian claims | S7-1 … S7-10 |
| 5d24288a | C — hook orchestration comments | S4-1, S4-2, S4-3, S4-5 |
| 6f5e864a | D — first-boot cosmetics | S5-1 … S5-5 |

## What changed, per finding

### Group A — installer dialogs

- **S1-4** (preseed/component-selector.sh:229-231) — `Choices:` / `Choices-C:`
  were swapped: the newt frontend showed raw tokens (`desktop`,
  `mgmt-container`) instead of the human descriptions. Swapped back to
  `Choices: ${_OFFERED}` (tokens) and `Choices-C: ${_CHOICES_C}`
  (descriptions), as the comment above the template already documented.
  `build/test-component-selection.sh` asserted the old swapped template;
  it now asserts the corrected one (tokens in `Choices:`, the three
  descriptions in `Choices-C:`).
- **S1-5** (preseed/component-selector.sh:136) — the `ncz_components=`
  cmdline override accepted `browsers`/`wallpaper-rotator` without
  `desktop`, silently installing browsers on a console-only system.
  Those two tokens are now dropped (with a logged warning) when the
  override has no `desktop`; with `desktop` they keep their legacy
  ride-along behaviour. Interactive answers are unaffected (the tokens
  are not offered in the dialog).
- **S1-6** (preseed/ncz-ui.sh:57) — every arm64 board displayed as
  `arm64 (Sky1)`. The label now probes `/proc/cpuinfo` and the device-tree
  `compatible` strings (the same `sky1|cp8180|cix` check 50-brand.sh's
  `ncz-hw-brand` uses) and appends `(Sky1)` only on a match; other arm64
  boards show plain `arm64`. Added an `NCZ_UI_SKY1` test seam so
  `build/test-ncz-ui.sh` asserts the Sky1-suffixed label deterministically
  regardless of the host (the plain-label path is covered by the amd64
  assertion and by any non-Sky1 arm64 host).

### Group B — installer dialog clarity

- **S2-1** (preseed/disk-fs-chooser.sh:289) — added `Choices-C:` with the
  short descriptions from the template body, so the newt select no longer
  shows raw `btrfs` / `ext4`.
- **S2-2** (preseed/disk-fs-chooser.sh:334) — the erase-confirmation
  dialog rendered the raw comma-separated component tokens. It now maps
  them to display names (Full Singularity desktop / management container /
  rescue partition / NVIDIA driver + CUDA; desktop covers its
  browsers/wallpaper-rotator companions). An empty record reads "no
  optional components"; the old `${_ncz_sel:-all}` fall-through was dead
  (a missing record — the "everything" case — cannot reach this screen).
- **S2-4** (preseed/hostname-suggest.sh:86-87) — reworded to "This name
  is tied to the machine, not to any network adapter."

### Group C — identity / branding

- **S3-3 / S3-4** — deleted `build/gen-maximilian-art.py` and
  `assets/dev/gen-maximilian-art.py` (26.7 Maximilian art generators;
  26.10 uses `branding/cygnus/tools/make-cygnus-art.py`). Verified no
  functional references before deleting; removed the inventory line from
  `docs/platform-inventory.tsv`. The 26.7-era mention in
  `docs/releases/26.10-cygnus.md` is history prose and stays.
- **S3-1** (post-install/50-brand.sh:95) — documented the `LOGO=`
  contract: `55-greeter.sh` installs the approved mark at exactly the
  path os-release's `LOGO=ncz-os-<codename>` resolves to (with a legacy
  `ncz.png` alias), so the key is not a dangling reference. Noting the
  precondition: a future codename without a shipped logo breaks the
  contract.
- **S3-2** (branding/cygnus/tools/make-cygnus-art.py:232) — "the 26.7
  banner" → "the old 26.7 banner".
- **S3-5** (post-install/50-brand.sh:7) — reworded the retired-scheme
  comment without naming the old per-variant codenames.

### Group D — hook orchestration

- **S4-2 / S4-3** (post-install/run-all.sh:367) — added in-line rationale
  for the unexplained `_SKIP_DESKTOP_RE` entries: 84-vpu-mpv/84-vpu-vaapi
  (video playback is a desktop workload) and 85-power-perf-mode (desktop
  power/perf tuning; the one hardware-flavoured name in the list).
- **S4-1 / S4-5** (post-install/run-all.sh:635-642) — the Phase 0 comment
  cited `09-diag-account.sh` as if it were on disk; it was retired after
  the r75/r76 shakedown (now `assets/dev/09-diag-account.sh.disabled`).
  Rewrote the comment to describe the set dynamically (05-time-sync.sh is
  today's only member; the `ls 0[0-9]-*.sh` glob auto-includes newly
  staged affordances) and dropped the retired "magnetar" account name
  from the live prose, keeping the historical 2026-05-07 bug note.

### Group E — first boot

- **S5-1** (post-install/55-greeter.sh:2) — header "26.7 SHIP greeter" →
  "26.10".
- **S5-2** (post-install/55-greeter.sh:165) — the `ncz-has-drm-output`
  wait now documents its bounds in-line (120 × 0.25 s = 30 s total; arm64
  LIT grace 32 × 0.25 s = 8 s), so the 8 s fail-open log is readable in
  context.
- **S5-3** (post-install/55-greeter.sh:42) — `WALL_SRC` → `BACKDROP_SRC`
  (it is a dedicated greeter backdrop, not a desktop wallpaper, per the
  adjacent comment).
- **S5-4** (post-install/51-ncz-tour-slides.sh:9) — the untracked "phase
  C" TODO now points at `docs/PLATFORM-SPLIT-DESIGN.md`, where phase C is
  specified.
- **S5-5** (post-install/63-ncz-idle-lock-order.sh:127) — the condition
  was already correct (recompile only in production; tests dry-run a
  scratch copy); added the missing comment stating exactly that.

## Stale-naming sweep (S7-1 … S7-11)

Headers that claimed to BE 26.7 Maximilian when the code is 26.10 Cygnus
were corrected: `manifests/desktop.pkgs`, `build/build-singularity.sh`,
`build/build-squashfs-layers.sh:608`, `preseed/ncz-ui.sh:4` (S7-3, same
line as S1-2). Retired-codename mentions in live comments were reworded:
`post-install/48-server-variant.sh` (S7-5, same as S3-5's file pair),
`post-install/59-desktop-curate.sh:89`, `post-install/61-chromium-icon.sh:6`
(kept "old 26.7 orange palette" as era label, dropped the name),
`post-install/20-desktop.sh:1034` ("not the old red accent").

Deliberately NOT changed:
- **S7-8** (build/test-ncz-ui.sh:6) — the inventory called it "acceptable
  as history prose"; I reworded it minimally to "through the 26.7 release
  this asserted the then-current identity" because it names a specific
  string a fixture used to pin, which reads as a claim about the current
  fixture. No behavioural change.
- **S7-11** (build/test-release-identity.sh:9,21) — left as-is per the
  inventory ("acceptable; no fix needed"); it documents why the guard
  exists, and the test actively checks that no live file names the old
  codename.

## Deliberately NOT done (and why)

- **All MEDIUM/LARGE rows** — out of scope per the task: S1-1, S1-3,
  S2-3, S2-5, S3-6, S4-4.
- **S3-1 logo file** — did not add `assets/branding/greeter/cygnus/
  ncz-os-cygnus.png`: the working logo asset is
  `ncz-os-cygnus-logo.png` (sha256-pinned by test-release-identity.sh)
  and 55-greeter.sh installs it under `LOGO_NAME.png`, so creating a
  near-duplicate asset would just add a third copy of the same mark.
  Documented the contract instead.
- **S5-2 log-line format** — did not alter the 8 s log message text or add
  a per-loop log line; the bounds are now documented in the script
  header, which is what the finding asks ("add a log line … documenting
  the total timeout (30 s) and the grace window (8 s)") without adding
  per-boot noise.
- **docs/releases/26.10-cygnus.md:72** still mentions
  `build/gen-maximilian-art.py` — release-history prose, intentionally
  left (it documents what the 26.7 art was, not how to build it).

## Verification

- `bash -n` on every touched shell file (preseed/*.sh: also `sh -n`,
  POSIX-safe; post-install and build scripts are bash with pre-existing
  bash-isms, verified identical before/after).
- `python3 -m py_compile branding/cygnus/tools/make-cygnus-art.py`.
- `build/lint-platform.sh` — OK (88 hooks, 3254 files classified),
  after the art-generator deletion + inventory update.
- UI / installer tests, all green:
  - build/test-ncz-ui.sh — 32/32 (bash, sh, dash, busybox ash)
  - build/test-component-selection.sh — 50/50 (sh + busybox sh)
  - build/test-installer-screens.sh — 112/112
  - build/test-installer-flow.sh — 65/65
  - build/test-release-identity.sh — 39/39
  - build/test-idle-lock-order.sh — 13/13
  - build/test-greeter-display-detect.sh — 8/8
  - build/test-greeter-output-mode.sh — 30/30
- No functional references to the deleted art generators remain (repo-wide
  grep; only the release-history doc and the read-only inventory).
