# Inference Limits — cixmini (CIX Sky1, 7.0.12-cix-sky1-next)

Empirical ncnn `benchncnn` sweep on MS-R1 (64 GB), loop_count=8, cooling_down=1.
Raw logs: `/mnt/argonas_backups/cixmini-bench/<ts>/` (cpu-4t, cpu-1t, gpu-panvk).

## Headline conclusion

Accelerator hierarchy for ML on this box: **NPU (Zhouyi V3) > CPU (12-core) > GPU-compute (panvk)**.
panvk GPU compute is the *slowest* option for every model tested — do not route ML to it.

## Why panvk loses

panvk capability probe:
```
fp16-cm=0  int8-cm=0  bf16-cm=0  fp8-cm=0   (NO cooperative-matrix / matmul accel)
subgroup=16  rebar=1
WARNING: panvk is not a conformant Vulkan implementation, testing use only.
```
Mali-G720's Vulkan path exposes no cooperative-matrix, so GEMM-heavy nets get no
acceleration and pay full dispatch/readback overhead. Result: 10x-47x slower than CPU.

## Data (avg ms, lower=better)

| model              | CPU 4t | panvk   | GPU penalty |
|--------------------|-------:|--------:|------------:|
| squeezenet         |   4.99 |   29.92 |   6x        |
| mobilenet_v2       |   4.31 |   30.54 |   7x        |
| resnet18           |   6.88 |   75.34 |  11x        |
| resnet50           |  19.40 |  189.31 |  10x        |
| vgg16              |  37.38 |  373.94 |  10x        |
| googlenet          |   9.78 |   84.63 |   9x        |
| mobilenet_yolo     |  23.16 |  168.57 |   7x        |
| vision_transformer | 215.70 | 10210.6 |  47x        |

## Guidance for the distro / AI dev

- **Embeddings + small CNN/vision**: CPU is excellent (mobilenet/squeezenet ~4-5 ms).
- **Heavy vision / detection / image-gen / Whisper**: route to **NPU** via cix-noe-umd
  + pre-compiled `.cix` graphs (Cix AI Model Hub). NPU mobilenet_v2 ~640 inf/s (1.5 ms).
- **GPU**: use panthor for display/desktop GL/Vulkan, NOT for ML compute.
- **Transformers/LLM**: no good local accelerator path — Zhouyi V3 compiler is
  static-graph only (no KV-cache); GPU has no coop-matrix. CPU is the fallback.

## NPU IOVA ceiling (32-bit bus)

NPU address bus is 32-bit (bus_dma_limit 0xc0000000). Driver patched to
`iova_region=2` (was 6) to match usable ~2 GB aperture; idx2 alloc failures gone.
Practical NPU working-set ceiling ~2 GB regardless of host RAM.
