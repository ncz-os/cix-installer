# r75 Rebake list — full canonical

What needs to land in NCZ r75 builds (cix-installer + Yocto + post-install hooks). Updated 2026-05-06 (full pass).

**Strategic frame:**
- **NCZ Reinhardt 26.5 r75** = arm64-Cix desktop variant (current).
- **NCZ Magnetar arm64-Cix** = headless server appliance variant; ships pre-configured agentic memory stack on Cix.
- **NCZ Magnetar Intel x86** = same product, Intel iGPU/AI-Boost-NPU embedder, runs on PYTHIA-class hardware. PYTHIA's next major update IS Magnetar.
- **NCZ Magnetar Pi** = community/edge tier image via pi-gen-nclawzero.
- **Magnetar container** = multi-arch OCI image (Linux amd64 + arm64), runs on Mac via Podman/Docker.

**Hard rules in effect for r75:**
- **Kernel 7.x mandatory on both Cix and Intel deploys.** No 6.x backwards path. Cix uses linux-cix-sky1 7.0.3-NEXT; Intel uses Ubuntu's 7.0.x stock generic. Both share the 7.x lineage.
- **Magnetar is multi-vendor.** Whichever box wins on the workload + price + form-factor is the recommended deploy for that segment. Cix doesn't have to win every fight.
- **Fair-comparison doctrine.** Any optimization applied to one HW target gets applied to others (cache, kernel patch, etc) before publishing benchmarks.
- **Rebake before in-place tuning.** Special Magic on .66 doesn't reproduce; bake it into the build. Iterate by rebake → reinstall → bench, not by hand-patching the running box.

---

## A) Kernel-side (Yocto rebake)

| # | Item | Why | Origin task | Blocking |
|---|---|---|---|---|
| K1 | **Bake kernel-headers** for 7.0.3-cix-sky1-next (and any LTS we still ship as fallback) | DKMS can't build NPU/GPU drivers without them | **#66 URGENT** | K2, future cix-gpu-kmd swap |
| K2 | **Apply n4hy v4 NPU patch** into aipu module source before bake | Eliminates 0x23 NOE_STATUS_TIMEOUT re-create-job workaround → ~2× NPU cold-pass throughput target 70-80 emb/sec | new | Closes "tooling-holding-back-hardware" gap |
| K3 | **Default boot = 7.0.3 NEXT** in systemd-boot. LTS available as fallback menu entry only (or dropped entirely). | ARM Linux velocity is in current kernels; 6.18 LTS frozen | #113 | All panthor/Mali/aipu modern fixes |
| K4 | **Pin Sky1-Linux Mesa 26.0 stack** (libdisplay-info3 + libllvm21 + mesa-vulkan-drivers + mesa-libgallium etc.) via apt priority pin | Mesa 25.2.8 panvk had OOM bug on llama.cpp Vulkan; 26.0 + 7.0.3 panthor is what made Mali work end-to-end | new | Cleaner GPU stack; future Mali workloads |
| K5 | **Verify dual-kernel rule (BOTH 6.18 LTS + 7.0.3 NEXT shipped)** stays per memory `feedback_dual_kernel_cixmini` — even though default flips to NEXT, LTS stays as a fallback boot-menu entry for emergency rollback | Solo-maintainer safety net during the kernel default flip | existing rule | none |

## B) Post-install hooks (cix-installer scripts)

| # | Item | Why | Task |
|---|---|---|---|
| P1 | **`usermod -aG render,video,audio,plugdev`** for first-boot user | r74 didn't add to render group → Vulkan failed silently with "Permission denied" on /dev/dri/renderD128 | #114 |
| P2 | **Hostname fallback to `ncz-<MAC4hex>`** if blank + early-abort on wireless-only env | Jeff Hunter first-external-user bug: empty hostname on wireless install crashed downstream | #109 |
| P3 | **Patch `cix-noe-umd` postinst** to gracefully skip libnoe pip install when Python ≥ 3.13 | Ubuntu 25.10 ships Python 3.13.7; libnoe wheel requires <3.13. C lib still works, just need `\|\| true` | #116 |
| P4 | **Bake GPU/NPU/LLM stack** — Vulkan dev (libvulkan-dev, glslang-tools, glslc, spirv-tools, spirv-headers), llama.cpp Vulkan binaries, NPU embedder Python (`npu_embed_v2.py` with cache + server), bge-small-zh.cix model, libnoe runtime | r75 image should ship "plug-in-and-it-works" — current PoC requires manual builds | #111 |
| P5 | **`ncz desktop on/off` toggle CLI** + Magnetar Server SKU defaults to `multi-user.target` + NoMachine pre-installed enabled | Headless server appliance baseline; Reinhardt Desktop SKU keeps graphical | #115 |
| P6 | **`ncz install mnemos`** wires MNEMOS server with NPU embedder backend at first boot (Cix-arm64 path) or OpenVINO embedder backend (Intel-x86 path) | The killer-app that justifies the SKU; PoC validated on .66 already | #98 |
| P7 | **`ncz models pull`** subcommand — pulls cixtech/ai_model_hub_25_Q3 LFS to /opt/ncz/models | Single canonical model location for MNEMOS + downstream apps | #99 |
| P8 | **explicit USB-removal prompt before reboot** | Avoids re-booting from the install USB | already completed in r56+ #76 — verify still in pipeline |
| P9 | **Cockpit container-management web UI** | Quick visual control plane for the agent containers | already completed #71 — verify still wired |

## C) Magnetar variants (the new SKU work)

| # | Item | Why | Task |
|---|---|---|---|
| M1 | **Magnetar Server build variant** (`BUILD_VARIANT=server` flag in cix-installer) | strips XFCE/GNOME/browser/Cockpit-as-default-active stages; ships headless. Same kernel + packages as Reinhardt, different default-target. | #102 / #108 |
| M2 | **Magnetar Pi image variant** via pi-gen-nclawzero | community/hedge tier; CPU fastembed only, no NPU. Pulls same upstream MNEMOS container as Cix. | #107 |
| M3 | **Magnetar Intel x86 deploy template** | PYTHIA's next major update. Ubuntu Server 26.04 LTS + MNEMOS container + OpenVINO 2026.1.0 embedder daemon + same agentic stack as Cix variant. | #118 |
| M4 | **Magnetar container multi-arch OCI manifest** (linux/amd64 + linux/arm64) | Mac users + cloud runs. Same software, just a container — no installer involved. Build on ULTRA arm64 + TYPHON x86, manifest-combine. | implicit in #102 |
| M5 | **Pluggable embedder selector** in MNEMOS | `MNEMOS_EMBEDDER=cix_npu\|openvino\|fastembed_cpu\|hailo` config knob. Lets Magnetar build pick the right backend per HW target. | #103 + new |

## D) Models / data

| # | Item | Why | Task |
|---|---|---|---|
| D1 | **Pull cixtech/ai_model_hub_25_Q3 LFS** to `/opt/ncz/models/` | bge-small-zh.cix + vision/audio models — single-source path | #99 |
| D2 | **Embedder runtime selector reads from /opt/ncz/models** | unified path across Cix-arm64, Intel-x86, Pi variants | new |

## E) ISO ergonomics

| # | Item | Why | Task |
|---|---|---|---|
| E1 | **Build netinstall ISO (~500 MB)** | smaller download for users who only need bootstrap + apt | #60 |
| E2 | **`BUILD_MODE=thin\|max` flag** | thin = current 5GB, max = include all GPU/NPU/LLM payloads + models | #61 |
| E3 | **tty3 progress feedback** during install | r55 install has no visible progress on tty1/tty2 | #62 |
| E4 | **Bake live r55+ MS-R1 fixes into pipeline** | accumulated patches need integration | #63 |

## F) Strategic / cross-cutting

| # | Item | Why | Task |
|---|---|---|---|
| F1 | **Subiquity / autoinstall migration** | when casper boots on Sky1, swap from cix-installer custom d-i to autoinstall | #97 |
| F2 | **Codex review gate** in build pipeline | PRIMARY DIRECTIVE #4: Codex at every release gate | existing rule |
| F3 | **Bilingual upstream engagement** for Cix software gaps | EN + ZH posts to cixtech/* repos + Zhihu/CSDN/Bilibili | #117 |
| F4 | **Surface to Intel team in parallel** with NVIDIA Jetson dialogue | NVIDIA owns 5% of Intel; both partner-ecosystem dialogues are constructive | new |
| F5 | **Upstream Cix NPU embedder PR to mnemos-os/mnemos** | the embedding-cache + ctypes wrapper goes upstream as `mnemos-embedder-cix-npu`, not a one-off in NCZ | #103 |
| F6 | **bigpi prod-parity test rig** (Pg17+pgvector+NATS+Redis on iSCSI to ARGONAS) | validates the prod stack on a CPU-only ARM platform without NPU as a confound | #104 |
| F7 | **bigpi ↔ PYTHIA NATS federation validation** | proves Magnetar federation works at the network layer | #105 |

## G) Open questions before bake

1. Do we ship Sky1-Linux Mesa 26 directly (apt pin priority) or fork into our own apt? — recommend pinning Sky1-Linux for now.
2. Does n4hy v4 patch land cleanly on the FyrbyAdditive aipu source we ship? — same upstream code; should be yes — verify in build.
3. Should kernel-headers be a separate apt package or baked into rootfs? — separate package is cleaner; less ISO bloat.
4. Magnetar Intel x86 kernel: stock Ubuntu generic, or our own cix-style-flipped 7.x? — stock is fine; PYTHIA already uses it.
5. Do we need a special ARM64 Mac container path (MLX-native) or is CPU fastembed in the Linux container good enough for the Mac developer-loop use case? — defer; CPU is fine for Mac dev.

## H) Order of attack

Recommended sequencing:

1. **K1** (kernel-headers Yocto rebake) — blocks K2, urgent.
2. **K2** (n4hy v4 patch in aipu source) — biggest perf win for NPU; needs K1.
3. **P1, P2, P3, P8/P9 verify** — small post-install fixes; trivial.
4. **K3, K4** (default 7.x + Mesa 26 pin).
5. **P4, P5, P6, P7** (bake GPU/NPU/LLM, headless toggle, install mnemos, models pull).
6. **M1** (Magnetar Server build variant) — fork the build path.
7. **M5** (pluggable embedder selector in MNEMOS) — unblocks M3 (Intel) + M4 (container).
8. **F5** (upstream NPU embedder PR) — gets the pattern out of NCZ-namespace.
9. **M3, M4** (Intel x86 deploy + multi-arch container).
10. **M2** (Pi image) — last, when Cix Magnetar is solid.
11. **F6, F7** (bigpi prod-parity + federation drill).
12. **F3, F4** (bilingual upstream + Intel team dialogue).
13. **E1, E2, E3, E4** (ISO ergonomics polish).

---

*Last revised 2026-05-06 by Claude Opus 4.7 in jperlow-mlt session 85a4aae3 with mnemos-claude cross-checks. When this drifts from MNEMOS or git, reconcile.*
