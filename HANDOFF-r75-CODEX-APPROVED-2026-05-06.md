# r75 unattended-build + Codex 6-round review handoff — 2026-05-06

**Status:** Codex adversarial-review **APPROVED** (verdict=approve, "no material findings") on take-10 at commit `3de7b30`.
**Build host:** ARGOS, `~/cix-installer-build/cix-installer/`.
**Repo state:** `main` at `3de7b30` (ARGOS + ARGONAS bare); local Mac r75-review branch tracks the same.

---

## Canonical r75 ISO

| Property | Value |
|---|---|
| Path on ARGOS | `/home/jasonperlow/cix-installer-build/cix-installer/build/ncz-installer-cixmini-26.5.r75-Reinhardt-thin.iso` |
| Size | 9.3 GB (9,348,395,008 bytes) |
| sha256 | `eebfe1df88782c23c32a02f9fd529a9035040347f2f86b5f15553250eb04cc35` |
| Build log | `argos:.../build/build-r75-take10.log` |
| Build version sidecar | `26.5.r75-Reinhardt-thin` (in `cixmini/BUILD_VERSION` inside ISO) |
| Build variant sidecar | `desktop` (Reinhardt SKU; Magnetar would set `server`) |

---

## 16 commits over 10 build takes (3664459..3de7b30)

### Functional patches (10 commits, takes 1–5)

| # | Commit | Item |
|---|---|---|
| 1 | `3664459` | K1: linux-headers tarball pipeline |
| 2 | `2f90c4b` | K3 default-NEXT + P1 render groups + P2 MAC hostname + P3 cix-noe-umd Py3.13 |
| 3 | `706aced` | P5 ncz CLI v0.1 + build-iso-di abs-path fix (readlink -f) |
| 4 | `a58164c` | K4 Sky1-Linux Mesa 26 apt pin |
| 5 | `0fc98c0` | P4 scope-1 Vulkan + SPIR-V substrate |
| 6 | `3c6e1c4` | docs: r75 release notes |
| 7 | `48f824e` | P5 ncz CLI v0.2 (models/install/status) + assets/cix-py/npu_embed_v2.py |
| 8 | `2fecfab` | K3 v2: systemd-boot 3-try auto-rollback (cixmini-next+3-0.conf) |
| 9 | `dcbdcd9` | M1: Magnetar Server build-variant infrastructure (--variant flag + sidecar + 48-hook) |
| 10 | `e415cb6` | P5: ncz status subcommand |

### Codex adversarial-review fix iterations (6 commits, takes 6–10)

| Round | Commit | Verdict before | Findings closed |
|---|---|---|---|
| 1 | `061025d` | needs-attention (2 HIGH + 3 MED + 1 LOW) | NPU buffer underallocation, NEXT-not-actually-default, cix-noe-umd over-permissive recovery, Magnetar reversibility, Mesa pin glob, hostname collision |
| 2 | `a791f2f` | needs-attention (1 HIGH + 2 MED) | bless-boot hard-fail, cache immutability, iU recovery |
| 3 | `0d33382` | needs-attention (1 MED) | dpkg-query absent path + hard-fail unknown states |
| 4 | `1df95b9` | needs-attention (2 HIGH) | drop bless-boot gate, drop cix-npu-driver-dkms, state-check VPU DKMS |
| 5 | `3de7b30` | needs-attention (1 HIGH) | per-entry cmdline (drop efi=noruntime on NEXT) |
| 6 | (none — review only) | **APPROVE** | "no material findings" |

### Codex review citations
- `review-moukoeqc-yxq7c2` (round 1)
- `review-moul5i32-up0qb9` (round 2)
- `review-mouli3m2-w472rs` (round 3)
- `review-mouluz77-0ybo9n` (round 4)
- `review-moum7y7b-m4lz7k` (round 5)
- `review-moumkusb-9imqxq` (round 6 — APPROVE)

Full Codex logs at `~/.claude/plugins/data/codex-openai-codex/state/cix-installer-a9a3bed73603d6f7/jobs/`.

---

## What's in the approved ISO

### r75 task list status

**Closed in r75 (canonical implementation):**
- K1 #66 — linux-headers tarball staging pipeline (asset production gated on next sky1-linux-build kernel rebuild)
- K3 #113 + K3v2 — default boot NEXT, sort-keys flipped, 3-try boot-counter auto-rollback (`cixmini-next+3-0.conf` + `systemctl enable systemd-bless-boot.service` enabled by systemd generator path)
- K4 — Sky1-Linux Mesa 26 apt pin priority 1001 with version-glob `*sky1*`
- K5 — dual-kernel rule verified (build log shows both 6.18.26-cix-sky1-lts + 7.0.3-cix-sky1-next staged)
- P1 #114 — operator added to render+video+audio+plugdev+input groups via usermod -aG
- P2 #109 — MAC-derived hostname fallback `ncz-<8-hex>` with wired→wireless→machine-id sha256 ladder
- P3 #116 — cix-noe-umd Py3.13 postinst stanza-only patch with iF/iU recovery + libnoe.so post-check + hard-fail unknown states
- P4 scope-1 #111 — Vulkan + SPIR-V toolchain substrate (`47-llm-stack.sh`)
- P5 #115 — ncz CLI v0.2.0 (`desktop on/off/status`, `models pull` STUB, `install mnemos` STUB, `status`, `version`) + npu_embed_v2.py wrapper at `assets/cix-py/`
- M1 #102 — Magnetar Server build-variant infrastructure (`--variant {desktop|server}` flag + `BUILD_VARIANT` sidecar + `48-magnetar-variant.sh` hook)

**Codex-fix safety hardening (rounds 1–5):**
- NPU wrapper: dtype-aware buffer sizing (rejects unknown data_type, immutable cached vectors via `setflags(write=False)`)
- bootloader: per-entry cmdline (LTS keeps `efi=noruntime`, NEXT drops it for bless-boot EFI variable write path), boot-counted entry filename, post-write resolution check, no false fallback to LTS
- cix-noe-umd recovery: iF AND iU handled identically (postinst stanza patch only, not whole-file replace), `dpkg-query || true` for absent-path under set -e, hard-fail unknown states with diagnostics, post-recovery state asserted to `ii`
- DKMS: cix-npu-driver-dkms NOT installed (FyrbyAdditive prebuilt path per task #87); cix-vpu-driver-dkms gated on `/lib/modules/<kver>/build` presence with state-recovery (purge iF/iU)
- Mesa pin: version-glob `*sky1*` instead of `Pin: origin "*"`
- ncz CLI: `desktop on` unmasks DM units before enabling (was failing under set -e on Magnetar systems)

**Deferred (operator action when convenient):**
- K2 NPU patch upstream — what earlier docs called "n4hy v4" is actually `visorcraft/orange-pi-6-plus-npu` (Patch 4 IOVA bypass + Patch 5 MODULE_IMPORT_NS workaround). visorcraft's patches let the aipu module compile against mainline kernel 6.18; they do NOT close the 0x23 NOE_STATUS_TIMEOUT recreate-job-per-call workaround that gates the 70-80 emb/sec target. That separate libnoe userspace fix is closed-source-cixtech or community reverse-engineering territory. See MNEMOS `mem_1778108263413_61ff71` for the attribution + analysis.
- P4 scope-2 #98 — `ncz install mnemos` body (depends on `ncz models pull` LFS strategy)
- P6/P7 #98/#99 — ncz install mnemos / models pull bodies
- M1 server bake test — operator runs `bash build/build-iso-di.sh --variant server ...` on .66
- F3 #117 — bilingual upstream issue publish action (draft at `docs/UPSTREAM-CIX-BILINGUAL-ISSUE.md`)
- F5 #103 — upstream NPU embedder PR to mnemos-os/mnemos (wrapper at `assets/cix-py/npu_embed_v2.py` is the candidate)

---

## Operator next steps

1. **Pull ISO from ARGOS:**
   ```
   scp jasonperlow@192.168.207.22:/home/jasonperlow/cix-installer-build/cix-installer/build/ncz-installer-cixmini-26.5.r75-Reinhardt-thin.iso .
   ```
2. **Verify sha256:**
   ```
   sha256sum ncz-installer-cixmini-26.5.r75-Reinhardt-thin.iso
   # expect: eebfe1df88782c23c32a02f9fd529a9035040347f2f86b5f15553250eb04cc35
   ```
3. **Flash to 16 GB+ USB on Mac:**
   ```
   diskutil unmountDisk /dev/diskN
   sudo dd if=ncz-installer-cixmini-26.5.r75-Reinhardt-thin.iso of=/dev/rdiskN bs=4m status=progress
   ```
4. **Boot MS-R1 from USB and verify each patch** (full checklist in earlier `HANDOFF-r75-UNATTENDED-2026-05-06.md` on `feat/sky1-7.0-next-msr1` branch).
5. **For Magnetar Server SKU**, re-bake on ARGOS:
   ```
   ssh argos
   cd ~/cix-installer-build/cix-installer
   bash build/build-iso-di.sh \
       --bookworm-iso /home/jasonperlow/.../debian-12.13.0-arm64-netinst.iso \
       --root /home/jasonperlow/cix-installer-build/cix-installer \
       --version 26.5.r75-Magnetar-thin \
       --output /home/jasonperlow/.../ncz-installer-cixmini-26.5.r75-Magnetar-thin.iso \
       --variant server
   ```
6. **Push to gitlab.com when ready** — ARGOS doesn't have the gitlab token; do this from Mac after `git fetch argonas main` + `git push origin main`.

---

## Known limitations / risks (none ship-blocking after Codex APPROVE)

- **9.3 GB ISO** — questing-mirror + rootfs.tar.zst dominate. r75 task #61 (`BUILD_MODE=thin|max` flag) deferred — not autopilot-safe to refactor build pipeline. Operator can flash to 16 GB+ USB; r76+ should split.
- **EFI runtime on NEXT untested on real hardware** — round-5 fix removed `efi=noruntime` from NEXT_CMDLINE_BASE based on systemd documentation + the assumption that `linux-cix-sky1-next 7.0.x` handles EFI runtime cleaner than the 6.6.10 fork the noruntime workaround was originally added for. If NEXT proves unstable on .66 without noruntime, the rollback path is to manually pick LTS from systemd-boot menu, then in r76 re-add efi=noruntime to NEXT_CMDLINE_BASE and drop boot-counting.
- **K2 NPU recreate-job workaround unresolved** — NPU stays at the 39.55 emb/sec cold envelope from r74. The `~70-80 emb/sec` target requires fixing libnoe userspace so it doesn't need a fresh job creation per call (the 0x23 NOE_STATUS_TIMEOUT workaround). This is closed-source-cixtech or community-reverse-engineering territory; visorcraft/orange-pi-6-plus-npu kernel patches do NOT close this gap.
- **Install + boot smoke test on real .66 hardware not yet performed** — bash -n syntax + Codex review approve. Runtime behavior on real hardware is verified by the operator post-flash.

---

## Git state

- ARGOS `main` at `3de7b30`
- ARGONAS bare `nclawzero/cix-installer.git/main` at `3de7b30` (canonical fleet backup)
- Local Mac `r75-review` tracks ARGONAS main
- Local Mac `feat/sky1-7.0-next-msr1` has earlier handoff doc + jetson brief commits (separate branch)
- gitlab.com push deferred (token not on ARGOS)

---

*Living doc — update inline as operator verifies items 1–6.*


---

## Post-APPROVE polish (2026-05-06 evening, dynamic /loop continued)

After the 6-round Codex APPROVE on the Reinhardt patches at 18:24 UTC, the dynamic /loop ran further unattended polish:

### Magnetar Server SKU bake validated

Added `--variant server` flag to `build/build-iso-di.sh` (M1 task #102). `48-magnetar-variant.sh` reads `BUILD_VARIANT` sidecar at first boot, sets multi-user.target + masks display-managers + pre-installs NoMachine. Validation bake produced two parallel r75 ISOs at canonical ARGOS path:

| SKU | Sidecar | sha256 |
|---|---|---|
| Reinhardt | `BUILD_VARIANT=desktop` | `eebfe1df88782c23c32a02f9fd529a9035040347f2f86b5f15553250eb04cc35` |
| Magnetar | `BUILD_VARIANT=server` | `df46049a7f3a46a480c5c38075b7e63b504b3a926d95cef8b5f4056304b14669` |

Both 9.3 GB. M1 task #102 closed.

### F5 NPU embedder upstream PR candidate staged

`assets/cix-py/README.md` published with full upstream-PR-ready spec: perf numbers (39.55 cold / 110.51 mixed-50 emb/sec, parity with PYTHIA Intel iGPU), API surface, cache contract (write=False protected), dtype dispatch table, license, attribution to visorcraft + FyrbyAdditive. Wrapper at `assets/cix-py/npu_embed_v2.py` is the candidate for `mnemos.embedders.cix_npu` plugin or standalone `mnemos-embedder-cix-npu` pip package — operator picks shape with mnemos-os maintainers.

### F3 bilingual upstream issue Codex APPROVED (5 rounds)

`docs/UPSTREAM-CIX-BILINGUAL-ISSUE.md` round-trip closed:

| Round | Findings | Fix commit |
|---|---|---|
| 1 | n4hy attribution drift, NVIDIA/Jetson framing, parity overclaim, ZH 嵌入式 -> 向量嵌入 | `2c8806c` |
| 2 | ZH body symmetry to match EN caveats | `7abf223` |
| 3 | EN TL;DR mirror | `f22be8b` |
| 4 | ZH reference symmetry (drop CIX-VS-JETSON cross-link) | `bcde483` |
| 5 | **APPROVE** — ship | (review only) |

MNEMOS `mem_1778117337736_3f9971`. F3 task #117 closed for code/content; operator action: publish per the doc's distribution plan.

### Attribution fix shipped

`n4hy` references in earlier docs were a memory drift; canonical Cix NPU community work is `visorcraft/orange-pi-6-plus-npu`. visorcraft's patches address kernel compile-against-mainline issues, NOT the 0x23 NOE_STATUS_TIMEOUT user-space recreate-job workaround (that's a libnoe userspace ask in the bilingual upstream issue). MNEMOS `mem_1778108263413_61ff71`.

### Repo state at end of polish round

* ARGOS `main` + ARGONAS bare both at the latest r75-review HEAD
* Local Mac `r75-review` branch tracks ARGONAS main
* Local Mac `feat/sky1-7.0-next-msr1` retains the earlier handoff + jetson brief commits (separate branch)
* gitlab.com push deferred (token not on ARGOS — operator does this from Mac)

---

## What's left for operator return

1. Pull Reinhardt or Magnetar ISO from ARGOS, flash to 16+ GB USB, install on .66 (Reinhardt) or a fresh box (Magnetar).
2. Verify the per-patch behavior list in this doc.
3. Push to gitlab.com from Mac.
4. F3 publish: post the bilingual upstream issue per the distribution plan.
5. F5 publish: open a PR to `mnemos-os/mnemos` (or stand up `mnemos-embedder-cix-npu` as a separate pip package) using the staged wrapper + README at `assets/cix-py/`.
6. K2 follow-up: file a tracking issue with cixtech (or `cixtech/cix-linux-main` directly) about the libnoe persistent-job API ask — the bilingual doc covers this.
