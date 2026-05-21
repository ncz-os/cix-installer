# Known Issues — Next NCZ Reinhardt Image (2026-05-20)

**Surfaced during:** Post-`7.0.9-cix-sky1-next` kernel boot validation on cixmini
`192.168.207.66` (NCZ 26.5-r79-take78-Reinhardt-Magnetar, Ubuntu 26.04 Resolute
Raccoon derivative).

**Severity legend:** P0 ship-blocker · P1 must-have for next image · P2 known but acceptable
**Status legend:** ✅ fixed in tree · 🛠 in progress · ⏳ scoped, not started · 📋 docs-only

---

## P0 #1 — Lockout-recovery: telnetd absent, ssh key wiped (✅ FIXED — `afbfaee`)

**Problem:** Fresh install ships with **no telnetd** (CLAUDE.md rule 9 violation)
and no STUDIO ssh key in `mini@authorized_keys`. When sshd misbehaves the box is
unreachable.

**Root causes:**

1. r78 commit `e9c2534` removed `inetutils-telnetd` + `openbsd-inetd` from
   `pkgsel` because the offline cdrom mirror lacked them → red-screen at install.
2. `post-install/36-telnetd.sh` silently skipped on apt failure.
3. `/etc/apt/sources.list` shipped only `cdrom://nclawzero` — no internet archive
   source, so apt could never fetch the packages after install either.

**Fix (already in r75-review HEAD):**

- New `post-install/21-internet-apt.sh` writes
  `/etc/apt/sources.list.d/ubuntu-archive.list` pointing at `ports.ubuntu.com`
  (arm64) for codename `${UBUNTU_CODENAME}` from `/etc/os-release`.
- `36-telnetd.sh` no longer treats failure as silent-OK; emits explicit recovery
  steps citing rule 9.
- Naming: `21-` < `25-cix-ppa.sh` < `36-telnetd.sh` so the archive source is in
  place when later hooks run.

**Remaining work for next image:**

- [ ] Bake STUDIO + magnetar ssh keys into the rootfs via cloud-init seed or
      `nclawzero-ssh-keys` recipe. Today `09-diag-account.sh` creates the
      `magnetar/REDACTED-CREDENTIAL` user but no fleet pubkeys are pre-authorized,
      forcing a `sshpass mini/mini` bootstrap on every install.
- [ ] Verify telnetd persists across reboot on the next reflash test (.66 was
      validated via manual sshpass-driven install, not from-fresh-iso path).

---

## P0 #2 — Sky1 NPU: kernel driver does not bind on 7.0.9-cix-sky1-next (⏳)

**Problem:** `armchina_npu` kernel module loads but probe fails with:

```
armchina CIXH4000:00: AIPU KMD (v1.0.0) probe start...
armchina CIXH4000:00: unidentified hardware version number: 5
armchina CIXH4000:00: aipu real probe failed, ret: -22
sky1_npu_probe: NPU core num is 3
sky1_npu_probe: failed to find NPU core device CRE0/CRE1/CRE2
```

The in-tree driver's hw_version allowlist is `{1, 2, 3}`; the silicon on the
Reinhardt-Magnetar build reports `5`. No `/dev/zhouyi*`, `/dev/cix-noe*`, or
`/dev/aipu*` chardevs are created. Userspace `libnoe.so` loads fine via ctypes
but has no device to open.

**Root causes:**

1. `armchina_npu.ko` shipped in `/lib/modules/7.0.9-cix-sky1-next/kernel/drivers/misc/armchina-npu/`
   is the in-tree version from the kernel source tree; it predates hw_version=5.
2. `post-install/80-npu.sh` is supposed to deploy FyrbyAdditive's prebuilt
   driver (per `25-cix-ppa.sh:197-202` task #87) — verify this actually fires
   on the new kernel and that the prebuilt knows about hw_version=5.
3. ACPI CRE0/CRE1/CRE2 core devices not enumerated → driver gives up before any
   inference can happen.

**Fix paths (decide):**

- [ ] **Path A:** Bump `armchina_npu` source allowlist to accept `hw_version=5`,
      rebuild the DKMS/prebuilt module, ship in next image. Requires upstream
      patch or a local patch carried by `meta-base/recipes-kernel`.
- [ ] **Path B:** Investigate why ACPI tables don't bind CRE0/1/2 — possible
      DSDT/SSDT issue or driver lookup bug (`failed to find NPU core device`).
      Compare DSDT dumps between this take and an earlier known-good install.
- [ ] **Path C:** If Sky1 production silicon truly reports `5` and the driver
      can't support it yet, document NPU as **unavailable** on this kernel and
      gate `25-cix-ppa.sh`'s `cix-noe-umd` install on driver-bound check so
      operators don't get a half-stack.

**Diagnostics to capture next install:**

```bash
sudo cat /sys/firmware/acpi/tables/DSDT | iasl -d -      # decompile
sudo cat /sys/firmware/acpi/tables/SSDT* | iasl -d -
sudo dmesg | grep -iE 'armchina|aipu|zhouyi|CIXH4000|CRE[0-9]'
sudo modinfo armchina_npu | grep -E 'version|filename|alias'
```

---

## P0 #3 — cix-noe-umd postinst trips on Python 3.14 (✅ workaround in `25-cix-ppa.sh`, 🛠 needs reinforcement)

**Problem:** Resolute ships Python 3.14.4. `cix-noe-umd` 4.0.0's postinst pip-
installs `libnoe-3.1.0-*manylinux*.whl` which declares `<3.14,>=3.10`. Install
half-completes (iU state); subsequent `apt` calls wedge.

**Existing recovery:** `post-install/25-cix-ppa.sh:121-185` detects iF/iU and
patches the postinst to comment the `pip install libnoe` line (libnoe.so is
already on disk from the deb's data tar — only the duplicate pip install
fails). Also fixes a `#!/bin/sh` → `#!/bin/bash` shebang for `[[ ]]` syntax.

**Issue observed on .66 this session:** The recovery did NOT fire during the
real install. cix-noe-umd was absent at first inspection (NOE_STATE=""), then
re-attempting `apt-get install` post-fix landed it in iU again. Suspected
cause: `apt-get update` failed during install because internet was down
(cdrom-only sources before the `afbfaee` fix), so cix-noe-umd was never tried
in the first place; absent → no recovery branch fires.

**Fix for next image:**

- [ ] After `21-internet-apt.sh` lands, re-run `25-cix-ppa.sh`'s install on
      first-boot if `cix-noe-umd` is absent OR in iU/iF. Wire this as a
      systemd oneshot `nclawzero-cix-runtime-fixup.service` triggered by
      `multi-user.target` with `ConditionPathExists=!/var/lib/nclawzero/cix-runtime.ok`.
- [ ] Drop the in-postinst pip install entirely by patching the deb in
      `assets/cix-ppa/` if we mirror it locally — cleanest fix.
- [ ] Bug-report upstream CIX: libnoe wheel must support Py3.14 to track
      modern Ubuntu.

---

## P1 #4 — GPU userspace empty out of box (📋 documented, partial fix this session)

**Problem:** Mali-G720-Immortalis under `panthor` driver loads correctly + DP
display link trains, but the installed system has **zero Mesa / Vulkan / VA-API
userspace**, no `glxinfo` / `vulkaninfo` / `vainfo`, and no display server.
Operator can't render anything; not even a headless `glmark2-es2` benchmark
runs.

**Root cause:** `pkgsel` ships a "Thin" mirror without graphics userspace, and
no post-install hook fetches it. The existing `post-install/15-mesa-sky1-pin.sh`
*pins* Sky1-blessed versions but doesn't *install* the underlying packages.

**Fix (recommended for next image):**

- [ ] New `post-install/16-gpu-userspace.sh` apt-installs:
      ```
      mesa-utils libgl1-mesa-dri libegl1 libegl-mesa0
      mesa-vulkan-drivers vulkan-tools
      vainfo mesa-va-drivers
      glmark2 glmark2-es2
      ```
      Runs AFTER `21-internet-apt.sh` (rename to `26-gpu-userspace.sh` to
      respect alphanumeric order). Validated as installable on .66 this
      session — Mesa 26.0.3, Vulkan 1.4.341, vainfo 2.22, glmark2 2023.01.

- [ ] **Vulkan driver mismatch:** stock `mesa-vulkan-drivers` ships
      `vulkan-asahi` ICD (Apple Silicon Mali-G13 reverse-engineering) which
      tries to bind `/dev/dri/renderD128` and fails with
      `VK_ERROR_INCOMPATIBLE_DRIVER`. Sky1's Mali-G720 needs `panvk`
      (still experimental upstream as of Mesa 26.0). Either:
      - Carry a `panvk` build via `cix-installer/assets/` and pin via
        `15-mesa-sky1-pin.sh`.
      - Suppress the Asahi ICD via
        `/etc/vulkan/icd.d/asahi_icd.aarch64.json` removal so userspace
        falls back to swiftshader/llvmpipe without confusing error.

- [ ] **Display server:** no session manager starts. Decide whether next image
      includes GNOME/KDE/labwc as a default or stays headless. Today the box
      console-boots despite DP being plugged in.

---

## P1 #5 — apt update spams cdrom errors on every run (📋)

**Problem:** Every `apt-get update` on the installed system emits:

```
E: Failed to fetch cdrom://nclawzero cixmini resolute - Thin arm64 Binary 1/...
E: Some index files failed to download. They have been ignored, or old ones used instead.
```

because the cdrom isn't present on the running system. Operators learn to
ignore the errors, which masks real failures.

**Fix:**

- [ ] `21-internet-apt.sh` should comment-out the `deb cdrom://` line in
      `/etc/apt/sources.list.d/cixmini-cdrom.list` (or move it to
      `cixmini-cdrom.list.disabled`) once the internet source is in place.
      The cdrom contents are already on disk after install; the source entry
      serves no purpose post-boot.

---

## P1 #6 — MNEMOS embedding stack incomplete (📋, surfaced 2026-05-20)

**Problem:** cixmini is the strategic target for federated MNEMOS embedding
nodes per `fleet-roles-canonical-2026-05-06.md`. Today's smoke test on .66:

| Component | State |
|---|---|
| MNEMOS federation network path (write+search via PYTHIA REST) | ✅ PASS |
| `/opt/cix/npu_embed_v2.py` (NPU ctypes wrapper) | ✅ shipped |
| `/usr/share/cix/lib/libnoe.so` v3.1.0 + static `.a` | ✅ shipped |
| `/usr/share/cix/pypi/libnoe-*.whl` (Python bindings) | ✅ staged, ❌ not installed |
| `/opt/ncz/embed-venv/` (Python 3.14 venv) | ✅ created, but empty (no pip, no deps) |
| `transformers`, `numpy`, `sentence_transformers` Python packages | ❌ not installed |
| `.cixmodel` / `.aipu` NPU-compiled embedding model (e.g. MiniLM-L6-v2 for Sky1 NoE) | ❌ ABSENT from installer payload |
| `/dev/aipu*` device node | ❌ blocked by P0 #2 (driver probe fail) |
| `/home/mini/embed-bench/inproc_bench_v2.py` + `bge-small-zh-v1.5-q8_0.gguf` (CPU baseline) | ✅ staged, ❌ `llama_cpp` Python pkg not installed |

**Cause:** No post-install hook populates `/opt/ncz/embed-venv/` with the
runtime deps. Even the staged libnoe wheel is unused.

**Fix for next image (updated 2026-05-20 — Path 3 ONNX unblock):**

Operator handoff 2026-05-20 (MNEMOS `mem_1779334429091_4260f2`):
ship the **embedkit `cix-npu-onnx` adapter with `bge-small-zh-v1.5`
ONNX from HuggingFace** instead of the compass `.cixmodel` AOT
path. Same Zhouyi V3 silicon, no AOT compile through Compass NN
needed. Path 3 unblocks the userspace + model-format layer entirely.

- [ ] New `post-install/27-cix-runtime.sh` after `21-internet-apt.sh`
      + the NPU userspace install. Does:
      ```
      python3 -m venv --system-site-packages /opt/ncz/embed-venv
      /opt/ncz/embed-venv/bin/pip install --break-system-packages \
          /usr/share/cix/pypi/libnoe-*.whl \
          embedkit                          # provides cix-npu-onnx adapter
          numpy onnxruntime                 # ONNX inference runtime
          huggingface-hub                   # for bge-small-zh fetch
      ```
      Stage the heavy deps as offline wheels under `assets/embed-wheels/`
      so net-down installs still complete.
- [ ] Pull `bge-small-zh-v1.5` ONNX from HuggingFace into
      `/opt/ncz/embed-models/bge-small-zh-v1.5/` — either bake-time
      pull during image build (~100 MB) or first-boot
      `huggingface-cli download BAAI/bge-small-zh-v1.5 --include "*.onnx"`.
- [ ] Wire `/etc/nclawzero/embed.env` so MNEMOS clients on cixmini auto-
      route to `localhost:<port>` for embedding generation instead of
      round-tripping to PYTHIA. Embedkit `cix-npu-onnx` adapter is the
      backend; bge-small-zh-v1.5 ONNX is the model path.
- [ ] **SUPERSEDED:** earlier expectation of a `.cixmodel` /
      Compass-NN-compiled payload. The ONNX path eliminates that
      requirement entirely. Do not chase the AOT compile pipeline.

**Caveat still relevant:** even with Path 3 userspace running, the
kernel driver must bind first (P0 #2 hw_version=5 mismatch). The
ONNX adapter calls into libnoe via `/dev/aipu0` which the in-tree
`armchina_npu` driver does not yet create on 7.0.9-cix-sky1-next.

**Out-of-scope for cix-installer (PYTHIA-side fleet issue):**

- `/pantheon/v1/embeddings` returns 403 with the fleet MNEMOS bearer token
  but accepts the same token at `/v1/memories/*`. Separate scope needed at
  PYTHIA pantheon proxy. Not a cixmini bug — note for `mnemos-claude` /
  next PYTHIA work.

**Test marker:** `mem_1779327100546_354016` was written from .66 during
smoke (delete after verification or keep as federation-health canary).

---

## P2 #7 — VA-API: no hardware video decode (📋 known)

**Problem:** `vainfo` opens `/usr/lib/aarch64-linux-gnu/dri/linlondp_drv_video.so`
(the display controller driver, not a real VA-API HW backend) and
`vaInitialize()` returns -1.

**Cause:** Sky1's VPU is separate hardware from the GPU; its userspace would
come from `cix-vpu-driver-dkms` (which `25-cix-ppa.sh:197-247` skips until
kernel-headers asset ships — task #66).

**Fix:** task #66 (ship kernel-headers asset) unlocks VPU DKMS build →
unlocks VA-API HW backend. Not a blocker for next image; document expected
status as "GPU runs, VPU pending kernel-headers asset".

---

## P2 #8 — fail2ban + recidive locks ssh on first password failure (📋)

**Problem:** Default sshd config has fail2ban + recidive jail enabled with low
threshold. One `Permission denied (publickey)` retry triggers a long ban; key
spray from a fresh client trips it immediately.

Confirmed today: tried `ssh -i ~/.ssh/id_ed25519 mini@.66` after fresh boot,
ssh tried multiple keys before getting to password, hit
`Too many authentication failures` + ban.

**Fix:**

- [ ] Raise fail2ban threshold for LAN clients (192.168.207.0/24) so key
      spray during legitimate first-contact doesn't trip recidive.
- [ ] Document the `-o IdentitiesOnly=yes -i <single key>` workaround in
      the install README.

---

## Process Improvements

- [ ] **Validation runbook:** Today's NPU/GPU/MNEMOS validation should become
      `post-install/99-diagnostics.sh` outputs feeding a single
      `nclawzero-acceptance-report.txt` consumed by the next image's CI gate.
- [ ] **First-boot oneshot:** Several recoveries (cix-noe-umd retry,
      ssh-key-bake, mesa pin) could converge into one
      `nclawzero-firstboot-fixup.service` that runs once + writes a stamp file.
- [ ] **Internal apt mirror:** Per fleet handoff, ARGOS already serves
      `http://192.168.207.22:8081/apt` as the internal nclawzero apt repo.
      The next ISO could pin THAT as the primary source instead of
      ports.ubuntu.com, getting both the Ubuntu base packages AND nclawzero
      debs from one mirror.

---

## Cross-references

- `~/.claude/rules/handoff-arm64-ic-engine-build-2026-05-06.md` — prior .66
  install pattern + gotchas (--userns=keep-id, fail2ban+recidive).
- `~/.claude/rules/handoff-to-ncz-claude-ic-engine-quadlet-2026-05-06.md` —
  ic-engine quadlet integration for 4th-agent (relevant once NPU userspace
  works → MNEMOS embedding on cixmini becomes viable).
- `~/.claude/rules/fleet-roles-canonical-2026-05-06.md` — cixmini as the new
  fleet baseline; depends on NPU + GPU userspace landing reliably.
- `mem_1779320845082_dfa764` — separate RiskyEats adversarial review (parallel
  work today, also led to a CLAUDE.md rule-9-style audit pattern).

---

*Living doc — update inline as next-image work lands.*

*Written 2026-05-20 from STUDIO session, post-sky1-next kernel boot on .66.*
