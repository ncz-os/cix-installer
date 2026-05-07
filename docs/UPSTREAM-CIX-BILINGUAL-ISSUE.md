# Bilingual upstream issue — Cix Sky1 software/hardware gap

**Targets:** primary on `cixtech/cix-linux-main` and `cixtech/ai_model_hub`; mirror to Sky1-Linux community; Chinese community via Zhihu / CSDN once English version lands and gets traction.

**Author:** Jason Perlow / @perlowja, NCZ Reinhardt project maintainer (`gitlab.com/nclawzero/cix-installer`). Personal-OSS work.

**Tone goal:** constructive ecosystem feedback. Cix silicon is genuinely good; we want to surface specific software gaps that block users from realizing the silicon's potential. Honest praise + specific asks.

---

## English version (post on `cixtech/cix-linux-main` issues)

### Title

> Sky1 Z3 NPU silicon is competitive at embedding workloads — but five specific tooling gaps block users from realizing it. Asks for the Cix engineering team.

### Body

Hi Cix engineering team,

We've been doing systematic benchmarking of the Cix Sky1 / CD8180 SoC for agentic-memory workloads (vector embeddings via the Z3 NPU at 256-token sequence length on `bge-small-zh.cix`). The hardware is genuinely competitive — and after one week of tooling work, we have honest, reproducible numbers that we want to share back.

**TL;DR:** On our test harness, Cix Sky1 NPU and current-gen Intel iGPU + OpenVINO 2026.1.0 land in **the same performance neighborhood** for this workload (cold-pass per-inference time within 4-7%). We can't yet attribute the residual gap to silicon, software-tuning, or model variant from this single dataset alone — and that's part of why we want the Cix team's read. What we can say plainly is that toolchain gaps in `libnoe`/CixBuilder are blocking us from evaluating + adopting this silicon at the rate the hardware seems to permit. We've identified five specific gaps and would value team feedback on the right paths to close them.

**Hardware setup:**
- Minisforum MS-R1 (Cix CD8180), 64 GB unified RAM premium SKU, kernel 7.0.3-cix-sky1-next, NCZ Reinhardt 26.5 r74 distro
- Mali-G720 panvk + kernel panthor with Sky1-Linux Mesa 26.0.0-1sky1.2 (after upgrading from Ubuntu 25.10's stock Mesa 25.2.8 which has a panvk command-buffer pool bug)
- Cix Z3 NPU via FyrbyAdditive's aipu kernel module port + libnoe.so.0.6.0 + libaipu_driver.so + custom Python ctypes wrapper
- bge-small-zh-v1.5 256-token .cix model from `cixtech/ai_model_hub`

**Reference comparison hardware:**
- PYTHIA: Intel Core 5 210H (Raptor Lake-P), Intel Iris Xe iGPU, Ubuntu 26.04 LTS, kernel 7.0.0-14-generic, OpenVINO 2026.1.0 + optimum-intel + bge-small-en-v1.5

**Benchmark methodology:**
- 2000-memory production corpus, single-stream sequential, LATENCY mode (verified — no auto-batching tricks on Intel side)
- Both sides given equal optimization treatment: SHA256-keyed content-hash embedding cache
- Three passes per device: cold (cache empty), warm (full cache), mixed-50% (realistic agentic workload with 50% repeat ratio)

**Results:**

```
                        COLD (raw NPU/iGPU)   WARM (cache hit)    MIX-50% (realistic)
Cix Sky1 NPU            39.55 emb/sec         128,670 emb/sec     110.51 emb/sec
PYTHIA Intel iGPU       42.45 emb/sec         534,775 emb/sec     105.06 emb/sec
PYTHIA Intel CPU        27.17 emb/sec         532,559 emb/sec      67.31 emb/sec
```

Cix Sky1 NPU and current-gen Intel iGPU are in the same neighborhood for cold-pass per-inference time on this harness — within 4-7%. **Caveats before drawing strong conclusions:**

- The two sides ran different language variants (`bge-small-zh` on Cix, `bge-small-en` on Intel) — same architecture and same 512-dim output, but quantization tables and tokenizer details differ.
- The MIX-50 column is dominated by the content-hash cache (cache-hit path is ~8 µs each on either side), not by raw accelerator throughput. The gap there reflects cache machinery, not silicon.
- The COLD column is point estimates from one harness run each side; we have not yet published variance bars or a same-model controlled run.

What we can say honestly: **at this harness, on this workload, neither accelerator dominates by a wide margin.** Whether the residual cold-pass gap is silicon, software-tuning, or model-variant we cannot yet attribute from this data alone — and that's part of why we want the Cix team's read.

**Five specific software gaps blocking the silicon's full potential:**

1. **Persistent-job inference times out with NOE_STATUS_TIMEOUT 0x23.** Empirically, calling `noe_job_infer_sync` repeatedly against the same `job_id` returns 0x23 after the first call; the only working pattern we and visorcraft have found is calling `noe_create_job` + `noe_clean_job` around every inference. This adds material per-call overhead and caps sustained throughput well below what the silicon should support. We don't yet know whether the bug lives in the kernel-side aipu module or in `libnoe` userspace state machine. **Ask:** can the Cix team confirm the layer, and is there (or could there be) a supported persistent-job API where one job_id can serve many sequential `noe_job_infer_sync` calls? That single change is likely the bridge between our 39 emb/sec measured and a 70+ emb/sec target on the same silicon.

2. **No persistent inference daemon shipped.** Both visorcraft and we have written our own OpenAI-compat HTTP wrappers around `libnoe`. OpenVINO ships `OpenVINO Model Server` for the equivalent role. **Ask:** would the Cix team consider shipping a `noe-server` binary in `cix-noe-umd` that does the standard "load .cix model → expose REST/gRPC endpoint → route inferences" pattern? This would cut hours off every implementer's onboarding.

3. **Closed Compass NN compiler (CixBuilder).** OpenVINO's accelerator went from "early-stage Intel-iGPU thing in 2018" to "ships current LLMs in 2026" partly because the optimization stack was open. The Cix Z3 silicon has `~28-30 TOPS INT8` of headroom; the question of which workloads *can* compile to .cix today is opaque to anyone outside Cix. **Ask:** is there a path to either (a) open-sourcing the Compass NN compiler, or (b) at minimum publishing a list of supported / unsupported ONNX ops for the current Z3 backend? Right now community implementers learn op-by-op via failed compilation attempts.

4. **No transformer-attention support documented as in-development.** We've seen multiple reports (visorcraft, our own attempts via Zhouyi Execution Provider, Cixtech's own [ai_model_hub#1](https://github.com/cixtech/ai_model_hub/issues/1) thread) that transformer attention layers are not currently mappable to Z3. **Ask:** is there a public roadmap for transformer-attention support, even if speculative? Knowing that "attention is on the roadmap for v3.x of Compass" vs "attention is not planned" lets community make different deployment decisions today.

5. **`cix-noe-umd` deb postinst pip-installs libnoe wheel locked to Python 3.11/3.12.** Ubuntu 25.10 ships Python 3.13.7; the postinst always fails on current Ubuntu. We patched ours locally to gracefully degrade. **Ask:** can a wheel for Python 3.13+ be added, or the postinst made tolerant of Python version skew? This bites every Ubuntu-25.10-or-newer user.

**What we're shipping:**
- The benchmark harness, results, and Python ctypes wrapper are open in `gitlab.com/nclawzero/cix-installer/docs/`
- The MNEMOS upstream PR (https://github.com/mnemos-os/mnemos) for `mnemos-embedder-cix-npu` is in progress — gives MNEMOS users a one-line config to use Cix NPU for their vector store backend.

**Why we're posting this:** Cix Sky1 silicon is the first ARM SoC we've seen that ships an integrated NPU at this TOPS class with this much unified RAM at a $700 price point. The product story we want to be able to tell is "Cix Sky1 is the right hardware for agentic memory workloads." The silicon supports that claim today; the toolchain is what we'd ask the Cix team to invest in.

Happy to provide reproducible benchmark scripts, raw data, environment details, or to test patches. Methodology: 2000-memory production corpus, single-stream sequential, content-hash cache (SHA256 → vector), `bge-small` 256-token / 512-dim, no auto-batching tricks. Cix-vs-Intel-iGPU baseline write-up at `gitlab.com/nclawzero/cix-installer/docs/` (we'll publish a Cix-only methodology note alongside this issue).

Thanks for the silicon and for engaging on the threads earlier this month.

— Jason Perlow / @perlowja
NCZ Reinhardt project maintainer
`gitlab.com/nclawzero/cix-installer` · `github.com/perlowja`

---

## 中文版本 (post on Zhihu, CSDN, or mirror to cixtech repos)

### 标题

> Cix Sky1 Z3 NPU 在向量嵌入工作负载上具有竞争力 — 但五个具体的软件工具链缺口阻碍用户充分发挥硅片潜力

### 正文

各位 Cix 工程师团队成员好,

我们一直在系统化基准测试 Cix Sky1 / CD8180 SoC 在 agentic memory 工作负载下的性能(通过 Z3 NPU 运行 256-token 序列长度的 `bge-small-zh.cix` 向量嵌入)。硬件确实有竞争力 — 经过一周的工具链调优后,我们有了诚实、可复现的数据,想分享回上游。

**核心结论:** 在我们这套测试工装上,Cix Sky1 NPU 与当前 Intel 集显 + OpenVINO 2026.1.0 在此工作负载上**位于同一性能区间**(冷启动逐次推理时间相差 4-7%)。我们尚不能从这一份数据中确定残留差距是硅片本身、软件调优,还是模型变体导致的 — 部分原因正是希望听取 Cix 团队的解读。我们识别了五个具体的工具链缺口,希望团队反馈正确的解决路径。

**硬件配置:**
- Minisforum MS-R1 (Cix CD8180), 64 GB 统一内存高端版本, 内核 7.0.3-cix-sky1-next, NCZ Reinhardt 26.5 r74 发行版
- Mali-G720 panvk + 内核 panthor + Sky1-Linux Mesa 26.0.0-1sky1.2 (Ubuntu 25.10 的 Mesa 25.2.8 有 panvk 命令缓冲池 bug,升级后修复)
- Cix Z3 NPU 通过 FyrbyAdditive 的 aipu 内核模块移植 + libnoe.so.0.6.0 + libaipu_driver.so + 自定义 Python ctypes 包装器
- bge-small-zh-v1.5 256-token .cix 模型(来自 `cixtech/ai_model_hub`)

**对比参考硬件:**
- PYTHIA: Intel Core 5 210H (Raptor Lake-P), Intel Iris Xe 集显, Ubuntu 26.04 LTS, 内核 7.0.0-14-generic, OpenVINO 2026.1.0 + optimum-intel + bge-small-en-v1.5

**测试方法:**
- 2000 条生产语料库, 单流顺序, LATENCY 模式 (已验证 — Intel 端无自动批处理)
- 两侧应用相同优化: SHA256 内容哈希嵌入缓存
- 每个设备三个 pass: 冷启动 (缓存空)、热缓存 (全部缓存命中)、混合 50% (重复率 50% 的真实 agentic 工作负载)

**结果:**

```
                        COLD              WARM              MIX-50% (真实)
Cix Sky1 NPU            39.55 嵌入/秒    128,670 嵌入/秒    110.51 嵌入/秒
PYTHIA Intel 集显       42.45 嵌入/秒    534,775 嵌入/秒    105.06 嵌入/秒
PYTHIA Intel CPU        27.17 嵌入/秒    532,559 嵌入/秒     67.31 嵌入/秒
```

在这套测试工装上,Cix Sky1 NPU 与当前的 Intel 集显在此工作负载的冷启动逐次推理时间上位于同一区间 — 相差 4-7%。**在得出强结论之前的几点说明:**

- 两边运行的是不同语言变体(Cix 上是 `bge-small-zh`,Intel 上是 `bge-small-en`)— 架构相同、512 维输出相同,但量化表和分词器细节有差异。
- MIX-50 列的结果由内容哈希缓存主导(任一边的缓存命中路径都约为 8 µs),而不是原始加速器吞吐量。该列的差距反映的是缓存机制,不是硅片。
- COLD 列是单次工装运行的点估计;我们尚未发布方差区间或同模型对照运行结果。

我们能诚实陈述的是:**在这套工装、这一工作负载下,两个加速器都没有大幅领先。** 残留的冷启动差距是硅片、软件调优,还是模型变体所致 — 仅凭这一份数据我们无法归因 — 这也是我们想听取 Cix 团队解读的部分原因。

**阻碍硅片潜力的五个具体软件缺口:**

1. **持久化 job 推理触发 NOE_STATUS_TIMEOUT 0x23 错误。** 经验上,对同一个 `job_id` 重复调用 `noe_job_infer_sync` 在第一次之后会返回 0x23;我们和 visorcraft 找到的唯一可用模式是在每次推理前后调用 `noe_create_job` + `noe_clean_job`。这增加了实质性的每次调用开销,使持续吞吐量远低于硅片应该能支持的水平。我们目前还无法判断该 bug 位于内核侧 aipu 模块还是 `libnoe` 用户空间状态机。**请求:** Cix 团队能否确认该 bug 所在层级,以及是否存在(或可以提供)受支持的持久化 job API,让一个 job_id 可以服务多次连续的 `noe_job_infer_sync` 调用?这一项变更很可能是从我们测得的 39 emb/sec 跨越到同一硅片 70+ emb/sec 目标的关键桥梁。

2. **未提供持久化推理守护进程。** visorcraft 和我们都写了自己的 OpenAI 兼容 HTTP 包装器调用 `libnoe`。OpenVINO 提供 `OpenVINO Model Server` 充当相同角色。**请求:** Cix 团队是否考虑在 `cix-noe-umd` 中提供 `noe-server` 二进制文件,执行标准的"加载 .cix 模型 → 暴露 REST/gRPC 端点 → 路由推理"模式?这将为每个实施者节省数小时的入门时间。

3. **闭源的 Compass NN 编译器 (CixBuilder)。** OpenVINO 的加速器从 2018 年的"早期阶段 Intel 集显项目"发展到 2026 年的"运行当前 LLM"——部分原因是优化堆栈是开源的。Cix Z3 硅片有 `~28-30 TOPS INT8` 的余量;但今天哪些工作负载*能*编译到 .cix 对 Cix 之外的人来说是不透明的。**请求:** 有没有可能 (a) 开源 Compass NN 编译器,或 (b) 至少发布当前 Z3 后端支持/不支持的 ONNX 算子列表?目前社区实施者只能通过失败的编译尝试逐个学习。

4. **未发布 transformer 注意力支持开发路线。** 我们看到多份报告(visorcraft、我们自己的 Zhouyi Execution Provider 尝试、cixtech 自己的 [ai_model_hub#1](https://github.com/cixtech/ai_model_hub/issues/1) 讨论)显示 transformer 注意力层目前无法映射到 Z3。**请求:** transformer 注意力支持是否有公开的路线图,即使是推测性的?知道"注意力在 Compass v3.x 路线图上"vs"注意力不在计划内"会让社区今天做出不同的部署决定。

5. **`cix-noe-umd` deb postinst pip 安装锁定到 Python 3.11/3.12 的 libnoe wheel。** Ubuntu 25.10 ships Python 3.13.7;postinst 在当前 Ubuntu 上总是失败。我们在本地修补让其优雅降级。**请求:** 能否为 Python 3.13+ 添加 wheel,或让 postinst 容忍 Python 版本偏差?这影响每个 Ubuntu 25.10 或更新版本的用户。

**我们正在贡献:**
- 基准测试工具、结果和 Python ctypes 包装器在 `gitlab.com/nclawzero/cix-installer/docs/` 开源
- 给 MNEMOS 上游的 PR (https://github.com/mnemos-os/mnemos) — `mnemos-embedder-cix-npu` 进行中,让 MNEMOS 用户一行配置即可使用 Cix NPU 作为向量存储后端

**为什么发这个帖子:** Cix Sky1 是我们见过的第一个在 $700 价位上集成此 TOPS 等级 NPU 加上如此多统一内存的 ARM SoC。我们想讲的产品故事是"Cix Sky1 是 agentic memory 工作负载的正确硬件"。硅片今天就支持这个说法;工具链是我们想请 Cix 团队投资的部分。

很乐意提供可复现的基准测试脚本、原始数据、环境详情或测试补丁。数据和方法在 `gitlab.com/nclawzero/cix-installer/docs/CIX-VS-JETSON-PERF-REPORT.md`。

感谢硅片和这个月早些时候在帖子里的回应。

— Jason Perlow / @perlowja
NCZ Reinhardt 项目维护者
`gitlab.com/nclawzero/cix-installer` · `github.com/perlowja`

---

## Distribution plan

| Channel | Language | Action | Timing |
|---|---|---|---|
| `cixtech/cix-linux-main` issue | EN | Primary post; comprehensive | Day 0 |
| `cixtech/ai_model_hub` issue (link to above) | EN | Cross-reference; deeper technical engagement on model-compilation gaps | Day 0 |
| Sky1-Linux/linux-sky1 issue (link to above) | EN | Awareness-share; Sky1-Linux is a peer downstream | Day 0 |
| 知乎 (Zhihu) long-form post | ZH | Translated body, link back to GitHub issue | Day 1-2 (after EN gets initial reactions) |
| CSDN blog post | ZH | Mirror of Zhihu, link back | Day 2-3 |
| Bilibili demo video | ZH | Optional — show the bench running on .66 | Week 2+ if traction warrants |
| r/LocalLLaMA, Phoronix forums | EN | Awareness-share, link back to GitHub issue | Day 0-1 |
| Geerling sbc-reviews thread | EN | Targeted: he tracks ARM/SBC perf benchmarks; comment on his Minisforum MS-R1 thread | Day 1 |

## Codex review gate before posting

This document goes through Codex `adversarial-review` before any of it ships, per CLAUDE.md PRIMARY DIRECTIVE #4. Sensitivities to flag-check:
- No NVIDIA-billable scope creep
- No vendor-bashing in either language
- Numbers correct vs measured data (cross-check `mem_1778089624337_8c530e` for fair-comparison final)
- Chinese translation idiomatic — not literal/mechanical
- Tone is constructive-feedback not arrogant-criticism
