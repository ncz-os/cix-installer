# Image release rule

NCZ-OS ships raw GPT disk images, `build/ncz-os-<arch>-<YYYYMMDD>-<sha>.img`,
one per architecture (amd64, arm64). There is no ISO deliverable; the upstream
Debian netinst ISO named by `UPSTREAM_ISO` / `SUBSTRATE_SHA` is the d-i
substrate the build consumes, not a product. This replaces the old
`NEXT_ISO.md`, whose recipe drove the retired ISO builder.

Every release follows this sequence.

## 1. Rebuild what changed

```bash
# Only if the shared debootstrap/kernel/firmware/Mesa layer changed:
bash build/build-squashfs-layers.sh base

# If desktop post-install hooks or manifests/desktop.pkgs changed:
bash build/build-squashfs-layers.sh desktop
```

There is **one desktop layer**. Console-only operation is a boot entry
(`systemd.unit=multi-user.target`) on the same image, not a separate squashfs.

> **Do not run the layer build with `WORK` on tmpfs.** The desktop layer
> expands well past 20 GB during verification.

## 2. Build and gate the image

```bash
make offline-mirror
make image-verified ARCH=arm64 VERSION=<VERSION>
make image-verified ARCH=amd64 VERSION=<VERSION> \
    UPSTREAM_ISO=debian-testing-amd64-netinst.iso
```

`make image` (`build/build-installer-image.sh`) writes the `.img`;
`make image-verified` then runs `build/kvm-install-gate-gpt.sh`, which installs
the image into a blank virtual disk unattended and boots the result. **The gate
is not optional:** the log must contain `GATE PASS (phase 1+2)`, and
`build/ship-image.sh` refuses to publish without it. A release once shipped with
an installer that aborted on every machine at the finish step, and it reached
hardware because no gate ran it.

Then validate on real hardware: install on the target and confirm the
accelerators with a workload, not a probe.

## 3. Ship

```bash
build/ship-image.sh build/ncz-os-<arch>-<date>-<sha>.img --gate-log <gate log>
```

`ship-image.sh` copies the image, its `.sha256`, `.receipt.json` and `.gated`
marker to the ARGONAS image archive and to the operator Mac, verifies the
sha256 at each destination, and prints the reap plan. It never writes to a USB
device.

## 4. Reap superseded images

```bash
build/reap-images.sh --arch <arch> --archive <archive dir> --dir build [--apply]
```

The default is a dry run. It keeps the newest gated image, the newest
operator-validated image and anything newer, and reaps the rest of that
architecture only (see the script header).

## 5. Publish

1. Update **`docs/releases/`** with what is in the release, and the **README**
   if capability or hardware status changed.
2. Push **ARGONAS → GitLab**. Those two green is the landing criterion.
3. Tag the release and create the GitLab release page with the image attached
   to the package registry.
4. **Remove superseded release artifacts** from the package registry; old
   images dominate project storage. **Never delete published kernel source
   packages** — GPLv2 §3(b) obliges us to keep source available to anyone who
   received the corresponding binaries.

## GitHub

`github.com/ncz-os/cix-installer` is a **documentation-only mirror**. It never
receives releases, image binaries, or source pushes. Downloads point at GitLab.
