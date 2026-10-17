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
5. `ncz-fetch-payload.sh` reads `ncz-fetch-payload.manifest` and fetches each
   artifact, **verifying its sha256 before use**: bounded retries with
   exponential backoff, HTTP `Range` resume, an overall deadline, a DNS
   readiness probe, idempotency (an already-verified artifact is not
   re-downloaded), and a loud serial failure. Any failure is fatal — an
   unverified rootfs is never installed.
6. The stub links `sqtools` in and extracts. The wipe of `$TARGET` deliberately
   skips `ncz-online`; deleting it would delete the file just verified.
7. `late.sh` (still a real `preseed/late_command`) unions the fetched
   `assets/` into `/target/usr/local/lib/cix-installer/assets/`, asserts
   `assets/{rescue,kernel,firmware,branding}` really arrived, and removes the
   staging root so it does not live inside the installed root filesystem.

Every post-install hook therefore still finds what it expects at
`$INSTALLER_META/assets/...`.

## Build inputs

The URLs and digests are build inputs, not something the writer invents. A
server build **refuses** to run without them, because a medium whose payload
cannot be verified can only fail at the operator's prompt on a headless box:

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
  regression cannot return. `build/build-installer-image.sh` no longer passes
  `256`. Measured: 256 MiB -> 66 MiB with the real kernel+initrd.
* `build_data_partition_img()` loses its **256 MiB floor** (now 64 MiB). The
  20% headroom, the +32 MiB and the 64 MiB granularity are unchanged, and the
  existing content-fits check still refuses an undersized partition. Measured:
  256 MiB -> 128 MiB for a 56.5 MB payload.

### (b) udebs the server install never loads -- proved, not guessed

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
  works; an unreachable host gives up in bounded time.

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

## Not yet proven

`build/kvm-install-gate-gpt.sh`'s **server variant mode** has **not** been
run against a real server image. The 2026-10-17 work added two
`NCZ_KVM_GATE_VARIANTS` sets to the gate (`server`,
`server-offline-negative`), the `NCZ_PAYLOAD_URL`/`NCZ_ASSETS_URL`
environment override, and a local HTTP server the gate starts on the
QEMU user-net gateway before the guest boots. Proven so far:

- **The payload HTTP server is a tested path.** `build/test-kvm-gate-server.sh`
  runs the exact `python3 - "$SRV_DIR" "$host" "$port" <<'PY'` heredoc
  invocation the gate uses, proves `sys.argv[1:]` carries the arguments,
  starts the server, GETs both served artifacts through it, and tears it
  down. This runs in CI (it is part of `make test`), on a local port,
  rootless.
- **The gate's server-set assertions are unit-tested** by
  `build/iso/tests/test_kvm_gate_server_matrix.py` (matrix wiring, the
  fetcher's refusal behaviour on a stopped server, the menu/ssh/desktop
  assertions against synthetic installed-root artifacts).
- **The build side** (`NCZ_VARIANT=server` medium: server menu, no desktop
  packages, fetcher pins (the gate's serve base for a gate medium, the published payload for release), BUILD_VARIANT
  stamped) is unit-tested by `test_write_usb_image_server_variant.py` and
  the build-image.sh / write-usb-image.py changes pass their suites.

**Not yet proven: the orchestrator's real gate run** — a full QEMU install
of a `NCZ_VARIANT=server` medium through the `server` set (guest reaches
the gate's 10.0.2.2 server, fetches + sha256-verifies the payload from
the network, installs, and all the installed-root assertions pass) and the
`server-offline-negative` run (loud bounded failure, no half-written
rootfs). First real run: record its result here (arch, run date, PASS/FAIL
per set, and the evidence paths).

**Known gap: `build-image.sh` does not yet drive a server gate end to end.**
Found in review 2026-10-17; each fails loudly, none affects desktop builds:

- Nothing pins a gate medium to the gate's server: `ncz_gate_serve_payload_base_url()`
  has no caller, so `NCZ_PAYLOAD_URL`/`NCZ_PAYLOAD_SHA256`/`NCZ_ASSETS_URL` must be
  supplied by hand for `NCZ_VARIANT=server`.
- `write-usb-image.py` builds the asset bundle inside its own work dir and deletes it
  on exit, so the gate has no bundle to serve.
- `stage_kvm_gate` runs the first (full) gate and the default `norescue minimal stalefs`
  sets in desktop mode on a server image, and passes `$RUN_DIR/kvm-gate-options/<set>`
  to the gate, whose default payload paths then resolve under `kvm-gate-options/`.

Until this is wired, run the server sets by hand with `NCZ_GATE_SERVER_PAYLOAD` and
`NCZ_GATE_SERVER_ASSETS` set.

The accelerator hook's server-mode branch (skip `ncz-vc4-sway-
accelerators` on the variant root, skip the rEFInd Mali/Panthor +
no-accel entries) runs only when a `BUILD_VARIANT=server` medium is
installed; its assertions are the server-set assertions above.

(Pre-2026-10-17, the gate had no server mode at all; the measurement
build that wrote the first version of this doc also had no sudo, so the
loop-mount step of `build_data_partition_img()` was not exercised end to
end. The fetch script's own failure and idempotency behaviour *is* covered
against a real HTTP server by the fetcher test above.)