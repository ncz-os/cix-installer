# R78 take7 invalid Release audit - 2026-05-07

## 1. Root cause

The failing take7 ISO is `/Users/jperlow/ncz-installer-cixmini-26.5-r78-Reinhardt-Magnetar.iso`, SHA256 `eb26c8a6b8c5852720d3fb3e62ba8913a22087318c582111590b566248fdc40f`.

The immediate failure is debootstrap's Release index validation:

- The ISO has `dists/resolute/Release` with `Components: main`.
- The same Release file has hashes only for:
  - `main/debian-installer/binary-arm64/Packages`
  - `main/debian-installer/binary-arm64/Packages.gz`
  - `main/i18n/Translation-en*`
- The ISO does not contain `dists/resolute/main/binary-arm64/Packages` or `Packages.gz`.
- The ISO still contains `.disk/base_installable` and `.disk/base_components` with `main`.
- The ISO has 279 udebs and 0 regular debs under `pool/`.

That combination is invalid for a base-installable CD. In debootstrap 1.0.141, `extract_release_components` reads `Components: main`; later `download_release_indices` requires a checksum entry for `main/binary-arm64/Packages`, `Packages.gz`, `Packages.xz`, or `Packages.bz2`. If no such entry exists, it raises:

```
Invalid Release file, no entry for main/binary-arm64/Packages
```

The red dialog is therefore Hypothesis A, with an important extra detail: it is triggered because the medium is still advertised as base-installable by `.disk/base_installable`. The problem is not the missing GPG signature, not date freshness, and not Suite/Codename mismatch. `Suite: resolute` and `Codename: resolute` are present, and unauthenticated installs are already allowed.

Why take7 still chooses `/cdrom` despite the netinstall preseed:

- The staged netinstall preseed correctly flips `apt-setup/use_mirror` to `true` and `apt-cdrom-setup/no-cd` to `true`.
- But bookworm `base-installer` does not use those apt-setup settings to choose the bootstrap source.
- Its `get_mirror_info` path first checks `/cdrom/.disk/base_installable`.
- If that marker exists, it sets:

```
PROTOCOL=file
MIRROR=
DIRECTORY=/cdrom/
COMPONENTS=main
```

So take7 did not actually force base-installer onto `ports.ubuntu.com`. It only removed the regular Packages index from a CD that still claimed to be base-installable. That made debootstrap stop earlier with "invalid Release file" instead of reaching the take6 failure where it tried to bootstrap from an empty `/cdrom/pool` regular-deb set.

## 2. Reference to upstream practice

Debian netinst CDs are base-installable CDs. They advertise `main`, keep `.disk/base_installable`, and include a real regular package repository, not just udebs. That is consistent with Debian's own description of netinst media as containing the installer plus a small core set of text-mode programs, with network needed for desktop or additional packages.

The relevant layout pattern is:

```
.disk/base_installable
.disk/base_components        # main
dists/<suite>/Release        # Components: main
dists/<suite>/main/binary-arm64/Packages[.gz|.xz]
dists/<suite>/main/debian-installer/binary-arm64/Packages[.gz|.xz]
pool/.../*.deb               # regular base packages
pool/.../*.udeb              # installer packages
```

Our r78 take7 ISO instead has:

```
.disk/base_installable       # still present - wrong for this ISO
.disk/base_components        # main
dists/resolute/Release       # Components: main
dists/resolute/main/debian-installer/binary-arm64/Packages.gz
no dists/resolute/main/binary-arm64/Packages*
pool/.../*.udeb              # 279
pool/.../*.deb               # 0
```

Ubuntu resolute arm64 netboot media does not use a CD-local `/dists` tree for the base system. The published resolute netboot arm64 directory contains boot files (`bootaa64.efi`, GRUB, `initrd`, `linux`) and expects archive access over the network. The Ubuntu ports archive itself has the normal repository structure, including `dists/resolute/main/binary-arm64/Packages.gz` and `dists/resolute/main/debian-installer/...`; debootstrap should read that over HTTP, not from our USB media.

So there are two valid upstream patterns:

- Base-installable CD: keep `.disk/base_installable`, keep `main/binary-arm64/Packages*`, and ship the matching regular `.deb` payload.
- Installer/netboot substrate: do not mark the medium base-installable; use it for udebs/boot only, and let base-installer use the configured HTTP mirror.

Take7 is a broken hybrid: installer-only payload with base-installable CD markers.

## 3. Recommended fix

Use the installer/netboot-substrate pattern for `--mode netinstall`.

Do not restore the empty `main/binary-arm64/Packages` as the primary fix. That would quiet the Release validation but would leave `.disk/base_installable` in place, so base-installer would again run debootstrap against `file:///cdrom/`. Because the ISO has zero regular debs, that recreates the take6 `/target/bin/true` failure.

Do not use `Components: main/debian-installer` or an empty `Components` field. `cdrom-retriever` reads `Components:` and then looks for `$component/debian-installer/binary-$arch/Packages`. With `Components: main`, it finds `main/debian-installer/binary-arm64/Packages`. With `Components: main/debian-installer`, it would look for `main/debian-installer/debian-installer/binary-arm64/Packages`. With empty Components, it has no udeb component to scan.

Do not stage a minimal Ubuntu resolute base mirror unless the product direction changes back to a larger offline/thin ISO. A practical base-installable ISO needs more than a token Essential set: debootstrap needs the required base chain, apt/dpkg, libc, shell/coreutils, compression tooling, and dependency closure. Debian and Ubuntu netinst images solve this by shipping a real regular package subset. That is exactly what the 602 MB take7 netinstall was trying not to do.

Concrete patch recipe:

1. Keep the take7 debootstrap-script symlink in `preseed/preseed-ubuntu.cfg`.
2. Keep the take7 `late.sh` conditional that skips the cdrom apt source when `main/binary-arm64/Packages*` is absent.
3. Keep the netinstall preseed rewrite in `build/build-iso-di.sh` lines 1056-1066 that disables `cdrom/suite`, disables `cdrom/codename`, sets `apt-setup/use_mirror=true`, and sets `apt-cdrom-setup/no-cd=true`.
4. Change `build/build-iso-di.sh` around lines 824-831 so `.disk/base_installable` and `.disk/base_components` are only written for `full` and `thin`, not for `netinstall`.

Patch shape for `build/build-iso-di.sh`:

```sh
# around line 827, after:
#   mkdir -p "$STAGING/.disk" "$STAGING/.disk/id"

if [ "$MODE" = "netinstall" ]; then
    rm -f "$STAGING/.disk/base_installable" "$STAGING/.disk/base_components"
else
    printf 'main\n' > "$STAGING/.disk/base_components"
    : > "$STAGING/.disk/base_installable"
fi
printf 'dvd\n' > "$STAGING/.disk/cd_type"
```

Leave `write_suite_release resolute arm64 main ...` alone. `Components: main` is still needed for anna/cdrom-retriever to find `main/debian-installer/binary-arm64/Packages`.

Optional comment cleanup in `build/build-iso-di.sh` lines 789-792 and `preseed/late.sh` lines 144-147: replace "forces base-installer onto http mirror" with "removes the regular cdrom apt component; netinstall also omits `.disk/base_installable` so base-installer uses the HTTP mirror." The functional fix is the `.disk` marker change above.

## 4. Verification plan

Before flashing take8, inspect the ISO, not just the source tree.

Required checks:

```sh
bsdtar -tf take8.iso | rg '^\.disk/base_installable$|^\.disk/base_components$'
```

Expected: no output in netinstall mode.

```sh
bsdtar -tf take8.iso | rg '^dists/resolute/main/binary-arm64/Packages'
```

Expected: no output in netinstall mode.

```sh
bsdtar -xOf take8.iso dists/resolute/Release | sed -n '1,80p'
```

Expected:

- `Suite: resolute`
- `Codename: resolute`
- `Components: main`
- hashes for `main/debian-installer/binary-arm64/Packages`
- no hashes for `main/binary-arm64/Packages`

```sh
bsdtar -xOf take8.iso cixmini/preseed.cfg | rg 'apt-setup/use_mirror|apt-cdrom-setup/no-cd|cdrom/(suite|codename)|mirror/http/hostname|mirror/http/directory|mirror/codename'
```

Expected:

- `apt-setup/use_mirror boolean true`
- `apt-cdrom-setup/no-cd boolean true`
- `mirror/http/hostname string ports.ubuntu.com`
- `mirror/http/directory string /ubuntu-ports`
- `mirror/codename string resolute`
- `cdrom/suite` and `cdrom/codename` lines commented as disabled by netinstall

```sh
bsdtar -tf take8.iso | rg '^pool/.*\.deb$' | wc -l
bsdtar -tf take8.iso | rg '^pool/.*\.udeb$' | wc -l
```

Expected: 0 regular debs, nonzero udebs.

Boot expectation on .66:

- cdrom-detect still mounts and recognizes the media via `.disk/info`.
- anna still reads local udebs via `main/debian-installer/binary-arm64/Packages`.
- base-installer no longer treats `/cdrom` as base-installable.
- debootstrap uses `http://ports.ubuntu.com/ubuntu-ports`, suite `resolute`, component `main`.

Patch recipe summary: in `build/build-iso-di.sh` lines 824-831, make `.disk/base_installable` and `.disk/base_components` conditional on `MODE != netinstall`; for netinstall, explicitly remove both markers after extracting the bookworm substrate.
