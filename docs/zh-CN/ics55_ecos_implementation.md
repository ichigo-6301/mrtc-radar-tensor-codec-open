# ICS55 ECOS 实现尝试

## 范围

本文记录 register-expanded RDTC wrapper 当前的物理实现边界。它与已验证的 ICS55 Design Compiler profile 独立，不新增物理性能 claim。

| 项目 | 结果 |
|---|---|
| PDK | ICsprout55 public-preview `v1.10.100`，commit `e696e093129ca2212487aa169af74d06ebd86eb6` |
| 标准单元库 | `ics55_LLSC_H7C_V1p10C100`，H7CR RVT，TT/1.2 V/25 C |
| 设计 | `mrtc_rdtc_wb_wrapper`，register-expanded，memory macro count 为 0 |
| DC handoff | 400 MHz mapped netlist 与匹配的 2.500 ns SDC |
| 物理工具 | ECOS Studio / iEDA stack，`0.1.0-alpha.5` |
| 物理目标 | 400 MHz |
| 完整设计状态 | 未完成 |

## 已完成阶段

完整 RDTC run 已完成 floorplan、fanout repair、placement、CTS 和 legalization。die 为 1145.211 x 1145.211 um，core utilization 约为 42%。placement 含 207,829 个 instance，CTS 服务 38,574 个 sink，target skew 为 0.080 ns。

不含 memory 的 platform canary 已从 synthesis 完成至 routed DEF/GDS，route-tool DRC 为 0。该结果只证明所选平台能力，不是 RDTC 产品物理证据。

## Route 尝试

完整 400 MHz route 已通过 topology、layer assignment，并进入第一次 detailed-routing。默认 detailed router 保持为配置的九次迭代，不做缩短。该 route 未完成：

- 三次配置的 SpaceRouter 后，resource overflow 为 65,239；
- TrackAssigner 初始 route-tool violation 为 136,290；
- DetailedRouter 在 18:51 内到达 529/4,761 个 box，violation 为 252,151；
- 再运行 20:38 到达 1,058/4,761 个 box，violation 为 347,130；
- 第三个 box group 尚未完成时，RSS 持续增长、可用内存降至 256 MiB 以下。

为避免 OOM killer，运行通过 `SIGTERM` 受控停止。这是资源保护停止，不是成功 route，也不是通过缩短 flow 得到的快速 pass。未生成 routed DEF、routed GDS、routed netlist、route-stage SDC、SPEF 或 SDF。

## 时序状态

ECOS 内建 ICS55 RC 被分类为 `ECOS_BUILTIN_RC`，不称为 PDK-calibrated 或 foundry signoff RC。route 未完成，且不存在同次 routed netlist/SDC/SPEF，因此没有执行 RCX、native route timing、OpenSTA 或 PrimeTime post-route 分析。不声明任何 ICS55 post-route 频率或 WNS/TNS。

## 结果解释

公开结果仍是已验证的 ICS55 DC-only profile。完整设计的 ECOS 尝试是未完成的工程观察，不是 implementation profile，也不是有 evidence 支撑的 physical claim。它不改变已验证的 Nangate45 physical 结果。

下一次物理实验需要对 route 问题做显式评审，例如 floorplan、utilization、placement density 或 routing resource 研究，并建立新的独立 run identity。不能用更快或更短的 detailed-router 设置代替本文记录的默认 run。

