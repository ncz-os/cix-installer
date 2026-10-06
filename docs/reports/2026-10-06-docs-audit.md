# NCZ-OS documentation audit — 2026-10-06

**Author:** Jason Perlow <jperlow@gmail.com>
**Branch:** `docs/audit-20261006` of `cix-installer`, based on the current
`integration/cygnus-26.10-2026-10-03` tip `bb295884`. Audit only: no end-user doc
was modified in this item.

This report covers the public projects in the GitLab group `ncz-os` (41 projects,
all public visibility, enumerated 2026-10-05 via the GitLab API) and the
ARGONAS-only source repos for the plugin / screensaver / artist-pack stack.
Companion file: `docs/screenshots-shotlist.tsv` (the screenshot shot-list).

Supersedes `docs/DOCS-AUDIT-2026-09-23.md` (the previous docs audit, run against
commit `79273b5`).

---

## 1. Authoritative current state (verified for this audit)

| Fact | Value | Verified from |
|---|---|---|
| Integration tip | `integration/cygnus-26.10-2026-10-03` @ **`bb295884`** on GitLab and ARGONAS (verified 2026-10-06: `git ls-remote` on both remotes) — the r2 re-integration branch was **fast-forward-merged into integration** after this audit's worktree was cut at `a26f60d3` | `merge-base --is-ancestor a26f60d3 bb295884` = true (FF, 34 commits) |
| Re-integration tip | `feat/cygnus-reintegrate-r2-20261005` @ `bb295884` — now identical to the integration tip | item AE report; `git ls-remote` on both remotes |
| Kernel policy (machine-readable) | `STABLE_BASE=7.2.9`, `EDGE_BASE=7.3.0-rc6`; edge = non-default, bootable, RC-only | `assets/kernel/KERNEL-POLICY` |
| amd64 stable KVER | `7.2.9-2-t2-trixie` | `assets/kernel/amd64-stable/KVER` |
| amd64 edge KVER | `7.3.0-rc6-1-t2-edge-aerfix` (AER-revert; the `7.3.0-rc6-2-t2-edge` quirk build is **not** shipped) | `assets/kernel/amd64-edge/KVER`, `KERNEL-POLICY` comment |
| arm64 mainline / edge | `r280-7.2.9-sky1-ncz-20261003` / `r282-7.3.0-rc6-sky1-ncz-20261004` (edge non-default) | `assets/kernel/mainline`, `assets/kernel/edge` |
| Screensavers published | `ncz-screensavers 0.8.9` (amd64+arm64), `ncz-screensavers-gtk4-reference 0.8.9` (all) from the NCZ apt repo (Buildkite primary, R2 backup) | item AC report; deb SHAs there |
| Singularity desktop published | `ncz-singularity-desktop 20261005+u20260925.g5c75e563d10e+deps1` (amd64+arm64) | item AC report |
| Screensaver package source | `ncz-screensavers` branch `release/0.8.9-apache-20261005` @ `f7e692c` (= tip of its `integration/cygnus-26.10-2026-10-03`); README says **74** hacks; `debian/changelog` tops out at 0.8.9 (Apache-2.0) | repo `ncz-screensavers.git` |
| Screensaver default-branch mismatch | the **default** branch of `ncz-screensavers.git` is `fix/gpu-tier-mali-g720-2026-09-30` @ `e47547c` (2026-09-30), whose README still says **84** hacks | `git ls-remote --symref` |
| Screensaver Settings plugin | `ncz-screensavers-plugin` (source: `ncz-screensavers/plugin/screensaver/`). **Not yet published** to the NCZ apt repo (item AC §5.5: version 0.3.16 explicitly deferred to a later publication). `post-install/59-ncz-screensavers-pkg.sh` and `manifests/install-extra.pkgs` already seed it; `build/verify-installed-target.sh` asserts it is installed | worktree hooks/manifests/verifier; item AC report |
| Screensaver tiers | weak / mid / strong GPU tiers; default saver **Black Hole** | `ncz-screensavers` 0.8.9 README + `docs/releases/26.10-cygnus.md` §3 |
| Hook 58 state | retired on the live tree (commit `bb295884`, now the integration tip): `post-install/58-screensaver-chooser.sh` and `assets/screensaver-chooser/` (84-row `hacks.tsv`) deleted; `docs/SCREENSAVER-CATALOGUE-RETIREMENT.md` + `post-install/62-cygnus-screensaver-default.sh` added. At `a26f60d3` (the pre-reintegrate tip) they still exist. | item AE report; verified diff `a26f60d3..bb295884`; `ls post-install/` at `bb295884` |
| Hook 57 | `post-install/57-screensaver.sh` still present on both branches (held legacy; AE named only hook 58) | worktree `ls post-install/` |
| T2 DKMS modules | `t2smc`, `t2gmux`, `t2smp` shipped; `t2thunderbolt` off by default | brief; `post-install/56-t2-dkms.sh` present on integration |
| Branding | Cygnus 26.10 (magenta/cyan on violet-black), `branding/cygnus/`; 7 shipped wallpapers in `assets/branding/wallpaper/` incl. `06-cygnus-vacuum-decay-2k.jpg` and one retired-codename file `07-maximilian-blackhole-2k.jpg` | worktree `branding/cygnus/`, `assets/branding/wallpaper/` |

State note for this audit:

- **Current integration** = `bb295884`: hook 58 and `assets/screensaver-chooser/`
  are retired on the live tree; `post-install/62-cygnus-screensaver-default.sh` and
  `docs/SCREENSAVER-CATALOGUE-RETIREMENT.md` exist; the package catalogue + Settings
  plugin is the only screensaver UX.
- The audit pass began at the then-tip `a26f60d3` (hook 58 and the legacy chooser
  still present there); the fast-forward was discovered during the audit and this
  branch was re-based onto `bb295884`. File:line citations were verified at
  `a26f60d3` and re-verified at `bb295884` for every file the 34-commit delta
  touches. The delta touches only these doc files (verified by diff):
  `docs/BOOT-SPEED.md` (new), `docs/REFIND-THEME.md` (new),
  `docs/SCREENSAVER-CATALOGUE-RETIREMENT.md` (new),
  `docs/reports/2026-10-04-panthor-vulkan-dmabuf.md` (new),
  `docs/PLATFORM-SPLIT-DESIGN.md` (one retired-example line removed),
  `docs/SINGULARITY_ISO_PLAN.md` (Cygnus accent line refreshed),
  `docs/releases/26.10-cygnus.md` (rEFInd theme rows expanded),
  `docs/platform-inventory.tsv`. None of the findings in §4–§5 is invalidated by
  that diff; the `docs/releases/26.10-cygnus.md` line numbers in §4.3 shift by at
  most ±2 after the new rows. The two new design docs (`BOOT-SPEED.md`,
  `REFIND-THEME.md`) are current build/brand docs and were not part of this audit's
  per-doc pass.

---

## 2. Methodology

1. **Group enumeration** — `GET https://gitlab.com/api/v4/groups/ncz-os/projects?include_subgroups=true&per_page=100` on 2026-10-05: **41 projects**, all `public` visibility (full list in `evidence/gitlab-projects.json`, item dir).
2. **Repo state** — each public repo cloned or checked against its GitLab default branch; each ARGONAS repo checked with `git ls-remote` against `/mnt/datapool/git/`. No remote was modified.
3. **Doc walk** — every `.md` in `cix-installer` `docs/` + both READMEs read and cross-checked against the state table above; grep for banned end-user tokens (fleet host names, `192.168.x`, `/mnt/` paths, `argonas:` paths, internal process talk).
4. **Link check** — Python pass over all `.md` files in `docs/` + `README.md` + `README.zh-CN.md`: every `](path)`, `![](path)` and `<img src=path>` local reference resolved against the tree (script + output in item-dir `evidence/`). Result: **136 local references, 4 broken** (§5.1).
5. **Image audit** — every referenced image checked for existence; every image under `docs/screenshots/`, `docs/attachments/`, `assets/branding/screenshots/` checked for references (script + output in item-dir `evidence/`). Result: 1 missing referenced image, 9 orphaned images (§5.2).
6. **Pages / wikis** — `https://ncz-os.gitlab.io/` returns `302` to the GitLab auth wall (no public Pages content); the wikis API returns `[]` for `cix-installer`, `zoder`, `meta-cix`, `ncz-tools`, `linux-cix` (no wiki pages on any sampled repo).
7. **Published-repo state** — the NCZ apt repo state (which packages/versions are served) is taken from item AC's verified publication report; no package was re-verified from this machine in this item.

### Doc rules applied (operator)

End-user docs must contain **no** internal fleet references (fleet host names such as
STUDIO/ARGOS/HYDRA/ULTRA/MEDUSA/CHIMERA/PEGASUS/PROTEUS/CERBERUS/ACHILLES, `192.168.x`
addresses, `/mnt/datapool` or `argonas:` paths, passwords/tokens), **no** internal
process talk (opencode/zoder/Hive/MNEMOS-as-memory-system, "the agent that built this"),
**no** debugging-journey narrative, **no** AI/Claude attribution. Product names that
happen to resemble host names are **not** flagged: Radxa Orion O6N, Minisforum MS-R1,
Orange Pi 6 / 6 Plus, CIX Sky1, Apple T2 Mac. This audit report itself quotes the
offending lines so a future fix pass can locate them; that quoting is how the finding
is stated, not an endorsement.

Only verified statements appear below. Where something could not be verified from
this machine, it is marked `TODO:`.

---

## 3. Group inventory — the 41 public `ncz-os` projects

### 3.1 NCZ-OS end-user surface (audited in depth, §4–§6)

| Project | Default branch @ head | Last activity | Doc state |
|---|---|---|---|
| `cix-installer` | `main` @ `0e075f57` (2026-09-29) is the public default but an **ancestor** of the live line `integration/cygnus-26.10-2026-10-03` @ `bb295884` (verified: `rev-list --count bb295884..main` = 0) | 2026-10-06 | Largely stale (§4) |
| `meta-cix` | `main` @ `2c0278a` (2026-09-17) | 2026-09-29 | Stale header + debugging-journal `PROGRESS.md` (§6.5) |
| `linux-cix` | `kernel-7.2.5-full-patched` @ `3862a088` (2026-09-11) | 2026-10-05 | No end-user docs (kernel tree) |
| `ncz-tools` | `main` @ `d37c847` (2026-07-08) | 2026-07-08 | Stale README (§6.6) |
| `ncz-wayland-screenhack` | `master` @ `2f06b47` (2026-08-17) | 2026-10-05 | Superseded design, not marked as such (§6.1) |
| `singularity-wallpaper-rotator` | `main` @ `ff32e44` (2026-08-29) | 2026-10-05 | Current, single-purpose plugin doc (§6.2) |
| `distro-core` | `main` (2026-07-08) | 2026-07-08 | Docs-only scaffold repo; README describes an extraction that has not happened (§6.7) |

### 3.2 Public but a different product line or infrastructure (spot-checked, not NCZ-OS end-user docs)

- **nclawzero claw family** (its own docs live in those repos): `zoder`, `zcon`, `tokenomics`, `mpf`, `pi-gen`, `cix-gen`, `meta`, `meta-base`, `debs` (no README), `linux-rpi` (no README, LICENSE only).
- **Agent memory / LLM infrastructure stack** (MNEMOS / GRAEAE / PANTHEON / Hive line): `mnemos`, `mnemos-stiphos`, `mnemos-rs`, `mnemosctl`, `mnemos-embedkit`, `mnemos-hot-rs`, `mnemos-bridge-{aider,anthropic,claude-connector,core,crewai,gemini,openai}`, `graeae`, `graeae-hive-mind`, `pantheon`, `charon`, `zepo`, `knemon`, `worker-hive-relay`, `mcp-stdio-rs`, `mcp-contracts`.
- **Governance:** `ncz-os-security-policy-project`.

None of the plugin / screensaver / artist-pack source repos below appear in this
public group — see §7 for the gaps that creates.

---

## 4. `cix-installer` — per-document findings (end-user docs)

Priorities: **P0** = must be fixed before the first 26.10 image is released (release
notes, README hero content); **P1** = visible regression in a doc a user lands on;
**P2** = cosmetic sweep. "Last updated" = last commit date touching the file on the
integration branch.

### 4.1 `README.md` (last updated 2026-09-30) — **P0**

The README names no 26.10 / Cygnus anywhere (verified: zero matches for `26.10` /
`Cygnus` in the file).

False claims (file:line → verified truth):

| Location | Stale claim | Verified truth |
|---|---|---|
| `README.md:59` | "NCZ-OS 26.7 'Maximilian' ships the Singularity desktop" | 26.10 "Cygnus" is the current line; no 26.10 image built yet (`docs/releases/26.10-cygnus.md` status row). Maximilian is history (`docs/RELEASE-HISTORY.md`). |
| `README.md:62` | "Current kernels (staged on `argonas:/mnt/datapool/yocto-shared/kernel-staging/`)" | Kernel numbers below are stale **and** the staging path is a fleet reference (doc-rule violation). |
| `README.md:66` | Stable: `7.2.7-sky1-ncz` (r274) / `7.2.7-2-t2-trixie` | `7.2.9-sky1-ncz` (r280, 2026-10-03) / `7.2.9-2-t2-trixie` |
| `README.md:67` | Edge: `7.3.0-rc4-sky1-ncz` (r273) / `7.3.0-rc4-2-t2-trixie` | `7.3.0-rc6-sky1-ncz` (r282, non-default) / `7.3.0-rc6-1-t2-edge-aerfix` (non-default, AER-revert) |
| `README.md:77` | "Latest release: [2026.08.27-v14]" | True only as "last *shipped* release of the 26.7 line"; the README must say 26.10 has no image yet and point at `docs/releases/26.10-cygnus.md` |
| `README.md:474`, `492`–`494`, `653`, `938` | `7.2.7-2-t2-trixie` / `7.3.0-rc4-2-t2-trixie` in the amd64 kernel sections (5 more occurrences) | `7.2.9-2-t2-trixie` / `7.3.0-rc6-1-t2-edge-aerfix` |
| `README.md:770` | "operator directive 2026-09-30: amd64 ships NO edge kernel because no validated amd64 7.3 kernel exists" | Superseded: `KERNEL-POLICY` now pins amd64 edge `7.3.0-rc6` (non-default, AER-revert). Also a `argonas:/mnt/datapool/...` path in the same row. |
| `README.md:99`, `104`, `109` | screenshots `desktop-sensor-panel.png`, `app-launcher.png`, `network-panel.png` | Files exist, but all three predate the current panel/launcher UI — **retake** (shot-1/2/3) |
| `README.md:253` | "hands-on validation on 2019–2024 hardware (PEGASUS: RTX 2060 laptop; HYDRA/ACHILLES: Ryzen 8700G desktops; PROTEUS/CERBERUS: current-generation Intel/AMD build hosts)" | Fleet host names — doc-rule violation; replace with plain board/chip descriptions |
| `README.md:261` | "Navi 1x, including MEDUSA's 5300M" | Fleet host name — keep only the chip model |
| `README.md:267` | "devices (PROTEUS/HYDRA/ACHILLES)" | Fleet host names — keep only the chip family |
| `README.md:884` | rescue hint "(`192.168.207.66/24`, gateway `192.168.207.1`) if DHCP fails" | `192.168.x` address — doc-rule violation; use a generic `<link-local or subnet>/24` form |
| `README.md:1142` | "[`gitlab.com/ncz-os/zoder`] — the coding and adversarial-review agent used to build this distribution" | Internal process talk in an end-user doc (zoder is a public repo, but the "agent used to build this" claim is process lore, not user content) — remove or reduce to a neutral build-from-source statement |

Missing topics:

- **Cygnus 26.10 branding** — described in `docs/releases/26.10-cygnus.md` and present in `branding/cygnus/`, but the README never names it (boot splash, rEFInd theme, wallpaper set).
- **The four new plugins the operator asked about** (desktop/sensors plugin, OCS wallpaper source, Bing wallpaper source with preferred-market, Artist Pack browser) — none are mentioned in the README. Their parts exist: `assets/wallpaper/ncz-wallpaper-ocs`, `assets/wallpaper/ncz-wallpaper-bing`, `assets/wallpaper/singularity-artist-pack-install` (+ `-inventory`), `post-install/49-artist-pack-browser.sh`, `post-install/45-wallpaper-rotator.sh`; the plugins themselves are in `singularity-plugins` (`sensors`, `wallpapers-ocs`, `wallpapers-bing`). No single end-user doc ties them together — see §8 gap G1.
- **The screensaver Settings plugin as the only screensaver UX** — the README is silent on how 26.10 screensavers are configured. Note the plugin package is not yet published (§1); until it is, the honest statement is "package catalogue + installer default; the Settings plugin lands with the next apt publication".
- **T2 DKMS module table** — `t2smc`/`t2gmux`/`t2smp` (with `t2thunderbolt` off by default) are mentioned in passing, not surfaced as a table in the T2 section.
- **Offline install / live apt update behaviour** — installer behaviour the operator named; the README's install section does not state the offline-mirror + live-apt-update model explicitly. TODO: verify the exact wording location after the P0 rewrite.

### 4.2 `README.zh-CN.md` (last updated 2026-09-23) — **P0**

Same content class as `README.md`, older by a week; the same P0 fix set applies.
Additionally:

| Location | Stale | Verified truth |
|---|---|---|
| `README.zh-CN.md:32`, `222` | `argonas:/mnt/datapool/yocto-shared/kernel-staging/` staging path | Fleet reference (same fix as README.md:62/477) |
| `README.zh-CN.md:115` | "前沿版 T2 构建…用 MEDUSA（已被重新指派为 T2 启动验证目标）完成真机启动测试" plus the `7.3.0-rc4-2-t2-trixie` kernel | Fleet host name **and** stale edge kernel (`7.3.0-rc6-1-t2-edge-aerfix` is the current edge) |

### 4.3 `docs/releases/26.10-cygnus.md` (last updated 2026-10-05 on the r2 rows; status content frozen at 2026-09-30, document version 1.0) — **P0**

The only 26.10 document. The r2 branch expanded its rEFInd theme rows (current); the
§3 status table itself is still frozen at 2026-09-30. False claims (line numbers
verified at the current integration tip `bb295884`):

| Location | Stale | Verified truth |
|---|---|---|
| `:164` | "plugin is the only UX … Release branch + package 0.7.1" | The published screensaver package is **0.8.9**; the plugin package is unpublished (item AC §5.5). Row must be re-verified at image-build time per the doc's own instruction. |
| `:165` | "84 native GLES3 savers … 35 hyprsaver, 36 xshadertoy, 12 classics" | 0.8.9 ships **74** savers (retirements since 0.7.x). |
| `:179`–`180` | "Sky1 kernel 7.2.8 / amd64 kernels 7.2.8 and 7.3.0-rc5" | `7.2.9-sky1-ncz` (r280); amd64 `7.2.9-2-t2-trixie` + edge `7.3.0-rc6-1-t2-edge-aerfix` |
| `:220`–`221` (at `bb295884`) | release-notes skeleton table: "Sky1 7.2.8 / 7.2.8 (T2)" | same kernel update |
| `:212` (at `bb295884`) | `<img src="../showcase/media/hero.jpg">` | **file does not exist** (broken reference; shot-4) |
| `:124` | "Tag the commit that was built, then push (ARGONAS first, then GitLab)" | Fleet reference in a release-notes doc; reword to "publish the tag to the canonical remotes" |
| `:14` | "The same decision is stored in MNEMOS under `projects/brand-hierarchy`" | Internal memory-system reference in an end-user-facing release doc; remove |
| `:155`, `:168` | "LEAD 3", "LEAD 20" role labels | Internal role terminology; reword to branch names only |

The rest of the doc (the name, the three referents, §4 theme/art tables) is current
and correct.

### 4.4 `docs/SOURCE-RELEASES.md` (last updated 2026-08-18) — **P1** (entirely 26.7/v12)

| Location | Stale | Verified truth |
|---|---|---|
| `:32` | "Components built from source in 2026.08.18-v12" | The v12 26.7 table; 26.10 has no shipped image yet |
| `:36` | kernel `7.2.0-sky1-ncz`, "286 patch files" | current arm64 mainline `7.2.9-sky1-ncz` (r280) |
| `:40` | `ncz-singularity-desktop 9.0.1-ncz3` from upstream packaging | now `ncz-singularity-desktop 20261005+u20260925.g5c75e563d10e+deps1` from the NCZ apt repo (published 2026-10-05) |
| `:73`–`78` | "Open item for 2026.08.18-v12 — version-string mismatch" | superseded by the 26.10 line |
| `:84` | "NCZ-OS 26.7 ships **one** kernel: `7.2.0-sky1-ncz`" | amd64 now has two (stable + non-default edge); arm64 has mainline + non-default edge |

`docs/SOURCE-RELEASES.zh-CN.md` (translation) goes stale with it; do not rewrite independently.

### 4.5 `docs/RELEASE-HISTORY.md` (last updated 2026-08-18) — **P2**

| Location | Stale |
|---|---|
| `:3` | "Per-release detail for NCZ-OS ISOs up to and including 26.7 'Maximilian'" — redirect to `docs/releases/` is right, but the header must stop naming Maximilian as the current line (current: 26.10 Cygnus, see `docs/releases/26.10-cygnus.md`) |
| body (per-release entries) | historical — keep; do not rewrite |

### 4.6 `docs/INSTALLER-BOOT-UX.md` (last updated 2026-09-29) — **P1**

| Location | Stale | Verified truth |
|---|---|---|
| `:3` | "Status 2026-09-29" | still the newest installer-UX doc; add "superseded by the 26.10 reinstall" line |
| `:22`–`23` | dialog frame mockup "NCZ-OS 26.7 Maximilian - name this computer … build c6806798" | the 26.10 image will frame as `NCZ-OS 26.10 Cygnus …`; `c6806798` is a 2026-09 build |
| `:32`, `:36` | same mockup (optional-components dialog, `build c6806798` row) | same |
| `:8` | "photos … were of image 18e8a14 (and 7e1d9c2)" | very stale image references; historical, keep with a date stamp |

### 4.7 `docs/OCS-WALLPAPER-BACKEND.md` (last updated 2026-09-12) — **P1**

`docs/OCS-WALLPAPER-BACKEND.md:3`: "Status: implemented backend/tooling. The GTK
browser is intentionally not part of this task." — the front end **has** shipped as
the `wallpapers-ocs` plugin (`singularity-plugins/wallpapers-ocs/wallpapers_ocs.vala`)
plus `assets/wallpaper/ncz-wallpaper-ocs`. Flip the status line; the rest of the doc
(commands, paging, per-image sidecar JSON) is current.

### 4.8 `docs/WALLPAPER-BING-PREFETCH.md` (last updated 2026-09-29) — **P1**

- `:3`–`4` names the two feature branches (`feat/wallpapers-bing-prefetch-2026-09-29`,
  `feat/wallpapers-bing-market-prefetch-2026-09-29`). The shipped code is on
  `integration/cygnus-26.10-2026-10-03` / the r2 branch; replace branch pointers with
  the integration tip or just the behaviour description.
- **Fleet references:** `:10` ("Measured on CHIMERA, MEDUSA and PEGASUS"),
  `:15`–`17`, `:34`, `:92` ("Plugin built on PROTEUS against the libsingularity
  installed on CHIMERA"), `:99`–`103` (per-host test table: MEDUSA/CHIMERA/PEGASUS
  rows). Replace with "test machines" / board descriptions.
- The behavioural content (helper, retry-on-75, preferred-market resolution,
  network-change handling) is correct and current.

### 4.9 `docs/WALLPAPER-PACKS.md` (last updated 2026-09-23) — **P1**

`:3`: "Status: DESIGN, not implemented … Written 2026-08-19." — wrong on the UI:
the desktop UI shipped (the `wallpapers-ocs` / artist-pack browser work landed in
September–October; the doc's own §6 describes the shipped schema). The per-sample
set count in §1 (17 images) does not match the shipped `assets/branding/wallpaper/`
set (7 curated + the published artist packs in `contrib/`). Rewrite §1 + status
header; the JSON schema and OCS-vs-curated distinction still hold.

### 4.10 `docs/NEXT_ISO.md` (last updated 2026-09-24) — **P0**

| Location | Stale | Verified truth |
|---|---|---|
| `:121`–`123` | "Current release … NCZ-OS 26.7 'Maximilian', installer 2026.08.18-v12. One kernel: 7.2.0-sky1-ncz. The 7.0.12 channel has been removed" | current line is 26.10 Cygnus (no image yet); kernels per §1 table |
| `:79`–`80` (approx) | "Real, current amd64 status (2026-09-22)" block | stale date; TODO: re-verify against the current amd64 writer state before the 26.10 build |

The gate procedure content is current.

### 4.11 `docs/DUAL-ARCH-PARITY.md` (last updated 2026-09-29) — **P1**

| Location | Stale |
|---|---|
| `:6` | "Branch: `release/dual-arch-2026-09-29`" — that branch is merged into `integration/cygnus-26.10-2026-10-03`; point at the integration tip |
| `:67` | "Stage-2 Sky1 ISO build fixes, ULTRA container runbook" — fleet host name; reword to "aarch64 build-host runbook" |
| `:118` | "the newest gated image (which must exist in the ARGONAS archive)" — fleet reference; reword to "the build-host archive" |
| `:84`, `:106` | "real O6N/MS-R1" — product names, OK, no change |

### 4.12 `docs/SINGULARITY_ISO_PLAN.md` (last updated 2026-07-26) — **P2** (already marked historical)

Header marks it a historical planning record — good. Remaining fleet references:

| Location | Stale |
|---|---|
| `:42` | "built on `.66` … Store the artifact on ARGONAS (`/mnt/datapool/archives/ncz/singularity/`) + fetch at ISO-build" — fleet IP shorthand + fleet name/path |
| `:85` | "6. Commit (argonas→gitlab), ship ISO to `.4`." — fleet reference + IP shorthand |

### 4.13 `docs/AI-ML-STACK.md` (last updated 2026-08-18) — **P2**

| Location | Stale |
|---|---|
| `:7`–`8` | "Scope note (26.7). NCZ-OS ships one kernel, `7.2.0-sky1-ncz`" → rebrand to 26.10 and the 7.2.9 line |
| `:36` | "✅ validated on the `.66` reference board" — fleet IP shorthand |
| `:250` | "All numbers measured on the `.66` board" — same |
| `:314` | "Logical CPU mapping on the `.66` reference board" — same |

The NPU/GPU substance is still correct per the integration tip.
(`docs/AI-ML-STACK.zh-CN.md` is its translation; same fixes.)

### 4.14 `docs/DESIGN-RATIONALE.md` (last updated 2026-08-18) — **P2**

| Location | Stale |
|---|---|
| `:5` | title "NCZ-OS 26.7 — Design Rationale" → 26.10 (the 26.7 decisions inherit; mark that) |
| `:31` | "Orion O6N, CIX Sky1, kernel 7.2.0-rc7-sky1-ncz" — old kernel in the scope note |

### 4.15 `docs/NCZ-OS-ORGANIZATION.md` (last updated 2026-08-18) — **P2**

| Location | Stale |
|---|---|
| `:3`–`8` | status header: historical plan, multi-variant portion obsolete — accurate; mark the whole doc superseded by `docs/PLATFORM-SPLIT-DESIGN.md` and link `docs/releases/26.10-cygnus.md` for the brand |
| `:22`, `:42` | "GitHub + Codeberg (+ the self-hosted ARGONAS bare remotes) are mirrors" — fleet reference in an end-user-facing organisation doc |
| `:85` | "builders pull `distro-core` as a **git submodule**" — no code extraction has happened (the public `ncz-os/distro-core` repo is a docs-only scaffold, §6.7); mark `P3`–`P6` deferred |

### 4.16 `docs/PLATFORM-SPLIT-DESIGN.md` (last updated 2026-09-29) — **P2**

| Location | Stale | Verified truth |
|---|---|---|
| `:3`–`5` | "Status: design (phase A) plus … phase C lands on a branch based on the dual-arch release branch" | the dual-arch branch is merged into integration; phase B is shipped on integration, phase C has not landed |
| `:55` | "Snapshot: 42 common, 14 mixed, 22 sky1 and 5 amd64 hooks; 317 rows cover all 2,500+ tracked files" | current `docs/platform-inventory.tsv` is **388** lines (at `bb295884`) |
| `:107`–`110` | `NCZ-PLATFORM-GUARD` description | guards verified in place (`grep -l NCZ-PLATFORM-GUARD post-install/` matches the amd64/sky1 hooks) |

### 4.17 Docs verified current (no edit needed)

- `docs/SUPPORTED-FIRMWARE.md` (2026-08-22) — policy + board table current.
- `docs/REMOTE-ACCESS.md` (2026-08-18) — matches current `post-install/31-remote-access.sh` / `36-telemetry.sh` behaviour.
- `docs/HW-VIDEO-DECODE-STATUS.md` (2026-09-22) — its own deferral disclaimer (VA-API route, Chromium HEVC untested) is still true; only the "Measured: 2026-08-05" date could gain a re-confirmation line.
- `docs/releases/2026.08.18-v12.md`, `-v13.md`, `2026.08.27-v14.md` — historical release notes; keep as-is.

### 4.18 Internal / not end-user docs (out of scope for the doc rules; noted for completeness)

`docs/KERNEL-BUILD-AND-INSTALL.md`, `docs/KERNEL-BOOT-TESTING-PROCEDURE.md`,
`docs/KERNEL-BUILD-YOCTO.md`, `docs/KERNEL-WARNINGS-72.md`,
`docs/ARM64-IMAGE-BUILD.md`, `docs/ARM64-IMAGE-RESULTS-*.md`,
`docs/INSTALLER-BOOT-TIMELINE-2026-09-29.md`, `docs/OTA-DKMS-HEADER-FIX-2026-08-21.md`,
`docs/ENGINEERING-EFFORT.md`, `docs/HANDOFF-embedding-fingerprint-protocol.md`,
`docs/MNEMOS-NPU-EMBEDDINGS.md`, `docs/NPU-USAGE-GUIDE.md`, `docs/EMBEDDING-MODELS.md`,
`docs/INFERENCE_LIMITS.md`, `docs/MODELSCOPE-MODELS.md`, `docs/SKY1-R278/R279-SUPERVISED-BOOT-TEST.md`,
`docs/VARIETY-FEATURE-DIFF-2026-09-25.md`, `docs/ISO-BUILD-GUARDRAILS.md`,
`docs/CUDA-DYNAMIC-INSTALL.md`, `docs/NCZ-SKY1-AUDIO-AUTOSWITCH.md`,
`docs/DRIVER_FIDELITY_72.md`, `docs/HOW-DID-WE-GET-HERE*.md`, `docs/upstream/`,
`docs/upstream-patches/`, `docs/superpowers/`, `docs/reports/`, `docs/installer-ux/`.

These carry the bulk of the fleet references found in the repo (build runbooks,
incident reports, patch notes). They are internal by nature and are **not** flagged
under the end-user rule; if the operator wants "no fleet references anywhere",
`docs/reports/` and the build runbooks need a separate sweep (open question Q3).

---

## 5. Link and image audit (`cix-installer`)

### 5.1 Broken local links (verified)

| Doc | Line | Reference | Status |
|---|---|---|---|
| `README.md` | 172 | `docs/AMD64-PACKAGE-AUDIT.md` | **broken** — file not present on the integration branch |
| `README.md` | 469 | `docs/AMD64-PACKAGE-AUDIT.md` | **broken** (second occurrence) |
| `docs/releases/26.10-cygnus.md` | 212 (at `bb295884`) | `../showcase/media/hero.jpg` | **missing image** — `docs/showcase/media/` has `blackhole-*.webp` stills but no `hero.jpg` (shot-4) |
| `docs/reports/2026-09-30-pegasus-nvidia-egl-rescue.md` | 6 | `/mnt/datapool/projects/ncz-session-2026-09-29/reports/pegasus-validate.md` | **broken + fleet path** (internal report; fix = sibling file or remove) |

136 local references checked in total; the checker flagged 7, of which 3 are this
report's own literal examples quoted in the methodology text — **4 genuinely broken**.
All `https://` links were **not** fetched from this machine (out of scope); the
`gitlab.com/ncz-os/...` URLs referenced from end-user docs point at real public
projects (spot-checked via the group listing).

### 5.2 Referenced images that are stale or missing

| Image | Referenced from | Status |
|---|---|---|
| `assets/branding/screenshots/desktop-sensor-panel.png` | README.md:99 | exists; UI changed — **retake** (shot-1) |
| `assets/branding/screenshots/app-launcher.png` | README.md:104 | exists; UI changed — **retake** (shot-2) |
| `assets/branding/screenshots/network-panel.png` | README.md:109 | exists; UI changed — **retake** (shot-3) |
| `docs/showcase/media/hero.jpg` | 26.10-cygnus.md:212 (at `bb295884`) | **missing** — new capture (shot-4) |
| `docs/screenshots/bing-browse-en-US.png`, `bing-browse-ja-JP.png`, `bing-settings-preferred-market.png`, `bing-source-populated-first-login.png` | none (orphaned) | 2026-09 Bing evidence — **stale/orphaned**; preferred-market + first-login replaced by shot-7/shot-8 |
| `docs/screenshots/wallpaper-rotator-before/after-2026-08-21.png` | none (orphaned) | pre-26.10 rotator evidence — **stale** |
| `docs/attachments/o6n-desktop-{brandon-perlow,ncz-wallpaper-active,singularity-default}-2026-08-21.png` | none (orphaned) | 26.7-era desktops — **stale**; retake as shot-9 |
| `assets/branding/wallpaper/ncz-wallpaper-07-maximilian-blackhole-2k.jpg` | README gallery + v12/v13/v14 notes | exists, but the file name carries the **retired** 26.7 codename; rename or retire for 26.10 |

`assets/branding/wallpaper/ncz-wallpaper-01..06-2k.jpg` and the published artist-pack
sets under `contrib/` are fine.

---

## 6. Other public `ncz-os` projects

### 6.1 `ncz-wayland-screenhack` (master @ `2f06b47`, 2026-08-17)

`README.md` (33 lines) documents the 2026-08 round-1..4 design (wlr-layer-shell
overlay + ext-session-lock two-surface design, "Target: labwc 0.9.5 / wlroots
0.20.2"). The lock-protected branch became the production path for `ncz-screensavers`
(the published 0.8.9 engine); this repo is now historical and says nothing about that.
**P1 (public surface):** add a one-paragraph status header: "superseded — the
production engine ships as the `ncz-screensavers` package; this repo is the 2026-08
design origin." Labwc/wlroots versions are design targets, not verified ship targets —
mark as such. `ROUND1..4_TASK.md` files are internal task notes; leave.

### 6.2 `singularity-wallpaper-rotator` (main @ `ff32e44`, 2026-08-29)

README is current and accurate (single-purpose timer plugin; `dev.sinty.plugin.wallpaper-rotator`
settings). It does not mention the Bing prefetch or OCS plugins — correct, those are
separate plugins. No change needed. **P2 (optional):** one line pointing to the
26.10 wallpaper stack (Bing/OCS/Artist Pack) so users find the new sources.

### 6.3 `zoder` (master @ `f7849fd`, 2026-10-05)

841-line README, self-contained, no fleet references (verified by grep). Not an
NCZ-OS end-user doc (it is its own tool's doc). No change needed. Note: `cix-installer`
README.md:1142 still makes the process-talk claim about it (§4.1).

### 6.4 `linux-cix` (default `kernel-7.2.5-full-patched` @ `3862a088`, 2026-09-11)

Kernel source tree, no README, no end-user docs. That is acceptable **only if**
kernel docs live in `cix-installer` (`kernel-source/SOURCE.md`, `docs/SOURCE-RELEASES.md`)
— which they do. **Gap note G4:** the default branch name (`kernel-7.2.5-full-patched`)
predates the 7.2.9 line; a user cloning the default gets an old kernel. Consider
retargeting the default branch at the next kernel release.

### 6.5 `meta-cix` (main @ `2c0278a`, 2026-09-17) — **P1**

| Location | Stale | Verified truth |
|---|---|---|
| `README.md:6`–`7` | "The hardware is not in hand yet, so this repository is intentionally a bootstrap scaffold" | MS-R1/O6N have been in production for months (26.7 line); the header is false |
| `PROGRESS.md` | entire file | debugging-journal narrative ("resumed iterations", "correction of prior fantasies, Round 2", `git reflog` forensics) with `192.168.207.101` root-SSH references — violates the doc rules; move to an internal incident report or delete |
| `PORTING-7.2.md`, `docs/REBASE-SLIM-PLAN-7.2.md` | — | current |

### 6.6 `ncz-tools` (main @ `d37c847`, 2026-07-08) — **P1**

| Location | Stale | Verified truth |
|---|---|---|
| `README.md:3`–`8` | "⚠️ Status: Alpha / experimental … part of the nclawzero claw-family experimental set … unfinished and not yet recommended for production use" | `ncz/Cargo.toml` is `version = "0.4.0"` and the CLI ships on the image; the disclaimer is stale |
| `README.md` members table | lists `zterm/` | `zterm` was removed (commit `e2ec792` "remove zterm (superseded by zerocode)"); only `ncz/` exists in the tree |
| `README.md:5`–`6` | links `gitlab.com/nclawzero/ncz-tools` and `gitlab.com/perlowja/zterm` | canonical location is `gitlab.com/ncz-os/ncz-tools`; the zterm link is dead product lore |

`ncz/README.md` describes the actual 0.4 CLI surface — current.

### 6.7 `distro-core` (public, 2026-07-08) — **P2 (new finding)**

The public repo contains only `README.md` (+ zh-CN) and `docs/NCZ-OS-ORGANIZATION.md`
(a copy). The README describes "the shared, hardware-agnostic core of the NCZ
distribution" with "What's in the box" content, and its "Start here" links point at
`cix-installer` docs — but no code has been extracted (verified: no source
directories). Add a status header: "scaffold — the extraction described here has not
happened; see `cix-installer` for the current tree." `cix-installer`
`docs/NCZ-OS-ORGANIZATION.md:85` (§4.15) makes the same unverified claim.

### 6.8 Public repos with no end-user doc at all

- `debs` — no README (packaging CI only). Fine (internal packaging).
- `linux-rpi` — LICENSE only. Fine (placeholder).
- The claw-family repos (`meta`, `meta-base`, `pi-gen`, `cix-gen`, `zcon`, `tokenomics`,
  `mpf`, `zoder`) carry their own docs for their own product line — out of scope for
  NCZ-OS end-user docs, no findings.

---

## 7. ARGONAS-only repos: the plugin / screensaver / artist-pack stack — gaps

None of these repos is in the public `ncz-os` group (verified against the 41-project
listing). Their public documentation surface is **zero**; user-facing coverage must
live in `cix-installer`.

| Repo (ARGONAS path) | State | Ships | Public doc surface |
|---|---|---|---|
| `singularity-plugins.git` | `main` @ `d255d47`; newest work on `upstream-ready/bing-prefetch-20261005` (`5f3015d`) and `upstream-ready/bing-preferred-market-20261005` (`bf374a3`), both 2026-10-05 | `sensors` (desktop/sensor plugin), `wallpapers-bing` (preferred market, prefetch), `wallpapers-ocs`, `wallpapers-stock` + upstream plugin set | **none** — no per-plugin READMEs (verified: plugin dirs contain only `.vala`/`meson.build`/`.plugin`); top-level README targets the upstream Singularity audience (GPL-3.0, upstream tracker) |
| `singularity-desktop.git` | `master` @ `dc716bc` (2026-09-30) | the shell itself (plugins host) | upstream-facing README only; NCZ user coverage belongs in `cix-installer` |
| `singularity-shell.git` | no `main`; newest: `upstream-ready/launcher-popup-20261005` (`dc15f67`), `upstream-ready/plain-contrast-20261005` (`9f502f9`) | shell sources incl. wallpaper attribution quadrant work | none |
| `libsingularity.git` | no `main`; two fix branches (2026-08-16) | toolkit | none |
| `ncz-screensavers.git` | default branch `fix/gpu-tier-mali-g720-2026-09-30` @ `e47547c` (**README says 84 hacks**); release branch `release/0.8.9-apache-20261005` @ `f7e692c` (**README says 74**, changelog to 0.8.9) | engine + launcher + idle timer + `plugin/screensaver` (the Settings plugin source) | none public; the 0.8.9 source tree carries a full README — **the public group has no screensaver repo at all** |
| `wayshade.git` | `main` @ `b22c6c3` (2026-09-29): "ncz-screensavers 0.7.3: first public source release" | 0.7.3-era source snapshot (README: 79 savers) | none; superseded by 0.8.9 — do not cite from user docs |
| `artistpack.git` | `master` @ `adc9efc` | the ArtistPack open standard: CLI, backend, spec, `docs/pak-package-format.md`, licenses | none public — the standard ships user-facing (Artist Pack browser) but has **no public repo and no public docs** (gap G3) |

Gaps:

- **G1 — no end-user doc for the four plugins.** Desktop/sensors plugin, OCS source,
  Bing source (preferred market), Artist Pack browser: four partial docs in
  `cix-installer` (`docs/OCS-WALLPAPER-BACKEND.md`, `docs/WALLPAPER-BING-PREFETCH.md`,
  `docs/WALLPAPER-PACKS.md`, plus the `assets/wallpaper/singularity-artist-pack-install`
  script headers) and no single user-facing page. A "Wallpapers and plugins" page in
  `cix-installer` would close it.
- **G2 — `ncz-screensavers-plugin` unpublished.** The 26.10 screensaver UX the docs
  describe (Settings plugin, Black Hole default) depends on a package that is not in
  the NCZ apt repo yet (item AC §5.5). `post-install/59-ncz-screensavers-pkg.sh` no-ops
  it and `build/verify-installed-target.sh` asserts it — so until publication, images
  either fail the verifier or ship without the settings UX. Publish before the first
  26.10 image, or adjust the verifier/hook in the same commit.
- **G3 — ArtistPack standard has no public home.** `artistpack.git` (ARGONAS) has a
  complete spec + governance + docs, but no public repo and no mention in any public
  `ncz-os` doc. If the standard is meant to be open (its own README says
  "an open distribution standard"), publish the repo and link it from the artist-pack
  user doc.
- **G4 — `linux-cix` default branch predates the shipping kernel** (§6.4).
- **G5 — `ncz-screensavers` default branch is the stale one** (84-hack README vs the
  74-hack 0.8.9 release branch). Retarget the default branch at the release line.

---

## 8. GitLab Pages and wikis

- `https://ncz-os.gitlab.io/` → `302` to the GitLab auth wall (verified 2026-10-06).
  No public Pages content exists for the group.
- Wikis: the wikis API returns `[]` for `cix-installer`, `zoder`, `meta-cix`,
  `ncz-tools`, `linux-cix` (verified). No wiki pages to audit.
- **Gap G6:** if a public doc site is intended (the operator asked about
  "ncz-os.gitlab.io redirects"), none exists today; the group's public documentation
  surface is the README/docs trees of the public repos only.

---

## 9. Screenshot shot-list

Full TSV: `docs/screenshots-shotlist.tsv` (columns: `id`, `what`, `used_in`,
`hw_or_session`, `capture_plan`, `priority`). Summary:

| id | shot | action | priority |
|---|---|---|---|
| shot-1 | `desktop-sensor-panel.png` (README.md:99) | retake — sensor panel UI changed | P0 |
| shot-2 | `app-launcher.png` (README.md:104) | retake — launcher UI changed | P0 |
| shot-3 | `network-panel.png` (README.md:109) | retake — panel UI changed | P0 |
| shot-4 | `docs/showcase/media/hero.jpg` (26.10-cygnus.md:212 at `bb295884`) | **new** — Black Hole in Cygnus palette, strong-tier GPU | P0 |
| shot-5 | Cygnus default wallpaper on the 26.10 desktop | **new** | P1 |
| shot-6 | Screensaver Settings plugin page (Black Hole selected) | **new** — blocked until `ncz-screensavers-plugin` is published (G2) | P1 |
| shot-7 | Bing row with preferred-market dropdown (replaces `bing-settings-preferred-market.png`) | replace | P1 |
| shot-8 | Bing source populated at first login (replaces `bing-source-populated-first-login.png`) | replace — needs a fresh install | P1 |
| shot-9 | The three 2026-08-21 O6N desktop attachments | retake ×3 (incl. one Artist-Pack state) | P1 |
| shot-10 | Cygnus rEFInd boot menu | **new** — KVM/spare-board boot test only | P2 |
| shot-11 | Cygnus boot splash in use | **new** — KVM/spare-board boot test only | P2 |
| shot-12 | `wallpapers-ocs` first-run browse screen | **new** | P2 |

Capture discipline (all shots): passive screen-capture from a running session or a
disposable KVM boot test; **no** reboots or config edits on hosts in service; nothing
under `/sys/kernel/debug`; never touch GPU/PCI sysfs control files. Fresh-install
shots (shot-8, shot-9-artist-pack) run on a spare board or KVM, not a host in service.

**This item did not retake any screenshot** — the shot-list is the deliverable.

---

## 10. Prioritized fix list

### P0 — blocks the first 26.10 image / its release notes

1. `README.md` + `README.zh-CN.md`: kernel table (7.2.9-2-t2-trixie / 7.3.0-rc6-1-t2-edge-aerfix / 7.2.9-sky1-ncz / 7.3.0-rc6-sky1-ncz), "26.10 has no image yet" line, and removal of every fleet reference (`argonas:/mnt/...` ×3 EN + ×2 ZH, PEGASUS/HYDRA/ACHILLES/PROTEUS/CERBERUS/MEDUSA, `192.168.207.66`) and the zoder process-talk line; retake shots 1–3.
2. `docs/releases/26.10-cygnus.md`: fix the §3 status table (74 savers, package 0.8.9, kernel 7.2.9/7.3.0-rc6), the skeleton kernel cells, the missing `hero.jpg` (shot-4), the MNEMOS reference (:14), the ARGONAS push step (:124), the LEAD role labels.
3. `docs/NEXT_ISO.md`: rewrite the "Current release" block to 26.10.
4. `ncz-screensavers-plugin` publication + verifier/hook alignment (G2) — a build blocker, listed here because the P0 docs cannot honestly describe the screensaver UX until it resolves.

### P1 — visible regression

5. `docs/SOURCE-RELEASES.md` (+ zh-CN): rewrite the component table against 26.10 (kernel r280, apt-published Singularity `…+deps1`, `ncz-screensavers` 0.8.9).
6. `docs/WALLPAPER-PACKS.md`: flip status header; fix ship-set counts; rewrite §1.
7. `docs/OCS-WALLPAPER-BACKEND.md`: flip the "GTK browser not part of this task" status (it shipped as the `wallpapers-ocs` plugin).
8. `docs/INSTALLER-BOOT-UX.md`: 26.10 Cygnus mockup frame, build-sha refresh, status line.
9. `docs/WALLPAPER-BING-PREFETCH.md`: branch pointers → integration tip; fleet names → "test machines" (:10, :15–17, :34, :92, :99–103).
10. `docs/DUAL-ARCH-PARITY.md`: merged-branch pointer (:6); ULTRA (:67); ARGONAS (:118).
11. `meta-cix/README.md`: drop "hardware not in hand"; `meta-cix/PROGRESS.md`: move to an internal incident report (doc-rule violation).
12. `ncz-tools/README.md`: drop the alpha/experimental disclaimer; remove `zterm` member; fix the `nclawzero/ncz-tools` URL.
13. `ncz-wayland-screenhack/README.md`: superseded header (§6.1).
14. `assets/branding/wallpaper/ncz-wallpaper-07-maximilian-blackhole-2k.jpg`: rename/retire for 26.10.
15. `README.md:172`/`:469`: fix the broken `docs/AMD64-PACKAGE-AUDIT.md` link (commit the file or remove the references).

### P2 — sweep

16. `docs/RELEASE-HISTORY.md`: header rebrand (26.7 historical / 26.10 current).
17. `docs/SINGULARITY_ISO_PLAN.md`: `.66`/ARGONAS/`.4` references (:42, :85).
18. `docs/AI-ML-STACK.md` (+ zh-CN): scope note 26.7→26.10, `.66` → board name (:7, :36, :250, :314).
19. `docs/DESIGN-RATIONALE.md`: title + scope-note kernel (:5, :31).
20. `docs/NCZ-OS-ORGANIZATION.md`: superseded header; ARGONAS mirror lines (:22, :42); distro-core submodule claim (:85).
21. `docs/PLATFORM-SPLIT-DESIGN.md`: phase status + inventory count (:3–5, :55 — 388 lines at `bb295884`).
22. `distro-core` (public): scaffold status header (§6.7).
23. `docs/reports/2026-09-30-pegasus-nvidia-egl-rescue.md`: `/mnt/datapool` link (:6) — internal report; low urgency.
24. Add a `_status.md` sidecar in `docs/screenshots/` and `docs/attachments/` pointing at the shot-list.

### P3 — structural gaps (decisions for the operator)

25. G1: a single end-user "Wallpapers and plugins" page in `cix-installer`.
26. G3: publish the `artistpack` standard (repo + docs) or state its licensing intent publicly.
27. G4: retarget `linux-cix` default branch at the shipping kernel line.
28. G5: retarget `ncz-screensavers` default branch at the 0.8.9 release line.
29. G6: decide whether a public doc site (GitLab Pages) is wanted; none exists.

---

## 11. Open questions

1. **Where does the fix pass land?** `feat/cygnus-reintegrate-r2-20261005` has since been fast-forward-merged into `integration/cygnus-26.10-2026-10-03` (tip `bb295884`), so the fix pass can land as a docs branch directly on integration; `docs/SCREENSAVER-CATALOGUE-RETIREMENT.md` now exists on integration. The only remaining base question is whether the P0 doc fixes should wait for (or ride with) the first 26.10 image build.
2. **`ncz-screensavers-plugin` version to publish** — item AC deferred 0.3.16; which version should the first 26.10 image carry (and does `build/verify-installed-target.sh` need a version floor or a "skip if unpublished" gate)?
3. **Fleet references in internal docs** — `docs/reports/`, the build runbooks and `docs/upstream-patches/` carry many fleet references by design. End-user rule only, or a repo-wide sweep?
4. **`README.md:884`** — keep the link-local rescue hint as generic fail-safe text, or remove it?
5. **Wallpaper `07-maximilian-blackhole`** — rename (keeping the file) or retire from the 26.10 set (README gallery + release-note references follow the decision)?