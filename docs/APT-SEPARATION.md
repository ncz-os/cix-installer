# Separating NCZ-OS package updates from Debian ones

NCZ-OS installs packages from three kinds of apt source: the Debian archive
(suite `forky`), the NCZ-OS repository, and, on Apple T2 Macs, the third-party
T2 repository. This page describes how the installed system keeps them apart,
so that an NCZ-OS package can never silently replace a Debian package of the
same name (or the reverse), and how updates are labelled.

## The pin

`post-install/lib/apt-separation.sh` writes
`/etc/apt/preferences.d/10-ncz-origin-separation.pref`. Sources are matched by
host (`Pin: origin <host>`), because the hosted NCZ registry cannot set its own
`Origin` field.

| Source | Packages | Priority |
|---|---|---|
| NCZ-OS | NCZ-owned names (`ncz-*`, `cix-*`, `chromium-ncz-*`, `panthor-cix-dkms`, the NCZ kernel and headers packages) | 990 |
| NCZ-OS | allowlisted Debian-name overrides (`libdrm*`) | 990 |
| NCZ-OS | any other Debian-named package | 100 (Debian's 500 wins) |
| Debian | NCZ-owned names | -1 (Debian cannot take them over) |
| T2 repo | the known T2 package names | 990 |
| T2 repo | everything else | 100 |
| T2 repo | kernel packages | -1 |

990 rather than 1000+ means nothing is ever forced to downgrade.

## One NCZ-OS repository

Only one NCZ-OS repository is enabled: the Buildkite Packages registry. A
Cloudflare R2 copy is staged but disabled; `ncz-apt-source r2` switches to it
(never both at once) and `ncz-apt-source buildkite` switches back. The offline
package pool on the install media is used only during installation.

## Delivery

New installs get the pin from `post-install/24-apt-sources.sh` before any other
apt operation. Installed systems get it from the `ncz-apt-policy` package
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
| `build/check-ncz-repo-policy.sh` | a Debian-named package is published in the NCZ-OS repository without an allowlist row, or a Debian kernel name appears there |
| `build/check-installed-apt-config.sh [ROOT]` | the pin is missing or stale, two NCZ-OS repositories are enabled, or the T2 repository has no pin |
| `build/lib/deb-version-gate.sh` | a package reuses a published version with different content |
| `build/apt-live-gate.sh` | the live NCZ-OS repository violates the policy above (step 2 of a release: fix the published package set, then re-run the gate) |
| `build/test-apt-separation.sh`, `build/test-ncz-repo-policy.sh`, `build/test-ncz-apt-policy-deb.sh` | real apt resolution, the gates above and the policy package itself regress |
