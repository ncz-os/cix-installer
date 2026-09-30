# PEGASUS NVIDIA EGL and PRIME rescue — 2026-09-30

The AMD64 image `2026.09.29-617e7303` installed NVIDIA driver 615.71.09-2
without the EGL ICD and Wayland external platform packages. Its RTX 2060
calibration fell back to Intel at 46.52 ms, leaving the pool weak. The
original [PEGASUS validation report](/mnt/datapool/projects/ncz-session-2026-09-29/reports/pegasus-validate.md)
records the pre-repair state.

The Turing-or-newer `DRIVER_PKGS` plan now includes `nvidia-egl-icd`,
`libegl-nvidia0`, `libnvidia-egl-wayland1`, and `libnvidia-egl-gbm1`.
`ncz-cuda-setup` already simulates the complete driver and toolkit plan and
refuses any `Remv` before installation; keeping these packages in that plan
also covers its deferred retry. The installed-target gate requires all four
packages on Turing-or-newer images. The R580 Maxwell/Volta plan is unchanged.

On the live PEGASUS test host, `apt-get install -s --no-install-recommends
--no-remove` reported zero removals for each package group before installing.
The first pair installed at 615.71.09-2 and restored NVIDIA to
`vulkaninfo --summary`, but Wayland calibration still selected Intel. The
Wayland and GBM external platform packages then installed at 1:1.1.21-1 and
1.1.4-2. NVIDIA's [Wayland EGL external platform project](https://github.com/NVIDIA/egl-wayland)
documents the external platform loader and its JSON registration directory.

After all four packages, the same Wayland `--identify` probe returned
`NVIDIA GeForce RTX 2060/PCIe/SSE2`, OpenGL ES 3.2 NVIDIA 615.71.09.
`ncz-screensaver calibrate --force --json` measured the RTX 2060 at 3.28 ms,
class `strong`, while Intel remained `weak` at 46.96 ms. The pool grew from
68/84 to 83/84 installed hacks. `plan crackberg_gles3` and
`plan xshadertoy_neongravity-1_gles3` selected NVIDIA with `offload=true`.

## Integration into `fix/installer-ux-kernel-final-2026-09-30`

This rescue is a focused, source-level package-list rescue, not a release
merge. It does not touch the installer-UX gates, the kernel-default
reconciliation, or the dialog/phase logic. The change set is exactly the
three commits on `fix/amd64-nvidia-egl-icd-2026-09-30` and is carried onto
a fresh isolated branch
`integration/installer-ux-kernel-egl-2026-09-30` from
`fix/installer-ux-kernel-final-2026-09-30` (no release branch merged).

Source verification: PROTEUS ran `bash build/test-amd64-cuda-gates.sh` at
`fd82fe15` with `PASS=160 FAIL=0`; it includes negative installed-target
checks for each absent EGL package. GNU Bash syntax and `git diff --check`
passed on the source worktree. Branch
`fix/amd64-nvidia-egl-icd-2026-09-30` was pushed to ARGONAS and GitLab.
Zoder Qwen review failed to complete; Ultra returned an unparseable verdict,
so neither is counted as approval. Codex reviewed the small change against
the existing simulation/retry flow and the live package evidence.

This is a source fix and a test-host hotfix. No new image was built, booted,
or flashed; fresh-install package presence, real saver frames on NVIDIA,
and release acceptance remain open. The already-running saver was not
restarted after recalibration. No release branch was merged.