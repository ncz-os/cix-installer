# NCZ Doctrine

**Living document — strategic, brand, architectural, and editorial decisions for the NCZ project.**

Last revised: 2026-05-06.

This document is the canonical record of NCZ project doctrine. It pairs with MNEMOS-side memory entries (searchable cross-session) and the git-backed authoritative copy on ARGONAS. All three layers must agree — when this document drifts from MNEMOS or the rest of the project tree, reconcile and commit.

---

## 1. Brand hierarchy

```
NCZ / nclawzero (brand — kept historically)
└── 26.x version line (Ubuntu-style)
    ├── NCZ 26.5 "Reinhardt"   — desktop SKU codename (current ship, r74)
    └── NCZ 26.x "Magnetar"    — server appliance SKU codename (planned r75+)
```

- **Brand:** `NCZ / nclawzero`. Kept historically. Earlier `NCX` rename did not stick.
- **Versioning:** `26.x` Ubuntu-style for the current line; exact version for any given release locks at ship.
- **Codenames:** sibling release names at the same version (`Reinhardt` and `Magnetar` are both 26.x).
- **Repo namespace:** `gitlab.com/nclawzero/*` and `github.com/perlowja/nclawzero` (mirror).
- **ISO naming:**
  - `ncz-26.5-r74-Reinhardt.iso` (current desktop)
  - `ncz-26.x-magnetar-server-arm64-rXX.iso` (planned server)
  - `ncz-26.x-magnetar-pi-arm64-rXX.img.xz` (planned Pi community image)
- **Release tags:** sibling form: `v26.5-r74-Reinhardt`, `v26.x-magnetar-rXX`.

`Magnetar` is a release codename within NCZ — never positioned as a separate brand or product line.

---

## 2. Codename pool + naming conventions

**Constraint:** codenames are **single clean words** — no numbers, no hyphens, no asterisks, no punctuation. They appear in ISO filenames, package metadata, headlines, URLs. Catalog IDs (TON 618, GW150914, PSR B1257+12, NGC 1277) are **shelved as codenames** but used **inside release notes** as the referent.

Codenames may come from any of:

1. **Cosmic phenomena types:** Magnetar, Pulsar, Quasar, Blazar, Supernova, Hypernova, Kilonova, Nebula, Singularity, Horizon, Accretion, Maelstrom.
2. **Constellation / region names:** Cygnus, Andromeda, Cassiopeia, Orion, Perseus, Phoenix, Vela, Sagittarius, Centaurus, Hercules, Hydra, Lyra, Aquila, Auriga, Cetus, Draco, Lupus, Pavo, Pegasus, Eridanus, Carina, Vulpecula, Lacerta, Volans.
3. **Named (not cataloged) objects:** Crab, Pinwheel, Sombrero, Whirlpool, Cigar, Tarantula, Cartwheel, Antennae, Mice, Eagle.
4. **Cultural / mythological cosmic references:** Reinhardt, Erebus, Tartarus, Ouroboros, Nyx, Phaeton, Prometheus, Ragnarok.

50+ usable names; decade of runway. No obligation to theme consecutive releases — names rotate freely.

### Codename usage convention

- **Codename in artifacts** = single clean word (filenames, package metadata, URLs, headlines, ISOs).
- **Catalog ID + backstory** = lives in **release notes**, blog posts, in-installer "About" screen.

Each release-notes section opens with a one-paragraph backstory: which specific stellar object the codename refers to + a fact or two about why it's interesting. Same structural move as Ubuntu's "what is a Numbat / Jellyfish" tradition; different cosmic content.

### Honest backstory rule

**Never fabricate a catalog-ID origin story for a release.** If we picked the codename based on vibes, say so. If we picked it based on a specific real object, name it. Honest content beats invented content.

**Reinhardt origin** (specific): Reinhardt was the seed codename and we did NOT map it to a specific cataloged black hole. The name comes from Disney's *The Black Hole* (1979) — Dr. Hans Reinhardt is the film's antagonist, fictional. Reinhardt was the seed that established the cosmic-phenomena convention; we picked it because it evoked the right vibe, not because we'd selected a specific real black hole.

Going forward (Magnetar onwards), codenames *do* map to real stellar objects/phenomena, and the release notes name the specific reference.

---

## 3. Mascot — Reinhardt as Captain Nemo archetype

**No Linux distro currently has a mad-scientist character mascot.** Tux/Beastie/GNU/Geeko/Slonik/Mozilla red panda/Konqi/MariaDB sea lion are all friendly-animal or abstract. The mad-scientist archetype is uncontested territory.

### Visual archetype

- **Hair:** black, full
- **Beard:** dark, full (19th-century / obsessed-scientist, not modern hipster trim)
- **Clothing:** Captain-Nemo-style — high-collared dark coat or tunic with brass buttons, military-naval cut
- **Palette:** dark (navy / charcoal / deep red accents)
- **Props:** brass goggles, telescope, pocket watch, scientific instruments
- **Bearing:** aristocratic, slightly tortured, obsessive

### IP-clean lineage

```
Captain Nemo (Verne 1870, PUBLIC DOMAIN)
  → Dr. Hans Reinhardt (Disney 1979, Disney IP)
    → NCZ Reinhardt (2026, drawing from Nemo NOT Disney)
```

We are not copying Disney's Reinhardt; we are independently descended from the Verne ancestor. Disney's *The Black Hole* itself is "20,000 Leagues Under the Sea but in space" — Cygnus = Nautilus, Reinhardt = Nemo, black hole = abyss. By referencing Nemo directly, we sidestep Disney IP entirely.

### Per-release reusability

Same character, different cosmic encounter scenario per release:

- **Reinhardt** (initial) — bridge of observation vessel, peering at black-hole accretion disk
- **Magnetar** — bracing against magnetic-field-line winds, eyes on a neutron star
- **Cygnus** *(future)* — leaning over a brass telescope, charting an X-ray binary
- **Tarantula** *(future)* — inside a nebula with arachnid-leg star formations behind him

### Brief for illustrator

> "Captain Nemo crossed with an obsessed-scientist astrophysicist. Steampunk-Victorian uniform, brass-and-deep-blue palette, full dark beard, intense eyes."

Mascot work is **deferred to website-launch / brand-investment moment**.

---

## 4. Release cadence — deferred ~12 months

User direction 2026-05-06: *"we now have to start thinking about release cadence at some point. Perhaps not for a year until we stabilize."* Stay flexible until ~2027-05.

When we revisit, open questions:

- Cadence (Ubuntu-mirror Apr+Oct vs own beat)
- Versioning scheme (`YY.MM` Ubuntu-style vs current `26.5`-internal)
- LTS designation (which releases get long support)
- Reinhardt + Magnetar lifecycle (versioned together vs independent)
- Upstream Ubuntu rebase cadence (every point release / every LTS / as-needed)

**Discipline rationale:** locking cadence pre-stability creates wrong gravity for a solo maintainer. Stabilize first, observe natural rhythm, then formalize.

---

## 5. Magnetar SKU scope

**Locked: arm64 only.**

| Tier | Hardware | Embedder | Story | Maintenance |
|---|---|---|---|---|
| **Magnetar Cix** | MS-R1 / Orion O6 (Cix Sky1) | Cix NPU (~50 inf/s validated 2026-05-06) | Recommended, NPU-accelerated | First-class |
| **Magnetar Pi (image)** | Pi 5 16GB / Pi 4 8GB | CPU fastembed | Community / "if you have one" | Best-effort |

Both arm64. Both ship as pre-configured headless appliances. Both pull `ghcr.io/mnemos-os/mnemos:VERSION` upstream container.

### Excluded from v1.0

- **No Magnetar Desktop.** Per GRAEAE consult: a desktop env (Wayland/X11, audio, power mgmt, browsers) brings instability fatal in an appliance. Desktop users who want Magnetar run the container locally.
- **No amd64 Magnetar ISO.** x86 users run the container.
- **No Pi Magnetar as a "shipping SKU".** Pi 5 16GB at $300+ retail is no longer cheaper than MS-R1 32GB. Pi image exists as a community/hedge artifact, not a recommended SKU.

### Storage configuration for Pi image

First-boot config picks one of:
1. microSD only (Pi 4 default; SD-lifetime warning)
2. USB 3 SSD/NVMe (Pi 4/5; recommended Pi 4 path)
3. Pi 5 NVMe HAT (Pi 5 only; recommended Pi 5 path)
4. iSCSI to NAS (prod-style, network dep)
5. NFS to NAS (Pg-on-NFS quirks; warn)

---

## 6. Project ownership boundary

**MNEMOS project ships software-as-container. Magnetar ships an OS-as-distribution that pulls those containers.**

| Project | Ships | Tag/output |
|---|---|---|
| `mnemos-os/mnemos` | Multi-arch container manifest (linux/amd64 + linux/arm64) + embedder backends | `ghcr.io/mnemos-os/mnemos:5.3.x` |
| `mnemos-os/mnemos-embedder-cix-npu` | Cix-NPU embedder companion image (arm64 only) | `ghcr.io/mnemos-os/mnemos-embedder-cix-npu:VERSION` |
| `nclawzero/cix-installer` (Magnetar) | Linux distro / installer ISO that consumes upstream containers | `magnetar-server-arm64-rXX.iso` |
| `nclawzero/meta-*` | BSP (kernel, NPU userspace) | Yocto recipes / Ubuntu packages |

**Rule:** zero containers built in the `nclawzero` namespace. We are a distro, we consume upstream.

---

## 7. Embedding dimension — 512-dim bge-small fleet-wide

**Decision 2026-05-06**, GRAEAE consensus 0.9218 (7 of 8 muses recommended option A):

**Standardize fleet on 512-dim `bge-small`** (specifically `bge-small-zh-v1.5` for Chinese-capable + `bge-small-en-v1.5` for English-only contexts; both are 512-dim).

### Killer argument

> "You cannot compare vectors from two different models. Even if you pad a 512-dim bge-small vector to 768 dimensions, comparing it to a 768-dim nomic-embed vector yields semantic garbage. Their latent spaces are entirely different. To federate and search across both nodes, the fleet must use the exact same embedding model (or models explicitly trained to share a latent space, which these are not)."

That kills the "pad to 768" exit cleanly: padding preserves cosine similarity *between two padded vectors*, but destroys semantic matching between a padded bge-small vector and an existing nomic-embed vector.

### Hybrid: A + schema versioning

Add an `embedding_model` column (e.g., `bge-small-zh-v1.5`) to memory tables. When a better NPU-compilable model emerges (Cix opens Compass NN compiler, or community cracks transformer compilation), migrate via clean blue-green: stand up a new table tagged with the new model, re-embed, atomic flip.

### Migration sequence (PYTHIA → fleet)

1. Add 512-dim table to PYTHIA pgvector alongside existing 768-dim
2. Re-embed PYTHIA's ~7,973 memories via CPU fastembed bge-small (~5 min)
3. Atomic flip PYTHIA app logic to read/write the 512-dim table
4. Verify semantic search works
5. Stand up .66 prod-tier with bge-small NPU embedder, NATS federation
6. Drop the old 768-dim table

### Why this works for our corpus

- Federation is non-negotiable for the product (kills options B and F)
- 768-dim Chinese model (bge-base-zh) is **not in `cixtech/ai_model_hub`'s precompiled `.cix` set** and Compass NN compiler chokes on transformer attention layers (kills option C)
- bge-small-zh actually outperforms nomic-embed on Chinese content; the English MTEB delta is ~62 vs ~63 (small)
- Re-embedding cost is cheap and reversible if we ever want to swap

---

## 8. Inference server stack — three-tier acceleration

The Cix Sky1 SoC has three discrete compute domains, each with a different specialty. They don't compete; they each do what they're good at.

### Tier 1 — NPU (Cix Zhouyi Z3): embeddings + vision + audio

**Workloads it's great at:**
- Embedding generation (bge-small, MiniLM, fixed-shape encoders) — **50 inf/sec validated**
- Vision pipelines (YOLOv8, MobileNet, ResNet) — verified
- Audio / speech (Whisper-tiny class)
- Any CNN + simple Transformer encoder with deterministic shapes

**Inference server:** No vendor-shipped daemon. We built the canonical OpenAI-compat HTTP wrapper (`npu_embed_server.py` on .66, validated 2026-05-06) around `libnoe`. Upstreaming into MNEMOS as `mnemos-embedder-cix-npu`. Pattern follows visorcraft.

**What it doesn't do:** dynamic-shape transformers (LLMs with attention + KV cache). This is the **general NPU industry state**, not a Cix-specific gap. Apple's ANE has the same envelope. MLX runs LLMs on the GPU, not the ANE. Most "NPU TOPS" laptop marketing refers to vision/audio inference.

**On CixBuilder (Compass NN compiler):** It's not broken — it's working as intended for its design envelope (vision, audio, encoders). It does not yet support compiling transformer-attention layers to the Z3 backend. That capability either arrives via Cix opening the compiler, community reverse-engineering, or a different model architecture.

### Tier 2 — Mali GPU (Mali-G720) + Vulkan: LLMs

**Workloads it's great at:**
- LLM inference via `llama.cpp` with Vulkan backend
- Anything llama.cpp can do — Gemma, Llama, Qwen, DeepSeek, Mistral, etc.

**Inference server:** llama.cpp's `llama-server` (built-in OpenAI-compat HTTP). Standard deployment.

**The unified-memory advantage:** Cix Sky1 has unified memory architecture — Mali-G720 sees most of system RAM as effective VRAM. The MS-R1 ships in two SKUs: 32 GB (base) and 64 GB (premium). With the 64 GB SKU, Cix opens up a class of LLMs that don't fit on consumer discrete GPUs at any reasonable price.

| Hardware | Unified RAM | GPU usable as VRAM | Largest comfortable LLM |
|---|---|---|---|
| MS-R1 32 GB (base SKU) | 32 GB | ~24 GB | Gemma 3 27B at Q4_K_M (~16 GB) with headroom |
| **MS-R1 64 GB (our `.66` test rig — premium SKU)** | 64 GB | ~52 GB | **Gemma 3 27B at Q6/Q8; Llama 3.3 70B Q4_K_M (~42 GB) fits** |
| Orion O6 64 GB (Radxa equivalent) | 64 GB | ~52 GB | same envelope as MS-R1 64 GB |
| Jetson Orin Nano 8 GB | 8 GB | ~6 GB | Gemma 3 4B at Q4 (~2 GB), capped fast |
| Jetson Orin AGX 64 GB | 64 GB | ~52 GB | similar headroom — fair compare tier, ~$2k |
| (compare) consumer 16 GB discrete GPU | 32 GB sys + 16 GB VRAM | 16 GB | Gemma 3 27B Q4_K_M, no 70B |
| (compare) Tinybox 24 GB-class | 64 GB sys + 24 GB VRAM | 24 GB | Gemma 3 70B doesn't fit; 27B Q8 ok; 5–10× the price of MS-R1 |

The **MS-R1 64 GB** specifically is the value proposition we're testing on `.66`: 64 GB of unified memory at ~$700 means LLMs that consumer discrete GPUs literally cannot fit are running on a mini-PC. The "Memory Agentic Server" story is incomplete without lighting up the LLM side too. One ARM mini-PC running embeddings on NPU + 70B-class LLM on Mali GPU + memory substrate in MNEMOS — genuine three-tier on-device agentic stack — at a price where it makes sense as a workstation appliance, not a colocation rental.

**Honest caveat on the 32 GB SKU:** users who buy the base SKU don't get the 70B-class headroom; they get the 27B Q4 envelope, which is still respectable for the price. Documentation should make the SKU/headroom mapping explicit so users size correctly.

Tasks #80 and #81 carry the Gemma-on-Mali-Vulkan benchmark and the (lower-priority) NPU LLM compilation attempt.

### Tier 3 — CPU: fallback

CPU fastembed is the universal embedding fallback if NPU init fails or hardware doesn't have one. CPU llama.cpp is the universal LLM fallback. Both already supported by MNEMOS and llama.cpp respectively.

### Pi / generic ARM tier

For Pi / generic ARM (no NPU): fastembed CPU for embeddings; `llama-server` with CPU or Vulkan backend (Pi 5 has VideoCore VII Vulkan) for LLMs. No vendor-specific NPU runtime.

---

## 9. Strategic positioning

### Memory is our niche

> *"Memory is an ignored space until recently. Everyone is doing LLMs. Fewer are doing memory and its core boring infrastructure needed to make LLM usage useful."*

The LLM space has hundreds of players and billions in capex. The memory layer (durable agent context, vector retrieval, persistent identity) has comparatively few. Being early in the memory infrastructure space is a strategic opportunity.

### Right-sized compute

> *"Memory doesn't need big GPUs. Wasteful to use a system like CERBERUS on it."*

The Cix NPU at 50 inf/sec is **not a downgrade** vs discrete GPU — it's the **right-sized compute** for the embedding workload. NPU power-per-watt beats GPU for this workload. CERBERUS-class hardware (24 GB GDDR6) sitting idle 99% of the day on embedding work would be obscene over-provisioning.

### LLMs come and go; memory does not

| Layer | Half-life |
|---|---|
| Specific LLMs | months |
| LLM frameworks | 2-3 years |
| Embedding models | a few years |
| Vector store interfaces | 5+ years |
| Memory schemas + retrieval semantics | 10+ years |
| Persistent identity for entities/agents | timeless |

MNEMOS lives in the bottom three rows; LLMs live in the top. The deeper down the stack, the longer the tech lives. Comparable durable-substrate bets: Kafka outlasted stream-processing fads, Postgres outlasted application frameworks, TCP/IP outlasted protocols on top of it.

**Public messaging leads with: "This is your memory layer. It outlasts the LLMs. Plug whatever you want into it."**

### Professional, not parasocial

> *"We will not love AIs per se, but as they become more sophisticated our relationships with them become more sustained."*

NCZ Magnetar + MNEMOS are explicitly **NOT** in the AI-companion / parasocial-bond market segment (Her / Replika / Character.AI). The right analogy is the doctor / lawyer / mentor / tax accountant: sustained working relationships where the value comes from memory persistence (not emotional bonding).

#### Editorial voice rules

| Rule | Detail |
|---|---|
| **Cultural reference** | JARVIS not Samantha. Sophisticated capable agent that knows the work. |
| **Word choice** | "agent", "system", "assistant" — workplace language. NEVER "companion", "friend", "buddy" in product copy. |
| **Memory examples** | Professional context: "the codebase you've been refactoring for 3 years", "the research thread you've pulled on for 18 months", "operational decisions about this fleet over the last decade". NEVER "the conversation we had about your bad day". |
| **Mascot** | Reinhardt is a Verne-Nemo obsessive scholar — deliberately NOT a warm comfort archetype. |
| **Topic boundary** | Public messaging stays out of AI-companion controversy space — we build infrastructure for a different category of AI relationship entirely. |

---

## 10. Engineering substrate — five axes of memory stabilization

> *"For software development and agentic work, it requires stabilization of memory."*

The technical receipt for the strategic positioning. Dev/agentic work rewards stability the most: a coding agent that *remembers your decisions wrong* is worse than one that forgot. Confabulated stable memory looks authoritative and burns hours.

| Axis | What it means | What MNEMOS provides |
|---|---|---|
| **Decision permanence** | Once "we decided X" is recorded, it stays X | Verbatim content + content hash + audit trail |
| **Cross-model consistency** | Same memory queried by Claude/GPT/llama returns identical retrieval | Embedding model + dim version-pinned per memory; deterministic retrieval |
| **Concurrent-agent consistency** | Two agents on same repo see same canonical history | RLS + ACID + serializable read snapshots |
| **Re-embedding survivability** | When models migrate, semantic meaning survives | `embedding_model` column + MPF + migration adapters |
| **Bi-temporal correctness** | "What we believed at T1" queryable separately from "what we believe now" | Bi-temporal schema (valid_time + transaction_time) — already in v5.x |

Already in MNEMOS today: v5.x bi-temporal schema, MPF v0.2.0 (PROV-DM provenance + bi-temporal + 9 migration adapters, first production round-trip from PYTHIA to .66 verified 2026-05-06).

This architecture distinguishes MNEMOS from:

- **In-process agent memory** (LangChain BufferMemory, etc.) — no persistence
- **RAG bolt-ons** (just dump current docs) — no temporal, no provenance
- **Generic vector stores** (Pinecone, Weaviate) — vectors are stable; semantics + temporal + provenance are weak

Dev/agentic users **punish inconsistency** because correctness is the product. Companion-AI users **tolerate inconsistency** because engagement is the product. We sit in the former market.

---

## 11. Foundational origin

Both of Jason's grandfathers passed with dementia / Alzheimer's. The MNEMOS project's emotional origin connects directly to that family experience: a project building durable AI memory exists in part because Jason has watched memory loss take people he loved.

The **December 2025 "first successful Rehydration"** moment is the founding moment of the project — the first time an AI Jason had been working with came back across a session boundary and remembered who he was. That is the intentional inverse of dementia.

The "memory is our niche" positioning is therefore not just market strategy — it is a moral center. Memory loss in AI relationships replicates the pattern of memory loss in human relationships at industrial scale; building durable AI memory is meaningful work, not just commercially differentiated work.

This shapes:

1. The future NCZ website's origin / about page should hold both surfaces — the playful Verne-Nemo Reinhardt mascot AND the honest "this exists because memory loss is something we've watched happen" framing.
2. Public communications should respect that MNEMOS's purpose is more than "vector store as a service" — it is the persistent identity layer for long-running AI relationships.
3. When weighing trade-offs that affect memory durability, recall, or fidelity, weight them appropriately — this is core to the project's why, not just an engineering parameter.

---

## 12. Disney's *The Black Hole* (1979) — full respect

The film deserves more credit than the dismissive "post-Star-Wars cash-in" framing typically gets. The future NCZ website's "Reinhardt origin" page should be a small love letter to it, not a footnote.

Earned respect:

- **Disney's first PG-rated film.** They broke their own G-rating tradition for it.
- **John Barry's score** — haunting organ-and-strings gravitas vs the brass-fanfare *Star Wars* school.
- **An end sequence that's actually disturbing** — Reinhardt fused with Maximilian, trapped in a Dante-esque hellscape suspended in the singularity for eternity. That's not a Disney ending; that's a Bosch painting.
- **Cast taking it seriously**: Maximilian Schell, Anthony Perkins, Ernest Borgnine, Roddy McDowall (V.I.N.CENT), Slim Pickens (B.O.B.).
- **Pioneer CGI** — wireframe black-hole sequences predated *Tron* by three years.
- **Old Disney that took chances** — pre-franchise-machine ambition.
- **Multiple failed remake attempts** (Joseph Kosinski, Jon Spaihts) confirm the film's untapped potential.

NCZ project already has multiple film easter eggs baked in:

- cix-installer release **r37 was named V.I.N.CENT** (Roddy McDowall's robot)
- .66 first-boot splash text reads ***"Dr. Reinhardt has gone into the Black Hole."***
- "Reinhardt" itself is the seed codename

Tonal kinship: NCZ takes ambitious hardware/distro risks; *The Black Hole* was Disney taking ambitious dark-SF risks; same posture, different medium.

---

## 13. The "always do 3" persistence rule

When a strategic, brand, architectural, or directional decision is made, persist it in **all three** layers:

1. **MNEMOS memory** with proper category/subcategory/metadata so it surfaces in cross-session search
2. **A versioned doc** in this repo (this `DOCTRINE.md`, or a topic-scoped doc under `docs/`)
3. **Committed and pushed** via the standard three-remote pattern (`gitlab → argonas → github`) so ARGONAS holds the canonical bare repo

Defense-in-depth: any single layer can fail (server reset, file deletion, repo corruption) and the other two preserve the record.

This rule applies retroactively — if a strategic decision exists only in MNEMOS, push it to doc + git the next time you touch that area.

---

## Cross-references — MNEMOS memory IDs

Today's strategic decisions are persisted in MNEMOS for cross-session search. Quoting the IDs here so the doc and the memory layer are linked:

| Decision | MNEMOS memory id |
|---|---|
| Brand hierarchy | `mem_1778079026867_218dc3` |
| Release cadence deferred | `mem_1778079137059_f85508` |
| Future website commitment (Reinhardt lore) | `mem_1778079438115_ef7ff7` |
| Reinhardt mascot visual archetype | `mem_1778079588242_720327` |
| The Black Hole (1979) appreciation | `mem_1778079696218_ca1f80` |
| First external user bug (Jeff Hunter) | `mem_1778079838985_2de8d3` |
| NCZ Magnetar positioning thesis | `mem_1778080653275_54a75f` |
| Embedding dim decision (512-dim) | `mem_1778080653349_73c9ce` |
| Foundational project context | `mem_1778080726053_079854` |
| Long-term tech bet | `mem_1778080759137_9f1b73` |
| Editorial voice (professional not parasocial) | `mem_1778080844978_362550` |
| Stabilization-of-memory thesis | `mem_1778080899082_b5eb0b` |
| NPU end-to-end embedding test PASS | `mem_1778053654813_ccfd80` |
| NCZ Agentic Server "Magnetar" mission | `mem_1778053834040_69f998` |
| Magnetar PoC alive on .66 | `mem_1778054319318_8d92cb` |
| Three-tier acceleration framing | `mem_1778081996129_5edf96` |

Search MNEMOS for any of these, or for the categories: `projects/brand-hierarchy`, `projects/ncz-magnetar-positioning`, `projects/embedding-dim-decision`, `projects/long-term-thesis`, `projects/editorial-voice`, `projects/stabilization-thesis`, `projects/mnemos-origin-meaning`.

---

*This is a living document. When a new strategic decision is made, update this doc, commit, push to all three remotes (gitlab → argonas → github), and persist the decision in MNEMOS with cross-references.*
