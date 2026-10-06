# GPU driver install progress on the installer screen

The GPU driver step can run for many minutes during "Finishing the
installation". On amd64 that is the NVIDIA driver download plus its DKMS
kernel-module build, or the ROCm packages. On Sky1 it is the Mali, Panthor,
VPU and NPU DKMS builds. Before this change the screen showed one unchanging
line for the whole step, and the install looked hung. Now the step has a
name, a status line that changes every heartbeat, and a result for each
module.

## What the operator sees

The d-i info line below the progress bar shows each of these in turn.
Examples are for an amd64 machine with an AMD iGPU and an NVIDIA dGPU:

| moment | info line |
|---|---|
| step starts | `Installing NCZ-OS: gpu accel (40/57, 0s) - Installing GPU drivers: AMD + NVIDIA - driver download + kernel module build (can take 10-20 min)` |
| packages downloading / unpacking | `Installing NCZ-OS: gpu accel (40/57, 95s) - packages 12%: nvidia-kernel-dkms ...` (the apt shim's per-package line) |
| module compiling | `[6:12 ..*.] GPU drivers (AMD + NVIDIA): building nvidia 580.95.05 for kernel 7.3.0-1-ncz-amd64 - compiling 412/1130 files, about 6 min left` |
| linking | `[8:40 *...] GPU drivers (AMD + NVIDIA): building nvidia ... - linking (modpost) 1130/1130 files` |
| module done | `[8:55 .*..] GPU drivers (AMD + NVIDIA): nvidia 580.95.05 for kernel 7.3.0-1-ncz-amd64 - built OK in 8m21s` |
| module failed | `... nvidia 580.95.05 for kernel ... - BUILD FAILED after 2m03s: error: <first compiler error>` |
| boot image refresh | `[9:30 ..*.] GPU drivers (AMD + NVIDIA): refreshing the boot image (initramfs) for kernel 7.3.0-1-ncz-amd64` |
| step done | `Installing NCZ-OS: gpu accel (40/57, 845s) - GPU drivers (AMD + NVIDIA): done in 845s - 1 kernel module build(s) OK, 0 failed` |

On a GPU status line, `[m:ss]` is how long the step has been running. The
moving `*` changes on every heartbeat (4 s), even while one large file
compiles, so the line never looks frozen.

If no driver is needed, the step says so and finishes at once:

- `GPU drivers: no AMD, NVIDIA or Intel GPU found - nothing to install, skipping`
- `GPU drivers: NVIDIA GPU found, driver/CUDA component not selected - skipping`
- `GPU drivers: server/headless install - no GPU driver needed, skipping`

Other steps get their own names:

- AMD only: `ROCm compute packages (amdgpu is in the kernel; a few min)`
- Intel only: `compute and media packages`
- Apple T2 Macs: `Building Apple T2 drivers`
- Sky1: `Installing GPU drivers: Mali` / `Panthor`, `Building VPU and NPU drivers`, `Preparing kernel headers ...`

## Where the numbers come from

Everything comes from what the build is actually doing. No step shows a
timer as if it were progress.

- **Module, version, kernel:** the header line DKMS writes at the top of
  `/var/lib/dkms/<module>/<version>/build/make.log`.
- **`412/1130 files`:** the kbuild `CC`/`AS` lines in that log, counted
  against the C and assembly sources in the build tree. If the same module
  was already built for another kernel earlier in this install, the count
  from that build log is used instead, because it is a measurement.
- **ETA (`about 6 min left`):** the compile rate seen so far, applied to the
  files still to build. It appears after at least 10 files and 30 s. Until
  then the step label gives the expected range. `10-20 min` for NVIDIA is
  the operator's estimate, not a measurement.
- **Built OK / BUILD FAILED:** what DKMS left on disk. Success means a
  module under `<module>/<version>/<kernel>/<arch>/module/`. Failure means
  no module, and `build/make.log` still holds the error.
- **Stage names between builds:** taken from running processes (`dkms`,
  `make modules_prepare`, `update-initramfs`/`dracut`, `dpkg`, the apt
  download methods).

## Progress bar

`run-all.sh` writes `/var/log/cix-install/progress.plan` (`index|hook|weight`).
`late.sh` spreads the bar range it owns by those weights, not one equal
slot per hook. The weights are:

| step | weight |
|---|---|
| NVIDIA driver step | 12 |
| AMD | 4 |
| Apple T2 builds | 4 |
| each Sky1 DKMS step | 2-3 |
| every other step | 1 |

Inside an NVIDIA step, the step's own percent is split into windows:

| window | range |
|---|---|
| packages before the build | 0-25 % |
| module builds | up to 90 % |
| later packages (CUDA toolkit) | up to 99 % |

The apt shim scales its package percent into the window the monitor hands
it, in `progress.state.window`. A package transaction therefore cannot use
up the build's share.

The bar only moves forward. A later record with a lower percent leaves the
bar where it is. If the plan is missing or does not match the step count,
the bar falls back to equal slots.

The bar only moves when finish-install gives `late.sh` a range
(`NCZ_PROGRESS_UNITS`). The legacy ISO builder patched finish-install to do
that, and that patch went away with those builders (f40a8061). Until the
raw-image path carries the patch again, the bar stays put during
post-install, and the changing info line is the visible feedback. `late.sh`
logs this state as `bar will NOT advance -- text-only degraded mode`.

## Records and logs

| file | contents |
|---|---|
| `/var/log/cix-install/progress.tsv` | every record, including the `GPU` events. The monitor only ever writes `GPU`, never `FAIL` or `WARN`, so a failed optional module build cannot fail the KVM gate. |
| `/var/log/cix-install/gpu-progress.log` | `STEP`, `BEGIN build`, a status sample every 30 s and on every stage change, `RESULT ok\|failed`, `END`. Also mirrored to tty3. |
| `/var/log/cix-install/gpu-progress.results` | `hook\|module\|version\|kernel\|ok\|failed\|seconds`, used for the step summary |
| `/var/log/cix-install/<hook>.log` | the hook's own output, unchanged |

## Code and tests

| file | role |
|---|---|
| `post-install/lib/gpu-progress.sh` | step profiles (hook + arch to label/weight), the monitor, start/stop helpers |
| `post-install/run-all.sh` | writes the plan, labels the step, starts and stops the monitor by exact PID around a GPU hook |
| `post-install/apt-progress-shim` | window scaling |
| `preseed/late.sh` | `hb_units_for` (weighted bar) and `hb_gpu_status` (the GPU line) |
| `build/test-gpu-install-progress.sh` | test (in `make parity`) |

The test drives a simulated DKMS build whose `make.log` grows. It asserts
that:

- the status text changes and names the module, version and kernel
- an ETA appears and the build gets its result line
- percent and bar never regress, and the bar moves on every build tick
- no `FAIL` row is written
- a fake `54-gpu-accel.sh` run through `run-all.sh` produces a labelled
  step and a summary

Set `NCZ_GPU_PROGRESS=0` to turn the monitor off for one install. The
labels and plan weights stay.
