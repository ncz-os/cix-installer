# Boot speed: install detection + installed-system boot (NCZ-OS 26.10 Cygnus)

Item D analysis. Scope: (1) the **install-detection phase** -- everything from
installer boot until d-i knows what it is installing on -- and (2) **overall
boot speed** of the installed system, on both arm64 (Sky1) and amd64.

Method, stated honestly up front: this work was done **without running an image
build or a VM/hardware boot** (the orchestrator owns those; item D is not allowed
to start them). Every "cost" below is either (a) taken from a measurement that
already exists in this repo, with a file:line citation, or (b) labelled
`UNMEASURED` and left in the "candidates needing measurement" list instead of
being changed. Only changes whose safety and benefit are provable from the code
were made.

The one code change in this item is documented in
[Changes made in this item](#changes-made-in-this-item) and covered by
`build/test-boot-speed.sh` (wired into `make parity`).

---

## 1. Install-detection sequence (mapped)

"Installer boot -> d-i knows what to install on" is this chain, in order. The
wall-clock markers are the KVM measurements from
`docs/INSTALLER-BOOT-TIMELINE-2026-09-29.md` (28a868c / "fixed image" columns).

| # | Stage | Where | Cost as last measured | Notes |
|---|-------|-------|-----------------------|-------|
| 0 | firmware -> boot manager | UEFI | 5.6 s | not ours |
| 1 | rEFInd menu wait | `build/iso/build-refind-esp.py:239` (`timeout 3`) | 3.2 s | was 10 s before 2026-09-29 |
| 2 | d-i initrd up (syslogd) | d-i | ~1.8 s | |
| 3 | `preseed/early_command` runs | `preseed/preseed.cfg:199-421` | ~3.6 s to banner | see breakdown below |
| 4 | "Loading additional components" (anna) | d-i + mirror block `preseed/preseed.cfg:423-485` | ~5 s | network-bound; ~285 udebs from the pinned mirror |
| 5 | first hardware-detection screen (hw-detect + udev coldplug) | d-i | ~8 s to first screen | |
| 6 | disk / previous-install detection + choosers | `preseed/preseed.cfg:596-670` (`partman/early_command`), `preseed/disk-fs-chooser.sh:94-171`, `preseed/component-selector.sh`, `region-chooser.sh`, `user-chooser.sh` | 27.2 -> 46.3 s (~19 s incl. anna tail + prompts) | interactive in the default flow; gated unattended by cmdline overrides |
| 7 | partition formatting | partman | 46.3 s | end of detection phase |

`preseed/early_command` (step 3) in detail -- this is the only large body of
installer code we own that runs before d-i's own detection:

| sub-step | line | blocking? | cost |
|----------|------|-----------|------|
| SSH keys, media resolve, NIC udeb install | `preseed/preseed.cfg:240-351` | yes | 5 sequential `find` scans (see finding F2) + `depmod -a` |
| `udevadm trigger`/`settle --timeout=5` | `preseed/preseed.cfg:352-353` | yes | <=5 s cap |
| wired-carrier pick | `preseed/preseed.cfg:368-412` | **yes** | breaks on first carrier (rank<=1 => ~1 s); up to 25 s only when a PCI NIC exists with no carrier |
| helper copy + `component-selector.sh` (non-prompt) | `preseed/preseed.cfg:413-419` | yes | cheap |
| heartbeat banner | `preseed/preseed.cfg:226` | background | 60x2 s loop, does not block |
| clock correction | `preseed/preseed.cfg:292-313` | background | up to 60x2 s, does not block |
| `usb-rescan.sh` | `preseed/usb-rescan.sh:80-123` | yes, when `/cdrom` not already mounted | immediately returns if `sd*` present; up to 10 s wait then a rebind only on the known Sky1 USB2 bug |
| `diag-console.sh` | `preseed/diag-console.sh:425` | background | up to 120 s wait for a banner IP, does not block install |
| `sshd-watcher.sh` | background | no | |

Platform detection in the installed-system path (item 1's "`ncz` platform
detection hooks in `post-install/` and `assets/`") is
`post-install/run-all.sh:251-304`: it maps `$_NCZ_SYSTEM_ARCH` to
`sky1-arm64`/`amd64` with no scans (cheap), so there is no time to recover there.

## 2. Installed-system boot contributors

| Stage | Where | Evidence |
|-------|-------|----------|
| root-wait tolerance | cmdline `rootwait`, no `rootdelay` | `assets/refind/ncz-refind-refresh.sh:260-264`; `docs/DRIVER_FIDELITY_72.md:324-352` (rootdelay=90 removed: ~94 s -> 3.6 s) |
| initrd builder | dracut (arm64) / dracut-or-initramfs-tools (amd64) | `post-install/94-dracut-config.sh:83-170`; `build/build-kernel-debs.sh:1129` |
| dracut driver set | `assets/dracut/10-ncz-sky1.conf:18-30` | superset chosen so a generic image always boots |
| rEFInd installed default timeout | `assets/refind/ncz-refind-refresh.sh:758` (`${NCZ_REFIND_TIMEOUT:-10}`) | learned/overridable; 10 s stock |
| graphical critical chain | `post-install/41-usb2-rescan.sh:126-134` | `graphical.target @8.843s -> greetd @7.738s -> ncz-usb2-rescan @2.031s +5.704s` (that 3 s grace is now 1 s) |
| amd64 "largest unit" on a machine it cannot help | `post-install/22-display-fix.sh:124-142` | `7.428s cix-detect-display.service` on MEDUSA; now **disabled** when arch != arm64 |
| boot splash | `post-install/60-boot-splash.sh:114-155` | 22 s safety cap, normal path exits on the greeter-ready marker |
| network bring-up | `post-install/33-network.sh:371-380` | NM-wait-online unmasked/enabled; bounded by NM_ONLINE_TIMEOUT (~30 s) |
| first-boot report | `post-install/97-firstboot-report.sh:31-46` | `Type=simple` deliberately, so its 30 s sleep does not hold multi-user.target |

## 3. Findings table

`cost` is from the cited evidence. `action` is one of FIXED / proposed (needs a
boot to validate) / no change (documented reason intact).

| id | Location | Cost | Evidence | Action |
|----|----------|------|----------|--------|
| F1 | `post-install/50-brand.sh:207` `ncz-issue-refresh.service` was `Type=oneshot` + `WantedBy=multi-user.target` + `After=/Wants=network-online.target` | up to ~60 s on the multi-user -> graphical critical chain on slow/absent DHCP (plus the network-online wait) | helper polls `TRIES 30 x sleep 2` (`50-brand.sh:179-194`); the project's own precedent `97-firstboot-report.sh:36-39` says a oneshot in multi-user's wants "would hold the target (and the display manager behind it)" | **FIXED** (see below) |
| F2 | `preseed/preseed.cfg:341-350` NIC udeb lookup runs `find` once per package over 4 media roots (5 scans) | `UNMEASURED`; scales with medium tree size | code | proposed |
| F3 | duplicate device enumeration: `preseed/preseed.cfg:247-254` then `preseed/preseed.cfg:604-643` | `UNMEASURED`; only when the payload is not at a known mountpoint | code | proposed |
| F4 | wired-carrier settle `_ncz_settle=25` (`preseed/preseed.cfg:377-403`) | 0-1 s when a PCI NIC has carrier; up to 25 s when it does not | comment: RTL8125B autoneg 9-13 s (`preseed/preseed.cfg:188-192`) | no change (reason intact) |
| F5 | `preseed/usb-rescan.sh:80-85` 10 s wait for `sd*` | only when medium not enumerated; documented Sky1 USB2 bug | `preseed/usb-rescan.sh:2-20` | no change |
| F6 | `preseed/preseed.cfg:56,58` `netcfg/dhcp_timeout`/`dhcpv6_timeout` 120 | only on a missing DHCP server | installer entries set `ipv6.disable=1` (`build/iso/build-refind-esp.py:158`) | proposed |
| F7 | installed rEFInd default `timeout 10` | up to 10 s menu wait per boot | `assets/refind/ncz-refind-refresh.sh:758`; operator timeout is learned (`:748-756`) | proposed (operator-facing) |
| F8 | `post-install/88-noe-umd-venv.sh:225-239` oneshot in `multi-user.target.wants` re-syncs a pip venv when `cix-noe-umd` changes | first boot after an upgrade blocks multi-user during the sync; common path is a cheap `dpkg-query`+import | code | proposed |
| F9 | `post-install/44-rtc-sync.sh:120-136` oneshot blocking up to 12x10 s waiting for NTP | offline/no-NTP boot delay | documented reason: never persist a wrong time (`:103-117`) | proposed (needs a decision) |
| F10 | `assets/dracut/10-ncz-sky1.conf:18` adds `msm` (Qualcomm MSM DRM) plus a wide USB-ethernet set | initrd size only | `msm` is not a Sky1 driver; the file's own comment argues for a boot-safe superset | proposed (risky, needs a boot) |
| F11 | **`ncz-rootdelay` initramfs hook is referenced but absent** | root-wait tolerance may be lower than the docs claim if initramfs-tools is ever the builder | no file/dir matches `ncz-rootdelay`, `slumber`, or `ROOTDELAY`; only `assets/refind/ncz-refind-refresh.sh:260` and `docs/DRIVER_FIDELITY_72.md:564` mention it | flag -> needs decision (kernel/initramfs area, item A) |
| F12 | `systemd-udev-settle.service` ordered `After=` by `41-usb2-rescan`, `22-display-fix`, `60-boot-splash`, `85-power-perf-mode`, `95-console-font-autosize`, `98-gpu-health`, `assets/gpu/ncz-gpu-switcher.service` | settle can add an unbounded wait | grep | proposed (each has a documented reason) |

Things already fixed before this item, recorded so they are not re-litigated:
rEFInd installer `timeout 3` (`build/iso/build-refind-esp.py:239`),
`quiet loglevel=3 ...` splash cmdline
(`assets/refind/ncz-refind-refresh.sh:257`), the `rootdelay=90` removal
(`docs/DRIVER_FIDELITY_72.md:561-567`), the USB2-rescan grace cut 3 s -> 1 s
(`post-install/41-usb2-rescan.sh:114-144`), `cix-detect-display` made
arm64-only (`post-install/22-display-fix.sh:124-142`), the component-selector
90 s poll replaced by a synchronous prompt
(`preseed/component-selector.sh:215-234`), and `ncz-firstboot-report`
`Type=simple`.

## 4. Changes made in this item

### F1 -- `ncz-issue-refresh.service` no longer holds the boot

`post-install/50-brand.sh` generated:

```
After=network-online.target
Wants=network-online.target
...
Type=oneshot
```

A `Type=oneshot` service pulled into `multi-user.target.wants` is **not**
fire-and-forget: the target's start job does not complete until the oneshot
process exits. Because `graphical.target` is `After=multi-user.target`, the
60 s address poll in `ncz-issue-refresh` (30 tries x `sleep 2`,
`post-install/50-brand.sh:179-194`) sat directly on the way to the login screen
on any boot where DHCP had not completed yet, and the `After=network-online`
added NM's online-wait budget on top.

The unit is now `Type=simple` with the redundant `After=/Wants=network-online`
removed. Safety: the helper is self-polling, so removing the ordering cannot
lose the address -- it keeps retrying and fills `/etc/issue` in when the lease
lands. This is the exact pattern `post-install/97-firstboot-report.sh:36-46`
already uses for the same reason.

* Expected saving: up to ~60 s per boot removed from the critical chain when
  DHCP is slow/absent; ~0 on a healthy network (the long case is the one that
  matters). `UNMEASURED` end-to-end until the orchestrator boots both images.
* Test: `build/test-boot-speed.sh` (new). It extracts the generated `ISSUE_UNIT`
  heredoc and asserts it is not a boot-blocking oneshot, is `Type=simple`, has
  no `network-online` ordering, and still ships a self-polling helper. It also
  self-checks the detector against a synthetic oneshot/simple unit.
* Before/after proof (run in this worktree):

  ```
  # before the 50-brand.sh edit
  boot-speed tests: 4 passed, 3 failed      (exit 1: "Type=oneshot", "declares Type=simple", "network-online")
  # after
  boot-speed tests: 7 passed, 0 failed      (exit 0)
  ```

## 5. Measurement plan for the orchestrator

Run these on: (a) the **installer** boot (KVM or metal), and (b) the **installed**
system on both arches. Record raw output, not sums.

### 5.1 Install-detection phase (installer)

The repo already has the harness: `build/boot-timeline.py` records
`(time, serial size)` every 0.2 s and maps markers to wall clock
(`build/boot-timeline.py:1-11`).

```sh
# from the build host, for each candidate image
python3 build/boot-timeline.py <image> <workdir> --max-secs 600
# d-i's own syslog timestamps after the install (d-i syslogd writes /var/log/syslog):
#   grep -E 'ncz|anna|hw-detect|netcfg|choose-mirror|partman' /var/log/syslog
# the exact early_command timing is logged at:
#   /var/log/early_command.log   (per-step lines with the carrier loop's `${_i}s`)
#   /var/log/ncz-usb-video.log   ("waited Ns for the kernel's own scan")
```

### 5.2 Installed-system boot (both arches)

```sh
systemd-analyze time
systemd-analyze blame | head -30
systemd-analyze critical-chain
systemd-analyze critical-chain graphical.target
# who waited on the network:
systemctl show -p ActiveEnterTimestampMonotonic -p InactiveExitTimestampMonotonic \
    NetworkManager-wait-online.service ncz-issue-refresh.service
journalctl -b -o short-monotonic | grep -E 'ncz-issue-refresh|ncz-usb2-rescan|cix-detect-display|ncz-boot-splash|NetworkManager-wait-online'
# initramfs:
lsinitrd /boot/initrd.img-$(uname -r) | grep -E '^dracut|^====' ; # module count/size
journalctl -k -o short-monotonic | grep -E 'Freeing unused kernel|nvme0n1: p1|systemd\[1\]: Detected'
# boot loader:
grep -E '^timeout|^scanfor' /boot/efi/EFI/BOOT/refind.conf
```

### 5.3 Before/after table template

| metric | arm64 before | arm64 after | amd64 before | amd64 after |
|--------|--------------|-------------|--------------|-------------|
| rEFInd menu wait (s) | | | | |
| kernel -> `systemd[1]` (s) | | | | |
| `systemd-analyze time` userspace (s) | | | | |
| `graphical.target` reached (s) | | | | |
| critical chain's slowest unit (name, s) | | | | |
| `ncz-issue-refresh.service` active delay (s) | | | | |
| installer: banner at (s) | | | | |
| installer: first hw-detect screen (s) | | | | |
| installer: partition formatting (s) | | | | |

## 6. Candidates needing measurement

Ordered by expected value; none implemented because the cost could not be
established without a boot (item D's rule).

1. **F7 installed rEFInd timeout 10 s** (`assets/refind/ncz-refind-refresh.sh:758`).
   Lowering the fresh-install default would save the full value every boot, but
   it is an operator-facing choice the script deliberately learns and preserves
   (`:748-756`). Decide policy, then measure.
2. **F9 `ncz-rtc-sync` blocking up to 120 s for NTP** (`post-install/44-rtc-sync.sh`).
   Could be made async like F1, but the unit waits on `systemd-time-wait-sync`,
   which may itself be wanted elsewhere; prove who is on the chain first.
3. **F8 `ncz-noe-venv-sync` oneshot in multi-user** (`post-install/88-noe-umd-venv.sh`).
   Async would remove the first-boot-after-upgrade stall, but only if nothing
   needs the venv before login. Measure the common path first.
4. **F12 `systemd-udev-settle.service`** ordering. Each consumer documents why it
   wants settle; removing it is a per-unit risk, not a global one.
5. **F2 NIC-udeb `find` x5** (`preseed/preseed.cfg:341-350`). Hoist to one
   `find '*.udeb'` and match in-shell; measure on a USB medium where the tree is
   large before changing the d-i busybox path.
6. **F3 duplicate media/device enumeration** (`preseed/preseed.cfg:247-254` vs
   `:604-643`). Only bites when the payload is not at a known mountpoint.
7. **F6 `netcfg` DHCP timeouts 120 s** (`preseed/preseed.cfg:56-58`). Only bites
   with no DHCP server; `ipv6.disable=1` already avoids DHCPv6 on the installer
   entries.
8. **F10 trim `msm` from the dracut driver set**
   (`assets/dracut/10-ncz-sky1.conf:18`). Likely initrd-size-only; requires a
   boot to prove no dependency, so not changed here.
9. **F11 `ncz-rootdelay` hook missing** (`assets/refind/ncz-refind-refresh.sh:260`,
   `docs/DRIVER_FIDELITY_72.md:564`). The comment and the doc assert a hook that
   does not exist anywhere in this repo (`git grep ROOTDELAY` finds only the
   doc). On dracut systems this may be moot, but if any installed image still
   uses initramfs-tools the documented 90 s fallback is not actually provided.
   This touches initramfs/kernel territory (item A) -- needs a decision, not a
   silent fix here.

## 7. Tests added

* `build/test-boot-speed.sh` -- regression test for F1 (and the detector's
  self-check). Registered in `docs/platform-inventory.tsv` and run by
  `make test-boot-speed` and by `make parity`.
