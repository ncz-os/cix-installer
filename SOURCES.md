# SOURCES — NCZ-OS 26.10 "Cygnus" release notes

Internal companion to `docs/RELEASE-NOTES-26.10-cygnus.md`. Not for end users.
Every claim in the public text is traced to a file or commit below. Where a
source conflicts with the task brief, the repository wins; the conflict is
recorded under OPEN QUESTIONS.

Pinned revisions used for this draft:

- cix-installer `integration/cygnus-26.10-2026-10-03` @ `c5698cdf22cd21099e9760b12d84c34e13bc968d` (GitLab)
- ncz-screensavers `integration/cygnus-26.10-2026-10-03` @ `d0e094888f616140ae5d1f79ee3b92344a559a21`

`c5698cdf` is ahead of the argonas mirror of the same branch (`4bf6fe79`); the
five GitLab-only commits are `e18ea280`, `213e6cef`, `aa75d80b`, `54fe94a0`,
`83f54873`, `c5698cdf`. The notes are drafted from the GitLab tip because the
brief names the GitLab branch as the base.

## OPEN QUESTIONS (deferred to the operator, not guessed)

1. **amd64 edge kernel is built but not shipped.** The brief says "edge
   7.3.0-rc6 on both arches"; the repository says otherwise.
   `docs/reports/2026-10-05-kernel-channel-policy.md` ("Not yet implemented …
   `build/verify-kernel-default-policy.sh` checks 5 and 8 … still refuse any
   amd64 edge payload") and `docs/reports/2026-10-05-sky1-r282-rc6-staging.md`
   ("The amd64 edge entries wait for the follow-up"). The notes therefore list
   arm64 edge only and file amd64 edge under Known issues. Confirm this is
   intended for 26.10.
2. **Cygnus visual theme and wallpapers are built but not wired.** `branding/cygnus/`
   exists in the tree (tokens, generators, containment tests, Singularity theme,
   rEFInd theme) but no hook or manifest consumes it: `rg cygnus post-install build
   Makefile manifests` returns only `release.conf`. `branding/cygnus/generated/
   singularity/99-ncz-cygnus.gschema.override.proposed` says "Not applied by this
   branch". `docs/releases/26.10-cygnus.md` §3 marks "Cygnus default theme,
   wallpapers, rEFInd theme" as Pending. The notes treat the visual theme as not
   shipped; only the release identity (name/version/codename) is applied. Confirm.
3. **Singularity desktop apt publication.** The `20261005+u20260925.g5c75e563d10e`
   build was published to a session directory, not the apt repository; the
   publication record says the apt repo still served `20260916…` debs at build
   time. The image picks the latest `ncz-singularity-desktop_*.deb` from its
   payload/apt at build time (`Makefile` `LATEST_SINGULARITY_DEB`, `post-install/
   20-desktop.sh`). Confirm which deb the tagged 26.10 image actually bundles.
4. **Screensaver catalogue count conflict.** ncz-screensavers 0.8.6 ships **74**
   (`debian/changelog` 0.8.5/0.8.6; `assets/screensaver-chooser/hacks.tsv` = 74
   rows). cix-installer's legacy chooser asset `assets/screensaver-chooser/
   hacks.tsv` still lists **84**. Both `post-install/58-screensaver-chooser.sh`
   and `post-install/59-ncz-screensavers-pkg.sh` are enabled on both arches.
   Confirm the image exposes the 74-title package catalogue and that the legacy
   chooser is superseded.
5. **Screensaver Settings plugin 0.3.15.** Built and published to a session
   directory; not confirmed present in the apt repo/offline mirror the image
   installs from. The notes describe the feature, not a specific plugin version.
6. **Release tag / r-counter.** `c5698cdf` carries no `v26.10` tag.
   `docs/releases/26.10-cygnus.md` §2.3 leaves the counter open (continue global
   `v26.10-r199` vs restart at `r1`). The notes show `<r>` as pending.
7. **arm64 stable package revision.** `assets/kernel/mainline` points at staging
   `r280-7.2.9-sky1-ncz-20261003`; the kernel packages and
   `assets/kernel-manifest.json` are `7.2.9-sky1-ncz+r281` (r281 = r280 plus the
   DKMS-headers fix). KVER is `7.2.9-sky1-ncz` either way. Confirm the package
   revision that ships.
8. **Screensaver family counts.** `docs/releases/26.10-cygnus.md` (2026-09-30)
   names 35 hyprsaver + 36 Shadertoy + 12 classics; the current 74-title
   catalogue is 30 hyprsaver + 30 Shadertoy + 11 classics + 3 home-grown. The
   notes use the current catalogue.

## Citation map

### Release identity and base
- Product / version / codename, base suite, build snapshot:
  `release.conf` (`NCZ_PRODUCT_NAME="NCZ-OS"`, `NCZ_RELEASE_VERSION="26.10"`,
  `NCZ_RELEASE_CODENAME="Cygnus"`, `NCZ_BASE_CODENAME="forky"`,
  `NCZ_BASE_MIRROR_SNAPSHOT="20260927T203404Z"`).
- Identity commit (takes effect on next image build): `f89a5127`
  "release: NCZ-OS 26.10 Cygnus identity".
- Versioned identity record and codename referents:
  `docs/releases/26.10-cygnus.md` §1–§2 (commit `02c61fee`).
- No 26.10 image built yet / first build gets `v26.10-r<n>`:
  `docs/releases/26.10-cygnus.md` header table and §2.2–§2.3.

### Desktop
- Singularity Desktop build version `20261005+u20260925.g5c75e563d10e`
  (upstream `singularityos-lab/singularity-desktop` master
  `5c75e563d10e9c6142519f8a976f307742c34c32`, 2026-09-25), amd64 + arm64,
  9 NCZ patches + in-recipe launcher-popup anchor fix:
  build record `~/Projects/oc-singularity-latest/report.md` §2–§5.
- Patch series in tree: `assets/singularity/patches/{singularity-desktop,
  singularity-plugins,singularity-shell,singularity-session,libsingularity}/*`.
- Packaging recipes: `build/build-singularity.sh`, `build/build-singularity-deb.sh`;
  image picks the latest deb via `Makefile` `LATEST_SINGULARITY_DEB` and
  `post-install/20-desktop.sh`.
- Native greeter (greetd + singularity-greeter, supersedes regreet):
  `post-install/55-greeter.sh`.
- Native KMS boot splash (singularity-boot-splash, replaces Plymouth):
  `post-install/60-boot-splash.sh`.
- Screensaver Settings plugin in the shell: `post-install/58-screensaver-chooser.sh`,
  plugin source `assets/screensaver-chooser/`; package plugin build record
  `~/Projects/oc-plugin-build/report.md` (v0.3.15). See OPEN QUESTION 5.

### Screensavers
- Engine version 0.8.6, version history 0.7.0 → 0.8.6:
  ncz-screensavers `debian/changelog` at the integration tip (`d0e0948`).
- Shipped catalogue count and contents (74):
  `assets/screensaver-chooser/hacks.tsv` (74 rows) and `categories.tsv`
  (74 rows; origin counts `ncz`=4, `ported`=70) at the ncz-screensavers
  integration tip. Family split: 30 `hyprsaver_*`, 30 `xshadertoy_*`,
  11 ported classics, 3 home-grown (`blackhole`, `fractasia`, `magmasimplex`).
- Grouped/settings UI, search, engine filter, favourites, Black Hole simple mode,
  headless still previews: `debian/changelog` 0.8.4.
- Magmasimplex ships (74 binaries), beat engine/audio sync/photosensitivity
  limiter, Flowerchild mode, shader install fix: `debian/changelog` 0.8.5, 0.8.6.
- Fractasia palette library (13 schemes) and effect recipes:
  `debian/changelog` 0.8.3.
- Idled logout/login (`EX_TEMPFAIL`) and greetd-restart fixes:
  `debian/changelog` 0.8.3, 0.8.4.
- GPU classes/tiers and option schema: `debian/changelog` 0.7.0, 0.7.2–0.7.4,
  0.7.11.
- Black Hole is the default saver: `debian/changelog` 0.8.0.
- Cygnus palette present on Black Hole (`--palette=cygnus`):
  `debian/changelog` 0.8.1.

### Kernels and hardware support
- Channel policy (stable = default + installer boot kernel, every arch; edge =
  separate non-default entry): `assets/kernel/KERNEL-POLICY`
  (`STABLE_BASE=7.2.9`, `EDGE_BASE=7.3.0-rc6`); rationale in
  `docs/reports/2026-10-05-kernel-channel-policy.md`; commit `aa75d80b`.
- arm64 stable `7.2.9-sky1-ncz` (+r281 packages): `assets/kernel-manifest.json`
  (`variants.mainline.kver`; debs `…+r281`); mainline symlink
  `assets/kernel/mainline` → `r280-7.2.9-sky1-ncz-20261003`; installer-boots-7.2.9
  commit `b43e3e52`; DKMS-headers postinst fix `d6efa774`.
- amd64 stable `7.2.9-2-t2-trixie`: `assets/kernel/amd64-stable/KVER`; T2 kernel
  with t2smc and no in-kernel applesmc; booted and checked on a MacBookPro16,1
  (17/17 post-boot checks): commit `b43e3e52`.
- arm64 edge `7.3.0-rc6-sky1-ncz` (r282): `assets/kernel/edge-manifest.json`;
  `docs/reports/2026-10-05-sky1-r282-rc6-staging.md`; commit `54fe94a0`.
- amd64 edge `7.3.0-rc6-1-t2-edge-aerfix` and the AER ANFE revert
  (`9010-Revert-PCI-AER-Support-Advisory-Non-Fatal-Errors.patch`, upstream
  `eddba19b8b5f`): `docs/reports/2026-10-05-kernel-channel-policy.md`. Not shipped
  (OPEN QUESTION 1).
- 7.2.8 and 7.3-rc5 retired: `b43e3e52`, kernel-channel-policy report.

### Installer and boot
- Installer boot UX: branded dialog titles with platform + build line, ASCII-only
  templates, erase review with confirmation, hostname/component dialogs moved
  before partitioning, no blank console: `docs/INSTALLER-BOOT-UX.md`; commits
  `3dd4778f`, `be36cb10`, `aa083066`, `043e010c`, `c6806798`, `55052b3d`,
  `617e7303`.
- Heartbeat banner routed to tty1+tty3+console: `0283ef84`.
- rEFInd 3 s timeout and quiet console: `e2ccc0bb`.
- Phase-0 time sync before HTTPS steps: `post-install/05-time-sync.sh`,
  commit `d35e20e3`.
- RTC sync waits for a real NTP sync and writes the RTC; hwclock shipped;
  RTC set to UTC: `post-install/44-rtc-sync.sh`, `post-install/37-ntp-hostname.sh`,
  commits `39b6a284`, `8b5b6167`.
- First-boot health report and ldconfig ordering: commit `918facc0`,
  `post-install/97-firstboot-report.sh`.
- Boot hygiene (failed units, `nodelalloc` on btrfs):
  `post-install/58-boot-hygiene.sh`.
- GPU health check / never-software-render: `post-install/98-gpu-health.sh`,
  commit `81392a86`.
- NVIDIA EGL runtime rescue (Turing+, amd64): commit `c3f2b355`.
- amd64 Intel VA-API driver in the desktop closure: commit `e18ea280`.
- Sky1-only USB2 rescan and performance-mode kept off T2 Macs: commit `213e6cef`.

### Fixes / other
- Sky1 HDMI/DP audio autoswitch: `docs/NCZ-SKY1-AUDIO-AUTOSWITCH.md`,
  `post-install/43-hw-quirks.sh`.
- Wallpaper providers (Bing/OCS) and rotator: `docs/WALLPAPER-PACKS.md`,
  `docs/OCS-WALLPAPER-BACKEND.md`, `post-install/45-wallpaper-rotator.sh`, and the
  wallpaper commits in the `v26.7-r198..c5698cdf` log.
- Dual-arch parity enforcement (`make parity`, shared installed-target verifier):
  `docs/DUAL-ARCH-PARITY.md`.

### Supported hardware (repo evidence only)
- Sky1 boards and status: `README.md` "Hardware support & testing status"
  (MS-R1 verified; Orion O6N verified; Orion O6 user-reported; Orange Pi 6 and
  MetaComputing Framework board not yet tested).
- AMD64 classes: `README.md` same section (T2 Macs 2017–2020, one model tested;
  pre-T2 Intel Macs untested; generic UEFI PC lightly tested).
- Minimum Sky1 firmware (Radxa Orion EFI 1.3.1): `docs/SUPPORTED-FIRMWARE.md`.

## Self-check
- Forbidden-term grep run over `docs/RELEASE-NOTES-26.10-cygnus.md` and
  `RELEASE-ANNOUNCE.txt` (host names, internal IPs, Hive/zoder/opencode/session,
  "operator", AI/model attributions): see `report.md`.
- Every substantive sentence in the public text maps to an entry above; anything
  that did not is listed under OPEN QUESTIONS rather than asserted.
