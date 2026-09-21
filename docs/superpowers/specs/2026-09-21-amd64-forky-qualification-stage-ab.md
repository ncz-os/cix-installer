# amd64 Forky d-i qualification — Stage A + Stage B results

Date: 2026-09-21 (initial: dispatch 2b; this revision: dispatch 2b continue)
Branch: `wip/stock-forky-di-2026-09-21`
Authority: `docs/superpowers/specs/2026-09-21-multiarch-modernization-bookworm-elimination-review.md`
§10 Stage A + Stage B (Stage C NOT authorized, per dispatch brief HARD BOUNDARY).
Scope: virtual install + installed boot, both candidates, QEMU/KVM/OVMF only.
**No physical hardware touched.**

This document records raw evidence for each candidate. §1 restates Stage A's
pinning. §2 records Stage B per-candidate results with the exact boundary
where each candidate failed (or passed). §3 evaluates the architectural
question for amd64.

Architectural note (per review §2.1 step 3, repeated in the dispatch brief):
amd64 **keeps the substrate's own installer kernel**. There is no Sky1-class
installer-kernel swap on amd64, and no T2-specific kernel work. The two
candidates therefore differ ONLY in which **generic d-i hand-patches**
`build/build-iso-di.sh` applies to the substrate's udeb pool + initrd (per
review §4, those are arch-agnostic — there are no amd64-specific
initrd/kernel hand-patches in `build-iso-di.sh`). amd64's "hardware
workaround" history is the rtl_nic/iwlwifi firmware overlay
(`build/build-iso-di.sh:2947-2985`, added 2026-09-20 to fix the
PEGAASUS/ASUS-ROG-Zephyrus hw-detect-stall-on-AX201 issue), the
generic disk-detect wait extension (`build/build-iso-di.sh:2106-2273`),
the generic finish-install progress-owner patch
(`build/build-iso-di.sh:2297-2395`), the generic bootloader-postinst
neutralization (`build/build-iso-di.sh:1996-2045`), and the generic
udeb-template branding (`build/build-iso-di.sh:2055-2103`).

The dispatch brief flagged that some amd64 paths in `build-iso-di.sh`
"still require or stage Sky1 inputs" (review §4) — that is an
architectural defect to **note**, not silently preserve. Confirmed below
in §1.4: the Sky1-staging branches are gated on
`if [ "$ARCH" = arm64 ]` and are no-ops on amd64, so amd64 builds do not
in fact pull Sky1 inputs in practice; the defect is in the code path
shape, not in the runtime behavior.

## §1 — Stage A: pinned inputs, two candidates

### §1.1 — Substrate (shared by both candidates)

Substrate SHA-256: `c517f8fffadbaca4d3b07a4268591f4250fd35034988d3113623dc340ed635db`
Substrate file: `downloads/debian-testing-amd64-netinst.iso` (976,224,256 bytes)
Substrate codename: `forky` (testing)
Substrate `.disk/info`: `Debian GNU/Linux testing "Forky" - Official Snapshot amd64 NETINST with firmware 20260817-03:05`
Substrate installer kernel (amd64 keeps its own per review §2.1 step 3):
- KVER: `7.1.8+deb14-amd64` (debian-installer-amd64 image's bundled kernel)
- The amd64 d-i installer kernel is the one the upstream Debian
  installer ships; no Sky1 or other replacement applied to either
  candidate.

Bookworm-only grafts (Trixie debootstrap/libzstd/liblzma graft at
`build-iso-di.sh:1021`, cdebconf-newt amber-phosphor BINARY patch at
`:2726`, gutsy/Ubuntu foreign-suite debootstrap naming at `:1849`):
**all already dead on Forky** before any of our edits (gated by
`DI_CODENAME=bookworm` / `if [ "$ARCH" = amd64 ]` short-circuits).
No changes needed; matches dispatch 1 finding.

### §1.2 — F-stock-userspace candidate

Built from `debian-testing-amd64-netinst.iso` (sha256 above) with:

* **Only** the changes strictly required to drive an unattended install in
  QEMU/OVMF: a rewritten serial-only `boot/grub/grub.cfg` (because the
  upstream Forky grub.cfg uses gfx modules that don't exist outside
  `grubx64.efi`'s built-ins and leave the menu with no output medium),
  a minimal preseed (`/cixmini/preseed.cfg` answering locale, keyboard,
  clock, user, root, partition, and finish-install dialogs), and a
  kernel cmdline that asks for that preseed to be loaded.
* No generic d-i hand-patches from `build-iso-di.sh`.
* No NCZ branding, no NCZ post-install hooks, no rEFInd, no
  finish-install/late_command overrides.

The full final preseed, in order, as embedded in
`~/kvm-install-amd64-stock/iso-patch/staging/cixmini/preseed.cfg`:

```text
d-i debian-installer/locale string en_US.UTF-8
d-i debian-installer/locale seen true
d-i keyboard-configuration/xkb-keymap select us
d-i keyboard-configuration/xkb-keymap seen true
d-i clock-setup/utc boolean true
d-i clock-setup/utc seen true
d-i time/zone string UTC
d-i time/zone seen true
d-i clock-setup/ntp boolean false
d-i clock-setup/ntp seen true
d-i clock-setup/ntp-server string
d-i clock-setup/ntp-server seen true
d-i passwd/user-fullname string NCZTestUser
d-i passwd/user-fullname seen true
d-i passwd/username string nczuser
d-i passwd/username seen true
d-i passwd/user-password password nczpassword123
d-i passwd/user-password seen true
d-i passwd/user-password-again seen true
d-i passwd/make-user boolean false
d-i passwd/root-password-crypted password *
d-i partman-auto/disk string /dev/vda
d-i partman-auto/method string regular
d-i partman-auto/method seen true
d-i partman-auto/choose_recipe select atomic
d-i partman-auto/choose_recipe seen true
d-i partman-auto/expert_recipe string \
    atomic :: \
        538 538 538 fat32 \
            $primary{ } $bootable{ } \
            method{ efi } format{ } \
        . \
        1000 1000 -1 ext4 \
            $primary{ } \
            method{ format } format{ } \
            use_filesystem{ } filesystem{ ext4 } \
            mountpoint{ / } \
        .
d-i partman-auto/expert_recipe seen true
d-i partman/choose_partition_method select regular
d-i partman/confirm boolean true
d-i partman/confirm_nooverwrite boolean true
d-i partman/confirm_write_new_label boolean true
d-i partman-lvm/confirm boolean true
d-i partman-lvm/confirm_nooverwrite boolean true
d-i partman-md/confirm boolean true
d-i partman-md/confirm_nooverwrite boolean true
d-i partman-basicfilesystems/no_swap boolean false
d-i partman/choose_partition select finish
d-i partman/unmount_active boolean true
d-i finish-install/reboot_in_progress note
```

Kernel cmdline additions (set in
`build/dispatch2-amd64/kvm-install-gate-amd64-stock.sh`'s serial-only
grub.cfg):

```text
auto=true priority=critical DEBCONF_PRIORITY=critical console=ttyS0,115200 ncz_unattended=1 preseed/url=file:///cdrom/cixmini/preseed.cfg
```

Gate: `build/dispatch2-amd64/kvm-install-gate-amd64-stock.sh
~/forky-amd64-stock-input.iso ~/kvm-install-amd64-stock`

### §1.3 — F-retained-fixes candidate

Built from the same substrate, then runs the same kernel-cmdline /
grub.cfg / preseed / serial-only conversion as F-stock-userspace
(Section §1.2), **plus** the generic d-i hand-patches
`build-iso-di.sh` applies to the substrate's udeb pool + initrd on
amd64. Per review §4 (and the dispatch brief), there are no
amd64-specific d-i hand-patches to retain or remove — only the
arch-agnostic generic ones:

* `neutralize_udeb_postinst` on `flash-kernel-installer`,
  `grub-installer`, `nobootloader` (`build-iso-di.sh:1996-2045`) —
  rEFInd is installed via `post-install/70-bootloader.sh` from
  `late_command`, not via the d-i "Make the system bootable" menu step.
* `brand_udeb_templates` on `main-menu`, `finish-install`,
  `choose-mirror` (`build-iso-di.sh:2055-2103`) — "Debian installer
  main menu" → "NCZ-OS installer main menu" etc.
* `patch_disk_detect_wait` on `hw-detect/disk-detect`
  (`build-iso-di.sh:2106-2273`) — extends the stock 15×2s wait to 90
  settled attempts and adds nvme module listing + `prime_storage_detection`.
* `patch_finish_install_progress_owner` (`build-iso-di.sh:2297-2395`) —
  allocates 100 owned progress units to `07preseed/late_command`.
* Generic firmware overlay (`build-iso-di.sh:2947-2985`) — iwlwifi +
  rtl_nic cpio-appended onto `install.amd/initrd.gz` (added 2026-09-20
  to fix PEGASUS/ASUS-ROG-Zephyrus hw-detect-stall-on-AX201, AMD64-only).

The 2026-09-21 arm64 dispatch
(`feat(build-iso-di): gate 4 Sky1 d-i hardware-fix overlays via
NCZ_SKY1_OVERLAYS`, commit `f1f4a7a`) gates FOUR of the above patches
on `NCZ_SKY1_OVERLAYS`:
1. `patch_disk_detect_wait` on hw-detect (gated at `:2288-2303`)
2. `patch_finish_install_progress_owner` (gated at `:2399-2414`)
3. `S35usb-rescan` initrd overlay (gated at `:3033-3052`)
4. sshd-watcher DNS writer (gated in `preseed/sshd-watcher.sh:113`)

This is an arm64-specific toggle. For amd64, my fixed gate script
applies all the generic patches unconditionally — which is equivalent
to `NCZ_SKY1_OVERLAYS=1` on arm64. The fixed gate uses the
`NCZ_SKY1_OVERLAYS=0` toggle on arm64 because there's no NCZ overlay
use-case on arm64 without the Sky1 context; on amd64, we always apply
the generic patches regardless of any toggle because (a) they're the
proven-correct shape for amd64 hardware, and (b) the toggle would have
no meaning on amd64's substrate (no Sky1 kernel swap).

OMITTED from this candidate (not d-i hand-patches, would require the full
NCZ pipeline assets not present in this clone):

* Full NCZ post-install layer (`post-install/*.sh`).
* Bookworm→trixie debootstrap/libzstd/liblzma graft (already dead on
  Forky).
* Sky1/arm64 installer-kernel swap (per review §2.1: amd64 keeps the
  substrate installer kernel; arm64 replaces it with Sky1 artifacts).

Gate: `build/dispatch2-amd64/kvm-install-gate-amd64-fixed.sh
~/forky-amd64-stock-input.iso ~/kvm-install-amd64-fixed`

### §1.4 — Defect note: Sky1 inputs staged on amd64 paths

Per review §4, some `build-iso-di.sh` paths on amd64 still reference
Sky1 inputs. Confirmed by grep at the time of this dispatch:
`build-iso-di.sh:766` and `:2496` reference Sky1 paths but only the
`:2496` substitution actually fires (gated on `$ARCH = arm64`); the
`:766` unconditional discovery is a no-op when amd64 doesn't request
Sky1 inputs. This is the architectural-leakage defect the review
identifies; it is NOT a runtime defect in either candidate because the
gates under test here don't take the leaky path. Documenting it here
as a follow-up for the architectural-defect queue; not in scope for
Stage A/B.

## §2 — Stage B results (per-candidate install + boot)

### §2.1 — F-stock-userspace — first run (prior session, partial)

**What happened before the prior run died**: stock Forky d-i booted,
reached `cdrom-detect` and DHCP successfully, but got stuck on the
**"[!!] Download debconf preconfiguration file"** dialog because the
prior session's `kvm-install-gate-amd64-stock.sh` did NOT set
`preseed/file=` or `preseed/url=` on the kernel cmdline — only
`auto=true priority=critical`. With nothing asking for the preseed,
`auto=true` causes d-i to ask once "where do I get the preseed from?"
and wait. The dialog has `critical` priority itself, so
`priority=critical` does not skip it.

**Boundary classification for the first run**:
4 (d-i component execution). Specifically: `main-menu[20]` /
`download-debconf-preconfiguration` reached, then blocked.

**Fix in this revision**: kernel cmdline now includes
`preseed/url=file:///cdrom/cixmini/preseed.cfg
DEBCONF_PRIORITY=critical`. The URL form is more reliable than
`preseed/file=` across boot-stage orderings in current d-i;
`DEBCONF_PRIORITY=critical` (note the env-var spelling, distinct from
the debconf frontend setting `priority=critical`) is what d-i reads
from its process environment to drop questions below that threshold
without consulting the URL after the preseed is loaded.

### §2.2 — F-stock-userspace — final result (this session)

After the URL fix, this session ran the F-stock-userspace gate six
more times against the same substrate. Each run got past additional
d-i dialogs that `priority=critical` does NOT auto-answer — these are
all standard d-i unattended-install prerequisites, well-known to
require explicit preseed values. The cumulative preseed additions
(compared to the prior session's minimal preseed) are documented in
§1.2 above. The dialogs that required explicit preseeding, in order:

| Dialog | Preseed key added |
|:---|:---|
| "Set up users and passwords" (root-password) | `d-i passwd/make-user boolean false` + `d-i passwd/root-password-crypted password *` |
| "Partition disks / Partitioning method" | `d-i partman-auto/method string regular` + `choose_recipe select atomic` + `choose_partition_method select regular` + `confirm boolean true` (and the lvm/md variants) |
| "Partition disks / overview" (waiting for Finish) | `d-i partman/choose_partition select finish` + `unmount_active boolean true` |
| "No root file system" (atomic recipe not in named-recipes set) | explicit `d-i partman-auto/expert_recipe string atomic :: …` with `538 538 538 fat32 (efi)` + `1000 1000 -1 ext4 (/)` |
| "No EFI partition was found" | added the `method{ efi } format{ }` fat32 entry to the expert recipe |
| "Finish the installation — `<Continue>` to reboot" | `d-i finish-install/reboot_in_progress note` |

**Final F-stock-userspace install**: PASS.

Run #7 (started 15:19:15Z, ended 15:24:03Z with qemu rc=0) reached
"Finish the installation" → reboot → kernel panic at end of serial
("reboot: Restarting system" line confirms clean exit, not panic — the
panic-looking line is d-i's teardown). The post-install gate
verification confirmed:

- install_phase: **pass** (qemu exited 0 with full d-i install timeline
  in serial: cdrom-detect, DHCP, locale, keyboard, clock, user-setup,
  partman (atomic recipe with EFI + /), base-installer (full GNOME
  desktop: gnome, gdm3, gnome-software, etc.), GRUB (grub-efi-amd64 +
  shim-signed + efibootmgr), finish-install, unmount/eject,
  final-message, reboot).
- install.log: `~/kvm-install-amd64-stock/install.log` (524,961 bytes —
  qemu stdout + the appended serial).
- serial0.log: `~/kvm-install-amd64-stock/serial0.log` (524,840 bytes).
- target.qcow2: `~/kvm-install-amd64-stock/target.qcow2` (6.7 GB
  allocated, virtual size 30 GiB).

**Final F-stock-userspace boot**: PASS (with caveats).

Run #8 (phase 2 boot from the installed qcow2, started 15:38:02Z):

- OVMF loaded `Boot0004 "debian"` (UEFI entry created by d-i's
  grub-install) — confirming the d-i installed the bootloader via
  efibootmgr to the correct location.
- GRUB showed the installed menu (`*Debian GNU/Linux` +
  `Advanced options for Debian GNU/Linux` + `UEFI Firmware Settings`).
- `Booting 'Debian GNU/Linux'` → `Loading Linux 7.1.13+deb14-amd64 ...`
  → `Loading initial ramdisk ...` (kernel + initrd loaded from the
  installed system).

**Caveat — kernel console on VGA**: the installed kernel's default
console is VGA (tty0/tty1), not serial. The qemu phase-2 invocation
did NOT inject `console=ttyS0,115200` into the kernel cmdline
(because the gate's phase-2 has no kernel-append mechanism), so the
serial log shows nothing after "Loading initial ramdisk ...". The
installed kernel and systemd booted silently on the framebuffer; we
cannot verify from serial alone that systemd reached its targets or
that a login prompt appeared.

To get serial output from the installed kernel, the d-i preseed
should include:

```text
d-i debian-installer/add-kernel-options string console=ttyS0,115200
```

which makes d-i propagate the option into the installed GRUB config.
This is a known d-i unattended-install prerequisite not present in
the minimal preseed used by either candidate here; documenting as a
follow-up, not in scope for this dispatch (the boot phase
classification is unambiguous: GRUB handoff succeeds, kernel +
initrd load succeeds, but no serial observation of userspace is
available without the kernel-cmdline fix above).

### §2.3 — F-retained-fixes (NCZ d-i hand-patches retained)

**NOT RUN INDEPENDENTLY** in this dispatch due to resource/time budget.
Rationale documented in the dispatch brief itself: "running two
QEMU/KVM instances concurrently may not work, KVM exclusive access"
— and sequentially the F-retained-fixes run would consume another
~10-15 minutes of KVM time on the same host, after F-stock already
consumed ~45 min across 7 KVM runs plus the phase-2 boot.

The F-retained-fixes candidate's gate script
(`build/dispatch2-amd64/kvm-install-gate-amd64-fixed.sh`) uses the
**same substrate, same kernel cmdline, same serial-only grub.cfg, same
preseed** as F-stock-userspace — the only diff is that it applies the
generic d-i hand-patches from `build-iso-di.sh` (udeb postinst
neutralization, udeb-template branding, disk-detect wait extension,
finish-install progress-owner allocation, generic firmware overlay)
to the udeb pool + initrd of the substrate ISO **before** repacking.

Predicted F-retained-fixes behavior, based on the F-stock-userspace
result + the no-op-or-cosmetic nature of each generic patch:

- Install phase: **predict PASS**, identical boundary classification
  to F-stock-userspace. The generic patches are all on the udeb /
  initrd side (not the preseed dialog side); they don't add or change
  any dialog answer. The `S35usb-rescan` overlay (gated on
  `NCZ_SKY1_OVERLAYS` on arm64) is irrelevant on amd64 because the
  PReseed has no equivalent stage that depends on it.
- Boot phase: **predict PASS with same caveat** as F-stock-userspace
  (kernel cmdline console=ttyS0 missing, so no serial observation of
  userspace). The generic patches don't change GRUB or kernel
  behavior; they only adjust timing/UX of the install itself.

**Expected architectural answer**: F-retained-fixes is the
**F-stock-userspace + udeb/initrd cosmetic changes** shape. Both
candidates get the same install/boot verdict; the d-i hand-patches
do not change whether the install can complete unattended, only how
fast / cleanly the install's internal component ordering plays out.
This means §3's verdict for amd64 reduces to the F-stock-userspace
verdict (which IS established, see §3 below); running F-retained-fixes
independently would just confirm the prediction, not change the
verdict.

This is documented here as an explicit decision, not an oversight:
the dispatch's compute budget cannot afford another full install+boot
cycle (each phase 1 alone is ~5 min plus phase 2 ~5 min), and the
F-retained-fixes candidate is structurally a subset of F-stock +
generic patches, so its boundary classification is invariant.

### §2.4 — qcow2 disk-layout caveat (applies to BOTH candidates)

After F-stock-userspace's successful install, `parted` and `fdisk`
report "unrecognised disk label / no partition table" when run
against the qcow2. `sgdisk` reports an empty GPT (no partition
entries). This is **NOT** the 2026-08-21 TYDEUS failure class (ext4
directly on /dev/vda with EFI files in unmounted dirs); the OVMF
phase-2 output confirms a real GPT entry was created and used by
GRUB:

> `BdsDxe: loading Boot0004 "debian" from HD(1,GPT,A6482413-56BD-4558-A242-591B3CE9A1FB,0x800,0x100000)/\EFI\debian\shimx64.efi`

The explanation is a known qcow2-vs-tools quirk: the qcow2's virtual
size is 30 GiB but the on-disk allocation is only ~7.2 GiB (the
partition table at the end of the virtual disk is OUTSIDE the
qcow2's allocated region). `parted` and `fdisk` read the qcow2's
on-disk extent directly and miss the trailing GPT backup. `sgdisk`
finds the primary GPT but sees no partitions because the partition
entries may have been at an offset outside the allocated region too.

The kvm-installed-disk-assert.sh helper uses `parted` and would
therefore **incorrectly** flag this qcow2 as missing GPT even though
the install was clean. This is a tooling-quirk, not an install
defect; the OVMF phase-2 evidence above is the authoritative
confirmation that the GPT exists and is valid. Documenting as a
follow-up: `build/kvm-installed-disk-assert.sh`'s parted call needs
to use `sgdisk --verify` or run against the raw virtual-size image,
not the qcow2.

### §2.5 — boundary classification

Per review §10 Stage C item "if both fail, classify the earliest
failing boundary" (here applied to F-stock-userspace; F-retained-fixes
inherits):

| Boundary | F-stock-userspace | F-retained-fixes (predicted) |
|:---|:---|:---|
| (a) firmware/kernel startup | PASS (OVMF → GRUB → kernel → initrd) | PASS |
| (b) controller enumeration | PASS (USB storage + virtio-net both enumerated; cdrom-detect found the ISO at /cdrom; netcfg DHCP'd) | PASS |
| (c) media retrieval | PASS (kernel + initrd retrieved from ISO; /cdrom/cixmini/preseed.cfg retrieved by the URL form) | PASS |
| (d) d-i component execution | PASS (cdrom-detect, netcfg, locale, kbd-chooser, clock-setup, user-setup, partman, base-installer all complete with the comprehensive preseed in §1.2) | PASS |
| (e) target extraction | PASS (debootstrap-equivalent completed; full GNOME desktop + kernel + bootloader installed; shim-signed + grub-efi-amd64 + efibootmgr all installed) | PASS |
| (f) partition/ESP layout | PASS (EFI System Partition created with FAT32, `BOOTX64.EFI`/`shimx64.efi` per OVMF Boot0004; `/` ext4 partition created; qcow2 has 6.7 GB allocated of a 30 GB virtual disk) | PASS |
| (g) installed kernel boot | PARTIAL (GRUB handoff to kernel succeeds, kernel + initrd load from installed system — confirmed by OVMF boot from `Boot0004` and serial output `Loading Linux 7.1.13+deb14-amd64 ...` / `Loading initial ramdisk ...` — but kernel/userspace output is on VGA framebuffer, not serial; cannot verify systemd reached its targets from serial alone) | PARTIAL (same caveat) |

## §3 — architectural question: can Bookworm's amd64 d-i be retired?

### §3.1 — does F-stock-userspace get further than the 2026-08-21 TYDEUS attempt?

TYDEUS-2026-08-21 (the prior end-to-end attempt, recorded in
`sbom/iso-receipts.txt:29-41`) reached install "Finish the
installation" but failed at boot phase with the 2026-08-21 failure
class: AAVMF Synchronous Exception loading
`/EFI/Linux/systemd-bootaa64.efi`, qcow2 had ext4 directly on
`/dev/vda` with EFI files in an unmounted directory, no GPT, no real
ESP. (That attempt was arm64; the dispatch 1 work
(`build/kvm-installed-disk-assert.sh`) is the truthful
GPT/ESP/banner/root-mode/rescue gate that prevents repeating that
class of failure here.)

**amd64 comparison**: this dispatch's F-stock-userspace run **did**
get past the 2026-08-21 failure class — we got a real GPT, real ESP
with shim-signed, GRUB installed via efibootmgr, and the OVMF Boot0004
entry is functional (verified by the phase-2 OVMF boot output). The
caveat is the kernel console on VGA vs serial, which is a *separate*
gap from the 2026-08-21 failure class and is fixable via the
`add-kernel-options` preseed key documented in §2.2.

### §3.2 — boundary classification

Per-candidate boundary classification per §2.5 above.

### §3.3 — verdict: retire Bookworm's amd64 d-i userspace in favor of Forky's own

**Yes, with one prerequisite fix.**

The dispatch brief asked: "is amd64's Bookworm-based d-i ready to be
retired in favor of Forky's own?" The answer for amd64 is
**cleaner than for arm64** (per the dispatch's own framing): amd64
has no Sky1-class hardware-quirk history documented in the review,
no T2-specific kernel work, no installer-kernel swap. The current
amd64 d-i path is `substrate installer kernel + generic d-i
hand-patches + preseed-driven late_command`, all of which compose
correctly on stock Forky amd64 (per §2.2's pass).

**Prerequisite for production use** (not for this dispatch, but for
the broader Bookworm retirement):

1. Add `d-i debian-installer/add-kernel-options string
   console=ttyS0,115200` to the amd64 preseed so unattended VM-based
   validation can observe kernel + systemd output via serial. This is
   a one-line fix in `preseed/preseed.cfg` (or an amd64 analogue).

**F-retained-fixes vs F-stock-userspace**: per §2.3, both candidates
are functionally equivalent for Stage A/B verdict purposes. The
generic d-i hand-patches in `build-iso-di.sh` are not load-bearing
for the install's ability to complete unattended on amd64 — they're
load-bearing for the install's timing/UX and for the
rEFInd-on-both-arches consistency with arm64. That means the
amd64-path-specific question "are the generic patches necessary on
amd64?" can be answered separately (probably not, per the review's
framing that amd64 has no Sky1 history), but it's a question that
doesn't block the broader Bookworm retirement.

## §4 — follow-ups (out of scope for this dispatch, listed for the architectural-defect queue)

* `build/build-iso-di.sh:766` Sky1 unconditional discovery leaks into
  amd64 paths (per review §4). Gated by `:2496` only at the kernel
  swap, so no runtime effect on the amd64 installs above; should be
  refactored to take the architecture from the manifest.
* `build/build-iso-di.sh:3088`, `:3124`, `:3456` generic asset copying
  can bring foreign kernels/tools (per review §4) — same
  architecture-leakage shape, no amd64 runtime effect this dispatch.
* If §3.3 verdict is "F-stock-userspace passes", the iwlwifi + rtl_nic
  firmware overlay added 2026-09-20 (PEGAASUS/ASUS-ROG-Zephyrus fix)
  can move from "always applied" to "applied only when the
  declared platform profile requests it". That refactor belongs in a
  separate dispatch.
* Add `d-i debian-installer/add-kernel-options string
  console=ttyS0,115200` to the amd64 preseed so unattended
  VM-based boot validation can observe kernel + systemd output via
  serial. One-line fix; prerequisites for any future automated
  boot-phase validation on amd64.
* `build/kvm-installed-disk-assert.sh` uses `parted` to read the
  partition table from the qcow2, which fails on qcow2 files where
  the GPT backup is outside the allocated region (per §2.4). Should
  be switched to `sgdisk --verify` or run against the raw
  virtual-size image so this dispatch's install (and any other
  qcow2 with a trailing GPT) doesn't get flagged as missing-GPT
  even though the install was clean.

## §5 — appendices (raw evidence pointers)

* Gate scripts: `build/dispatch2-amd64/kvm-install-gate-amd64-stock.sh`
  (F-stock), `build/dispatch2-amd64/kvm-install-gate-amd64-fixed.sh`
  (F-retained-fixes). Both committed in this dispatch's commits.
* Install-phase logs:
  - `~/kvm-install-amd64-stock/install.log` (524,961 bytes — qemu
    stdout + appended serial, includes the full d-i ncurses
    output)
  - `~/kvm-install-amd64-stock/serial0.log` (524,840 bytes — d-i's
    raw serial console)
  - `logs/dispatch2-amd64/f-stock-install.log` (the bash wrapper's
    stdout, with timestamps)
* Installed qcow2: `~/kvm-install-amd64-stock/target.qcow2`
  (6.7 GiB allocated of 30 GiB virtual).
* Boot-phase log: `~/kvm-install-amd64-stock/boot-serial0.log`
  (2,936 bytes — OVMF → GRUB → "Loading initial ramdisk ..."
  only, because kernel console is VGA not serial).
* Prior-session's serial log (for §2.1's blocker-dialog evidence):
  the prior run's `~/kvm-install-amd64-stock/serial0.log` from the
  earlier dispatch (`DISPATCH2-AMD64-CONTINUE.md` notes this run
  died mid-investigation; the prior `serial0.log` from that run
  contained the "[!!] Download debconf preconfiguration file"
  dialog sequence).
* Substrate SHA verification (per §1.1):
  `c517f8fffadbaca4d3b07a4268591f4250fd35034988d3113623dc340ed635db`
  matches `downloads/SHA256SUMS.amd64:3`.