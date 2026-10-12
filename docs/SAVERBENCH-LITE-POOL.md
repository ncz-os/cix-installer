# saverbench — which screensavers run well on old GPUs (HD4000 / HD3000)

**Operator request (2026-10-12):** *"find what other classics perform well"* after
litebase found `fractasia` / `hypertorus` / `xshadertoy_hexplasma` hold 60 fps
native on the HD 4000.

**Author:** opencode / deepseek-flash. **Mode:** autonomous, unattended.
**Hosts:** `.70` = **ncz-biham-1109** (Dell Inspiron 5521, i7-3537U Ivy Bridge,
**Intel HD 4000**, Gen7, 1366×768) and `.89` = **ncz-elnath-6067** (Macmini5,1,
i5-2415M Sandy Bridge, **Intel HD 3000**, Gen6, 1600×900, display via
`ncz-vsfix.service`). Both run **NCZ-OS 26.10 Cygnus RC5 `2026.10.12-fd89fd11`**,
kernel `7.3.0-rc7-t2-ncz`, **Mesa 26.1.6** (OpenGL 4.2 core / **OpenGL ES 3.0**),
**`ncz-screensavers 0.8.12`** (74 installed savers).
**Leases:** `.70` `inspiron` and `.89` `192.168.207.89`, via `tools/lockrig/lease.sh`
(both held one at a time, both released at the end).

---

## 1. Headline

* **Every one of the 11 shipped "classics" holds a solid 60 fps at native
  scale on both the HD 4000 and the HD 3000** — no scaling, no compile errors
  (one exception state: `klein` is still catalogue-flagged *suspect*).
* **`fractasia` also holds 60 fps native on both** (part of the operator's
  lite pool); **`xshadertoy_hexplasma` holds 60 fps native on both**.
* **`blackhole` must be scaled** (0.5 on HD 4000, 0.25 on HD 3000);
  **`magmasimplex` is unusable** — it stalls the GPU on HD 4000 and stutters on
  both (p95 ≈ 6 s).
* **The whole `hyprsaver` family (30 savers) is `exclude` on Gen6/Gen7**: every
  one fails to compile (`GLSL ES 3.20 is not supported … 3.00 ES`).
* Recommended **lite-class default pool = 19 savers** (the intersection that is
  `pool` on *both* GPUs): the 11 classics + `fractasia` + 7 xshadertoy
  (`hexplasma`, `neonhorizon`, `elementalring`, `neongravity`,
  `logarithmiccircles`, `trainmandala`, `truchetzoom`).

**Method note (important).** Every number below is **measured on the live
desktop session** (the path the desktop screensaver uses), not estimated.
Measurement is done by running the installed saver binary directly under the
session (`/usr/lib/ncz-screensavers/<id>`) with a **fixed** render scale
(`NCZ_RENDER_SCALE_MODE=fixed`, `NCZ_RENDER_SCALE={1.0,0.5,0.25}`), for a warm-up
plus ≥8–12 s of steady state, reading the harness's own `[stats]` steady-state
`p50`/`p95` swap-to-swap frame times, plus the process CPU%. The lock's 8 fps
policy is *not* applied — this is what the GPU **can** do. See §6 for the
separate **off-screen / lock-feed** cross-check and its caveats.

---

## 2. Recommended lite-class default pool (`verdict = pool`)

A saver is `pool` when it reaches **≥30 fps with p95 ≤40 ms at native scale**
(and produced content, no fatal compile error). The operator's intended
"lite-class default pool" should be the set that works on **both** weak GPUs
(the weaker HD 3000 is the binding constraint):

**Pool on BOTH hosts (19):**

| saver | family | HD4000 native | HD3000 native |
|---|---|---:|---:|
| `fractasia_gles3` | Fractasia | 60.2 / 17.1 | 60.1 / 16.8 |
| `cityflow_gles3` | Classics | 60.2 / 16.8 | 60.1 / 16.7 |
| `crackberg_gles3` | Classics | 60.2 / 16.9 | 60.1 / 16.7 |
| `cubestorm_gles3` | Classics | 60.2 / 16.9 | 60.1 / 16.7 |
| `datatowers_gles3` | Classics | 60.2 / 16.8 | 60.1 / 16.7 |
| `geodesic_gles3` | Classics | 60.2 / 16.9 | 60.1 / 16.8 |
| `hexstrut_gles3` | Classics | 60.2 / 16.8 | 60.1 / 16.7 |
| `hypertorus_gles3` | Classics | 60.2 / 16.9 | 60.1 / 16.7 |
| `klein_gles3` | Classics | 60.2 / 17.0 | 60.1 / 16.7 |
| `noof_gles3` | Classics | 60.2 / 16.9 | 60.2 / 16.6 |
| `projectiveplane_gles3` | Classics | 60.2 / 16.8 | 60.1 / 16.7 |
| `voronoi_gles3` | Classics | 60.2 / 16.6 | 60.1 / 17.2 |
| `xshadertoy_elementalring_gles3` | xshadertoy | 60.2 / 16.7 | 30.1 / 33.5 |
| `xshadertoy_hexplasma_gles3` | xshadertoy | 60.2 / 16.8 | 60.1 / 16.7 |
| `xshadertoy_logarithmiccircles_gles3` | xshadertoy | 60.2 / 16.9 | 60.1 / 16.8 |
| `xshadertoy_neongravity_gles3` | xshadertoy | 60.2 / 16.6 | 30.1 / 33.3 |
| `xshadertoy_neonhorizon_gles3` | xshadertoy | 60.2 / 16.7 | 60.1 / 16.7 |
| `xshadertoy_trainmandala_gles3` | xshadertoy | 60.2 / 16.8 | 60.1 / 16.7 |
| `xshadertoy_truchetzoom_gles3` | xshadertoy | 60.2 / 16.7 | 60.1 / 16.7 |

*(`elementalring` and `neongravity` land exactly on the HD 3000 bar at
30.1 fps / p95 ≈33 ms — pool, but the first to drop if the bar is tightened.)*

**Pool on HD 4000 only (6 more xshadertoy), `scaled` on HD 3000:**
`xshadertoy_bestill5-0`, `xshadertoy_darktransit`,
`xshadertoy_goldenapollian`, `xshadertoy_neontriangulator`,
`xshadertoy_protophore`, `xshadertoy_trizm`.

So: **HD 4000 pool = 25** (11 classics + Fractasia + 13 xshadertoy);
**HD 3000 pool = 19**.

---

## 3. The `scaled` lists (needs a lower render scale for 30 fps)

`min_scale_for_30fps` is the smallest render divisor that still reaches
≥30 fps / p95 ≤40 ms. `blackhole` is the only non-xshadertoy that needs scaling.

**HD 4000 (`ivb-hd4000`) — 17 savers:**

| saver | scale | native fps |
|---|---|---:|
| `blackhole_gles3` | 0.5 | 12.0 |
| xshadertoy `alienbeacon` | 0.5 | 30.1 |
| xshadertoy `batteredplanet` | 0.5 | 20.1 |
| xshadertoy `bestill0-0` | 0.5 | 12.0 |
| xshadertoy `bestill1-0` | 0.5 | 10.0 |
| xshadertoy `bestill2-0` | 0.25 | 7.5 |
| xshadertoy `bestill3-0` | 0.5 | 10.0 |
| xshadertoy `bestill4-0` | 0.25 | 6.7 |
| xshadertoy `fluxcore` | 0.25 | 12.0 |
| xshadertoy `gimbalharmonics` | 0.5 | 20.1 |
| xshadertoy `noxfire` | 0.5 | 8.6 |
| xshadertoy `polarnight` | 0.25 | 4.3 |
| xshadertoy `prococean` | 0.5 | 30.1 |
| xshadertoy `rigrekt` | 0.5 | 10.0 |
| xshadertoy `skyline` | 0.25 | 6.0 |
| xshadertoy `starnest` | 0.5 | 30.1 |
| xshadertoy `topologica` | 0.5 | 20.1 |

**HD 3000 (`snb-hd3000`) — 19 savers:**

| saver | scale | native fps |
|---|---|---:|
| `blackhole_gles3` | 0.25 | 4.6 |
| xshadertoy `alienbeacon` | 0.5 | 10.0 |
| xshadertoy `batteredplanet` | 0.25 | 5.0 |
| xshadertoy `bestill0-0` | 0.25 | 5.0 |
| xshadertoy `bestill1-0` | 0.25 | 4.0 |
| xshadertoy `bestill2-0` | 0.25 | 3.5 |
| xshadertoy `bestill3-0` | 0.25 | 4.0 |
| xshadertoy `bestill5-0` | 0.5 | 20.0 |
| xshadertoy `darktransit` | 0.5 | 30.1 |
| xshadertoy `downfall` | 0.25 | 3.0 |
| xshadertoy `gimbalharmonics` | 0.25 | 5.5 |
| xshadertoy `goldenapollian` | 0.5 | 20.0 |
| xshadertoy `noxfire` | 0.25 | 3.2 |
| xshadertoy `prococean` | 0.5 | 8.6 |
| xshadertoy `protophore` | 0.5 | 8.6 |
| xshadertoy `rigrekt` | 0.25 | 4.0 |
| xshadertoy `starnest` | 0.5 | 10.0 |
| xshadertoy `topologica` | 0.25 | 6.7 |
| xshadertoy `trizm` | 0.5 | 15.0 |

---

## 4. Cross-check of the 12 kept classics (explicit)

The operator's "12 classics" (per `docs/CLASSICS-SHADER-PORT.md`: 9 shader
ports + `hypertorus`, `klein`, `projectiveplane`) — named one by one:

| # | classic | id as shipped | HD4000 | HD3000 | verdict |
|---|---|---|---|---|---|
| 1 | Voronoi | `voronoi_gles3` | 60.2 | 60.1 | **pool** |
| 2 | Gravitywell | — | — | — | **excluded / not installed**: displaced by `xshadertoy_neongravity` (catalogue `PROVENANCE.tsv`: *displaced-by:xshadertoy_neongravity*, 0.8.2) |
| 3 | Hexstrut | `hexstrut_gles3` | 60.2 | 60.1 | **pool** |
| 4 | Cubestorm | `cubestorm_gles3` | 60.2 | 60.1 | **pool** |
| 5 | Crackberg | `crackberg_gles3` | 60.2 | 60.1 | **pool** |
| 6 | Cityflow | `cityflow_gles3` | 60.2 | 60.1 | **pool** |
| 7 | Noof | `noof_gles3` | 60.2 | 60.2 | **pool** |
| 8 | Geodesic | `geodesic_gles3` | 60.2 | 60.1 | **pool** |
| 9 | Gibson | `datatowers_gles3` | 60.2 | 60.1 | **pool** *(ships as "Data Towers"; id renamed, source is `cs_gibson.c`)* |
| 10 | Hypertorus | `hypertorus_gles3` | 60.2 | 60.1 | **pool** |
| 11 | Klein | `klein_gles3` | 60.2 | 60.1 | **pool** *(catalogue still flags it `suspect`)* |
| 12 | Projectiveplane | `projectiveplane_gles3` | 60.2 | 60.1 | **pool** |

**So 11 of the 12 are shipped and all 11 are `pool` at native 60 fps on both
GPUs.** The canonical twelfth (`gravitywell`) is not installed in 0.8.12 — it was
replaced by the in-house `xshadertoy_neongravity` classic port; the classic set
shipped is therefore 11, and `neongravity` itself is also `pool` on both.

No classic needs scaling and no classic is `exclude`.

---

## 5. GLES / desktop-GL features absent on Gen6/Gen7

| savers | requirement | Gen6/Gen7 | result |
|---|---|---|---|
| **all 30 `hyprsaver_*`** | `#version 320 es` (GLSL **ES 3.20**) | cap = **ES 3.00** | **compile failure** on every shader: `0:1(10): error: GLSL ES 3.20 is not supported. Supported versions are: 1.00 ES, and 3.00 ES` → the harness exits, **no frames** → `exclude` on both hosts |
| **`fractasia_gles3`** (optional families) | ES 3.20 for `escape_time.frag`, `multibrot.frag`, `burning_ship.frag` | cap ES 3.00 | those optional fractal families fail to compile and are **disabled**, but the main shader compiles and renders at **60 fps** → still `pool` (recorded as a partial-warning, not a failure) |
| `xshadertoy_*`, classics, blackhole, magmasimplex | ES 3.00 | OK | compile and run |

**No saver in the installed 0.8.12 set needs desktop GL or GLES >3.0 except the
32 sources noted above** (30 hyprsaver + 3 fractasia optional passes). This
matches (and extends) litebase's finding that the hyprsaver family cannot run on
an ES 3.0 part.

---

## 6. Off-screen / lock-feed path cross-check (and its caveats)

The lock renders the saver **off-screen** through
`/usr/libexec/ncz-screensaver-feed` + `src/ncz_feed_render.c`, which uses
**EGL surfaceless** (no compositor, no window system) and then `glReadPixels` +
swizzle into a memfd. That path was driven directly (`offscreen.py`, speaking the
same `lock_framesrc_proto.h` wire protocol: HELLO→WELCOME→FRAME→READY) for all
74 savers on `.70`. Raw data: `off70.jsonl`.

Findings:

* It is **compositor-independent and robust** (it worked even while the desktop
  compositor was wedged), which is a genuine advantage for a headless bench.
* But it **underestimates** and has **false negatives**: for several savers the
  off-screen read-back came back all-zero (rendered *black*): `fractasia`,
  `noof`, `magmasimplex`, `xshadertoy_bestill0-0/1-0/3-0`, `darktransit`,
  `rigrekt`. All of these render fine on-screen (e.g. `fractasia` 60 fps,
  `noof` 60 fps). So the off-screen path is **not** a faithful proxy for the
  desktop saver, and a saver that is black *there* is not necessarily broken on
  screen.
* Where both agree, they agree well (`fractasia`, `hypertorus`, `hexplasma`,
  blackhole-slow); where they disagree the on-screen number is authoritative.
  A few light savers even measure *slower* off-screen (e.g. `bestill5-0`
  38 fps off-screen vs 60 fps on-screen) because of the per-frame read-back.

**Consequence for the lock:** the off-screen black-frame results are a real
*lockscreen* concern (`fractasia`/`noof`/`magmasimplex` may show black in the
lock's hosted saver on Gen6/Gen7), but they do **not** change the desktop pool
verdicts above. This is recorded as a risk for the lock/saver-feed owner, not
re-classified here.

---

## 7. Method, raw data, and the compositor wedge

* **Harness:** `bench.py` (a hardened extension of litebase's `saver_perf.py`):
  fixed scale via env, `[stats]` steady p50/p95, process CPU%, `[diag]
  framebuffer` non-black sample, GLSL/ES compile/link capture, SIGUSR1 snapshot,
  SIGTERM with a 10 s grace. Sweeps: `sweep.py` (native → 0.5 → 0.25 only when
  native is short; a compile/link failure is not re-run) and the auto-recovery
  wrapper `sweep_on.sh`. `offscreen.py` implements the lock protocol.
* **Raw data (this directory):** `on70_all.jsonl` (HD4000, on-screen, 100 records
  / 74 hacks), `on70x.jsonl`, `on70.jsonl`, `off70.jsonl` (HD4000, off-screen),
  `on89.jsonl` (HD3000, on-screen, 120 records / 74 hacks).
* **Per-host TSVs:** `savers-lite-pool-ivb-hd4000.tsv`,
  `savers-lite-pool-snb-hd3000.tsv`; **combined:** `savers-lite-pool.tsv`
  (columns: saver, family, hostclass, native_fps, p95, min_scale_for_30fps,
  verdict, reason).
* **GPU hang (recorded).** `magmasimplex_gles3` at **native** scale on the
  HD 4000 drives an i915 engine hang: `dmesg` shows `GPU HANG: ecode
  7:1:85fffffc, in magmasimplex_gl` + repeated `Resetting rcs0 for stopped
  heartbeat`, and its measured p95 frame time is **≈5.9 s (HD4000) / ≈6.1 s
  (HD3000)** at *every* scale → `exclude` ("GPU hang/stutter").
* **Compositor wedge (recorded).** On this driver, a saver window that never
  completes its first frame, when SIGKILLed, leaves labwc's output frame timer
  dead: every subsequent GL client then waits forever for a frame callback
  (grim still reads the frozen buffer). This is a real defect of the test rig,
  not a shader property. It required **2 session recoveries on `.70` and 8 on
  `.89`** during the sweeps; `sweep_on.sh` detects a no-frame SIGKILL and
  terminates/re-logs-in the session (greeter IPC via `kbd2.py type:ncz enter`)
  to continue. No host was rebooted.
* **Thresholds:** pool = ≥30 fps **and** p95 ≤40 ms at native; scaled = the same
  after dividing the render resolution (0.5 / 0.25); exclude = neither, or a
  fatal compile/link failure, or GPU-hang stutter.

---

## 8. Cleanup receipt

* **Leases:** `inspiron` (`.70`) acquired 16:13 EDT and **released** after the
  `.70` sweep; `192.168.207.89` (`.89`) acquired 17:32 EDT and **released** at
  the end. Both held one at a time, per the rig.
* **No reboot.** The only disruptive action was terminating the *graphical
  session* to clear the wedge (2× `.70`, 8× `.89`) and logging back in through
  the greeter; both hosts were left **logged in to a working desktop**.
* **No persistent settings changed.** The harness sets render scale only via the
  child process environment (`NCZ_RENDER_SCALE*`); the `dev.ncz.screensaver`
  / `dev.sinty.desktop` GSettings and `/etc/ncz/lock-renderer.env` were **not**
  modified. No `gsettings set` was issued.
* **No flash/dd/repartition; no rescue-entry edits; optical `sr0` untouched.**
* **Scratch:** all bench files under `/home/ncz/Projects/saverbench` on each host
  (no `/tmp`); nothing left running (`sweep*.py`, `bench.py`, `jigg*`, the
  saver binaries and `offscreen.py` children were all reaped).
* **Result hosts:** `.70` and `.89` left logged in, compositor healthy.
* **Branch:** `fix/lite-saver-pool-20261012` off `fix/rc7-final-20261012`
  (`f64cba5c`) in `cix-installer` — adds the measured lite saver pool as a data
  file (`assets/perf/lite-saver-pool-20261012.tsv`) and this report
  (`docs/SAVERBENCH-LITE-POOL.md`). **Commit `b0071f67`**, pushed **GitLab
  ncz-os first, then ARGONAS**, all three SHAs verified equal (`git ls-remote`
  → `b0071f6747d8aeb511a5b996047cdadecdd22365`). **Not merged.** No image
  build/tag/ship.

## 9. Risks / caveats

1. The on-screen harness measures the **desktop** saver at the session's real
   output size (1366×768 / 1600×900) on the panel the unit has today; a different
   panel/resolution changes the numbers (scaling tiers are resolution-sensitive).
2. `magmasimplex` appears as `exclude` because of a **driver-level GPU hang**, not
   a slow shader — it may be fine on a newer part; it is not safe on Gen6/Gen7.
3. The **compositor wedge** is a live labwc/driver defect on these two hosts; any
   real rotation through heavy savers on such a GPU can hit it.
4. The **off-screen lock path** has its own false negatives (§6); the lockscreen
   pool should be re-measured through the feed once it is fixed, rather than
   inferred from the desktop pool.
5. `klein_gles3` is measured `pool` here but is still catalogue-`suspect`
   (large single-colour areas) — a quality flag, not a performance one.
6. Nothing is merged; the pool is a recommendation and the operator decides the
   final enable-list.
