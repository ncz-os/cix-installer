# Magnetar: the server variant of the netinst installer image

`NCZ_VARIANT=server` builds the installer medium for a headless Magnetar
server. The default is `desktop`, and **desktop media is byte-identical to
before this variant existed** — every branch below is on
`_variant() == "server"`. That claim is not taken on faith: running
`build_ncz_payload_tree` + the desktop pool staging from both this
`write-usb-image.py` and the one at `HEAD`, over identical real inputs (real
assets, real preseed/post-install trees, the real substrate udebs, a real
offline mirror), produces the same 2,566 files with the same 2,566 sha256
digests — the only two that differ are `ncz-payload/BUILD_DATE` and
`dists/<suite>/Release`, which carry a build timestamp by design.

The whole point of the variant is that the medium is small: it carries the
installer and a pinned manifest, and the multi-gigabyte payload comes off the
network at install time, verified by sha256 before a single byte of it is
used.

## What was measured, not assumed

Measured on the amd64 server image of 2026-10-16 by reading the finished
image's data partition (dd + `debugfs rdump`, no assumptions):

| Path | Bytes | What it is |
|---|---:|---|
| `pool/` | 1,960,721,624 | 1,875,725,028 regular `.deb` (the offline apt closure) + 84,996,596 substrate `.udeb` |
| `ncz-payload/assets/` | 574,624,515 | rescue 212,638,137 · firmware 170,081,121 · kernel 124,339,917 · branding 57,359,189 |
| `dists/` | 2,805,485 | the apt indexes |
| `ncz-payload/` (everything else) | ~8.6 MB | sqtools, post-install, preseed, metadata |
| **data partition content** | **2,546,377,288** | → 2.94 GiB partition (20% headroom) → **3,424,649,216 B image** |

The task brief guessed the ~2.5 GB was "the installer pool (kernel, initrd,
debootstrap udeb, substrate assets)". Measurement says it is two distinct
things: the **offline apt closure** (1.88 GB, only ever consumed by a
desktop-only hook) and the **substrate assets** (564 MB, read by the
kernel/rescue/firmware/branding post-install hooks). Both come off the medium;
the substrate **udebs** stay, for the reason in the next section.

## What moves, and what must not

The r159 CONTRACT is in `preseed/preseed.cfg`: the debootstrap stub that
replaces `/usr/sbin/debootstrap` is the **only live install path** under d-i
— there is no `partman/late_command` (verified against partman-base 241), so
`extract-rootfs.sh` never runs. Anything needed *during boot* must therefore be
on the medium, or fetched **before** the stub runs.

That splits the payload cleanly:

**Stays on the medium (never moves, on any variant).**
The `debian-installer` substrate: 231 udebs and the
`dists/<suite>/main/debian-installer/binary-<arch>/Packages` index they are
read through. d-i's `cdrom-retriever`/`load-cdrom` reads these during
`main-menu`, long before `bootstrap-base` invokes the stub — fetching them at
install time would be too late by contract. Plus `sqtools` (the arch-matched
static `unsquashfs`, a few MB, needed to unpack the file the stub downloads),
the preseed/post-install scripts, rEFInd, and the metadata files.

**Comes off the medium, fetched and verified at install.**

| Artifact | Before | Mechanism |
|---|---:|---|
| `base.squashfs` | ~700 MB | `NCZ_PAYLOAD_URL` + `NCZ_PAYLOAD_SHA256` |
| `assets/{rescue,firmware,kernel,branding}` | 564,418,364 B | packed into one pinned `ncz-assets-<arch>.tar.gz`, `NCZ_ASSETS_URL` + digest |
| the offline apt closure (regular `.deb`s) | 1,875,725,028 B | not staged at all |

The offline closure is not *fetched*, it is **dropped**, and that is a
deliberate call rather than an oversight: its only consumer on the medium is
`post-install/20-desktop.sh`, which registers `deb [trusted=yes]
file:///cdrom` and exits immediately for `BUILD_VARIANT=server|headless`;
`post-install/24-apt-sources.sh` already treats a missing pool as a warning and
falls back to the network sources. Shipping 1.8 GB of packages nothing on a
server image can install was the single largest reason the medium was ~3.4 GB.
(Superseded: see the correction and the decision below.)

> **Correction (2026-10-26, first real server installs).** That premise is
> wrong. `20-desktop.sh` is not the only consumer of the on-media regular
> repository: the r159 stub binds it into the target as the install-time apt
> source and refuses to continue without it (`FATAL: r159 stub: no on-media
> <arch> apt repository found`, both arches, Preview4 `079bbf39`), apt-setup's
> preseeded `local0` source is `file:///cdrom`, and `late.sh` and many
> post-install hooks `apt-get install` from it. The server base layer does not
> carry what they install: in the extracted Preview4 base, `firmware-linux-free`,
> `firmware-realtek`, `firmware-misc-nonfree`, `python3-dbus`,
> `libtext-iconv-perl` and `refind` are absent on both arches, and
> `ncz-apt-policy` on amd64. A server medium therefore needs a regular apt
> closure from somewhere (on the medium, in the fetched payload, or a computed
> subset). Resolved for Preview4 by option A (next section).

## Decision: A for Preview4 (orchestrator 2026-10-26, pending operator review); B is the long-term target

- **A (Preview4):** the server medium carries the offline apt closure
  (`dists/` + `pool/`, as desktop does). It leaves out only the squashfs
  layers and the assets, which the install fetches and verifies.
- **B (long-term):** fetch the closure as a third pinned payload artifact and
  present it to the install as `/cdrom`, so the medium shrinks again.

What A costs, from the Preview4 receipts (`medium_size`):

| | amd64 | arm64 |
|---|---:|---:|
| image | 2,837,446,656 B | 2,536,505,344 B |
| data partition | 2,617,245,696 B | 2,415,919,104 B |
| offline pool | 1,782 debs, 1,878,201,360 B | 1,822 debs, 1,529,373,396 B |

The gates enforce A: `scan-shipped-secrets.py --variant server` and
`forky-provenance.py --variant server` fail a server medium that carries no
regular `.deb` under `pool/` or no regular `dists/<suite>/<component>/binary-<arch>/Packages`
index, and still fail one that carries a squashfs layer.

### What the install takes from the pool

Measured on the Preview4 amd64 server install (the installed target's hook
logs, 498 `Setting up` lines, i.e. what the install set up on top of the
base layer):

| consumer | packages |
|---|---|
| r159 stub | `libtext-iconv-perl` (debconf needs it before apt-setup) |
| apt-setup / `late.sh` | the `file:///cdrom` source itself (`apt-get update`) |
| `13-firmware-bom.sh` | the 40-package firmware BOM (`firmware-linux-free`, `firmware-misc-nonfree`, `firmware-realtek`, `firmware-iwlwifi`, ...) |
| `24-apt-sources.sh` | `gnupg` (+ `gpg`, `dirmngr`, ...), `ncz-apt-policy` |
| `33-network.sh` | `wpasupplicant` |
| `34-firewall.sh` | `nftables` |
| `40-claude-code.sh` | `nodejs`, `npm` and about 300 `node-*` dependencies |
| `44-rtc-sync.sh` | `util-linux-extra` |
| `47-llm-stack.sh` | `mesa-vulkan-drivers`, `vulkan-tools`, `clinfo`, `glmark2-*` and their GL/X11 libraries |
| `92-apparmor-enable.sh` | `apparmor`, `apparmor-utils`, `apparmor-profiles` |
| `93-zram-swap.sh` | `systemd-zram-generator` |

Some of these hooks are not server-specific (`40-claude-code.sh`,
`47-llm-stack.sh`); whether a server install should run them is a separate
question for option B, where the pool's size becomes the payload's.

## The install-time flow

1. d-i boots from the medium and reads its installer udebs (`/cdrom`).
2. `partman/early_command` installs the r159 stub from
   `ncz-payload/debootstrap-udeb/`, refusing to continue without it.
3. `bootstrap-base` calls the stub with `/target`.
4. The stub finds no local `base.squashfs`, finds
   `ncz-fetch-payload.sh` beside the payload, picks a **writable** staging root
   (`$TARGET/ncz-online/ncz-payload`; the medium itself is mounted `-o ro,noload`,
   so a fetch into `/cdrom` would die part-way and leave a half-written tree),
   and runs the fetcher.
5. `ncz-fetch-payload.sh` reads the medium's `ncz-fetch-payload.manifest` (the
   stub passes it as `NCZ_FETCH_MANIFEST`; the destination is empty) and fetches
   each artifact with GNU `wget` (wget-udeb, which the build requires in the
   initrd; d-i's busybox has no `wget` applet), falling back to `busybox wget`
   only when that applet answers and failing loudly before any download when
   neither works. Every artifact is **sha256-verified before use**: bounded retries with
   exponential backoff, HTTP `Range` resume, an overall deadline, a DNS
   readiness probe, idempotency (an already-verified artifact is not
   re-downloaded), and a loud serial failure. Any failure is fatal — an
   unverified rootfs is never installed.
6. The stub links `sqtools` in and extracts. The wipe of `$TARGET` deliberately
   skips `ncz-online`; deleting it would delete the file just verified.
7. `late.sh` (still a real `preseed/late_command`) unions the fetched
   `assets/` into `/target/usr/local/lib/cix-installer/assets/` (the bundle's
   members all live under `assets/` for this), asserts
   `assets/{rescue,kernel,firmware,branding}` really arrived, and removes the
   staging root so it does not live inside the installed root filesystem. A
   staging root without `assets/`, or a server medium whose stub staged
   nothing, fails the install.

Every post-install hook therefore still finds what it expects at
`$INSTALLER_META/assets/...`.

## Build inputs

The URLs and digests are build inputs, not something the writer invents. A
server build **refuses** to run without them, because a medium whose payload
cannot be verified can only fail at the operator's prompt on a headless box.

`build/build-image.sh` drives a server build end to end:

```sh
NCZ_VARIANT=server build/build-image.sh --arch amd64 --full --sources pinned \
    --substrate pinned --no-publish --keep-work --run-dir <run>
```

| Parameter | Default | Meaning |
|---|---|---|
| `NCZ_VARIANT` | `desktop` | `server` builds a Magnetar medium; anything else is a usage error |
| `NCZ_PAYLOAD_BASE_URL` | the KVM gate's serve base, `http://10.0.2.2` (`ncz_gate_serve_payload_base_url()`) | where the medium will fetch `base.squashfs` and `ncz-assets-<arch>.tar.gz` |
| `NCZ_PAYLOAD_URL` / `NCZ_ASSETS_URL` | `<base>/base.squashfs` / `<base>/ncz-assets-<arch>.tar.gz` | per-artifact override |
| `NCZ_PAYLOAD_SHA256` | the sha256 of `assets/squashfs/base.squashfs` | must equal it if given |
| `NCZ_GATE_SERVER_HOST` | unset | pin a LAN address of the build host instead of 10.0.2.2 |
| `NCZ_KVM_GATE_SERVER_SETS` | `server server-offline-negative` | the server gate sets |

The image stage pins the payload before the writer runs, passes the pins and
`NCZ_ASSETS_EXPORT_DIR` into the image container (that one call only), and
afterwards requires the receipt to say `variant=server` and to pin exactly the
bytes now in `<run>/payload/` (the exported bundle and a copy of the base
layer). `<run>/payload.result` records the pins and `published=no`.

A medium pinned to the gate's base is a **gate medium**. A release medium pins
the published URL (`NCZ_PAYLOAD_BASE_URL=https://…`); nothing in the build
uploads anything.

Calling the writer directly still works:

```sh
NCZ_VARIANT=server \
NCZ_PAYLOAD_URL=https://…/base.squashfs \
NCZ_PAYLOAD_SHA256=<64 hex> \
NCZ_ASSETS_URL=https://…/ncz-assets-amd64.tar.gz \
  make image ARCH=amd64
```

`NCZ_ASSETS_SHA256` is not an input: the writer builds the bundle itself (so
the pin is the digest of exactly the bytes desktop would have shipped) and
records it in `ncz-fetch-payload.manifest` and in the image receipt. The
bundle is a deterministic gzip tar (sorted members, uid/gid/uname/gname/mtime
normalised, gzip header mtime pinned to 0) because that digest is only
meaningful if two builds of the same inputs agree on it — covered by
`build/iso/tests/test_write_usb_image_server_variant.py`.

## Result, measured

| | Before | After |
|---|---:|---:|
| staged data-partition content | 2,546,377,288 B | **104,000,790 B** |
| data partition | 3,154,116,608 B (2.94 GiB) | **268,435,456 B** (256 MiB, the floor) |
| image | 3,424,649,216 B | **538,968,064 B** |
| offline closure `.deb`s on the medium | 1,778 | 0 |
| substrate `.udeb`s on the medium | 231 | 231 |

Measured on HYDRA 192.168.207.78 against the real repo (real assets, real
substrate, real `dpkg-scanpackages`/`apt-ftparchive` staging). `mke2fs -d`
confirms the ext4 image is exactly 268,435,456 B.

## Slim layout (fix/p3-magnetar-slim-20261017): the honest numbers

Measured on 2026-10-17 by **building both images from the same inputs**, twice:
the parent commit `76692942` and this branch, with the real r20261013 amd64
substrate pool (231 udebs), the real 28.6 MB d-i initrd, the real preseed/
post-install trees and a real xz run. Everything not listed below (the
squashfs layers, the offline apt closure) is not on a server medium.

| | parent `76692942` | this branch | delta |
|---|---:|---:|---:|
| ESP (FAT) | 268,435,456 | **69,206,016** | −199,229,440 |
| data partition (ext4) | 268,435,456 | **134,217,728** | −134,217,728 |
| substrate udebs on the medium | 231 / 84,996,596 B | **69 / 48,272,260 B** | −162 udebs, −36,724,336 B |
| data-partition content | 99,216,521 B | **56,484,859 B** | −42.7 MB |
| **raw image** | **538,968,064** | **205,520,896** | **−61.5%** |
| **`.img.xz`** | **146,072,784** | **103,357,360** | **−29%** |

The 60 MB target is **not met**, and the remainder is not slack:

| what is still on the medium, and why | bytes | xz | room left to cut |
|---|---:|---:|---|
| d-i initrd, embedded in the ESP | 28,602,231 | 29.5 MB | **none** |
| `linux-binary-*-di` | 13.6 MB | — | none: it IS the installer kernel initrd paired with |
| `nic-wireless-modules` | 12.3 MB | — | only by dropping Wi-Fi installs |
| `nic-modules` | 8.9 MB | — | none: the only NIC driver source on the medium |
| rest of the kept pool (64 udebs) | ~1.1 MB + kernel modules | — | each has a named consumer |

Two facts make <= 60 MB unreachable **without breaking the documented d-i
contract**, and both are measurements rather than opinions:

1. **The initrd does not compress.** `xz -6` on
   `initrd-amd64.gz` (28,602,231 B) gives 28,502,356 B -- 0.3%. It is a
   compressed cpio archive holding an already-compressed kernel-module set and
   already-compressed `.deb`-like members. Its 28.6 MB is a hard floor of the
   image.
2. **rEFInd cannot read xz.** `build-refind-esp.py` embeds the d-i kernel and
   initrd as plain FAT files because rEFInd's SFS driver opens them directly;
   a `.xz`/`.zst` initrd on the ESP is not a layout rEFInd can boot. So the
   initrd cannot move out of the raw image, and the raw image therefore cannot
   go below ~30 MB of initrd + ~22 MB of kernel even with an empty pool.

Arithmetic for the floor with the current d-i inputs: 1 MiB GPT head + 69 MiB
ESP (66 MiB content × 1.15 + 8) + 128 MiB data (56.5 MiB content × 1.2 + 32,
64 MiB granularity) + 1 MiB backup = 199 MiB raw, and ~103 MB xz. Dropping
**every** udeb would still leave ~55 MB raw of initrd+kernel and ~30 MB xz.
Meeting 60 MB compressed therefore requires one of: a smaller d-i initrd
(a d-i build decision, not this repo's), a netboot-style medium that does not
embed an initrd at all (a different product, and it breaks the
"medium must install with no network" contract), or network-booting the
installer -- none of which this task authorises.

### (a) Partitions sized to content

* `build/iso/build-refind-esp.py --size-mib` now defaults to **0 = size to
  content**; `_required_esp_mib()` keeps its `content × 1.15 + 8 MiB` rule and
  still grows past a request that is too small, so the 2026-09-26 "Disk full"
  regression cannot return. `build/build-installer-image.sh` chooses the floor
  from `NCZ_VARIANT`: **desktop keeps `--size-mib 256`** (so the desktop image
  stays byte-identical to pre-Magnetar builds -- the ESP is built by one
  variant-agnostic script, so this gate is what keeps desktop untouched) and
  only `NCZ_VARIANT=server` passes `0`. Measured for server: 256 MiB -> 66 MiB
  with the real kernel+initrd.
* `build_data_partition_img()` loses its **256 MiB floor** (now 64 MiB). The
  20% headroom, the +32 MiB and the 64 MiB granularity are unchanged, and the
  existing content-fits check still refuses an undersized partition. Measured:
  256 MiB -> 128 MiB for a 56.5 MB payload. This floor never binds for
  desktop: a desktop medium carries multi-GB squashfs layers, and above ~135
  MiB of content the old and new arithmetic give the identical size, so the
  desktop data partition is byte-for-byte unchanged too.

### (b) udebs the server install never loads -- proved, not guessed

> **Review correction (2026-10-17).** The 69-udeb keep-set below is NOT what
> the build ships. Re-measured on the pinned
> `debian-testing-amd64-netinst-20261013` substrate, the d-i initrd's dpkg
> status holds 104 packages and does **not** include `partman-base`,
> `partman-auto`, `partman-ext3`, `partman-target`, `base-installer`,
> `bootstrap-base`, `pkgsel`, `choose-mirror`, `clock-setup`,
> `finish-install`, `apt-setup-udeb` or `user-setup-udeb`: anna loads them
> from `/cdrom`. The minimal set dropped every one of them (and, because the
> writer read the gzip initrd as a text status file, the build path measured
> zero builtins). It also dropped `partman-btrfs`, although btrfs is the
> default root filesystem in `preseed/disk-fs-chooser.sh`.
>
> The build now uses `slim_keep_set()`: keep every udeb except the provable
> classes in `provable_drop_reason()` (preseed-unused partman/kickseed/
> speech/on-screen-keyboard components and the `xfs`/`jfs` module sets),
> then re-add any of those a kept udeb still `Depends:` on. On the pinned
> amd64 substrate that is 21 dropped udebs, 10,989,328 B. The cut is
> **opt-in** (`NCZ_MAGNETAR_SLIM_SUBSTRATE=1`) until a server-variant KVM
> install has passed; by default the full pool ships and the receipt records
> `magnetar_substrate.enabled = false`. The partition sizing in (a) and the
> `--compress` option in (d) are unaffected.

`build/lib/magnetar_substrate.py` derives the keep-set from measurements:

* **The initrd already holds the modules+main closure.** The r20261013 amd64
  initrd carries 104 packages in `/var/lib/dpkg/status`; anna resolves
  `Depends:` against that status before fetching anything, and 45 of the 231
  pooled udebs are in it.
* **`preseed/early_command` udpkg-installs the NIC udebs by path.** They stay,
  and the measurement that forced this is in the module: the initrd carries
  448 `.ko` files and **zero** under `drivers/net/` (only `net/rfkill`), while
  `nic-modules` carries 122. An earlier revision of this module dropped
  `nic-modules` as "a second copy"; the real run caught it and the rule is now
  "only the non-server filesystem module sets (`xfs`, `jfs`) may be dropped by
  name", with a test that pins it.
* **`netcfg` + `net-retriever` are absent from the initrd status** and are what
  brings the link up and unpacks the rest of the chain, so they are kept;
  a pool without them fails the build instead of shipping.
* **Preseed skips whole components** (`grub-installer/skip`,
  `systemd-boot-installer/skip`, `partman-auto/method=regular`,
  `anna/no_kernel_modules=true`, no crypto/LVM/RAID/iSCSI/NBD), so the udebs
  reachable only from those are dropped with the skipping setting named as the
  reason.
* The **openssh udebs** stay (manifest) because `diag-console.sh` installs them
  by path -- remote installer diagnostics must not depend on the network it
  exists to debug.

The image receipt gains `magnetar_substrate`: kept set with reasons, dropped set
with reasons, and the **basis** the set was measured from (the initrd path).
The pool is re-indexed with `dpkg-scanpackages` after the drop, so
`Packages` lists exactly what the medium holds.

### (c) Compressing the substrate -- measured, and deliberately not done

| the substrate | tar stream | `xz -6` |
|---|---:|---:|
| all 231 udebs | 85,411,840 B | 85,064,564 B (99.6%) |
| the 162 dropped | 37,017,600 B | 36,769,596 B (99.3%) |
| the 69 kept | 48,404,480 B | 48,298,004 B (99.8%) |

udebs are `.deb` archives whose payload is already xz. A second pass recovers
0.1%, and there is no d-i-readable compressed container to put them in:
`cdrom-retriever` fetches a udeb *path* from the apt index and `dpkg-deb` reads
the file itself, so a `.tar.xz` pool needs a retriever fork and breaks
`load-cdrom`. Compressing the substrate would cost correctness for ~106 KB.
The compression that does pay is (d).

### (d) `.img.xz` / `.img.zst`

`write-usb-image.py --compress {none,xz,zst}` writes `image.img.xz|.zst` beside
the raw image (kept: it is what gets `dd`ed and what `ship-image.sh` /
`kvm-install-gate-gpt.sh` take) and records kind, level, sha256, raw size,
compressed size and ratio in the receipt. `build/build-installer-image.sh`
passes `NCZ_IMAGE_COMPRESS` through; default `none`, so nothing changes for
existing callers. Measured on this branch's amd64 image: xz -6 103,357,360 B
(4.94x), zstd -19 103,501,908 B.

### (e) udebs online: why not

`main-menu` loads the installer's udebs *before* the network exists -- `netcfg`
is itself a udeb that brings the link up. Anything needed before that must be on
the medium, and that is exactly the set the module keeps. The only udebs that
could move online are the ones no component loads at all, and those are now
simply not shipped.

### (f) arm64

Not measured for this branch: it needs the arm64 substrate pool, the arm64 d-i
initrd and a real arm64 run on ULTRA, none of which was available in this job
(`~/Projects/p3-*` and the build hosts were off-limits by the task rules).
The code is arch-parametric (`--arch arm64`, `--index`/pool path, flavour
defaulting to arch) and the two size mechanics are arch-independent, but the
numbers above are **amd64 only**. This is the main thing left unproven.

## Tests


- `build/iso/tests/test_write_usb_image_server_variant.py` — desktop stages
  the assets and demands a baked `base.squashfs`; server moves
  `rescue/firmware/kernel/branding` off the medium and pins them; the substrate
  udebs stay and the 1.8 GB of `.deb`s do not; a server build without pins
  fails; `make_targz` is deterministic.
- `build/iso/tests/test-ncz-fetch-payload.sh` — real HTTP server, real digests:
  a good manifest fetches/verifies/unpacks; a second run downloads nothing; a
  wrong pin fails the run loudly and installs nothing; an unwritable
  destination is refused *before* any bytes move; the env-only contract still
  works; an unreachable host gives up in bounded time; with no downloader the
  run fails before any attempt; busybox-only and GNU-wget-only both work.
- `build/iso/tests/test_kvm_gate_server_matrix.py` — the stub's own fetch block
  hands the medium manifest to the fetcher, and with the real fetcher installs
  from it.
- `build/iso/tests/test_patch_initrd.py` — the build fails if the final initrd
  lacks wget-udeb, including an initrd node reused from the cache.
- `test_write_usb_image_server_variant.py` also: a server build refuses a
  payload node carrying `base.squashfs`; the bundle unpacks under `assets/`;
  `NCZ_ASSETS_EXPORT_DIR` exports the pinned bytes; `late.sh`'s overlay fails
  without `assets/`.
- `build/test-build-image.sh` section 6 (the build-image server path),
  `build/test-shipped-secret-scan.sh` and `build/test-shipped-secret-scan-payload.sh`
  (`--variant server`, `--payload`), `build/test-no-ubuntu.sh` section 9
  (provenance `--variant server`).

```sh
python3 -m pytest build/iso/tests/test_write_usb_image_server_variant.py -q
sh build/iso/tests/test-ncz-fetch-payload.sh
```

## One latent fragility fixed on the way

`stage_installer_substrate()` used to build the destination path as
`stage_dir/pool/<path relative to --installer-pool>`. The production caller
passes `$SUBSTRATE_NODE/extract/pool`, so the relative path is `main/...` and
that has always been right. A caller that passed the extract *root* instead
got `pool/pool/main/...`, and then `dpkg-scanpackages --type udeb pool/main`
failed with `binary path pool/main not found` — i.e. an installer Packages
index that does not list the substrate udebs, exactly the
"empty index lets load-cdrom return, but leaves main-menu with no next
component" failure the surrounding comment warns about. The leading `pool/`
component is now stripped if present. This is a no-op for the production
desktop call (proved by the A/B above) and a fix for the extract-root form.

## Gates (build-image.sh, server media)

Every gate a desktop image passes, adapted to a medium that does not carry its
payload:

- **secret scan**: `scan-shipped-secrets.py --image <img> --variant server`
  (the receipt must say server, the medium must carry no squashfs layer and
  must carry the fetch manifest; every file on it is scanned), then
  `--payload base.squashfs --payload ncz-assets-<arch>.tar.gz` on the exact
  pinned bytes.
- **provenance**: `forky-provenance.py --image <img> --variant server
  --server-payload <run>/payload`: receipt and medium agree it is a server
  medium (no layer, no offline apt pool, a well-formed manifest pinning what
  the receipt pins), the payload hashes to its pins, and `base.squashfs`, the
  rootfs tarballs and the `.deb`s in the bundle are checked against the pinned
  snapshot and ledgers. ESP, initrd, installer-pool and kernel-purity checks
  are unchanged.
- **KVM**: the `server` and `server-offline-negative` sets (the desktop full
  gate and desktop option sets cannot install a server medium; the installer
  dialogs are judged on the desktop medium).

## The LAN-served payload

The gate serves the payload itself: it reads the pins back off the medium,
copies `<run>/payload/{base.squashfs,ncz-assets-<arch>.tar.gz}` into its work
dir under `~/Projects`, starts `python3 http.server` there bound to the
host's loopback for a `10.0.2.2` pin (QEMU user-net forwards the guest's
10.0.2.2 to it) or to the pinned LAN address of the build host, proves it
answers 200 before the guest boots, and stops it on every exit path. Nothing
is published.

## Publication: waiting on the operator

A release Magnetar medium pins a public URL (the Preview3 plan was the R2
bucket `ncz-apt`, prefix `magnetar/<preview>/<arch>/`). Uploading the payload
is an operator decision and has not been made for Preview4: the Preview4
server images are gate media marked "payload not yet published". When it is
made: rebuild the image stage with `NCZ_PAYLOAD_BASE_URL` set to the published
prefix, upload the secret-scanned `<run>/payload/` bytes, verify the public
sha256 matches the pins, then install from the published URL.

## Gate runs

- 2026-10-26, Preview4, both arches: the first real server installs found and
  fixed, in order: the stub never passed the medium's manifest to the
  fetcher; the bundle unpacked beside `assets/`; the fetcher called a
  `busybox wget` that d-i lacks; `late.sh` skipped a missing overlay
  silently; the payload cache reused the desktop node (base layer on the
  server medium). Results of the full set after those fixes are recorded in
  the next entry.
- 2026-10-26, Preview4 `079bbf39`, both arches: image, secret scan (medium
  `--variant server` and payload) and provenance PASS; the cached initrd node
  passed the wget-udeb check. In the `server` KVM set the guest fetched both
  artifacts with GNU wget and verified them (amd64 4 s, arm64 18 s), unpacked
  the base layer, then stopped at the missing on-media apt repository (see the
  correction above). No server medium has completed an install yet.
- 2026-10-26, Preview4 `d6c21317` (option A, fetcher tees to ttyS0), both
  arches: image, secret scan and provenance PASS with the pool on the medium
  (amd64: 6,901 packages checked, 0 failures). In the `server` set both
  installs completed (amd64 3 min, arm64 7 min). The installed-target checks
  passed, and the gate confirmed that the payload was fetched and its sha256
  verified, that `ssh.service` is enabled, and that there is no telnet
  surface. amd64 `server-offline-negative` PASS. Remaining failure: the installed rEFInd menu
  is the desktop one (amd64 4 entries, arm64 5) instead of Console + Rescue
  Partition; `assets/refind/ncz-refind-refresh.sh` picks the server menu only
  from an `NCZ_VARIANT` environment variable that the install (and a later
  kernel upgrade) does not set.

