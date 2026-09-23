# Build host roles

Operator decision, 2026-08-28.

| host | addr | role |
|---|---|---|
| **ULTRA** | 192.168.207.88 (wifi .13) | **PRIMARY build host** — ISO and kernel |
| TYDEUS | 192.168.207.73 | **Inference**, not a build host. Secondary/overflow builds only. |
| cixmini | 192.168.207.66 | Future build host, once stabilised |
| O6N | 192.168.207.3 | Future build host, once stabilised |

## Why ULTRA is primary

TYDEUS runs the fleet's GPU inference services (llama-gemma-4-31b-it-qat,
qwen38, tydeus-modeld). Builds there contend with inference for CPU and disk,
and TYDEUS needed 456G reclaimed in a single session this August just to keep
building. ULTRA has 4.0T free, 61G RAM, 10 cores, and already mounts the
ARGONAS yocto-shared export that carries DL_DIR and SSTATE_DIR.

Measured 2026-08-28:

    ULTRA   4.0T free   61G RAM   10 cores   /mnt/argonas-yocto-shared mounted
    TYDEUS  constrained          10 cores    /nfs-shared (same export, different path)

Both hosts mount the SAME ARGONAS export, so the download and sstate caches are
already shared: a kernel build moved to ULTRA reuses TYDEUS's sstate rather
than starting cold.

## What ULTRA still needs before it can build kernels

ULTRA can already build ISOs and has both container images. It does NOT yet
have the Yocto workspace. To finish the move it needs:

  - the layer checkout (openembedded-core, meta-yocto, meta-openembedded-wrynose,
    meta-cix from /mnt/argonas-git/meta-cix.git, branch
    wip/ultra/2026-07-10-linlondp-26q2)
  - a build dir whose conf/local.conf sets MACHINE=cixmini and points DL_DIR
    and SSTATE_DIR at ULTRA's mount path (/mnt/argonas-yocto-shared/{downloads,
    sstate-cache}) rather than TYDEUS's /nfs-shared/...
  - a run wrapper using podman and ncz-yocto-y6:trixie

Note the layer directory on TYDEUS is named `yocto6-ncz-tydeus`, which is
host-specific naming for something that is not host-specific. Do not copy that
name onto other hosts.

## Adding a new build host

Everything needed is committed here. On the new host: install podman, mount the
ARGONAS yocto-shared export, clone the layers, then `./build-images.sh`. The
`--rootful` flag is required where the build needs device nodes.

One host-level prerequisite is easy to miss: **rootless podman needs
/dev/net/tun** for its network setup. On TYDEUS that node did not exist at all
(CONFIG_TUN=y, built in, so there was no module to load — only the device node
was missing) and every rootless container build failed with
`slirp4netns failed: open("/dev/net/tun"): No such file or directory`.
Fixed there with /etc/tmpfiles.d/ncz-tun.conf. Check for it on any new host.
