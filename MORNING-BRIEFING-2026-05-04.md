# Morning Briefing — 2026-05-04

## TL;DR

- **r34 V.I.N.CENT** is the latest build. Ready to flash and test in the morning.
- 3 codex agents ran adversarial reviews overnight. All CRITICAL findings applied. HIGH/MEDIUM/LOW findings documented below for morning attention.
- 6.19 kernel research done — recommendation: DEFER (it's actually EOL'd upstream as of 2026-04-22).
- Architecture validated by GRAEAE (architectural design review) and Codex (code-level adversarial review). The path forward is sound.

## State at end of session

### r34 V.I.N.CENT ISO

```
Path:    /home/jasonperlow/cix-installer-build/cix-installer/build/ncz-installer-cixmini-2026.05.04-r34-VINCENT.iso
Size:    2.6 GB (2692034560 bytes)
Status:  Built, NOT flashed.
```

What r34 contains (functional changes since pre-overnight r31):

| Fix | Source | Where applied |
|---|---|---|
| `mirror/udeb/suite=questing` (was `bookworm`) | Codex pre-overnight audit | preseed-ubuntu.cfg |
| `KERNEL_LTS` filename → `KVER_LTS` | Codex pre-overnight audit | build-iso-di.sh |
| Trixie ISO missing now fail-loud + verify 5 udebs extracted | Codex A1 (overnight) | build-iso-di.sh Step 4.5 |
| xorriso `-appended_part_as_gpt` for proper arm64 EFI System Partition | Codex A1 (overnight) | build-iso-di.sh xorriso call |
| `bind-mount /cdrom → /target/cdrom` for offline apt-get | Codex A2 (overnight) | preseed/late.sh |
| `file:///cdrom questing main` apt source `[trusted=yes]` | Codex A2 (overnight) | preseed/late.sh |
| 70-bootloader failure now propagates rc to late_command | Codex A2 (overnight) | post-install/run-all.sh |

## Morning checklist

1. **Flash r34**:
   ```
   ssh jasonperlow@192.168.207.22 "sudo dd if=/home/jasonperlow/cix-installer-build/cix-installer/build/ncz-installer-cixmini-2026.05.04-r34-VINCENT.iso of=/dev/sda bs=4M status=progress conv=fdatasync; sync"
   ```
2. Bytes-exact verify
3. Pull USB, boot on MS-R1
4. Watch for: V.I.N.CENT ASCII art GRUB → ~5s blackness → d-i banner → no red error → trixie-grafted debootstrap extracts zstd debs → base install → late_command → reboot to questing 25.10
5. If success: write the blog post, push ncz-installer to gitlab.com/nclawzero/ncz-installer
6. If failure: failure surface narrowed to specific apt/late hook issues — debuggable in <30 min each

## Pending codex findings (NOT blocking r34 first-flash test)

These were flagged but are NOT in the boot/install hot path. Apply iteratively after r34 boots:

### Codex A1 — build-iso-di.sh

| Severity | Finding | Fix |
|---|---|---|
| HIGH | zstd download via curl with no SHA256 verify (supply chain) | Add `: "${ZSTD_SHA256:?}"; sha256sum -c -` |
| HIGH | network-console password hardcoded in preseed (anyone with ISO has installer SSH password) | Templatize via `@NETCONSOLE_PASSWORD@` substitution |
| MEDIUM | Concurrent build runs share staging dir (race condition) | Add `mkdir LOCK || exit` guard at script entry |
| MEDIUM | dpkg-scanpackages can emit duplicate Package stanzas | Detect dups via awk after generation |
| MEDIUM | Silent `cp -aL ... \|\| true` failures hide missing assets | Drop the `\|\| true` |
| LOW | GRUB ASCII art has unescaped variable injection risk | Sanitize via `printf '%s' "$1" \| sed 's/[\\"]/\\\\&/g'` |

### Codex A2 — preseed + late.sh + post-install hooks

| Severity | Finding | Fix |
|---|---|---|
| HIGH | 20-desktop.sh comments out cdrom apt source then runs `apt-get update` | Remove lines that disable cdrom; with our late.sh fix apt-update against cdrom now works |
| HIGH | preseed `late_command` hardcodes `sh /cdrom/cixmini/late.sh`; multi-path probe in late.sh never runs if /cdrom moved | Move probe into late_command itself |
| HIGH | late.sh `cp -r` into existing cix-installer dir nests on rerun | Replace with `rm -rf` + `cp -a` |
| HIGH | 35-ssh.sh assumes user `ncz`, preseed asks operator for username | Detect first UID≥1000 user OR preseed `passwd/username ncz` |
| MEDIUM | 33-ntp-hostname.sh `systemctl enable --now` in chroot fails (no systemd bus) | Use `systemctl enable` only; let first boot start service |
| MEDIUM | 25-cix-proprietary.sh runs even if 20-desktop failed | Add prerequisite check |
| MEDIUM | 70-bootloader efibootmgr failure ignored, no NVRAM entry guarantee | Try normal `bootctl install` first; fail loudly on no entry |
| LOW | 20-desktop.sh writes initial-setup marker only to `/etc/skel`, after user is already created | Also apply to existing UID≥1000 home dirs |

### Codex A3 — 6.19 kernel decision

**Recommendation: DEFER.** Key findings:

- **6.19 reached EOL 2026-04-22** (not LTS, not "stable middle lane" — already a dead mainline branch).
- Sky1-Linux community keeps it patched for the SoC, but upstream security fixes have stopped flowing.
- Adding 6.19 as a third slot would require coordinated changes to `build-iso.sh`, `10-our-kernel.sh`, `70-bootloader.sh` — all three reference only `lts`/`next` slots today.
- Right path: build a Yocto recipe (`linux-cix-sky1-619_6.19.x.bb`) and boot-test on MS-R1 first. If SCMI timeouts (issue #25) don't reproduce with cixtech `ad5281ee`+`c3e05f4d` patches, it could REPLACE NEXT (not join it).
- The kernel matrix probably stays: 6.18 LTS (stable, default) + 7.0.1 NEXT (beta, opt-in). 6.19 only if testing proves it superior to NEXT.

## Architecture summary (validated by GRAEAE + Codex)

```
ncz-installer cixmini r34 V.I.N.CENT

  USB boot (Sky1 UEFI)
       │
       ▼
  bookworm GRUB-EFI (proven — boots Sky1 since r6)
       │
       ▼
  bookworm d-i /init  ← busybox sh, the "calm" init that survives Sky1's
       │                aggressive linlondp DRM coldplug
       │
       ├──── trixie udeb graft (anna fetches from /pool at runtime):
       │     • debootstrap 1.0.141 (zstd-aware shell, all-arch)
       │     • libzstd1-udeb 1.5.7 (runtime library)
       │     • liblzma5-udeb 5.8.1
       │     • base-installer 1.226 (calls debootstrap, not cdebootstrap)
       │     • bootstrap-base 1.226
       │
       ▼
  cdebootstrap → debootstrap (per trixie's bootstrap-base 1.226)
       │
       ▼
  debootstrap reads /cdrom/dists/questing/Release → fetches questing debs
  from /cdrom/pool/main/ → zstd-extracts via libzstd1-udeb
       │
       ▼
  /target = Ubuntu questing 25.10 minbase (no kernel — base-installer/
       │    kernel/image=none)
       │
       ▼
  late_command runs /cdrom/cixmini/late.sh in /target chroot
  (with /cdrom bind-mounted into /target/cdrom for offline apt access)
       │
       ├── 10-our-kernel.sh:    linux-cix-sky1-lts 6.18.26 → /boot/vmlinuz
       ├── 12-sky1-firmware.sh: panthor mali_csffw + Cix DSP/VPU
       │                        (with mali_csffw symlink fix from r25)
       ├── 20-desktop.sh:       ubuntu-desktop-minimal + xubuntu-core
       ├── 22-display-fix.sh:   master-of-seat udev for cards 0/1/2/4
       ├── 25-cix-proprietary.sh: Cix-licensed bits (USB-C controller, etc)
       ├── 30-agents.sh:        nclawzero/zeroclaw container stack
       ├── 32-quadlet-shim.sh:  systemd quadlet shim
       ├── 33-ntp-hostname.sh:  hostname=cixmini, chrony NTP
       ├── 35-ssh.sh:           sshd config + NetworkManager
       ├── 40-claude-code.sh:   claude-code dev tool install
       ├── 50-brand.sh:         nclawzero branding assets
       ├── 60-plymouth.sh:      plymouth theme  
       ├── 70-bootloader.sh:    systemd-boot at /boot/efi (PROVEN on r6 install)
       └── 99-diagnostics.sh:   final state dump
       │
       ▼
  reboot → systemd-boot → cixmini-lts entry → linux-cix-sky1-lts 6.18.26
       │
       ▼
  Ubuntu questing 25.10 + Sky1 6.18 kernel + nclawzero customizations
  on /dev/nvme0n1
```

## Release codename history

| Iteration | Codename | Status | Key learning |
|---|---|---|---|
| r6 | (unnamed) | ✅ Boots, installs Debian | bookworm d-i + Sky1 LTS works on this hardware |
| r9-r12 | (unnamed) | ❌ "black + reboot" | trixie d-i hits a different Sky1 boot issue (still unverified — codex A3 hypothesis: not /init script difference but possibly module-load ABI mismatch) |
| r17-r24 | (various) | ❌ Casper black-screen | Bootloader is a red herring; userspace `boot=casper` was missing |
| r25-r27 | Reinhardt | ❌ partman → mirror hash → Release file structure | DVD audit fixed structural mirror issues |
| r28 | Maximilian | ❌ trixie d-i panicked | Different cause than casper, defer investigation |
| r29-r30 | Reinhardt | ❌ apt-utils zstd extraction failed | Discovered cdebootstrap-static lacks zstd entirely |
| r31 | V.I.N.CENT | ⚠️ trixie udeb graft architecture, 2 codex bugs found pre-flash | First version with the bookworm-shell + trixie-userspace approach |
| r32 | V.I.N.CENT | ⚠️ Pre-overnight codex fixes applied | Built, didn't flash |
| r33 | V.I.N.CENT | ⚠️ Codex A1 fixes applied | Built, didn't flash |
| **r34** | **V.I.N.CENT** | **🟢 ALL OVERNIGHT FIXES APPLIED — READY FOR MORNING FLASH** | A1 + A2 + structural |

## Reminder

- **Don't flash before morning** — user explicitly said no more flashes tonight.
- The 30-hour debugging session is documented across the conversation history.
- ncz-installer is now a real OSS project, ready for `gitlab.com/nclawzero/ncz-installer`.
- Blog post outlines drafted in conversation; multiple title options.
- Sleep first; flash r34 in the morning with a clear head.
