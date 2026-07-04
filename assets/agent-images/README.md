# assets/agent-images — offline OCI image bundle

Container images bundled into the ISO so `ncz install` works **offline** (no
registry pull). Each `*.oci.tar` here is copied to the target at install time
(`/usr/local/lib/cix-installer/assets/agent-images/` via `late.sh`, and to
`/var/lib/nclawzero/agent-images/` by `30-agents.sh`), and loaded on demand:

- `ncz install mnemos` → `podman load` of `mnemos.oci.tar`, then starts the
  `mnemos.container` quadlet (`Pull=never`) on `:5002`.

The `*.oci.tar` blobs are **git-ignored** (large build-time artifacts, staged
via NFS like `base.squashfs` / the Vivaldi `.deb`). They are NOT committed —
regenerate them on a host with network + skopeo/podman.

## Regenerate `mnemos.oci.tar` (arm64)

The MNEMOS server image is multi-arch on ghcr; extract the **arm64** manifest
(Cix Sky1 is aarch64) into a tagged OCI archive:

```sh
skopeo copy --override-arch arm64 --override-os linux \
    docker://ghcr.io/ncz-os/mnemos:latest \
    oci-archive:assets/agent-images/mnemos.oci.tar:ghcr.io/ncz-os/mnemos:latest
```

Result is ~260 MB (compressed layers preserved). The archive is tagged
`ghcr.io/ncz-os/mnemos:latest` so `podman load` yields exactly the ref the
quadlet's `Image=` expects.

Verify the arm64 manifest exists before regenerating:

```sh
skopeo inspect --raw docker://ghcr.io/ncz-os/mnemos:latest | \
    python3 -c 'import sys,json;print([m["platform"]["architecture"] for m in json.load(sys.stdin)["manifests"]])'
```
