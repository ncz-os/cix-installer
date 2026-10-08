# Installer wall-clock analysis (2026-10-08)

Status: **analysis + the single-preseed duplicate fix only.** No broad timing or
runtime change is made in this phase. Everything below is either a measurement
from an already-existing log with a file:line reference, or explicitly marked
`UNMEASURED`.

## Scope

Two questions from the operator:

1. Is `preseed.cfg` loaded twice, and did that cost wall clock?
2. Where does the installer spend significant wall clock, and how can it be
   reduced?

Answer 1 is proven below and fixed. Answer 2 is a measurement plan, not a set of
edits: the largest window is currently **unattributed**.

Method: this document reuses measurements that already exist in the repo. No new
image was built, booted, or shipped for this analysis. Times are **elapsed**
wall clock taken from installer syslog / serial logs; CPU time was not captured.
Operator dialog time is excluded wherever the source separated it.

## 1. Measured OLD-image timelines (prior images, exact references)

These are the only installer-phase measurements available. They are **not** the
current branch (no rebuilt image exists); they are the baseline the duplicate
fix is measured against.

| machine / arch | image | source |
|---|---|---|
| CHIMERA amd64 (MacBookPro16,1) | r199 `de5f9f06`, kernel `7.3.0-rc6-3-t2-edge-aer9011` | `docs/BOOT-SEQUENCE.md:32-53` |
| PEGASUS amd64 (ASUS GU502LV) | r199-era installer run, before the net-pick re-apply fix | `docs/BOOT-SEQUENCE.md:71-89` |
| O6N arm64 (Sky1) | 7.3.0-rc6 diag image | `docs/BOOT-SEQUENCE.md:91-118` |
| KVM on ULTRA aarch64 | `2026-09-29-28a868c`, `2026-09-28-3fc79c3` | `docs/INSTALLER-BOOT-TIMELINE-2026-09-29.md:14-29` |

### 1.1 Boot + detection phases (seconds)

| phase | CHIMERA amd64 | PEGASUS amd64 | O6N arm64 |
|---|---:|---:|---:|
| d-i startup (incl. initrd preseed parse) | 6.6 | 2 | 11.5 |
| `preseed/early_command` | 3.7 | 27 (25 = net-pick eno2 settle) | 7.5 |
| **file-preseed duplicate load** | **6.0** | **2** | **13.5** |
| first dialog at (cumulative) | 24.1 | 34 | 37 |
| `load-cdrom` (anna) | 5 | 5 | 11 |
| `ethdetect` | 4 | 3 | 4 |
| `netcfg` (link renegotiation + DHCP) | 8 | 67 (60 = cable-less eno2 link wait) | 11 |
| `clock-setup` | <1 (rdate stepped +14.05 s, not a stall) | <1 | 1 |
| `disk-detect` | 3 | 3 | 4 |

Operator wait (CHIMERA 49 s + 34 s; O6N 88 s) is excluded.

### 1.2 Detection, extraction, pkgsel and late.sh

From `docs/INSTALLER-BOOT-TIMELINE-2026-09-29.md:14-29` (KVM, aarch64), marker
times are cumulative seconds from qemu start:

| marker | 28a868c | 3fc79c3 |
|---|---:|---:|
| "Partitions formatting" | 50.3 | 50.1 |
| "Installing the base system" | 51.3 | 51.3 |
| "Select and install software" | 86.3 | 87.5 |
| late.sh starts | 92.1 | 93.1 |
| reboot | 399.6 | 317.1 |
| offline variant: late.sh / reboot | 75 / 470 (`:28-29`) | |

The **late.sh -> reboot window is 317.1 - 93.1 = 224 s** and **399.6 - 92.1 =
307.5 s**; the offline variant is **470 - 75 = 395 s**. That is the single
largest window and it is **UNATTRIBUTED** in these logs (see section 4).

## 2. Callgraph: where each phase runs

```
d-i detection (per 1.1)
  -> cdrom-detect / load-cdrom / ethdetect / netcfg / clock-setup / disk-detect
  -> partman
  -> "Installing the base system"
       bootstrap-base -> patched /usr/sbin/debootstrap
         (patch-debootstrap-stub.py:261-268)
         unsquashfs base.squashfs + desktop.squashfs delta -> /target   <-- EXTRACTION
  -> "Select and install software" (pkgsel; pkgsel/include is empty,
     preseed.cfg:801-824, so this is a near no-op here)
  -> finish-install -> finish-install.d/07preseed -> preseed/late_command
       -> preseed/late.sh:
            run-all.sh post-install hooks (10-our-kernel, 20-desktop,
            54-gpu-accel/DKMS, 70-bootloader, ...), apt, dracut/DKMS
  -> reboot
```

**Extraction is NOT inside the late.sh window.** `preseed.cfg:652-654` records
that bootstrap-base calls the patched `/usr/sbin/debootstrap` with `/target`;
`build/iso/patch-debootstrap-stub.py:261-268` is where `unsquashfs` runs.
`preseed/late.sh` contains no extraction (`base.squashfs` appears only in
comments at `late.sh:262,305,1320`). So the extraction belongs to the
"Installing the base system" step, which precedes "Select and install software"
and late.sh. Its own duration is `UNMEASURED` in the available logs (the KVM
table records marker instants, not the step's span).

## 3. R1: the duplicate preseed load (fixed 2026-10-08)

Historical mechanism, proven from a real log in commit `538f420b`
(CHIMERA 2026-09-29, image `2026.09.29-62d5c46`):

```
00:34:55 preseed: successfully loaded preseed file from file:///preseed.cfg
00:35:33 main-menu[10412]: INFO: Menu item 'file-preseed' selected
00:35:40 preseed: successfully loaded preseed file from file:///cdrom/ncz-payload/preseed.cfg
$ grep -c "running preseed command preseed/early_command" /var/log/syslog
2
$ md5sum /preseed.cfg /cdrom/ncz-payload/preseed.cfg
f478d51cd3e65e3a6a7a067ad440d74f  /preseed.cfg
f478d51cd3e65e3a6a7a067ad440d74f  /cdrom/ncz-payload/preseed.cfg
```

The same file was loaded twice and `preseed/early_command` ran twice. Measured
duplicate cost before the first dialog (section 1.1): **2 s (PEGASUS amd64),
6.0 s (CHIMERA amd64), 13.5 s (O6N arm64)**. It also reset `netcfg/
choose_interface`/`get_hostname` on the second load, which is what produced the
60 s netcfg wait on PEGASUS (`docs/BOOT-SEQUENCE.md:83`) and the `ncz-20e7bc`
hostname on the O6N (`docs/INSTALLER-BOOT-TIMELINE-2026-09-29.md:89`).

Fix: `build/iso/build-refind-esp.py` no longer passes
`preseed/file=/cdrom/ncz-payload/preseed.cfg`; `preseed.cfg` is loaded once by
d-i's own `S30initrd-preseed` from the baked initrd `/preseed.cfg`. The
`file-preseed` udeb is not installable when `preseed/file` is empty
(`file-preseed.isinstallable`), so the second load cannot happen. The
locale/keyboard window `file-preseed.postinst` used to reopen is restored by a
baked startup hook `S61ncz-preseed-reenable`, which runs after `S60auto-install`
(S61 > S60) -- a `echo 0` inside `preseed/early_command` would be overwritten by
S60 and does not work. The persisted re-apply helpers (`net-pick.sh`,
`user-chooser.sh`, `hostname-suggest.sh`) are kept as defensive, not as the
normal path.

Expected saving when a rebuilt image is measured: the duplicate term in 1.1
(2 / 6.0 / 13.5 s) plus the removed reset of the NIC/hostname path. It is not
booked as a measured win here because no rebuilt image exists yet.

## 4. The late.sh window (224-395 s): UNATTRIBUTED

`late.sh` runs the post-install hook chain. **The chain is already instrumented**
-- do not add a second timing scheme:

* `post-install/run-all.sh` writes `/var/log/cix-install/progress.tsv` with the
  schema `started|updated|event|phase|index|total|hook|percent|rc|detail`
  (`run-all.sh:456-472`).
* Each hook records `HOOK_START`/`HOOK_DUR` around its run
  (`run-all.sh:630-643`, `673-693`, `728-749`) and emits a `DONE`/`WARN` row.
* `progress.plan` gives the step weights used for the bar
  (`docs/GPU-INSTALL-PROGRESS.md:66-90`: NVIDIA 12, AMD 4, T2 4, Sky1 DKMS 2-3,
  all other steps 1). Weights are UI weights, **not** times.

What is missing is the **data**, not the instrumentation. To attribute the
window, collect from the next approved fresh image:

```
/var/log/cix-install/progress.tsv          # per-hook started/updated + HOOK_DUR
/var/log/cix-install/gpu-progress.results  # hook|module|version|kernel|ok|failed|seconds
/var/log/cix-install/                      # hook logs, dkms build logs
/var/log/installer/syslog                  # d-i phases (extraction vs pkgsel)
/var/log/early_command.log
```

Then rank by `HOOK_DUR` and sum by phase. Only after that should any hook be
optimized.

Clock note: `HOOK_DUR` is epoch-based (`date +%s`). A real clock **step** is
demonstrated during install -- `clock-setup` `rdate` stepped CHIMERA by +14.05 s
(`docs/BOOT-SEQUENCE.md:49-50`). That step is at `clock-setup`, **before**
late.sh, and there is no evidence yet of a step inside the late.sh window, so
the epoch `HOOK_DUR` is expected to be reliable there. A monotonic-clock
(`/proc/uptime`) enhancement is a **follow-up only if** a fresh image shows a
step inside the late.sh window; it is not required by the current evidence.

## 5. Candidate contributors inside the late.sh window (sequential, UNMEASURED)

Ordered by expected leverage. None has a measured per-hook time in the existing
logs, so no saving is claimed; each must be attributed from the `progress.tsv`
collection above before optimization.

1. **APT** -- `late.sh:587-660` installs/updates from `file:///cdrom` +
   `/target/etc/apt`, with `Acquire::Retries "5"` (`late.sh:739-746`). Includes
   `apt-get update` and package installs.
2. **DKMS builds** -- NVIDIA (weight 12) and the Sky1 vendor modules
   (`80-npu.sh` / `54-gpu-accel.sh`); DKMS is CPU-bound and the largest single
   weight in the plan. `gpu-progress.results` already records per-module
   `seconds`.
3. **dracut / initramfs** -- run once the kernel/modules exist.
4. **Optional hooks** -- desktop, browsers, wallpaper, rescue, etc.
5. **Bootloader** -- `70-bootloader.sh` installs rEFInd on both arches
   (`post-install/70-bootloader.sh:5-6`; it switched from systemd-boot to
   rEFInd at 26.6-r118), required and on the critical path.

Extraction (`unsquashfs` base + desktop) is **not** in this list; it is in the
earlier "Installing the base system" step (section 2), and it is also
`UNMEASURED`.

## 6. Already fixed (do not re-litigate)

* net-pick wired-carrier settle 25 s -> 5 s (link up), 10 s (no adapter), 20 s
  (no carrier) -- `docs/BOOT-SEQUENCE.md:242`.
* `clock-setup` NTP moved to a bounded background `clock-sync.sh`
  (`docs/BOOT-SEQUENCE.md:243`); worst measured foreground NTP-filter stall was
  60.07 s (`docs/BOOT-SEQUENCE.md:225-229`).
* installed `NetworkManager-wait-online` bounded to 15 s
  (`docs/BOOT-SEQUENCE.md:245`).
* the duplicate preseed load (section 3, this change).

DHCP/NIC/time waits that remain are deliberate (a late cable or late DHCP still
works) and are not part of this phase.

## 7. Recommendation

1. **This phase:** land the single-preseed fix as **source only**. Do **not**
   ship an image from it; the existing release holds remain in force. The
   duplicate removal is proven from code and fixtures, but its end-to-end effect
   is only measurable on a rebuilt image after release-input holds are
   resolved and the normal build/acceptance gates pass.
2. **Next measurement:** collect `progress.tsv` / `gpu-progress.results` /
   installer syslog from one approved fresh image and attribute the late.sh
   window by `HOOK_DUR`, separating the earlier extraction and pkgsel steps. No
   saving is claimed for any unmeasured step; the numbers in this document are
   the existing OLD-image measurements only.
3. **Only then, and only with that data:** apply one of the concrete, bounded
   changes below. Each is a proposal, not a measured win.
   * **Same APT source, refreshed once:** if the validation run shows a hook
     re-reading an unchanged target source, refresh that same source once per
     validation instead of per hook. Do not add or re-order sources.
   * **Reuse signed prebuilt modules:** when a step rebuilds modules for the
     exact same ABI/revision that already has a signed, revision-matched
     prebuilt set, reuse that set and register it with DKMS for future upgrades
     instead of an unconditional rebuild. Only if the ABI/revision signature
     matches; otherwise keep the rebuild.
   * **Consolidate the initramfs refresh:** build the initramfs once, after all
     modules and the SSDT configuration are in place, then copy it to the ESP and
     regenerate the rescue entries. No blind parallel DKMS/dpkg, which would race
     on the same package database and initramfs.
   * **Monotonic `HOOK_DUR`:** only if the fresh data shows a clock step inside
     the late.sh window.
4. **No quantified savings** are attached to items in (3): their inputs are
   `UNMEASURED`.
