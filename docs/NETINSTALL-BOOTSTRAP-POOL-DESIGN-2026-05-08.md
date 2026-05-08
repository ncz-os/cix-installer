# Netinstall Bootstrap Pool Design - 2026-05-08

## Executive summary

`netinstall` stays truly minimal and unchanged.
New `netinstall-bootstrap` adds a small local apt pool for pkgsel/include only.
The ISO remains non-base-installable, so debootstrap still uses ports.ubuntu.com.
Before pkgsel, d-i pins `file:///cdrom` above the network mirror.
The existing 1 GB netinstall size ceiling still applies.

## Mechanism design

### Cross-arch package fetch

`build/build-mirror.sh` does not use host `apt-get download` for cross-arch
resolution. It expects an Ubuntu arm64 chroot, writes arm64 Ubuntu sources into
that chroot, bind-mounts `/dev`, `/proc`, and `/sys`, then runs:

```sh
sudo chroot "$CHROOT" /usr/bin/env DEBIAN_FRONTEND=noninteractive apt-get update
sudo chroot "$CHROOT" /usr/bin/env DEBIAN_FRONTEND=noninteractive apt-get install -d -y ...
```

On x86 ARGOS this relies on the existing binfmt/qemu-user-static setup that can
execute arm64 userland inside the chroot. After apt fills the chroot apt cache,
the host script copies `.deb` files into `pool/main/...` and runs
`apt-ftparchive` to generate `dists/$SUITE/main/binary-$ARCH/Packages(.gz)` and
`Release`.

The new `build/build-bootstrap-pool.sh` uses the same mechanism: apt metadata
and package downloads happen inside the arm64 chroot; repository assembly
happens on the host.

### Subset extraction

The explicit pkgsel set is the preseed line:

```text
openssh-server ca-certificates curl gnupg lsb-release sudo
```

The bootstrap builder computes the hard dependency closure at bake time with:

```sh
apt-cache depends --recurse \
  --no-recommends --no-suggests --no-conflicts --no-breaks \
  --no-replaces --no-enhances \
  openssh-server ca-certificates curl gnupg lsb-release sudo
```

It filters the closure to real binary packages available in apt, downloads that
closure with `apt-get download`, and writes these manifests beside the generated
pool:

```text
bootstrap-pool.packages.raw.txt
bootstrap-pool.packages.txt
bootstrap-pool.install-plan.txt
```

The observed take16/take20 failures should be represented in that closure
where they are still current resolute package names:

```text
libcbor0.10 libfido2-1 openssh-client openssh-sftp-server libwrap0
libnghttp2-14 libpsl5t64 libbrotli1 libsasl2-modules-db libsasl2-2
libldap-common libldap2 librtmp1 libssh2-1t64 libcurl4t64 curl
libassuan9 gpgconf libksba8 libnpth0t64 dirmngr gpg pinentry-curses
gpg-agent gpgsm gnupg openssh-server lsb-release sudo ca-certificates
```

Resolute is a development suite, so package names and versions can roll. This
patch accepts "current at bake time" and records the exact package manifest in
the build output. A future deterministic variant can point `BOOTSTRAP_POOL_UPSTREAM`
at an apt snapshot URL.

### Essential packages

Do not mark the bootstrap ISO as base-installable. `.disk/base_installable`
remains absent in both `netinstall` and `netinstall-bootstrap`, so
base-installer/debootstrap still uses the configured HTTP mirror and installs
the essential/required base set before pkgsel. The local bootstrap pool is not a
complete base mirror and does not need to be one.

Some essential/base packages can still appear in the computed hard dependency
closure if apt reports them as dependencies of the pkgsel packages. That is
harmless, but the design does not depend on those packages for base install.

### Apt source priority

Use `file:///cdrom`, not `cdrom://`. The pre-pkgsel hook bind-mounts `/cdrom`
to `/target/cdrom`, so apt running inside `/target` can read the ISO through a
plain file source:

```text
deb [trusted=yes] file:///cdrom resolute main
```

The hook writes an apt preferences file:

```text
Package: *
Pin: release o=nclawzero
Pin-Priority: 1001
```

The generated Release file has `Origin: nclawzero`, so apt selects local
packages over same/newer network candidates when the local package exists. The
normal ports.ubuntu.com source remains present as fallback for packages missing
from the bootstrap pool.

The hook updates only the local cdrom list before pkgsel:

```sh
apt-get \
  -o Dir::Etc::sourcelist="sources.list.d/cixmini-cdrom.list" \
  -o Dir::Etc::sourceparts="-" \
  -o APT::Get::List-Cleanup="0" \
  update
```

That avoids making the pre-pkgsel hook itself depend on DNS.

### Pkgsel behavior

pkgsel runs `pre-pkgsel.d` hooks immediately before its package work, then uses
the target apt configuration through `apt-install`/`in-target`. It respects apt
sources and apt pinning; there is no separate pkgsel-only downloader that must
hit the network.

For `netinstall-bootstrap`, the generated preseed also changes:

```text
d-i pkgsel/upgrade select none
```

That is necessary because `full-upgrade` would reintroduce arbitrary network
fetches during pkgsel. Post-reboot and late-command network work remains the
fallback layer with better diagnostics.

## Concrete patch

Implemented files:

```text
build/build-iso-di.sh
build/build-bootstrap-pool.sh
preseed/sshd-watcher.sh
preseed/late.sh
```

Patch shape:

```diff
--- build/build-iso-di.sh
+++ build/build-iso-di.sh
@@
-  --mode {full|thin|netinstall}
+  --mode {full|thin|netinstall|netinstall-bootstrap}
@@
+      netinstall-bootstrap
+                 netinstall + local pkgsel bootstrap pool, still <1 GB
@@
+    netinstall-bootstrap)
+        EMBED_MIRROR=0
+        STAGE_ROOTFS=0
+        PATCH_DEBOOTSTRAP_STUB=0
+        STAGE_LTS_KERNEL=0
+        INSTALLER_KERNEL_FLAVOR=next
+        BOOTSTRAP_POOL=1
+        ;;
@@
+        "$ROOT/build/build-bootstrap-pool.sh" \
+            "$BOOTSTRAP_POOL_CHROOT" \
+            "$BOOTSTRAP_POOL_DIR" \
+            resolute arm64 "$BOOTSTRAP_POOL_UPSTREAM"
@@
-if [ "$EMBED_MIRROR" = "0" ]; then
+if [ "$EMBED_MIRROR" = "0" ] && [ "$BOOTSTRAP_POOL" = "0" ]; then
@@
+elif [ "$BOOTSTRAP_POOL" = "1" ]; then
+    [ -s "$STAGING/dists/resolute/main/binary-arm64/Packages" ] || exit 1
@@
-if [ "$MODE" = "netinstall" ]; then
+if [ "$MODE" = "netinstall" ] || [ "$MODE" = "netinstall-bootstrap" ]; then
     rm -f "$STAGING/.disk/base_installable" "$STAGING/.disk/base_components"
@@
+mode == "netinstall-bootstrap" && $0 == "d-i pkgsel/upgrade select full-upgrade" {
+    print "d-i pkgsel/upgrade select none"
+    next
+}
```

```diff
--- preseed/sshd-watcher.sh
+++ preseed/sshd-watcher.sh
@@
+install_ncz_bootstrap_pool_hook() {
+    hook_final=/usr/lib/pre-pkgsel.d/20ncz-bootstrap-pool
+    # no-op unless base_installable is absent and regular Packages is non-empty
+    # bind-mount /cdrom into /target/cdrom
+    # write cixmini-cdrom.list
+    # pin release o=nclawzero at priority 1001
+    # apt-get update only that local file source
+}
+install_ncz_bootstrap_pool_hook
```

```diff
--- preseed/late.sh
+++ preseed/late.sh
@@
-if [ -e /cdrom/.disk/base_installable ]; then
+if [ -e /cdrom/.disk/base_installable ] || \
+   [ -s /cdrom/dists/resolute/main/binary-arm64/Packages ]; then
+    # keep /cdrom bind-mounted in /target and preserve the same pin
```

`build/build-bootstrap-pool.sh` is the new focused builder. It fetches the
pkgsel hard dependency closure from the arm64 chroot, writes `pool/main/...`,
generates `Packages.gz`, writes Release metadata with `Origin: nclawzero`, and
records the bake-time package manifests.

## Test plan

Build:

```sh
REFRESH_BOOTSTRAP_POOL=1 \
BOOTSTRAP_POOL_CHROOT=/path/to/resolute-arm64-chroot \
bash build/build-iso-di.sh \
  --mode netinstall-bootstrap \
  --bookworm-iso /path/to/debian-arm64-netinst.iso \
  --root /Users/jperlow/cix-installer \
  --version take21 \
  --output /path/to/take21.iso
```

ISO inspection before flashing:

```sh
bsdtar -tf take21.iso | rg '^pool/main/.+\.deb$' | wc -l
bsdtar -xOf take21.iso dists/resolute/main/binary-arm64/Packages | rg '^Package: (openssh-server|ca-certificates|curl|gnupg|lsb-release|sudo)$'
bsdtar -xOf take21.iso dists/resolute/Release | rg '^(Origin|Suite|Codename|Components):'
bsdtar -xOf take21.iso cixmini/preseed.cfg | rg 'pkgsel/upgrade|apt-setup/use_mirror|apt-cdrom-setup/no-cd'
```

Expected:

```text
Origin: nclawzero
d-i apt-setup/use_mirror boolean true
d-i apt-cdrom-setup/no-cd boolean true
d-i pkgsel/upgrade select none
```

During take21, before or during pkgsel:

```sh
bash tools/di-diag.sh 192.168.207.66 'echo ==pool==; ls -lh /cdrom/dists/resolute/main/binary-arm64/Packages* 2>&1; grep -c "^Package: " /cdrom/dists/resolute/main/binary-arm64/Packages 2>&1; echo ==apt-source==; cat /target/etc/apt/sources.list.d/cixmini-cdrom.list 2>&1; echo ==pin==; cat /target/etc/apt/preferences.d/00cixmini-bootstrap-pool.pref 2>&1; echo ==policy==; chroot /target apt-cache policy openssh-server curl gnupg sudo ca-certificates lsb-release 2>&1 | sed -n "1,160p"; echo ==hook-log==; grep -E "ncz-bootstrap-pool|pkgsel" /var/log/early_command.log /var/log/syslog 2>/dev/null | tail -80'
```

Expected:

```text
/target/etc/apt/sources.list.d/cixmini-cdrom.list contains file:///cdrom
Pin-Priority: 1001
apt-cache policy shows file:/cdrom candidates at priority 1001
early_command.log contains [ncz-bootstrap-pool] file:///cdrom source...
```

Failure collection if pkgsel still reaches DNS:

```sh
bash tools/di-diag.sh 192.168.207.66 'echo ==sources==; find /target/etc/apt -maxdepth 3 -type f -print -exec sed -n "1,80p" {} \; 2>&1; echo ==lists==; ls -lh /target/var/lib/apt/lists/*cdrom* /target/var/lib/apt/lists/*ports* 2>&1; echo ==apt-errors==; grep -iE "temporary failure resolving|failed to fetch|ports.ubuntu.com|file:/cdrom|ncz-bootstrap-pool" /var/log/syslog /var/log/installer/syslog /var/log/early_command.log 2>/dev/null | tail -120'
```
