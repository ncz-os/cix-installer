# Ubuntu Suite Migration to Resolute - 2026-05-08

## Executive summary

- Target Ubuntu rootfs moved from Ubuntu 25.10 to Ubuntu 26.04 LTS resolute.
- Debian 12 bookworm remains the d-i boot substrate; bookworm references were not changed.
- ports.ubuntu.com remains the target archive host, with path `/ubuntu-ports`.
- The local debootstrap fallback is `resolute -> gutsy`, matching Ubuntu's upstream symlink pattern.
- CIX packages remain on `archive.cixtech.com/debian trixie main`; no resolute CIX suite was found in public docs.

## Files changed

- `preseed/preseed-ubuntu.cfg`: suite/codename switched to resolute; early debootstrap symlink switched to `resolute -> gutsy`; security host/path left on `ports.ubuntu.com` and `/ubuntu-ports`.
- `preseed/late.sh`, `preseed/sshd-watcher.sh`: local bootstrap-pool paths and file sources switched to `dists/resolute`.
- `build/build-iso-di.sh`: target suite paths, mirror defaults, bootstrap-pool defaults, Release generation, rootfs tarball name, `.disk/info`, and boot menu suite text switched to resolute.
- `build/build-mirror.sh`, `build/build-bootstrap-pool.sh`: default chroot/mirror directories, suite default, labels, and generated apt metadata switched to resolute.
- `post-install/20-desktop.sh`: target apt sources switched to resolute, resolute-updates, resolute-security, and resolute-backports.
- `post-install/50-brand.sh`: `/etc/os-release` now reports `PRETTY_NAME="Reinhardt 26.5 (based on Ubuntu 26.04 Resolute Raccoon)"`, `VERSION_ID="26.04"`, and `UBUNTU_CODENAME=resolute`.
- `post-install/12-sky1-firmware.sh`, `15-mesa-sky1-pin.sh`, `25-cix-ppa.sh`, `32-quadlet-shim.sh`: suite/version comments updated without changing behavior.
- Tracked docs outside `docs/STABILITY-SWEEP-*`: stale old-suite references updated to resolute.

## Codename and suite verification

- Canonical announced Ubuntu 26.04 LTS, codenamed Resolute Raccoon, on April 23, 2026:
  https://ubuntu.com/blog/canonical-releases-ubuntu-26-04-lts-resolute-raccoon
- Ubuntu announce confirms `Ubuntu 26.04 LTS, codenamed "Resolute Raccoon"` and 5 years of maintenance:
  https://lists.ubuntu.com/archives/ubuntu-announce/2026-April/000323.html
- Web check passed for the ports archive:
  `https://ports.ubuntu.com/ubuntu-ports/dists/resolute/`
  The index exposes `Contents-arm64.gz`, `InRelease`, `Release`, and the expected `main`, `universe`, `restricted`, and `multiverse` directories.
- Arm64 package index exists at:
  `https://ports.ubuntu.com/ubuntu-ports/dists/resolute/main/binary-arm64/`
- Mesa verification: `mesa-vulkan-drivers` in resolute is `26.0.3-1ubuntu1`, so stock resolute Mesa is already Mesa 26-class:
  https://packages.ubuntu.com/search?keywords=mesa-vulkan-drivers

## Debootstrap script base

Chosen base: `gutsy`, via `ln -sf gutsy /usr/share/debootstrap/scripts/resolute`.

Rationale:

- Ubuntu debootstrap `1.0.141ubuntu1` added a symbolic link for resolute:
  https://lists.ubuntu.com/archives/resolute-changes/2025-October/000560.html
- Debian debootstrap `1.0.142` also notes "Ubuntu: add symlink for resolute".
- The current installer flow can still graft older trixie debootstrap `1.0.141`, so the local early_command symlink remains necessary when that udeb does not already contain `resolute`.
- Noble/oracular were not chosen as the fallback because upstream debootstrap models Ubuntu releases as symlinks to the shared Ubuntu `gutsy` script family.

## CIX archive decision

No change to `post-install/25-cix-ppa.sh`.

- The source remains:
  `deb [signed-by=/usr/share/keyrings/cix-deb-repo.gpg] https://archive.cixtech.com/debian trixie main`
- Radxa and CIX public docs describe the CIX community repo as Debian 13 trixie scoped, and the CIX PPA manual lists Debian 13 trixie as the required supported distribution for the open-source driver option:
  https://docs.radxa.com/en/orion/o6/other-os/debian13
  https://github.com/cixtech/cix-developer-docs/wiki/CIX%20PPA%20User%20Manual%20%28Open%E2%80%90Source%20Driver%20Edition%29
- Direct shell fetches are DNS-blocked in this workspace, and no public CIX resolute suite was discoverable through web search/fetch. Keep Debian trixie until CIX publishes an Ubuntu resolute suite.

## Test plan for take22

1. Build the resolute bootstrap chroot, mirror, and ISO; confirm generated paths are under `dists/resolute`.
2. Inspect the ISO: `.disk/info` says resolute, `dists/resolute/Release` has `Suite: resolute` and `Codename: resolute`, and no previous-suite dists tree is present.
3. Boot take22 on `.66`; confirm `/var/log/early_command.log` either sees an existing resolute debootstrap script or logs `linked resolute -> gutsy`.
4. In netinstall modes, confirm base-installer debootstraps from `http://ports.ubuntu.com/ubuntu-ports` suite `resolute`, not from `file:///cdrom`.
5. After first boot, verify `/etc/os-release`, `/etc/apt/sources.list`, `apt-cache policy mesa-vulkan-drivers`, LightDM/XFCE, CIX repo setup, and both desktop/server variant behavior.
