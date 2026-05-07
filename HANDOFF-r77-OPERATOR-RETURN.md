# r77 Reinhardt-Magnetar — operator handoff for bake + ship

**Status when this was written:** code lands done, bake queued for operator's manual trigger, PR drafts staged. Operator was AFK; the autonomous run prepared everything that could be done without supervising a 30-60 min image bake.

## What's done

- ✅ `build/build-iso-di.sh` — GRUB now offers Desktop + Server + Rescue chooser (commit `cfe7832`).
- ✅ `preseed/late.sh` — captures `ncz_variant=desktop|server` from kernel cmdline, writes BUILD_VARIANT sidecar (commit `cfe7832`).
- ✅ `post-install/47-embedkit.sh` — installs `mnemos-embedkit` + libnoe + llama-cpp-python + stages `bge-small-zh-v1.5` GGUF + .cix to /opt/ncz/models/ (commit `cfd93e4`).
- ✅ `assets/models/bge-small-zh-v1.5-q8_0.gguf` (25 MB, sha256 `5a88d266...`) — bundled in the repo for ISO bake (commit `cfd93e4`).
- ✅ `RELEASE-NOTES-26.5-r77-Reinhardt-Magnetar.md` — release notes drafted.
- ✅ Repo lint clean (commit `8dcaf38` — shellcheck-warning sweep, real `56-icon-theme.sh` bug fix).
- ✅ Branch `r75-review` pushed to gitlab.com/nclawzero/cix-installer + ARGONAS bare.
- ✅ ARGOS at .22 has `r75-review` checked out and ready to bake.

## What needs operator trigger

### 1. Bake the ISO on ARGOS

The bake takes 30-60 min and needs supervision (xorriso has occasionally crashed on disk pressure). Run from the ARGOS terminal:

```bash
ssh jasonperlow@192.168.207.22
cd /home/jasonperlow/cix-installer-build/cix-installer
git pull origin r75-review

# Bake the unified Reinhardt-Magnetar ISO
# (the GRUB chooser handles desktop vs server at install time;
#  --variant here is the bake-time default for legacy kernel-cmdline-less boots)
nohup bash build/build-iso-di.sh \
    --bookworm-iso /home/jasonperlow/cix-installer-build/cix-installer/downloads/debian-12.13.0-arm64-netinst.iso \
    --root /home/jasonperlow/cix-installer-build/cix-installer \
    --version 26.5-r77-Reinhardt-Magnetar \
    --variant desktop \
    --output /home/jasonperlow/cix-installer-build/cix-installer/build/ncz-installer-cixmini-26.5-r77-Reinhardt-Magnetar.iso \
    > build/build-r77-take1.log 2>&1 &

tail -f build/build-r77-take1.log
```

Output ISO will be ~9 GB at `build/ncz-installer-cixmini-26.5-r77-Reinhardt-Magnetar.iso`.

### 2. Smoke-test the ISO

Before publishing — boot the ISO in QEMU OR flash to a stick and boot on .66:

```bash
# QEMU smoke (ARGOS):
bash build/qemu-test.sh /home/jasonperlow/cix-installer-build/cix-installer/build/ncz-installer-cixmini-26.5-r77-Reinhardt-Magnetar.iso

# Or flash to USB on TYPHON and boot .66 (operator path):
ssh jasonperlow@192.168.207.61 \
    'sudo dd if=/path/to/ncz-installer-cixmini-26.5-r77-Reinhardt-Magnetar.iso \
              of=/dev/sda bs=4M status=progress conv=fsync'
```

### 3. Tag + push the release

```bash
cd /Users/jperlow/cix-installer    # or ARGOS clone
git tag -a v26.5-r77-Reinhardt-Magnetar -m "NCZ 26.5 r77 Reinhardt-Magnetar — unified Desktop/Server chooser + embedkit"
git push origin v26.5-r77-Reinhardt-Magnetar
```

### 4. Upload to GitLab Releases

```bash
# Compute SHA256
sha256sum build/ncz-installer-cixmini-26.5-r77-Reinhardt-Magnetar.iso > build/ncz-installer-cixmini-26.5-r77-Reinhardt-Magnetar.iso.sha256

# Create the release with attached ISO + sha256 + release notes
glab release create v26.5-r77-Reinhardt-Magnetar \
    -R nclawzero/cix-installer \
    --name "NCZ 26.5 r77 Reinhardt-Magnetar" \
    --notes-file RELEASE-NOTES-26.5-r77-Reinhardt-Magnetar.md \
    "build/ncz-installer-cixmini-26.5-r77-Reinhardt-Magnetar.iso#NCZ 26.5 r77 Reinhardt-Magnetar Cix arm64 ISO" \
    "build/ncz-installer-cixmini-26.5-r77-Reinhardt-Magnetar.iso.sha256#SHA256 sums"
```

### 5. Fire PRs (operator authorizes each)

The PR drafts live in `pr-drafts/` (created next). Authorize each individually:

#### PR 1 — `mnemos-os/mnemos-embedkit` repo standup announce

Already pushed initial commit + staged `docs/CODEX-ADAPTER-HANDOFF.md`. No PR is needed for this repo since you have direct push access to `mnemos-os`. The kit lives at `https://github.com/mnemos-os/mnemos-embedkit`.

After Codex completes its adapter implementation, fire **PR 1a** as a single feature PR for the priority-1-4 adapters (cpu-llamacpp, cix-npu, nvidia-cuda, apple-mlx). PR draft text is in `pr-drafts/01-mnemos-embedkit-adapters.md`.

#### PR 2 — `mnemos-os/mnemos` integration

Migrate MNEMOS's embedding helper to `embedkit.Engine(...)`. PR draft text in `pr-drafts/02-mnemos-embedkit-integration.md`. **Don't fire until the embedkit adapters land.**

#### PR 3 — `nclawzero/distro` r77 release announcement

Update `nclawzero/distro/README.md` to point at v26.5-r77 GitLab Release. PR draft in `pr-drafts/03-nclawzero-distro-r77-pointer.md`.

#### PR 4 — Email to Yocto crew (Kate Stewart, Richard Purdie)

Send the existing `~/email-yocto-crew.md` updated with the r77 release link + the embedkit story. **Do NOT auto-send;** the email content is at `pr-drafts/04-yocto-crew-email-r77.md`.

#### PR 5 — Sky1-Linux community announcement

Cross-link the kit + bench numbers to the Sky1-Linux GitHub Discussions / Discord. PR draft in `pr-drafts/05-sky1-linux-announcement.md`.

## Pre-bake checklist (verify before triggering bake)

- [ ] ARGOS disk space: `df -h /home/jasonperlow` shows >50 GB free (need ~25 GB for staging + output).
- [ ] `r75-review` HEAD on ARGOS == latest local HEAD: `git log --oneline -1` matches `cfe7832`.
- [ ] `assets/models/bge-small-zh-v1.5-q8_0.gguf` exists (25 MB).
- [ ] `assets/models/MODELS-README.md` exists.
- [ ] `post-install/47-embedkit.sh` executable + lint-clean.
- [ ] Existing bookworm ISO at `downloads/debian-12.13.0-arm64-netinst.iso`.
- [ ] (Optional) `assets/models/bge-small-zh-v1.5_256.cix` if available — if missing, 47-embedkit.sh logs WARN and skips.

## Risk notes for operator

1. **First bake of unified chooser GRUB** — the new GRUB cfg has 3 entries instead of 2. Boot test BOTH Desktop and Server entries before publishing. Defer ship if either fails to boot.
2. **`56-icon-theme.sh` bug fix changes runtime behavior.** The black-hole trash icon will install for the first time since r74. Watch for any icon-cache or dconf weirdness on first-boot Reinhardt; if reported, revert to r74 path.
3. **47-embedkit.sh smoke logs to /var/log/cix-install/47-embedkit-smoke.log** — check this on first boot. If embedkit imports fail, the appliance still installs cleanly (hook is non-fatal); operator can fix on the running system.
4. **No pre-compiled .cix bundled in this build** — task #99 (pull from cixtech/ai_model_hub_25_Q3 LFS) is still pending. The NPU adapter falls back to "model not found" until the operator manually copies `bge-small-zh-v1.5_256.cix` to `/opt/ncz/models/`. Document this caveat in the GitLab Release notes.
