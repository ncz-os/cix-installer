# Email — Tom Cubie (Radxa) — Orion O6 loaner request

**Status:** DRAFT 2026-05-07. Hold for operator authorization. Not yet sent.
**Subject:** Loaner Orion O6 — NCZ Linux distribution + accelerated NPU embeddings on Sky1
**To:** Tom Cubie (Radxa) — `tom@radxa.com` (verify) or Discord `@tom`
**Reply-to:** jperlow@gmail.com

---

Hi Tom,

Short ask first: would Radxa loan me an Orion O6 for testing? Happy to ship it back, or buy at wholesale if that's simpler on your accounting side.

I'm Jason Perlow. I'm shipping **NCZ** — a public-OSS Apache-2.0 Linux distribution targeting Cix Sky1 / CP8180 silicon. The first public release went up at <https://gitlab.com/nclawzero/cix-installer/-/releases> earlier this week. Today I'm finishing the next release — and I think it's the kind of thing the Radxa side would care about.

## What's in the new ISO (NCZ 26.5 r78 "Reinhardt-Magnetar")

A **single ~615 MB netinstall ISO**. Debootstrap'd from `ports.ubuntu.com/ubuntu-ports` at install time, GitHub-distributable, no Cix-internal infrastructure dependency for the base bootstrap. At boot the operator picks one of three entries:

```
Install NCZ "Reinhardt"  — Desktop (XFCE, wired link required)
Install NCZ "Magnetar"   — Server (headless, agent appliance)
SAFE — rescue shell
```

Both install entries run the same d-i + post-install pipeline; the only difference is a kernel cmdline `ncz_variant=desktop|server` that propagates through to first-boot toggles (mask `getty@tty1` for headless, NoMachine remote-access on Magnetar, etc.).

Under the hood:

- **Kernel**: `linux-cix-sky1-next 7.0.3` only. The dual-kernel LTS+NEXT path stays for the offline-rootfs full-mode ISO; netinstall ships NEXT-only to keep the image small. Yocto-built; tracks Sky1-Linux upstream.
- **Userspace**: Ubuntu 25.10 questing arm64. Cix proprietary userspace (`cix-noe-umd 2.0.2`, `libnoe`) layered post-bootstrap from `archive.cixtech.com`.
- **Boot**: systemd-boot, NEXT default with boot-counting auto-rollback.
- **Hostname**: deterministic `ncz-<MAC8hex>` from the first wired NIC at first boot — ten of these on a homelab LAN don't collide.

## Accelerated NPU embeddings — the part Radxa cares about

The new release bakes **mnemos-embedkit** — Apache-2.0 OSS Python package at <https://github.com/mnemos-os/mnemos-embedkit> — and stages a Compass-NN-compiled `bge-small-zh-v1.5` model for the **Cix Zhouyi V3 NPU**. First boot, `embedkit.Engine.auto()` returns the `npu-cix` adapter; embeddings run on the NPU directly via `libnoe` + `/dev/aipu`. Same uniform Python API across silicon — same code runs on a CUDA box, an Apple-Silicon Mac, an Intel iGPU, a Pi 5 — but on Sky1 the NPU adapter wins.

The numbers for the always-on edge-memory workload (sentence embedding, ~256-token average, INT8 quantized, 8038-record corpus, all in-process — no HTTP RPC):

| Engine | rec/sec | p50 | TDP class |
|---|---|---|---|
| **Cix Sky1 NPU** (Zhouyi V3 INT8 .cix) | **54.86** | 14.6 ms | ~2 W silicon |
| Cix Sky1 12-core ARM CPU (Q8 GGUF) | 12.03 | 100 ms | ~30 W full SoC |
| Apple M1 Max Metal (Mac Studio) | 176 | 6.2 ms | ~30 W GPU portion |
| Workstation discrete GPU | 487 | 2.3 ms | ~115 W GPU |
| Raspberry Pi 5 16 GB CPU | 3.4 | 305 ms | ~5 W |

**Cix NPU at ~27 rec/s per watt is the per-watt leader on always-on edge-memory workloads** — about an order of magnitude better than a discrete GPU at the same workload. For the always-on 24/7 agent fleet memory use case, this is the only platform tested that fits "fanless 1L appliance, sub-$1/year electricity, sub-$1000 hardware" — and the Orion O6 lands in exactly that envelope.

Full cross-platform bench page (with hardware identification, methodology, model SHA, and live JSONL pointers) at <https://github.com/mnemos-os/mnemos-embedkit/blob/main/benches/results.md>.

## Why an O6 specifically

1. **Validate NCZ on O6** — same Sky1 silicon, different board, different boot path. Marcus Comstedt (zeldin) filed Sky1-Linux #29 today reporting PCIe issues on his O6 (same family as #20). I'm working with him on dmesg, but having an O6 in the test fleet myself would let me iterate against it directly rather than asking the community to bisect for me.
2. **NPU embedding parity on O6** — the bench numbers above are from the Minisforum MS-R1. We expect O6 to be the same Sky1 silicon and similar NPU throughput, but I haven't measured it. A measured O6 row in the bench page closes the loop for Radxa-specific operators who'd otherwise have to extrapolate.
3. **Sky1-Linux upstream** — fixes that fall out of O6 testing flow back to the kernel work directly. Patches against your shared engineering side.

## What I'd put back

- **"Tested on Orion O6"** badge + Radxa attribution in NCZ release notes.
- **Public bench numbers** for the O6 alongside the rest of the platform spectrum at the embedkit benches page.
- **Sky1-Linux upstream patches** for any O6-specific kernel / firmware / devicetree fixes.
- **Coverage at techbroiler.net** in the writeup that goes with the netinstall release ship.
- **NPU-adapter "tested-on-O6"** label in the embedkit kit docs — every operator looking at a Sky1 board for an agent appliance sees Radxa as a verified target.

Loaner, eval, purchase — whatever's easiest on your side. Happy to ship it back when validation is done.

Available via email or Discord (`perlowja`).

Thanks,

Jason Perlow
<jperlow@gmail.com>
<https://gitlab.com/nclawzero> · <https://github.com/perlowja>

---

## Notes for operator (for the actual send)

- Subject line is dual-purpose. If routed to engineering instead of Tom, the "accelerated NPU embeddings on Sky1" hook lands in the right context.
- The bench table is the differentiating story. Tom is a technical founder; concrete throughput-per-watt numbers will land harder than abstract claims.
- Per `feedback_no_competitor_comparisons.md` — no NVIDIA-product framing in the email. The discrete-GPU and Apple Metal numbers are listed as **peer rows in the bench table that show the kit runs across platforms**, not as competition. There's no "Cix beats NVIDIA" framing, just per-watt envelope context for the 24/7 agent appliance use case.
- Sky1-Linux #29 is a live touchpoint with Radxa-engineering-adjacent (zeldin); referencing it lands the request in the right context.
- The "wholesale purchase" offer is the safety hatch for Radxa's accounting — gives them a clean path if a loaner is awkward.
- Discord handle (`perlowja`) is correct; verify Tom's username before the actual send.
