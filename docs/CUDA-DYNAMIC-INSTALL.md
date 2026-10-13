# NVIDIA driver + CUDA on AMD64: dynamic, per-GPU-family install

Decision (2026-09-29): CUDA is NOT baked into the ISO or the offline
mirror. It is downloaded from NVIDIA's apt repo during install when an NVIDIA GPU
is present and the network is up, and finished by a first-boot timer otherwise.
The ISO therefore carries only the two repo keys, `ncz-cuda-setup` and its units
(about 100 KB). `build/verify-cuda-assets.sh --mirror DIR` fails if any NVIDIA or
CUDA package ever lands in the offline pool.

## Family matrix (post-install/lib/cuda-select.sh)

| Family | PCI device id | Driver | Kernel module | CUDA toolkit | Repo | Verified |
|---|---|---|---|---|---|---|
| turing-plus (sm_75+) | >= 0x1e00 | R615 (`cuda-drivers`) | open | 13.4 | debian13 | run on hardware (RTX 2060) |
| maxwell-volta (sm_50-70) | 0x1340-0x1dff | R580 (`cuda-drivers-580`) | proprietary (`nvidia-kernel-dkms`) | 12.9 | debian12 | resolved with apt-get -s; R580 module compile-tested on 7.2.8-t2; not run on hardware |
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

Toolkit set per family: `cuda-compiler-N`, `cuda-libraries-N`,
`cuda-libraries-dev-N` (cuBLAS/cuFFT/cuSPARSE/cuSOLVER/cuRAND/NPP headers and dev
libraries, cudart-dev, cccl/thrust, profiler-api, driver-dev, nvrtc-dev). Nsight,
docs and samples are left to `apt install cuda-toolkit-N`. Host compiler: CUDA
13.4 supports gcc 6-16; forky's gcc 16.2 compiled and ran kernels unmodified.

## Files

- `/etc/ncz/cuda-selection.conf`: GPU id, family, driver branch, toolkit, reason.
- `/etc/apt/preferences.d/ncz-nvidia-cuda.pref`: pins the driver family to its
  branch (`615.*` or `580.*`); delete to move deliberately.
- `/usr/local/sbin/ncz-cuda-setup {run|retry|status}`, `ncz-cuda-setup.service`
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
