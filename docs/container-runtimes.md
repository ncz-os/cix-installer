# Deploying zeroclaw with containers: Docker vs Podman (quadlets) vs OrbStack vs Colima

**Status:** Reference doc — 2026-06-02 by Jason Perlow.
**Audience:** Anyone deploying `zeroclaw` (the agent runtime) in their own environment — a solo developer on a laptop, or an ops team running it across a fleet of Linux servers. This guide answers one question: *you want to run `zeroclaw` reliably as a container — which runtime do you pick, and how do you deploy it idempotently?*

The short version:

- **On Linux servers, run zeroclaw under Podman quadlets.** A quadlet gives you a real systemd service with no daemon, rootless by default, auto-restart, journald logs, and a declarative config you can commit to git. This is the recommended production pattern.
- **On a Mac, run it under OrbStack or Colima** — both are mac-arm-native VMs. OrbStack for a polished GUI, Colima if you want fully-OSS and CLI-first.
- **Docker works everywhere** and is the lowest-friction way to start, but on servers you'll usually want to graduate to Podman quadlets for real service lifecycle.

The rest of this doc explains the zeroclaw deployment decision first, then the runtime details behind it (including what a quadlet actually is and why it beats compose for servers).

---

## 1. The zeroclaw deployment decision

| Where you're deploying zeroclaw | Use | Why |
|---|---|---|
| **Linux server (production)** | **Podman + quadlet** | native systemd lifecycle, rootless, daemonless, auto-restart, declarative config in git, idempotent re-apply |
| **Mac (development)** | **OrbStack** or **Colima** | mac-arm-native VM; OrbStack for polish, Colima for fully-OSS / CLI-first |
| **CI pipeline** | **rootless Podman** | no daemon to provision, no privileged socket, runs as the CI user, reproducible |
| **You're already on Docker** | **Docker** (then migrate) | lowest friction to start; move servers to Podman + quadlets when you need real service lifecycle |

Throughout this doc, two things are placeholders you fill in for your own environment:

- **`<org>`** — the registry org/namespace your zeroclaw image lives under (e.g. your GitHub org under `ghcr.io/<org>/zeroclaw`, or your private registry path). Substitute your own.
- **`${ZEROCLAW_VERSION}`** — the image tag you want to run. **Pin a specific version in production** (e.g. a release tag or digest) so deploys are reproducible. Use `latest` only when you deliberately want rolling upgrades (see §3).

---

## 2. Podman + quadlets — the recommended server pattern

### What a quadlet IS

A **quadlet** is a small declarative unit file that describes a container (or pod, volume, or network) using systemd-style syntax. You drop it in a systemd unit directory and Podman's generator turns it into a *real* systemd service at boot/reload. You then manage the container with `systemctl` exactly like any other service.

The file types:

| Extension | Describes |
|---|---|
| `.container` | a single container |
| `.pod` | a pod (group of containers) |
| `.volume` | a named volume |
| `.network` | a network |
| `.kube` | a Kubernetes YAML deployment to run |
| `.build` | an image to build from a Containerfile |

Where they live:

- **Rootful (system services):** `/etc/containers/systemd/`
- **Rootless (per-user):** `~/.config/containers/systemd/`

The mechanism: `podman-system-generator` is a systemd *generator* that runs on every `systemctl daemon-reload`. It reads each `*.container` file and writes a transient `name.service` unit into systemd's runtime tree. You never write the `.service` yourself — you write the `.container`, reload, and systemd has a service named after the file.

### Why it beats `docker run` / compose for servers

- **Native systemd lifecycle.** Start/stop/enable/status/restart and journald logging come for free. No bolt-on supervisor, no `--restart=always` hack, no compose-as-init.
- **No daemon.** There is no `dockerd` to crash, hold a socket, or run root by default. systemd is already PID 1; Podman just fork/execs the container under it.
- **Rootless by default.** Run the whole stack as an unprivileged user (`~/.config/containers/systemd/`) — a compromised container is not a compromised host root.
- **Auto-restart + ordering.** Use the normal systemd toolbox: `Restart=`, `After=`, `Wants=`, `WantedBy=`, healthcheck-driven restarts. Boot ordering is solved by the same dependency graph as the rest of the OS.
- **Declarative + version-controllable.** The `.container` file is the source of truth — commit it like any config. No imperative `docker run` buried in a script's history. Re-applying the same file **converges** the running container to match it; it never creates a duplicate.

### Deploying zeroclaw as a quadlet

`/etc/containers/systemd/zeroclaw.container`:

```ini
[Unit]
Description=zeroclaw agent runtime
After=network-online.target
Wants=network-online.target

[Container]
# Pin the version you want in production. Substitute your registry org for <org>.
# :latest + AutoUpdate=registry (below) gives you a rolling-upgrade path instead.
Image=ghcr.io/<org>/zeroclaw:${ZEROCLAW_VERSION:-latest}
ContainerName=zeroclaw
PublishPort=42617:42617
Volume=zeroclaw-data.volume:/data
Environment=ZEROCLAW_PROVIDER=together
# Re-pull a newer image matching the tag on (re)start — part of the idempotent upgrade path:
Pull=newer
# Opt the container into `podman auto-update` (pairs with the podman-auto-update.timer):
AutoUpdate=registry

[Service]
Restart=always

[Install]
WantedBy=multi-user.target default.target
```

Deploy it (these steps are **idempotent** — safe to re-run any time):

```bash
# 1. Place the declarative source of truth.
sudo cp zeroclaw.container /etc/containers/systemd/

# 2. Regenerate units from the .container files. Re-running this just reconverges.
sudo systemctl daemon-reload          # generator turns .container into zeroclaw.service

# 3. Start (or restart-to-apply). Running this again is harmless — it converges to the file.
sudo systemctl restart zeroclaw

# Manage and observe it like any service:
systemctl status zeroclaw
journalctl -u zeroclaw -f              # logs via journald
```

Because the `.container` file is the single source of truth, the whole sequence is **idempotent**: editing the file and re-running `daemon-reload` + `restart` converges the running container to match — it never duplicates it. There is no separate `systemctl enable` step for generated units; the `[Install] WantedBy=` line is what makes zeroclaw come up automatically after the next reload/boot.

> **Rootless variant:** drop the file in `~/.config/containers/systemd/`, use `systemctl --user daemon-reload && systemctl --user restart zeroclaw`, and run `loginctl enable-linger $USER` so the user manager (and your container) survives logout.

### Version pinning vs `:latest` — the idempotent upgrade path

- **Pin a tag or digest in production** (`Image=ghcr.io/<org>/zeroclaw:1.2.3` or `...@sha256:...`). Upgrading is then a deliberate, reviewable change: bump the tag in the `.container` file, commit it, re-run the deploy steps above. Re-applying the same pinned file is a no-op; bumping it converges to the new version. Reproducible and roll-back-able.
- **Use `:latest` with `Pull=newer` + `AutoUpdate=registry`** if you want rolling upgrades instead. `Pull=newer` re-pulls a newer image for the tag whenever the unit (re)starts; `AutoUpdate=registry` opts the container into `podman auto-update`, which the `podman-auto-update.timer` runs on a schedule (enable it with `sudo systemctl enable --now podman-auto-update.timer`). New image on the tag → next timer tick pulls it and restarts the unit. This is convenient but trades reproducibility for currency — prefer pinned tags where deploys must be auditable.

Either way, the deploy mechanism is the same idempotent `.container` → `daemon-reload` → `restart` loop; only what `Image=` resolves to differs.

This same quadlet pattern works for any other long-running container alongside zeroclaw — one `.container` file per service.

---

## 3. OrbStack vs Colima (macOS)

On macOS there is no native Linux kernel, so *every* option (Docker Desktop, Podman, OrbStack, Colima) runs containers inside a lightweight Linux VM. For running zeroclaw on a Mac, OrbStack and Colima are the two mac-arm-native VMs worth comparing.

| | OrbStack | Colima |
|---|---|---|
| **Engine under the hood** | custom, highly tuned arm64 VM | Lima VM + containerd/Docker |
| **License** | commercial, freemium (free personal use) | Apache 2.0, fully open source |
| **Interface** | GUI app + CLI, "it just works" UX | **CLI-first** (`colima start/stop/...`), scriptable |
| **Docker compat** | ships a `docker` CLI + context | runs the Docker engine inside the VM; `docker` talks to it |
| **Idle footprint** | tends to be lower / lighter-touch | comparable; tunable via `--cpu/--memory/--disk` |
| **Best when** | you want minimal fuss and polish | you want everything OSS and config in code |

**Honest framing:** performance is **comparable** for typical dev workloads. OrbStack tends to have lower idle overhead and a more polished UX; Colima is fully open source and CLI-first. The real differentiators are licensing (commercial vs OSS) and UX preference, not raw speed. If idle RAM or build throughput matters to you, **benchmark both on your own machine** — don't take a headline number on faith.

Once either VM is up, you run zeroclaw with the `docker` CLI it provides — see §4. (Note that systemd quadlets are a Linux-host feature; on a Mac you're driving the engine inside the VM with `docker`/`podman` commands, not `systemctl`.)

---

## 4. How to deploy zeroclaw on each runtime

In every snippet below, substitute your registry org for `<org>` and your chosen tag for `${ZEROCLAW_VERSION}` (default `latest`).

### Podman on Linux (recommended for servers)

```bash
sudo apt install podman               # Debian/Ubuntu; use your distro's package
# Quick one-off run (rootless, no daemon):
podman run -d --name zeroclaw -p 42617:42617 \
  ghcr.io/<org>/zeroclaw:${ZEROCLAW_VERSION:-latest}
# For a real server, write a .container quadlet instead — see §2.
```

### Docker on Linux (fastest start)

```bash
# Install (Debian/Ubuntu)
curl -fsSL https://get.docker.com | sh
docker run -d --name zeroclaw --restart=always -p 42617:42617 \
  ghcr.io/<org>/zeroclaw:${ZEROCLAW_VERSION:-latest}
```

### OrbStack (macOS)

```bash
brew install orbstack                 # or download the .dmg
# OrbStack provides the docker CLI:
docker run -d --name zeroclaw -p 42617:42617 \
  ghcr.io/<org>/zeroclaw:${ZEROCLAW_VERSION:-latest}
```

### Colima (macOS)

```bash
brew install colima docker            # docker CLI talks to colima's VM
colima start --cpu 4 --memory 8
docker run -d --name zeroclaw -p 42617:42617 \
  ghcr.io/<org>/zeroclaw:${ZEROCLAW_VERSION:-latest}
```

### Migration notes

- **`docker` → `podman`** is mostly a **drop-in alias**: `alias docker=podman`. The CLI surface (`run`, `build`, `ps`, `images`, `exec`, `logs`) is compatible for the common cases. Most scripts — including the snippets above — work unchanged.
- **compose → quadlet** is the **server upgrade path.** `docker compose` (or `podman compose`) is fine for dev, but on a server you want zeroclaw as a real systemd unit. Translate the compose service into a `.container` quadlet (image, ports → `PublishPort=`, volumes → `Volume=`, env → `Environment=`, `depends_on` → `After=`/`Wants=`). You gain journald logging, boot ordering, idempotent re-apply, and `systemctl` management; you lose the single-file convenience (acceptable on a managed host). For a multi-container app you can also keep a `compose.yaml`/Kubernetes YAML and point a single `.kube` quadlet at it.

---

## 5. Summary

- **Deploying zeroclaw on a Linux server?** Podman + a `.container` quadlet. You get a real systemd service — rootless, daemonless, auto-restarting — with a declarative config you commit to git and re-apply idempotently.
- **On a Mac?** OrbStack (polished) or Colima (OSS, CLI-first). Benchmark both for your workload; they're comparable.
- **In CI?** Rootless Podman — no daemon, no privileged socket, reproducible.
- **Already on Docker?** Start there, then migrate servers to Podman quadlets when you need real service lifecycle.
- **Versioning:** pin a tag/digest for reproducible, auditable deploys; or use `:latest` + `Pull=newer` + `AutoUpdate=registry` for a managed rolling-upgrade path. Either way the deploy loop stays idempotent.
