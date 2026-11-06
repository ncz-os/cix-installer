# NCZ UX Minor Issues — Read-Only Inventory

Incremental audit. Append one section per scope as it completes.

| id | severity | file:line | what | why it matters | suggested fix | effort |
|----|----------|-----------|------|----------------|---------------|--------|

## S1 — installer dialogs (ncz-ui.sh, component-selector.sh)

| id | severity | file:line | what | why it matters | suggested fix | effort |
|----|----------|-----------|------|----------------|---------------|--------|
| S1-1 | functional | preseed/ncz-ui.sh:29-30 | `ncz_ui_brand()` reads `NCZ_RELEASE_VERSION`/`NCZ_RELEASE_CODENAME` from a RELEASE file on the install medium | a stale RELEASE copy renders the retired 26.7 name in every dialog frame title | always derive from a single source (e.g. build-time stamp in BUILD_VERSION) or validate the version against release.conf before display | MEDIUM |
| S1-2 | cosmetic | preseed/ncz-ui.sh:4 | comment says `"NCZ-OS 26.7 Maximilian"` — stale 26.7 codename in the docstring | operators reading the source see a retired release name | update to current release or use a placeholder like `<version> <codename>` | EASY |
| S1-3 | functional | preseed/component-selector.sh:329-375 | after normalisation, lines 370-375 reassemble `CHOSEN` from WANT_* booleans — this drops the original order and can re-add `browsers`/`wallpaper-rotator` even if the operator explicitly unticked them (they ride along with `desktop`) | a user who unticks `desktop` but leaves `browsers` visible in the log gets a surprise browsers install; the reassembly also loses `cuda` ordering relative to others | keep the normalised token list as the single source of truth; only auto-derive `browsers`/`wallpaper-rotator` from `desktop` if not already in the list | MEDIUM |
| S1-4 | functional | preseed/component-selector.sh:229-231 | `Choices:` is set to the *descriptions* and `Choices-C:` to the *tokens* — these are swapped. cdebconf's newt frontend uses `Choices-C:` as the display label and `Choices:` as the value key | the checkbox labels in the newt frontend show raw tokens (`desktop`, `mgmt-container`) instead of the human descriptions; the comment at lines 159-177 explicitly documents the intended fix but the code does the opposite | swap: `Choices: ${_OFFERED}` and `Choices-C: ${_CHOICES_C}` | EASY |
| S1-5 | cosmetic | preseed/component-selector.sh:136 | `INTERNAL_COMPONENTS` includes `browsers` and `wallpaper-rotator` which are never shown in the dialog but are accepted as valid tokens in cmdline overrides | an unattended run passing `browsers` without `desktop` gets browsers installed with no desktop — silent mismatch vs. the UI contract | either reject `browsers`/`wallpaper-rotator` when `desktop` is absent, or document that the override bypasses the auto-derivation | EASY |
| S1-6 | functional | preseed/ncz-ui.sh:57 | `arm64` is hard-coded to display as `"arm64 (Sky1)"` regardless of the actual Sky/SoC | on a non-Sky1 arm64 board the label is wrong | read the Sky/SoC from a payload file or `uname -v` and only append the suffix if it matches | EASY |

## S2 — installer dialogs (disk-fs-chooser.sh, hostname-suggest.sh)

| id | severity | file:line | what | why it matters | suggested fix | effort |
|----|----------|-----------|------|----------------|---------------|--------|
| S2-1 | cosmetic | preseed/disk-fs-chooser.sh:289 | `Choices: btrfs, ext4` — btrfs listed first, matching `Default: btrfs`, but the description text at line 294-295 explains btrfs first too; the ordering is consistent but the comma-separated `Choices` in a select template has no human-readable description per option (no `Choices-C:`) | newt frontend will show raw tokens `btrfs` / `ext4` as checkbox labels instead of the descriptive text the operator expects | add a `Choices-C:` field with the short descriptions | EASY |
| S2-2 | cosmetic | preseed/disk-fs-chooser.sh:334 | `Components: ${_ncz_sel:-all}` in the erase-confirmation dialog shows raw comma-separated tokens (e.g. `desktop,browsers,wallpaper-rotator,rescue-partition`) | operator sees internal tokens, not human-readable component names | map tokens to their display names before rendering the dialog | EASY |
| S2-3 | functional | preseed/hostname-suggest.sh:79 | the `--prompt` branch at lines 77-103 is dead code: `preseed.cfg` no longer calls this script with `--prompt` (stated at lines 75-76), but the block still creates the template, shows the dialog, and writes state — it will execute if anyone re-adds the flag | stale code path that could silently re-enable an interactive prompt in an unattended pipeline; also the `$ASKED` marker is created (line 78) before the dialog is shown, so a failed dialog would permanently suppress the prompt | remove the `--prompt` block or guard it behind an explicit feature flag; create `$ASKED` only after the dialog is answered | MEDIUM |
| S2-4 | cosmetic | preseed/hostname-suggest.sh:86-87 | prompt says "It stays the same if you swap network adapters" — this is true for the hostname but the wording implies a network-adapter-specific binding that could confuse operators who expect hostname to change with hardware | minor UX clarity issue | reword to "This name is tied to the machine, not to any network adapter" | EASY |
| S2-5 | functional | preseed/disk-fs-chooser.sh:234-245 | the disk-selection template uses `Choices: ${CHOICES}` with raw `/dev/nvme0n1` tokens and no `Choices-C:`; the `LONG` variable with human-readable descriptions is embedded only in the `Description` body | the newt select shows `/dev/nvme0n1` / `/dev/sda` as the only labels — no model name or size in the selector itself, only in the description text below | add a `Choices-C:` field mapping each token to its `disk_model` + `disk_size_h` description | MEDIUM |

## S3 — identity / branding (50-brand.sh, release.conf, branding/)

| id | severity | file:line | what | why it matters | suggested fix | effort |
|----|----------|-----------|------|----------------|---------------|--------|
| S3-1 | cosmetic | post-install/50-brand.sh:95 | `LOGO=ncz-os-${SKU_LOWER}` expands to `ncz-os-cygnus` but there is no matching logo file in the repo (no `branding/cygnus/logo.png` or similar) | the LOGO key in os-release points to a non-existent asset; any consumer that reads it (e.g. a greeter icon picker) will fail silently | either ship the logo file or remove the LOGO key | EASY |
| S3-2 | cosmetic | branding/cygnus/tools/make-cygnus-art.py:232 | comment references "the 26.7 banner" — stale 26.7/Maximilian era reference | cosmetic; a future maintainer reading the code sees a retired release name | update comment to reference 26.10/Cygnus or remove the 26.7 reference | EASY |
| S3-3 | functional | build/gen-maximilian-art.py:2-5 | entire script is a 26.7 "Maximilian" art generator, still shipped in the repo | ships dead code for a retired release; adds confusion about which art tool is current | remove the file (or move to `retired/`) since 26.10 uses `branding/cygnus/tools/make-cygnus-art.py` | EASY |
| S3-4 | functional | assets/dev/gen-maximilian-art.py:2-5 | duplicate 26.7 Maximilian art generator under `assets/dev/` | same as S3-3; two copies of dead 26.7 tooling | remove both copies | EASY |
| S3-5 | cosmetic | post-install/50-brand.sh:7 | comment says "retired the old 'Reinhardt'=desktop / 'Magnetar'=server per-variant codename scheme" — the retired names appear in a comment that could confuse a reader skimming for current identity | minor: stale names in a doc comment that is otherwise clear | reword to "retired the old per-variant codename scheme" without naming them | EASY |
| S3-6 | functional | post-install/50-brand.sh:265 | the motd banner script re-sources `/etc/cix-installer/RELEASE` and recomputes `SKU` via `VERSION_CODENAME^` (bash case-fold) — if `VERSION_CODENAME` is missing from os-release (e.g. a partial install), the banner falls back to `${NCZ_RELEASE_CODENAME:-Unknown} Desktop` which is always "Desktop" even on a Server build | Server installs can show "Unknown Desktop" in the login banner if os-release is incomplete | default to the variant from `NCZ_VARIANT` in os-release rather than hard-coding "Desktop" | EASY |

## S4 — hook orchestration (run-all.sh: _SKIP_DESKTOP_RE, MACHINE_HOOKS_RE, overlap)

| id | severity | file:line | what | why it matters | suggested fix | effort |
|----|----------|-----------|------|----------------|---------------|--------|
| S4-1 | functional | post-install/run-all.sh:635-642 | Phase 0 comment references `09-diag-account.sh` creating a "magnetar" account — the file does not exist in post-install/ (only 05-time-sync.sh is on disk) | dead code reference: operators reading the Phase 0 rationale will look for a hook that isn't there; if 09-diag-account.sh was removed, the comment is stale; if it's staged elsewhere, the comment is misleading | update the comment to reference the actual Phase 0 hooks on disk, or add a note that 09-diag-account.sh is optional/staged externally | EASY |
| S4-2 | cosmetic | post-install/run-all.sh:367 | `_SKIP_DESKTOP_RE` includes `85-power-perf-mode` — a hook named "power-perf-mode" reads like a hardware/perf concern, not a desktop one, yet it's in the desktop-skip list | an operator reading the skip list may be confused why a "power" hook is skipped when desktop is OFF; the comment at lines 368-374 explains 54/55 are deliberately excluded but not 85 | add a comment line explaining why 85-power-perf-mode is desktop-gated | EASY |
| S4-3 | cosmetic | post-install/run-all.sh:367 | `_SKIP_DESKTOP_RE` includes `84-vpu-mpv` and `84-vpu-vaapi` — VPU/video hooks in the desktop-skip list without an in-line explanation | same as S4-2: the exclusion rationale for 54/55 is documented but the 84-vpu-* inclusion is not | add a brief comment: "84-vpu-mpv/vaapi: video playback is a desktop workload" | EASY |
| S4-4 | functional | post-install/run-all.sh:174 | `MACHINE_HOOKS_RE` is a hand-maintained allowlist of ~90 hook names; the comment block at lines 131-173 documents three separate incidents (r204, r262, 2026-10-06) where hooks were added to post-install/ but forgotten in this regex, silently dropping them from baked installs | the allowlist pattern is fragile: every new hook requires a manual edit here or it silently disappears from `--mode full` installs. The 2026-10-06 note says a test (build/test-run-all-baked-allowlist.sh) now catches this, but the regex itself remains a single point of failure | switch to a denylist (list hooks that are NOT machine hooks) or auto-generate MACHINE_HOOKS_RE from the hooks.list files, eliminating the manual sync requirement | LARGE |
| S4-5 | cosmetic | post-install/run-all.sh:637 | comment says "09-diag-account.sh creates magnetar/diags" — the account name "magnetar" is the retired server-variant codename (retired 2026-07-27 per 50-brand.sh:7) | stale naming in a comment; a reader may think "magnetar" is still a live account name | update the comment to use the current account name (or "the diag account") | EASY |

## S5 — first boot (51-ncz-tour-slides.sh, 63-ncz-idle-lock-order.sh, 55-greeter.sh)

| id | severity | file:line | what | why it matters | suggested fix | effort |
|----|----------|-----------|------|----------------|---------------|--------|
| S5-1 | cosmetic | post-install/55-greeter.sh:2 | header comment says "NCZ-OS 26.7 SHIP greeter" — stale 26.7 release number in the hook header | the hook is the greeter for 26.10 Cygnus; a reader sees a retired release number | update to "NCZ-OS 26.10" or just "NCZ-OS SHIP greeter" | EASY |
| S5-2 | functional | post-install/55-greeter.sh:165 | `logger -t ncz-greetd-drm "connected output not enabled after 8s"` — the message says "8s" but the actual grace window is 32 iterations × 0.25 s = 8 s, which is correct; however the message is emitted at iteration 32 (line 164) which is 32 × 0.25 = 8 s from the first connected observation — the log message is accurate but the variable name `try` vs the 120-iteration max loop makes the timeout hard to reason about | minor: the 120 × 0.25 s = 30 s total timeout is not documented in the log message; an operator seeing the log may not know whether the greeter gave up or is still waiting | add a log line at the top of the loop documenting the total timeout (30 s) and the grace window (8 s) | EASY |
| S5-3 | cosmetic | post-install/55-greeter.sh:42 | `WALL_SRC=$ASSETS/greeter/cygnus/greeter-backdrop-1920x1080.png` — the variable name `WALL_SRC` implies a wallpaper, but the comment at lines 84-89 explicitly says it is NOT a wallpaper (it is a dedicated greeter backdrop) | naming mismatch; a reader may confuse it with the desktop wallpaper path | rename to `BACKDROP_SRC` or `GREETER_BG` | EASY |
| S5-4 | cosmetic | post-install/51-ncz-tour-slides.sh:9 | TODO comment: "split the Sky1 slide into a platform hook when phase C lands" — open TODO with no tracking reference | an untracked TODO in a shipping hook is a maintenance risk; nobody will know when phase C lands | move to a tracking issue or add a milestone tag; or remove if the split is deferred indefinitely | EASY |
| S5-5 | functional | post-install/63-ncz-idle-lock-order.sh:127 | `if [ -z "${NCZ_IDLELOCK_SCHEMA_DIR:-}" ]` — the `glib-compile-schemas` recompile at line 128 is skipped when `NCZ_IDLELOCK_SCHEMA_DIR` is set (the test seam), but the scratch-copy validation at line 119 already passed. In production (seam unset) the recompile runs. The logic is correct but the condition is inverted from what the comment implies: the recompile is for PRODUCTION, not for tests | the guard is correct but confusingly named: a reader may think the recompile is skipped in production when it's actually the opposite. The condition should be `if [ -n "${NCZ_IDLELOCK_SCHEMA_DIR:-}" ]; then :; else glib-compile-schemas ...; fi` for clarity | restructure the condition to read naturally: "recompile the real schema dir in production (skip in tests)" | EASY |

## S6 — settings keys (gsettings set duplicates in post-install/)

| id | severity | file:line | what | why it matters | suggested fix | effort |
|----|----------|-----------|------|----------------|---------------|--------|
| S6-1 | — | (none) | No key is set more than once by `gsettings set`. The four unique keys are: `dev.sinty.desktop background-picture-uri` (45-wallpaper-rotator.sh:469, runtime), `org.gnome.desktop.background picture-uri` / `picture-uri-dark` / `picture-options` (45-wallpaper-rotator.sh:475-477, GNOME fallback path, mutually exclusive with the Singularity path). `background-picture-uri` also appears in a gschema override at 20-desktop.sh:1087 (install-time default) but that is a schema-default mechanism, not a `gsettings set` call, and is superseded by the runtime rotator. No duplicate-set bug found. | — | — | — |

## S7 — stale naming (Maximilian / Reinhardt in source)

| id | severity | file:line | what | why it matters | suggested fix | effort |
|----|----------|-----------|------|----------------|---------------|--------|
| S7-1 | cosmetic | manifests/desktop.pkgs:1 | header comment: `NCZ-OS 26.7 "Maximilian" Singularity Desktop offline closure` | this is a live package manifest, not a comment about history — the first thing a maintainer sees says the retired 26.7 name | update to `NCZ-OS 26.10 "Cygnus" Singularity Desktop offline closure` | EASY |
| S7-2 | cosmetic | build/build-singularity.sh:5 | header comment: `NCZ-OS 26.7 "Maximilian" ships Singularity Desktop` | same as S7-1 in a build script; misleading on a fresh read | update to 26.10 Cygnus | EASY |
| S7-3 | cosmetic | preseed/ncz-ui.sh:4 | docstring example: `"NCZ-OS 26.7 Maximilian"` (same file as S1-2) | duplicate of S1-2; the docstring example shows a retired release | update to a current or generic example | EASY |
| S7-4 | cosmetic | post-install/50-brand.sh:7 | comment: `retired the old "Reinhardt"=desktop / "Magnetar"=server` (same as S3-5) | duplicate of S3-5 | reword without naming the retired codenames | EASY |
| S7-5 | cosmetic | post-install/48-server-variant.sh:11-14 | comments reference the retired "Reinhardt"/"Magnetar" scheme and rename the file from `48-magnetar-variant.sh` | historical context in a shipping hook header; the file is now correctly named 48-server-variant.sh but the comment still carries the old names | trim to "the old per-variant codename scheme was retired 2026-07-27" without the names | EASY |
| S7-6 | cosmetic | post-install/59-desktop-curate.sh:89 | comment: `Stray old-codename branding ("Reinhardt" was retired in 26.7)` | the comment correctly identifies what it cleans up but names a retired codename in a way that could confuse a reader who doesn't know the history | reword to "Stray old-codename branding (pre-Cygnus era)" | EASY |
| S7-7 | cosmetic | post-install/61-chromium-icon.sh:6 | comment: `in the 26.7 Maximilian orange. 26.10 Cygnus uses a magenta -> violet ->` | the comment documents the colour change correctly but the 26.7 name is the first thing a reader sees | reword to "the old 26.7 orange palette; 26.10 Cygnus uses..." | EASY |
| S7-8 | cosmetic | build/test-ncz-ui.sh:6 | comment: `this asserted "NCZ-OS 26.7 Maximilian" through 26.7` | test comment references the retired codename; the test itself (per build/test-release-identity.sh:61) actively checks that no live file names Maximilian, so this comment is the test documenting its own history | acceptable as history prose; no fix needed unless the test file is refactored | EASY |
| S7-9 | cosmetic | build/build-squashfs-layers.sh:608 | comment: `26.7 "Maximilian": Singularity Desktop (labwc/wlroots, GTK4) REPLACES XFCE` | build-script comment names the retired release; the build is now producing 26.10 | update to 26.10 Cygnus | EASY |
| S7-10 | cosmetic | post-install/20-desktop.sh:1034 | comment: `Cygnus -- not the old Maximilian red` | the comment is correct context but names the retired codename in a live hook | reword to "the old red accent" without naming Maximilian | EASY |
| S7-11 | cosmetic | build/test-release-identity.sh:9,21 | comments document that the test used to pin 26.7/Maximilian and now checks no live file names it | test history prose; the test is the guard that prevents regressions, so the comment is useful context | acceptable; no fix needed | EASY |

## SUMMARY

### Counts by severity

| severity | count | ids |
|----------|-------|-----|
| functional | 10 | S1-1, S1-3, S1-4, S1-6, S2-3, S3-6, S3-1*, S4-4, S4-1, S5-5 |
| cosmetic   | 21 | S1-2, S1-5, S2-1, S2-2, S2-4, S2-5, S3-2, S3-3, S3-4, S3-5, S4-2, S4-3, S4-5, S5-1, S5-2, S5-3, S5-4, S7-1 … S7-11 |
| none       | 1  | S6-1 (no duplicate found) |

\* S3-1 is borderline: a missing logo file is functional if any consumer reads LOGO; cosmetic if nothing does. Marked functional here.

### Top 10 — worth doing first

Ranked by impact-per-effort, mixing cosmetic polish and functional fixes.

| # | id | severity | one-liner | effort |
|---|----|----------|-----------|--------|
| 1 | S1-4 | functional | `Choices:` / `Choices-C:` are swapped in the component-selector template — checkbox labels show raw tokens instead of descriptions | EASY |
| 2 | S1-1 | functional | Stale RELEASE file on the install medium renders the retired 26.7 name in every installer dialog | MEDIUM |
| 3 | S1-3 | functional | Component reassembly at lines 370-375 re-adds browsers/wallpaper-rotator even when the operator unticked desktop | MEDIUM |
| 4 | S3-3/3-4 | functional | Two copies of the 26.7 Maximilian art generator still ship in build/ and assets/dev/ | EASY |
| 5 | S4-4 | functional | MACHINE_HOOKS_RE is a 90-entry hand-maintained allowlist; three separate incidents of silently-dropped hooks documented in its own comments | LARGE |
| 6 | S2-5 | functional | Disk-chooser select shows raw /dev nodes with no model/size label in the newt frontend | MEDIUM |
| 7 | S2-3 | functional | `--prompt` block in hostname-suggest.sh is dead code that could re-enable an interactive prompt in an unattended pipeline | MEDIUM |
| 8 | S1-6 | functional | arm64 label hard-coded to "Sky1" regardless of actual SoC | EASY |
| 9 | S7-1 | cosmetic | manifests/desktop.pkgs header still says "26.7 Maximilian" — the first line a maintainer reads | EASY |
| 10 | S5-1 | cosmetic | 55-greeter.sh header says "26.7 SHIP greeter" — the most-visible hook header on the system | EASY |
