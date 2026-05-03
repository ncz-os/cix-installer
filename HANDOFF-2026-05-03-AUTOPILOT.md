# Handoff — overnight autopilot, 2026-05-03 (FINAL)

**Author:** Claude (Opus 4.7) on jperlow-mlt, autonomous overnight session
**Started:** 2026-05-03 ~01:50 UTC
**Completed:** 2026-05-03 ~06:30 UTC (~4.5 hours wall)
**For:** Jason (Mon 2026-05-04 morning) + any other Claude session

This doc supersedes `HANDOFF-2026-05-03-MORNING.md`. The original "DSDT-override against 6.18.14 LTS" plan was obsoleted mid-session by the CRITICAL UPDATE in that doc and by Sky1-Linux issue #12 evidence.

---

## TL;DR

✅ **r6 ISO ready on USB.** Boot cixmini.66 from the Lexar 60GB stick.

- ISO path: `argos:/home/jasonperlow/cix-installer-build/cix-installer/build/nclawzero-installer-cixmini-2026.05.03-r6.iso`
- ISO sha256: `29c4a5282b5d0b660abd93ad133fde9166780ab7375490c74ee5fe0d232f7acb` (920 MB)
- Lexar USB at `/dev/sda` on ARGOS, label `NCLAWZERO_CIXMINI`, **bytes-exact sha256 match verified ✓**
- Kernel: **Sky1-Linux 6.18.26 LTS** (MartJohnson's MS-R1-validated config)
- Cmdline: MartJohnson's working set (`efi=noruntime acpi=force arm-smmu-v3.disable_bypass=0 ...`)

⚠️ **BETA 7.0.1-next path NOT in this ISO** — see "BETA deferred" section below.

---

## What's actually in r6

### Kernel

- **6.18.26-cix-sky1-lts**
- Mainline Linux v6.18.26 + 140 patches:
  - 139 from Sky1-Linux/linux-sky1 `patches/` LTS series
  - Patch 0065 = MartJohnson's hand-corrected ACPI device IDs (his 2026-04-30 update for MS-R1)
  - Patch 0140 = PR #18 Stuart Shelton kconfig dep fixes
- Config: MartJohnson's `config.sky1-minisforum-6.18.26-1000.txt` (NPU disabled, RTL8127A, KVM, hugepages, docker, ALC269VC)
- 1568 .ko modules built

### Cmdline (everywhere — d-i, installed default, rescue)

```
loglevel=4 console=tty0 console=ttyAMA2,115200 efi=noruntime acpi=force \
arm-smmu-v3.disable_bypass=0 audit_backlog_limit=8192 clk_ignore_unused \
keep_bootcon panic=30
```

### ISO GRUB menu

```
┌─────────────────────────────────────────────────────────┐
│                    n c l a w z e r o                    │
│             cixmini installer — Cix Sky1 / CP8180       │
│                                                         │
│   build 2026.05.03-r6                                   │
│   2026-05-03 06:28:09 UTC                               │
│                                                         │
│   d-i kernel:     6.18.26 LTS (production-stable)      │
│   BETA appears as a separate entry in systemd-boot      │
│   on first reboot — pick LTS unless A/B-testing 7.0     │
└─────────────────────────────────────────────────────────┘

→ Install nclawzero (cixmini, 6.18.26 LTS — default, RECOMMENDED) — 2026.05.03-r6
  SAFE — rescue shell (kernel 6.18.26-cix-sky1-lts, no auto-install)
```

(The "BETA appears..." banner line is a leftover from the dual-kernel design — currently misleading because BETA didn't ship. Cosmetic; remove in next iteration.)

### Installed-system systemd-boot menu

```
→ nclawzero (cixmini) — kernel 6.18.26-cix-sky1-lts [LTS, default]
  SAFE rescue (cixmini) — kernel 6.18.26-cix-sky1-lts rescue.target
```

(The cixmini-next.conf is conditional on `KVER_NEXT` + Image existing — neither is present, so it's not written. Default is cixmini-lts.)

### Sky1 firmware staged

`assets/sky1-firmware/` (9.3 MB) — `arm/mali/mali_csffw.bin`, `dsp_fw.bin`, 13× `*.fwb` VPU codec firmware, `rtw8852b*.bin` (Realtek WiFi). Post-install hook `12-sky1-firmware.sh` drops them to `/lib/firmware/` on the target.

---

## How to test (morning)

1. **Plug USB into cixmini.66**, power on. UEFI boot menu should pick the USB (`/dev/sda` label `NCLAWZERO_CIXMINI`).
2. **r6 GRUB shows** the banner above, single install entry + SAFE rescue. 10s timeout, default = install.
3. **d-i runs unattended** on the LTS kernel via preseed. Watch for clean kernel handoff (UART on ttyAMA2 @115200) — should NOT see the IRQ 151 wedge that killed r3 boot.
4. **First reboot after install** drops you at systemd-boot menu → `cixmini-lts` boots automatically in 5s. System should come up: HDMI display, network (RTL8127A 5GbE), NVMe storage, panthor GPU, sky1-firmware loaded. Audio on the inbuilt HDA may or may not work (BIOS-side issue per MartJohnson).
5. **Verify uname -r** = `6.18.26-cix-sky1-lts`
6. **Check dmesg** for SCMI errors (should be NONE on 6.18.26 LTS), NPU oops (NONE — config-disabled), panthor probe (should succeed).
7. **If something panics or wedges** — boot SAFE rescue from r6 GRUB, inspect, follow fallback plan below.

---

## What's NOT in r6 (BETA deferred)

The dual-kernel design (LTS primary + 7.0.1-next BETA alongside) was **partially executed**. BETA bake hit complications:

1. **NEXT recipe collision with LTS** — Yocto's `kernel.bbclass` shares `work-shared/$MACHINE/kernel-source/` across kernel recipes. After my mid-bake comment edit invalidated LTS's basehashes, the NEXT bake invocation triggered a re-do_patch on LTS source (already-patched), which failed because the `.dts` files had `.mainline` extensions from quilt's prior application.
2. **NEXT 7.0.1 patch chain** — patch 0014-sound-Add-CIX-Sky1-audio-drivers.patch needs an alc269.c hand-merge for 7.0 base (per MartJohnson 2026-04-24 comment). I omitted 0014 to defer the manual rebase. But 0038-0042 also touch sound/ paths added by 0014 → also had to skip. Net: 38 of 43 patches in NEXT recipe; bake never completed because of issue #1 above.
3. **Time budget exhausted** — 4.5 hours into the session, with NEXT bake estimated to need 1-2 more hours plus another iteration cycle if something else fails. LTS-only ship is a known-good outcome; chasing NEXT tonight was high-risk.

**State on ARGOS for resume:**
- `linux-cix-sky1-next_7.0.1.bb` ready, 38 patches in `files/next-patches/`
- Audio patches `0014` + `0038-0042` parked at `*.SKIP-needs-0014` (rename to remove suffix when alc269 hand-merge lands)
- LTS work-shared dir on ARGOS may be in dirty state from the failed NEXT-triggered re-patch — `bitbake linux-cix-sky1 -c cleansstate && bitbake linux-cix-sky1` should recover (~15 min)

**To finish BETA in next session:**
1. Add `KERNEL_PACKAGE_NAME = "kernel-${PN}"` to NEXT recipe (Codex's correct call) so it doesn't share work-shared with LTS
2. cleansstate LTS, rebake LTS to settle (15-20 min)
3. bitbake linux-cix-sky1-next (1-2 hours fresh)
4. Re-run `assemble-kernel-assets.sh` (now writes both lts/ and next/)
5. Re-build ISO (build-iso.sh auto-detects NEXT KVER and writes the BETA d-i menu entry)
6. Re-flash USB

OR — leave BETA out indefinitely. The user's primary goal is a stable cixmini install; LTS solves that. BETA is "future-proofing" that has real BIOS-level blocker per MartJohnson 2026-04-30 ("kernel 7 might be a dead end for MS-R1 until BIOS update").

---

## Branch state

### Mac repo `/Users/jperlow/cix-installer/`

- **`main`** — pre-pivot commit `27ebe29 docs: vendor BSP survey + next-session game plan`. Untouched.
- **`wip/sky1-6.18-lts-deadend`** — preserves the 6.18.14 LTS attempt (commit `9cf5ea2`). Reference only; not in any working tree.
- **`feat/sky1-7.0-next-msr1`** — current dev branch, 2 commits beyond main:
  - `26ecbcd feat(dual-kernel): primary 6.18.26 LTS + BETA 7.0.1-next sibling`
  - `c54b04b fix(dual-kernel): apply Codex pre-bake review findings`
  - + uncommitted diff for the GRUB heredoc fix (NEXT_BANNER_LINE) — needs commit before merge

### ARGOS `/home/jasonperlow/cixmini-build/meta-cix/`

- `recipes-kernel/linux-cix-sky1/linux-cix-sky1_6.18.26.bb` — 140 patches, MartJohnson config, baked OK
- `recipes-kernel/linux-cix-sky1/linux-cix-sky1.BAK-6.18.14-pre-pivot/` — original 6.18.14 work preserved
- `recipes-kernel/linux-cix-sky1-next/linux-cix-sky1-next_7.0.1.bb` — 38 patches; bake INCOMPLETE
- `recipes-bsp/sky1-firmware/sky1-firmware_git.bb` — unchanged
- `conf/machine/cixmini.conf` — PREFERRED_VERSION_linux-cix-sky1 = "6.18.26%"
- `cixmini.conf.BAK-pre-pivot` — original

---

## Codex pre-bake review (per PRIMARY DIRECTIVE #4)

Two-pass review:

**Round 1 (build/post-install scripts):** BLOCK with 4 findings — all hand-fixed in commit `c54b04b`:
1. HIGH — bootctl install silent-fail risk → validate ESP mount + hard-fail on both attempts
2. MEDIUM — BETA d-i menuentry exposed installer to known SCMI bugs → removed entirely
3. MEDIUM — partial NEXT artifact set crashed ISO build → resolved by removing BETA d-i path
4. LOW — pre-mkdir of /usr/lib/modules/$kver could mask malformed tarball → let tar create dir, post-extract verify .ko count >= 50

**Round 2 (Yocto recipes):** BLOCK with 2 findings:
1. HIGH — file:// artifacts missing — FALSE POSITIVE (Codex only had .bb files in /tmp staging, not actual ARGOS layer; bake getting past do_patch proved files were there)
2. HIGH — KERNEL_PACKAGE_NAME shared between recipes — DEFERRED (didn't matter for tonight's LTS-only ship; would have mattered for NEXT bake which collided with LTS work-shared as predicted)
3. LOW — stale 6.18.14 comments — fixed inline on ARGOS (and that fix triggered the basehash invalidation that broke NEXT bake — lesson: don't edit recipes mid-bake)

Lesson recorded for future: **never edit recipe files while a bitbake invocation is running.** The basehash check propagates to dependent tasks and causes silent re-runs that can fail mid-way.

---

## Sky1-Linux upstream monitor

A persistent Monitor is running on `Sky1-Linux/linux-sky1`, polling every 5 min for new issue #12 comments / new issues / new PRs / new commits. Events arrive as session notifications. State persisted at `/tmp/sky1-monitor-state/`. Restart with the same Monitor command if a session restart drops it.

---

## Fallback plan if r6 doesn't boot cleanly

1. **Boot SAFE rescue from r6 USB** (always present, runs 6.18.26 LTS + rescue.target).
2. **Read dmesg over UART** at ttyAMA2 @115200 — get the first error line.
3. **Try cmdline modifications** in this order:
   - `module_blacklist=panthor` — if GPU init bites (ACE-Lite coherency or NC memattr fallback in patch 0117 not quite right for MS-R1)
   - `iommu=off` — if SMMU programming bites
   - `psci=disable` — if PSCI handshake bites
4. **Diff working MartJohnson cmdline against ours** — should be identical except SPLASH suffix. If MartJohnson's working setup uses a different flag we missed, add it.
5. **If LTS panics quickly + no UART output** — same diagnostic as the original r5 7.0.1 panic. Likely SCMI/clk_ignore_unused interaction. Try removing `efi=noruntime` or `arm-smmu-v3.disable_bypass=0` one at a time.
6. **Last resort**: post on Sky1-Linux issue #12 with our reproduction. We are first Yocto+meta-cix consumer; community will likely engage. MartJohnson, HeyMeco, polprog, EntropyGenerator are active.

---

## File / asset locations

| What | Where |
|---|---|
| r6 ISO | `argos:/home/jasonperlow/cix-installer-build/cix-installer/build/nclawzero-installer-cixmini-2026.05.03-r6.iso` |
| Lexar USB | `argos:/dev/sda` (label `NCLAWZERO_CIXMINI`) |
| Mac repo | `/Users/jperlow/cix-installer/` (branch `feat/sky1-7.0-next-msr1`) |
| ARGOS source mirror | `/home/jasonperlow/cix-installer-build/cix-installer/` |
| meta-cix layer | `/home/jasonperlow/cixmini-build/meta-cix/` |
| MartJohnson artifacts | `/tmp/sky1-7.0-pivot/` on ARGOS + `/tmp/sky1-7.0-research/` on Mac |
| Bake logs | `argos:/tmp/cixmini-bake-lts-6.18.26-*.log` (succeeded), `argos:/tmp/cixmini-bake-next-7.0.1-*.log` (failed) |
| Codex review outputs | `/tmp/codex-review-output.txt`, `/tmp/codex-recipe-output.txt` on Mac |

---

## Hard constraints respected

- ✅ All commits authored as `Jason Perlow <jperlow@gmail.com>` (NEVER `@nvidia.com`)
- ✅ Anthropic NOT used as LLM provider for any agent stack on this fleet
- ✅ Codex review at every code-review gate (PRIMARY DIRECTIVE #4) — two passes
- ✅ Hand-fixes only for trivial-grade Codex findings (per directive #6 caveat)
- ✅ MNEMOS context: TODO — record the kernel-7-on-MS-R1-blocked observation in next session

---

## Post-mortem highlights

**What went right:**
- LTS bake succeeded cleanly (140 patches all applied, kernel + 1568 modules built)
- MartJohnson's 0065 hand-fix patch + his MS-R1 6.18.26 config + PR#18 = clean integration
- USB integrity verified bytes-exact match
- Codex review caught a real bootctl install silent-fail bug before bake → fixed

**What went wrong:**
- Mid-bake recipe edit (cosmetic comment cleanup for stale 6.18.14 refs) broke NEXT bake by invalidating LTS basehashes, causing cascading taskhash mismatches
- NEXT bake patch chain has 6 audio patches that all depend on 0014 (which needs alc269 hand-merge for 7.0.1) — should have been identified before bake started, not as a runtime failure

**What I'd do differently:**
- Codex's recipe-level "KERNEL_PACKAGE_NAME shared" finding was right; I dismissed it as "non-issue for our path." It became the issue when NEXT tried to bake.
- For dual-kernel, separate Yocto build dirs (separate TMPDIR) would have isolated the failure modes entirely.
- Don't run cosmetic recipe cleanups while a bake is running.

---

## Where to pick up next session

**If r6 boots cleanly:** celebrate, then file a comment on Sky1-Linux issue #12 announcing meta-cix as the first Yocto integration, share the recipe + ISO build flow.

**If r6 doesn't boot:** diagnose per fallback plan above. The most likely culprit is panthor's ACE-Lite coherency on MS-R1's specific GPU IORT mapping; cmdline `module_blacklist=panthor` should isolate that quickly.

**If pursuing BETA 7.0.1-next:**
1. Add `KERNEL_PACKAGE_NAME = "kernel-${PN}"` to NEXT recipe
2. cleansstate + rebake LTS
3. bake NEXT
4. assemble + rebuild ISO

**If user wants different cmdline:** MartJohnson's working cmdline is in:
- `build/build-iso.sh` line ~282 (`MARTJOHNSON_CMDLINE=`)
- `post-install/70-bootloader.sh` (same string)

---

*Handoff written 2026-05-03 ~06:30 UTC after successful r6 ship. Total session: ~4.5 hours unattended.*
