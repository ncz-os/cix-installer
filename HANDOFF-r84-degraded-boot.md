# HANDOFF — cixmini (.66) r84 Magnetar: degraded boot + installer source bugs

**Date:** 2026-06-16  •  **From:** Studio Claude (jperlow-mlt)  •  **To:** opencode
**Repo:** `~/cix-installer` (this tree)  •  **Branch:** `recovery/26.6-take1`  •  **HEAD:** `93b8d2f`
**Target:** cixmini `.66` (Cix Sky1 / Minisforum MS-R1), variant = **server / Magnetar**, build `26.6.r84-Magnetar`.

---

## TL;DR — current live problem (what to work on)

`.66` did a **full r84 install** to NVMe and boots, but comes up **degraded**:
- **Old/stock login banner** (not the Magnetar branding).
- **tty1 login broken** ("original banner login behavior where terminal 1 could not be logged into").
- **zeroclaw quadlets won't load** (same as an earlier install).

**Operator's diagnosis (trust this):** *"something was left in the old config in the R84 sources — this is the old config on the new install."* i.e. stale config from a previous build is bundled into the r84 payload and getting installed. **The task is to find that stale config in THIS repo and fix it.** Do NOT keep treating it as a fresh-install runtime issue.

`.66` is currently **unreachable over the network** (no ping, ssh+telnet closed) — likely the RTL8125 `r8125` NIC module didn't get set up (see `33-network.sh` + MNEMOS `reference_msr1_hardware`). So debugging is console-only OR via the source tree.

---

## Where I was when stopped

Searching the r84 source tree for the stale "old config." Findings so far:
- Banner/branding logic: `post-install/50-brand.sh` (+ `assets/branding/`).
- Quadlet templates bundled: `assets/agent-stack/{zeroclaw,openclaw,hermes,nemoclaw}.container` → staged to `/usr/share/ncz/quadlets/`, active copy to `/etc/containers/systemd/` by `post-install/30-agents.sh`.
- **Next step I did not finish:** read `assets/agent-stack/zeroclaw.container`, `post-install/50-brand.sh` + its `assets/branding/` payload, and any committed `/etc/issue`/getty/console config, to find what's stale. Also diff the bundled config vs what the running-system symptoms imply. `git log -p` on those asset files will show if an old version is committed.

**Suspect chain to chase:**
1. **Banner** — `50-brand.sh` writes `/etc/issue`/motd/branding from a stale asset → old banner.
2. **tty1 login** — a hook (likely `50-brand.sh` or `20-desktop.sh`/console setup) ships an old getty / `/etc/issue` / autologin / PAM config that breaks tty1 login. This reproduces a historically-fixed bug, so a stale file regressed it.
3. **zeroclaw quadlet won't load** — `assets/agent-stack/zeroclaw.container` is an old/broken version, OR `30-agents.sh` activates a stale quadlet. The container-load service also blocks boot (see bug #2 below).

---

## Access paths to .66

- **No network right now.** Console (HDMI) only until NIC is fixed.
- When the d-i **installer** is running: network-console `installer@.66` pw `Gumbo@Kona1b`, driven via `tools/di-diag.sh <host> '<cmd>'` (uses `expect`; sshd-watcher also patches `root@` pubkey).
- Diag account on the **installed** system (created in Phase 0, no network needed): **`magnetar` / `Gumbo@Kona1b`**, NOPASSWD sudo (`post-install/09-diag-account.sh`). Try this on any VT.
- Installed operator account: `mini` (pw set at install).
- **Rescue boot:** systemd-boot menu → **"SAFE rescue (cixmini)"** → root sulogin shell (`rescue.target`, accelerators blacklisted, does NOT start `multi-user.target` services → bypasses the container stall).

---

## What's ALREADY fixed on .66 (do not redo)

The original install **failed at late.sh**. Root cause: **ESP (`/boot/efi`, 512 MiB) was 100% full**, so `70-bootloader.sh`'s `bootctl install` died with "No space left," `run-all.sh` EXIT trap returned non-zero, and late.sh's `set -e` aborted → d-i "failed preseeded command."

I did an **in-place rescue** (via the d-i ramdisk): freed the ESP (removed stale `*cix-sky1-lts*`/`goldenrescue` kernels + 2 `kernel-install` machine-id dirs), wrote `/etc/kernel/install.conf` = `layout=other`, re-ran `dpkg --configure -a` + `70-bootloader.sh` in chroot. Result: `BOOTLOADER_RC=0`, ESP now **59% used / 209M free**, three valid entries (`cixmini-stable` default / `cixmini-edge+3-0` BETA / `cixmini-rescue`), `EFI/BOOT/BOOTAA64.EFI` fallback in place. **The box is bootable.** (Note: `efibootmgr` can't write NVRAM on MS-R1 — "EFI variables not supported" — so it relies on the removable-media fallback path; this is expected.)

EFI cleanup the operator asked for is **NOT done** (box went unreachable): still-present stale items to remove when a shell is available — `cixmini-clean.conf.disabled`, `cixmini-v3.conf.disabled`, `EFI/BOOT/BOOTAA64-refind.EFI`, `EFI/BOOT/BOOTAA64-systemd-backup.EFI`, stale Orion-O6 DTBs + `dtb/`. **Keep** the three active `cixmini-*.conf`, their kernels/initrds, `loader.conf`, `EFI/systemd/`, live `BOOTAA64.EFI`, and the active `cixmini-rescue.conf` (rescue-kernel rule).

---

## Installer SOURCE bugs to fix for r85 (in this repo)

### Bug 1 — ESP overflow (root cause of the install failure)
`post-install/70-bootloader.sh`:
- The ESP **wipe** (`rm -f /boot/efi/vmlinuz-*` etc., ~line 138–144) runs **AFTER** `bootctl install` (~line 87). On a re-install onto a populated ESP it dies before cleaning. **Move the wipe to BEFORE `bootctl install`** (after the `/boot/efi` mount validation, ~after line 80), and **expand it** to also `rm -f /boot/efi/initrd.img-*` and `rm -rf` the 32-hex `kernel-install` machine-id dirs.
- The `systemd-boot` deb postinst's `kernel-install` writes a **second** full copy of every kernel into `/boot/efi/<machine-id>/<kver>/` (Type #2 BLS) on top of our manual Type #1 staging → doubles ESP usage. **Write `/etc/kernel/install.conf` with `layout=other` BEFORE `apt-get install systemd-boot`** (~line 56) so the deb postinst doesn't duplicate onto the ESP.
- (Optional) ESP recipe is 512 MiB on disk though `preseed/preseed.cfg` recipe says `1024 1024 1024` — investigate the discrepancy; dedup makes 512M fit, but bump for headroom.

### Bug 2 — container-load boot stall (likely part of today's degraded boot)
`post-install/30-agents.sh` creates `/etc/systemd/system/nclawzero-load-agent-images.service`:
```
Wants/After=network-online.target ; Before=zeroclaw.service
TimeoutStartSec=3600 ; WantedBy=multi-user.target   # oneshot podman pull from ghcr.io
```
It's a `multi-user.target` sync point doing `podman pull ghcr.io/zeroclaw-labs/...`. With **no internet route** (this box) it hangs up to **1 hour** → "loading containers" stall. **Fix:** decouple from boot (post-boot `.timer`/`OnBootSec`, not a `multi-user.target` blocker), bound `TimeoutStartSec` to ~180, and **preload the zeroclaw image into podman storage at install time from a bundled tarball** so offline boxes don't pull. This also relates to "zeroclaw quadlets won't load."

### Bug 3 — late.sh masks the real failure
`preseed/late.sh` line ~234: `in-target run-all.sh` runs under `set -e`, so a non-zero return aborts before `RET=$?` (line 235) and the `"in-target run-all.sh exited: $RET"` diagnostic never prints. Wrap that call in `set +e`/`if` so failures surface cleanly.

### Bug 4 (the operator's actual ask) — stale "old config" baked into r84 payload
Find and fix whatever old config is bundled that produces: old banner + broken tty1 login + non-loading zeroclaw quadlets. Start at `post-install/50-brand.sh` + `assets/branding/`, `assets/agent-stack/zeroclaw.container`, and any committed getty/`/etc/issue`/console config. Use `git log -p -- <file>` to spot a regressed/old version. **This is the priority for the live box.**

Also note: the install ran with **broken apt** (`E: Unable to locate package linux-firmware` / "Custom package install failed" in the late log) — confirm whether the box had a working mirror/DNS during install; if it installed offline, branding/console/network packages never landed, which compounds the degraded-boot symptoms.

---

## Conventions / guardrails
- nclawzero = personal OSS → commit as **`Jason Perlow <jperlow@gmail.com>`**, never `@nvidia.com`. No AI-attribution footer on zeroclaw-labs.
- **Codex `adversarial-review` gate before any push** (PRIMARY DIRECTIVE #4); Codex fixes its own findings.
- Rescue-kernel rule is **inviolable**: never delete/rename/disable a rescue boot entry; only add or `.disabled`.
- `set -e` is on in `late.sh`/`run-all` Phase 1 — be careful editing.
- Build/bake host for the ISO: STUDIO `~/` (r84 ISO `ncz-installer-cixmini-26.6-r84.iso` lives there). Don't bake from a dirty tree.

## MNEMOS handoff already stored
`mem_1781589545188_b7d87d` (the r84 validation handoff) — note its claim that "preseed/late.sh is fixed / 70-bootloader execution restored" was **WRONG**; that's why the install still failed. Correct the record when done.
