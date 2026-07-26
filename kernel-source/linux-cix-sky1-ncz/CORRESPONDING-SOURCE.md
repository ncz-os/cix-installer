# GPL corresponding-source index — linux-cix-sky1-ncz / linux-cix-sky1-next

This directory carries the CIX Sky1/NCZ kernel *recipe + patch series* only
(`.bb` recipe + `patches-7.x/*.patch`) — it does not vendor a full pristine
kernel tree in-repo. That is normal for a Yocto BitBake recipe (the recipe's
`SRC_URI`/`SRCREV` describe exactly how to reconstruct the full source), but
GPLv2's corresponding-source obligation is stronger than "buildable" — it
requires the source to remain reachable even if the third-party upstream we
fetch from ever becomes unreachable. This file records where the *complete*
source (pristine base + our patches) is permanently mirrored under our own
control, so the obligation doesn't quietly depend on `git.kernel.org` staying
up forever.

## 7.2 track — `linux-cix-sky1-ncz_7.2.bb`

- Our patches: `linux-cix-sky1-ncz-7.2/patches-7.2/*.patch` (this repo, full
  git history, all 3 remotes: ARGONAS canonical, GitLab, GitHub-source-stub-N/A).
- Pristine base recipe fetches: `git://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git`
  pinned via `SRCREV_kernel = "1590cf0329716306e948a8fc29f1d3ee87d3989f"` (v7.2-rc4).
- **Self-mirrored pristine base** (single-commit archive of that exact SRCREV,
  independent of kernel.org staying reachable):
  <https://gitlab.com/api/v4/projects/81838641/packages/generic/linux-pristine-base-cix-sky1-ncz/7.2-1590cf03/linux-cix-sky1-ncz-7.2-pristine-base-1590cf03.tar.gz>
  sha256 `a6e2d227bec5e0d9f9ec9882cc94657a932b7a1da57fa1745067efc846627bdb`
  (uploaded 2026-07-26, GitLab generic package registry, `ncz-os/cix-installer`,
  publicly downloadable without auth).

## 7.0.12 track — `linux-cix-sky1-next_7.0.12.bb` (meta-cix)

- Our patches: `meta-cix` `recipes-kernel/linux-cix-sky1-next/files/next-patches*/*.patch`.
- Pristine base recipe fetches: `git://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git`
  pinned via `SRCREV_kernel = "f53879e2e1e2fa053040e734c1ef8f386109a61b"` (v7.0.12).
- **Self-mirrored pristine base**:
  <https://gitlab.com/api/v4/projects/81838641/packages/generic/linux-pristine-base-cix-sky1-next/7.0.12-f53879e2/linux-cix-sky1-next-7.0.12-pristine-base-f53879e2.tar.gz>
  sha256 `6adfd49db52de5324368501587681c4af96a9665a57c24a3a7bb07a3ded443dc`
- **Self-mirrored complete (pristine+patched, as-built) tree**, recovered from an
  ARGOS local archive that predated this index (`/home/jasonperlow/ARCHIVE-20260625/linux-7.0.12-cix-sky1-ncz-src.tar.gz`,
  99,443 files) and had never been published anywhere reachable before now:
  <https://gitlab.com/api/v4/projects/81838641/packages/generic/linux-source-cix-sky1-ncz/7.0.12/linux-7.0.12-cix-sky1-ncz-src.tar.gz>
  sha256 `2baa328c80259caf816cb55a3e715a2a506371a276f869769349152db53a534c`

## Notes

- All three tarballs above are hosted on `ncz-os/cix-installer`'s GitLab
  Generic Package Registry — project-controlled, not a third-party mirror,
  and confirmed publicly downloadable (HTTP 200, unauthenticated) as of
  2026-07-26.
- These are point-in-time snapshots of the exact pinned `SRCREV`s in the
  recipes above. If a recipe's `SRCREV_kernel` is ever bumped, add a new
  entry here (don't overwrite/delete the old one — GPL obligations for
  previously-shipped binaries persist).
- 6.18.26 LTS and 7.1.x tracks are not yet covered by this index; same
  pattern applies if/when their `SRCREV`s need self-mirroring.
