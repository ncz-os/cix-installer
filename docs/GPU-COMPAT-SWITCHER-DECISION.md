# GPU switcher / cixgpu-compat escalation — decision record (2026-10-17)

**Decision: (A) SUPERSEDED.** Branch `fix/gpu-switcher-stop-reenabling-compat`
(commit `5776efd6`, "fix(gpu): stop ncz-gpu-switcher re-enabling the Mesa-24/26
collision") was never merged, but **the identical defect was already fixed on
`release/preview3-20261017`** by commit **`60a39a23`**. No functional port is
needed or wanted — porting `5776efd6` on top would re-introduce nothing but
would conflict with the already-correct code.

## The question

`5776efd6` claimed that `assets/gpu/ncz-gpu-switcher.sh`'s `userspace_mali()`
called `enable_file "$LD_COMPAT"`, re-enabling
`/etc/ld.so.conf.d/01-cixgpu-compat.conf` on every mali-mode boot and thereby
undoing the deliberate build-time decision in
`post-install/26-gpu-default-mali.sh`.

## What release/preview3 actually contains

### The superseding commit

```
60a39a23fd245052da3b0ce3366c0c9d846074cb
Jason Perlow <jperlow@gmail.com>   Wed Sep 16 16:34:49 2026 -0400
fix(gpu): ncz-gpu-switcher must never re-enable 01-cixgpu-compat.conf

 assets/gpu/ncz-gpu-switcher.sh | 20 ++++++++++++++++++--
```

`git merge-base --is-ancestor 60a39a23 origin/release/preview3-20261017` → **yes**.
It is a strict superset of `5776efd6`: same root cause, same conclusion (drop
`LD_COMPAT` from the switcher's toggle logic), but additionally removes the
`disable_file "$LD_COMPAT"` from `userspace_panthor()` and carries live
hardware verification on O6N (greetd active, labwc + singularity-greeter
stable, zero new coredumps) rather than a cixmini (.66) reproduction.

### The code lines on release/preview3-20261017

`assets/gpu/ncz-gpu-switcher.sh`, `userspace_mali()` (lines 250-266):

```sh
userspace_mali() {
    enable_file "$LD_PRO"
    # LD_COMPAT (01-cixgpu-compat.conf) is DELIBERATELY NEVER TOUCHED HERE.
    # BUG FIXED 2026-09-16 (real, metal-verified on O6N): this used to
    # enable_file it on every boot, which directly undid
    # post-install/26-gpu-default-mali.sh's own, deliberate, extensively
    # metal-verified (2026-09-04) decision to leave it disabled --
    # /opt/cixgpu-compat is a COMPLETE second GL stack (cix-libglvnd 1.7.0
    # + cix-mesa 24.0.4) that conflicts with the system's real glvnd/Mesa
    # 26.x + GTK 4.22, and that hook's own header documents the exact
    # failure mode re-enabling it causes: "Could not initialize EGL
    # display" / labwc SIGSEGV inside libEGL's __eglLoadVendors, greetd
    # start-limit-hit, black screen. ...
    enable_file "$ICD_MALI"
```

`userspace_panthor()` (lines 297-301):

```sh
userspace_panthor() {
    disable_file "$LD_PRO"
    # LD_COMPAT: not touched here either -- see userspace_mali()'s comment.
    # This was already correctly a no-op in practice ...
    disable_file "$ICD_MALI"
```

`git grep -nE '^[[:space:]]*(enable_file|disable_file)[[:space:]]+"?\$LD_COMPAT'`
over the whole file returns **nothing**. `$LD_COMPAT` survives only as the
variable assignment at line 58 (so the documented intent stays greppable) and
in comments.

The install-time counterpart is also present — `post-install/26-gpu-default-mali.sh`:

```
52:# 01-cixgpu-compat is DELIBERATELY LEFT DISABLED as of 2026-09-04.
93:disable_file /etc/ld.so.conf.d/01-cixgpu-compat.conf "GL/GLX/GLES glvnd compat (ld path)"
```

## What this branch adds

No functional change. `5776efd6`'s fix was correct but **unprotected** — nothing
in the test suite would have caught its reintroduction, which is how the same
class of bug (a boot-time component overriding an install-time decision)
survives. This branch adds a regression guard to
`build/test-gpu-switcher-fallback.sh`:

1. **static** — no `enable_file`/`disable_file` of `$LD_COMPAT` anywhere in the
   switcher;
2. **behavioural** — a sandboxed `sky1.gpu=vendor` boot, seeded with
   `01-cixgpu-compat.conf.disabled`, must leave that file disabled;
3. **non-vacuity** — the same boot must still enable `00-cixgpu-pro.conf`, so
   (2) cannot pass by the switcher having stopped touching `ld.so.conf.d`
   altogether.

Verified to fail against the pre-`60a39a23` switcher
(`NCZ_TEST_ROOT=<tree at 60a39a23^>`, which reports both
`switcher toggles LD_COMPAT` and `mali boot re-enabled
01-cixgpu-compat.conf`) and to pass on `release/preview3-20261017`.

## Explicitly not done

**MINOR-003 (have the switcher write its own blacklist) is deferred**, per the
task's own instruction, and is not implemented here. No editor ever wrote a
blacklist entry in this tree, so the blacklist-writer idea has no
reproduction to build a test from.

## Residual risk

None identified for the compat-collision question. Note the `5776efd6` vs
`60a39a23` divergence: `5776efd6` left `disable_file "$LD_COMPAT"` in
`userspace_panthor()`. That is harmless (panthor mode leaves the file disabled
either way, and `26-gpu-default-mali.sh` already disables it), and `60a39a23`'s
removal of it is the more conservative reading — "neither GPU mode may ever
touch it". This branch does not attempt to restore the `5776efd6` shape.