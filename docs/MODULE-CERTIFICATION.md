# NCZ Reinhardt cixmini — partner integration / certified-module pattern

**Status:** draft 2026-05-24
**Hive job:** `019e5822-b564-7ec1-92c7-3f84e22b3b7b`
**Pattern reference:** Amazon Alexa Connect Kit (ACK), NXP EdgeReady, Microsoft Pluton, Google Coral certified-module program

---

## TL;DR

NCZ Reinhardt on cixmini is a **drop-in AI edge module**. Partner contributes their domain application + chassis + branding. NCZ ships the whole AI runtime, OS, secure boot, OTA, agent stack, and semantic data layer pre-certified. Partner integration surface is one HTTP localhost endpoint plus a `ncz update` channel.

Comparable to:
- **Amazon ACK** — partner adds host MCU + business logic; module ships pre-certified WiFi + Alexa stack
- **NXP EdgeReady** — pre-validated SoM with vision / voice / motion stacks, partner reskins
- **Google Coral M.2 + dev board** — partner adds carrier board + app; Coral ships TPU + Edge TPU runtime

NCZ goes further: ships **semantic data awareness** (E0 gateway) and **multi-agent runtime** on top of NPU silicon.

---

## Module bill of materials

| Layer | Product | Notes |
|---|---|---|
| Silicon | CIX P1 SoC (Sky1) — 12c arm64, 30 TOPS Zhouyi V3 NPU, Radeon-class iGPU | cixmini ships in Minisforum AI Mini chassis (62 GB RAM, 2 TB NVMe, ~30-50 W idle). bigpi (Pi 5 16 GB + Hailo HAT) covers the sub-$400 tier. |
| OS | NCZ Reinhardt 26.5+ ISO | Yocto-built, Debian-derivative userspace, signed grub + verified boot, `cix-installer` produces the ISO + post-install hooks. Telnet baked in for lockout recovery (LAN-only fleet policy). |
| Kernel | Linux 6.18.x LTS (Sky1 BSP) or 7.0.x NEXT | meta-cix layer ships kernel + Zhouyi V3 driver (`/dev/aipu`). 8-patch armchina-npu series upstream-pending. |
| AI runtime | `cix-npu-onnxruntime` + `cix-ai-engine` + `cix-noe-umd` | apt-installed from internal repo (`192.168.207.22:8081`); production cycle: NPU compiles per-shape models offline via Compass MiniPkg; userspace loads via libnoe. |
| Tensor lib | `cixmini-tensor-runtime` | Non-model-bound python lib for NPU inference primitives. Ships per hive `019e581d-4680` once landed. Python 3.11 venv path (workaround A, `019e581f-804a`) or 3.14 ctypes bypass (workaround D) — see triage coordinator `019e581f-8073`. |
| Embed | `llama.cpp` Vulkan + `bge-m3` or `bge-small-zh-v1.5` on AIPU | Localhost `:8090` endpoint. v6.1 mnemos backend honors via `MNEMOS_EMBED_HTTP_URL`. |
| Rerank (optional) | `bge-reranker-v2-m3` localhost `:8091` | v6.2 retrieval-profile `deep` path. |
| E0 gateway | `mnemos-data-awareness` sidecar at `:5777/v1/ingest` | Ships per hive `019e5819-cc81`. POST events → semantic awareness + drift alerts + LLM-ready context. |
| Memory | MNEMOS SQLite edge replica at `:5002` | Federation-pulls from org PYTHIA primary. Local semantic search; survives WAN outage. |
| Agents | zeroclaw + openclaw + hermes via systemd-podman quadlets | `ncz agent install --all`. Each agent has its own quadlet + env-file under `/etc/nclawzero/`. |
| Mgmt CLI | `ncz` (binary in `nemoclaw-firstboot` deb) | `ncz agent {install,list,restart}`, `ncz update {check,apply}`, `ncz health`. |
| Secure boot | CIX P1 verified boot + UEFI signed | Operator-provisioned at provisioning time; partner does NOT need to manage keys. |
| OTA | `nemoclaw-firstboot` deb + ncz update channel | Internal apt repo at `192.168.207.22:8081`; staged rollout via channel pin. Partner can host their own channel mirror. |

---

## Partner integration model

### What partner contributes

| Layer | Partner work |
|---|---|
| Application | Their domain code (kiosk UI, kiosk hardware driver, signage controller, etc.) — runs as a podman container OR systemd service |
| Data ingest | POSTs domain events to `localhost:5777/v1/ingest` (E0 gateway) |
| Data consumption | GETs / SSE-subscribes to `localhost:5002/v1/memories/search` (semantic) and `localhost:5777/v1/awareness` (drift alerts) |
| Branding | Boot splash, GNOME background, default browser homepage |
| Chassis | Their enclosure, I/O ports, peripherals |
| Power | Their charger + battery (cixmini = 12-19 V DC, 30-50 W typical) |
| Connectivity | Their preferred WiFi / cellular / wired uplink |

### What NCZ provides

Everything else. Including:

- Yocto-built ISO + cix-installer for first-time provision
- OTA channel + nemoclaw-firstboot hook
- AI runtime + tensor lib + NPU drivers
- E0 semantic gateway
- Multi-agent stack (zeroclaw, openclaw, hermes)
- MNEMOS edge replica
- `ncz` CLI for ongoing management
- Verified-boot key infrastructure
- Internal apt repo + signing keys
- Docs (this doc + per-component docs)
- Reference designs (4 below)

### Integration boundary

```
+--------------------------------+--------------------------------+
|        PARTNER ZONE            |          NCZ ZONE              |
|                                |                                |
|  Partner app (any container/   |  E0 gateway :5777              |
|    systemd service)            |  MNEMOS :5002                  |
|                                |  llama-embed :8090             |
|       |                        |  llama-rerank :8091            |
|       |                        |  Agent runtimes (3-agent)      |
|       v                        |  NPU runtime + driver          |
|                                |  ncz CLI + OTA                 |
|  HTTP localhost ---------------+  Yocto kernel + secure boot    |
|     :5002 (memory)             |                                |
|     :5777 (events + awareness) |                                |
+--------------------------------+--------------------------------+
```

Partner code never touches the NPU driver, the agent runtimes, the OS, or the OTA channel directly. Update cadence: NCZ ships monthly minor + quarterly major; partner pins via `ncz update channel <stable|beta|nightly>`.

---

## Reference designs (4 candidates)

Each reference design ships as: pre-baked NCZ ISO + sample partner-zone container + 1-page integration guide.

### Ref-1: RiskyEats inspection device (PRIORITY)

**Target customer:** county health departments, state regulators, FoH chain QA teams.

**Stack:**
- Partner zone: web UI for inspector check-in, photo capture, severity rating
- NCZ zone: `ic-engine`-equivalent risk-eats engine (`/v1/risk-score`), MNEMOS replica of inspection history, semantic search ("similar findings from chains nearby"), E0 awareness ("inspector caught 3 similar pest-control failures this month — flag as habitual")
- Hardware: cixmini in industrial-grade chassis, daylight-readable 10" touch display, 12 V DC + 8-hour battery
- Connectivity: WiFi + LTE failover; offline-first via MNEMOS replica
- Updates: nightly inspection-rule deltas via ncz update channel

**Why first:** RiskyEats backend already deterministic + benchmarked (per riskyeats project). Engine maps cleanly to cixmini NPU + MNEMOS pattern. Partner cost: chassis + screen + battery (~$300 BOM addition).

### Ref-2: Portfolio reporting kiosk

**Target customer:** independent financial advisor offices, wealth management firms.

**Stack:**
- Partner zone: dashboard UI (already exists per InvestorClaw)
- NCZ zone: `ic-engine` + investorclaw dashboard module + MNEMOS replica of client research notes
- Hardware: cixmini in desktop chassis, 24" 4K display
- Compliance: SOC2 documentation path already exists for ic-engine

**Why interesting:** ic-engine container already multi-arch. Just needs cixmini-targeted bundle.

### Ref-3: Memory-augmented operator console (field tech)

**Target customer:** facility ops, field service, manufacturing operators.

**Stack:**
- Partner zone: ticketing UI, work-order dispatch
- NCZ zone: MNEMOS replica of work-order + asset history, semantic search ("how did we fix the boiler glitch in Q1?"), E0 awareness ("seeing similar fault pattern across 3 sites — escalate")
- Hardware: rugged tablet OR fixed-mount in control room
- Connectivity: WiFi + offline-buffered

**Why valuable:** purest "MNEMOS as service" pattern, no domain-specific engine needed.

### Ref-4: Custom-data-awareness module (etlantis-on-cixmini)

**Target customer:** mid-market enterprises with custom ETL pipelines who want drift detection without cloud dependency.

**Stack:**
- Partner zone: their ETL pipelines push events to E0
- NCZ zone: etlantis pipeline analyzer + MNEMOS replica of historical drift signatures + semantic search across past anomalies
- Hardware: cixmini in rack-mount sled OR desktop
- Updates: weekly model deltas via ncz update

**Why deferred:** etlantis itself is parked per fleet-roles doc. Re-prioritize when etlantis ships.

---

## Certification levels

Three tiers partners can claim against the NCZ module:

### NCZ-CERTIFIED-BASIC

- Uses unmodified NCZ Reinhardt ISO
- Partner-zone code runs in a podman container with no privileged ops
- All AI calls via `localhost:5002` + `localhost:5777` only
- No modifications to NPU driver, agent runtimes, OS kernel

Partner gets: "Built on NCZ Reinhardt" mark + automatic security updates + OTA channel.

### NCZ-CERTIFIED-EXTENDED

- Above + may install partner-zone apt packages (signed by partner key)
- May add systemd quadlets for partner workloads
- May use NPU directly via documented APIs (libnoe / onnxruntime)

Partner gets: above + can claim "NCZ NPU Inside" mark.

### NCZ-CERTIFIED-ENTERPRISE

- Above + custom OTA channel under NCZ shared signing infrastructure
- White-label cix-installer ISO with partner branding (still NCZ-signed)
- Support contract with NCZ for kernel + driver updates

Partner gets: above + enterprise SLA + custom-channel branding.

---

## Compliance + secure-boot story

**Verified boot chain:**
1. CIX P1 ROM verifies UEFI firmware signature
2. UEFI verifies signed grub
3. Grub verifies signed kernel + initramfs
4. Initramfs verifies / partition root-hash (dm-verity, optional in r78)

**Signing keys:**
- NCZ holds root signing key (cold-stored)
- Per-channel intermediate keys (rotated quarterly)
- Partner-zone code does NOT need NCZ signature; partner can sign their containers with their own keys

**OTA security:**
- nemoclaw-firstboot deb installs + verifies signature at first boot
- ncz update channel pulls signed apt repo index
- Channel pin (`stable` / `beta` / `nightly`) enforced via apt preferences

**Audit trail:**
- All MNEMOS writes go to per-instance audit log
- E0 ingest writes timestamped + idempotency-keyed (v6.2 audit chain when shipped)
- ncz CLI commands log to journald

---

## Open work

Hive jobs feeding this pattern:

| Job | Status | Need |
|---|---|---|
| `019e581d-4680` cixmini-tensor-runtime library | claimed goose@mini | tensor lib must land for `cix-ai-engine` to be useful |
| `019e5819-cc81` E0 semantic ingest gateway | claimed goose@mini | `:5777` endpoint is the partner-zone integration surface |
| `019e581f-8073` py3.14 workaround triage coordinator | queued (this op) | unblock noe-engine Python compat |
| `019e5817-5c90` import-linter routes-db violation | claimed goose@mini | mnemos plumbing for clean E0 sidecar deploy |
| `019e5826-1886` fleet-wide anomaly detection framework | claimed goose@mini | feeds E0 drift-alert path |

Doc-side follow-ups:
- 1-page partner integration guide per reference design (4 docs to write once Ref-1 ships)
- White-label branding playbook for cix-installer ISO
- Compliance addendum: HIPAA / SOC2 / FedRAMP applicability per reference design

---

## Cross-references

- `DOCTRINE.md` (this repo) — fleet posture + naming conventions
- `MAGNETAR-CONTAINER-MULTIARCH.md` — multi-arch container shipping
- `EMBEDKIT-DESIGN.md` — embed-kit subcomponent
- `mnemos-prod-working/docs/medusa-edge-replica-deployment.md` — edge replica pattern that informs the cixmini deploy
- `mnemos-prod-working/docs/v6.1-roadmap.md` + `v6.2-nexus-pattern-adoption.md` — MNEMOS roadmap items the module surfaces
- Hive job `019e5822-b564-7ec1-92c7-3f84e22b3b7b` — this doc satisfies the design-doc deliverable
