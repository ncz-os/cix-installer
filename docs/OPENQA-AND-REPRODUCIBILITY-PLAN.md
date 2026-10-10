# openQA-based installer/image testing **and** the reproducible + deterministic NCZ-OS build/test program

**Status:** research + design + prototype (P0) — decision document for the operator.
**Author:** Jason Perlow `<jperlow@gmail.com>`
**Date:** 2026-10-10
**Branch:** `fix/r203-openqa-scope-20261010` (base `fix/r203-integration-20261010` @ `73f3dcbf`, ARGONAS, at clone time)
**Scope:** Part A — scope (and prototype) openQA for the NCZ installer flow. Part B — gap analysis + roadmap that makes the **build/test system reproducible and deterministic** (the operator's actual requirement, 2026-10-10).

> Everything below distinguishes **[VERIFIED]** (I ran it or read it directly), **[RESEARCHED]** (upstream doc/source read on 2026-10-10 with a URL), and **[NOT VERIFIED]** (honest gap).

---

## Executive summary (1 page)

**What already exists (good news).** The image build is far more reproducible than a typical distro build. `build/build-image.sh` is a fixed-pipeline entrypoint (preflight → refresh-substrate → stage-inputs → refresh-sources → offline-mirror → layers → image → kvm-gate → provenance-gate → receipt → archive) with a **written determinism contract** in `docs/IMAGE-BUILD-PROCESS.md` §5: same git SHA + same committed pins (`manifests/base.pin`, `manifests/determinism.pin`) ⇒ bit-identical image. Wrapper byte-stability (tar/squashfs/ext4/vfat) is proven on all three build hosts, a compare tool (`build/compare-images.sh`) exists with normalisation rules, and the installer gate (`build/kvm-install-gate-gpt.sh`) already installs + boots the image under KVM and runs an installer-UI check. The r203 provenance gate enforces a three-origin rule and a one-kernel rule; a per-package `sid` exceptions ledger shrinks over time. **[VERIFIED]**

**The two real gaps.**

1. **Installer UI verification is weak.** The amd64 UI check is **`PASS-LIMITED`**: it samples the framebuffer for "many distinct frames" but explicitly does **not** verify dialog titles, their order, or branding (`build/kvm-installer-ui-check.sh`: "dialog titles, dialog ORDER and branding were NOT verified"). arm64 uses a custom `pyte` terminal-emulator check of the serial console. There is no screenshot/reference-image history, no per-screen pass/fail, no result UI, and no way to see *which* screen regressed. **[VERIFIED]**

2. **The build is not hermetic.** The payload build performs **unpinned network fetches**: the `vetro` Go host tool is `go build`-ed in the build container and downloads Go modules (`go: downloading github.com/mirkobrombin/go-cli-builder/v2 v2.0.5`, `.../go-foundation v0.2.0`) — observed in the live r203 amd64 log (`rebuild/opencode.log:6233-6234`, `rebuild/opencode2.log:1046-1049`). The payload container also runs `apt-get update && apt-get install` against a **rolling Debian mirror**, clones upstream git repos at build time, and meson resolves `wrap-git` subprojects (`labwc/subprojects/scenefx.wrap`) from the network. `docs/IMAGE-BUILD-PROCESS.md` §5 claims "no unpinned network fetch inside the build"; the observed log contradicts that claim for Go modules (and the others are not enforced). **[VERIFIED]**

**Recommendation (both parts).**

- **Part A — openQA: ADOPT-LATER, scoped.** openQA is the right tool (it is what Debian/Fedora/openSUSE use), it runs fully containerised, and it needs only `--device /dev/kvm`. I **stood it up on PROTEUS and ran real UEFI jobs against our own netinst substrate** (boot + needle match + serial assertion + result in UI/API) in well under the time-box. But the honest conclusion is: **openQA buys us little until the build is hermetic and the image is reproducible**, because an installer test on a nondeterministic image produces nondeterministic needles. So P1 openQA (amd64 installer gate) should follow, not precede, the first Part-B quick wins. **Do not replace** the existing KVM gate or the pyte arm64 check yet; **augment** them.
- **Part B — reproducibility: ADOPT NOW.** This is the higher-value work and mostly quick wins: (1) make the payload build hermetic (Go vendoring, pinned snapshot apt, prefetched meson wraps, git from the mirror cache only, `--offline` fails closed); (2) pin the build **environment** by container digest; (3) enforce `--offline` in CI/nightly; (4) record a per-image **attestation**. The long poles are a second **arm64** build host (none exists; TYDEUS is not an image host) and a full signed-attestation chain.

**Prototype (P0) — verified.** Single-instance openQA container (`registry.opensuse.org/devel/openqa/containers/openqa-single-instance:latest`, digest `sha256:af4bca0a…`) on PROTEUS `.68`; `ncz` test distribution with two needles (`ncz-boot-menu`, `ncz-di-first`); a **UEFI** Debian-testing netinst (our substrate family) job **PASSED** with both needles at similarity `1.00` and a serial assertion (`wait_serial` matched `BdsDxe: loading Boot0002` from `serial0.txt`). Web UI reachable on the LAN, REST API returns the result. Everything created was removed (see Cleanup receipt). **[VERIFIED]**

**The one-sentence ask:** fund Part B (hermetic + attested builds) as the priority, and schedule openQA as the P1 gate that consumes it.

---

## Decision list for the operator

| # | Decision | Recommendation |
|---|---|---|
| D1 | Adopt openQA for installer testing? | **Adopt-later (P1)**, after Part-B quick wins B1–B4. Not instead of the KVM gate. |
| D2 | Replace the pyte arm64 check / amd64 `PASS-LIMITED` check? | **No.** Keep both; openQA **augments** them (reference-image match + history). Retire pyte only after arm64 openQA jobs are green for a full release cycle. |
| D3 | Where does openQA run? | **HYDRA `.78`** (worker) + a **persistent web UI on ARGOS `.22`** (idle) for P1; PROTEUS `.68` only for prototypes. 1 worker slot to start. |
| D4 | Is openQA in the build-critical path? | **Only as an additional gate** (`openqa-gate`, after `provenance-gate`). A red openQA job blocks publish; it never blocks the build from producing an image for inspection. |
| D5 | Build hermeticity: enforce now? | **Yes.** Make `--offline` fail closed and require it for shipped/nightly builds. |
| D6 | Second arm64 build/verify host? | **Needed for real independent verification.** ULTRA is the only arm64 build host today; recommend adding one (Ampere-class) or accept "same-host only" for arm64. |
| D7 | Signing keys for attestations? | **Propose only.** Use an **operator-held** minisign/GPG key (or a hardware token); agents must never generate or hold release keys. |
| D8 | Hardware (O6N/MEDUSA/CHIMERA/PEGASUS) under openQA? | **Out of scope for P1/P2.** Screenshot automation of real hardware is a later, opt-in project (D8-a: HDMI capture + smart plug + serial relay per host). |
| D9 | Nightly/weekly split? | Weekly full image ⇒ full openQA run; nightly canary ⇒ payload-level asserts only (no full install), per the `nightly` design. |
| D10 | Keep the P0 prototype artifacts in the repo? | **No** — they live as this doc's appendix + ARGONAS evidence; enabling them is a P1 change (a `prototype/openqa/` seed). |

---

# PART A — openQA

## A.1 Upstream state (research, 2026-10-10)

### A.1.1 What openQA is, and its parts

openQA is a testing framework for GUI and boot/kernel/output. It is **two components**: the **web UI + scheduler** (`os-autoinst/openQA`, Perl/Mojolicious + PostgreSQL) and the **test engine** (`os-autoinst/os-autoinst`, Perl, drives QEMU and other backends, does needle matching). A **test distribution** (a git repo: `main.pm`, `tests/*.pm`, `needles/*.png|*.json`, `scenario-definitions.yaml`) defines what to test. **[RESEARCHED: https://github.com/os-autoinst/openQA (README; fetched 2026-10-10); https://github.com/os-autoinst/os-autoinst]**

**License:** GPL-2.0-or-later for openQA and os-autoinst (the `assets/3rdparty` directory excepted). The example distro is `GPL-2.0-or-later` per file header. **[VERIFIED: openQA README License section; os-autoinst-distri-example file headers]**

**Development model:** "every commit in the git master branch is considered stable"; old git tags are described as misleading. This is a **continuous-release project with disruptive changes between versions**, so the web UI and worker must be the **same version** ("You need to be sure that the webui and the worker that you are using have the same version number or, at least, that they are compatible"). **[VERIFIED: openQA README Releases; docs/Installing.md "Custom installation"]**

### A.1.2 Deployment — containerised single instance (what I actually used)

`docs/Installing.md` documents three container variants:
- **Single-instance** (what the prototype used): `registry.opensuse.org/devel/openqa/containers/openqa-single-instance`, run with `--device /dev/kvm -p 1080:80 -p 1443:443`. It bootstraps openSUSE Tumbleweed, PostgreSQL, the web UI, a local worker, and QEMU, in one container. **[VERIFIED: ran it; fetched each package via zypper on first start]**
- **Split web UI + worker**: `registry.opensuse.org/devel/openqa/containers16.0/openqa_webui:latest` and `.../openqa_worker:latest`, configured with `/data/conf/openqa.ini` / `workers.ini` / `client.conf` bind-mounts. **[RESEARCHED: Installing.md]**
- **Kubernetes/Helm** charts in `container/helm`. **[RESEARCHED: Installing.md]**

**Auth methods:** OpenID (default), OAuth2, `Fake` (dev), and **`None`** — "bypasses any authentication entirely and automatically treats every visitor as an 'admin' … Do not use for any exposed instances!" The single-instance container ships `[auth] method = None` + `[openid] httpsonly = 0` (files `01-enable-none-auth.ini`, `01-enable-http-auth.ini`). **[VERIFIED: read `/etc/openqa/openqa.ini.d/*` inside the container; RESEARCHED: Installing.md auth section]**

**System requirements per worker (default qemu backend):** ~1 core with 2 hyperthreads (or 2 cores), **8 GB RAM**, **40 GB disk** (SSD/NVMe preferred). PostgreSQL ≥ 14. **[RESEARCHED: Installing.md "System requirements"]**

**Git integration:** `CASEDIR`/`NEEDLES_DIR` are auto-cloned per job; optional needle auto-commit, auto-update, and `checkout_needles_sha`. Enable via `[scm git]` in `openqa.ini`. **[RESEARCHED: Installing.md "Setting up git support"]**

**Remote workers:** require shared `/var/lib/openqa/share` (NFS example given) and synced clocks. Asset/needle caching (`CACHEDIRECTORY`, `TESTPOOLSERVER`) exists for remote workers. **[RESEARCHED: Installing.md]**

**REST API / CLI:** `openqa-cli` (in the web UI container) and `/api/v1/...` (e.g. `/api/v1/jobs/<id>` → `{"job":{"state","result",…}}`). `openqa-cli schedule --monitor async=1 …`. **[VERIFIED: used it]**

### A.1.3 Backends and how an installer is actually driven

- **qemu** (default): boot an ISO/disk, VNC console, screenshots → needles; serial captured to a logfile that `wait_serial` reads; UEFI via `UEFI=1` (OVMF on x86_64; on aarch64 the equivalent AArch64 UEFI firmware). Backend variables are catalogued in `doc/backend_vars.md`. **[RESEARCHED: os-autoinst `doc/backends.md`, `doc/backend_vars.md`, `backend/qemu.pm`]**
- **Needles**: a PNG + JSON with `area`s (`xpos/ypos/width/height/type=match`, optional `similarity`) and `tags`. `assert_screen 'tag'` waits for a match; `wait_serial qr/.../` asserts on the serial stream. This is the same mechanism Debian/Fedora use to drive d-i/Anaconda interactively **and** to verify branding/order. **[VERIFIED: wrote needles, matched at 1.00]**
- **generalhw** (real hardware): supports a **serial UART**, **SSH/xterm console**, **HDMI grabber + keyboard-emulation device**, and can run **scripts to power-cycle and to flash an SD card** using special hardware. Detailed recipe lives in the openSUSE distro: `os-autoinst-distri-opensuse/data/generalhw_scripts/raspberry_pi_hardware_testing_setup.md`. **[RESEARCHED: `doc/backends.md` generalhw section]**
- **svirt**: SSH to another machine, boot a libvirt VM (QEMU/Xen/Hyper-V/VMware). **ipmi**: power control via IPMI. **vagrant**: **limitations — no needle matching, no serial listening** (so it is not usable for installer UI tests). **s390x**: zVM/zKVM. **[RESEARCHED: `doc/backends.md`]**

### A.1.4 Who else does this, and how (precedents)

- **openSUSE** originates openQA; `openqa.opensuse.org`. **[VERIFIED: HTTP 200]**
- **Debian** runs **openqa.debian.net** ("Welcome to Debian's openQA instance"): job groups include **Debian netinst (amd64)**, **Debian netinst (aarch64)**, **Debian Live** for sid/forky/trixie/bookworm/bullseye, **Salsa CI**, Debian Edu, SolydXK, Kali, Windows. Version string `5.1782486535.1bf71ec48-8~srv+1~fto13+1`, GPL-2.0. The tests repo is **`https://salsa.debian.org/qa/openqa/openqa-tests-debian`**. **[VERIFIED: fetched openqa.debian.net 2026-10-10; NOT VERIFIED: the Salsa repo contents — Salsa returned an automated-fetch challenge, so I could not read the test code directly]**
- **Fedora** runs **openqa.fedoraproject.org** (HTTP 200) and the tests live in **`os-autoinst/os-autoinst-distri-fedora`**. Fedora's nightly compose testing is the model the operator cited. **[VERIFIED: HTTP 200; NOT VERIFIED: I did not read the Fedora distro source or Fedora's `check-compose` internals — I could not confirm the exact `check-compose` implementation, which lives in Fedora release-engineering tooling]**
- **NixOS** gates channels on **Hydra** tests (not openQA; a different mechanism — build-derivation tests, `nixos/tests`). **[RESEARCHED: general knowledge; not re-verified this session]**

### A.1.5 Alternatives considered

| Option | Verdict |
|---|---|
| **openQA** | Best fit: reference-image matching, result history/UI, video, serial, containerised, proven by Debian/Fedora/openSUSE. Heavier (PostgreSQL + web UI). |
| **Plain os-autoinst** (no web UI) | Lighter: run `isotovideo` directly with a `vars.json` and a distro dir. **Loses** result history, UI, needle editor, scheduling, the REST gate. Good as a fallback if the web UI is unwanted. **[RESEARCHED: os-autoinst README/docs]** |
| **Debian Salsa CI with qemu+expect** | Script-level; brittle for GUI; no reference images/history. Essentially what our KVM gate already does. |
| **Autotest/Avocado** | General test framework, not image/OS-install oriented; no needle matching. **[RESEARCHED: avocado-framework.github.io]** |
| **Our current `kvm-install-gate-gpt.sh` + `pyte` + serial** | Keep. Already asserts install completion, first boot, failed units, one-kernel, and (arm64) dialog sequence. Weakness: amd64 UI is framebuffer-sampling only; no per-screen history. |
| **Fedora `check-compose`** | Compose-level sanity, not installer UI. Complementary, not a substitute. **[NOT VERIFIED internals]** |

### A.1.6 What I could **not** verify (honesty)

- Salsa `openqa-tests-debian` source (fetch blocked).
- Fedora distro / `check-compose` internals.
- aarch64 KVM guest performance on Apple-silicon Asahi (see A.2.3) — not run.
- A full end-to-end install to completion + first-boot under openQA (time-box; see A.4).
- openQA's exact maintenance cadence in production (upgrade pain) — inferred from the "disruptive changes between versions" warning, not measured.

---

## A.2 Mapping NCZ needs → openQA, and the `openqa-gate` design

### A.2.1 The NCZ installer flow we must assert

From `installaudit/REPORT.md`, `build/kvm-install-gate-gpt.sh`, `build/kvm-installer-ui-check.sh`, and `docs/IMAGE-BUILD-PROCESS.md`:

- **amd64:** d-i raw **GPT** image; **rEFInd**; dialogs are drawn on the framebuffer console (read-back is blank while partman runs → currently answered on a timer and judged by framebuffer sampling).
- **arm64:** **8 ordered branded dialogs** — `NCZ-OS 26.10 Cygnus - select your REGION → choose a USERNAME → choose a PASSWORD → type the same PASSWORD → optional components → … → Finishing the installation` — driven and asserted via the **serial** console (pyte).
- **Post-install feedback lines** (new, `installaudit`): milestone `INFO` lines per hook, plus truthful GPU lines `Detected GPU: …` / `GPU driver: …`. Emitted to the d-i VT and the serial log.
- **First boot:** greeter/desktop starts, **no unexpected failed units**, wallpaper smoke (fetch `--if-stale` rc 0/75).
- **Offline mirror install** and the **one-kernel** rule.

### A.2.2 openQA mapping

| NCZ need | openQA mechanism |
|---|---|
| Reference-match every dialog (branding, order) | **Needles** per dialog; `assert_screen [ordered]`; store needles in git; the needle set hash goes in the receipt. This directly fixes the amd64 `PASS-LIMITED` gap. |
| Branded header text | Needle the title bar / `assert_screen` on the header region; on arm64 keep the serial `pyte` assertions as a second channel. |
| Arm64 8-dialog order | A serial text module (keep the existing `pyte` logic) **plus** needles for the visual dialogs; `--require-prompt-sequence` equivalent via multiple `assert_screen`s. |
| Post-install feedback lines incl. GPU | `wait_serial qr/Detected GPU:.*GPU driver:/` — a serial assertion; no screenshot needed. |
| First boot: greeter/desktop, failed units, wallpaper | P3 module: after install, boot the installed disk, `assert_screen 'desktop'`, `systemctl --failed` via the serial/SSH console, wallpaper smoke. |
| Offline install | Boot with no network (qemu `-netdev user` but no reachable mirror) so the installer must use `/cdrom`; assert no online fetch. |
| One-kernel | Keep the existing `provenance-gate`; openQA is not the place for it. |
| Determinism of the test itself | Fixed MAC (`52:54:00:12:34:56`), fixed resolution (`VGA edid 1024×768`), fixed qemu (pinned), pinned OVMF/AAVMF; **no `sleep` for synchronization** — use `assert_screen`/`wait_serial` with timeouts; seed any input. |

### A.2.3 VMs and KVM on our build hosts

- **ACHILLES `.11`** (x86_64, Ubuntu): `/dev/kvm` **gid 990, root-run gate** — openQA's worker container would need the same arrangement (`--device /dev/kvm`, run as a user in the `kvm` group, or rootful).
- **ULTRA `.88`** (Fedora Asahi, aarch64): **`/dev/kvm` exists and is usable**, but whether it can virtualise **aarch64 guests** depends on the Apple-silicon/Avahi KVM support for that guest type. If not, fall back to **TCG**, which is roughly **10–40× slower** (the existing gate already documents TCG being called out). **I did not verify aarch64-guest KVM on ULTRA** (builds in flight) — this must be measured before P2 commitments.
- **GPU-less guests**: software rendering is allowed in the VM; **real-GPU checks stay on the four primary hardware hosts** (O6N/MEDUSA/CHIMERA/PEGASUS). openQA VMs are GPU-less by construction.

### A.2.4 Test determinism (anti-flake)

- Pin the **QEMU** version with the worker container digest; pin **OVMF/AAVMF** files.
- Fixed resolution + fixed MAC + fixed disk/ISO checksums (`CHECKSUM_ISO`).
- **No wall-clock races**: `assert_screen(tag, timeout)` and `wait_serial(regex, timeout)` only; never `sleep` for correctness (the prototype's `wait_still_screen` was capture-only).
- **Flake handling**: openQA has no built-in retry-as-pass; instead (a) keep assertions behavioural, not pixel-exact where the UI legitimately varies (a `similarity` < 1 on a bounded area), (b) mark a genuinely flaky module `fatal => 0` only with a triage note, (c) re-run a red job once and open a triage entry if it flips. A flip is a finding, not a pass.
- **Artifacts/logs/videos retention**: openQA stores per job `autoinst-log.txt`, `serial0.txt`, screenshots, and `video.ogv`, with configurable cleanup (GRU). For a release gate, mark the job `important` (never GRU-deleted) and mirror the small artifacts to ARGONAS.

### A.2.5 The `openqa-gate` stage (how it plugs into `build-image.sh`)

Today's fixed stage list is:

```
preflight refresh-substrate stage-inputs refresh-sources offline-mirror
layers image kvm-gate provenance-gate receipt archive
```

Proposed insertion — a new **`openqa-gate`** between `provenance-gate` and `receipt`:

```
… image  kvm-gate  provenance-gate  openqa-gate  receipt  archive
```

- **What it runs**: `openqa-cli` against the openQA host to schedule the `ncz` installer job(s) for this image (upload the image as an asset, or download it from the web UI by URL/sha), `--monitor` to completion, parse `/api/v1/jobs/<id>`.
- **Exit codes**: `0` iff every scheduled job `result == "passed"`; `1` otherwise (any `failed`/`incomplete`/`timeout`/`user_cancelled`). This mirrors the existing `kvm-gate.result` convention.
- **Receipt**: write `openqa-gate.result` with `result=PASS|FAIL`, the **job ids**, the **needle-set hash** (sha256 over the sorted needle files), the openQA web UI URL, and the assethash. The `receipt` stage folds this into `run-metadata.json`, and `archive` requires openQA PASS just as it requires KVM + provenance PASS.
- **`--gates`** gains `openqa` (currently `kvm,provenance`).
- **Replacement/augmentation of the pyte check**: **augment, do not replace** in P1. The pyte arm64 check remains authoritative for the serial dialog *order* until the openQA arm64 job is green for a full cycle; the amd64 `PASS-LIMITED` framebuffer check is **superseded** by per-dialog needles in P1 (that is the whole point).
- **Prototype of the gate** (verified in P0): `openqa-gate.sh` exits `0` for passing jobs and `1` for a cancelled/failed job, and prints the needle-set hash — see A.4.

### A.2.6 Nightly vs weekly

Aligned with the `nightly` design (`briefs/nightly-brief.md`; `nightly/REPORT.md` not yet written at the time of this session):

- **Weekly full image** (`build/build-image.sh --arch both --full --sources latest --no-publish`) ⇒ schedule the **full openQA install run** (amd64 + arm64) and the P3 first-boot/desktop modules. This is the "reference-image" run.
- **Nightly canary** ⇒ **payload-level tests only** (no full install): static shader gate, `meson test` where present, provenance input modes, the SceneFX hardware smoke. openQA is not run nightly.

---

## A.3 Hardware automation (the four primary test systems)

Hosts (from `briefs/nightly-brief.md`): **O6N `.3`** (Radxa Orion O6N, CIX Sky1/Mali, arm64), **MEDUSA `.38`** and **CHIMERA `.6`** (MacBookPro16,1 T2, amd64), **PEGASUS `.85`** (ASUS ROG, amd64 non-T2).

**What openQA's `generalhw` backend could automate:** serial UART console (all four, if wired), SSH/xterm console, **HDMI capture card** for screen screenshots, **USB keyboard/mouse emulation** for input, and **power control** (a network smart plug or a relay board; IPMI only if the host has a BMC — these do not). Flashing an SD/ESP via a hardware programmer is scriptable in principle.

**What stays operator-only:** **flashing** images to the four hosts; **T2 SEP/secure-boot** boot selection on MEDUSA/CHIMERA; firmware/EC changes; and physical intervention (the T2 GPU-recover kill from `nightly-brief.md`). Also: openQA cannot touch a host that is mid-GPU-work.

**Recommendation:** **declare hardware openQA out of scope for P1/P2**, and treat it as an opt-in later project (D8). A minimal honest path, if pursued, is **one host at a time**: a **serial-to-USB** adapter + a **network smart plug** + an **HDMI capture dongle** (e.g. a UVC grabber) on **PEGASUS** (the non-T2 control machine, least risky). Budget: ~1 day of wiring + ~2–3 days of `generalhw` scripting per host, plus ongoing cable/host maintenance — poor value compared to VM coverage. Keep the current **operator hardware checklist** (flash + boot-test) as the release gate.

---

## A.4 PROTOTYPE (P0) — what was run, and the evidence

> Time-boxed. Host: **PROTEUS `192.168.207.68`** (permitted: idle, WIP backed up SAFE-TO-WIPE; used as an ordinary build host, scratch under `~/Projects`, nothing wiped). **ACHILLES/ULTRA not touched** (two image builds in flight). No outbound exposure beyond the LAN; container removed at the end.

### A.4.1 Exact setup

```
# on PROTEUS (Debian 13 trixie, 20 vCPU, 30 GB RAM, rootful podman, /dev/kvm present)
mkdir -p ~/Projects/openqa-proto && cd ~/Projects/openqa-proto
podman pull registry.opensuse.org/devel/openqa/containers/openqa-single-instance
sudo podman run -d --name openqa-proto --device /dev/kvm \
     -p 1080:80 -p 1443:443 \
     registry.opensuse.org/devel/openqa/containers/openqa-single-instance
# web UI: http://<proteus>:1080  (openqa-cli available inside the container)
sudo podman exec openqa-proto openqa-cli api jobs
```

### A.4.2 Versions, digest, resources

| Item | Value |
|---|---|
| Container image | `registry.opensuse.org/devel/openqa/containers/openqa-single-instance:latest` |
| Image **digest** | `sha256:af4bca0a2a3efa32a8cc7dc30a490b837a011c18e9aa8d4d718227895c203b1d` (config `6bfe60ea8216`), 1.49 GB |
| Guest OS | openSUSE Tumbleweed `20261009` |
| openQA | `5.1791468191.ebf995c1-1.1` |
| os-autoinst | `5.1790961809.b728c27-1.1` (isotovideo API v60) |
| QEMU | `qemu-x86 11.1.2` |
| Auth | `[auth] method = None` (no credentials to leak; LAN-only, ephemeral) |
| Idle footprint | ~13 % CPU, ~1.5 GB RAM, ~1.2 GB storage; host load ~0.2 |

### A.4.3 Jobs run

| Job | Distri / build | What | Result | Wall |
|---|---|---|---|---|
| 1 | `example` (upstream) | QEMU boot, needle match (`bootloader`→`no-boot-media`) | **passed** | ~16 s |
| 2 | `ncz` netinst UEFI | first attempt — bad test API (`save_screenshot` arg) | failed (test bug) | — |
| 3 | `ncz` netinst UEFI | capture pass (boot) | **passed** | ~33 s |
| 4 | `ncz` netinst UEFI | GRUB key-edit to inject `console=ttyS0` — **did not take effect** (serial unchanged) | user_cancelled | — |
| 5 | `ncz` netinst UEFI | **needle `ncz-boot-menu` + serial assert + boot** | **passed** | ~33 s |
| 6 | `ncz` netinst UEFI | **needles `ncz-boot-menu` + `ncz-di-first`, serial assert** | **passed** | ~12 s |

Job 6 log proof: `found ncz-boot-menu, similarity 1.00 @ 0/0` **and** `found ncz-di-first, similarity 1.00 @ 0/0`; `serial0.txt` contains `BdsDxe: loading Boot0002` and `wait_serial` matched it. Module `installer_boot` = `passed`. Web UI reachable from STUDIO over the LAN (HTTP 200); `/api/v1/jobs` returns the results.

### A.4.4 The `ncz` test distribution (P0 seed)

```
ncz/main.pm
ncz/scenario-definitions.yaml      # product ncz / flavor installer / machine uefi-64 (backend qemu)
ncz/tests/installer_boot.pm        # assert_screen ncz-boot-menu / wait_serial / assert_screen ncz-di-first
ncz/needles/ncz-boot-menu.{json,png}   # GRUB menu (OVMF UEFI)
ncz/needles/ncz-di-first.{json,png}    # d-i first screen
```

Needle-set hash (sorted `sha256sum`): `7cfd59d225ec73708847d9d22e5bd9eb03f4f3a6cd0e70703f3e24874f274357`.

### A.4.5 Gate prototype (verified)

`openqa-gate.sh <HOST> <NEEDLES_DIR> <JOB…>` queried `/api/v1/jobs/<id>` and exited **0** for jobs 1/5/6 and **1** for the cancelled job 4 — i.e. the exact control-flow a `build-image.sh` `openqa-gate` stage needs.

### A.4.6 What worked / what failed (honest)

- **Worked:** single-instance bootstrap; UEFI OVMF boot of our netinst substrate; needle authoring from captured frames (auto-detected the text bbox, but the Debian GRUB theme fills the frame, so the needle is full-screen with `similarity 0.90`); needle match at 1.00; serial assertion; REST gate; LAN UI.
- **Failed / not done:** (a) injecting `console=ttyS0` by editing the GRUB entry via `send_key` did **not** take effect — so the serial assertion in P0 is on the **SUT's firmware/GRUB serial**, not the installer's progress lines (our own rEFInd images *do* pass `console=ttyS0`, and the arm64 pyte check already consumes those lines — that path is P1/P2); (b) **no full install to completion** and **no first-boot module** (time-box); (c) **no arm64 job** (ULTRA busy; and aarch64 KVM there is unverified); (d) the scenario-definitions schema rejected machine `vars` — pass `UEFI=1` as a scheduling variable instead.

### A.4.7 Exact commands (reproducible)

```
# schedule (inside the web UI container)
openqa-cli schedule async=1 \
  SCENARIO_DEFINITIONS_YAML_FILE=/var/lib/openqa/share/tests/ncz/scenario-definitions.yaml \
  DISTRI=ncz VERSION=26.10 FLAVOR=installer ARCH=x86_64 TEST=installer_boot BUILD=proto8 \
  CASEDIR=/var/lib/openqa/share/tests/ncz PRODUCTDIR=. NEEDLES_DIR=/var/lib/openqa/share/tests/ncz/needles \
  ISO=debian-testing-amd64-netinst.iso UEFI=1 QEMURAM=2048 _GROUP_ID=0
# gate
openqa-gate.sh http://localhost:1080 /var/lib/openqa/share/tests/ncz/needles 6   # rc=0 iff passed
```

Full logs (`autoinst-proto7.log`, `autoinst-proto8.log`, `jobs.json`, `versions.txt`, `needle-hashes.txt`, the `ncz` distro) are archived in `openqa/openqa-evidence.tgz` and ARGONAS `reports/r203-openqa-scope-evidence/`.

---

## A.5 Cost/benefit, recommendation, phases, hosting, risks

### Cost/benefit

| | Benefit | Cost |
|---|---|---|
| openQA P1 (amd64 installer gate) | Replaces the `PASS-LIMITED` amd64 check with real per-dialog reference matching; result history + video; a REST gate. | ~3–5 engineer-days (host + distro + needles + stage); ongoing needle maintenance when the UI changes. |
| openQA P2 (arm64) | Visual dialogs on arm64 in addition to the pyte serial check. | aarch64 KVM/TCG must be measured; TCG is slow; +2–3 days. |
| openQA P3 (first boot/desktop) | Catches greeter/desktop/failed-unit/wallpaper regressions in a VM. | +3–5 days; some checks still need real GPUs. |
| openQA P4 (nightly) | Weekly reference run; nightly stays cheap. | +1–2 days; storage/retention. |
| **Part B (hermetic + attested builds)** | **The operator's stated requirement**: same SHA + pins ⇒ identical image, and a build that cannot silently change under you. | mostly quick wins (B1–B4: ~2–4 days); long poles (arm64 second host, full attestation) larger. |

### Recommendation

**Part A: ADOPT-LATER (P1), scoped and additive.** openQA is proven and cheap to stand up; the prototype shows the plumbing works against our own substrate today. But since a nondeterministic image yields nondeterministic needles, sequence it after Part-B quick wins. **Part B: ADOPT NOW.**

### Phased plan

| Phase | Scope | Effort (eng-days) |
|---|---|---|
| **P0 (done)** | Single-instance openQA + `ncz` distro + UEFI needle/serial proof + gate prototype. | 0.5 (done) |
| **P1** | AMD64 installer gate: persistent web UI (ARGOS) + 1 worker (HYDRA); full `ncz` distro (all branded dialogs, offline-mirror assert, post-install feedback serial lines); `openqa-gate` stage in `build-image.sh` after `provenance-gate`; replace the amd64 `PASS-LIMITED` framebuffer check with needles; receipt = job ids + needle-set hash. | 3–5 |
| **P2** | arm64: measure aarch64 KVM on ULTRA / TCG fallback; `ncz` arm64 needles for the 8 ordered dialogs; keep pyte as the serial cross-check. | 2–3 |
| **P3** | First-boot/desktop modules: greeter/desktop screen, `systemctl --failed`, wallpaper smoke; GPU lines asserted via serial. | 3–5 |
| **P4** | Weekly integration: weekly full image ⇒ openQA run; nightly ⇒ payload-level only; retention + triage. | 1–2 |
| **H (opt-in, later)** | Real-hardware `generalhw` on PEGASUS (serial + smart plug + HDMI capture). | 3–5/host + hardware |

### Hosting plan

- **Web UI (persistent):** **ARGOS `.22`** (idle, load ~0.1) in a container, no LAN exposure beyond the fleet, `auth=None` *only* if firewalled to the fleet; otherwise create one operator API key and disable `None`.
- **Worker:** **HYDRA `.78`** (busy; **1 worker slot**, `-j 4` cap per house rules) — GPU-less qemu is fine. Do **not** put workers on ACHILLES/ULTRA while image builds run.
- **Disk:** ~40 GB per worker for pool/results + the ISO/image assets (images are ~8–15 GB each; keep the last N builds only).
- **Version pinning:** pin the single-instance image **by digest**; keep web UI and worker on the **same** openQA version.

### Risks

- **Flaky needles** on UI churn → treadmill; mitigate with bounded `similarity`, behavioural assertions, and a needle-review step in PRs.
- **openQA version churn** ("disruptive changes") → pin by digest; upgrade deliberately.
- **TCG-slow arm64** if aarch64 KVM is unavailable → long job times; measure first.
- **Nondeterministic images defeat the point** → this is exactly why Part B comes first.
- **`auth=None` exposure** → firewall to the fleet or use an API key.

---

# PART B — reproducible + deterministic build/test system

## B.0 Current state (what already exists)

All from `docs/IMAGE-BUILD-PROCESS.md`, `buildproc/REPORT.md`, `rebuild/REPORT.md`, `provgate/REPORT.md`, `sidledger/REPORT.md`, and the tree at `73f3dcbf`. **[VERIFIED unless noted]**

- A single entrypoint `build/build-image.sh` with a fixed stage list, scopes (`full`/`respin`/`quick-respin`/`rebuild-base`/`rebuild-desktop`/`rebuild-hotfix`/`components`/`only-image`), `--arch amd64|arm64|both`, `--offline`, `--gates kvm,provenance`, `--resume-from`, `--container`, `--jobs`.
- A **determinism contract** (§5.1) and a fingerprint model (`build/lib/layerplan.py`) that deliberately excludes the git SHA and `SOURCE_DATE_EPOCH` so quick respins reuse layers.
- Fixed `SOURCE_DATE_EPOCH`, `LC_ALL=C`, `TZ=UTC`, `umask 022`; reproducible `tar`/`mksquashfs`/`mke2fs`/`vfat`/GPT wrappers (`build/lib/reproducible.{sh,py}`); pinned filesystem/GPT UUIDs and FAT serial.
- A compare tool `build/compare-images.sh` (whole-file sha256 + normalisation; `--expect` rules: `content-equal-container-diff`, `json-volatile-only`, `documented-exception`).
- Byte-stability tests (`make test-build`) green on ACHILLES/HYDRA (x86_64, mksquashfs 4.7.5) and ULTRA (aarch64, 4.6.1).
- **Not yet done:** the full **two-image** determinism run (build each arch twice from clean state and compare the final `.img` + every layer) — the tool and recipe exist; the run is the next dispatch (`buildproc/REPORT.md` §3).
- Provenance: three-origin rule + one-kernel rule (`build/forky-provenance.py`); per-package `sid` exceptions ledger (`manifests/sid-exceptions.tsv`); substrate must be refreshed each build and the snapshot derived from it.
- Environment defect found during a real build: ACHILLES's `~/.api_keys_master.json` lacked `fleet_credentials.sudo_password` → preflight failed until supplied (`rebuild/REPORT.md` §4.1.5).

## B.1 (a) The contract

> **Contract.** Given the same **git commit** and the same **recorded pins** (`manifests/base.pin`, `manifests/determinism.pin`, and the input ledgers `manifests/{build-inputs,ncz-packages,vendor-debs,vendor-repos,forky-snapshot}.tsv`), a build produces **bit-identical** artifacts: the `.img`, every squashfs layer, the initrd, and the ESP contents. Every deliberate difference is a **normalised exception** recorded in an `--expect` file with a rule, a reason, an owner, and an expiry.

**Strengthening (proposed):** the contract should name the **build environment** as part of "recorded pins" — i.e. the **container image digest**, toolchain versions, and pinned firmware — because today two builds with different `mksquashfs` (4.6 vs 4.7) can differ. Add `env.pin` (see B.3). Also: the contract must be **enforced**, not just documented — `--offline` should be required for shipped/nightly builds, and an **attestation** (B.6) should record the inputs+outputs so a third party can check the claim.

## B.2 (b) Hermetic inputs — every network access in the build, and the fixes

**Method used:** static analysis of the build tree (`rg` over `build/`, `assets/`, `post-install/`) plus the observed build logs. **Not done:** the runtime `strace -f -e trace=network` / no-route-netns capture the brief asked for — ACHILLES/ULTRA have image builds in flight and HYDRA is shared, so I did not run a payload build. The recipe to close this is below and is a B1 task.

### B.2.1 Inventory (static) — **[VERIFIED by reading the tree]**

| # | Where | Fetch | Pinned? | Hermetic today? |
|---|---|---|---|---|
| 1 | `build/build-singularity.sh` (payload container) | `go build -o /usr/local/bin/vetro .` → **Go module downloads** (`github.com/mirkobrombin/go-cli-builder/v2 v2.0.5`, `.../go-foundation v0.2.0`) | **No** (no vendor dir; no `go.sum` pin recorded) | **No — confirmed by the live log** |
| 2 | `build/build-singularity.sh` (payload container) | `apt-get update && apt-get install …` against the **rolling Debian mirror** | **No** (not the pinned snapshot) | **No** |
| 3 | `build/build-singularity.sh` / `singularity-pins.sh` | `git clone --mirror` / `git fetch` of the superproject + ~30 submodules + `vetro` + boot-splash | SHA pinned (`assets/singularity/upstream-pins.tsv`) but **URL fetched** | **Partial** — mirror cache exists (`$CACHE`) but not hashed into the pin; falls back to network |
| 4 | `build/build-singularity.sh` | `git clone --recursive --branch <ref>` of `singularity-desktop` | superproject SHA via override; **submodules via `.gitmodules`** | **Partial** |
| 5 | `build/patch-singularity-scenefx.sh` + `meson setup` | `labwc/subprojects/scenefx.wrap` (`[wrap-git]`, `revision=`) + wlroots wrap resolved at setup | revision named in the wrap, **fetched** | **No** (network unless pre-seeded) |
| 6 | `build/build-libdrm-debs.sh` | `curl -fsSLO "$BASE_URL/$f"` (source tarball) | URL in script; **sha not clearly enforced** | **Partial** |
| 7 | `build/pin-forky-snapshot.sh`, `build/refresh-substrate.sh` | `snapshot.debian.org`, `cdimage.debian.org` (substrate/snapshot pins) | **Yes** (GPG-verified, digest recorded) | Expected (pinning activity) |
| 8 | `build/check-ncz-repo-policy.sh` | `curl` of package sources, Buildkite `InRelease`, R2 `Release` | n/a (policy check) | Network by design |
| 9 | `build/singularity-deb-depends.sh` | `apt-get update && apt-get install` inside a container | **No** | **No** (analysis tool) |
| 10 | `post-install/46-python311.sh`, `88-noe-umd-venv.sh`, `55-t2-firmware.sh` | bounded `curl` fallbacks | n/a | **Install-time** network; offline-first with timeouts — relevant to the offline-install rule |
| 11 | Wallpaper/artist packs | built from `assets/wallpaper*`; `ncz-wallpaper-bing fetch` is a **runtime** helper (not build) | n/a | Build-time is local; verify no artist-pack fetch sneaks in |

**No** `cargo`, `npm/pnpm/yarn`, or `pip/uv` fetch was found **in the image build**; Go (vetro), git, apt, and meson wraps are the actual offenders. (`uv`/`pip` appear only at install time in `89-npu-embed-server.sh`.) **[VERIFIED by `rg`]**

### B.2.2 Per-ecosystem fixes

- **Go (vetro — the confirmed gap).** Best: **vendor** the modules and build offline. Since vetro is an upstream repo, do it non-invasively:
  1. resolve vetro at its pinned SHA, run `go mod download`/`go mod vendor` **once** into a content-addressed cache keyed by the vetro commit + `go.sum` digest;
  2. record that digest in `manifests/determinism.pin`;
  3. at build time: `GOFLAGS=-mod=vendor GOPROXY=off GOSUMDB=off go build` (vendor tree copied in), or `GOPROXY=file://$CACHE GONOSUMDB=* GOSUMDB=off go build -mod=mod`.
  - **Verify offline**: the build must fail if the cache is absent, never silently fetch.
- **apt (payload container).** Replace `apt-get update` with the **pinned snapshot** mirror (`snapshot.debian.org/archive/debian/<timestamp>` from `manifests/base.pin`) using the committed keyring + `sha256`, exactly as the offline mirror already does. No rolling mirror inside the build.
- **git.** Make the `singularity-pins.sh` mirror cache the **only** source and **hash the mirror set** into `determinism.pin`. In `--offline`, a missing commit is a hard error (no network fallback).
- **meson wraps.** Pre-fetch `subprojects/*.wrap` (`scenefx.wrap`, wlroots) at their declared `revision=` into a content-addressed cache; seed `subprojects/<name>` before `meson setup`; run meson with `--wrap-mode=nodownload`; verify the wrap URL+revision hashes.
- **curl source fetches.** Pin URL **and** sha256 in a manifest; verify before use.
- **Policy:** `build-image.sh --offline` becomes **fail-closed** and is **required** for any image that can be published. The nightly canary may use `--sources latest` (network by design) but must still be offline for the *dependency resolution* step.

### B.2.3 Closing the inventory (the runtime check the brief asked for)

Recipe (one task, ~1–2 h on an idle host):

```sh
# A) no-route netns: run the payload build with no network and see exactly what fails
sudo ip netns add ncz-nonet
sudo ip netns exec ncz-nonet bash -c '<payload build cmd>'   # every fetch becomes a visible error
# B) syscall view of a normal run
sudo strace -f -e trace=network -o /tmp/ncz.net \
     bash -c '<payload build cmd>'
grep -E 'connect\(' /tmp/ncz.net | awk '{print $NF}' | sort -u   # every endpoint contacted
```

Add both as a **test** (`build/test-build-hermetic.sh`) that asserts the offline run reaches the same artefact hash as the online run.

## B.3 (c) Build environment pinning

| Item | Today | Required |
|---|---|---|
| Build container | `localhost/ncz-imagebuild:trixie` (a **tag**) | **pin by digest**; record it in `env.pin`; rebuild/refresh deliberately |
| Payload container | `debian:<codename>` (a **tag**) | pin by digest |
| Toolchain | mksquashfs **4.6 (ULTRA) vs 4.7 (ACHILLES/HYDRA)** → can differ | same major.minor across the verification pair; record versions in `env.pin`; ideally run the same container everywhere |
| Locale/TZ/umask | `LC_ALL=C TZ=UTC umask 022` | keep; assert in preflight |
| `SOURCE_DATE_EPOCH` | commit time / `snapshot_epoch` | keep; record in the receipt |
| Kernel/uname/CPU-dependent steps | some `uname -m` branches; `-march`? | audit for `-march=native`/`$(uname -r)`; pin or prefix-map |
| Build path leakage | `$ROOT`, `DESTDIR`, compilers may embed absolute paths | build at a fixed path and/or use `-fdebug-prefix-map`/`--build-path` where the tool supports it |
| Parallelism | `mksquashfs -processors 1` (fixed); make/ninja default | pin `-j` for anything that can affect byte order; Go/meson are reproducible under parallelism, but verify |
| OVMF/AAVMF firmware | from the host runtime | pin firmware files by digest for VM tests |

Deliverable: a committed **`manifests/env.pin`** (container digests, tool versions, firmware digests) checked by preflight, alongside `base.pin`/`determinism.pin`.

## B.4 (d) Nondeterminism — found, unknown, and how to find the rest

**Already found and fixed (from `buildproc/REPORT.md`):** mksquashfs thread count/timestamps; the mksquashfs≥4.7 `SOURCE_DATE_EPOCH` conflict; base reuse stamp missing `assets/wallpaper/`+`post-install/`; `gen-base-pin --check` host-dependence; `mke2fs` UUID/`hash_seed`; GPT GUIDs + FAT serial; `ncz_canon_tree` using GNU `find -printf` (empty on BSD); build-time timestamps leaking into artifacts; the container not seeing the substrate cache; kernel-staging symlink spelling; per-run password FIFOs; scratch on tmpfs; the Singularity payload's build-time version string.

**Remaining unknowns (to hunt):**
- **initrd/dracut**: embedded timestamps, module ordering, `/etc/machine-id` inside the initramfs.
- **dpkg status ordering**; `ldconfig` cache (claimed deterministic — verify); **fontconfig**, **man-db**, **mime** caches.
- **ext4/btrfs** inode allocation/`lazy_itable_init`; squashfs inode ordering; **vfat** directory-entry order.
- **GPT** backup header + disk GUIDs (pinned) — verify the protective MBR.
- **ISO (Rock Ridge/Joliet)** timestamps if an ISO is produced; `xorriso` defaults.
- **random seeds**, `/etc/machine-id`, `ssh_host_*` (handled: stripped at bake, regenerated first boot).
- **`/proc`, `hostname`, `date`, `lsb_release`** leakage into packages/scripts.

**How to find the rest:** run **`diffoscope`** on two builds; run **`reprotest`** with the `build`/`vary` variations; follow **reproducible-builds.org** guidance for **filesystem images** (ext4/squashfs/GPT timestamps and UUIDs). Wire `compare-images.sh` (already present) as the arbiter.

## B.5 (e) Independent verification (second host)

- **amd64:** build on **ACHILLES** and independently on **HYDRA** (both x86_64, same mksquashfs 4.7.5) or **PROTEUS** (Debian trixie — check its mksquashfs version first). Compare with `build/compare-images.sh` and emit an attestation.
- **arm64:** **ULTRA is the only arm64 build host today.** **TYDEUS is not an image host.** So arm64 "second-host" verification is currently impossible → either (a) accept **same-host repeatability only** for arm64 and state so in the contract, or (b) add a second arm64 host (Ampere-class). This is D6.
- **Weekly ritual:** the weekly full build produces a second-arch/second-host comparison + a signed attestation; a mismatch is a release blocker.

## B.6 (f) Signed provenance / attestations

Per image, emit an **in-toto/SLSA-style statement** (JSON) alongside the `.img`:

```json
{
  "_type": "https://in-toto.io/Statement/v1",
  "subject": [{"name": "ncz-os-amd64-...img", "digest": {"sha256": "..."}},
              {"name": "base.squashfs", "digest": {"sha256": "..."}}, ...],
  "predicateType": "https://slsa.dev/provenance/v1",
  "predicate": {
    "buildType": "https://ncz-os/buildtypes/image/v1",
    "builder": {"id": "<host>"},
    "invocation": {"configSource": {"uri": "git+.../cix-installer", "digest": {"sha1": "<git sha>"}},
                   "parameters": {"arch": "amd64", "sources": "pinned", "pins": {"base":"...","determinism":"...","env":"..."}}},
    "materials": [{"uri": "pkg:deb/...","digest": {"sha256":"..."}}, ...],
    "metadata": {"buildStartedOn": "...", "buildFinishedOn": "...", "completeness": {"parameters": true, "environment": true, "materials": false}},
    "gates": {"kvm": "PASS", "provenance": "PASS", "openqa": {"result":"PASS","jobs":[6],"needle_set":"7cfd..."}},
    "byproducts": [{"name": "build-metadata.json"}]
  }
}
```

**Signing (propose; do not create keys):** sign with **`minisign`** (simple, offline, Ed25519) or **`cosign`** (Sigstore; supports keyless OIDC or a key). **Key custody:** an **operator-held** offline key (hardware token for cosign, or a file key on an offline machine). Agents **never** generate, hold, or use release keys. Verification happens in `build/stage-to-argonas.sh` (the image never reaches ARGONAS `images/` unsigned) and again at any promotion/flash step.

## B.7 (g) Policy — what is allowed to differ

- **Allowed to differ (NOT artifact inputs):** the run wall-clock, the run id, the image **filename date**, and anything in a separate **`build-metadata.json`** (build start/finish, host, operator, durations). These are **never** hashed into an artifact.
- **Everything else must be bit-identical**, or listed as an **exception** in the `--expect` file consumed by `compare-images.sh`, with columns `path | rule | reason | owner | expiry`. As of `buildproc`, there are **no exceptions for the amd64/arm64 final image**; only `content-equal-container-diff` normalisation is auto-accepted.
- **Exception hygiene:** an exception with no expiry or no owner fails a lint; exceptions are reviewed monthly (same cadence as the `sid` ledger).

## B.8 (h) Roadmap — what to do FIRST

| id | Task | Type | Effort | Depends |
|---|---|---|---|---|
| **B1** | Make the payload build hermetic: vendor Go (vetro) + offline `GOPROXY`; pinned-snapshot apt; pre-fetched meson wraps; git from the mirror cache only; `--offline` **fail-closed** | Quick win | 2–3 d | — |
| **B2** | `manifests/env.pin` (container digests + tool versions + firmware) checked by preflight | Quick win | 0.5 d | — |
| **B3** | Add the no-route-netns + `strace` hermeticity **test**; assert offline hash == online hash | Quick win | 1 d | B1 |
| **B4** | Run the **full two-image determinism** comparison (each arch twice, clean) with `compare-images.sh`; archive the report | Quick win | 1–2 d runtime | B1, B2 |
| **B5** | `diffoscope`/`reprotest` sweep for the remaining unknown nondeterminism (initrd, caches, ISO) | Medium | 2–3 d | B4 |
| **B6** | Second-host independent build + comparison (amd64 ACHILLES↔HYDRA/PROTEUS) | Medium | 1–2 d | B4 |
| **B7** | **arm64 second build host** (D6) or formally scope arm64 as same-host-only | Long pole | host-dependent | — |
| **B8** | Per-image **attestation** (in-toto/SLSA) + `minisign`/`cosign` verification in `stage-to-argonas.sh`; operator key custody (D7) | Long pole | 3–5 d | B2, B4 |
| **B9** | openQA **P1** amd64 gate + `openqa-gate` stage | Part A | 3–5 d | B1 (so needles are stable) |

**Do first:** B1 + B2 + B3 — they are small, they close the confirmed non-hermeticity, and they make everything downstream (determinism, attestation, openQA) meaningful. Then B4/B5/B6, then B8, then Part-A P1+.

### Roadmap status — branch `fix/r203-hermetic-20261010` (2026-10-10)

| id | Deliverable | Status |
|---|---|---|
| B1 | payload build hermetic (Go modules, apt, meson wraps, git mirrors, `--offline` fail-closed) | **DONE (code + tests)**: `build/fetch-inputs.sh` (phase-1 content-addressed caches + `inputs.lock`), `build/lib/offline.sh` (enforcement), `build-singularity.sh`/`build/singularity-pins.sh` consume caches offline (`--network none`), `--offline` default for `--full`. Remaining: the payload-container **apt build-dep closure** is not yet a phase-1 cache (tracked; `phase2-todo` in the allowlist) |
| B2 | `manifests/env.pin` (container digests + toolchain) checked by preflight | **DONE**: `manifests/env.pin`, `build/gen-env-pin.sh`, `build/lib/envpin.sh`; preflight FAILs with a per-key diff |
| B3 | no-route-netns + strace hermeticity test | **DONE**: `build/test-hermetic.sh` (unit + fixture + both-directions + lint) in `make test-build`; empirical `strace`/`--network none` inventory captured (hermetic/evidence) |
| B4 | full two-image determinism comparison | **IN PROGRESS (rebuild session owns the run)**; the tooling (`compare-images.sh`) is unchanged and wired into `verify-reproducible.sh` |
| B5 | diffoscope/reprotest sweep | **SCAFFOLDED**: `verify-reproducible.sh` runs diffoscope when present (none installed yet — venv under `~/Projects`) |
| B6 | second-host independent build (amd64 ACHILLES↔HYDRA/PROTEUS) | **SCAFFOLDED**: `build/verify-reproducible.sh` + `build/config/builders.tsv` |
| B7 | arm64 second build host (D6) | **DESIGNED**: cixmini `.66` is the second arm64 builder once stabilised; `docs/BUILD-HOST-PROVISIONING.md` (deliverable only, not provisioned); arm64 runs same-host-twice recording `second_builder=pending(cixmini)` |
| B8 | per-image attestation (in-toto/SLSA) + signing | **SCAFFOLDED**: `build/attest.sh` emits the statement with `builder_cpu`/`builder_kernel`/`builder_container_digest` (+ CPU-independence claim); signing is operator-key-only (D7) |
| B9 | openQA P1 amd64 gate | **NOT STARTED** (Part A; sequence after B1–B4) |

---

## Appendix — prototype artifact index

- `ncz` distro (P0 seed): `openqa/ncz-distro/` in the evidence bundle.
- Gate prototype: `openqa/openqa-gate.sh`.
- Logs: `openqa/autoinst-proto7.log`, `openqa/autoinst-proto8.log`, `openqa/serial0-proto7.raw`, `openqa/serial0-proto8.raw`, `openqa/jobs.json`, `openqa/versions.txt`, `openqa/needle-hashes.txt`.
- ARGONAS: `reports/r203-openqa-scope-evidence/` (same bundle).

## Cleanup receipt (P0 prototype)

**Removed on PROTEUS `.68` (scratch under `~/Projects`, never tmpfs):**
- container `openqa-proto` (stopped + `podman rm -f`);
- image `registry.opensuse.org/devel/openqa/containers/openqa-single-instance:latest` (untagged + deleted, config `6bfe60ea8216`);
- scratch `~/Projects/openqa-proto/` (`rm -rf`, verified absent);
- no volumes or other containers left. `df /`: **219 G → 216 G used** (~3 GB reclaimed).
- No tag / ship-image / reap / flash / GitHub / live Buildkite-R2; PROTEUS content otherwise untouched (no wipe/reinstall).

**Kept (list):** `~/Projects/oc-mission-20261010/openqa/openqa-evidence.tgz` on STUDIO and ARGONAS `reports/r203-openqa-scope-evidence/` (report + prototype distro + logs). Nothing was left running anywhere.

## Sources (fetched/read 2026-10-10 unless noted)

- openQA: https://github.com/os-autoinst/openQA (README; `docs/Installing.md`; `docs/backends.md`; container layout via GitHub contents API).
- os-autoinst: https://github.com/os-autoinst/os-autoinst (`doc/backends.md`; `backend/generalhw.pm`, `backend/ipmi.pm`; `consoles/vnc_base.pm`, `serial_screen.pm`; `doc/backend_vars.md`; GPL-2.0-or-later).
- Example distro: https://github.com/os-autoinst/os-autoinst-distri-example (`main.pm`, `tests/boot.pm`, `needles/bootloader.{json,png}`, `scenario-definitions.yaml`).
- openSUSE generalhw recipe: `os-autoinst-distri-opensuse/data/generalhw_scripts/raspberry_pi_hardware_testing_setup.md`.
- Debian instance: https://openqa.debian.net (job groups; version 5.1782486535…; GPL-2.0). Tests repo: https://salsa.debian.org/qa/openqa/openqa-tests-debian (**fetch blocked by a bot challenge — contents not read**).
- Fedora: https://openqa.fedoraproject.org (HTTP 200); https://github.com/os-autoinst/os-autoinst-distri-fedora.
- openSUSE: https://openqa.opensuse.org (HTTP 200).
- Reproducible builds: https://reproducible-builds.org/docs/ ; https://diffoscope.org ; reprotest (reproducible-builds.org tools).
- Attestations: https://in-toto.io ; https://slsa.dev ; Sigstore cosign (docs.sigstore.dev); minisign.
- This repo: `docs/IMAGE-BUILD-PROCESS.md`, `build/build-image.sh`, `build/kvm-install-gate-gpt.sh`, `build/kvm-installer-ui-check.sh`, `build/lib/{layerplan,reproducible,priv}`, `build/compare-images.sh`, `build/build-singularity.sh`, `build/patch-singularity-scenefx.sh`, `build/singularity-pins.sh`, `manifests/*`, and the mission reports under `~/Projects/oc-mission-20261010/{buildproc,rebuild,rebuildarm,provgate,sidledger,installaudit,proteusbackup,nightly}/`.
