# 致 Tom Cubie 的中文摘要 (English summary in 06-radxa-tom-cubie-o6-loaner.md)

发送渠道建议:邮件直接回复你之前发的英文,或在 Radxa Discord 私信
(perlowja);中文版作为补充,方便他和工程团队同步。

---

## 邮件正文(中文摘要版)

主题: NCZ 发行版 Orion O6 / O6N 测试样机申请

Tom 你好,

我是 Jason Perlow。我正在维护一个开源(Apache-2.0)的 Linux 发行版
**NCZ**,专为 Cix Sky1 / CP8180 SoC 设计,代码仓在
https://gitlab.com/nclawzero/cix-installer 。第一个公开版本本周已经发布;
今晚正在收尾下一版 (r78 Reinhardt-Magnetar 网络安装版,约 615 MB),
内容上我觉得 Radxa 这边会感兴趣。

### 一句话需求

希望 Radxa 借给我 **一台 Orion O6 加一台 O6N**(我了解到这是两块不同
的板子,需要分别验证)做测试。可在测试完成后寄回;如果对账上更省事,
也可以按批发价直接采购。

### 为什么是 O6/O6N

1. **同芯不同板**: 目前 NCZ 的测试床是 Minisforum MS-R1,与 O6 是同一颗
   Sky1。在 GitHub 上的 Sky1-Linux 仓库中,Marcus Comstedt(zeldin)
   今天提交了一个 O6 的 PCIe 问题(issue #29,与 #20 同源)。如果手上
   有一台 O6,我可以直接调试,不必让社区代为复现。
2. **NPU 嵌入推理对照基准**: 当前发布版本集成了
   `mnemos-embedkit` (https://github.com/mnemos-os/mnemos-embedkit ),
   一个跨硬件的向量嵌入工具包(NPU/GPU/CPU 自动选择)。在 MS-R1 上,
   Sky1 NPU 跑 bge-small-zh-v1.5 (Q-INT8 .cix) 实测 **54.86 rec/sec
   (p50 14.6 ms)**, 整芯仅约 2W 功耗,**每瓦速率(~27 rec/W)在所有
   测试平台中位列第一**, 比 115W 级独显还高一个数量级。同套代码也跑过
   Apple M1 Max Metal、独立 GPU、Raspberry Pi 5 等,完整对照表见
   https://github.com/mnemos-os/mnemos-embedkit/blob/main/benches/results.md。
   O6 测得的数据可以独立列入对照表,使 Radxa 的客户群无需再做外推。
3. **比 Radxa 现有 Debian 12 镜像更新的 stack**:
   - 内核 (kernel): linux-cix-sky1-next 7.0.3 (相对 Radxa 当前
     基于 6.6 的 BSP)
   - 用户空间: Ubuntu 25.10 questing aarch64
   - cix-noe-umd 2.0.2 + libnoe (来自 archive.cixtech.com)
   - systemd-boot,启动计数自动回滚
   - 主机名规则 ncz-<MAC8hex>,十台同时部署不会冲突
   如果可行,Radxa 客户可以选用最新 Ubuntu 25.10 + 7.0.3 内核,
   而非现行的 Debian 12 + 6.6。

### Radxa 能得到什么

- 在 NCZ 发布说明中加上"已在 Orion O6 上测试通过"标识 + Radxa 署名;
- 在 embedkit 跨平台基准页面公开列出 O6 的实测数据;
- 测试中发现的内核/固件/设备树相关补丁,我会推送到 Sky1-Linux 上游;
- techbroiler.net 上的发行版评测文章(配合 r78 上线)中将明确感谢 Radxa
  并附上 O6 的链接;
- embedkit 文档中,NPU 适配器加上 "tested-on-O6" 标识。

每一个考虑用 Sky1 板做"低功耗代理常驻设备"的开发者,都会看到 Radxa 是
经过验证的目标平台。

### 工作量预估

如果有一台 O6 在手,我有把握在一个周末内把它做到与 MS-R1 同等可用度。

### 联系方式

- Email: jperlow@gmail.com
- Discord: perlowja
- 邮寄地址:
  Jason Perlow
  8466 NW 43RD COURT
  CORAL SPRINGS FL 33065
  USA

任何方便 Radxa 的形式都可以——借测、评测样机、以批发价采购,都行。
测试完成后我可以把样机寄回。

期待回复,谢谢。

—— Jason Perlow
   Argonaut Media Communications
   https://techbroiler.net | https://github.com/perlowja
