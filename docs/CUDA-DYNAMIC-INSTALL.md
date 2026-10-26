# NVIDIA driver + CUDA on AMD64: dynamic, per-GPU-family install

Decision (2026-09-29): CUDA is NOT baked into the image or the offline
mirror. It is downloaded from NVIDIA's apt repo during install when an NVIDIA GPU
is present and the network is up, and finished by a first-boot timer otherwise.
The image therefore carries only the two repo keys, `ncz-cuda-setup` and its units
(about 100 KB). `build/verify-cuda-assets.sh --mirror DIR` fails if any NVIDIA or
CUDA package ever lands in the offline pool.

## Family matrix (post-install/lib/cuda-select.sh)

| Family | PCI device id | Driver | Kernel module | CUDA toolkit | Repo | Verified |
|---|---|---|---|---|---|---|
| turing-plus (sm_75+) | >= 0x1e00 | newest that builds (`nvidia-open`) | open (`nvidia-kernel-open-dkms`) | newest 13.x | debian13 | run on hardware (RTX 2060, 615.71.09); 615.71.10 + 595.112.07 built against 7.3.0-t2-ncz headers in a container |
| maxwell-volta (sm_50-70) | 0x1340-0x1dff | newest R580 that builds (`cuda-drivers-580`) | proprietary (`nvidia-kernel-dkms`) | newest 12.x | debian12 | resolved with apt-get -s; R580 module compile-tested on 7.2.8-t2; not run on hardware |
| kepler-older | < 0x1340 | none | nouveau | none | - | logged skip |

The oldest NVIDIA GPU in the machine decides (R580 serves Turing too; R615 does
not serve Pascal). Device-id thresholds are a heuristic, tested at both boundaries.
Kepler and older get nothing: Debian forky ships no `nvidia-legacy-*` packages and
NVIDIA publishes no CUDA 11 for debian12/13.

Evidence: CUDA 12.9 release notes (Maxwell/Pascal/Volta feature-complete, offline
compilation and library support removed in the next major toolkit); NVIDIA's
statement that R580 is the last branch for Maxwell/Pascal/Volta; NVIDIA's debian13
repo carries drivers >= 590 and toolkits 13.1-13.4 only, the debian12 repo carries
580.x and toolkits 12.3-12.9.

Toolkit set per family: `cuda-compiler-N-M`, `cuda-libraries-N-M`,
`cuda-libraries-dev-N-M` for the newest complete N.M (cuBLAS/cuFFT/cuSPARSE/cuSOLVER/cuRAND/NPP headers and dev
libraries, cudart-dev, cccl/thrust, profiler-api, driver-dev, nvrtc-dev). Nsight,
docs and samples are left to `apt install cuda-toolkit-N`. Host compiler: CUDA
13.4 supports gcc 6-16; forky's gcc 16.2 compiled and ran kernels unmodified.

## Versions are chosen at run time (2026-10-26)

Nothing in the image names a driver point release or a CUDA minor version.
`ncz-cuda-setup`:

- **Driver ladder.** Lists every version of the family's module package that
  NVIDIA's repo offers (one per upstream version, newest first; Maxwell..Volta
  limited to `580.*`). Each is installed as a matched set: an exact-version apt
  pin moves every NVIDIA driver package to that version. When the DKMS module
  does not compile for the running kernel, the next older version is tried (at
  most `NCZ_CUDA_DRIVER_TRIES`, default 4, per run; the timer continues). The
  version that built is recorded in `/var/lib/ncz/cuda-setup.driver` and as
  `INSTALLED_DRIVER` in the selection. The newest pins its series (`615.*`);
  a fallback is held at exactly its version so `apt upgrade` cannot pull the
  broken one back (`ncz-cuda-setup retry` tries the newer ones again).
- **Build records.** Each failed version is remembered with the kernel, its
  config and the local patches. The timer never rebuilds identical inputs; a
  new kernel, a new driver version in the index or a new patch is tried at once.
- **All fail.** The half-configured module package (and only its own driver
  metapackages) is removed so apt is never left broken, the family pin is
  restored, status is `failed:no-buildable-driver`, `/etc/motd.d/ncz-nvidia-driver`
  and the first-boot notice say the integrated GPU is in use, and
  `nvidia-persistenced` is skipped (not failed) because no module exists.
- **Toolkit.** The newest `cuda-compiler-<series>-N` whose companion packages
  (`TOOLKIT_PKGS` stems) all exist. A renamed or missing set is
  `failed:toolkit-not-found` (the driver is still installed); a renamed driver
  package is `failed:package-missing`.

## Local DKMS patches are matched by content

`assets/nvidia/dkms/<module>/<set>/` holds a patch set and its `fixed-upstream`
marker (line 1: file in the driver source, line 2: a string the upstream fix
adds). For any driver source, a set is staged only when the marker is absent
AND every patch applies to the pristine source exactly (`patch --fuzz=0`,
offsets allowed); otherwise it is refused and logged. Staging writes
`/usr/src/<module>-<version>/patches/` and `/etc/dkms/<module>-<version>.conf`
before dpkg runs the module postinst: `ncz-cuda-setup` checks the downloaded
`.deb`, and the apt hook `/etc/apt/apt.conf.d/60ncz-nvidia-dkms` does the same
for a plain `apt upgrade`; a driver update whose build still fails re-arms
`ncz-cuda-setup`, which falls back. `ncz-cuda-setup dkms-stage DIR` runs the
check by hand.

Shipped: `0001-dmem-cgroup-init-linux-7.3` (Linux 7.3 changed
`dmem_cgroup_register_region()` to take `struct dmem_cgroup_init *`). It applies
to 615.71.09 and 615.71.10; NVIDIA fixed it in 615.78.08 (GitHub tag, commit
ca2d03e6), which the marker recognizes. 610.57.04 has the same defect but a
different `nvidia.Kbuild`, so the set is refused there (the ladder moves on);
595.x does not have the code and built unpatched on 7.3.0-t2-ncz.

## Files

- `/etc/ncz/cuda-selection.conf`: GPU id, family, driver branch, toolkit, reason.
- `/etc/apt/preferences.d/ncz-nvidia-cuda.pref`: family default (any NVIDIA
  driver series for Turing+, `580.*` for Maxwell..Volta), then rewritten by
  `ncz-cuda-setup` to the series or exact version that built.
- `/etc/apt/apt.conf.d/60ncz-nvidia-dkms`: the apt hooks above.
- `/etc/systemd/system/nvidia-persistenced.service.d/ncz-needs-module.conf`:
  `ExecCondition` on `modinfo -k <running kernel> nvidia`.
- `/etc/modprobe.d/ncz-nvidia-legacy-fb.conf`: blacklists `nvidiafb`/`rivafb`
  (pre-2008 chips only; they bind nothing on Maxwell or newer).
- `/usr/local/sbin/ncz-cuda-setup {run|retry|status|dkms-stage}`, `ncz-cuda-setup.service`
  and `.timer` (first retry 2 min after boot, then every 10 min; the tool applies
  a 5 min to 6 h exponential backoff; exit 75 is not a failure; not part of the
  boot transaction, so it never blocks login). Log `/var/log/ncz-cuda-setup.log`,
  stamp `/var/lib/ncz/cuda-setup.done`, result `/var/lib/ncz/cuda-toolkit.status`.
- Installer component `cuda`: offered (default on) only when an NVIDIA display
  controller is present; `ncz_components=` lists are authoritative (a list that
  omits `cuda` skips it).

## Known trade-off

NVIDIA still signs the debian12 repo with its 2022 key, whose SHA-1 self-signature
Debian's apt-sequoia policy rejects. On maxwell-volta machines only, 54 writes
`/etc/crypto-policies/back-ends/apt-sequoia.config` extending
`sha1.second_preimage_resistance` to 2027-12-31. That setting is machine-wide for apt.
