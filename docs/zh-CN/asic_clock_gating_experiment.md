# Direct 映射级自动时钟门控功耗 A/B

[English](../en/asic_clock_gating_experiment.md) · [Stage 1 架构功耗实验](asic_power_experiment.md) · [结果](results.md)

## 结论

本 Stage-2 实验比较 Direct-AXIS 未门控映射实现 `G0` 与同一 Direct-AXIS
自动时钟门控实现 `G1`。私有权威分类为
`MRTC_CLOCK_GATING_MAPPED_POSITIVE_PRIVATE`；公开包从脱敏机器证据确定性复算。

<p align="center">
  <a href="../../evidence/rdtc_v1_clock_gating_mapped_dc/README.md"><img src="../assets/rdtc_stage2_clock_gating_power.svg" width="1000" alt="Stage-2 Direct G0 与 G1 自动时钟门控 mapped-power 对比"></a>
</p>

该协调图提供 Stage-2 总览；下文保留 coverage 分母、等价性、activity、审计 caveat
与成熟度边界。

两个功耗实验回答不同问题：

| 阶段 | Baseline | Candidate | 唯一主要变量 |
|---|---|---|---|
| Stage 1 | Buffered | Direct-AXIS | wrapper 架构与存储职责 |
| Stage 2 | Direct G0 | Direct G1 | Design Compiler 自动时钟门控 |

Stage-2 百分比只相对 Direct G0，不与 Stage-1 百分比相加，也不表述为一个合并节省。

## 固定合同

两点均使用 `mrtc_rdtc_bounded_axis_multiengine_wrapper`、双 Engine、
register-expanded Direct-AXIS、Nangate45 TT / 1.1 V / 25 C、315 MHz
（`3.174603 ns`）且禁用 retiming。G0 禁用门控；G1 使用 272 个
`CLKGATETST_X1`，功能态 `test_enable=0`。

| 实现指标 | G0 未门控 | G1 门控 | Candidate minus baseline |
|---|---:|---:|---:|
| Cell area | 420,208.442440 um2 | 354,760.204745 um2 | -15.58% |
| Setup WNS | +0.093015 ns | +0.0151572 ns | 均闭合 |
| Setup TNS | 0 ns | 0 ns | 不变 |
| Electrical violations | 0 | 0 | 不变 |
| ICG count | 0 | 272 | 仅 `CLKGATETST_X1` |
| Gating setup / hold WNS | N/A | +1.4645 / +0.18546 ns | 均闭合 |

面积负变化是这组受控映射综合的结果，不推广为“时钟门控通常减小面积”。

## Coverage 分母

Evidence 严格区分 register bit 与 mapped sequential cell：

| 数量 | 值 | 含义 |
|---|---:|---|
| Gated bits | 34,816 | G1 实际门控寄存器 bit |
| Post-map sequential bits | 50,988 | G1 `all_registers` bit 分母；门控 68.28273319212363693418059151% |
| Precompile register bits | 55,929 | common checkpoint bit 分母；门控 62.2503531262851114806272238% |
| Mapped sequential cells | G0 50,999 / G1 51,271 | `report_area` cell 数，不作 bit 分母 |
| Ring data bits | 32,768 / 32,768 | Ring data coverage 100% |

公开材料不在缺少分母时单列一个 state coverage 百分比。

## Workload

- `IDLE`：测量 4,096 cycle；无 descriptor/input traffic，完成 block 为 0，
  clock 持续运行。
- `BURST_IDLE`：完成 32 block，共四组、每组 8 block；每组 drain 后加入
  1,024 idle cycle；P0/P1 固定向量交替，输出 `TREADY` 始终为高。
- `ACTIVE_LEGAL`：完成 64 block；P0/P1 交替，block start 间隔 320 cycle，
  不加入人为长 idle gap，输出 `TREADY` 始终为高。

P0 为全零 block，selected `k=0`、20 个 packet beat；P1 为固定 bounded
non-zero pattern，selected `k=2`、72 个 packet beat。`ACTIVE_LEGAL` 是高占空
合法压缩 workload，不是 100% compressed-output `TVALID` duty、零间隔持续输入、
最大吞吐或 Fmax。

## Activity 方法

```text
G0/G1 mapped netlist
        |
        v
Questa zero-delay mapped gate simulation
        |
        v
workload-gated VCD measurement window
        |
        v
clip and rebase VCD -> vcd2saif
        |
        v
Design Compiler / Power Compiler
read DDC + mapped SDC + SAIF
        |
        v
coverage checks -> report_power
```

六点全部使用 `mapped_zero_delay`、`RACE_FREE_DRIVE`、功能态 SE=0、各自独立
activity artifact 和 0.0 default toggle/static probability。Clock、functional
input、sequential output、internal leaf pin 与 overall non-default 的 Activity
Annotation Coverage 均为 100%。Activity Annotation Coverage 不是验证 test coverage，
也不表示 code、functional、assertion、toggle 或 fault coverage closure。

## 功能证据与 ICG 模型

接受结果只称 **gate-level regression equivalence evidence**，不是 Formality
结果。G0/G1 在最小 2-block、32-block `BURST_IDLE` 与 64-block
`ACTIVE_LEGAL` 中的 packet data、selected k、TLAST/TUSER、decoder output、
status、count 和顺序均 bit-exact。

实际解析的 `CLKGATETST_X1` functional model 只有一个定义，无 duplicate/shadow；
`CK/E/SE/GCK` 与 audited library 的 pin 和 polarity 一致，A-F canary 全部通过。
模型不含 timing check，因此能力记录为 `NOT_SUPPORTED_BY_MODEL`，而不是 PASS。

历史 GLS mismatch 的根因是未解析的 test-enable bind：top test port 与 272 个
ICG `SE` 为 Z/X。使用固定为 0 的具名 `.power_test_en(CG_TEST_ENABLE)` 后，
在不修改 production RTL 的条件下恢复功能等价。SE=1 bypass 仅用于诊断，仍有
一个 output mismatch；它不构成 DFT/scan evidence，也不进入功耗分析。

## 结果

| Workload / 指标 | G0 | G1 | Candidate minus baseline |
|---|---:|---:|---:|
| IDLE dynamic | 66.9676 mW | 27.7229 mW | -58.60% |
| IDLE total | 75.507 mW | 34.826 mW | -53.88% |
| BURST_IDLE dynamic | 107.3535 mW | 41.1522 mW | -61.67% |
| BURST_IDLE total | 115.4 mW | 47.942 mW | -58.46% |
| BURST_IDLE energy/block | 164.5480357 nJ | 68.3601554 nJ | -58.46% |
| ACTIVE_LEGAL dynamic | 107.2775 mW | 43.4293 mW | -59.52% |
| ACTIVE_LEGAL total | 115.3 mW | 50.209 mW | -56.45% |

`BURST_IDLE` 下 sequential power 变化 -61.41%，internal power -63.10%，
switching power -11.80%，leakage -15.53%。页面仅作显示舍入，精确十进制权威
保存在 `points.csv` 与 `comparisons.csv`。

全部 promotion gate 通过：等价、activity coverage、34,816 gated bits、
68.28% post-map gated-bit coverage、100% Ring coverage、BURST dynamic、
sequential/internal 与 energy 收益、ACTIVE dynamic 非回退、面积、setup、
electrical，以及 clock-gating setup/hold。

## 审计 caveat

导出的 mapped SDC 产生 8,136 对 vector replay error。结果按
`MAPPED_SDC_VECTOR_REPLAY_ERRORS_DDC_CONSTRAINTS_PRESERVED` 接受，因为加载的
DDC 保留约束，且 mapped-SDC hash、clock/period/corner、WNS/TNS、零 electrical
violation 与 `check_timing` 均一致；这不形成 portable mapped-SDC handoff claim。

六份报告均正常完成。Outer exit code 2 来自旧 parser 错把 echoed Tcl marker
识别为失败；修正后的 parser 只重读 immutable report，没有重跑 EDA，恢复六点，
process ownership 最终为 `FULL_RELEASED`。

## 成熟度与边界

本结果是 activity-driven mapped-netlist estimate，不声明 routed power、CTS
clock-tree power、PrimeTime-PX、silicon measurement、foundry signoff、DFT/scan
closure、Fmax 或 workload-independent saving。Mapped `clock_mw` 只保留为工具
输出，不解释为物理 clock-tree power。

机器权威与确定性验证见
[Stage-2 Evidence 包](../../evidence/rdtc_v1_clock_gating_mapped_dc/README.md)。
