# T2 Mac CPU package power cap (load-triggered hard power cut)

**Status:** shipped (26.10) as post-install hook
`post-install/64-t2-power-cap.sh`. Goal: stop the T2 MacBookPro16,1 hard power
cuts by capping CPU package power.

## The bug

On the Apple T2 MacBookPro16,1 (tested on an i9-9980HK and an i7-9750H unit) the
firmware ships Intel RAPL package power limits of **PL1 = 100 W / PL2 = 125 W**
with turbo enabled and `intel_pstate/max_perf_pct = 100`. Under a sustained
all-core load the package alone draws more than the power delivery path can
supply (the battery's current limit on battery; the 96 W charger plus the
always-on Navi 14 dGPU on AC), and the SMC/BMS protection **cuts all power
instantly**. The machine goes dark with no clean shutdown and nothing in the
journal; the prior boot ends mid-line. It is not a thermal trip (fans/temps are
normal at the cut) and not a worn battery.

This is the load-triggered cut, distinct from our T2 7.3 **boot-time** cut
(16-27 s after `Booting OS`) investigated separately
(in the kernel development notes). The iGPU/gmux hang (omacom/omarchy issue
#9609) is a separate issue and is unaffected.

Prior art (the fix this is modelled on): omacom/omarchy issue **#13295**, PR
**#14987** — same machine, same cut, field-confirmed fixed by capping the RAPL
package limits.

## The fix

`/usr/local/sbin/ncz-t2-power-cap` applies a policy chosen from the AC state:

| state | PL1 | PL2 | no_turbo | max_perf_pct |
|---|---|---|---|---|
| battery | 25 W | 35 W | 1 | 50 |
| AC (default) | 45 W | 60 W | 0 (firmware) | 100 (firmware) |

* **Battery** is the field-proven conservative policy (12 days upstream with no
  cut). On battery the whole machine runs off the pack, so the cap must sit
  well below the ~15-18 W the always-on dGPU + platform already drain.
* **AC** is capped too, because a cut was observed **on AC** at the firmware
  100/125 W limits. 45 W is the firmware's own read-only PL1 ceiling on these
  machines (`constraint_0_max_power_uw = 45 W`, read live on both test machines
  2026-10-11), so it is a value the firmware itself accepts. Turbo and
  `max_perf_pct` are left at the firmware values so a build host keeps
  throughput.

Applied from four places so it survives every transition:

* **boot** — a udev rule on the `powercap` `intel-rapl:0` **`add`** event. This
  is the crucial one: `intel_rapl_common` registers `intel-rapl:0` **late**
  (~21.8 s) while udev coldplug fires the Mains `add`/`change` event **earlier**
  (~19.7 s), so a helper that only ran at the Mains event finds no zone and the
  machine boots uncapped (upstream hit exactly this). The helper also waits
  (bounded) for the zone.
* **plug/unplug** — the same udev rule on the Mains `change` event.
* **resume** — `/usr/lib/systemd/system-sleep/ncz-t2-power-cap` (a resume emits
  no Mains change event).
* **thermald** — `/etc/systemd/system/thermald.service.d/10-ncz-t2-power-cap.conf`
  runs the cap in `ExecStartPre`, because `thermald --adaptive` remembers the
  PL1 it read at startup and rewrites it after every 95 °C excursion and on
  stop. Starting thermald on top of the cap makes its remembered value the cap.

The helper writes `constraint_N_power_limit_uw` — **never**
`constraint_N_max_power_uw`, which is the read-only ceiling (writing it silently
no-ops; upstream shipped a broken cap for days because of this).

## Policy override and opt-out — `/etc/ncz/power-cap.conf`

The hook writes a default config once and never overwrites an operator's edits.
Edit it and re-run `sudo ncz-t2-power-cap apply` to change live (no reboot):

```
NCZ_T2_POWER_CAP=0            # disable every write
NCZ_T2_POWER_MODE=default     # battery + AC capped (recommended)
NCZ_T2_POWER_MODE=performance # AC UNCAPPED (firmware 100/125 W); battery still capped
NCZ_T2_POWER_MODE=disabled    # same as CAP=0
NCZ_T2_POWER_FORCE=1          # also enforce on non-MacBookPro16 T2 Macs
```

`performance` is the documented opt-out for a machine the operator is willing
to risk a cut on under sustained load (e.g. a build host). The battery cap is
kept in every mode as the safety floor.

Values are W / integer percent; the per-state PL1/PL2/no_turbo/max_perf and the
firmware (restore) values are all keys in the file.

## Scope and reversibility

Installed on any Apple T2 machine with an `intel_pstate` CPU; the helper
**enforces by default only when `product_name` is `MacBookPro16*`** (the
documented-affected machine). Other T2 Macs need `NCZ_T2_POWER_FORCE=1`. A
non-T2 machine, or a T2 machine with no RAPL package zone, is a no-op. The
whole feature is idempotent and never fails boot (`apply` exits 0 even when a
write fails; `--strict` is available for tests/manual use).

Reversible: `sudo ncz-t2-power-cap restore` writes back the values captured
before the first write this boot (`/run/ncz-t2-power-cap.baseline`), or the
firmware values from the config when no baseline exists.

## Lock-screen saver thermal cap

The lock-hosted saver renderer (`ncz-feed-render`, ncz-screensavers) reads the
hottest `coretemp`/`amdgpu`/`t2smc`/`k10temp`/`acpitz` hwmon sensor once a
second. From 75 C it renders at the warm frame rate; at the hot threshold it
pauses and holds the last frame, and it resumes 5 C below that threshold. The
compiled-in hot threshold is 85 C. On MacBookPro16,1 the dGPU is always on and
the CPU idles warm, so 85 C is reached in ordinary use and the lock-screen saver
stays almost still.

On T2 Macs the same hook (`post-install/64-t2-power-cap.sh`) raises it, in
`/etc/ncz/lock-renderer.env`:

| setting | value | compiled-in |
|---|---|---|
| `NCZ_FEED_TEMP_HOT_MC` | 100 C, or 2 C under the lowest critical trip of those sensors when it is at or below 100 C (98000 on MacBookPro16,1) | 85000 |
| `NCZ_FEED_FPS_WARM` | 6 | 15 |
| `NCZ_SAVER_AUTO_FPS` | 15 (what Auto means for the saver frame rate; full resolution is kept, and the Settings page warns before a higher rate is used) | 30 |

Up to 100 C is normal on these Macs. Measured on both MacBookPro16,1 units
(i9-9980HK and i7-9750H):

- `coretemp` `temp*_max` = `temp*_crit` = 100 C: Tjmax with TCC offset 0, so
  the CPU throttles itself at 100 C. The package/core `thermal_throttle`
  counters advance in ordinary use and advanced during the runs below (i9
  package 1600 -> 3497, i7 76 -> 89).
- Shutdown-class trips are all above 100 C: `amdgpu` junction crit 105 C
  (emergency 110 C), edge crit 110 C (emergency 115 C), PCH thermal zone
  critical trip 120 C. The `x86_pkg_temp` zone has no enabled trip.
- coretemp reports Tjmax itself as its `crit`, which is at 100 C, so the cap
  sits 2 C under it: 98 C, resume at 93 C.
- The package temperature moves 10-14 C within one second under turbo bursts,
  so the reading that trips the pause overshoots the threshold; at 98 C the
  pause readings were 98-100 C. The CPU's own Tjmax throttling covers that.
- Live lock runs, saver kept animating (freeze off), 5 minutes, test stopped if
  any sensor reached its critical - 5 C (none did at 98 C):

| hot threshold | i7: frames distinct | i9: frames distinct | i9: pause readings |
|---|---|---|---|
| 85 C | 33 / 75 | 27 / 42 | 85-99 C |
| 98 C | 75 / 75 | 75 / 75 | 98-100 C |

The 85 C i9 run was an earlier one stopped at critical - 10 C after 168 s.

The lock policy has no timer freeze: the saver keeps animating until input
raises the unlock prompt, so this cap is what keeps an unattended saver moving
on these Macs. At 85 C it pauses most of the time; at 98 C it animated for the
whole 5-minute runs above.

The lines are written only when `lock-renderer.env` already names a lock
renderer (`post-install/64-ncz-lock-saver-plan.sh`). A value already in the file
is kept. If no critical trip can be read at install time, the measured
MacBookPro16,1 value is used on that model and other models keep the default.
Delete the two lines (and log in again) to go back to the compiled-in values.

## Verification

`build/test-t2-power-cap.sh` (47 assertions) runs the hook and helper against a
**fake sysfs tree**: battery/AC numbers, the read-only ceiling is never written,
restore, idempotency, `performance` and `C=0` opt-outs, the product DMI gate,
the bounded wait for a late `intel-rapl:0`, `--strict`, the saver thermal cap
(100 C, 2 C under a critical trip at or below 100 C, operator value kept, no renderer = no
change, model fallback, unwritable file reported), and registration.

## Adding `rasdaemon` (MCE persistence)

The i9 test machine's boot log carried a leftover uncorrected machine check (banks 12/13,
status `ee0000000040110a`) consistent with a prior hard power cut; there is no
MCE persistence package on the images today. `mcelog` is **not** in Debian
forky (checked against the pinned snapshot index 2026-10-05); `rasdaemon`
0.8.4-2 **is** (main/amd64, deps present). It is added to the amd64 closure
(`manifests/desktop-amd64.pkgs`) so it is available offline and its provenance
stays traceable to forky.
