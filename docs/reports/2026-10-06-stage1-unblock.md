# Stage 1 unblock for the r200 respin (2026-10-06)

Branch `fix/stage1-unblock-20261006`, based on `release/26.10-respin-20261006`
at `c8234581`.

## What failed, and why

Stage 1 (`build/build-squashfs-layers.sh all`, and the `desktop`/`hotfix`
stages) calls `build_singularity_payload()`, which runs
`build/build-singularity.sh` on every run. The failure was in that on-image
payload build. The preflight gate only reported the drift. The installer
does not take the payload from Buildkite: `ncz-singularity-desktop` is built
on the build host and then staged into `assets/cix-debs/`. The `+bk0` in its
version means no Buildkite build number, and `tgzXXXXXXXX` is the first 8 hex
digits of the payload tarball's sha256.

Until this change, `build-singularity.sh` cloned the
`singularityos-lab/singularity-desktop` superproject from `master` and then
moved every submodule to its tracked branch head (the re-pin loop). It also
cloned `vetro` and `singularity-boot-splash` at HEAD. So each build used
whatever upstream had pushed that hour.

Upstream pushed a coordinated feature drop between 13:26Z and 15:51Z on
2026-10-06: libsingularity `f3d0f49` (+97k lines), singularity-shell
`1da3224`, labwc `4653655f..2da90c41`, new superproject submodules
(accounts, sharing, nearby, media-plugins), and a commit in nearly every app.
Results against current upstream, reproduced on ULTRA:

| patch | at the r199 pins | at current upstream |
|---|---|---|
| libsingularity/0001-sensors-resource-section-outline | applies | **fails**: `src/style/style.css:5513` |
| singularity-shell/0002-choose-attribution-quadrant | applies | **fails**: `src/components/background/background.vala:92` |
| singularity-shell/0003-plain-contrast-live-quadrant-and-wrap | applies | **fails**: `background.vala:121` |
| singularity-session/0002-supervisor-per-run-logs-signals-core | applies | **fails**: `src/singularity-desktop-session.in:44` (the old preflight never checked singularity-session: it had no URL case for it) |
| singularity-desktop/0002-sensors-settings-keys-and-color-mode | applies | **fails** against the new superproject master |
| all other queued patches (9) | apply | apply |

The old preflight check [2] passed at 14:55Z because it applied the patches
to the default branch at that moment. The payload build that started a few
minutes later cloned `f3d0f49` and died with
`ERROR: ncz patch does not apply: libsingularity/0001-sensors-resource-section-outline.patch`.
The old gate run on this tree today prints 4 failures and 3 warnings.

## The fix: pin every upstream input

`assets/singularity/upstream-pins.tsv` has one row per repository that
`build-singularity.sh` clones. That is 33 rows: the superproject, all 30
submodules in its `.gitmodules`, `vetro`, and `singularity-boot-splash`.
`build/singularity-pins.sh` is the only code that reads the file.

- `build-singularity.sh` does three things before it starts a container.
  It validates the pin file. It clones the superproject at its pin. It runs
  `checkout-tree`, which puts every submodule at its pin and fails, naming
  the path, if `.gitmodules` has a submodule with no pin, or if the pin file
  names a submodule that no longer exists.
  It clones `vetro` and the boot splash at their pins. It writes
  `singularity-opt.tgz.sources`, which records the upstream commit of every
  repository built, bound to the tarball's sha256. It refuses
  `SINGULARITY_REF` in a pinned build. The old branch-head behaviour is
  still available, but only with the explicit `NCZ_SINGULARITY_TRACK_HEAD=1`,
  and the log marks that output as not reproducible.
- Preflight check [2] runs `singularity-pins.sh check-patches`. Each patch
  queue is applied, in order, to its pinned commit, and the loginui queue is
  also applied to the copy bundled with the boot splash. The check runs
  offline from bare mirrors after `singularity-pins.sh fetch-cache`. If the
  network is down and nothing is cached, it gives WARN (rc 2), never a false
  OK.
- `singularity-patch-reconcile.py` retires a merged PR's patch only after
  the pinned commit contains the merge, which it checks with the GitHub
  compare API. Otherwise, the nightly job would delete patches that the
  pinned build still needs.

### Pins and how they were derived

The r199 build metadata recorded no upstream SHAs, and the build logs were
cleaned up. The pins come from upstream history and are checked against the
shipped artifact:

1. r199 stage 1 ran between about 08:00 and 09:00Z on 2026-10-06 (mission
   STATE log: amd64 stage 0 ended 08:31Z, arm64 stage 1 was running at
   08:43Z).
2. On every tracked branch, the newest first-parent commit before
   2026-10-06T12:00Z is dated 2026-09-25 or older. The next commit on any of
   them is the 13:26Z feature drop. So the answer does not depend on exactly
   when r199 built inside that window. The superproject `5c75e563d10e`
   matches the `g5c75e563d10e` in the earlier `+deps1` package version.
3. Verification: I rebuilt the payload at these pins on ULTRA through the
   real stage-1 code path (`build-squashfs-layers.sh hotfix`) and compared it
   with the `ncz-singularity-desktop_20261006+bk0+tgz5fa6f59c_arm64.deb`
   extracted from the shipped r199 image `ncz-os-arm64-20261006-d7ab4948.img`.
   Both have the same 581 files. 519 of the 520 non-ELF files are
   byte-identical; the exception is `libloginui.a`, a static archive that
   embeds timestamps. 57 of the 61 ELF files are byte-identical; the 4 that
   differ are the same size and are the binaries that link `libloginui.a`.

| path | pin |
|---|---|
| `.` (singularity-desktop) | `5c75e563d10e9c6142519f8a976f307742c34c32` |
| subprojects/libsingularity | `b454931607437b4761c916c39d17283b30393509` |
| subprojects/singularity-shell | `3b72f26fc254940670aa28cb78c5c31a672e75f0` |
| subprojects/labwc | `6fe073cb94dde9eefa2039671671139839ea5c91` |
| vetro | `bb1013b407b2ef32dbe475a670f30a27510a9b6a` |
| singularity-boot-splash | `bab3cee8c995ec206239bba1d8259038e02de1b2` (bundled loginui `3ab6cfa6`) |

`upstream-pins.tsv` has all 33 rows. I did not rebase any patch, because
pinning to the r199 commits was possible.

## Forky snapshot pin

I ran `build/pin-forky-snapshot.sh`, which moved the pin from
`20260927T203404Z` to `20261006T143441Z`. That was the newest snapshot
available, and its Release file is valid for about another 165 hours (checked
16:59Z). `preseed.cfg` needs no change, because d-i uses `deb.debian.org`.
Run on macOS, the tool's `check-preseed-mirror-sync.sh` step fails with
`mirror: unbound variable` (bash 3.2 has no associative arrays). On ULTRA it
passes.

How the new pin was checked to resolve: I replicated `build-forky-mirror.sh`'s
resolver with the same seed union, `--no-install-recommends`, and
`check-valid-until=no`. The NCZ-only packages come from the shipped r199
mirror index, as stanzas the old snapshot does not carry: 17 on arm64, 3 on
amd64. I ran it in a debian:forky container on ULTRA for both architectures.

- Method check: at the r199 snapshot, the resolved closure matches the
  shipped r199 offline mirror exactly (1810 arm64 and 1728 amd64), except for
  `lsb-base`, which reaches the mirror by another path.
- At `20261006T143441Z`, every seed resolves on both architectures (1817
  arm64, 1735 amd64).
- Package versions that change: 251 on arm64 and 244 on amd64, listed in
  full in `2026-10-06-forky-snapshot-bump-delta.tsv`. The notable ones:
  systemd/udev 261.2-1 -> 262-1, GTK 4.22.4 -> 4.24.0, ffmpeg 8.1.2 -> 9.0.2,
  linux-libc-dev 7.2.6 -> 7.2.8, dwarves 1.31-2 -> 1.32-1 (the pahole
  requirement from r199 defect 13), firmware-sof-signed 2025.12.2 ->
  2026.09.1, wireplumber 0.5.17 -> 0.5.18, epiphany 51.0 -> 51.1.
- The ffmpeg 9 transition is still in progress in forky. libavcodec63,
  libavformat63, libavfilter12, libavutil61, libswscale10, libswresample7 and
  libavdevice63 are added, and libavcodec-extra62 (8.1) is still pulled in
  beside them. On amd64, libavformat-extra62 and libavfilter-extra11 (8.1)
  also remain. Both ABIs install side by side. The installed image needs
  attention here.
- Added to the closure on both arches (11): libaribb24-0t64,
  libavcodec-extra62, libavcodec63, libavdevice63, libavfilter12,
  libavformat63, libavutil61, libsubid6, libswresample7, libswscale10,
  liburing2. Also added on amd64: libavfilter-extra11 and
  libavformat-extra62.
- Removed from the closure on both arches: libattr1, libavcodec62, and
  libsubid5 (replaced by libsubid6). Also removed on amd64: libavfilter11 and
  libavformat62 (replaced by their -extra builds).
- Unchanged by this pin: firmware-nvidia-gsp and nvidia-driver stay at
  550.163.01-5.1, and gnome-online-accounts stays at 3.58.1-2 (it is still
  in no seed; r199 known issue 4). `nvidia-kernel-open-dkms` 615.71.09 is not
  in the Debian snapshot in either pin. It comes from NVIDIA's CUDA apt repo
  at install time, so this pin cannot change it.

## Not covered by these pins (residual drift)

- The payload build container runs `apt-get update` against live forky, not
  the snapshot. Build dependencies (GTK headers, the compiler) still float.
- labwc's wlroots fallback wrap and any other meson wraps are fetched by
  meson. They are fixed by the labwc commit only as far as each `.wrap` file
  pins a revision.
- `singularity-shell`'s launcher-popup fix in `build-singularity.sh` is
  applied by anchor, not as a patch file. The patch check does not cover it
  (the build does).
