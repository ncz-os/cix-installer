# ISO release rule

**There is exactly one valid ISO at a time.** Every rebuild follows this
sequence.

> **Pipeline note (2026-09-22):** the arm64/Sky1 production path is
> `build/build-iso-di.sh` (the script below). The new xorriso-based
> amd64 writer (`build/iso/write-image.py` + sibling scripts) supersedes
> it for amd64; that path uses the same content producer
> (`build-squashfs-layers.sh`) but a different assembly stage. arm64 has
> not yet been migrated to the new writer (no amd64 parity yet) — see
> `docs/superpowers/specs/2026-09-21-incremental-di-iso-assembly-design.md`.

## 1. Rebuild what changed

```bash
# Only if the shared debootstrap/kernel/firmware/Mesa layer changed:
bash build/build-squashfs-layers.sh base

# If desktop post-install hooks or manifests/desktop.pkgs changed:
bash build/build-squashfs-layers.sh desktop
```

There is **one desktop layer**. NCZ-OS ships a single build; console-only
operation is a boot entry (`systemd.unit=multi-user.target`) on the same
image, not a separate squashfs. Any `server` target in older instructions is
obsolete.

> **Do not run the layer build with `WORK` on tmpfs.** The desktop layer
> expands well past 20 GB during verification. `/tmp` on the build host is a
> 32 GB tmpfs; the script relocates automatically, but a manual `WORK=`
> override on tmpfs will fail at ~21% and report as archive corruption.

## 2. Bake the ISO (arm64/Sky1 production path)

```bash
sudo ./build/build-iso-di.sh \
  --bookworm-iso downloads/debian-testing-arm64-netinst.iso \
  --root . \
  --version <VERSION> \
  --output build/nclawzero-installer-cixmini-<VERSION>.iso
```

> **Note on the `--bookworm-iso` flag name:** the flag is historical
> (predates the Bookworm→Forky substrate migration). The actual substrate
> is `debian-testing-arm64-netinst.iso`, which is **Debian Testing /
> Forky**, NOT Bookworm — see `release.conf`'s `NCZ_BASE_CODENAME=forky`
> and `Makefile`'s `UPSTREAM_ISO` default. The Makefile target `make iso`
> passes the right ISO automatically; calling `build-iso-di.sh` by hand
> is for explicit substrate override or gate-only invocation.

## 3. Bake the ISO (amd64 — new xorriso writer)

The new amd64 path is a Python composition, not a single shell call:

```bash
# 1. Import the d-i substrate (Bookworm amd64 netboot, pinned by hash).
#    One-shot per substrate; subsequent builds reuse the cache:
bash build/iso/import-substrate.py --arch amd64 \
    --iso-url https://deb.debian.org/debian/dists/bookworm/main/installer-amd64/current/images/netboot/mini.iso

# 2. Build the rEFInd ESP image (deterministic, content-hashed):
bash build/iso/build-refind-esp.py --arch amd64

# 3. Stage the ncz-payload + patched debootstrap stub:
bash build/iso/stage-ncz-payload.py --arch amd64
bash build/iso/patch-debootstrap-stub.py --arch amd64

# 4. Compose the bootable ISO:
bash build/iso/write-image.py --arch amd64 --mode cold \
    --output build/ncz-cold-amd64-<VERSION>.iso

# 5. Verify independently:
bash build/iso/verify-image.py build/ncz-cold-amd64-<VERSION>.iso
```

> **Real, current amd64 status (2026-09-22):** base-only ISO is
> boot-verified end-to-end (1.69 GB). Desktop squashfs is NOT yet
> staged for the new writer, and arm64/Sky1 has never been attempted
> with the new writer. Both are real gaps — do not imply otherwise.

## 4. Gate it before it reaches hardware

```bash
sudo ./build/kvm-install-gate.sh build/nclawzero-installer-cixmini-<VERSION>.iso
```

This installs the ISO into a blank NVMe target unattended and boots the
result. **This step is not optional.** A release once shipped with an
installer that aborted on every machine at the finish step, and it reached
hardware because no gate ran it.

Then validate on real hardware: install on an O6N or MS-R1 and confirm the
accelerators with a workload, not a probe.

## 5. Publish

1. Update **`docs/releases/<VERSION>.md`** with what is in the release, and the
   **README** if capability or hardware status changed.
2. Push **ARGONAS → GitLab**. Those two green is the landing criterion.
3. Tag the release and create the GitLab release page with the ISO attached to
   the package registry.
4. **Remove superseded releases and their ISO artifacts.** Old ISO packages are
   ~5 GB each and dominate project storage:
   ```bash
   curl -X DELETE -H "PRIVATE-TOKEN: $TOK" \
     "https://gitlab.com/api/v4/projects/ncz-os%2Fcix-installer/packages/<id>"
   ```
   **Never delete published kernel source packages** — GPLv2 §3(b) obliges us
   to keep source available to anyone who received the corresponding binaries.

## GitHub

`github.com/ncz-os/cix-installer` is a **documentation-only mirror**. It never
receives releases, ISO binaries, or source pushes. Refresh its docs commit when
the documentation changes; do not create GitHub releases or tags. Downloads
point at GitLab.

## Current release

**NCZ-OS 26.7 "Maximilian"**, installer `2026.08.18-v12`.

- **One kernel:** `7.2.0-sky1-ncz`. The 7.0.12 channel has been removed from
  the image — it is not a fallback and not a rescue kernel.
- **Desktop:** Singularity (labwc/wlroots, Wayland-native; X11/XFCE removed).
- **GPU:** both drivers ship — `mali_kbase` default, `panthor` selectable via
  boot entry or `ncz-gpu-select`.
- **Updates:** Buildkite Packages (`ncz-os/ncz`) primary, Cloudflare R2 as an
  independent second apt source.
- **Kernel source:** `kernel-source/` in this repository, including the
  as-built `.config`. Recipes on GitLab `ncz-os/meta-cix`.
- A dedicated **NCZRESCUE** partition (full toolset, self-configuring network)
  ships on every install and is a release gate.
