# T2 Mac CPU package power cap (load-triggered hard power cut)

**Status:** shipped as post-install hook `64-t2-power-cap.sh` (branch
`fix/t2-power-cap-20261011`). Operator mission 2026-10-11 ("stop the T2
MacBookPro16,1 hard power cuts by capping CPU package power").

## The bug

On the Apple T2 MacBookPro16,1 (CHIMERA = i9-9980HK, MEDUSA = i7-9750H) the
firmware ships Intel RAPL package power limits of **PL1 = 100 W / PL2 = 125 W**
with turbo enabled and `intel_pstate/max_perf_pct = 100`. Under a sustained
all-core load the package alone draws more than the power delivery path can
supply (the battery's current limit on battery; the 96 W charger plus the
always-on Navi 14 dGPU on AC), and the SMC/BMS protection **cuts all power
instantly**. The machine goes dark with no clean shutdown and nothing in the
journal; the prior boot ends mid-line. It is not a thermal trip (fans/temps are
normal at the cut) and not a worn battery.

This is the load-triggered cut, distinct from our T2 7.3 **boot-time** cut
(16-27 s after `Booting OS`) investigated separately (MNEMOS
`project_t2_73_powercut_handoff_2026_10_04`, mem_1791153431205_d3fa8b;
amd64-kernel-t2 `docs/`). The AER revert decision and the iGPU/gmux hang
(omacom/omarchy issue #9609) are separate hypotheses and are unaffected.

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
  machines (`constraint_0_max_power_uw = 45 W`, read live on CHIMERA and MEDUSA
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

## Verification

`build/test-t2-power-cap.sh` (31 assertions) runs the hook and helper against a
**fake sysfs tree**: battery/AC numbers, the read-only ceiling is never written,
restore, idempotency, `performance` and `C=0` opt-outs, the product DMI gate,
the bounded wait for a late `intel-rapl:0`, `--strict`, and registration.

## Adding `rasdaemon` (MCE persistence)

The CHIMERA boot log carried a leftover uncorrected machine check (banks 12/13,
status `ee0000000040110a`) consistent with a prior hard power cut; there is no
MCE persistence package on the images today. `mcelog` is **not** in Debian
forky (checked against the pinned snapshot index 2026-10-05); `rasdaemon`
0.8.4-2 **is** (main/amd64, deps present). It is added to the amd64 closure
(`manifests/desktop-amd64.pkgs`) so it is available offline and its provenance
stays forkyd ([more in the mission report](../../oc-mission-20261010/t2powercap/REPORT.md)).
