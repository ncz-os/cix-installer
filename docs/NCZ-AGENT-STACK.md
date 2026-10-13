# ncz agent stack + MNEMOS — operator guide

This doc covers the on-system pieces the `ncz` CLI manages:

  - `ncz install mnemos` — MNEMOS memory server (REST + OpenAI-compatible
    gateway on `:5002`, MCP HTTP/SSE on `:5004`, sqlite-backed, in-process
    embedder)
  - `ncz install zeroclaw` / `ncz agent install zeroclaw` — ZeroClaw gateway +
    agents container
  - `ncz install zoder` — ZeroClaw work-history CLI (the binary that talks
    through MNEMOS for human review of an agent's work history)
  - `ncz install nemoclaw` — NVIDIA NemoClaw OpenShell sandbox runtime
  - `ncz models pull` — host-side embedder model (nomic-embed-text-v1.5 Q8, 768-dim)

It is written for an operator who is logged into a freshly-installed NCZ-OS
box and wants to land the full memory + agent stack in one or two commands.

---

## TL;DR

```bash
sudo ncz install mnemos       # REST/OpenAI gateway :5002, MCP :5004
sudo ncz install zeroclaw     # agent gateway on :42617
sudo ncz install zoder        # CLI for MNEMOS-backed agent review
sudo ncz status               # confirm everything is up + which embedder backend is active
```

All three install paths are idempotent: re-running `sudo ncz install <thing>`
on a working system is a no-op (or a small restart).

---

## What `ncz install mnemos` does, end to end

1. **Image acquisition.** OFFLINE-FIRST. If a bundled OCI archive is present at
   `/var/lib/nclawzero/agent-images/mnemos.oci.tar` (or under the install payload),
   `podman load -i` it. Otherwise, `podman pull ghcr.io/ncz-os/mnemos-enterprise:latest`
   with 3 retries and a clear offline diagnostic on failure.
2. **MNEMOS internal-audit-token bootstrap.** Generate a per-host 256-bit token
   (`/etc/nclawzero/mnemos-audit-token`), stamp it into the active quadlet's
   `Environment=MNEMOS_INTERNAL_AUDIT_TOKEN=…` line. Robust against quadlet
   template drift: anchors after `MNEMOS_PERSISTENCE_BACKEND=sqlite`, falls
   back to `MNEMOS_SQLITE_PATH=`, then to any `[Container]` header, then
   fails loud with a clear remediation message.
3. **MNEMOS container start.** `Pull=never`, `Network=host` (Sky1 kernel has
   no veth/bridge support, so PublishPort fails on metal), sqlite-backed
   (`/data/mnemos.db` on the `mnemos-data` podman volume, persistent across
   restarts). The quadlet runs `Exec=mnemos-serve-api-and-mcp` (the image's
   API+MCP supervisor): the REST/OpenAI-compatible API on `:5002` and the MCP
   HTTP/SSE transport on `:5004`. The installer also provisions
   `MNEMOS_MCP_TOKEN` (`/etc/nclawzero/mnemos-mcp-token`) into the quadlet —
   without it the supervisor does not start the MCP child.
4. **Wait for `/health` (60 s)** before bootstrap.
5. **Direct-sqlite first-run admin bootstrap.** The standard `/admin/users`
   endpoint requires bearer auth; we don't have one on a fresh install. Insert
   a `ncz-<hostname>` user (role=root, namespace=default) + a single api_key
   row directly, using parameter binding so a hostile hostname can't break
   out of SQLite. Write the bearer token to `/etc/nclawzero/mnemos.env`
   (mode 0640, group nclawzero). Idempotent: re-running is a no-op when the
   file already has a token.
6. **Host-side embedder model pull.** `ncz models pull` downloads
   `nomic-embed-text-v1.5.Q8_0.gguf` (146 MB) from HuggingFace to
   `/opt/ncz/models/`. Idempotent (skip on sha256 match), 3 retries, clear
   offline diagnostic. Best-effort: MNEMOS still embeds via its in-image copy
   if the pull fails.
7. **SQLite memory_embeddings backfill.** MNEMOS's SQLite persistence writes
   inline embeddings to `memories.embedding` (at create_memory time) but
   semantic_search reads from `memory_embeddings` (a separate join table).
   Without a backfill, semantic_search silently returns 0 hits even when the
   inline embed succeeded. `ncz install mnemos` runs an
   `INSERT OR IGNORE INTO memory_embeddings(...) SELECT FROM memories ...`
   inside the container so semantic_search returns hits on the very next
   request. Idempotent (ON CONFLICT DO NOTHING).
8. **Print post-install guidance.** Endpoint URL, health probe command, data
   volume path, embedder backend, service status.

The full result on a fresh amd64 or arm64/Sky1 host: `ncz status` shows the
MNEMOS service active, the embedder backend and its 768-dimension (the
in-process CPU/llamacpp path is the default on BOTH arches), the model path,
the MCP transport state, and a live `/health` line.

---

## What `ncz install zeroclaw` does

Thin alias for `ncz agent install zeroclaw`, which:

  - Stages `/etc/containers/systemd/zeroclaw.container` (Pull=never, host
    networking, `EnvironmentFile=/etc/nclawzero/agent-env`).
  - Stages `/var/lib/nclawzero/zeroclaw-data` (the gateway's persistent state).
  - Loads the official `ghcr.io/zeroclaw-labs/zeroclaw:latest` image if not
    already present, or `podman pull` it from the registry as a fallback.
  - Enables + starts `zeroclaw.service`.
  - Stamps a desktop shortcut at `/etc/skel/Desktop/ZeroClaw.desktop` (and
    `/usr/share/applications/ZeroClaw.desktop`).

---

## What `ncz install zoder` does

Downloads zoder (ZeroClaw CLI for MNEMOS work history) from the public
`ncz-os/zoder` nightly release.

  - Architecture dispatch: `x86_64-unknown-linux-gnu` and
    `aarch64-unknown-linux-gnu` are the only targets today. Anything else
    fails loud with the URL so the operator can roll their own.
  - Pinned: each arch has a tarball sha256 baked into `ncz_install_zoder`;
    the inner `zoder` binary's sha256 is re-verified against the bundled
    `manifest.json`. Mismatches fail loud with the expected vs actual hashes.
  - Stages `/usr/local/bin/zoder` (mode 0755).
  - Stages `/etc/zoder/manifest.json` (engine SHA + upstream SHA + run link
    for auditability).
  - Stages `/etc/nclawzero/zoder.conf` — a PUBLIC-SAFE sample documenting
    `MNEMOS_URL` + `MNEMOS_TOKEN` placeholders. NO site-specific model
    routes or endpoints, NO Anthropic (project ban). Operators populate
    `MNEMOS_TOKEN` from `/etc/nclawzero/mnemos.env`.
  - Smoke test: `zoder --version` must run; an install that silently leaves
    a non-runnable binary exits 1.

zoder itself is a CLI — it's not a daemon. To use it:

```bash
set -a; source /etc/nclawzero/mnemos.env; set +a
export MNEMOS_URL="$MNEMOS_BASE_URL"
unset MNEMOS_USER    # zoder reads only MNEMOS_TOKEN + MNEMOS_URL
zoder -h
zoder search 'test query'
```

---

## `ncz models pull` details

Public source: HuggingFace `nomic-ai/nomic-embed-text-v1.5-GGUF`.

```text
URL:    https://huggingface.co/nomic-ai/nomic-embed-text-v1.5-GGUF/resolve/main/nomic-embed-text-v1.5.Q8_0.gguf
sha256: 3e24342164b3d94991ba9692fdc0dd08e3fd7362e0aacc396a9a5c54a544c3b7
size:   146 MB
target: /opt/ncz/models/nomic-embed-text-v1.5.Q8_0.gguf
```

The hash matches the file baked into `ghcr.io/ncz-os/mnemos-enterprise:latest`
at `/opt/mnemos/models/<file>.gguf`. If HuggingFace rotates the file, the
install refuses with the expected-vs-actual mismatch so the operator bumps
the pin and re-rolls `ncz`.

Public source only — no Anthropic fork, no private mirror.

---

## `ncz status` output (after a successful install)

```text
ncz:                       0.2.0
hostname:                  ncz-example
kernel:                    7.3.0-rc7-t2-ncz
BUILD_VARIANT:             desktop
default-target:            graphical.target
NPU:                       absent
GPU /dev/dri/renderD128:   present
Vulkan devices:            Intel(R) ...
models:                    0 .cix / 1 .gguf files in /opt/ncz/models
mnemos service:            active
mnemos embedder:           llamacpp (default) (dim=768)
mnemos model:              (in-image) /opt/mnemos/models/nomic-embed-text-v1.5.Q8_0.gguf
mnemos mcp:                enabled (:5004)
mnemos health:             {"status":"healthy",...}
zeroclaw:                  active
zoder:                     zoder 0.2.1
```

On both arches the default embedder is the in-process CPU/llamacpp path at
768 dimensions, and the model line reports the in-image GGUF. The NPU path is
opt-in (see below) and is only reported when the quadlet has been configured
for it.

---

## What we deliberately don't do (operator notes)

  - The NPU embedder on Sky1 currently has a UMD ABI gap (Cix 26Q2 will close
    it). `ncz install mnemos` keeps the in-process CPU embedder active and
    makes the NPU path opt-in with `NCZ_MNEMOS_NPU=1`; until the gap is closed
    the NPU path cannot produce usable vectors.
  - We don't `podman exec` into the mnemos container to wire up custom
    secrets, site-specific model routes, or alternative MNEMOS backends. The
    embedder is in-process llama-cpp-python; the network policy is whatever
    the operator's network is.
  - zoder has no apt package. It ships only as a GitHub release asset. On a
    closed LAN, `ncz install zoder` fails loud; the operator retries when
    the network is up.
---

## Stopping and removing

Every component installs as a systemd (quadlet) service, so stop/disable is the
removal path — there is no hidden state:

```bash
# MNEMOS
sudo systemctl disable --now mnemos.service
sudo rm -f /etc/containers/systemd/mnemos.container && sudo systemctl daemon-reload
sudo podman volume rm mnemos-data          # optional: drop stored memories

# agent gateways (zeroclaw / openclaw / hermes / portainer)
sudo ncz agent uninstall <name>            # or: --all

# zoder (a single binary + a sample config)
sudo rm -f /usr/local/bin/zoder /etc/zoder/manifest.json /etc/nclawzero/zoder.conf
```

`ncz install mnemos` and `ncz install <name>` are idempotent: re-running them on
a working system re-stages the quadlet only when needed and restarts the
service, without duplicating containers or volumes.
