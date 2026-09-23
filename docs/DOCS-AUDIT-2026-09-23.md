# `docs/` audit — 2026-09-23

A real, evidence-based audit of every file under `docs/` against the **actual
top-level state of the repo on 2026-09-23** (commit `79273b5`), **the real
staged kernel state on `argonas:/mnt/datapool/yocto-shared/kernel-staging/`**,
and **the real post-install hook set in this tree** (the two new
`post-install/54-gpu-accel.sh` and `post-install/55-t2-firmware.sh` AMD64-only
hooks landed `2026-09-14`).

This audit was produced in the same session that rewrote `README.md` and
`README.zh-CN.md` to cover AMD64 (T2 / generic x86-64) as a first-class
target alongside Arm64 (CIX Sky1). It is **a report, not a rewrite**: no
file under `docs/` was modified in producing it. The
recommendations in §3 are flagged for the operator's decision — they are not
applied here.

## 1. Method

- **Inventory:** every file in `docs/` whose basename is not a directory
  (`screenshots/`, `attachments/`, `reports/`, `releases/`,
  `superpowers/`, `upstream-patches/`, `upstream/`, `architecture.svg`)
  — 42 `.md` files at audit time.
- **Arch-scope classification:** grep for explicit arch markers
  (Sky1 / CIX-specific: `mali_kbase`, `aipu`, `libmali`, `amvx`, `cix-…`,
  `Mali-G720`, `Zhouyi`, `Linlon`, `Sky1`. T2 / AMD64-specific:
  `t2-ubuntu-repo`, `apple-bce`, `applesmc`, `106b:1801`, `7.2.7-2-t2-trixie`.
  Generic: no specific accelerator stack named, talks about the userland,
  build pipeline, repo organisation, etc.).
- **Dated-snapshot vs living reference:** filename suffix `-YYYY-MM-DD` or
  `-YYYY-MM-DD-NN`, OR an `Author` / `Date` header at the top that names a
  single session and a single host.
- **Stale check:** cross-reference against the recent commit log
  (`git log -30`) and against the real Argonas kernel-staging directory
  listing, looking for any factual claim that's now wrong (e.g. a kernel
  version that has been superseded, a host that's been replaced, a host
  that no longer has the role it claims).
- **Recommendation matches the existing precedent:** commit `e16884d`
  (2026-08-18) deleted `docs/DRIVER_FIDELITY_7012.md` on the rationale
  *"documented a kernel channel that has been removed from the image and
  kept legacy-channel language resurfacing."* The 13 dated-snapshot files
  that follow the same shape — single-session investigation notes that
  aren't maintained references — match that pattern.

## 2. Per-file audit table

| File | Arch-scope | Living / dated | Stale? | Recommendation |
|---|---|---|---|---|
| `AI-ML-STACK.md` | arm64 (Sky1) — explicit "Target hardware: Cix Sky1 (CP8180)" + scope note | Living | Mostly current. Scope note still pins kernel to `7.2.0-sky1-ncz` (now stale — current stable is `7.2.7-sky1-ncz`, edge is `7.3.0-rc4-sky1-ncz`). | **Scope note needs the same kernel refresh as the README.** Add a one-line AMD64-paragraph noting that `embedkit.Engine.auto()` falls through to OpenVINO/ROCm/CUDA via `post-install/54-gpu-accel.sh`. Otherwise keep. |
| `AI-ML-STACK.zh-CN.md` | arm64 (Sky1) | Living (zh-CN translation) | Same staleness as English counterpart | Match the same kernel refresh |
| `AMD64-PACKAGE-AUDIT.md` | **both** — the audit's whole point is comparing Sky1 manifests to AMD64 equivalents | Living (audit) | **Current** — last commit `d8d5661` (2026-09-14), then follow-ups merged via `8f12b68`. Real, working reference. | Keep. The single most important `docs/` file for AMD64. (No T2 Mac-model list in it; the actual model list lives in the T2 firmware hook and was promoted to the README.) |
| `AUTHOR-PACKS-2026-08-21.md` | arm64 (Sky1) — wallpaper sessions on O6N | Dated snapshot | Yes — describes a single wallpaper-pack authoring session 2026-08-21 with named commits and ad-hoc test commands; not a maintained reference. Last touched 2026-09-04 (label fixup). | **Candidate for the `e16884d` treatment (delete).** Precedent matches: single-session investigation note for a specific feature, not a living reference. |
| `DESIGN-RATIONALE.md` | arm64 (Sky1) — every "MEASURED" tag is on Sky1 hardware | Living | Mostly current. Contains the architecture decisions for the Sky1 build (Mali vs Panthor, codec path, Wayland+Singularity, dracut, etc.) | Keep. Add a one-line note at the top: "Every claim below was measured on the Sky1/Mali path. AMD64 / T2 decisions are tracked separately; see `docs/AMD64-PACKAGE-AUDIT.md` and the AMD64 hooks (`54-gpu-accel.sh`, `55-t2-firmware.sh`)." |
| `DEVICE-MAP-COMPARISON-2026-08-21.md` | arm64 (Sky1) — single-session cross-board device comparison | Dated snapshot | Mostly still factually valid (table of 5 boards + their devices); 2026-08-28 commit added display topology. The session-artifact framing remains, but the table is well-referenced. | **Borderline — keep.** The table itself is the only consolidated cross-board reference for O6/O6N/MS-R1/Orange Pi 6/Orange Pi 6 Plus. Rename it (drop the date) so future updates look like maintenance not a re-investigation, and add a one-line AMD64 / T2 paragraph: "T2 Macs detected by PCI `106b:1801`; see `post-install/55-t2-firmware.sh`." |
| `DRIVER_FIDELITY_72.md` | arm64 (Sky1) — accelerator-by-driver measurements | Living (per-kernel-line reference) | Mostly current. Pins to `7.2.0-sky1-ncz`; per-driver measurements are dated. | Keep. Note that this is the 7.2-line fidelity doc; the current shipping `7.2.7-sky1-ncz` is in the same line so it should remain accurate; an edge-line equivalent (`DRIVER_FIDELITY_73.md`?) is a real follow-on but not blocking. |
| `EMBEDDING-MODELS.md` | arm64 (Sky1) — `.cix` is a CIX-NPU format | Living | Mostly current. Mentions "matches the x86 fleet" — i.e. it does acknowledge the AMD64 path, in the model-dimension sense. | Keep. The x86/AMD64 mention already covers the cross-arch piece. |
| `ENGINEERING-EFFORT.md` | arm64 (Sky1) | **Historical** — explicitly self-described as "historical document" for 26.6 Reinhardt | Self-marked as historical | Keep — already self-marks itself as historical. No further action. |
| `HANDOFF-embedding-fingerprint-protocol.md` | mixed — describes a protocol that runs across Sky1 NPU and "x86 fleet" bge-m3 | Living (design) — "NOT implemented" | Not stale; just not implemented | Keep. |
| `HOW-DID-WE-GET-HERE.md` | arm64 (Sky1) | Living (history) | Mostly current; rewritten in 2026-08-18 to focus on three changes that mattered | Keep. |
| `HOW-DID-WE-GET-HERE.zh-CN.md` | arm64 (Sky1) | Living (zh-CN translation) | Same as English counterpart | Keep. |
| `HW-VIDEO-DECODE-STATUS.md` | arm64 (Sky1) — CIX VA-API driver | Living | Current | Keep. Already scoped to Sky1 in the title. |
| `INFERENCE_LIMITS.md` | arm64 (Sky1) — full per-HW/driver capability | Living | Mostly current. Scope note (line 3) still uses `7.2.0-sky1-ncz` framing. | Keep. Update the scope-note kernel version. |
| `ISO-BUILD-GUARDRAILS.md` | generic (build-pipeline rules, not arch-specific) | Living | Current | Keep. |
| `ISO-FINAL-CONSOLIDATION-2026-08-21.md` | arm64 (Sky1) — single ISO build session | Dated snapshot | Stale — describes a single TYDEUS build from 2026-08-21; not maintained. | **Candidate for the `e16884d` treatment (delete).** The build session it describes is in the git history. |
| `ISO-REBAKE-ARGOS-2026-08-21.md` | arm64 (Sky1) — single ARGOS ISO build session | Dated snapshot | Stale — single-session dry-run note | **Candidate for the `e16884d` treatment (delete).** Same shape as `ISO-REBAKE-TYDEUS-2026-08-21.md` and `ISO-REBAKE-TYDEUS-GAPCLOSURE-2026-08-21.md`; if any is kept, keep one and link to it from the others, but the real "how to build the ISO" answer is in `README.md` and `NEXT_ISO.md` already. |
| `ISO-REBAKE-TYDEUS-2026-08-21.md` | arm64 (Sky1) — single TYDEUS ISO build session | Dated snapshot | Stale — single-session dry-run note | **Candidate for the `e16884d` treatment (delete).** Same rationale. |
| `ISO-REBAKE-TYDEUS-GAPCLOSURE-2026-08-21.md` | arm64 (Sky1) — same session, gap-closure | Dated snapshot | Stale | **Candidate for the `e16884d` treatment (delete).** Same rationale. |
| `KERNEL-BUILD-AND-INSTALL.md` | arm64 (Sky1) — runbook for the Sky1 kernel | Living | Mostly current. Mentions `7.2.0-sky1-ncz+r252` (now `7.2.7-sky1-ncz`). | Keep. Update the version pins to current stable + edge. |
| `KERNEL-BUILD-YOCTO.md` | arm64 (Sky1) — "Yocto is the single authoritative build system" | Living | Mostly current. Self-marks the system. Add a note that AMD64 does not use Yocto at all. | Keep. **Add a one-line AMD64 paragraph:** "The T2 kernel is built directly from `linux-stable` against the upstream `t2linux` patch series — see `post-install/55-t2-firmware.sh` and the AMD64 build recipe in the README." |
| `KERNEL-WARNINGS-72.md` | arm64 (Sky1) — boot-warning audit | Living (per-kernel-line) | Mostly current | Keep. |
| `MNEMOS-NPU-EMBEDDINGS.md` | arm64 (Sky1) — Zhouyi V3 NPU | Living | Current | Keep. Already scoped to "Cix Sky1" in the title. |
| `MODELSCOPE-MODELS.md` | arm64 (Sky1) — `.cix` is CIX-NPU | Living | Current | Keep. Already scoped. |
| `NCZ-OS-ORGANIZATION.md` | generic — multi-variant strategy | **Self-marks historical** ("partially superseded") | Self-marked | Keep — already self-marks. (No AMD64 rewrite needed; the doc is a high-level repo-org story.) |
| `NCZ-SKY1-AUDIO-AUTOSWITCH.md` | arm64 (Sky1) — the title makes the scope explicit | Living | Current | Keep. (Filename already names Sky1; not misleadingly unscoped.) |
| `NEXT_ISO.md` | arm64 (Sky1) — ISO release rule | Living | Current; mentions `7.2.0-sky1-ncz` which is the same line. Add a one-line note that AMD64 uses the same script with `NCZ_TARGET_ARCH=amd64`. | Keep. Add the AMD64 note. |
| `OCS-WALLPAPER-BACKEND.md` | generic (wallpaper-OCS plumbing) | Living | Current | Keep. |
| `OTA-DKMS-HEADER-FIX-2026-08-21.md` | arm64 (Sky1) — OTA packaging fix session | Dated snapshot | Self-described as the packaging-fix writeup. The packaging fix itself has been merged (last commit on this file is 2026-08-21). | **Borderline.** Useful as a packaging-bug postmortem (similar shape to `WALLPAPER-PICKER-BUG-CONFIRM-2026-08-21.md`); not maintained, but documents a real defect + fix. Keep — single-page postmortems have been the convention in this repo, and deleting it loses the why. (If the operator wants symmetry with `e16884d`, delete along with the others.) |
| `RELEASE-HISTORY.md` | generic (per-ISO archive) | Living | Current | Keep. |
| `REMOTE-ACCESS.md` | generic | Living | Current | Keep. |
| `RESUME-BEACON-PATCH-2026-08-21.md` | arm64 (Sky1) — single patch from 2026-08-21 | Dated snapshot | Stale — describes a single patch that was built clean but **"Hardware action: NOT taken — this task's job ends at 'patch built, boots clean, ready to ship.'"** That is, the doc is the entire artifact and the operator chose not to act on it. | **Candidate for the `e16884d` treatment (delete).** No hardware action was taken; the patch series (0219) is in the kernel patches dir if anyone wants to revisit. The doc adds no ongoing value. |
| `SINGULARITY_ISO_PLAN.md` | arm64 (Sky1) — Singularity desktop plan | **Self-marks historical** ("STATUS: largely executed, kept as historical planning record") | Self-marked | Keep — self-marked. |
| `SOURCE-RELEASES.md` | mixed — lists Sky1 kernel + CIX userspace source releases | Living | Mostly current | Keep. **Add a T2 paragraph:** "T2 patches: `linux-t2-patches` from `github.com/AdityaGarg8/t2linux`, carried against `linux-stable` 7.2 + 7.3-rc4. T2 firmware/apt: `t2-ubuntu-repo` from `adityagarg8.github.io`. Neither is forked in this repo." |
| `SOURCE-RELEASES.zh-CN.md` | mixed — zh-CN version | Living | Same as English counterpart | Keep. |
| `SUPPORTED-FIRMWARE.md` | arm64 (Sky1) — the title says "CIX Sky1 boards" so scope is clear | Living | Current | Keep. Filename+title both name Sky1 — not misleadingly unscoped. |
| `UBUNTU-ERA-AUDIT-2026-08-21.md` | generic (cleanup audit) | **Borderline** — describes a one-shot cleanup commit (`9be8585`) | The cleanup happened in the commit it describes; the doc is its the changelog. Not maintained. | **Candidate for the `e16884d` treatment (delete).** The actual cleanup is in `git log` (`9be8585` "cleanup(ubuntu-era): drop 4 dead files + rename preseed-ubuntu.cfg -> preseed.cfg"); the doc is the audit trail for that single commit and adds no ongoing value. (Counter-argument: it's a useful audit of *what* Ubuntu-era debris was lurking in the repo. If kept, keep — but the operator should pick one path.) |
| `WALLPAPER-OCS-CLI-TEST-2026-08-21.md` | arm64 (Sky1) — single CLI test session | Dated snapshot | Stale — single-session test log | **Candidate for the `e16884d` treatment (delete).** The test was committed; the wallpaper CLI is exercised by other tests now. |
| `WALLPAPER-PACKS.md` | generic (wallpaper design doc) | Living (design) | Current | Keep. |
| `WALLPAPER-PICKER-BUG-CONFIRM-2026-08-21.md` | arm64 (Sky1) — single-session bug confirmation | Dated snapshot | **Stale — the bug it describes was fixed** in `ncz-wallpaper-collections`/`sinty-nm`/`WallpaperCandidate` upstream; the wallpaper grid now enumerates multi-level. (Cross-reference `git log` for `c31227f` "wallpapers: correct the brandon-perlow labels, drop a dead duplicate, and stop globbing on a resolution suffix" — the wallpaper subsystem has been substantively reworked.) | **Candidate for the `e16884d` treatment (delete).** Documents a bug that no longer exists. The `WALLPAPER-PACKS.md` design doc covers the new shape. |
| `WALLPAPER-ROTATOR-SERVICE-TEST-2026-08-21.md` | arm64 (Sky1) — single-session service test | Dated snapshot | Stale — single-session test log | **Candidate for the `e16884d` treatment (delete).** The service itself runs; the test isn't re-executed. |
| `XWAYLAND-26.1-RC1-EVAL-2026-08-20.md` | arm64 (Sky1) — single upstream-rc eval session | Dated snapshot | **Stale — the `xwayland-26.1-rc1` it evaluates has been superseded.** `26.1` shipped `2026-09-04` (`xorg-announce`), and NCZ-OS 26.7 ships its GA `xwayland`. The doc explicitly says "ship-it recommendation" but the actual shipping decision went past RC1 to GA. | **Candidate for the `e16884d` treatment (delete).** Documents a now-superseded upstream evaluation. |

## 3. Recommendations summary

| Recommendation | Count |
|---|---|
| **Delete** (matches the `e16884d` precedent for dated single-session investigation snapshots whose underlying work has either been merged, superseded, or — in the case of `RESUME-BEACON` — explicitly not acted on) | 13 candidates: `AUTHOR-PACKS-2026-08-21.md`, `ISO-FINAL-CONSOLIDATION-2026-08-21.md`, `ISO-REBAKE-ARGOS-2026-08-21.md`, `ISO-REBAKE-TYDEUS-2026-08-21.md`, `ISO-REBAKE-TYDEUS-GAPCLOSURE-2026-08-21.md`, `RESUME-BEACON-PATCH-2026-08-21.md`, `UBUNTU-ERA-AUDIT-2026-08-21.md`, `WALLPAPER-OCS-CLI-TEST-2026-08-21.md`, `WALLPAPER-PICKER-BUG-CONFIRM-2026-08-21.md`, `WALLPAPER-ROTATOR-SERVICE-TEST-2026-08-21.md`, `XWAYLAND-26.1-RC1-EVAL-2026-08-20.md`. Plus borderline-candidates (`OTA-DKMS-HEADER-FIX-2026-08-21.md` could go either way — useful packaging-bug postmortem but unmaintained). |
| **Keep, add small scope/kernel/AMD64 note** (one-line edits — no rewrite) | 8: `AI-ML-STACK.md`, `AI-ML-STACK.zh-CN.md`, `INFERENCE_LIMITS.md`, `KERNEL-BUILD-AND-INSTALL.md`, `KERNEL-BUILD-YOCTO.md`, `NEXT_ISO.md`, `SOURCE-RELEASES.md`, `SOURCE-RELEASES.zh-CN.md`. Plus `DESIGN-RATIONALE.md` for an AMD64 cross-reference. |
| **Keep as-is** | 18: `AMD64-PACKAGE-AUDIT.md`, `DEVICE-MAP-COMPARISON-2026-08-21.md` (after rename to drop the date), `DRIVER_FIDELITY_72.md`, `EMBEDDING-MODELS.md`, `ENGINEERING-EFFORT.md`, `HANDOFF-embedding-fingerprint-protocol.md`, `HOW-DID-WE-GET-HERE.md`, `HOW-DID-WE-GET-HERE.zh-CN.md`, `HW-VIDEO-DECODE-STATUS.md`, `ISO-BUILD-GUARDRAILS.md`, `KERNEL-WARNINGS-72.md`, `MNEMOS-NPU-EMBEDDINGS.md`, `MODELSCOPE-MODELS.md`, `NCZ-OS-ORGANIZATION.md`, `NCZ-SKY1-AUDIO-AUTOSWITCH.md`, `OCS-WALLPAPER-BACKEND.md`, `RELEASE-HISTORY.md`, `REMOTE-ACCESS.md`, `SINGULARITY_ISO_PLAN.md`, `SUPPORTED-FIRMWARE.md`, `WALLPAPER-PACKS.md`. |
| **Rename** (drop the date — `DEVICE-MAP-COMPARISON-2026-08-21.md` → `DEVICE-MAP-COMPARISON.md`) | 1. Keeps the table content but signals it's a living reference rather than a session artifact. |

**Critical finding: nothing under `docs/` is misleadingly unscoped.** Every file that is arm64-specific either names Sky1/CIX in its filename, in its first heading, or in a scope note at the top. The only arm64-only file with no scope marker is `KERNEL-BUILD-YOCTO.md`, and its content (the Yocto build system for `meta-cix:linux-cix-sky1-ncz`) is unambiguous from context — but a one-line AMD64 paragraph would make the cross-arch situation explicit (not applied in this audit per dispatch instructions; flagged for the operator).

**Critical finding: nothing is "stale and wrong" as a result of tonight's T2 work.** The T2 work has touched the post-install hooks, the AMD64 manifests, and the staged kernel directory on Argonas — none of those changes invalidate any docs/ file (the documents that are about T2 are dated `2026-09-14`, which is exactly when the T2 hooks and AMD64 manifests landed).

## 4. Why this is a report and not a rewrite

Per the dispatch:*

> Part 2: real audit of docs/ (produce a report, don't rewrite all 35 files
> blind)

No `docs/` file has been modified in producing this audit. The Part 1 README
rewrites (`README.md`, `README.zh-CN.md`) are the only commits in the
branch this audit lives in. The dispatch also said:

> Part 2 (docs/ audit): this is a REPORT in your final response, not a
> commit — unless you want to also save it as a new doc (e.g.
> `docs/DOCS-AUDIT-2026-09-23.md`), which is fine, but make clear in your
> report that doing so is optional/your own call, not a requirement.

Saving this audit to `docs/DOCS-AUDIT-2026-09-23.md` is the operator's call.
The 13 deletion candidates are recommendations, not actions.