# NCZ 26.6 take1 "Reinhardt-Magnetar" — Triple-Boot Recovery-Hardened Netinstall ISO

**Release date:** 2026-06-01
**Codename:** Reinhardt (Desktop) + Magnetar (Server) on a single bootable netinstall ISO
**Kernels shipped:** linux-cix-sky1-lts **6.18** (DEFAULT, all working drivers) + linux-cix-sky1-next **7.1** ([BETA], A/B 3-try rollback)
**Userspace:** Ubuntu 25.10 questing arm64, debootstrap'd from `ports.ubuntu.com/ubuntu-ports` at install time
**Hardware:** Cix Sky1 / CP8180 (Minisforum MS-R1; Radxa Orion O6 — community verification in progress)
**Wired Ethernet required at install** — `d-i netcfg` does not handle wireless cleanly in this build path.

---

## Headline — the brick is gone, and you can always get a console

This is the **recovery hardening** release. It exists because the MS-R1 (.66) bricked with a black screen and no network after a boot entry carried `iommu.passthrough=1`. 26.6-take1 makes a fresh install **observable and recoverable from day zero**:

1. **`iommu.passthrough=1` is never written.** It is not present anywhere in the build tree, so no generated boot entry can carry it.
2. **Three boot entries, every install** — a stable default, a clearly-labelled beta, and a *fully safe* rescue:
   - **LTS 6.18 — DEFAULT** (`sort-key 1-lts`). All working drivers. This is what boots if you do nothing.
   - **NEXT 7.1 — [BETA]** (`sort-key 2-next`). A/B boot-counted (3 tries, auto-rolls-back to LTS on repeated failure). Labelled `*** [BETA — UNSTABLE SCMI] ***` because the 7.1 SCMI transport still times out on current MS-R1 firmware (see Known Issues).
   - **SAFE rescue** (`rescue.target`). No NPU, no GPU, no VPU — `armchina_npu,panthor,mali,bifrost,cix_vpu,linlon_vpu` blacklisted *in addition to* the standard `typec_rts5453,rts5453`. Boots to a rescue shell with networking + telnet.
3. **Maximum telemetry, on by default** — telnet backup console on :23, all syslog forwarded to the fleet loghost (ARGOS .22), persistent journald, and a real serial getty on ttyAMA2. A box that wedges mid-boot still streams its logs to a host that stays up.

## Why LTS 6.18 is the default (not 7.1)

The previous netinstall (r78) shipped 7.0.3 NEXT-only with **no LTS sibling** — a single point of failure. 26.6-take1 reverses the default: **LTS 6.18 boots first** because it has all working drivers and is stable, and **7.1 ships as an explicit, boot-counted [BETA]**. The 7.1 SCMI transport still does not negotiate cleanly on MS-R1 firmware (FAST channel 0 never returns a TX-ack IRQ; the firmware wants the CIXHA001:06 doorbell channel 8), so 7.1 cannot honestly claim "all working drivers" yet. Until that lands, 7.1 is opt-in and self-rolls-back.

This honors the standing operator rule: **there must always be a rescue kernel choice, and we never remove or disable a boot entry — only add.**

## What's new in 26.6-take1

### 1. Recovery-hardened bootloader (`post-install/70-bootloader.sh`)

- **Default flipped to LTS 6.18.** `loader.conf` default + runtime `DEFAULT_ENTRY` selection both prefer `cixmini-lts`; `cixmini-next*` is only chosen as default if LTS is somehow unavailable.
- **Sort-keys reordered** so LTS sits at the top of the menu: LTS `1-lts`, NEXT `2-next`.
- **7.1 NEXT is honestly labelled** `*** [BETA — UNSTABLE SCMI] nclawzero kernel <kver> [NEXT 7.1, A/B only] ***` and retains the existing `+3-0` boot-count A/B rollback (3 tries → `.failed` rename → fall back to LTS by sort-key, via `systemd-bless-boot` ESP-filename rename so it works under `efi=noruntime`).
- **Rescue entry hardened to truly safe.** A `RESCUE_EXTRA_BLACKLIST` of `armchina_npu,panthor,mali,bifrost,cix_vpu,linlon_vpu` is **merged into** the single `module_blacklist=` token (via `sed`, not appended as a second token — the kernel keeps only the *last* `module_blacklist=` it parses). `arm-smmu-v3.disable_bypass=0` is kept; **`nomodeset` is deliberately NOT used** — on Sky1 the only console is firmware efifb/simplefb and `nomodeset` can black-screen it.

### 2. Maximum telemetry + lockout-prevention console (`post-install/36-telemetry.sh`, NEW)

Variant-agnostic Phase-2 hook (fail-tolerant; one missing package can't abort the install):

- **telnetd on TCP :23** — `inetutils-telnetd` behind `openbsd-inetd`, with a busybox-`telnetd.socket` systemd fallback. `ttyAMA2` + `pts/0..9` added to `/etc/securetty` so root stays reachable as a true lockout fallback (LAN-only; CLAUDE.md directive 9).
- **rsyslog → loghost 192.168.207.22 (ARGOS)** — `/etc/rsyslog.d/90-loghost.conf` forwards `*.*` over UDP/514, disk-queued (`LinkedList`, `ActionResumeRetryCount -1`, save-on-shutdown) so a brief loghost outage doesn't drop local logging.
- **Persistent journald** — `Storage=persistent`, `ForwardToSyslog=yes`, `SystemMaxUse=512M`, so logs survive the reboot and feed rsyslog for forwarding.
- **Serial getty on ttyAMA2 @115200** — a real login over the serial console that matches the `console=ttyAMA2,115200` boot cmdline.

### 3. No `iommu.passthrough=1` — the brick parameter is absent

Confirmed by tree-wide grep: the parameter exists in **no** cmdline base, hook, or generated entry. The protective params remain on every entry: `module_blacklist=typec_rts5453,rts5453` (MS-R1 IRQ 151 wedge), `clk_ignore_unused`, `keep_bootcon`, `console=tty0 console=ttyAMA2,115200`, `arm-smmu-v3.disable_bypass=0`, `panic=30`.

## Unified GRUB chooser (unchanged from r78)

The installer ISO still boots to a Desktop / Server / Rescue chooser; the selection writes `ncz_variant=desktop|server` → `BUILD_VARIANT` sidecar, consumed by `48-magnetar-variant.sh` on first boot. Both variants ship both kernels and all three post-install boot entries.

## Known issues

- **NEXT 7.1 SCMI timeout on MS-R1.** The 7.1 SCMI mailbox transport times out against current MS-R1 firmware. 7.1 is therefore [BETA], opt-in, and boot-counted; the system self-recovers to LTS 6.18 after 3 failed 7.1 boots. Kernel-side investigation (DB doorbell channel 8 / CIXHA001:06) is tracked separately.
- **Wired Ethernet required at install** (carried over).

## Cross-references

- `nclawzero/cix-installer` — this repo, the installer build pipeline.
- Prior: `RELEASE-NOTES-26.5-r78-Reinhardt-Magnetar.md` (unified chooser, embedkit).

---

*26.6-take1 is the recovery-hardening response to the .66 brick: LTS-default, honest-BETA 7.1, a truly-safe rescue, telnet+remote-syslog telemetry on by default, and a build tree that cannot emit `iommu.passthrough=1`.*
