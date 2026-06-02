# Container Runtimes: Docker vs Podman (quadlets) vs OrbStack vs Colima

**Status:** Reference doc — 2026-06-02 by Jason Perlow.
**Audience:** Anyone provisioning containers on the fleet. The fleet runs `zeroclaw` (and the rest of the agent stack) under **Podman quadlets** on every Linux host; the Macs run **OrbStack** (mac-arm native). This doc explains why, what a quadlet actually is, and how the macOS options compare.

---

## 1. Quick comparison

| | Docker | Podman (+ quadlets) | OrbStack | Colima |
|---|---|---|---|---|
| **Platform** | Linux, mac/Win via VM | Linux native; mac/Win via VM | macOS only | macOS (+ Linux experimental) |
| **Rootless** | optional (rootless mode exists, not default) | yes — first-class, the default model | runs containers in a VM; host-side rootless | runs containers in a VM; host-side rootless |
| **Daemonless** | no — `dockerd` long-running daemon | yes — no central daemon; fork/exec per container | n/a (VM hosts the engine) | n/a (VM hosts the engine) |
| **systemd integration** | none native (needs `docker run --restart` or compose + extra) | **native** via quadlets → real systemd units | n/a (dev tool) | n/a (dev tool) |
| **mac-arm native** | via Docker Desktop VM | via `podman machine` VM | **yes** — purpose-built fast arm64 VM | **yes** — Lima-based arm64 VM |
| **Licensing** | Engine = Apache 2.0; **Docker Desktop = commercial** (paid for larger orgs) | Apache 2.0, fully OSS | **commercial / freemium** (free for personal, paid for business) | **Apache 2.0, fully OSS** |
| **Resource overhead** | daemon always resident | per-container, no idle daemon | low idle (tuned VM) | moderate (Lima VM); tunable |
| **CLI compatibility** | reference CLI | drop-in `docker`-compatible CLI | provides a `docker` CLI + own | provides a `docker`/`nerdctl` CLI |

Numbers like idle RAM vary by host, image set, and VM tuning — **benchmark for your own workload** rather than trusting a single figure.

---

## 2. Podman + quadlets (the fleet's actual server pattern)

### What a quadlet IS

A **quadlet** is a small declarative unit file that describes a container (or pod, volume, or network) using systemd-style syntax. You drop it in a systemd unit directory and Podman's generator turns it into a *real* systemd service at boot/reload. You manage the container with `systemctl` exactly like any other service.

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
- **Declarative + version-controllable.** The `.container` file is the source of truth, commit it like any config. No imperative `docker run` buried in a script's history.

### Minimal `.container` example

`/etc/containers/systemd/zeroclaw.container`:

```ini
[Unit]
Description=zeroclaw agent runtime
After=network-online.target
Wants=network-online.target

[Container]
Image=ghcr.io/nclawzero/zeroclaw:0.8.0-beta-1
ContainerName=zeroclaw
PublishPort=42617:42617
Volume=zeroclaw-data.volume:/data
Environment=ZEROCLAW_PROVIDER=together
AutoUpdate=registry

[Service]
Restart=always

[Install]
WantedBy=multi-user.target default.target
```

Enable and run it:

```bash
sudo cp zeroclaw.container /etc/containers/systemd/
sudo systemctl daemon-reload          # generator turns .container into zeroclaw.service
sudo systemctl start zeroclaw         # start now
systemctl status zeroclaw             # manage it like any service
journalctl -u zeroclaw -f             # logs via journald
```

`[Install] WantedBy=` is what makes it come up automatically after the next reload/boot — there is no separate `systemctl enable` step for generated units; the `WantedBy` line wires the dependency.

> Rootless variant: drop the file in `~/.config/containers/systemd/`, use `systemctl --user daemon-reload && systemctl --user start zeroclaw`, and run `loginctl enable-linger $USER` so the user manager survives logout.

This is exactly the pattern every Linux fleet host uses for `zeroclaw`, `openclaw`, and `hermes`.

---

## 3. OrbStack vs Colima (macOS)

On macOS there is no native Linux kernel, so *every* option (Docker Desktop, Podman, OrbStack, Colima) runs containers inside a lightweight Linux VM. OrbStack and Colima are the two mac-arm-native VMs the fleet cares about.

| | OrbStack | Colima |
|---|---|---|
| **Engine under the hood** | custom, highly tuned arm64 VM | Lima VM + containerd/Docker |
| **License** | commercial, freemium (free personal use) | Apache 2.0, fully open source |
| **Interface** | GUI app + CLI, "it just works" UX | **CLI-first** (`colima start/stop/...`), scriptable |
| **Docker compat** | ships a `docker` CLI + context | runs the Docker engine inside the VM; `docker` talks to it |
| **Idle footprint** | tends to be lower / lighter-touch | comparable; tunable via `--cpu/--memory/--disk` |
| **Best when** | you want minimal fuss and polish | you want everything OSS and config in code |

**Honest framing:** performance is **comparable** for typical dev workloads. OrbStack tends to have lower idle overhead and a more polished UX; Colima is fully open source and CLI-first. The real differentiators are licensing (commercial vs OSS) and UX preference, not raw speed. If idle RAM or build throughput matters to you, **benchmark both on your machine** — don't take a headline number on faith.

The fleet's Macs run **OrbStack** today; Colima is a fully supported OSS fallback for anyone who prefers it or can't use commercial software.

---

## 4. How to implement each

### Docker (Linux)

```bash
# Install (Debian/Ubuntu)
curl -fsSL https://get.docker.com | sh
# Run a container
docker run -d --name nginx -p 8080:80 nginx
```

### Podman (Linux — fleet standard)

```bash
sudo apt install podman              # Debian/Ubuntu
# Run a container (rootless, no daemon)
podman run -d --name nginx -p 8080:80 docker.io/library/nginx
# For a server: write a .container quadlet instead (see §2)
```

### OrbStack (macOS)

```bash
brew install orbstack               # or download the .dmg
# OrbStack provides the docker CLI
docker run -d --name nginx -p 8080:80 nginx
```

### Colima (macOS)

```bash
brew install colima docker          # docker CLI talks to colima's VM
colima start --cpu 4 --memory 8
docker run -d --name nginx -p 8080:80 nginx
```

### Migration notes

- **`docker` → `podman`** is mostly a **drop-in alias**: `alias docker=podman`. The CLI surface (`run`, `build`, `ps`, `images`, `exec`, `logs`) is compatible for the common cases. Most scripts work unchanged.
- **compose → quadlet** is the **server upgrade path.** `docker compose` (or `podman compose`) is fine for dev, but on a server you want each service as a real systemd unit. Translate each compose service into a `.container` quadlet (image, ports → `PublishPort=`, volumes → `Volume=`, env → `Environment=`, `depends_on` → `After=`/`Wants=`). You gain journald logging, boot ordering, and `systemctl` management; you lose the single-file convenience (acceptable on a managed host). For multi-container apps you can also keep a `compose.yaml`/Kubernetes YAML and point a single `.kube` quadlet at it.

---

## 5. Key differences / when to use which

| Scenario | Use | Why |
|---|---|---|
| **Linux servers / fleet hosts** | **Podman + quadlets** | native systemd lifecycle, rootless, daemonless, auto-restart, declarative config in git |
| **macOS development** | **OrbStack** (or **Colima**) | mac-arm-native VM; OrbStack for polish, Colima for fully-OSS / CLI-first |
| **CI pipelines** | **rootless Podman** | no daemon to provision, no privileged socket, runs as the CI user, reproducible |
| **Cross-platform team already on Docker** | **Docker** (then migrate) | lowest friction to start; move servers to Podman+quadlets when you need real service lifecycle |

**Rule of thumb for the fleet:** servers → Podman + quadlets; macOS dev → OrbStack or Colima; CI → rootless Podman.
