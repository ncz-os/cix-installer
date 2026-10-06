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

## First boot

The NVIDIA DKMS build already runs during the install, inside the GPU step
above (`54-gpu-accel.sh` -> `ncz-cuda-setup` -> apt -> the
`nvidia-kernel-open-dkms` postinst -> `dkms build`). It is not deferred on
purpose. A DKMS package reaches first boot unconfigured only when that build
did not finish: dpkg then leaves it `half-configured`, and the first-boot
`dpkg --configure -a` in `ncz-firstboot` (ordered before the display
manager) runs its postinst, and so the build, again.

Measured on PEGASUS (r199, RTX 2060, kernel 7.3.0-rc6, 2026-10-06): the
build failed at install with a compiler error after about 60 s
(`os-interface.c:3031: error: passing argument 1 of
'dmem_cgroup_register_region' makes pointer from integer without a cast`,
NVIDIA 615.71.09 against the Linux 7.3 dmem cgroup API). First boot ran the
identical build, which failed the identical way after about 60 s, and the
login screen waited for it with nothing on screen. Nothing cut the build
short: the unit has no start timeout and finished with `Result=success`.
In r199 `ncz-cuda-setup.timer` then repeated the build in the background
with backoff. Since fix/nvidia-dkms-73-20261006 it records the compiler
error and rebuilds only when the kernel, its config, the driver or the local
DKMS patches change, and the shipped dmem patch makes 615.71.09 build on 7.3.

`post-install/lib/dkms-pending.sh` classifies each DKMS package dpkg left
unconfigured:

- `failed`: its `make.log` for this kernel holds a compiler `error:` line.
  The same driver source, kernel headers and compiler produce the same error,
  so first boot does not rerun it before the login screen.
- `needed`: anything else (the build never ran, or stopped without a compiler
  error). This build may succeed, so first boot runs it.

### End of the install

`preseed/late.sh` shows the `nclawzero/remove-media-gpu` variant of the last
dialog (the remove-the-USB note) when there is a notice. Otherwise it shows
the unchanged `nclawzero/remove-media`. The same text goes to the tty banner
and the install log. Possible paragraphs:

- needed: `First boot will finish setting up your GPU drivers (a DKMS build
  of nvidia 615.71.09). The login screen may take several minutes to
  appear. Do not power off.`
- failed: `GPU driver build failed for this kernel (nvidia 615.71.09):
  <first error line from make.log>. The desktop uses the open-source driver
  for now; ncz-cuda-setup retries it automatically once the kernel or the
  driver changes (status: ncz-cuda-setup status).` Without the NVIDIA retry
  timer the last part reads `it is retried when the kernel or driver is
  updated (or run: sudo dpkg --configure -a).`
- the NVIDIA driver could not be downloaded at all (no network during the
  install): `The NVIDIA driver could not be downloaded during the install.
  It is downloaded and built in the background after first boot; restart
  once it has finished (status: ncz-cuda-setup status).`

For a DKMS module that is not a GPU driver (for example an Apple T2 or NPU
module), the same lines say `drivers` / `Driver build failed ... The module
is unavailable for now; ...` and make no claim about the desktop.

The notice only names a duration of "several minutes". The full open-module
build takes about 50 s on a 16-core build host and longer on a laptop CPU,
and the initramfs refresh comes on top of that. It has not been timed end to
end on target hardware.

### During first boot

`ncz-firstboot` runs `lib/firstboot-gpu.sh configure` in place of the bare
`dpkg --configure -a`. If the helper is missing, it falls back to the bare
command.

- Nothing pending: `dpkg --configure -a`, no message.
- failed: the failed DKMS packages are left out. Every other unconfigured
  package is still configured, and dependents of a failed package stop at
  once on a dependency error. The login screen is not held up. The status
  line is `GPU driver build failed for this kernel (<module> <version>):
  <error>. The desktop uses the open-source driver for now; ncz-cuda-setup
  retries it automatically once the kernel or the driver changes (status:
  ncz-cuda-setup status).`, the same sentence as at the end of the install.
  For NVIDIA the package stays with ncz-cuda-setup, whose apt run
  configures it again when its inputs change.
- needed: the status line `Finishing GPU driver setup: DKMS build of
  <module> <version>. The login screen appears when it is done (several
  minutes). Do not power off.`, then live lines from `lib/gpu-progress.sh`'s
  monitor (`GPU drivers: building nvidia 615.71.09 for kernel ... -
  compiling 120/198 files, about 2 min left`), then either `GPU drivers
  ready (...)` or the failure line. The login screen waits for this build on
  purpose. On a machine whose only display GPU is the NVIDIA one, the
  greeter would otherwise start without its driver. `ncz-firstboot.service`
  has `TimeoutStartSec=infinity`, so the build is never cut short.

After a successful first-boot build, an NVIDIA display device that no driver
has claimed gets `modprobe nvidia-drm`, which is what udev would have done at
boot if the module had existed. The status line then says `built and
loaded`. If another driver already holds the device, the line says `It is
used after the next restart.` Nothing reboots on its own.

Where the lines go: `plymouth display-message` when `plymouth --ping`
answers, otherwise `/dev/console`. Every line also goes to the journal
(`journalctl -u ncz-firstboot`) and to `/var/log/ncz-firstboot-gpu.log`.
amd64 images replace Plymouth with the native `singularity-boot-splash`.
That splash has no message API and exits after at most about 22 s, so the
console lines appear on the screen that would otherwise stay black. The
helper repeats the current line every 15 s, so a line the splash painted
over comes back.

| file | role |
|---|---|
| `post-install/lib/dkms-pending.sh` | classification and install-end notice (POSIX sh; runs in d-i busybox against `/target`) |
| `post-install/lib/firstboot-gpu.sh` | first-boot configure step, status relay, ready/failed line |
| `preseed/extract-rootfs.sh`, `build/iso/patch-debootstrap-stub.py` | the two `ncz-firstboot` copies (the stub is the live one); both call the helper |
| `build/test-firstboot-gpu.sh` | test (in `make parity`) |
