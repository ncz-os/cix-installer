# T2 DKMS re-sync: vendored t2smc and t2gmux to KaiT2en upstream HEAD

Date: 2026-10-05
Branch: `fix/t2-dkms-resync-20261005` (base `fix/t2-dkms-provenance-clamp-20261005`, tip `03a6040`)
Pinned upstream: `github.com/kaiT2en/KaiT2en-Fedora` HEAD
`a88f36f452676bdcf840a5d958478e49d221c384`, committed 2026-10-06T00:38:31+02:00
("Merge pull request #93 from turannul/patch-1"). Both modules below are vendored from that
one commit.

## 1. What changed, old to new

| module | previous vendored commit | new vendored commit | upstream commits since |
|---|---|---|---|
| t2smc | `6715ce61c5397a72d3463d86f13909b322af4603` (2026-09-05) | `a88f36f452676bdcf840a5d958478e49d221c384` (2026-10-06 HEAD) | 5, RTC rework only |
| t2gmux | `8760e41cd73fd736c3e5fb955ecc5fed49afee0d` (2026-09-28) | `a88f36f452676bdcf840a5d958478e49d221c384` (2026-10-06 HEAD) | 6, safety/power sequencing |
| t2smp | `72841efd0b67188b2ba3e64407dbabca1ed5901b` | unchanged | 0 |
| t2thunderbolt | `b1855a0a6cc6956f4d0545cb23a69da6d5611cbb` | unchanged | 0 |

`t2smp` and `t2thunderbolt` were **not touched**: upstream has no commits beyond their pinned
shas, and t2thunderbolt is still called unsafe both upstream and by t2linux. Their PROVENANCE
files are unchanged and still pass the provenance test.

Vendored C sources are byte-identical to upstream at `a88f36f`. The only local deltas are the
t2smc patch (external file, applied at DKMS build time) and metadata (PROVENANCE, README copy,
dkms.conf PATCH lines). sha256 of the vendored trees and files, the per-commit change list and
GitHub compare links are recorded in each `assets/kernel/<module>/PROVENANCE`.

### t2smc (`6715ce6..a88f36f`)

All five commits are the RTC rework, all dated 2026-10-05:

- `a299672` read the RTC through the `CLKL` latch and `CLKR` rate like AppleSMCRTC
- `ef538f9` only write `CLKO` when the RTC offset changed
- `0137d29` synchronize `CLKO` with the system clock before sleep and at shutdown
- `3772fcc`, `598fe57` chrony `rtcfile` integration (distro-side, see below)

Also `T2SMC_VERSION` 0.0.1 -> 0.0.2, new `T2SMC_RTC_LATCH`/`T2SMC_RTC_RATE` keys, new
`has_rtc_latch`/`rtc_offset`/`rtc_rate` fields, new suspend/shutdown PM ops and README/tools
additions. No fan or charge-limit changes.

### t2gmux (`8760e41..a88f36f`)

Six commits, 2026-09-29 .. 2026-10-05:

- `65af65f` follow macOS for 16,x dGPU power-up, gmux interrupts and the inactive eDP (the
  largest change, 190 lines; this is the 16,x path, which is our MacBookPro16,1)
- `952a2ee` on resume only power down a dGPU that is powered
- `60686dd` wait for the T2 mailbox and skip busy accesses like AppleMuxControl2
- `398dd08` keep the PCI core from suspending the bridges on `ports=native` (`pci_d3cold_disable`
  on the dGPU)
- `8f32b9c` block user config access across `PWRD` transitions, check the `PWRD` result
- `26fa944` add the transition lock

No new module parameters and no new sysfs/udev interface; the module exposes the same
vga_switcheroo handler, backlight and existing debugfs nodes as before.

## 2. Critical read of the new code

### t2smc RTC

- **Read path.** `t2smc_read_rtc_counter()` uses `t2smc_read_latched_counter()` when the SMC
  advertises `CLKL`, else the direct `CLKM` read. The latch exchange writes six `0xff` bytes,
  sleeps 20 ms, then polls `CLKL`; it retries and holds `t2->mutex` for the whole exchange.
  `CLKR` is read once at probe as the counter rate (default 32768 Hz, rejected if 0 or
  `U32_MAX`).
- **Write path.** `t2smc_write_rtc_key()` is now reached only from
  `t2smc_rtc_write_offset()`, which masks the offset to the signed 48-bit `CLKO` register and
  writes only when the offset moved by at least the tolerance. Calendar time is
  `(counter + CLKO) / CLKR`.
- **Writes at suspend/shutdown.** `t2smc_suspend()` and `t2smc_shutdown()` both call
  `t2smc_rtc_sync_from_system()`, which reads the counter and writes `CLKO` at nanosecond
  resolution. This is process context (device PM), so the msleep/usleep_range are legal. On
  failure it logs `failed to synchronize the RTC` and still returns 0, so it cannot fail or hang
  suspend. Worst case a latch exchange is bounded at roughly 0.5 s of retries while holding the
  SMC mutex.
- **Failure modes.** A machine with `CLKL` but a latch that never returns a valid value would
  make RTC reads fail with `-EAGAIN` after the retries; the T2 clock itself keeps running. A
  frequent `CLKL` reader holds the shared SMC mutex, which also serializes fan and temperature
  access, so a stuck exchange can delay a fan write by up to the retry bound.
- **chrony integration: what it installs/expects.** Nothing is installed by the module. The
  chrony integration is `scripts/fedora/install-rtc-sync.sh`, a Fedora-only script that writes a
  `kait2en-rtc-sync.service` running `chronyc waitsync 180 && hwclock --systohc --utc`. It is
  **not vendored and not installed by `post-install/56-t2-dkms.sh`**, so the image ships no
  chrony artifact. `tools/t2smc-rtc-client.c` is likewise not vendored and not built. The README
  now documents both, which is the only trace in the vendored tree.
- **dkms.conf/Makefile unchanged**; the module still installs only `t2smc.ko`.

### t2gmux

- **Power sequencing.** `__gmux_set_discrete_state()` now takes a `power_lock`, reinitialises the
  power completion, and on power-up runs `gmux_lock_dgpu_cfg()` around `PWRD(0)` and the state
  restore. The transition lock wraps the whole sequence. On power-down it saves state, calls
  `PWRD(1)`, then restores the port. `gmux_call_pwrd()` moves to `acpi_evaluate_integer` and
  warns when `PWRD(0)` returns nonzero (link did not train).
- **User config locking.** While `PWRD` moves the PEG link between L0 and L2, user-space config
  accesses (lspci, setpci, sysfs) to the dGPU, its HDA function and the bridges up to the root
  port are trylocked so they cannot hit a link that is neither up nor down. Kernel save/restore
  access is not blocked.
- **Mailbox.** `gmux_mmio_busy()` polls the command register once per millisecond for up to
  200 ms and reads/writes are skipped while the mailbox is busy (a skipped read returns
  `0xdeadbeef`/low byte), matching AppleMuxControl2.
- **Interrupts.** The `_L15` notify handler is replaced by a level-triggered GPE handler plus a
  work item; the GPE is enabled/disabled around handling and re-enabled after resume.
- **Resume.** Resume only powers a dGPU down again when `GMUX_PORT_DISCRETE_POWER & 3 == 3`.
- **ports=native vs compat.** `398dd08` calls `pci_d3cold_disable()` on the dGPU so the PCI core
  cannot runtime-suspend the GPU and the bridges below/above the root port while gmux owns the
  rail. The commit is written for `ports=native`; under `pcie_ports=compat` the PCI-core-driven
  runtime PM that this guards against is already suppressed, so the disable is harmless there.
  The image adding `pcie_ports=compat` to the T2 edge entry does not conflict with these fixes.
- **amdgpu runtime PM / vga_switcheroo.** The module drives dGPU power only through its existing
  vga_switcheroo handler; the changes serialize and guard transitions. `pci_d3cold_disable()`
  deliberately prevents d3cold on the dGPU, which can change amdgpu runtime-PM behaviour on T2
  hardware whose rail gmux controls. **Nothing in this item enables iGPU-only mux mode**; the
  operator's hold on iGPU-only mode is unaffected.

## 3. Risk assessment per behavioural change

| change | risk | why |
|---|---|---|
| t2smc `CLKL` latch read path | medium | new path on 16,1, holds the shared SMC mutex for up to ~0.5 s per exchange; can delay fan/temp access if CLKL misbehaves |
| t2smc `CLKO` write only on change | low | reduces SMC traffic; upstream masks to signed 48-bit |
| t2smc `CLKO` sync before sleep/shutdown | low-medium | best-effort, bounded, cannot fail suspend, but exercises an SMC write in the PM path |
| t2smc `CLKR` rate handling | low | guarded against 0/`U32_MAX`; default is the known rate |
| t2smc range-check patch rebase | low | behaviour preserved; RTC check is now defense-in-depth because upstream masks |
| t2gmux transition/power locks | low | serialization only; `lockdep_assert_held` documents nesting |
| t2gmux GPE handler rewrite | medium-high | replaces the interrupt path; directly in the area that took MEDUSA down |
| t2gmux mailbox busy handling | medium | skipped reads can return a sentinel value; callers must tolerate a non-value read |
| t2gmux `PWRD` result check | low | warning only; continues by design |
| t2gmux dGPU config trylock across `PWRD` | low-medium | prevents user access on a link that is neither up nor down; trylock avoids deadlock |
| t2gmux `pci_d3cold_disable` | medium | changes dGPU PCI/amdgpu runtime PM; intentional on T2 but observable |
| t2gmux resume power condition | low | narrower, more faithful to AppleMuxControl2 |

## 4. Build verification (no hardware, build only)

Built in a `debian:trixie` container on HYDRA (x86_64), `dkms 3.2.2`, gcc 14, against the
headers extracted read-only from MEDUSA `/usr/src` (the exact revisions requested; no matching
`.deb` for `-1-t2-edge-aerfix` was found on ARGONAS or in the apt repo):

- `linux-headers-7.2.9-2-t2-trixie`
- `linux-headers-7.3.0-rc6-1-t2-edge-aerfix`

Using the same path `post-install/56-t2-dkms.sh` uses (copy `src/` and `patches/` into
`/usr/src/<m>-<ver>`, `dkms add`, `dkms build`):

| module | 7.2.9-2-t2-trixie | 7.3.0-rc6-1-t2-edge-aerfix |
|---|---|---|
| t2smc (patched) | BUILD OK, vermagic correct | BUILD OK, vermagic correct |
| t2gmux | BUILD OK, vermagic correct | BUILD OK, vermagic correct |

- modpost clean; **no compiler warnings or errors** in either kernel's `make.log`.
- `modinfo`: license `GPL`, correct vermagic; t2gmux `depends: video`.
- The built `t2smc.ko` contains the range-check messages
  (`rejecting fan%d min ...`, `rejecting fan%d target ...`), proving the DKMS patch applied.
- Repo tests: `build/test-t2-dkms-provenance.sh` 20/20, `build/test-t2smc-range.sh` all cases
  passed (including the new `CLKO` normalize/wrap cases).
- No module was loaded, no SMC/gmux register written; MEDUSA was read-only (headers tar) and no
  GPU/PCI debugfs or register access was performed anywhere.

### Bug found and fixed in the previous pin

The t2smc hardening patch could never have applied under DKMS:

1. `dkms.conf` had `PATCH[0]="patches/0001-..."`, but DKMS 3.2.2 resolves each `PATCH[]` entry
   below its own `patches/` directory, so it looked for `patches/patches/0001-...` and died.
2. The patch used `src/t2smc.c` paths, but `56-t2-dkms.sh` flattens `assets/kernel/t2smc/src/`
   into the DKMS module root, so `patch -p1` could not find `src/t2smc.c`.

Either failure aborts `dkms build`, so the previously shipped image would have had **no t2smc**
(and therefore no fan control) on a real T2 install. Fixed on this branch: `PATCH[0]` is now the
bare file name and the patch is written for the flattened tree; `build/test-t2smc-range.sh` now
reproduces the DKMS layout instead of a `src/` scratch layout.

## 5. Hardware test plan (MacBookPro16,1) — for the operator

Do this on the **stable kernel** (`7.2.9-2-t2-trixie`, the default) first; do not take the edge
entry until the stable run is clean. No debugfs, no register reads, no GPU `power/control`,
`reset`, `remove`, `rescan`, vga_switcheroo or driver bind/unbind. `hwmon`, `power_state`,
`runtime_status`, `/proc`, `dmesg`, `journalctl` and `hwclock` are safe reads.

1. Baseline. Record `uname -r`, `dkms status`, `modinfo t2smc t2gmux`, and
   `dmesg | grep -iE 't2smc|gmux'`. Save the current PROVENANCE commit for rollback.
2. Install the new modules on the stable kernel only (`dkms install`), reboot.
3. Load/registration: `dmesg | grep -iE 't2smc|t2gmux|RTC registered|CLKL|PWRD'`. Expect
   `RTC registered (rate=32768 Hz, CLKL=enabled)` (or `CLKL=unavailable`), no `failed to
   synchronize the RTC`, no `PWRD ... link did not train`, no mailbox timeout.
4. Fans (thermal safety, the reason t2smc exists): `sensors` / `cat /sys/class/hwmon/*/name`
   and `fan1_input`/`fan2_input` should be plausible and non-zero under load. Write a moderate
   `fan1_target` and confirm it is accepted; confirm a deliberately out-of-range target is
   rejected with `EINVAL` and the log line appears. Do not drive extremes.
5. RTC: compare `hwclock --rtc /dev/rtc0 --show` with `date`; ensure the clock advances and is
   within a second. Optionally run the upstream `t2smc-rtc-client` for a minute to exercise the
   `CLKL` path, and watch for SMC timeouts or stalled hwmon reads.
6. Suspend/resume: `systemctl suspend`, wake, then `dmesg | grep -iE 't2smc|gmux|PWRD|CLKL'`;
   check clock drift across the sleep and that `failed to synchronize the RTC` did not appear.
7. Shutdown/reboot: confirm a clean shutdown and that the clock survives (T2 derives it from the
   SMC RTC while off).
8. dGPU: read `lspci -s <ddgpu>` presence, `cat /sys/bus/pci/devices/<ddgpu>/power_state` and
   `runtime_status` (plain reads). Do **not** force a GPU reset or a mux switch to exercise the
   power path. If the dGPU is absent (as after the MEDUSA event) these fixes cannot be exercised
   and the result is inconclusive.
9. Regression watch: fan-write latency while a `CLKL` reader is active, intermittent `EINVAL`
   on valid fan writes, display blanking during mux transitions, vga_switcheroo/amdgpu errors.

**Roll back if:** the machine fails to suspend or resume, the RTC gains/loses more than a few
seconds across a suspend, fan writes start failing, `PWRD`/mailbox timeouts or GPE interrupt
floods appear, or the dGPU behaves worse than on the previous pin. Rollback for `t2gmux` is the
previous PROVENANCE commit `8760e41`; for `t2smc` it is `6715ce6` (and note the old patch never
applied under DKMS, so rolling back t2smc also means shipping it without the range checks or
carrying the fixed patch on top of the old source).

## 6. Recommendation

- **t2gmux:** the previous module lacks exactly the transition lock and mailbox/PWRD guards that
  the MEDUSA dGPU loss implicates. The new code is the correct direction, but the GPE handler
  rewrite is unproven on hardware. Take it on the stable line **after** the test plan above; do
  not put it on the edge entry before the stable run passes.
- **t2smc:** the RTC rework is low-risk and fixes real clock behaviour, and the DKMS patch-path
  fix is strictly required for the hardening (and for t2smc to install at all). Take it on the
  stable line.
- Both are at most one hardware session away from being trustworthy; without that session the
  recommendation is "stage on stable, validate on the 16,1, then promote the edge entry".

## 7. What could not be verified without hardware

- Whether `CLKL` exists and behaves on the 16,1, and the real cost of the latch exchange on the
  SMC mutex under thermal load.
- Whether `CLKO` sync at suspend/shutdown actually sets the T2 clock, and whether any SMC write
  blocks in the PM path in practice.
- Whether the GPE-handler rewrite behaves on the 16,1 (interrupt flood, missed power
  completions, resume correctness).
- Behaviour with `pcie_ports=compat` versus `ports=native`, and the effect of
  `pci_d3cold_disable` on amdgpu runtime PM.
- dGPU power sequencing on a working dGPU; MEDUSA could not be used for this.

## 8. Files, branches, shas

Branch `fix/t2-dkms-resync-20261005` (base `03a6040`):

- `0ca5b26` — re-vendor t2smc/t2gmux to `a88f36f`, update both PROVENANCE and the t2smc
  README copy, rebase the range-check patch, extend the range test.
- `bae5a18` — fix the DKMS `PATCH[0]` path and the patch `-p1` layout, mirror the DKMS layout
  in `build/test-t2smc-range.sh`.
- `bf8e089` — this report.
- `38aa027` — review follow-up: make the CLKO normalize comment reference `T2SMC_RTC_BITS`.

Pushed to GitLab `ncz-os/cix-installer` as `fix/t2-dkms-resync-20261005`; no merge request,
no merge. The branch is based on `03a6040` and can be rebased/deleted without touching other
history.

## 9. Review

`zoder review --json --scope branch --base 03a6040`, run against a curated branch that carries
only the authored delta (patch, tests, PROVENANCE, dkms.conf and this report); the vendored
upstream blobs were excluded because they are upstream content and exceed the per-hunk review
limit. This report was split into three theme-sized files for the review snapshot only; the
deliverable is the single file above.

- Round 1 (`nvidia/nemotron-3-ultra-550b-a55b`): `request_changes`, 2 findings. One was a
  false positive — the reviewer misread the *diff of the patch file* as a hunk-header/function
  mismatch; the applied patch is correct (the DKMS build and the unit test both prove it). The
  other was a fair doc nitpick (`sign-extend from bit 47`), fixed in `38aa027`.
- Round 2 (`nvidia/nemotron-3-ultra-550b-a55b`): HTTP 429, 0/1 reviewers completed, no output.
- Round 2 retry (`MiniMax-M3`): `request_changes` with 5 findings, **all** "unparseable review
  (fail-closed)" — the model returned prose thinking instead of structured JSON (each body
  truncated at 8000 chars). No actionable finding.

Stopped there per the review budget: only a fixed nitpick and unparseable/truncated reviewer
output remain.
