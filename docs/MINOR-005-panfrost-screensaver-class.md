# MINOR-005 — ncz-screensavers on the 7.3 Panthor (Panfrost/Mesa) entry:
## GPU class 'mid' with 63/74 weak hacks, and why screensavers do not run

Investigation + fix record, 2026-10-17 (Debian Forky, Sky1 arm64). No test
hosts were touched; nothing was flashed or rebooted. Evidence below is
file:line from:

- the pinned ncz-screensavers engine source, A7 pin
  `a7fe5cd4ed3b3c90c74fd5efd990e922c37de5ca` on
  `wip/studio/2026-10-14-t2-perf` (see `build/screensavers-version.env`,
  2026-10-15 NOTE: 0.8.16 engine repinned to a7fe5cd4; plugin 0.3.23 at
  `8f8433c4f90e0a3b2d80225dafee098957eea8d5` per
  `post-install/lib/ncz-screensavers-plugin.lock`);
- this repository's post-install GPU hooks
  (`post-install/26-gpu-default-mali.sh`, `post-install/82-mali-gpu.sh`,
  `post-install/83-panthor-gpu.sh`, `assets/gpu/ncz-gpu-switcher.sh`,
  `assets/gpu/ncz-gpu-status`, `assets/gpu/ncz-gpu-hw-present`,
  `post-install/lib/gpu-progress.sh`, `post-install/98-gpu-health.sh`).

## Symptom (as reported)

On a Sky1 booted into the experimental **7.3 Panthor** entry (mali_kbase
blacklisted, panthor bound, GLES renderer `Mali-G720 MC10 (Panfrost)`,
Vulkan PanVK, Mesa 26.x):

- `ncz-screensaver` classifies the GPU as **mid**;
- its pool policy marks **63 of 74** installed hacks 'weak' and **11** 'mid';
- `ncz-gpu-status` (and `ncz-gpu-health.service`) report render=true (healthy);
- screensavers **do not run**.

Under the default **Mali** entry (vendor ICD
`/opt/cixgpu-compat/.../40_cix.json`, blob GLES) the class was historically
'weak' on the same hardware.

## (a) Is 'mid' + 63 weak a policy-table outcome or a mis-detection?

**Both, at two different layers. The classification itself is a policy-table
outcome; the 'nothing runs' behaviour is a second, independent failure.**

### 1. The 'mid' verdict is a deliberate table outcome — not a mis-detection

The class is computed by `launcher/ncz-screensaver` (Python). Precedence
(0.8.16 / a7fe5cd4 line numbers):

- `launcher/ncz-screensaver:1284` — after a calibration run the class is
  `class_from_ms(ms)` (`:591-592`): `weak` at ≥ 20 ms, `mid` at ≥ 8 ms,
  else `strong` (`CLASS_WEAK_MS`/`CLASS_MID_MS`, `:132-133`).
- `launcher/ncz-screensaver:1242` / `:1260` — when the benchmark is missing
  or fails, `fallback_entry()` = `class_from_renderer(renderer) or
  class_from_topology(gpu)` (`:1189`).
- `class_from_renderer` (`:667`) walks `RENDERER_TABLE` (`:602-625`); the
  mid arm is `immortalis|mali-g(?:5[7-9]|6\d\d|7\d\d)|mali-g(?:6[0-9]|7[0-9])\b|...`
  — `Mali-G720 MC10 (Panfrost)` matches `mali-g7\d\d` → **mid**.
- `class_from_topology` (`:926`) falls back to the bound driver name;
  `MID_DRIVERS` (`:638-647`) explicitly lists `panfrost` and `panthor` →
  **mid**.

So whatever path fires — measured calibration (Mali-G720 Panfrost lands in
the 8–20 ms band, the same band the blob renders in: live Mali calibration
history on Sky1 is 9.88–11.76 ms, `ms`-based class mid), renderer string, or
topology — the table says **mid**. The 2026-09-29 regression tests
(`tools/tests/test_gpu_class.py::test_sky1_mali_g720_immortalis_is_mid_not_weak`
and `test_sky1_live_capture_*`) deliberately pin this: a Sky1 Mali-G720 must
report mid, never weak. The Mali-default history of 'weak' came from an
older binary (0.7.1-era, md5 1bd3ee4b…) whose topology fallback never
surfaced the standalone `/dev/mali0` platform device (see that fix, ncz
commits a4ab3890/1129d549): the four linlondp display controllers were the
only 'GPUs' visible and each classified weak.

`system_class()` (`launcher/ncz-screensaver:1376`) adds one wrinkle worth
recording: when the class cache has no entry for the display GPU it
substitutes `gpu_topology().display_class` (`:440`), which for any non-NVIDIA
panel reports `integrated` → **weak** (`:1392-1395`). That only applies
before the first calibration; a live host that has ever run
`ncz-screensaver calibrate` (the idle path does it automatically,
`Supervisor.calibrate()`, `:2407`) has a cache entry and reports the
calibrated/table mid.

### 2. The 63 weak / 11 mid split is the shipped tier table, not detection

`pool-gpu-class` defaults to `auto` (`launcher/ncz-screensaver:52`),
resolved by `pool_class()` (`:1470`) to `best_class(settings)`; on a
single-GPU host that is the display class, i.e. **mid**. The per-hack
eligibility filter is `filter_pool()` (`:1482`): a hack is kept iff
`rank(tiers[hack]) <= rank(pool_class)` (`:1497`). The tiers are baked in at
build time from `assets/screensaver-chooser/tiers.tsv`, produced by
`tools/measure-tiers.py`. At the A7 pin the table counts are:

- 63 rows `weak`
- 11 rows `mid`
- **0 rows `strong`**

(74 hack rows total; the table also carries preset rows, e.g. blackhole
scenes.) So on a mid GPU the policy table *by construction* enables 63+11 and
excludes exactly the set whose measured minimum class is above mid. That the
63 weak rows are all 'weak' is not a mis-detection: each was measured at or
above 30 fps on Intel UHD 630 / weak-class render scale (tier definition
comment, `tiers.tsv:1-4`). It is a statement about the *catalogue*: 85% of
the 74 installed titles are weak-class titles, so on a mid GPU 85% of them
remain eligible — the remaining 11 mid rows are likewise eligible (mid ≤ mid).

**Conclusion (a):** 'mid' is the correct, intended class for the Mali-G720
on Panfrost (same silicon, same mid band). 63 weak is the shipped
`tiers.tsv` composition, a policy-table outcome, and — crucially — the pool
filter does NOT exclude weak hacks on a mid GPU: it excludes hacks whose
tier is *above* the pool class. Eligibility is `rank(tier) <= rank(mid)`,
which keeps all 74.

## (b) Why nothing runs

The eligibility filter is not the blocker (it keeps everything on a mid
pool). The GL-vs-GLES path is a red herring for the 'does not run' symptom:
the harnesses are GLES3-only (`gles3_*`), and Panfrost provides a full
GLES 3.x context; PanVK is only used by Vulkan-path tools and does not gate
saver launch. Neither `filter_pool` nor `plan_for` (`:1407`) returns an
empty pool on a single mid GPU.

The launcher has exactly one path that produces *no saver at all* on a GPU
that is rendering fine: **the per-hack software-renderer guard**.

- Every hack carries an engine-level guard that refuses to start when the
  renderer it got is not the real GPU (exits `GUARD_EXIT = 3`,
  `launcher/ncz-screensaver:79`).
- `Supervisor.run_one()` (`launcher/ncz-screensaver:2365-2373`): a child
  exit 3 is logged as `the software renderer guard refused to start it; not
  retrying`, a desktop notification 'No hardware GPU is available for the
  screensaver.' is raised, and the result `refused` **ends the whole idle
  session** (`:2433-2434`). No rotation, no retry of the next hack, no
  per-hack fail count.
- The guard decides from the *context the process actually created*. Under
  Panfrost/Mesa a saver process created with the wrong EGL vendor (the CIX
  blob vendor, still registered system-wide, or a `__EGL_VENDOR_LIBRARY_*`
  pin inherited from the compositor) opens a display on `/dev/mali0`, which
  no longer exists on this entry, fails or degrades, and the guard aborts —
  even though a bare `eglinfo` (what `ncz-gpu-status` probes,
  `assets/gpu/ncz-gpu-status:141-158`) would happily report the Panfrost
  renderer. That asymmetry is exactly the reported signature: **health
  render=true, class mid, nothing runs.**

Why the vendor would be wrong on the 7.3 Panthor entry — the cix-installer
side:

- `assets/gpu/ncz-gpu-switcher.sh:81-89` — `userspace_panthor()` calls
  `egl_vendor_off()` (`:89`), removing `/etc/glvnd/egl_vendor.d/10_cix.json`
  (the symlink the Mali half creates to
  `/opt/cixgpu-compat/share/glvnd/egl_vendor.d/40_cix.json`, `:81-88`) and
  disables the Mali Vulkan ICD and the CIX WSI layer, enabling Mesa's
  device-select layer. On a *fresh* image the panthor half is clean.
- BUT the Mali half of the same script, `userspace_mali()` (`:250`), re-arms
  the blob vendor **on every Mali boot and every panthor→mali fallback**
  (`egl_vendor_on`, `:266`), and the r201-class fallback fires whenever
  `panthor` did not bind while `mali_kbase` is available
  (`ncz-gpu-switcher.sh:349-376`). After any such fallback (or after a
  manual `ncz-gpu-select mali` round-trip on an upgrade install),
  `10_cix.json` is back in `/etc/glvnd/egl_vendor.d`. If the machine is then
  booted into the Panthor entry on a kernel where panthor *does* bind (7.3),
  `driver_live panthor` is true, `activate_panthor` runs the userspace half,
  and the vendor file is removed again — so the *normal* path self-heals.
  The window in which it does not is: panthor boot with a stale
  `__EGL_VENDOR_LIBRARY_FILENAMES` / `MESA_LOADER_*` / `EGL_PLATFORM`
  exported by a session that was started under the Mali stack (the launcher
  copies compositor GPU vars into the child env,
  `launcher/ncz-screensaver:431-436`, `find_compositor_environ`), or an
  upgrade-install image where a hand-edited vendor file lives outside the
  two paths the switcher manages.

So (b) decomposes into:

1. **Not** the eligibility filter (keeps 74/74 on mid) — ruled out.
2. **Not** the GL-vs-GLES split (Panfrost has GLES 3; harnesses want GLES) — ruled out.
3. **Not** `ncz-gpu-status`/`98-gpu-health` (they only *report*; the probes
   run `eglinfo -B` and `vulkaninfo --summary` in the session env and a bare
   `env -i` env, `assets/gpu/ncz-gpu-status:141-158`, and judge only for
   software renderers — a healthy Panfrost box passes, as observed).
4. **The engine's software-renderer guard + EGL vendor selection under
   Mesa** — the saver child is handed a GL environment that does not resolve
   to the Panfrost device (stale CIX blob vendor pin, or a compositor-exported
   vendor pin the launcher re-injects), the child's guard sees no usable
   hardware context and exits 3, and `run_one()` converts that one refusal
   into a silent end of the idle session with a misleading 'No hardware GPU'
   notification. This is UNPROVEN on hardware (see below) but is the only
   code path that produces the observed combination, and it is the class of
   bug the switcher's own comments document for the inverse direction
   (`ncz-gpu-switcher.sh:51-57`: blob vendor left registered → 'Could not
   initialize EGL display' / llvmpipe under the wrong stack).

## The fix (confined, on branch `fix/panfrost-screensaver-class-20261017`)

1. `docs/MINOR-005-panfrost-screensaver-class.md` — this root-cause record.
2. `assets/gpu/ncz-gpu-switcher.sh` — documentation-only change: records
   that the 7.3 experimental entry selects the stack via
   `sky1.gpu=panthor` and that `mesa` remains an accepted alias (both are
   already handled at `get_mode()`, line `vendor|mali / mesa|panthor`).
   No executable line changed; the Mali default behaviour is untouched.

No pin change, no package change, no tier-table change: the 0.8.16 engine at
a7fe5cd4 is the accepted source, the 63/11 split is the intended catalogue
composition, and 'mid' on Panfrost is the correct class.

## What this does NOT change

- The Mali (Default) entry: `GPU_MODE=mali` default, `activate_mali()`
  userspace half, `40_cix.json` vendor registration, `mali.json` ICD, the
  `00-cixgpu-pro.conf`/`01-cixgpu-compat.conf` policy in
  `post-install/26-gpu-default-mali.sh` — all untouched.
- `build/screensavers-version.env` (floor stays 0.8.16) and
  `post-install/lib/ncz-screensavers-plugin.lock` (0.3.23) — untouched.
- `tiers.tsv` / `render-hints.tsv` shipped inside the ncz-screensavers
  package — untouched (owned by the saver repo, not this one).

## UNPROVEN (needs hardware confirmation on a Sky1)

1. **The exact refusal signature on the 7.3 Panthor entry** — i.e. that the
   idle session ends in a `GUARD_EXIT` (3) 'software renderer guard' rather
   than in some other early-exit class. Confirm on a test board with:
   `journalctl --user -u ncz-screensaver-idled`,
   `$XDG_RUNTIME_DIR/ncz-screensaver/launcher.log` (look for 'the software
   renderer guard refused to start it'), and
   `ncz-screensaver doctor` (`hack_env`, `running_hack_env`,
   `gpu_verdict_rows`). If the refusal is *not* a guard exit, the (b)
   decomposition above needs revisiting.
2. **Which vendor artifact is stale** in the failing environment (the
   `/etc/glvnd/egl_vendor.d/10_cix.json` symlink vs a compositor-exported
   `__EGL_VENDOR_LIBRARY_FILENAMES` inherited into the child env vs a
   hand-edited file). `ncz-screensaver doctor`'s `hack_env`/`running_hack_env`
   plus `ls -l /etc/glvnd/egl_vendor.d/` after a panthor boot settles it.
3. **That the pool is non-empty end-to-end on the live host**: the local
   unit-level proof (this doc, evidence 2) shows `filter_pool` keeps 74/74
   when the pool class is mid; the live `ncz-screensaver pool` and
   `ncz-screensaver list --json` output on the board would close it.
4. **Calibration landing**: that a fresh calibrate on Panfrost 7.3 returns a
   `ms` in the 8–20 band (→ mid via `class_from_ms`) rather than ≥ 20 (→
   weak). The class *reported* by the user (mid) is consistent with either
   the calibrated or the table path, so this is recorded, not asserted.
5. Anything about the 7.3 panthor.ko build/vermagic on the specific board —
   out of scope (no test hosts touched).

## Evidence log (commands run, no hardware)

```
# (1) class + pool behaviour against the A7 launcher, fake Sky1 sysfs
#      (linlondp display cards + panthor-bound /sys/class/misc/mali0,
#      no cache, no calibrator):
$ python3 - <<'PY'
# ... (fake sysfs; launcher loaded from source)
# gpus: [('soc-CIXH5000_00', 'panthor', True, True)]
# display_gpu: soc-CIXH5000_00 panthor
# topology fallback: mid
# system_class: weak            # pre-calibration only: gpu_topology().display_class
PY
# Post-calibration (cache entry present) system_class() == 'mid'.

# (2) pool filter with the shipped A7 tiers.tsv (63 weak / 11 mid / 0 strong)
#     and pool class mid:
# pool kept: 74 of 74            # nothing is excluded by the filter

# (3) this repo's GPU stack tests (unchanged, still green after the doc-only
#     switcher edit):
$ bash build/test-gpu-switcher-fallback.sh
gpu switcher fallback tests: 12 passed, 0 failed
$ bash build/test-no-software-render.sh
no-software-render tests: 68 passed, 0 failed
$ bash build/lint-no-software-render.sh
lint-no-software-render: OK
$ bash build/lint-platform.sh && bash build/check-no-ubuntu.sh \
    && bash build/tools/check-release-links.sh   # make lint-platform
ok

# (4) ncz-screensavers launcher unit suite (separate repo, for reference):
$ python3 -m pytest tools/tests/test_gpu_class.py -q
12 failed, 184 passed
# All 12 failures pre-date this change and target the gpuinfo sysfs
# fallback (ncz commits a4ab3890/e47547cd), which is intentionally not in
# the A7 engine pin; none touch the Panfrost/Mesa path.
```
