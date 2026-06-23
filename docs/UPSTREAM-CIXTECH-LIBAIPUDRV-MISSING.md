# Upstream issue: `cix-noe-umd 4.0.0` ships without `libaipudrv.so` backend on kernel 7.0

**Filing target:** `cixtech/cix-developer-docs` issue tracker (or wherever cixtech accepts apt-distribution bug reports). Mirror to `Sky1-Linux/apt` if cixtech non-responsive.
**Filer:** Jason Perlow (`@perlowja`) — NCZ Reinhardt / Magnetar maintainer
**Status:** DRAFT 2026-05-07. Validated end-to-end on Minisforum MS-R1 (Cix Sky1 / CD8180) running NCZ Magnetar 26.5.r76 (Ubuntu 25.10 questing + linux-cix-sky1-next 7.0.3).

---

## Title

`cix-noe-umd 4.0.0` is incomplete on `archive.cixtech.com/debian trixie main` for kernel 7.0 (open-source path) — `libaipudrv.so` backend is not in any apt package. Frontend `dlopen()` returns ENOENT and every NPU init call fails.

## Summary

The `cix-debian13-k7.0-driver-opensource` 1.0.2 meta-package on `archive.cixtech.com` pulls in the kernel-side DKMS modules (`cix-npu-driver-dkms`, `cix-vpu-driver-dkms`) but does not pull a **complete** userspace pair. Specifically:

| Package | Provides | Kernel pair |
|---|---|---|
| `cix-noe-umd` 4.0.0 | `libnoe.so` (frontend) + Python bindings | needs `libaipudrv.so` backend at runtime |
| `cix-npu-driver` 4.0.0 | DKMS source for kernel 6.6.89 | not for 7.0 |
| `cix-debian13-k7.0-driver-opensource` 1.0.2 | grub config + DKMS shells | no userspace |

`libaipudrv.so` does not exist in any package on the apt archive. As a result, **a fresh install of the official open-source path cannot run a single inference on the NPU it ships with.**

## Reproducer

```bash
# fresh Ubuntu questing 25.10 + linux-cix-sky1-next 7.0.3
curl -fsSL https://archive.cixtech.com/cix-repo-community.sh | sudo sh
# select option 2 (open-source kernel-7.0 driver)

sudo apt-get install -y cix-noe-umd cix-ai-engine

# verify the kernel module probes (it does — FyrbyAdditive prebuilt or DKMS rebuild)
ls /dev/aipu                  # exists
sudo dmesg | grep -i aipu     # "AIPU detected: zhouyi-v3"

# try a basic inference using cixtech's reference script
cd /path/to/ai_model_hub_25_Q3/models/Generative_AI/Text_Image_Search/onnx_bge_small_zh
python3 inference_npu.py
# fails with:
# aipu_adapter.cpp ERROR:151 - load_aipu_library: Failed to load backend:
#   libaipudrv.so: cannot open shared object file: No such file or directory
# noe_api.cpp ERROR:184 - noe_init_context: Failed to initialize adapter
```

The frontend `libnoe.so` (installed at `/usr/share/cix/lib/libnoe.so` from `cix-noe-umd 4.0.0`) calls `dlopen("libaipudrv.so", ...)` at runtime. The file is not on the system, no apt package ships it.

## Why this is a problem for Sky1 distros

Several downstream distributions ship the cixtech apt path verbatim, including:

- **NCZ Reinhardt / Magnetar** (`cix-installer`) — Ubuntu 25.10 questing on Sky1 hardware
- **Sky1-Linux** (`Sky1-Linux/apt`)
- **Radxa Orion O6** documentation references the same apt source for NPU usage
- **Orange Pi 6 Plus** community guides

A user following the official cixtech Open-Source Driver instructions on kernel 7.0 today gets a board with a probed-clean NPU kernel module and a userspace pipeline that immediately dies on `dlopen`. We have validated this on .66 (NCZ Magnetar with FyrbyAdditive prebuilt KMD) — the issue is reproducible from scratch.

The closed-source kernel-6.6 path (`cix-debian13-k6.6.89-driver`) ships a complete bundle (`cix-npu-driver`, `cix-npu-onnxruntime`, `cix-mnn`, `cix-ai-engine`, ...). The `cix-debian13-k7.0-driver-opensource` 1.0.2 path needs the same userspace pair to be useful.

## Note: there's a parallel stack that is complete

`cix-npu-onnxruntime` 2.0.0 ships with `libaipu_driver.so` (paired with a cixtech-built `libonnxruntime.so.1.22.0` and `onnxruntime_zhouyi-1.22.0-cp311.whl`). This **is** a complete UMD+frontend pair, but it's a parallel stack — `aipu_*` symbol namespace, not the `noe_*` namespace that `libnoe.so` expects.

So cixtech effectively ships **two parallel stacks**:

1. **"NoE" stack**: `libnoe.so` (frontend, `noe_*`) → expects `libaipudrv.so` backend (**MISSING from apt for kernel 7.0**)
2. **"ONNX Runtime" stack**: `libonnxruntime.so.1.22.0` (frontend) → bundles `libaipu_driver.so` backend (`aipu_*`) — **complete**

The NoE stack is what the open-source `ai_model_hub` Chinese-language references and `inference_npu.py` use as the canonical example. Most users — including everyone following Cix's reference code — hit the missing backend.

## What we'd like

One of:

1. **Ship `libaipudrv.so` in apt** — package it so `cix-noe-umd` is complete on the open-source kernel-7.0 path. Either as a separate `libaipudrv` deb that `cix-noe-umd` depends on, or embedded inside `cix-noe-umd 4.0.x`. Pairing should be against the corresponding `cix-npu-driver-dkms` 4.0.0 KMD ABI so existing user code works unchanged.
2. **Document the migration to the ONNX Runtime stack** — if `libnoe.so` / `cix-noe-umd` is being deprecated for kernel 7.0+, say so explicitly and update `ai_model_hub`'s `inference_npu.py` reference scripts to use `onnxruntime_zhouyi-1.22.0` instead. Today users follow `inference_npu.py` and dead-end.

We'd be happy to help test any pre-release builds against NCZ Magnetar real hardware (Minisforum MS-R1 / Cix Sky1) — UART+SSH access, CI smoke, full embedding-corpus benchmarks (we have an 8038-record real corpus benchmark wired). Just say where to file follow-ups.

## Cross-links

- This file: `gitlab.com/nclawzero/cix-installer/-/blob/main/docs/UPSTREAM-CIXTECH-LIBAIPUDRV-MISSING.md`
- Reproduction logs and full stack details captured during 2026-05-06/07 NCZ Reinhardt+Magnetar validation
- NCZ Reinhardt 26.5 r74 release notes (canonical reference for the affected user-facing image)

## Author / contact

Jason Perlow (`@perlowja`) — NCZ project maintainer. Personal-OSS work, not on behalf of any vendor.
