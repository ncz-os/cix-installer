# GPU switcher: 01-cixgpu-compat.conf and the Mali selection record

Decision record for the two questions raised against `ncz-gpu-switcher`
(2026-10-17). Both are answered here so nobody has to re-derive them from
`git log` archaeology.

## 1. Is the fix from `fix/gpu-switcher-stop-reenabling-compat` (5776efd6) still needed?

**No. It was superseded. Do not port it.**

Evidence, in order:

- `5776efd6` ("fix(gpu): stop ncz-gpu-switcher re-enabling the Mesa-24/26
  collision", 2026-09-14) changed one function only: it removed
  `enable_file "$LD_COMPAT"` from `userspace_mali()` of
  `assets/gpu/ncz-gpu-switcher.sh` and left `userspace_panthor()` alone.
- `60a39a23` ("fix(gpu): ncz-gpu-switcher must never re-enable
  01-cixgpu-compat.conf", 2026-09-16) is the same fix done further: it removes
  the `LD_COMPAT` toggle from **both** `userspace_mali()` and
  `userspace_panthor()`, with a longer rationale, and records a live
  metal-verified repro on the Radxa Orion O6N (labwc SIGSEGV in
  `__eglLoadVendors`, five restarts, `greetd` start-limit-hit) plus the live
  verification of the fix (greetd active, labwc and the greeter stable, no new
  coredumps).
- `60a39a23` is an ancestor of `main` **and** of `release/preview3-20261017`.
  `5776efd6` is on no shipped branch.

How to re-check the claim against any future base:

```sh
git merge-base --is-ancestor 60a39a23 release/preview3-20261017   # expect 0
# No caller may enable/disable the compat file:
grep -n 'LD_COMPAT' assets/gpu/ncz-gpu-switcher.sh
```

On `release/preview3-20261017` the only surviving occurrence of `LD_COMPAT` is
the variable definition kept as documentation of the path; neither userspace
function references it. The install-time decision belongs to
`post-install/26-gpu-default-mali.sh`, which disables the file and explains why
(second glvnd + Mesa 24.0.4 ahead of system Mesa 26); the switcher no longer
overrides it on any boot.

Porting 5776efd6 now would be a no-op at best and a regression at worst (it
would re-introduce a `LD_COMPAT` call into `userspace_panthor()`, where it was
not before, or leave the two functions asymmetric).

## 2. Which stack did the switcher actually apply?

The selection used to exist only as the bootloader's `sky1.gpu=` token (or
`GPU_MODE=` in `/etc/default/ncz-gpu`), and nothing reads that token back. On
the Panthor entry, r201 deliberately stopped blacklisting the kbase trio on the
cmdline so the Mali fallback stays possible, which left an installed system with
no on-disk statement of which driver the switcher had loaded.

`ncz-gpu-switcher.sh` now writes `# Selected: mali|panthor` into
`/etc/modprobe.d/ncz-gpu-drivers.conf` itself, in the same write that lays down
the two holds.

Design constraints that made this the small, contained option:

- **`blacklist` only, never `install <mod> /bin/true`.** A modprobe.d
  `blacklist` suppresses modalias autoload but still permits an explicit
  `modprobe`, which is what `activate_panthor()` and the Mali fallback depend
  on. `mali_kbase` therefore stays in the file on a Panthor boot; that is the
  line that stops udev from autoloading it out from under Mesa.
- **One write, published by rename.** The file is built in a sibling temp file
  and `mv`-ed over the target, so modprobe.d (read by udev coldplug, which can
  run concurrently with the switcher unit) sees either the old file or the new
  one, never a truncated one.
- **`sky1.gpu=none` records no selection.** That entry already blacklists every
  accelerator on the cmdline; the switcher loads nothing and claims nothing.

The full kernel-cmdline rewrite of `module_blacklist=` stays deferred: the
cmdline `module_blacklist=` refuses even an explicit load, so any attempt to
manage it from the switcher would break the Mali fallback that exists so a
machine with a GPU never renders in software.

## Tests

`build/test-gpu-switcher-fallback.sh` covers both halves in its stubbed
sandbox: the selection record (per mode, `blacklist`-only, exactly one hold
line per module, `none` claims nothing) and the publication (inode replaced by
rename, no temp files left in modprobe.d, mode 0644, one header, four hold
lines, newline-terminated) — plus the `mktemp`-less fallback path.

`build/test-gpu-switcher-compat-guard.sh` pins section 1's invariant against
regression. It RUNS the real switcher in the same stubbed sandbox and asserts
the compat file is left exactly as found in three directions: mali mode with
the file pre-enabled (no `disable_file` regression), mali mode with the file
pre-disabled (the shipped state — a re-introduced `enable_file "$LD_COMPAT"`
flips this back, i.e. exactly the 5776efd6 bug), and panthor mode. A static
check also fails the build on any `enable_file`/`disable_file` call that
references `$LD_COMPAT`, and on the install-time hook no longer disabling the
file. Verified: the behavioral case fails (exit 1) when the regression line is
re-introduced into `userspace_mali()`, and passes on the committed code.
