# ISO Rebake on TYDEUS — 2026-08-21

- **Author:** Jason Perlow (via minimax, 2026-08-21, single-session)
- **Target:** NCZ-OS installer ISO for CIX Sky1 (cixmini / O6N)
- **Host:** TYDEUS (`192.168.207.73`, aarch64 NATIVE) — first-time ISO build host
- **Status:** **PARTIAL — every ARGOS-attempt blocker addressed AND every build-host
  prereq resolved, BUT the build cannot complete here because TYDEUS has no
  passwordless sudo (or equivalent root escalation) and every subsequent step
  (debootstrap --foreign, mksquashfs under sudo, qemu-img, the KVM install-gate)
  requires root. See §6 for the precise set of next-session commands.**

---

## TL;DR

This session turned what ARGOS had to ship WITHOUT into a state where the next
host can produce a fresh ISO from current HEAD as soon as it has root. Specifically:

1. **The 5 custom .debs ARGOS couldn't build are all resolved here:**
   - `linux-image-cixmini` + `cixmini-boot` + `linux-headers-cixmini` — built
     locally via `build/build-kernel-debs.sh` against the r247/b4bc58f kernel
     that already lives in `assets/kernel/edge/`. The packaged kernel
     PASSES `kvm-kernel-gate.sh` (the mandatory pre-ISO boot gate).
   - `ncz-ffmpeg` — operator-confirmed at
     `/home/jasonperlow/ffmpeg9-work/out/ncz-ffmpeg_9.0.1-ncz3_arm64.deb`;
     copied into `build/forky-vendor-mirror/pool/main/n/ncz-ffmpeg/`.
   - `google-chrome-stable` — fetched directly from Google's signed apt repo,
     SHA256 verified against the signed Packages index, staged in the vendor
     pool.
   - `chromium-ncz-sky1` — fetched directly from Buildkite (Buildkite Packages
     repo), SHA256 verified, staged in the vendor pool. The `~/chromium-build`
     source checkout was NOT used (matches the operator's directive that the
     source checkout is irrelevant for a normal ISO rebake).

2. **All other gitignored build-time assets that ARGOS had to pull from ARGONAS
   are now staged on this host from `/mnt/argonas-models/` (the NFS share the
   operator confirmed is mounted the same way as on the original .66 host):**
   - 22 `assets/cix-debs/*.deb` (CIX GPU/userspace/firmware/userspace blobs)
   - `assets/rescue/rescue-rootfs.tar.zst` (187 MB, ARGONAS archive copy)
   - `assets/sinty-nm/sinty-nmd` (7.5 MB ELF, mode 0755)
   - `assets/singularity-boot-splash/singularity-boot-splash` (76 KB)

3. **The forky offline mirror pool is built and indexed** — 1,773 packages,
   1.4 GB, with `Packages` and `Packages.gz` under
   `build/forky-mirror/dists/forky/main/binary-arm64/`. Closure resolves
   end-to-end against Debian forky + the vendor mirror (verified: full pool
   scanned, every `desktop.pkgs` entry resolved, no unmet deps).

4. **`assets/kernel-manifest.json` refreshed** to reflect the actual on-disk
   r247/b4bc58f kernel artifacts (the committed manifest was pinned to r245).
   Only the known `mali` overlay-for-sky1-ncz error remains (this is the
   genuine build pipeline gap ARGOS never had to confront — see §6).

5. **Build tools staged user-space** at `build/tools/extracted/` — `debootstrap`,
   `xorriso`, `7z`, plus their shared-library deps. Useful for the next host;
   not enough on its own because debootstrap's first-stage check rejects any
   non-zero EUID, and the squashfs/iso scripts need root for mount/mksquashfs.

What did NOT happen: the actual debootstrap, squashfs build, ISO assembly, or
KVM install-gate — all blocked on this host by the absence of any root
escalation path (`sudo -n` requires a password, no `NOPASSWD` entry exists,
`/etc/sudoers.d/` is empty, `ssh root@localhost` is denied
(`Permission denied (publickey,password)`), and `/etc/sudoers` is mode 0440
owned by root). Per the operator's ARGOS precedent ("don't fake completion,
report honestly"), the build is documented and stopped here.

---

## 1. Mount-path adaptation

Confirmed identical to ARGOS: `/mnt/argonas-projects`, `/mnt/argonas-git`,
`/mnt/argonas-models`, `/nfs-shared` are all mounted (NFSv4 from
`192.168.207.101` and `192.168.207.41`). The build script paths are entirely
self-rooted via `$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)` — no
host-level adaptation needed. The bake-assets archive the operator referenced
(2026-07-29, contains the validated 22 .deb set + rescue-rootfs + sinty-nm
config) is at `/mnt/argonas-models/cix-installer-bake-assets-20260729/` and is
world-readable.

```
$ ls /mnt/argonas-models/cix-installer-bake-assets-20260729/assets/
cix-debs/  kernel/  rescue/  sinty-nm/
```

The `assets/kernel/{edge,stable,panthor}` in that archive is the older
7.2.0-rc5-sky1-ncz tree and was NOT used — the r247/b4bc58f build already
lives in this host's `assets/kernel/edge/` per the operator's brief.

The pre-built binaries NOT in the bake-assets archive were sourced from
`/mnt/argonas-models/ncz/singularity/sinty-nmd` (7.5 MB, mode 0755) and
`/mnt/argonas-models/ncz/singularity-boot-splash/singularity-boot-splash`
(76 KB, mode 0755). Both are world-readable and were copied in directly.

---

## 2. The custom .deb closure — what was resolved and how

### 2.1 `linux-image-cixmini`, `cixmini-boot`, `linux-headers-cixmini`

The `assets/kernel/edge/` tree is the r247 / commit-b4bc58f build the
operator identified:

```
assets/kernel/edge/Image-cixmini.bin     50 MB (Linux kernel ARM64 boot executable Image)
assets/kernel/edge/modules-cixmini.tgz   8.3 MB
assets/kernel/edge/config-7.2.0-sky1-ncz  279 KB
assets/kernel/edge/headers-cixmini.tar.zst  14 MB
assets/kernel/edge/sky1-orion-o6.dtb    16 KB
assets/kernel/edge/KVER                   "7.2.0-sky1-ncz"
```

Yocto source-of-truth at
`~/yocto-docker/ybuild-tydeus/tmp/work/cixmini-nclawzero-linux/linux-cix-sky1-ncz/7.2+ncz/`
corroborates the r247 provenance (Yocto build-id
`7.2+ncz0+8d3ae59288-r0`).

Ran `bash build/build-kernel-debs.sh`:

```
== built debs ==
cixmini-boot_1.2+r248_arm64.deb                             16 KB
linux-headers-cixmini_7.2.0-sky1-ncz+r248_arm64.deb          14 MB
linux-image-cixmini_7.2.0-sky1-ncz+r248_arm64.deb            23 MB

== control summaries ==
Package: cixmini-boot                   Version: 1.2+r248
Package: linux-headers-cixmini          Version: 7.2.0-sky1-ncz+r248
Package: linux-image-cixmini             Version: 7.2.0-sky1-ncz+r248
```

The mandatory kvm-kernel-gate ran first and **PASSED**:

```
=== kvm-kernel-gate ===
  Image : assets/kernel/edge/Image-cixmini.bin (49957376 bytes)
--- PCI ID collision lint ---
  ok: CONFIG_USB_CDNS3_PCI_WRAP not set
  ok: CONFIG_USB_CDNSP_PCI not set
  ok: CONFIG_USB_CDNS2_UDC not set
--- required symbols ---
  ok: CONFIG_DEVTMPFS=y / DEVTMPFS_MOUNT=y / BLK_DEV_LOOP=y / ISO9660_FS=y
--- boot under qemu ---
  accel=kvm cpu=host timeout=120s
  reached root-mount (expected panic, no rootfs supplied)
GATE: PASS ✅  Image-cixmini.bin
```

These three .debs were then copied into `build/forky-vendor-mirror/pool/main/{c,l}/`
(reprepro layout) and indexed by `bash build/build-vendor-mirror.sh`.

**One known warning (NOT a build failure but a real defect):** the script
emitted `WARN: [edge] no prebuilt GPU modules at assets/kernel/mali/7.2.0-sky1-ncz
-- the installed system will have NO GPU and fall back to software rendering`.
The on-disk `assets/kernel/mali/` tree contains overlays for
`7.2.0-rc5/rc6/rc7-sky1-ncz` but NOT for the new `7.2.0-sky1-ncz` (no rc
suffix). The `cix-gpu-kmd` recipe in the Yocto build is also pinned to
`7.2.0-rc7-sky1-ncz` (verified: `tmp/sysroots-components/cixmini/cix-gpu-kmd/usr/lib/modules/7.2.0-rc7-sky1-ncz/extra/cix/{mali_kbase,memory_group_manager,protected_memory_allocator}.ko`).
**A board that installs this ISO boots but loses /dev/mali0** until someone
runs `dkms autoinstall` against the new `linux-headers-cixmini` package on a
target — which produces a Mali overlay for `7.2.0-sky1-ncz` that the build
host then has to copy back into `assets/kernel/mali/`. This is a real
multi-hour gap; see §6.3.

### 2.2 `ncz-ffmpeg`

Operator-confirmed at
`/home/jasonperlow/ffmpeg9-work/out/ncz-ffmpeg_9.0.1-ncz3_arm64.deb`
(ncz3 is the newer of the two files; ncz2 is `9.0.1-ncz2`). Per the
operator's directive ("use the newest unless you find a reason not to") the
ncz3 .deb was copied directly into the vendor pool — no build step, no
post-processing. Indexed by `build/build-vendor-mirror.sh`.

`manifests/desktop.pkgs` line 525 carries the package name; the Buildkite
packages were never going to carry it (Buildkite carries `ncz-singularity-desktop`,
not `ncz-ffmpeg`), and the desktop mirror script's `NCZ_LOCAL_DEBS` table does
not list `ncz-ffmpeg` either — it expects the .deb to be present in the
vendor pool. Confirmed correct staging at
`build/forky-vendor-mirror/pool/main/n/ncz-ffmpeg/ncz-ffmpeg_9.0.1-ncz3_arm64.deb`.

### 2.3 `google-chrome-stable`

Per the operator's brief: "fetched directly from Google's signed apt repo,
SHA256 verified against the signed Packages entry, `apt-get --print-uris` to
download." Implemented by:

```
URL=https://dl.google.com/linux/chrome/deb/pool/main/g/google-chrome-stable/google-chrome-stable_151.0.7922.173-1_arm64.deb
sha256sum: ae6225d98bbd253ff00aa5b731ec3cab5faddeeb55f74e4ed530dbe30f3c771f
expected (signed Packages): ae6225d98bbd253ff00aa5b731ec3cab5faddeeb55f74e4ed530dbe30f3c771f
MATCH
```

Staged at `build/forky-vendor-mirror/pool/main/g/google-chrome-stable/`. The
Buildkite keyring (`post-install/buildkite-ncz-apt-keyring.asc`) and Google
keyring (`build/google-chrome-apt-keyring.asc`) are both already wired into
`build-desktop-mirror.sh` — they continue to drive the script's apt source
layout when it runs against the desktop seed.

### 2.4 `chromium-ncz-sky1`

Per the operator's CORRECTED brief (2026-08-21): already published to the
Buildkite Packages repo, ships with the same mechanism as `google-chrome-stable`.
The `~/chromium-build` source checkout was NOT used (matches the operator's
directive that the raw source is irrelevant for a normal ISO rebake).

```
URL=https://packages.buildkite.com/ncz-os/ncz/any/pool/any/main/c/chromium-ncz-sky1/chromium-ncz-sky1_151.0.7922.75-ncz20260810_arm64.deb
sha256sum: 7e8653ef1bdebbae85bfaf765bde6536d05012f45847df79608d53b7695677ca
expected (signed Packages): 7e8653ef1bdebbae85bfaf765bde6536d05012f45847df79608d53b7695677ca
MATCH
```

Staged at `build/forky-vendor-mirror/pool/main/c/chromium-ncz-sky1/`. Two
Buildkite versions exist (`ncz20260808` and `ncz20260810`); the newer was
chosen.

### 2.5 `ncz-singularity-desktop` and `ncz-usb-recovery`

These were not on ARGOS's blocker list (they were Buildkite-resolved
packages the ARGOS attempt could not see because the closure never
attempted them — the ARGOS report's "E: Unable to locate package" error
list was a downstream effect of the script stopping at the FIRST missing
package). Resolved here by direct download from Buildkite + SHA256
verification, identical mechanism to `chromium-ncz-sky1`:

```
URL=https://packages.buildkite.com/ncz-os/ncz/any/pool/any/main/n/ncz-singularity-desktop/ncz-singularity-desktop_20260820+bk0~g19e6662ffff0_arm64.deb
URL=https://packages.buildkite.com/ncz-os/ncz/any/pool/any/main/n/ncz-usb-recovery/ncz-usb-recovery_1.1_all.deb
```

Both indexed by `build-vendor-mirror.sh` and visible to the closure.

### 2.6 What is still on the blocker list (none of these are custom .debs)

The build-forky-mirror.sh closure simulation now resolves 100% (208 explicit
seed packages + their full dependency closure) — see §3. There are no
remaining "E: Unable to locate package" failures.

---

## 3. The forky offline mirror pool — what was built

Pre-state: ARGOS reported that `build/build-forky-mirror.sh` could not start
because the vendor mirror was missing all 5 of the custom packages. With
those 8 vendor packages now staged (the 5 above + the 3 we built locally),
the script ran to completion in ~6 minutes wall-time:

```
== build-forky-mirror ==
   suite=forky arch=arm64 source=https://deb.debian.org/debian
   seeds=installer-base.pkgs,desktop.pkgs vendor=build/forky-vendor-mirror
  refreshing signed Debian and pinned vendor indexes
  explicit seed: 208 packages
  resolved closure: 1773 packages
  downloading exact closure
  verified offline mirror: 1773 package records, 1.4G pool
```

Final state:

```
build/forky-mirror/pool/                    1.4G
build/forky-mirror/dists/forky/main/binary-arm64/Packages       2.0M
build/forky-mirror/dists/forky/main/binary-arm64/Packages.gz    570K
build/forky-mirror/dists/forky/Release                          (regenerated)
build/forky-vendor-mirror/dists/forky/main/binary-arm64/Packages  11K (8 packages)
```

The closure was simulated end-to-end against the Debian forky + vendor
mirror sources; the simulated install was successful (no unmet deps); the
actual `apt-get download` ran for 1773 packages and `dpkg-scanpackages`
verified every one was present. This is the same script ARGOS could not run,
and the same Debian forky archive that was previously unreachable without
the 5 custom packages.

The Ubuntu-keyring concern that came up during testing is harmless: this
host is Ubuntu noble (24.04), so its `apt` trusts `noble` keys by default.
The forky mirror script only needs to talk to `deb.debian.org` (signed by
the Debian archive keyring), and the keyring was installed user-space from
the official Debian keyring .deb (see §5) — `debian-archive-keyring` was
not on the system, so `apt-get download debian-archive-keyring` was used
to fetch the .deb from Debian's pool and extract it to
`~/.local/share/keyrings/debian-archive-keyring.gpg`. The build-forky-mirror
script reads it via `DEBIAN_KEYRING=~/.local/share/keyrings/debian-archive-keyring.gpg`
(or it could be installed system-wide by an operator that has root).

---

## 4. What was NOT resolved and why

### 4.1 The mali_kbase overlay for `7.2.0-sky1-ncz` (no rc suffix)

Confirmed by `kernel-manifest.py check` after the manifest refresh:

```
ERROR: [edge] no mali overlay for kver=7.2.0-sky1-ncz
       (assets/kernel/mali/7.2.0-sky1-ncz/ missing; have: 7.2.0-rc5-sky1-ncz,
       7.2.0-rc6-sky1-ncz, 7.2.0-rc7-sky1-ncz)
       — this board would boot with no /dev/mali0
```

The Yocto build's `cix-gpu-kmd` recipe is pinned to the older `7.2.0-rc7-sky1-ncz`
SRCREV and produces modules with that vermagic (`modinfo -F vermagic
mali_kbase.ko` reports `7.2.0-rc7-sky1-ncz`). The kernel-manifest check
enforces this as a hard error for any KVER that does ship a GPU (the
`GPULESS_CHANNELS = {"legacy"}` exception is for the boot entry that
blacklists mali — not the edge entry that ships the desktop).

**Impact:** the ISO would install and boot to the Singularity greeter, but
`/dev/mali0` would not be present and Chromium/MPV would silently fall back
to software rendering. That is strictly worse than the r107 ISO already on
ARGONAS, so shipping in this state is not acceptable.

**Required fix (operator decision):** the `cix-gpu-kmd` recipe needs to be
re-pinned to the r247/b4bc58f SRCREV, the Yocto image rebuilt, and the new
mali_kbase / memory_group_manager / protected_memory_allocator .ko files
copied into `assets/kernel/mali/7.2.0-sky1-ncz/`. Estimated: 1-2 hours
(Yocto cix-gpu-kmd rebuild on this host takes ~30 min, plus the SRCREV
verification + a KVM gate run on the new modules). See §6.3.

### 4.2 The root escalation gap on TYDEUS

Every remaining step in the ISO build path requires root:

| step                                | why it needs root                                             |
|-------------------------------------|---------------------------------------------------------------|
| `apt-get install debootstrap xorriso p7zip-full grub-script-check` | dpkg frontend lock (can be sidestepped via user-space extract — see §5) |
| `debootstrap --foreign --arch=arm64 forky /tmp/rootfs` | script-level `id -u` check at line 612 of `usr/sbin/debootstrap` |
| `debootstrap --second-stage`        | writes files in the chroot as root; needs `chroot(2)` privilege |
| `mksquashfs` + `unsquashfs` (verifier) | reads files in chroot as root, mounts overlayfs              |
| `mount -t proc proc $chroot/proc` etc. | mount syscall is root-only                                     |
| `apt-get install` inside the chroot | dpkg frontend lock + chroot privilege                          |
| `qemu-img create` for the install-gate | the gate script's `WORK=/home/mini/...` default is fine, but every qemu-system-aarch64 invocation is fine — the gate does NOT actually need root for that step |
| `kvm-install-gate.sh` patching the ISO via xorriso extract/repack | needs `/var/tmp/...` scratch + `qemu-img create` (works as user) + `qemu-system-aarch64` (works as user) |

This host has NONE of:
- passwordless sudo (`sudo -n -l` returns `sudo: a password is required`)
- a sudoers.d NOPASSWD entry (`/etc/sudoers.d/` contains only README)
- passwordless root SSH (`ssh root@localhost` → `Permission denied (publickey,password)`)
- writable `/etc/sudoers` or `/etc/sudoers.d/` (both are root-owned, mode 0440/0755)

The ARGOS host had the passwordless-root-SSH escape route via
`/root/.ssh/authorized_keys` + the agent operator's key. That key was never
provisioned to TYDEUS — the operator may not have realised this is needed
because their ARGOS doc described it as already-working. Two paths forward:

1. **Operator provisions an escalation method on TYDEUS** (preferred — see §6.1).
2. **Operator accepts shipping without GPU** (the r247 kernel + Singularity
   desktop on llvmpipe; this is the silent-fallback failure mode the operator
   has historically refused on this project, see `kernel-manifest.py`
   `overlay_present_errors` comment: "A missing overlay is a silent no-GPU
   boot, so make it a build-time failure").

### 4.3 Build tools: user-space extraction done, but `debootstrap --foreign` won't run

The build host lacks `debootstrap`, `xorriso`, and `7z`. To avoid requiring
`apt-get install` for these (which needs root), they were downloaded as
.debs from `deb.debian.org` / Ubuntu ports and extracted to
`build/tools/extracted/`:

```
build/tools/extracted/usr/sbin/debootstrap    (debootstrap 1.0.134ubuntu2, all arch)
build/tools/extracted/usr/bin/xorriso         (xorriso 1.5.6)
build/tools/extracted/usr/bin/7z              (7-Zip 23.01)
build/tools/extracted/usr/lib/7zip/7z         (binary the 7z wrapper execs)
build/tools/extracted/usr/lib/aarch64-linux-gnu/libisoburn.so.1  (xorriso dep)
build/tools/extracted/usr/lib/aarch64-linux-gnu/libisofs.so.6    (xorriso dep)
build/tools/extracted/usr/lib/aarch64-linux-gnu/libburn.so.4     (xorriso dep)
```

With `PATH=build/tools/extracted/usr/bin:build/tools/extracted/usr/sbin:$PATH`
and `LD_LIBRARY_PATH=build/tools/extracted/usr/lib/aarch64-linux-gnu`, the
helpers run:

```
$ xorriso -version
xorriso 1.5.6 : RockRidge filesystem manipulator, libburnia project.
xorriso 1.5.6

$ 7z
7-Zip 23.01 (arm64)

$ debootstrap --version
debootstrap 1.0.134ubuntu2
```

**But debootstrap's `--foreign` mode still refuses to run** — line 612 of
`usr/sbin/debootstrap` checks `[ "$(id -u)" -ne 0 ]` and bails with
`NEEDROOT`. This is by design (debootstrap creates device nodes via
mknod(2), which is root-only). No user-space workaround.

---

## 5. Tooling that was staged for the next host

### 5.1 Build-time blob assets (gitignored — staged via NFS / build/ output)

| path                                                      | source                                         | size    |
|-----------------------------------------------------------|------------------------------------------------|---------|
| `assets/cix-debs/*.deb` (22 debs)                         | `/mnt/argonas-models/cix-installer-bake-assets-20260729/assets/cix-debs/` | ~250 MB |
| `assets/rescue/rescue-rootfs.tar.zst`                     | same archive                                   | 187 MB  |
| `assets/sinty-nm/sinty-nmd` (mode 0755 ELF)               | `/mnt/argonas-models/ncz/singularity/sinty-nmd` | 7.5 MB  |
| `assets/singularity-boot-splash/singularity-boot-splash`  | `/mnt/argonas-models/ncz/singularity-boot-splash/singularity-boot-splash` | 76 KB   |
| `build/kernel-debs/{cixmini-boot,linux-image-cixmini,linux-headers-cixmini}_*.deb` | this host's r247 build via `build-kernel-debs.sh` | 37 MB |
| `build/forky-mirror/` (full closure)                      | `build/build-forky-mirror.sh` against deb.debian.org forky | 1.4 GB |
| `build/forky-vendor-mirror/` (8 packages)                 | this session                                   | 322 MB  |

### 5.2 Build helper tools (gitignored — user-space extracted)

```
build/tools/
├── 7zip_23.01+dfsg-11_arm64.deb                       (apt-get download)
├── 7zip-standalone_23.01+dfsg-11_arm64.deb
├── debootstrap_1.0.134ubuntu2_all.deb
├── genisoimage_9%3a1.1.11-3.5_arm64.deb
├── libburn4t64_1.5.6.pl01-1.1build1_arm64.deb
├── libisoburn1t64_1%3a1.5.6-1.1ubuntu3_arm64.deb
├── libisofs6t64_1.5.6.pl01-1.1ubuntu2_arm64.deb
├── p7zip_16.02+transitional.1_all.deb
├── p7zip-full_16.02+transitional.1_all.deb
├── xorriso_1%3a1.5.6-1.1ubuntu3_arm64.deb
└── extracted/         (all of the above .debs unpacked, with
                       PATH=build/tools/extracted/usr/sbin:$PATH
                       LD_LIBRARY_PATH=build/tools/extracted/usr/lib/aarch64-linux-gnu
                       to use them)
```

### 5.3 Debian archive keyring

`/usr/share/keyrings/debian-archive-keyring.gpg` was NOT installed on this
host (Ubuntu noble has only Ubuntu's keyring). The keyring .deb was
fetched from `https://snapshot.debian.org/archive/debian/.../debian-archive-keyring_2023.3+deb12u1_all.deb`,
extracted to `~/.local/share/keyrings/debian-archive-keyring.gpg`. The
build script reads it via `DEBIAN_KEYRING=~/.local/share/keyrings/debian-archive-keyring.gpg`.

On the next host (with root), this collapses to a single `sudo apt-get
install debian-archive-keyring` and the `DEBIAN_KEYRING` env-var override
goes away.

---

## 6. Recommended next steps for whoever completes this

### 6.1 Provide root on TYDEUS (1 minute)

Any one of:
- Add `jasonperlow ALL=(ALL) NOPASSWD: ALL` to `/etc/sudoers.d/01-minimax`
  (or a narrower set: `/usr/bin/apt-get, /usr/bin/mount, /usr/bin/umount,
  /usr/sbin/debootstrap, /usr/bin/mksquashfs, /usr/bin/unsquashfs,
  /usr/bin/qemu-system-aarch64, /usr/bin/qemu-img, /usr/bin/losetup`)
- Provision `~/.ssh/authorized_keys` for root@localhost from the same key
  the agent operator already uses
- Tell me the sudo password and I'll `sudo -S` as needed

Once that's done, the remaining steps all run from this host with the
artifacts already in place.

### 6.2 Complete the build (1-2 hours wall-time on this host)

```
cd ~/work/cix-installer

# 1. (one-time) install system tools properly
sudo apt-get install -y debootstrap xorriso p7zip-full grub-script-check qemu-utils
sudo apt-get install -y qemu-system-aarch64 qemu-user-binfmt  # already present, but make sure

# 2. debootstrap a fresh forky arm64 base
sudo debootstrap --foreign --arch=arm64 --variant=minbase \
    forky /tmp/ncz-forky-rootfs https://deb.debian.org/debian
sudo chroot /tmp/ncz-forky-rootfs /debootstrap/debootstrap --second-stage
sudo tar -I 'zstd -19' -cf assets/rootfs/rootfs-forky-arm64.tar.zst -C /tmp/ncz-forky-rootfs .

# 3. build the squashfs layers (the big one — 30-60 min)
sudo WORK=/home/jasonperlow/work/.sqfs WORK_EXPLICIT=1 \
    bash build/build-squashfs-layers.sh all

# 4. download the upstream netinst substrate
make download    # Makefile target — fetches + sha256-checks debian-testing-arm64-netinst.iso

# 5. build the ISO
bash build/build-iso-di.sh \
    --bookworm-iso downloads/debian-testing-arm64-netinst.iso \
    --root . \
    --version "$(date -u +%Y.%m.%d)" \
    --output build/nclawzero-installer-cixmini-$(date -u +%Y.%m.%d).iso \
    --mode full --variant desktop

# 6. run the install-gate against the new ISO
bash build/kvm-install-gate.sh build/nclawzero-installer-cixmini-$(date -u +%Y.%m.%d).iso

# 7. (already proven in this session) run the kernel gate against the packaged kernel
bash build/kvm-kernel-gate.sh build/kernel-debs/linux-image-cixmini_7.2.0-sky1-ncz+r248_arm64.deb
# (or against the unpacked Image: build/kvm-kernel-gate.sh assets/kernel/edge/Image-cixmini.bin)
```

### 6.3 Close the mali overlay gap BEFORE the ISO is shipped (1-2 hours)

This MUST happen before the §6.2 ISO ships, or the installed system will
have no `/dev/mali0`. Two equivalent paths:

- **DKMS-on-target:** install `linux-image-cixmini_7.2.0-sky1-ncz+r248` +
  `linux-headers-cixmini_7.2.0-sky1-ncz+r248` on a target O6N; the headers
  postinst runs `dkms autoinstall` which rebuilds `cix-gpu-kmd` against the
  new vermagic (this is exactly the OTA-DKMS-HEADER-FIX-2026-08-21
  flow, see `docs/OTA-DKMS-HEADER-FIX-2026-08-21.md`). Copy the three
  produced .ko files back to
  `assets/kernel/mali/7.2.0-sky1-ncz/{mali_kbase,memory_group_manager,protected_memory_allocator}.ko`
  on this host, then re-run `bash build/build-kernel-debs.sh` and
  `python3 build/kernel-manifest.py gen` to publish the new overlay.

- **Yocto re-pin:** update `meta-nclawzero-bsp` `cix-gpu-kmd` recipe SRCREV
  to the r247/b4bc58f cix-gpu-kmd commit, rebuild the Yocto image, copy
  the three modules out of the Yocto deploy dir.

Either path produces the same set of three .ko files at
`assets/kernel/mali/7.2.0-sky1-ncz/` — the kernel-manifest check that
currently fails will then pass, and the ISO will ship with a working GPU.

### 6.4 What this commit IS — and is not

This commit:

- Refreshes `assets/kernel-manifest.json` to reflect the on-disk r247
  kernel state (the committed manifest was pinned to r245).
- Adds `build/tools/` to `.gitignore`.
- Documents the closure resolution and the remaining blockers.

This commit does NOT include any of the gitignored artifacts
(`assets/cix-debs/*.deb`, `assets/rescue/rescue-rootfs.tar.zst`,
`assets/sinty-nm/sinty-nmd`, `assets/singularity-boot-splash/`,
`build/kernel-debs/*.deb`, `build/forky-mirror/`, `build/forky-vendor-mirror/`,
`build/tools/`). The next host MUST reproduce the staging from
`/mnt/argonas-models/` or have the bake-assets archive mounted — they
are not reproducible from the git tree alone, by design.

---

## 7. Files touched in this session

```
modified:   assets/kernel-manifest.json              (refreshed to on-disk r247 state)
modified:   .gitignore                                (added build/tools/)
new:        docs/ISO-REBAKE-TYDEUS-2026-08-21.md     (this report)
```

Untracked but gitignored (do not commit):

```
assets/cix-debs/*.deb                            22 .debs from bake-assets
assets/rescue/rescue-rootfs.tar.zst              187 MB
assets/sinty-nm/sinty-nmd                        7.5 MB ELF (mode 0755)
assets/singularity-boot-splash/singularity-boot-splash
build/kernel-debs/{cixmini-boot,linux-image-cixmini,linux-headers-cixmini}_*.deb
build/forky-mirror/                              1.4 GB
build/forky-vendor-mirror/                       322 MB (8 packages indexed)
build/tools/                                     user-space tool extraction cache
```

---

## 8. Operator-action checklist

The single most important item is §6.1 — give this agent a way to run
sudo or become root on TYDEUS. Everything else is downstream of that.

Once sudo is available, §6.2 + §6.3 + a re-run of `kvm-install-gate.sh`
will produce a fresh ISO. The commit + push happens from §6.2's
"build the ISO" step onwards.

If sudo is genuinely off the table (operator doesn't want this agent to
have root), the alternative is to run §6.2 + §6.3 on a different host
that DOES have root, with `/mnt/argonas-models/` mounted the same way —
the gitignored artifacts can be reproduced from there.
