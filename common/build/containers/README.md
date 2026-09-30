# Build containers

## `Containerfile.ncz-imagebuild` -- the arm64 image-build environment for ULTRA

ULTRA is the designated arm64 IMAGE build host, but it runs Fedora Asahi
Remix, not Debian. The two pipeline stages therefore split by what each one
actually needs:

| stage | command | where it runs on ULTRA | why |
|---|---|---|---|
| 1 content | `build/build-squashfs-layers.sh all` | **bare host** | the script already handles an Asahi host explicitly (podman per-container MCS categories) and drives mkosi through podman itself, so it must not be nested inside another container |
| 2 assembly | `make image` | **inside this container** | `libdrm-debs` and the apt-mirror targets are dpkg-native and cannot run on Fedora |

Build it, then move it into the **rootful** store (stage 2 needs
`--privileged` for losetup, and rootful podman cannot see rootless images):

    podman build --build-arg BUILD_UID=$(id -u) --build-arg BUILD_GID=$(id -g) \
        -t ncz-imagebuild:trixie -f build/containers/Containerfile.ncz-imagebuild .
    podman save localhost/ncz-imagebuild:trixie | sudo podman load

Then stage 2:

    # Probe the per-host ARGONAS yocto-shared spellings. ULTRA mounts it at
    # /mnt/argonas-yocto-shared, TYDEUS at /nfs-shared, and other hosts
    # (HYDRA/ACHILLES/PROTEUS) under /mnt/argonas/datapool/yocto-shared via
    # autofs. assets/kernel/mainline is an absolute symlink into
    # /mnt/argonas-yocto-shared/kernel-staging/, so inside the container it
    # DANGLES unless the staging tree is bind-mounted in too -- the kernel-
    # debs target (Makefile, gated now on assets/kernel/mainline/KVER freshness)
    # dies with `no KVER for channel 'mainline'` otherwise. Same probing
    # convention build/stage-amd64-kernel.sh and build/preflight-freshness-
    # gate.sh already use; do not hardcode one spelling.
    KSTAGING=$(for c in /mnt/argonas-yocto-shared/kernel-staging \
                          /nfs-shared/kernel-staging \
                          /mnt/argonas/datapool/yocto-shared/kernel-staging; do \
                   [ -d "$c" ] && { echo "$c"; break; }; \
               done); \
    [ -n "$KSTAGING" ] || { echo "ERROR: ARGONAS kernel-staging not mounted on this host" >&2; exit 1; }; \
    sudo podman run --rm --privileged --net=host \
        -v "$PWD":/work/cix-installer -v /dev:/dev -v "$KSTAGING":"$KSTAGING" \
        -w /work/cix-installer -e NCZ_TARGET_ARCH=arm64 -e HOME=/root \
        localhost/ncz-imagebuild:trixie bash -lc 'make image'

### Why this file exists

`~/build-env/run.sh` on ULTRA references an `ncz-buildenv:trixie` image that
was never built, and the only image actually present, `ncz-isobuild:trixie`,
carries just xorriso and squashfs-tools. The first real arm64 build attempt
on ULTRA therefore died in `libdrm-debs` on unmet build dependencies
(`debhelper-compat`, `meson`, `libpciaccess-dev`, `libudev-dev`,
`libx11-dev`, `pkgconf`, `python3-docutils`, `python3-setuptools`). This
image is the union of the README's build-host prerequisites and the
source-build dependencies the Makefile actually reaches, so ULTRA's
designated role is reproducible from the repo instead of from one host's
home directory.

### Stage 1 is not optional

`make image` refuses to assemble media when `base.squashfs` is absent
("refusing to build install media that cannot install"). That guard is
correct. Run stage 1 first; never work around it.
