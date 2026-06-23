# Kernel R8169 Mainline Migration - 2026-05-08

Status: blocked before ARGOS build. This records the local changes made and the
network/checkout gaps that prevented a complete take24 bake from this session.

## meta-cix changes

Writable working checkout:

`/Users/jperlow/cix-installer/.work-meta-cix-r8169`

Base ref available locally:

`origin/feat/msr1-rebake-2026-05-01` from the nearby cached checkout at
`/Users/jperlow/cixmini-msr1-rebake/meta-cix`.

Local commit:

`4877b8a90cae01daf7eb88dc3b6acd1b007d5f1d`

Commit subject:

`linux-cix-sky1-next: use mainline r8169 for Realtek NICs`

Changed files:

- `recipes-kernel/linux-cix-sky1-next/files/config.sky1-next`
- `recipes-kernel/linux-cix-sky1-next/linux-cix-sky1-next_7.0.3.bb`

Config change in `config.sky1-next`:

```text
CONFIG_MII=y
CONFIG_R8169=m
# CONFIG_R8125 is not set
# CONFIG_R8126 is not set
CONFIG_REALTEK_PHY=m
```

Recipe header comment added:

```text
2026-05-08: drop out-of-tree r8125/r8126; rely on mainline r8169
which supports RTL8125 since kernel 5.13 and RTL8126 since kernel 6.7
```

No separate `r8125` or `r8126` DKMS/module recipes were found in the available
cached `meta-cix` checkout. The only non-patch references were the Sky1-next
kernel config symbols above.

## LTS recipe status

The requested `linux-cix-sky1-lts` 6.18.26 recipe was not present in any local
`meta-cix` ref available to this session. Searches for these paths returned no
matches:

```text
recipes-kernel/linux/linux-cix-sky1-lts*.bb
recipes-kernel/linux/linux-cix-sky1-lts*.bbappend
recipes-kernel/linux-cix-sky1-lts*.bb
recipes-kernel/linux-cix-sky1-lts*.bbappend
```

The available cached remote ref contains `linux-cix-sky1-next_7.0.3.bb`, but no
LTS sibling. Fetching a newer copy was blocked by network restrictions:

```text
fatal: unable to access 'https://gitlab.com/nclawzero/meta-cix.git/':
Could not resolve host: gitlab.com
```

## cix-installer changes

Changed file:

- `post-install/33-network.sh`

Removed the take23 transitional block that wrote:

- `/etc/modules-load.d/ncz-realtek.conf`
- `/etc/modprobe.d/ncz-blacklist-r8169.conf`

Post-change verification:

```text
rg -n "ncz-realtek|r8125|r8126|blacklist r8169|modules-load" post-install/33-network.sh
```

Output: no matches.

`post-install/10-our-kernel.sh` was not touched.

The parent `cix-installer` checkout could not be committed from this sandbox
because writes under `.git/` are blocked:

```text
fatal: Unable to create '/Users/jperlow/cix-installer/.git/index.lock':
Operation not permitted
```

## Yocto build and artifacts

ARGOS SSH was blocked from this session, so the Yocto build was not started.

Attempted command:

```text
ssh -o BatchMode=yes -o ConnectTimeout=10 jasonperlow@192.168.207.22 hostname
```

Output:

```text
ssh: connect to host 192.168.207.22 port 22: Operation not permitted
```

Build wall-clock time:

```text
linux-cix-sky1-lts: not run
linux-cix-sky1-next: not run
```

Artifact sizes:

```text
lts/Image-cixmini.bin: not generated
lts/modules-cixmini.tgz: not generated
next/Image-cixmini.bin: not generated
next/modules-cixmini.tgz: not generated
```

## Module tarball SHA256

New take24 tarballs were not generated, so no new SHA256 values are available.
No May 4-5 baseline `modules-cixmini.tgz` was found locally under:

```text
/Users/jperlow/cix-installer
/Users/jperlow/cix-installer-build
/Users/jperlow/cixmini-gen
/Users/jperlow/ncz-netloader
```

SHA256 comparison:

```text
lts/modules-cixmini.tgz: unavailable
next/modules-cixmini.tgz: unavailable
old May 4-5 baseline: unavailable
```

## Module verification

The required tarball verification could not run because ARGOS build artifacts
were not produced in this session.

Required verification command for the completed ARGOS run:

```text
tar tzf lts/modules-cixmini.tgz | grep -E '/r8169|/r8125|/r8126'
tar tzf next/modules-cixmini.tgz | grep -E '/r8169|/r8125|/r8126'
```

Expected output after successful rebuild:

```text
r8169.ko present
r8125.ko absent
r8126.ko absent
```

Config-level verification completed for Sky1-next:

```text
2740:CONFIG_MII=y
3059:CONFIG_R8169=m
3061:# CONFIG_R8125 is not set
3062:# CONFIG_R8126 is not set
3217:CONFIG_REALTEK_PHY=m
```

## ISO bake and copy status

take24 ISO bake was not started because the ARGOS Yocto build was blocked.
No `ncz-installer-cixmini-take24.iso` was produced or copied to
`/Users/jperlow/`, and no take23 ISO was deleted.

## Push status

Requested push order was attempted for `meta-cix`.

GitLab push:

```text
git push origin feat/msr1-rebake-2026-05-01
fatal: unable to access 'https://gitlab.com/nclawzero/meta-cix.git/':
Could not resolve host: gitlab.com
```

ARGONAS push:

```text
ssh: connect to host 192.168.207.101 port 22: Operation not permitted
fatal: Could not read from remote repository.
```

GitHub mirror was not pushed.

The `cix-installer` push was not attempted because the parent checkout could
not create a local commit and the branch already had unrelated unpublished
history.

## Unexpected side effects and risks

- The available `meta-cix` cache is missing the requested LTS recipe, so only
  Sky1-next was patched locally.
- ARGOS, ARGONAS, and GitLab were unreachable from this sandbox, preventing the
  build, staging, ISO bake, and remote pushes.
- The parent `cix-installer` `.git/` directory is not writable in this sandbox,
  so only the working-tree files were updated there.
- The Sky1-next `0013-net-Add-CIX-Sky1-networking-drivers.patch` still carries
  vendor `r8125/r8126` source for rollback, but the config disables those
  symbols so the modules should not be built.
- No `bbappend` conflicts were observed in the available checkout.
