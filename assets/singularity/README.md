# assets/singularity — Singularity Desktop payload

`/opt/singularity` (labwc/wlroots + GTK4/Vala Singularity shell) is the
NCZ-OS 26.7 "Maximilian" desktop. It replaces the old XFCE/X11 desktop.

> **Install mechanism changed:** as of the Buildkite-primary/R2-backup apt
> hosting work, `post-install/20-desktop.sh` installs Singularity as a real
> **`.deb` package** (`apt-get install ncz-singularity-desktop` from the
> NCZ-OS apt repo) — **not** by extracting `singularity-opt.tgz` from this
> directory. The tarball-extraction recipe below (`build-singularity.sh` →
> `singularity-opt.tgz` → `tar -xzf`) describes an earlier packaging
> approach and is superseded; see `post-install/20-desktop.sh` for the
> current apt-based install path. `build/build-singularity.sh` may still be
> useful as the underlying build recipe that produces the payload which
> then gets packaged into the `.deb` — check that script before assuming
> the tarball flow below is still how the ISO gets built.

**Any tarball staged here is a build-time blob and is gitignored** (like
`assets/vivaldi/*.deb` and the kernel/squashfs artifacts). It is NOT
committed.

## Producing / refreshing the payload (historical tarball flow)

Reproducible recipe (arm64 host with docker/podman):

```bash
./build/build-singularity.sh                 # -> build/sinty-out/singularity-opt.tgz
cp build/sinty-out/singularity-opt.tgz assets/singularity/singularity-opt.tgz
```

Or stage on ARGONAS and fetch at ISO-build time:

```bash
./build/build-singularity.sh --push-argonas  # -> ARGONAS:/mnt/datapool/archives/ncz/singularity/
```

## How it's consumed (current)

- `post-install/20-desktop.sh` installs the `ncz-singularity-desktop` `.deb`
  via `apt-get install` from the NCZ-OS apt repo (Buildkite Packages
  primary, Cloudflare R2 backup — see the top-level README's OTA channel
  section), which lands the payload at `/opt/singularity`.
- The `.deb`'s postinst configures the shared-library path (see
  `post-install/20-desktop.sh` header comment).

If `/opt/singularity` extracts to `opt/singularity/...`, `tar -C / -xzf`
would land it at `/opt/singularity` and touch nothing else (safe on a live
rootfs) — but this is no longer how it's installed; noted here only in case
the tarball path is ever needed again for a build-host-local test.

## Structure

`bin/` (singularity-desktop shell, labwc, session launchers, apps),
`lib/` (libsingularity, plugins), `libexec/` (polkit agent + xdg portal backend),
`share/` (themes/Singularity, gschemas, applications, wayland labwc config),
`include/`.
