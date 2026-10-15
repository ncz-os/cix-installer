# Separating NCZ-OS package updates from Debian ones

NCZ-OS installs packages from three kinds of apt source: the Debian archive
(suite `forky`, snapshot-pinned at build time), the NCZ-OS repository, and on
machines that were installed before 2026-10-15 a third-party Ubuntu T2 repo and
the Intel apt repo may still have a `.list` file on disk. This page describes
how the installed system keeps them apart, so that an NCZ-OS package can never
silently replace a Debian package of the same name (or the reverse), and how
foreign sources are rejected outright.

## The pin

`post-install/lib/apt-separation.sh` writes
`/etc/apt/preferences.d/10-ncz-origin-separation.pref`. Sources are matched by
host (`Pin: origin <host>`), because the hosted NCZ registry cannot set its own
`Origin` field.

| Source | Packages | Priority |
|---|---|---|
| NCZ-OS | NCZ-owned names (`ncz-*`, `cix-*`, `chromium-ncz-*`, `panthor-cix-dkms`, the NCZ kernel and headers packages) | 990 |
| NCZ-OS | the narrow allowlist of intentional Debian-name overrides the NCZ suite builds natively (see below) | 990 |
| NCZ-OS | any other Debian-named package | 100 (Debian's 500 wins) |
| Debian | NCZ-owned names | -1 (Debian cannot take them over) |
| Ubuntu T2 host (`adityagarg8.github.io`) | every package, no exception | -1 |
| Intel apt host (`apt.repos.intel.com`) | every package, no exception | -1 |

990 rather than 1000+ means nothing is ever forced to downgrade.
The two foreign hosts (`adityagarg8.github.io` and `apt.repos.intel.com`) are
rejected wholesale. Earlier revisions let a known set of names win from the T2
host (the `t2-ubuntu-repo` allowlist) and let `libopenvino-intel-*` win from
the Intel host: that is gone, regardless of whether a legacy `.list` file
survives on an installed system. Strict version checking stays on for every
override -- nothing in this policy disables it.

Debian-originated T2 names that exist in Debian (`apfs-dkms 0.3.21-1` in the
signed Forky snapshot `20261012T023456Z`, etc.) keep apt's default priority
500, so `apt upgrade` offers them like any other Debian package. Nothing in
this policy blocks Debian from supplying them.

## The narrow NCZ-only allowlist

The override rows in `ncz_apt_debian_overrides` are deliberately short. Every
row is one of two kinds:

1. a row for a Debian package NCZ honestly rebuilds from Debian sources and
   ships to every relevant architecture -- `libdrm*` and
   `libgtk4-layer-shell0 (arm64)`;
2. a row for a name the installer builds **natively** for the Forky-only
   installer, replacing the old foreign-host allowlist:
   - `apple-t2-audio-config` (NCZ MIT-licensed functional ALSA UCM, native
     Forky build from the public immutable source `92a5c84e0d097c41e016699d896edb76baf472fc`;
     artifact `0.5.1+ncz1`, Architecture: all);
   - `apple-firmware-script` (NCZ Forky-native firmware extractor, public
     immutable source `6ee3987de2cd7494993eeb60fbe226f78f5b75e5`; package `20261015+ncz1/all`);
   - `libopenvino-2026.4.1`, `libopenvino-intel-cpu-plugin-2026.4.1`,
     `libopenvino-intel-gpu-plugin-2026.4.1`,
     `libopenvino-intel-npu-plugin-2026.4.1` -- amd64 only, own Forky upstream
     source build; the artifact list is the actual selected CPackConfig names
     (no `libopenvino-*` wildcard);
   - `intel-driver-compiler-npu`, `intel-fw-npu`, `intel-level-zero-npu`,
     `intel-validation-npu` -- amd64 only, own Forky upstream source build (no
     `intel-*` wildcard).

The libopenvino and intel-npu artifacts are not yet ready; the publisher and
`build/lib/deb-version-gate.sh` decide when the debs ship. Bypassing the
version gate to push a not-yet-built artifact is forbidden.

## One NCZ-OS repository

Only one NCZ-OS repository is enabled: the Buildkite Packages registry. A
Cloudflare R2 copy is staged but disabled; `ncz-apt-source r2` switches to it
(never both at once) and `ncz-apt-source buildkite` switches back. The offline
package pool on the install media is used only during installation.

## Delivery

New installs get the pin from `post-install/24-apt-sources.sh` before any NCZ
source is enabled. Installed systems get it from the `ncz-apt-policy` package
(`build/build-ncz-apt-policy-deb.sh`), which rewrites the pin in its postinst
and migrates a configuration that had both NCZ-OS repositories enabled. The
update manager installs `ncz-apt-policy` after every index refresh, before an
upgrade is planned.

## Labelled updates

`ncz-update-check` classifies each pending update by apt origin as `ncz-os`,
`debian` or `third-party`, and the NCZ-OS update manager shows the three groups
separately. A same-version rebuild is marked "[rebuilt, same version]".
`/etc/ncz-os/update-origins.conf` can add hosts to the `ncz-os` group.

## Checks

| Check | Fails when |
|---|---|
| `build/check-ncz-repo-policy.sh` | a Debian-named package is published in the NCZ-OS repository without an allowlist row, an allowlisted row is published for an architecture it did not list, or a Debian kernel name appears there |
| `build/check-installed-apt-config.sh [ROOT]` | the pin is missing or stale, two NCZ-OS repositories are enabled, or a `t2.list` survives that the whole-host `-1` does not cover |
| `build/lib/deb-version-gate.sh` | a package reuses a published version with different content |
| `build/apt-live-gate.sh` | the live NCZ-OS repository violates the policy above (step 2 of a release: fix the published package set, then re-run the gate) |
| `build/test-apt-separation.sh` | real apt resolution of every override row, the whole-host `-1` for the T2 and Intel hosts, the Debian-only fallback names (`apfs-dkms 0.3.21-1`) and the prior `fonts-liberation`/`libdrm*`/`libgtk4-layer-shell0` protections regress |
| `build/test-ncz-repo-policy.sh` | the override rows admit the wrong architecture or the namespace check regresses |
| `build/test-ncz-apt-policy-deb.sh` | the `ncz-apt-policy` package itself ships the wrong library, the wrong maintainer-script interpreter, or the wrong fixed epoch |
