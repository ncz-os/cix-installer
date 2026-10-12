# NCZ-OS capability tiers (`ncz-capability`)

Operator (2026-10-12): *"hardware profile these machines and have an algorithm
that ranks systems by capability and only enables what they can healthily do by
default."* The evidence that forced the design: **CYCLOPS** (`.89`, a 2011 Mac
mini with Intel HD 3000) runs the GUI, Chrome, video and the compositor effects
smoothly. So a tier is a **measurement**, never a guess from age or marketing
name.

* Tool: `assets/capability/ncz-capability` (Python 3, standard library only).
* Install hook: `post-install/65-capability-tier.sh`.
* Tests: `assets/capability/tests/test_capability.py` + `build/test-capability-tier.sh`.
* Output: `/etc/ncz/capability.json` (+ a human summary on stdout).

## 1. Tiers

| tier | name | meaning |
|---|---|---|
| **T0** | minimal | only what the machine can do without stutter |
| **T1** | low | reduced effects; the lite-profile class |
| **T2** | mid | the stock Singularity look (effects on) |
| **T3** | high | stock look plus the optional blur material |

The tier numbers are the contract; the names are free. T2 is deliberately
"stock": a machine that measures healthy keeps every effect it ships with
(corner radius, animations, dim, screensaver). T3 only *adds* the optional
background-blur material. T1/T0 only ever *reduce defaults*.

## 2. Inputs

Collected from `/proc` and `/sys` (plus optional `lspci`/`eglinfo`/`vulkaninfo`):

* **CPU** — model, physical cores, threads, max MHz, coarse micro-arch label.
* **RAM** — `MemTotal`, `MemAvailable`.
* **Storage** — root block device, rotational flag, bus (nvme/sata/usb).
* **GPUs** — per DRM/render card: vendor/device id, driver, VRAM, plus a
  detected renderer string and a `software` flag (`llvmpipe`/`softpipe`/
  `swrast`/`lavapipe`/`zink`). On arm64 the Mali node (`/dev/mali0`,
  `mali_kbase`) is added because the DRM card is the display controller.
* **Display** — connected outputs and their mode (total lit pixels).
* **Thermal / power** — AC online, battery present, maximum temperature and
  headroom.

### The short calibration (< 10 s)

| probe | how | unit |
|---|---|---|
| CPU single | SHA-256 throughput on one thread (C-level, stable across Python versions) | MiB/s |
| CPU multi | the same across `min(cores,32)` threads until a shared deadline | MiB/s |
| disk 4k | random 4k reads on the root filesystem after evicting the page cache (`fadvise DONTNEED`, `drop_caches` when root) | µs, median |
| GPU | a full-screen 160-iteration shader fill at 1280×720 on a GBM pbuffer, synced with a 1-pixel `glReadPixels` every frame (a plain `glFinish` returns before retirement on tile-based Mali and read a real fill as 0.1 ms) | ms/frame |

If the GPU bench cannot run (no EGL, a locked-down driver), the renderer string
from `eglinfo -B` and a class table seed the GPU subscore instead, and the JSON
records `gpu_measured=false` so the difference is visible.

## 3. Scoring (deterministic)

Each metric maps to a 0..100 **rung** by piecewise-linear interpolation between
anchors (`assets/capability/ncz-capability`, "Scoring constants"). Subscores are
combined with fixed weights:

```
cpu 30   gpu 30   mem 10   storage 15   display 8   thermal 7
```

`display` scores *headroom*: a smaller lit-pixel count is lighter compositor
work. A headless machine scores a neutral 65 (neither a penalty nor a bonus).
`thermal` uses the headroom to the throttle point, ±8 for AC/battery.

```
score -> tier   T3 >= 72   T2 >= 48   T1 >= 24   else T0
```

### min-of-subsystem gating

The score is an upper bound. A weak subsystem **caps** the tier no matter how
fast the rest is (`score()` returns the `caps` list):

| condition | cap |
|---|---|
| a software renderer in the display path | **T1** |
| measured GPU ≥ 50 ms/frame | T1 |
| root disk rotational, or 4k read ≥ 4000 µs | **T1** |
| installed RAM < 3072 MiB | T1 |
| installed RAM < 1536 MiB | T0 |

A cap only ever *lowers* the tier. This is what keeps a fast CPU with a
spinning disk, or a strong CPU behind llvmpipe, out of T3.

## 4. Feature map (tier → defaults)

Data file: `assets/capability/capability-features.tsv`. Three kinds:

* `gsetting` → a **system default** via a validated
  `99-ncz-capability.gschema.override` next to the installed schema. A user's
  own `gsettings set` still wins (standard GSettings precedence).
* `env` → written to `/etc/environment.d/60-ncz-capability.conf`, read by the
  lock-saver feed and the thermal governor.
* `flag` → written to `/etc/ncz/capability/features.env`, consumed by wrappers
  (boot splash; indexer).

| area | key | T0 | T1 | T2 | T3 |
|---|---|---|---|---|---|
| compositor | `background-effect` | disabled | disabled | disabled | blur |
| compositor | `blur-strength` | 0 | 0 | 60 | 60 |
| compositor | `window-transparency` | 0 | 0 | 12 | 12 |
| compositor | `window-rounded-corners` | false | false | true | true |
| compositor | `reduce-motion` | true | true | false | false |
| compositor | `motion-duration-scale` | 0.1 | 0.5 | 1.0 | 1.0 |
| compositor | `idle-dim-screen` | false | false | true | true |
| compositor | `allow-tearing` | true | true | false | false |
| tour | `show-tour` (first-login animations) | false | false | true | true |
| screensaver | `pool-gpu-class` (eligible set) | weak | weak | mid | all |
| screensaver | `render-scale-mode` / `render-scale` | fixed/0.5 | fixed/0.5 | auto/1.0 | auto/1.0 |
| screensaver | `max-render-height` | 480 | 720 | 1080 | 0 |
| screensaver | `gpu-offload` | off | off | auto | auto |
| screensaver | `show-all-hacks` | false | false | false | true |
| saver feed | `NCZ_SAVER_LOCK_FPS` | 4 | 6 | 8 | 12 |
| saver feed | `NCZ_SAVER_RENDER_DIV` | 4 | 2 | 2 | 1 |
| saver feed | `NCZ_SAVER_FREEZE_AFTER_S` (intro length) | 8 | 12 | 15 | 20 |
| thermal governor | `NCZ_FEED_TEMP_WARM_MC` / `_HOT_MC` | 65/75 °C | 70/80 °C | 75/85 °C | 75/85 °C |
| boot splash | `CAPABILITY_SPLASH` | off | lite | full | full |
| background load | `CAPABILITY_INDEXER` | off | lite | full | full |

`NCZ_SAVER_FREEZE` (freeze after the intro) is **not** varied: the operator
policy of 2026-10-12 is "freeze on every system", and the capability tier only
changes how long the intro runs (`_FREEZE_AFTER_S`). The boot splash "off"
means the wrapper skips painting — the unit stays enabled, so this is a default,
not a disabled feature.

## 5. Overrides

Precedence, highest first:

1. `ncz-capability apply --tier T2` (explicit CLI pin).
2. `/etc/ncz/capability.override`:

   ```ini
   # force a tier, or any single feature
   tier = T1
   feature.screensaver.render-scale = 0.25
   gsetting.dev.sinty.desktop:blur-strength = 0
   env.NCZ_SAVER_LOCK_FPS = 8
   flag.CAPABILITY_SPLASH = lite
   ```
3. the measured tier.

A user's own `gsettings set` always wins over the system default for that key,
and the preference schema `dev.ncz.capability` (`tier = auto|t0..t3`) records
intent for a future Settings row.

## 6. Wiring

* **First boot** — `ncz-capability.service` (oneshot, enabled by the hook) runs
  `probe` then `apply` once, gated on `ConditionPathExists=!/etc/ncz/capability.json`.
  It runs `Nice=15`, `IOSchedulingClass=idle`, `TimeoutStartSec=120`, so it is
  never on the critical path. If the profiler fails, `probe` writes nothing and
  `apply` falls back to the built-in T2 default (the shipped schema defaults),
  so a machine is never left worse than stock.
* **Hardware change** — `ncz-capability-recheck.service` runs `detect`, which
  re-probes only when the recorded signature (GPU ids/driver, RAM, root block
  device, display connectors, CPU model) differs. It is started by a udev rule
  when a DRM card appears and by `ncz-capability-recheck.timer` (5 min after
  boot, then daily) as a backstop for RAM/CPU/disk changes udev does not
  announce. Both are cheap and only write defaults.
* **Never during a high-cost moment** — the only expensive step is the <10 s
  calibration at first boot and on a real hardware change; the daily timer runs
  `detect`, which is a no-op on an unchanged machine.

## 7. Safety

* **Defaults only.** `apply` writes a GSettings override, an
  `/etc/environment.d` file and a feature file. It never touches a user's dconf,
  never uninstalls, and the only service state it changes is a four-unit
  background-indexer allowlist, disabled at T0 and re-enabled at T2/T3 (tracked
  in `/etc/ncz/capability/service-state`, never masked).
* **Validated before install.** The GSettings override is compiled with
  `glib-compile-schemas --strict --dry-run` on a scratch copy first, exactly
  like hooks 62/64; a body that cannot compile is not installed.
  `ncz-capability check` performs the same validation against the **live**
  installed schemas and changes nothing, so a host can be checked safely before
  any default is written.
* **Fail-safe.** Every probe is best-effort; missing tools fall back and the
  JSON records what was measured. `ncz-capability` never raises on a machine
  without a GPU output (headless / KVM / PROTEUS) and never reboots.
* **Arch-neutral.** amd64 and arm64 (Sky1 Mali). O6N is scored and the result
  recorded, but arm64 applies the same defaults as any measured tier.

## 8. Validated fleet ranking

Measured with `ncz-capability probe` on the test fleet (see
`captier/REPORT.md` for the raw JSON and the before/after smoothness metrics):

| machine | class | tier | operator verdict |
|---|---|---|---|
| CHIMERA `.6` | MacBookPro16,1 i9 + Radeon 5500M | T3 | — |
| PEGASUS `.85` | ROG GU502LV i7 + RTX 2060 | T3 | — |
| MEDUSA `.38` | MacBookPro16,1 i7 + Radeon | T3 | — |
| O6N `.3` | CIX Sky1, Mali-G720 | (recorded) | arm64, no behaviour change |
| PROTEUS `.68` | headless Arrow Lake | T2+ | headless, no crash |
| CYCLOPS `.89` | Mac mini 5,1 HD 3000 | T2 | **smooth → effects stay on** |
| Inspiron `.70` | Dell 5522 i7 HD 4000 + SSD | T2 | — |

Tiers are filled from the hardware run; the fixtures under
`assets/capability/fixtures/` pin CYCLOPS and `.70` at T2 in the regression
test so the "measured, not guessed" rule cannot silently regress.
