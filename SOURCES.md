# SOURCES — NCZ-OS 26.10 "Cygnus" release notes

Internal companion to `docs/RELEASE-NOTES-26.10-cygnus.md`. Not for end users.
Every claim in the public text traces to a file or commit below. Where a source
conflicts with the task brief, the repository wins; the conflict is recorded as
an OPEN QUESTION.

Pinned revisions:

- cix-installer `integration/cygnus-26.10-2026-10-03` @ `c5698cdf22cd21099e9760b12d84c34e13bc968d` (GitLab)
- ncz-screensavers `integration/cygnus-26.10-2026-10-03` @ `d0e094888f616140ae5d1f79ee3b92344a559a21`

`c5698cdf` is ahead of the argonas mirror (`4bf6fe79`); the GitLab-only commits
are `e18ea280`, `213e6cef`, `aa75d80b`, `54fe94a0`, `83f54873`, `c5698cdf`.
The notes are drafted from the GitLab tip because the brief names that branch.

## OPEN QUESTIONS (deferred, not guessed)

1. **amd64 edge built but not shipped.** Brief says "edge 7.3.0-rc6 on both
   arches"; repo says otherwise: `docs/reports/2026-10-05-kernel-channel-policy.md`
   ("checks 5 and 8 … still refuse any amd64 edge payload") and
   `docs/reports/2026-10-05-sky1-r282-rc6-staging.md` ("The amd64 edge entries
   wait for the follow-up"). Notes list arm64 edge only; amd64 edge is a known
   issue. Confirm.
2. **Cygnus visual theme/wallpapers built but not wired.** `branding/cygnus/`
   exists (tokens, generators, contrast tests, Singularity theme, rEFInd theme)
   but no hook or manifest consumes it: `rg cygnus post-install build Makefile
   manifests` returns only `release.conf`. `99-ncz-cygnus.gschema.override.proposed`
   says "Not applied by this branch"; `docs/releases/26.10-cygnus.md` §3 marks the
   theme/wallpapers Pending. Notes treat the visual theme as not shipped.
3. **Singularity desktop apt publication.** The `20261005+u20260925.g5c75e563d10e`
   build was published to a session directory, not the apt repo; the build record
   says the apt repo still served `20260916…` debs then. The image picks the
   latest deb from payload/apt (`Makefile` `LATEST_SINGULARITY_DEB`,
   `post-install/20-desktop.sh`). Confirm which deb the tagged image bundles.
4. **Catalogue count conflict (74 vs 84).** ncz-screensavers 0.8.6 ships 74
   (`debian/changelog`; catalogue 74 rows). cix-installer's legacy
   `assets/screensaver-chooser/hacks.tsv` lists 84, and both
   `post-install/58-screensaver-chooser.sh` and `post-install/59-ncz-screensavers-pkg.sh`
   are enabled. Confirm the image exposes the 74-title package catalogue.
5. **Screensaver plugin 0.3.15.** Built and published to a session directory; not
   confirmed in the apt repo/offline mirror. Notes describe the feature, not a
   plugin version.
6. **Release tag / r-counter.** `c5698cdf` has no `v26.10` tag;
   `docs/releases/26.10-cygnus.md` §2.3 leaves the counter open (global
   `v26.10-r199` vs restart `r1`). Notes show `<r>` pending.
7. **arm64 stable package revision.** `assets/kernel/mainline` → staging
   `r280-7.2.9-sky1-ncz-20261003`, but the packages and
   `assets/kernel-manifest.json` are `7.2.9-sky1-ncz+r281` (r281 = r280 + DKMS
   headers fix). KVER is `7.2.9-sky1-ncz` either way. Confirm shipping revision.
8. **Screensaver family counts.** `docs/releases/26.10-cygnus.md` (2026-09-30)
   says 35 hyprsaver + 36 Shadertoy + 12 classics; the current 74-title catalogue
   is 30 + 30 + 11 + 3 home-grown. Notes use the current catalogue.

## Citation map

### Identity and base
- Product/version/codename, base suite, build snapshot: `release.conf`
  (`NCZ_RELEASE_VERSION="26.10"`, `NCZ_RELEASE_CODENAME="Cygnus"`,
  `NCZ_BASE_CODENAME="forky"`, `NCZ_BASE_MIRROR_SNAPSHOT="20260927T203404Z"`).
- Identity commit: `f89a5127`. Identity record and codename referents:
  `docs/releases/26.10-cygnus.md` §1–§2 (`02c61fee`). "No 26.10 image built yet"
  and `v26.10-r<n>`: same doc, header table and §2.2–§2.3.

### Desktop
- Singularity build `20261005+u20260925.g5c75e563d10e`, upstream
  `singularityos-lab/singularity-desktop` master
  `5c75e563d10e9c6142519f8a976f307742c34c32` (2026-09-25), amd64+arm64, 9 NCZ
  patches + launcher-popup anchor fix: `~/Projects/oc-singularity-latest/report.md`
  §2–§5. Patches in tree: `assets/singularity/patches/*`. Packaging:
  `build/build-singularity.sh`, `build/build-singularity-deb.sh`; deb selection:
  `Makefile`, `post-install/20-desktop.sh`.
- Native greeter: `post-install/55-greeter.sh`. Native KMS boot splash:
  `post-install/60-boot-splash.sh`. Screensaver Settings plugin:
  `post-install/58-screensaver-chooser.sh`, `assets/screensaver-chooser/`;
  plugin build record `~/Projects/oc-plugin-build/report.md` (v0.3.15).

### Screensavers
- Engine 0.8.6, history 0.7.0→0.8.6: ncz-screensavers `debian/changelog` at
  `d0e0948`.
- Catalogue 74: `assets/screensaver-chooser/hacks.tsv` (74 rows) and
  `categories.tsv` (74 rows; origin `ncz`=4, `ported`=70). Families: 30
  `hyprsaver_*`, 30 `xshadertoy_*`, 11 ported classics, 3 home-grown
  (`blackhole`, `fractasia`, `magmasimplex`).
- Grouped settings UI/search/filter/favourites/Black Hole simple mode/still
  previews: changelog 0.8.4. Magmasimplex ships, beat engine, audio sync,
  photosensitivity limiter, Flowerchild, shader install fix: 0.8.5, 0.8.6.
  Fractasia palette library + effect recipes: 0.8.3. Idled logout/login and
  greetd-restart fixes: 0.8.3, 0.8.4. GPU classes and option schema: 0.7.0,
  0.7.2–0.7.4, 0.7.11. Black Hole default: 0.8.0. Cygnus palette on Black Hole:
  0.8.1.

### Kernels and hardware
- Policy: `assets/kernel/KERNEL-POLICY` (`STABLE_BASE=7.2.9`,
  `EDGE_BASE=7.3.0-rc6`); `docs/reports/2026-10-05-kernel-channel-policy.md`;
  commit `aa75d80b`.
- arm64 stable `7.2.9-sky1-ncz`: `assets/kernel-manifest.json`
  (`variants.mainline.kver`, debs `+r281`); `assets/kernel/mainline` symlink;
  commits `b43e3e52`, `d6efa774`.
- amd64 stable `7.2.9-2-t2-trixie`: `assets/kernel/amd64-stable/KVER`; T2 kernel,
  t2smc, no in-kernel applesmc; booted/checked on a MacBookPro16,1: `b43e3e52`.
- arm64 edge `7.3.0-rc6-sky1-ncz` (r282): `assets/kernel/edge-manifest.json`;
  `docs/reports/2026-10-05-sky1-r282-rc6-staging.md`; commit `54fe94a0`.
- amd64 edge `7.3.0-rc6-1-t2-edge-aerfix` and AER ANFE revert (upstream
  `eddba19b8b5f`): kernel-channel-policy report. Not shipped (OPEN QUESTION 1).
- 7.2.8 and 7.3-rc5 retired: `b43e3e52`, kernel-channel-policy report.

### Installer and boot
- Installer boot UX (branded titles, platform+build line, ASCII templates, erase
  review, dialog reorder, no blank console): `docs/INSTALLER-BOOT-UX.md`; commits
  `3dd4778f`, `be36cb10`, `aa083066`, `043e010c`, `c6806798`, `55052b3d`,
  `617e7303`. Heartbeat banner: `0283ef84`. rEFInd 3 s + quiet console:
  `e2ccc0bb`.
- Phase-0 time sync: `post-install/05-time-sync.sh`, `d35e20e3`. RTC sync waits
  for NTP and writes the RTC; hwclock shipped; RTC UTC: `post-install/44-rtc-sync.sh`,
  `post-install/37-ntp-hostname.sh`, `39b6a284`, `8b5b6167`.
- First-boot health report: `918facc0`, `post-install/97-firstboot-report.sh`.
  Boot hygiene: `post-install/58-boot-hygiene.sh`. GPU health:
  `post-install/98-gpu-health.sh`, `81392a86`. NVIDIA EGL rescue (Turing+,
  amd64): `c3f2b355`. Intel VA-API closure: `e18ea280`. T2 USB2/perf isolation:
  `213e6cef`.

### Fixes / other
- Sky1 audio autoswitch: `docs/NCZ-SKY1-AUDIO-AUTOSWITCH.md`,
  `post-install/43-hw-quirks.sh`.
- Wallpaper providers and rotator: `docs/WALLPAPER-PACKS.md`,
  `docs/OCS-WALLPAPER-BACKEND.md`, `post-install/45-wallpaper-rotator.sh`, and the
  wallpaper commits in `v26.7-r198..c5698cdf`.
- Dual-arch parity: `docs/DUAL-ARCH-PARITY.md`.

### Supported hardware (repo evidence only)
- Sky1 boards and status: `README.md` "Hardware support & testing status"
  (MS-R1 verified; Orion O6N verified; Orion O6 user-reported; Orange Pi 6 and
  MetaComputing Framework board untested).
- AMD64 classes: `README.md` same section (T2 Macs 2017–2020, one model tested;
  pre-T2 Intel Macs untested; generic UEFI PC lightly tested).
- Sky1 firmware floor (Radxa Orion EFI 1.3.1): `docs/SUPPORTED-FIRMWARE.md`.

## Self-check
- Forbidden-term grep over the public text: recorded in `report.md`.
- Every substantive sentence in the public text maps above; anything unproven is
  an OPEN QUESTION rather than an assertion.
