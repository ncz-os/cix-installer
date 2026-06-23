# Upstream issue: panvk crashes (`vk::DeviceLostError`) on Mali-G720 (Cix Sky1) under sustained ggml encoder embedding workload

**Filing target:** `freedesktop.org` GitLab Mesa project (`mesa/mesa`) — panvk component. Mirror to `Sky1-Linux/mesa-sky1` for awareness.
**Filer:** Jason Perlow (`@perlowja`) — NCZ Reinhardt / Magnetar maintainer
**Status:** DRAFT 2026-05-07. Reproducible on Minisforum MS-R1 (Cix Sky1 / CD8180), Mali-G720 MC10, Mesa 26.0.0-1sky1.2 (`panvk`), kernel 7.0.3-cix-sky1-next.

---

## Title

panvk: `vk::DeviceLostError: Device::waitForFences: ErrorDeviceLost` after ~5 sustained encoder requests via llama.cpp Vulkan backend on Mali-G720 (Cix Sky1)

## Summary

Running `llama.cpp` (commit `803627f1`) with the Vulkan backend (`-DGGML_VULKAN=1`, `-ngl 99`) on a Cix Sky1 Mali-G720 system serving an embedding model (`nomic-embed-text-v1.5.Q8_0.gguf`, 768-dim, encoder-only, ~140 MB Q8) successfully embeds **3-5 records**, then deterministically crashes the Vulkan device with:

```
terminate called after throwing an instance of 'vk::DeviceLostError'
  what():  vk::Device::waitForFences: ErrorDeviceLost
```

Stack from the crash:

```
ggml_vk_wait_for_fence(ggml_backend_vk_context*)
ggml_vk_synchronize(ggml_backend_vk_context*)
ggml_backend_vk_get_tensor_2d_async(...)
llama_context::encode(llama_batch const&)
llama_decode()
server_context_impl::update_slots()
```

After crash, all subsequent embedding requests get `Connection refused` (the `llama-server` process dies). The kernel does not log a Mali-side error, but the next vulkaninfo call may succeed — the device recovers at the kernel level, just the userspace context is lost.

This also reproduces with `-ngl 0` on the same llama.cpp build (Vulkan backend is loaded for tensor allocator even if no layers are GPU-offloaded). Building llama.cpp with `-DGGML_VULKAN=0` avoids the issue entirely.

## Reproducer

```bash
# Cix Sky1 hardware (e.g. Minisforum MS-R1) with Mesa panvk (Mesa 26.0.0+sky1)
git clone --depth 1 https://github.com/ggml-org/llama.cpp.git
cd llama.cpp
cmake -B build -DGGML_VULKAN=1 -DCMAKE_BUILD_TYPE=Release
cmake --build build -j$(nproc) -- llama-server

# Get an embedding model
curl -fL -o /tmp/nomic.gguf https://huggingface.co/nomic-ai/nomic-embed-text-v1.5-GGUF/resolve/main/nomic-embed-text-v1.5.Q8_0.gguf

# Start server
./build/bin/llama-server -m /tmp/nomic.gguf --embeddings -ngl 99 -c 8192 \
    --host 127.0.0.1 --port 18900 &

# Issue ~10 sequential embedding requests
for i in $(seq 1 10); do
    curl -sf -X POST http://127.0.0.1:18900/v1/embeddings \
        -H "Content-Type: application/json" \
        -d "{\"input\": \"sample text $i\", \"model\": \"nomic\"}" -o /dev/null
done
```

Result: requests 1-4 succeed, request 5+ fail (server has crashed). Mean time-to-crash on our setup is ~30 seconds total.

## Hardware/software details

- **SoC:** Cix Sky1 / CD8180 (P1) — ARMv9 Cortex-A720+A520, Mali-G720 MC10
- **Kernel:** 7.0.3-cix-sky1-next (based on linux-cix-sky1-next, with FyrbyAdditive Mali-G720 driver patches)
- **Mesa:** 26.0.0-1sky1.2 (Sky1-Linux fork — `Sky1-Linux/mesa-sky1`)
- **Vulkan loader:** stock libvulkan-dev for trixie/questing
- **Workload:** ggml-vulkan from llama.cpp `803627f1` (current main)
- **Vulkan device reports:** "WARNING: panvk is not a conformant Vulkan implementation, testing use only" on every vulkaninfo / llama-server start. So the disclaimer is in place — this is more of a "what does it take to make panvk usable for inference" report than an outright bug.

## What works on the same hardware

- **CPU-only ggml-vulkan disabled build** (`-DGGML_VULKAN=0`): runs the same model + same workload + same model + same load shape and produces 6+ embeddings/sec sustained over our 8038-record real corpus, no crashes. So it's specifically the Vulkan compute path that fails, not Sky1 platform integration.
- **Other Vulkan workloads** (vkmark, vkcube) appear to run, though we haven't run them long enough to confirm panvk stability under those.

## What we'd like

We understand panvk on Mali-G720 / Cix Sky1 is "testing only" by Mesa's own disclaimer. This filing is to:

1. **Document the failure mode** for any future user trying ML-on-Mali via Vulkan compute on this SoC, so they save the time we spent.
2. **Ask: is anyone working on a panvk path that's stable under sustained compute submission?** Embedding-class workloads are the natural Mali-G720 fit on Cix Sky1 (the silicon has good FP16/INT8 capacity and 47 GB of unified RAM addressable via Vulkan host memory). If panvk gets stable for compute, this becomes a major embedded-AI use case.
3. **Cross-link to Sky1-Linux/mesa-sky1** for community awareness.

We'd be happy to test fixes against real hardware (NCZ Magnetar / Minisforum MS-R1) and contribute repro corpus / additional log captures if it helps.

## Cross-links

- This file: `gitlab.com/nclawzero/cix-installer/-/blob/main/docs/UPSTREAM-MESA-PANVK-EMBEDDING-CRASH.md`
- Sky1-Linux mesa fork: `github.com/Sky1-Linux/mesa-sky1`
- Companion issue we filed re: cixtech apt missing `libaipudrv.so`: `gitlab.com/nclawzero/cix-installer/-/blob/main/docs/UPSTREAM-CIXTECH-LIBAIPUDRV-MISSING.md`

## Author / contact

Jason Perlow (`@perlowja`) — NCZ project maintainer. Personal-OSS work, not on behalf of any vendor.
