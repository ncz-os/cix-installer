# NCZ Magnetar — multi-arch OCI container plan

**Status:** DRAFT 2026-05-06 by Claude Opus 4.7 in jperlow-mlt session — pending build execution + manifest publish.
**Strategic frame:** R75 rebake list item M4 (multi-arch OCI manifest, linux/amd64 + linux/arm64). The container is the **Mac/cloud surface** for Magnetar; ISO variants (M1 Cix-arm64, M2 Pi-arm64, M3 Intel-x86) are the **bare-metal surfaces**. Same agentic stack, different deploy substrate.

---

## What goes in the container

**Single image, two arches.** Identical software stack on linux/amd64 and linux/arm64 — only difference is the embedder backend selected at runtime per `MNEMOS_EMBEDDER` env var (rule M5 in r75 list).

| Component | Source | Pin strategy |
|---|---|---|
| MNEMOS server | `mnemos-os/mnemos` | tagged release (currently v4.1.x, plan v5.0 cut before Magnetar GA) |
| GRAEAE | `mnemos-os/mnemos` (bundled) | same as MNEMOS |
| Postgres 17 + pgvector | `pgvector/pgvector:pg17` | upstream digest pin |
| NATS JetStream | `nats:2-alpine` | upstream digest pin |
| Redis 8 | `redis:8-alpine` | upstream digest pin |
| Hatchet workflow engine | `hatchet-dev/hatchet` | tagged release once v5 design lands |
| Embedder runtime | conditional — `fastembed-cpu` always present; `mnemos-embedder-cix-npu` (arm64-only, vendored cixtech artifacts), `mnemos-embedder-openvino` (amd64-only, OpenVINO 2026.1.0) | MNEMOS_EMBEDDER picks |
| zeroclaw + openclaw + hermes | upstream OCI images, pulled at first start (compose-style) — NOT baked, per fleet rule "we don't maintain those, pull upstream" | digest-pinned in compose file |

**Sidecars vs in-image:** zeroclaw/openclaw/hermes stay as separate containers under the Magnetar pod (Podman) or stack (Docker Compose). The Magnetar image itself is just MNEMOS + storage backends + workflow + embedder.

---

## Why one multi-arch image, not two

**Reproducibility**: a single `quay.io/nclawzero/magnetar:v26.5.r75` resolves to the right arch via OCI manifest list. Mac-arm64 (Podman/Docker Desktop) gets the linux/arm64 layers; cloud-x86 (any standard runtime) gets linux/amd64. Same Compose file works everywhere.

**Anti-fragmentation**: Pi-arm64 (Magnetar Pi M2) and Cix-arm64 (Magnetar Cix M1) are **bare-metal ISO** deploys, not container deploys. The container is for users who want Magnetar without flashing hardware. Two manifest entries (amd64 + arm64) cover that surface; we don't need a separate Pi-flavored container.

**Drift prevention**: rule F2 + F4 (fair-comparison doctrine, surface to Intel team in parallel with Jetson). One image means there's one binary path the user experiences, regardless of hardware. Differences live at runtime config (MNEMOS_EMBEDDER), not at image-build time.

---

## Build topology

Per fleet build-routing-matrix (`~/.claude/projects/-Users-jperlow/memory/reference_build_routing_matrix.md`):

| Layer | Build host | Why |
|---|---|---|
| linux/amd64 layers | TYPHON (192.168.207.61) | x86_64 native, RTX 5060 for any GPU-touching test stages |
| linux/arm64 layers | ULTRA (192.168.207.60) | macOS arm64 host running Podman 5.8.2 in Linux container env (`~/build-env/podman-rust-build.sh`) |
| Manifest combine | jperlow-mlt | Mac-side `podman manifest create + add + push` — no compute, just OCI metadata stitching |
| Registry | `quay.io/nclawzero/magnetar` (canonical) + `ghcr.io/perlowja/magnetar` (mirror) | quay = OSS-friendly tier; ghcr = mirror for users who already have GitHub auth wired |

**ARGONAS** (192.168.207.101) keeps the build artifacts as backup tarballs (`podman save`).

---

## Containerfile sketch (ASCII-only — see /docs/CONTAINERFILE.magnetar for canonical)

```dockerfile
# syntax=docker/dockerfile:1.7
ARG TARGETARCH

FROM debian:13-slim AS base
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl python3 python3-pip python3-venv \
        postgresql-client nats-server redis-tools \
        && rm -rf /var/lib/apt/lists/*

# Embedder layer — conditional per arch
FROM base AS embedder-amd64
RUN python3 -m venv /opt/embedder \
    && /opt/embedder/bin/pip install --no-cache-dir openvino==2026.1.0 \
        optimum[openvino]==1.21.* transformers==4.46.* numpy==2.* \
    && /opt/embedder/bin/python -c "from optimum.intel import OVModelForFeatureExtraction"

FROM base AS embedder-arm64
# Cix NPU ctypes wrapper + libnoe runtime; FyrbyAdditive aipu kernel module
# is host-side (not in container).
RUN python3 -m venv /opt/embedder \
    && /opt/embedder/bin/pip install --no-cache-dir \
        numpy==2.* transformers==4.46.* fastembed==0.4.* \
    && mkdir -p /opt/cix
COPY --chmod=0755 npu_embed_v2.py /opt/cix/npu_embed_v2.py
# libnoe.so itself is bind-mounted from host /usr/share/cix/lib at runtime;
# container ships only the Python wrapper + tokenizer config.

# Final image
FROM embedder-${TARGETARCH} AS final
RUN python3 -m venv /opt/mnemos \
    && /opt/mnemos/bin/pip install --no-cache-dir mnemos==5.0.*
ENV MNEMOS_EMBEDDER=fastembed_cpu \
    MNEMOS_BIND=0.0.0.0:5002 \
    PATH=/opt/mnemos/bin:/opt/embedder/bin:/usr/local/bin:/usr/bin:/bin
EXPOSE 5002 5003 5004
CMD ["mnemos", "serve"]
```

**Embedder dispatch** (runtime, `mnemos serve` boot path):

```python
backend = os.environ.get("MNEMOS_EMBEDDER", "fastembed_cpu")
if backend == "cix_npu":
    from cix.npu_embed_v2 import NPUEmbedder
    emb = NPUEmbedder("/host/cix/bge-small-zh_256.cix",
                     "/host/cix/lib/libnoe.so")
elif backend == "openvino":
    from mnemos.embedders.openvino import OpenVINOEmbedder
    emb = OpenVINOEmbedder("BAAI/bge-small-en-v1.5", device="GPU")
elif backend == "hailo":
    from mnemos.embedders.hailo import HailoEmbedder
    emb = HailoEmbedder("...")
else:
    from fastembed import TextEmbedding
    emb = TextEmbedding("BAAI/bge-small-en-v1.5")
```

---

## Build commands (canonical sequence)

### On TYPHON (linux/amd64)
```bash
cd ~/magnetar-build
podman build \
    --platform linux/amd64 \
    --build-arg TARGETARCH=amd64 \
    --tag magnetar:v26.5.r75-amd64 \
    -f Containerfile.magnetar .
podman save -o /tmp/magnetar-amd64.tar magnetar:v26.5.r75-amd64
scp /tmp/magnetar-amd64.tar jperlow@jperlow-mlt:/tmp/
```

### On ULTRA (linux/arm64)
```bash
ssh jasonperlow@ultra
cd ~/build-env
./podman-rust-build.sh   # opens persistent rust-build container
# Inside container:
cd ~/magnetar-build
podman build \
    --platform linux/arm64 \
    --build-arg TARGETARCH=arm64 \
    --tag magnetar:v26.5.r75-arm64 \
    -f Containerfile.magnetar .
podman save -o /tmp/magnetar-arm64.tar magnetar:v26.5.r75-arm64
# Outside container, scp to local Mac:
scp /tmp/magnetar-arm64.tar jperlow@jperlow-mlt:/tmp/
```

### On jperlow-mlt (manifest stitch + push)
```bash
# Load both arch tarballs into local podman
podman load -i /tmp/magnetar-amd64.tar
podman load -i /tmp/magnetar-arm64.tar

# Tag for the canonical registry
podman tag magnetar:v26.5.r75-amd64 quay.io/nclawzero/magnetar:v26.5.r75-amd64
podman tag magnetar:v26.5.r75-arm64 quay.io/nclawzero/magnetar:v26.5.r75-arm64

# Push individual arches first (needed for manifest assembly)
podman push quay.io/nclawzero/magnetar:v26.5.r75-amd64
podman push quay.io/nclawzero/magnetar:v26.5.r75-arm64

# Build the manifest list
podman manifest create quay.io/nclawzero/magnetar:v26.5.r75
podman manifest add quay.io/nclawzero/magnetar:v26.5.r75 \
    quay.io/nclawzero/magnetar:v26.5.r75-amd64
podman manifest add quay.io/nclawzero/magnetar:v26.5.r75 \
    quay.io/nclawzero/magnetar:v26.5.r75-arm64
podman manifest push --all quay.io/nclawzero/magnetar:v26.5.r75 \
    docker://quay.io/nclawzero/magnetar:v26.5.r75

# Same for ghcr mirror
for a in amd64 arm64; do
    podman tag magnetar:v26.5.r75-$a ghcr.io/perlowja/magnetar:v26.5.r75-$a
    podman push ghcr.io/perlowja/magnetar:v26.5.r75-$a
done
podman manifest create ghcr.io/perlowja/magnetar:v26.5.r75
podman manifest add  ghcr.io/perlowja/magnetar:v26.5.r75 ghcr.io/perlowja/magnetar:v26.5.r75-amd64
podman manifest add  ghcr.io/perlowja/magnetar:v26.5.r75 ghcr.io/perlowja/magnetar:v26.5.r75-arm64
podman manifest push --all ghcr.io/perlowja/magnetar:v26.5.r75 \
    docker://ghcr.io/perlowja/magnetar:v26.5.r75
```

### Verify
```bash
podman manifest inspect quay.io/nclawzero/magnetar:v26.5.r75 | jq '.manifests[].platform'
# Expect:
#   { "architecture": "amd64", "os": "linux" }
#   { "architecture": "arm64", "os": "linux" }

# Pull from a Mac (auto-selects arm64)
docker pull quay.io/nclawzero/magnetar:v26.5.r75
docker inspect --format='{{.Architecture}}' quay.io/nclawzero/magnetar:v26.5.r75
# Expect: arm64

# Pull from x86 (auto-selects amd64)
ssh typhon 'docker pull quay.io/nclawzero/magnetar:v26.5.r75 \
    && docker inspect --format="{{.Architecture}}" quay.io/nclawzero/magnetar:v26.5.r75'
# Expect: amd64
```

---

## Compose file (for end-users)

`docker-compose.magnetar.yml` — what users `docker compose up -d`:

```yaml
services:
  magnetar:
    image: quay.io/nclawzero/magnetar:v26.5.r75
    environment:
      MNEMOS_EMBEDDER: ${MNEMOS_EMBEDDER:-fastembed_cpu}
      MNEMOS_BIND: 0.0.0.0:5002
      DATABASE_URL: postgres://mnemos:mnemos@postgres:5432/mnemos
      NATS_URL: nats://nats:4222
      REDIS_URL: redis://redis:6379/0
    ports:
      - "5002:5002"
      - "5003:5003"  # MCP HTTP
      - "5004:5004"  # MCP SSE
    volumes:
      - magnetar-data:/var/lib/mnemos
      # Cix users only — bind libnoe + .cix model from host
      - ${CIX_LIB:-/dev/null}:/host/cix/lib:ro
      - ${CIX_MODELS:-/dev/null}:/host/cix:ro
    depends_on: [postgres, nats, redis]

  postgres:
    image: pgvector/pgvector:pg17
    environment:
      POSTGRES_USER: mnemos
      POSTGRES_PASSWORD: mnemos
      POSTGRES_DB: mnemos
    volumes: [postgres-data:/var/lib/postgresql/data]

  nats:
    image: nats:2-alpine
    command: ["-js", "-sd", "/data"]
    volumes: [nats-data:/data]

  redis:
    image: redis:8-alpine
    volumes: [redis-data:/data]

  # Optional — agent containers, separately maintained upstream
  zeroclaw:
    image: ghcr.io/perlowja/nclawzero-demo:latest
    environment:
      MNEMOS_URL: http://magnetar:5002
    profiles: [agents]

  openclaw:
    image: ghcr.io/openclaw/openclaw:main
    profiles: [agents]

  hermes:
    image: docker.io/nousresearch/hermes-agent:latest
    profiles: [agents]

volumes:
  magnetar-data:
  postgres-data:
  nats-data:
  redis-data:
```

`docker compose --profile agents up -d` to bring up the full stack including agents; default profile is just MNEMOS + storage.

---

## Sequencing within r75

Per R75-REBAKE-LIST H ordering, M4 (this work) sequences after **M5 (pluggable embedder selector)** lands in MNEMOS upstream. Without M5 the container can only ship one embedder backend, defeating the multi-arch story.

Order:
1. M5 lands in `mnemos-os/mnemos` master (PR per F5)
2. MNEMOS v5.0 cut tagged
3. **This work** — build linux/amd64 layers on TYPHON, linux/arm64 on ULTRA, manifest-stitch on jperlow-mlt
4. Push to quay + ghcr
5. Smoke-test: pull on Mac (arm64) + on x86 cloud (amd64), both run `docker compose up`, both pass MNEMOS health probe + agentic-memory smoke

If M5 slips, this can ship as v26.5.r75 with `MNEMOS_EMBEDDER=fastembed_cpu` hardcoded — degrades to "everyone uses CPU embedder" but still works as a Mac developer-loop deploy. Cix NPU + Intel iGPU paths gate on M5.

---

## Open questions before publish

1. **Quay vs ghcr canonical**: I lean quay.io for the OSS-friendly framing, ghcr for the mirror. Open to flip.
2. **Image size budget**: estimated ~1.2 GB amd64 (OpenVINO is heavy) / ~600 MB arm64 (fastembed only) — within reason for a Mac developer-loop pull. Could split openvino into a separate `magnetar-intel` flavor if size complaints come in.
3. **License headers in Containerfile**: Apache-2.0 NOTICE block at top; verify before push.
4. **Cix `.cix` model handling**: bind-mount-only (host carries `bge-small-zh_256.cix`) keeps the container generic. Alternative is to bake the model in arm64-only flavor — defer until Cix users complain about the bind-mount UX.
5. **NoMachine in container?** No — Magnetar container is headless-only (no display server inside). Users who want graphical access run NoMachine on the host (Cix-arm64 ISO ships it; Mac/cloud users use their host UI). Document explicitly so nobody expects `docker compose up` to give them a desktop.

---

## Codex review gate

This document + the Containerfile + compose YAML must pass `codex-companion adversarial-review` before publish per PRIMARY DIRECTIVE #4. Specific concerns to surface:

- Is the OpenVINO version pin (2026.1.0) the latest supported on Debian 13 slim?
- Does the manifest list publish strategy work cleanly across both Quay and ghcr (different OCI auth quirks)?
- Is the bind-mount UX for Cix `.cix` model + libnoe sustainable, or will it create support tickets?
- Reverse-DNS naming: quay.io/nclawzero vs quay.io/perlowja — which is canonical?
- Multi-arch Containerfile pattern (`embedder-${TARGETARCH}` stages) — is this idiomatic enough, or should we split into two Containerfiles?

---

*Living doc. Update inline as M5 lands and the build pipeline gets exercised.*
