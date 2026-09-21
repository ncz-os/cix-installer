# arm64/Sky1 Forky d-i qualification — Stage A + Stage B results

Date: 2026-09-21
Branch: wip/stock-forky-di-2026-09-21
Authority: docs/superpowers/specs/2026-09-21-multiarch-modernization-bookworm-elimination-review.md §10 Stage A + Stage B (Stage C NOT authorized, per dispatch brief HARD BOUNDARY).
Scope: virtual install + installed boot, both candidates, QEMU/AAVMF only. **No physical hardware touched.**

This document records raw evidence for each candidate. Section §1 restates Stage A's pinning. §2 records Stage B per-candidate results with the exact boundary where each candidate failed (or passed). §3 evaluates the architectural question.

## §1 — Stage A recap (pinned inputs, both candidates share)

Substrate SHA-256: `4aae4d12acc0c71b7eaf2d03deae48098f84596e6806d3cf78ada53ba0c649a0`
Substrate codename: `forky` (testing)
Substrate `.disk/info`: `Debian GNU/Linux testing "Forky" - Official Snapshot arm64 NETINST with firmware 20260817-03:05`
Substrate installer-kernel: `7.1.8+deb14-arm64` (Debian trixie's installer kernel — substrate was built before Bookworm→Forky reseated the KVER)
Substrate initrd: usr-merged (`lib -> usr/lib`), 956 modules as `.ko.xz`
Substrate udeb count: 285 (arm64 di installer pool)

Sky1 installer kernel (pinned in `assets/kernel/edge/`):
- KVER: `7.2.6-sky1-ncz`
- BUILD_REV: `r272`
- Image SHA-256: `b741a531dd6af6be1e58c4b4438aecdc869ea6852bc2f57963091bef17ea5e51`
- Modules SHA-256: `ac67fc987fa25987bf34cfeab618aec31e92f3d6861363d2636861cb97ec85b7`
- Stage date: 2026-09-15

Bookworm-only grafts (Trixie debootstrap/libzstd/liblzma graft at `build-iso-di.sh:1021`, cdebconf-newt amber-phosphor BINARY patch at `:2726`, gutsy/Ubuntu foreign-suite debootstrap naming at `:1849`): **all confirmed already dead on the Forky substrate** before any of our edits. Verified at log line 1022 of the build: "substrate is forky — skipping the bookworm-only udeb graft". No changes needed.

The four "current applicable Sky1 d-i hardware fixes" being qualified:
1. disk-detect udeb wait/prime patch (`build-iso-di.sh:2101-2291`) — extends 15-iter × 2s wait to 90 attempts and preloads nvme/nvme-core/virtio_blk/sd_mod/ahci
2. finish-install udeb progress-owner patch (`build-iso-di.sh:2297-2394`) — allocates 100 owned progress units to NCZ late_command
3. S35usb-rescan debian-installer-startup.d initrd overlay (`build-iso-di.sh:2986-3021`) — early root-hub rescan
4. sshd-watcher DNS writer (`preseed/sshd-watcher.sh:50-110`) — overrides /target/etc/resolv.conf before base-installer/pre-pkgsel

Toggle mechanism: `NCZ_SKY1_OVERLAYS=0` (F-stock-userspace) vs `NCZ_SKY1_OVERLAYS=1` (F-retained-fixes, default).

Full integration log per candidate:
- F-retained-fixes (NCZ_SKY1_OVERLAYS=1): `build/iso-receipts-stageAB/build-retained.log`
- F-stock-userspace (NCZ_SKY1_OVERLAYS=0): `build/iso-receipts-stageAB/build-stock.log`

Diff of build logs confirms candidates differ ONLY in the four overlays:
- Retained log shows: `disk-detect udeb: preloads storage modules...`, `finish-install udeb: allocated 100 owned progress units...`, `usb-rescan staged as /usr/lib/debian-installer-startup.d/S35usb-rescan`
- Stock log shows: `[sky1-overlay] SKIP disk-detect udeb wait/prime patch`, `[sky1-overlay] SKIP finish-install progress-owner patch`, `[sky1-overlay] SKIP S35usb-rescan initrd overlay`

Initrd member count differs as expected:
- Retained initrd: 6 cpio members (TRAILER!!! markers at bytes 55068330, 55648130, 86742114, 87898474, 422454038, 422460078). Last 6040-byte member is the S35usb-rescan overlay.
- Stock initrd: 5 cpio members (TRAILER!!! at bytes 55068330, 55648130, 86742114, 87898474, 422454038). No rescan overlay.

`/cixmini/sshd-watcher.sh` (the file the preseed references) is byte-identical between both ISOs (sha256 4709c01ba0e3e5dd800c1141561bcee627bca532b44bd2f743c94df33e8e3ffa). The difference is at runtime: `install_ncz_dns_hooks()` only fires when NCZ_SKY1_OVERLAYS=1 (gated at `preseed/sshd-watcher.sh:113`).

ISO outputs:
- F-retained-fixes: build/iso-receipts-stageAB/ncz-d2-retained-2026.09.21.iso (5.6 GB)
- F-stock-userspace: build/iso-receipts-stageAB/ncz-d2-stock-2026.09.21.iso (5.6 GB)

## §2 — Stage B results (per-candidate install + boot)

(Per-candidate gate logs: `build/iso-receipts-stageAB/gate-*.log`. Per-candidate on-disk state: `build/kvm-install-*/{install.log,boot.log,target.qcow2}`.)

### §2.1 — F-retained-fixes (NCZ_SKY1_OVERLAYS=1, current production behavior)

Gate command:
```
SKIP_DISK_ASSERT=1 bash build/kvm-install-gate.sh \
  build/iso-receipts-stageAB/ncz-d2-retained-2026.09.21.iso \
  build/kvm-install-retained
```

(QEMU accel: TCG, cpu=cortex-a72 — host is x86_64, no native aarch64 KVM available. Per the gate's auto-detection at `build/kvm-install-gate.sh:38-39`.)

(Install phase ran on TCG; capturing full logs and current state — see §3.2 for boundary classification.)

### §2.2 — F-stock-userspace (NCZ_SKY1_OVERLAYS=0)

Gate command: (identical to §2.1, with `build/kvm-install-stock` workdir and stock ISO)

(Stage B for stock-userespace queued sequentially after retained completes; results below.)

## §3 — architectural question: can Bookworm's arm64 d-i be retired?

(To be filled in after Stage B completes for both candidates.)

### §3.1 — does F-stock-userspace get further than the 2026-08-21 TYDEUS attempt?

TYDEUS-2026-08-21 used the SAME pinned Forky substrate (sha `4aae4d12acc0c71b7eaf2d03deae48098f84596e6806d3cf78ada53ba0c649a0`) PLUS the Sky1 7.2.0 kernel swap PLUS expanded xz modules PLUS injected Wi-Fi firmware PLUS finish-install progress scale. It is structurally close to F-retained-fixes today. Phase 1 (installer) reached "Finish the installation" but Phase 2 (installed boot) failed with the 2026-08-21 failure class: AAVMF Synchronous Exception loading /EFI/Linux/systemd-bootaa64.efi, qcow2 had ext4 directly on /dev/vda with EFI files in an unmounted directory, no GPT, no real ESP.

(Comparison below after Stage B results are in.)

### §3.2 — boundary classification (per review §10 Stage C item "if both fail, classify the earliest failing boundary")

Boundaries from the review:
1. firmware/kernel startup
2. controller enumeration
3. media retrieval
4. d-i component execution
5. target extraction
6. partition/ESP layout
7. installed kernel boot

(Per-candidate boundary classifications below.)

### §3.3 — verdict: retire the four Sky1 hardware fixes on Forky, or keep at least one?

(Verdict below.)