# assets/singularity — Singularity Desktop payload

`singularity-opt.tgz` is the built `/opt/singularity` tree (labwc/wlroots +
GTK4/Vala Singularity shell), the NCZ-OS 26.7 "Maximilian" desktop. It replaces
the old XFCE/X11 desktop.

**The tarball is a build-time blob and is gitignored** (like `assets/vivaldi/*.deb`
and the kernel/squashfs artifacts). It is NOT committed.

## Producing / refreshing it

Reproducible recipe (arm64 host with docker/podman):

```bash
./build/build-singularity.sh                 # -> build/sinty-out/singularity-opt.tgz
cp build/sinty-out/singularity-opt.tgz assets/singularity/singularity-opt.tgz
```

Or stage on ARGONAS and fetch at ISO-build time:

```bash
./build/build-singularity.sh --push-argonas  # -> ARGONAS:/mnt/datapool/archives/ncz/singularity/
```

## How it's consumed

- `build/build-squashfs-layers.sh` (desktop layer) stages this into the overlay
  chroot; `post-install/20-desktop.sh` extracts it to `/opt/singularity` and
  bakes it into `desktop.squashfs`.
- `build/build-iso-di.sh` also stages it to `/cixmini/assets/singularity/` for
  install-time (union-synced, baked-wins), mirroring the mali_kbase overlay.

The tarball extracts to `opt/singularity/...`, so `tar -C / -xzf` lands it at
`/opt/singularity` and touches nothing else (safe on a live rootfs).

## Structure

`bin/` (singularity-desktop shell, labwc, session launchers, apps),
`lib/` (libsingularity, plugins), `libexec/` (polkit agent + xdg portal backend),
`share/` (themes/Singularity, gschemas, applications, wayland labwc config),
`include/`.
