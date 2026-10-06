# Detection and boot sequence (NCZ-OS 26.10, 2026-10-06)

Operator order (2026-10-06): fix the detection and boot-up sequence on both
architectures. This document records what was measured first, what changed on
branch `fix/boot-detect-sequence-20261006`, and what the change is expected to
do. It follows on from [BOOT-SPEED.md](BOOT-SPEED.md), which covers the earlier
oneshot and NTP fixes.

**The "after" numbers in this document are expected, not measured.** No image
was built or booted for this change. They become measurements only after a
rebuilt image boots on CHIMERA, PEGASUS and the O6N.

Sources (all read-only):

| platform | what | source |
|---|---|---|
| amd64 T2 (CHIMERA `192.168.207.6`, MacBookPro16,1) | installed boot | `systemd-analyze`, `blame`, `critical-chain`, unit timestamps, `journalctl -b 0/-1/-2 -o short-monotonic`. Image r199 `de5f9f06`, kernel `7.3.0-rc6-3-t2-edge-aer9011` |
| amd64 T2 (CHIMERA) | installer | `/var/log/installer/syslog` of the r199 install, 2026-10-06 13:57 UTC |
| amd64 Intel + NVIDIA (PEGASUS `192.168.207.85`, ASUS GU502) | installed boot | same commands, first boot of r199 |
| amd64 (PEGASUS) | installer | saved syslog of an earlier r199-era run (2026-10-06 14:17 UTC, before the net-pick re-apply fix) |
| arm64 Sky1 (O6N `192.168.207.3`) | installer | live installer syslog, `early_command.log`, `ncz-usb-video.log`, `diag-console.log` (2026-10-06, 7.3.0-rc6 diag image); serial log on PROTEUS |
| arm64 (O6N) | installed boot | not reachable today (the board was in the installer). The last measured installed boot is the 2026-10-04 one in BOOT-SPEED.md section 0 |

Installer times are wall clock from the syslog, converted to seconds since
kernel start using a kernel-stamped line from the same second. The O6N has no
RTC; its offset comes from `/proc/uptime` read with `date -u` at the same moment.

---

## 1. Measured timelines (before)

### 1.1 Installer, amd64, CHIMERA (r199, T2 kernel)

| t (s) | event |
|---:|---|
| 0 | kernel start (13:57:36.9 UTC) |
| 6.8 | last kernel probe message (T2 BCE USB/HID) |
| 6.8 to 13.4 | **no output: d-i startup** (S15lowmem, S20templates, S30initrd-preseed, S32, S33) |
| 13.4 | `preseed/early_command` (initrd preseed); medium mounted |
| 14.1 | `enx00e04c684081: carrier on` (USB NIC) |
| 17.1 | early_command done; d-i main menu |
| 17.1 to 23.1 | `file-preseed`: media preseed fetched and parsed again, duplicate early_command run |
| **24.1** | **first dialog**: locale/keyboard chooser (`console-setup-udeb`) |
| +49 | (operator) |
| 73.1 to 78 | `load-cdrom` (anna fetches the installer components) |
| 78 to 82 | `ethdetect` (check-missing-firmware takes two cable-less NICs up and down) |
| 82 to 90 | `netcfg`: link renegotiation 1 s, DHCP 4 s |
| +34 | (operator: user-setup) |
| 124 | `clock-setup`: `rdate` returns within the same second. The syslog jumps 13:59:41 to 13:59:55 because rdate **stepped the clock by +14.05 s**. It did not stall |
| 125 to 128 | `disk-detect` |

Firmware and the rEFInd menu (installer timeout 3 s) come before t=0 and are
not in the syslog.

Top contributors before the first dialog and in the detection phase (operator
time excluded):

| # | item | s |
|---:|---|---:|
| 1 | netcfg (renegotiation + DHCP) | 8 |
| 2 | kernel device probe (T2) | 6.8 |
| 3 | d-i startup, kernel silent (templates load + initrd preseed parse) | 6.6 |
| 4 | file-preseed (second parse of preseed.cfg) | 6.0 |
| 5 | load-cdrom (anna) | 5 |
| 6 | ethdetect | 4 |
| 7 | early_command | 3.7 |
| 8 | disk-detect | 3 |
| 9 | partman-base to chooser | 2 |
| 10 | clock-setup | <1 (the apparent 14 s is a clock step) |

### 1.2 Installer, amd64, PEGASUS (earlier r199-era image)

| t (s) | event |
|---:|---|
| 0 | kernel start (14:17:54 UTC) |
| 5 | early_command starts |
| 6.6 | `enx00e05c6701d5: carrier on` (USB NIC; onboard `eno2` has no cable) |
| 5 to 32 | **early_command: 27 s, of which ~25 s is net-pick waiting for `eno2`** (`SETTLE=25` when a PCI Ethernet controller exists) |
| **34** | **first dialog** (locale/keyboard) |
| | (operator 21 s) |
| 55 to 60 | load-cdrom |
| 60 to 63 | ethdetect |
| 63 to 130 | **netcfg 67 s: auto mode activated the cable-less `eno2` and waited the full 60 s link timeout.** Fixed on the respin branch (net-pick pin re-applied after the preseed reload) |
| | clock-setup <1 s (`adjust local clock by 0.399064 seconds`) |
| | disk-detect 3 s |

Top contributors: netcfg 67 s (60 s was the eno2 wait, already fixed),
net-pick 25 s, load-cdrom 5 s, kernel to early_command 5 s, ethdetect 3 s,
disk-detect 3 s, file-preseed 2 s, d-i startup 2 s, clock-setup <1 s.

### 1.3 Installer, arm64, O6N (2026-10-06 diag image, 7.3.0-rc6)

| t (s) | event |
|---:|---|
| 0 | kernel start |
| 2 | initrd up (syslogd) |
| 3.5 | last device: USB medium `sdb` attached |
| 3.5 to 15 | **no output: d-i startup (11.5 s)** |
| 15 | early_command starts |
| 17.7 | medium mounted (`usb-rescan`: "waited 0s", medium already present) |
| 17.7 to 18.5 | SSH udebs installed. **31 x "Bus error" and "Text file busy"**: `udpkg -i libc6-udeb` replaces the running libc under `sshd-watcher.sh` (finding D1 below) |
| 18.5 to 21.7 | NIC udebs, `net-pick`: `enp1s0` raised at 18.65, `Link is Up 2.5Gbps` at 21.73, picked at 2 s |
| ~22.5 | early_command done |
| 22.5 to 36 | **file-preseed: ~13.5 s** (second parse of preseed.cfg) |
| **37** | **first dialog** (locale/keyboard) |
| | (operator 88 s) |
| +11 | load-cdrom |
| +4 | ethdetect |
| +11 | netcfg: link renegotiation 4 s, DHCP 4 s |
| | clock-setup 1 s (`adjust local clock by 0.590406 seconds`) |
| +4 | disk-detect |

The older O6N image printed `Waiting for a wired network link... (45s)`. That
image enumerated only `lo` (PCIe in DT mode), so the loop counted to its 45 s
maximum before netcfg reported no interface.

Top contributors: file-preseed ~13.5, d-i startup 11.5, load-cdrom 11, netcfg
11, early_command ~7.5, ethdetect 4, disk-detect 4, initrd 2, clock-setup 1.

**Preseed parsing is the largest fixed cost before the first dialog on all
three machines.** It runs twice: once at d-i startup, once at file-preseed.
CHIMERA spends 6.6 + 6.0 s, the O6N 11.5 + 13.5 s and PEGASUS ~2 + 2 s. d-i's
`/usr/bin/debconf-set-selections` is a shell loop that forks `echo`, `grep` and
`sed` several times per line, and preseed.cfg has 428 non-comment lines, 260
of them continuations. Lower-bound benchmark: the real d-i script with stubbed
`db_*` calls, run under static busybox on ULTRA (arm64):

| variant | non-comment lines | parse (s) |
|---|---:|---:|
| preseed.cfg as shipped | 428 | 1.24 to 1.33 |
| early_command body moved to a helper | 275 | 0.82 to 1.09 |
| every continuation value joined | 180 | 0.64 to 0.76 |

The installer pays several times this lower bound, because the real `db_*`
calls are IPC to cdebconf, which holds a 14 MB `templates.dat`. Candidate C1
below. Not changed here.

### 1.4 Installed boot, amd64, CHIMERA

`Startup finished in 365ms (kernel) + 2.046s (initrd) + 13.669s (userspace) = 16.080s`.
The two previous boots took 15.370 s and 15.711 s. Apple firmware does not
report firmware or loader time.

| t (s) | event |
|---:|---|
| 2.4 | switch root |
| 3.18 | `cix-detect-display` starts polling for a connected connector |
| 4.17 to 7.61 | `boot-efi.mount` 3.44 s on this boot (0.13 s and 0.14 s on the two previous boots: a one-off) |
| 7.62 | amdgpu starts probing (7.63 and 7.90 on the previous boots) |
| 7.74 | basic.target; NetworkManager starts |
| 8.33 | DHCP lease on `enx00e04c684081` |
| 10.30 | `Initialized amdgpu` (eDP-1 on card1) |
| 10.35 | `cix-detect-display` finishes (7.17 s); splash starts |
| 11.30 | **greetd started**; greeter session at 11.77 |
| 16.04 | NetworkManager `startup complete` |
| 16.05 | NetworkManager-wait-online finishes (8.08 s) |
| 16.07 | multi-user.target (inetd is `After=network-online.target`) |
| 16.08 | graphical.target |

Critical chain: `graphical.target -> multi-user.target -> inetd -> network-online.target -> NetworkManager-wait-online +8.083s`.
The greeter is **not** on that chain. It is gated by
`cix-detect-display -> greetd` (`55-greeter.sh` drop-in: `After=/Wants=cix-detect-display`).

Top 10: NetworkManager-wait-online 8.08 (gates graphical.target only),
cix-detect-display 7.17 (waiting for amdgpu's eDP; this is the greeter
path), amdgpu init 2.7 (starts late at 7.6 s), boot-efi.mount 3.44 (one-off),
initrd 2.05, fwupd 1.97 (off-chain), greetd 0.94, initrd-switch-root 0.92,
boot splash 0.91, ncz-gpu-health 0.58.

### 1.5 Installed boot, amd64, PEGASUS (first boot)

`Startup finished in 9.268s (firmware) + 6.482s (loader) + 459ms (kernel) + 2.226s (initrd) + 1min 5.748s (userspace) = 1min 24.185s`.

| unit | start to active (s) |
|---|---|
| ncz-firstboot | 4.52 to 68.39 (63.87; failing NVIDIA DKMS build. Another branch owns this) |
| NetworkManager-wait-online | 7.65 to 13.20 (5.55) |
| multi-user.target | 13.32 |
| greetd | 68.39 to 68.43 (waits for ncz-firstboot) |
| graphical.target | 68.43 |
| ncz-cuda-setup | not on the boot path: timer, `OnBootSec=2min`, own `After=/Wants=network-online.target` |

Top 10: ncz-firstboot 63.87 (first boot only, other owner), firmware 9.27,
loader 6.48 (installed rEFInd `timeout 10`), NetworkManager-wait-online 5.55,
ncz-gpu-health 2.72, fwupd-refresh 2.32 (timer), initrd 2.23, apparmor 1.97,
blueman-mechanism 1.41, cix-detect-display 1.37 (i915 eDP is ready early).

### 1.6 Installed boot, arm64, O6N

Not measured today. The last measurement (BOOT-SPEED.md section 0, 2026-10-04,
7.2.9) was `2.0s (kernel) + 2.65s (initrd) + 32.7s (userspace) = 37.3s`. Its
top items have all been fixed since, in BOOT-SPEED.md items D, F and G:
ncz-rtc-sync / systemd-time-wait-sync held multi-user.target for 31.4 s, the
ncz-issue-refresh poll took 10.1 s, and the first timesyncd contact took 30 s.
The greeter chain was `graphical @8.843s -> greetd @7.738s -> ncz-usb2-rescan +5.7s`;
the rescan grace has since dropped from 3 s to 1 s. The serial log adds UEFI
PCIe init at 0.62 to 1.35 s of firmware time.

---

## 2. Findings that changed the plan

* **cix-detect-display on amd64 is not dead time.** Its 7.17 s on CHIMERA is
  the wait for amdgpu to publish eDP. That happens at 10.30 s because amdgpu
  only starts probing at 7.6 s. greetd's `ExecCondition=ncz-has-drm-output`
  checks for a connected connector **once**. Removing the unit from greetd's
  path on amd64 would let that check run before amdgpu is ready, and greetd
  would be *skipped* (no login screen). So the wait stays.
* **What it also did on amd64 was wrong.** greetd `Wants=` the unit, so it ran
  every boot even though 22-display-fix.sh disables it on amd64 (CHIMERA:
  `systemctl is-enabled` = `disabled`, `WantedBy=greetd.service`). It then
  wrote the Sky1 layout onto PC hardware. Both CHIMERA and PEGASUS carry
  `/etc/udev/rules.d/73-cixmini-primary-display.rules`, which strips
  master-of-seat and seat from every card except the one that was connected
  last boot, plus an Xorg `kmsdev` pin. On PEGASUS the stripped card is the
  NVIDIA GPU, which drives the HDMI port. The rule is written after coldplug,
  so it applies at the **next** boot to whatever card numbering that boot has.
  The install-time run in the same hook did the same thing from inside the
  installer.
* **clock-setup did not stall on the measured installs.** The "14 s rdate" on
  CHIMERA is a +14.05 s clock step. It does stall when UDP/123 is filtered.
  Measured with the installer's own `rdate` binary (rdate-udeb, copied from
  the O6N) in a network namespace whose default route silently drops packets:

  | case | rdate time |
  |---|---:|
  | no route | 0.001 s ("Network is unreachable") |
  | one address, packets dropped | 15.02 s |
  | four-address name (as `0.debian.pool.ntp.org` resolves), packets dropped | **60.07 s** |

* **NetworkManager-wait-online does not gate the greeter.** It gates
  graphical.target through `inetd.service` (`After=network-online.target`).
  CHIMERA had its lease at 8.33 s but NetworkManager reported `startup complete`
  only at 16.04 s. `nm-online -s` waits for that, and it also covers the second,
  cable-less USB NIC and the Wi-Fi device. The stock timeout is 60 s, not the
  "~30 s" that 33-network.sh claimed.

## 3. What changed

| # | file | change | why |
|---|---|---|---|
| 1 | `preseed/net-pick.sh` | When a PCI or USB link is up, settle after 5 s (was 25 s with a cable-less PCI NIC). With no wired adapter at all, stop at 10 s and print `[ncz] No wired network adapter was detected ...` with the Alt+F2 / Alt+F4 / Sky1 serial hint (was a silent 45 s count). With adapters but no carrier, give up at 20 s (was 45 s; the slowest measured autoneg is 13 s, and netcfg still waits its own 60 s afterwards). Unchanged: a PCI link wins at once, and a weak iBridge-only candidate still gets the PCI settle | PEGASUS 25 s; O6N old image 45 s |
| 2 | `preseed/preseed.cfg`, new `preseed/clock-sync.sh`, `build/iso/patch-initrd-t2-kernel.py` | `clock-setup/ntp=false`, as the KVM gates already boot. early_command starts `clock-sync.sh` detached. It waits up to 120 s for a default route and up to 180 s for anna's rdate, runs one SNTP attempt bounded at 20 s wall clock, and falls back to the mirror Date header only when the year is < 2020 (the rule the inline subshell had; that subshell moved into the helper). The helper is baked into the initrd. early_command shrank from 10,677 to 9,964 bytes | up to 60 s of foreground progress bar on networks that filter NTP |
| 3 | `post-install/22-display-fix.sh` | The generated `detect-primary-display.sh` keeps its bounded wait for a connected output on every arch, but writes the udev master-of-seat rule and the Xorg pin only on `aarch64`. The install-time run is arm64-only | Sky1 pin leaked onto CHIMERA and PEGASUS; greetd still gets its DRM-ready wait |
| 4 | `post-install/33-network.sh` | Drop-in `NetworkManager-wait-online.service.d/10-ncz-bounded.conf`: `NM_ONLINE_TIMEOUT=15`. Failure semantics unchanged | caps network-online, and with it multi-user and graphical, at 15 s instead of 60 s when DHCP is absent |
| 5 | `preseed/diag-console.sh` | `alive()` is defined before the first `serial_tick` | O6N log: `diag-console.sh: line 238: alive: not found`; the serial pidfile guards never worked on the first pass |
| 6 | `build/test-boot-sequence.sh`, `Makefile` (`test-boot-sequence`, `parity`), `docs/platform-inventory.tsv` | regression tests, run under sh and busybox sh | |

Not touched, because other branches own them: ncz-firstboot DKMS logic,
ncz-cuda-setup, `post-install/lib/gpu-progress.sh`,
`post-install/60-boot-splash.sh`, the preseed choosers and the progress bar.

### Tests

`build/test-boot-sequence.sh` runs the real scripts and generated heredocs
against stubs. On HYDRA: **39 passed, 0 failed** under both `sh` and
`busybox sh`. Against the base commit `c8234581`, with the old files overlaid:
**12 passed, 18 failed** (both shells): every assertion about the new behaviour fails without the change, and the 12 that pass check behaviour that was meant to stay the same.
Existing suites still pass unchanged:

* check-early-command-size: 9,964 bytes
* test-installer-flow: 65/65
* test-installer-screens: 82/82
* test-boot-speed: 20/20
* test-timesync-retry: 14/14
* test-installed-target-verifier: 82/82
* test-sky1-serial-diag: 17/17
* lint-hook-arch-gates: OK

Four suites fail identically on the base commit and on this branch, because
the test copy is sparse and not a git checkout, and because of host tools:
lint-platform, test-platform-lint, test-usb2-rescan-greetd and
test-greeter-output-mode. In a temporary git copy, lint-platform reports the
same 79 findings before and after.

## 4. Expected after (not measured)

| platform / phase | before (measured) | expected after |
|---|---|---|
| Installer, USB link up + cable-less onboard NIC (PEGASUS) | early_command 27 s, first dialog at 34 s | early_command ~7 s, first dialog at ~14 s (-20 s) |
| Installer, no wired adapter (old O6N image) | silent count to 45 s | message at 10 s with the diagnostics hint (-35 s) |
| Installer, adapters but no cable | 45 s scan + netcfg 60 s | 20 s scan + netcfg 60 s (-25 s) |
| Installer, clock-setup, NTP reachable | 0 to 1 s | 0 s in the foreground; the sync runs in the background |
| Installer, clock-setup, UDP/123 filtered | 60 s progress bar (measured worst case) | 0 s in the foreground; the background attempt stops at 20 s |
| Installed CHIMERA, greeter | greetd at 11.3 s | unchanged: bound by amdgpu eDP at 10.3 s (see C2) |
| Installed CHIMERA, graphical.target | 16.08 s | unchanged on a healthy LAN (8 s < 15 s cap) |
| Installed amd64, no DHCP server | network-online and graphical up to +60 s | at most +15 s |
| Installed amd64, display pin | Sky1 udev/Xorg pin written every boot | none; arm64 unchanged |
| Installed O6N | 37.3 s (2026-10-04, before items D/F/G) | not changed by this branch; re-measure |

## 5. Detection audit (task 3)

| device class | detected by | when needed | longest wait on an absent device, after this change |
|---|---|---|---|
| NIC | net-pick in early_command (after the NIC udebs and `udevadm settle --timeout=5`) | netcfg, ~60 s later | link up: 5 s. No adapter: 10 s, then a message. Adapters without carrier: 20 s, then d-i netcfg's own 60 s link wait (d-i, unchanged: a late cable still works) |
| install medium (USB / disk) | early_command mount loop; `usb-rescan.sh` | before cdrom-detect | 0 s when present (O6N "waited 0s"). Up to 10 s plus the Sky1 USB2 rebind only when the medium is missing |
| target disks (NVMe, USB, SATA) | d-i disk-detect, NCZ disk chooser | partman | disk-detect 3 to 4 s measured; no wait on absent disks |
| display, installer | efifb / fbcon | first dialog | none |
| display, installed | `cix-detect-display` (all arches: connector wait; pin on Sky1 only), then greetd `ExecCondition` | greeter | bounded 30 s on a headless desktop, then greetd is skipped (console login unaffected). This is load-bearing; see C2 |
| input, installed | `ncz-wait-input-ready` (1 s), `ncz-usb2-rescan` (Sky1, 1 s grace) | greeter | 1 s |

## 6. Candidates, measured but not changed

| id | item | evidence | why not here |
|---|---|---|---|
| C1 | Preseed parsed twice by a fork-heavy shell loop | 2+2 s (PEGASUS), 6.6+6 s (CHIMERA), 11.5+13.5 s (O6N) before the first dialog. Moving the early_command body into a baked helper removes 36% of the non-comment lines and ~33% of the lower-bound parse time | Large rewrite of the most fragile value in the repo (size cliff, comment and escape traps, several tests pin its text). Needs a KVM install run, which this branch may not do |
| C2 | amdgpu starts probing at 7.6 to 7.9 s on CHIMERA (i915 at 4.3 s) and takes 2.7 s, so the greeter waits until ~10.3 s | three boots, kernel log | kernel / initramfs territory (amdgpu not in the initrd, late coldplug). kernelwatch-first, needs a full rebuild and a supervised boot |
| C3 | Installed rEFInd `timeout 10` on both amd64 hosts | PEGASUS loader 6.48 s (`systemd-analyze`) | operator-facing policy that `ncz-refind-refresh.sh` learns and preserves (BOOT-SPEED.md F7) |
| C4 | NetworkManager `startup complete` 7.7 s after the only real link activated | CHIMERA: lease 8.33 s, startup complete 16.04 s | needs NM debug logs to attribute (a cable-less second NIC's carrier wait vs the Wi-Fi scan). Changing NM log level on a live host was out of bounds |
| C5 | d-i startup with the kernel silent: 2 s (PEGASUS), 6.6 s (CHIMERA), 11.5 s (O6N) | syslog | stock d-i (templates load, 14 MB `templates.dat`, plus the initrd preseed parse). Only the preseed share (C1) is ours |
| D1 | `udpkg -i libc6-udeb` in early_command replaces the running libc: 31 x "Bus error" plus "Text file busy" in `sshd-watcher.sh`, first `sshd` start fails (`/etc/ssh` missing), watcher recovers at i=19 | O6N `early_command.log` 2026-10-06 | robustness bug in the diagnostic SSH bootstrap, not a timing item. Report to that owner |

## 7. How to verify on a rebuilt image

```sh
# installer (any arch): syslog markers, early_command log
grep -E 'preseed: running|Menu item|net-pick|selected .* after|No wired network adapter|ncz-clock' /var/log/syslog /var/log/early_command.log
# installed amd64
systemd-analyze; systemd-analyze critical-chain graphical.target
systemctl show NetworkManager-wait-online -p Environment     # NM_ONLINE_TIMEOUT=15
ls /etc/udev/rules.d/73-cixmini-primary-display.rules        # must NOT exist on amd64
tail -3 /var/log/ncz-display-detect.log                      # "x86_64: connected-output wait only"
```
