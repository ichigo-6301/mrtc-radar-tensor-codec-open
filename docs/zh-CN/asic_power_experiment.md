# Activity-Driven 架构功耗 A/B

[English](../en/asic_power_experiment.md) · [Stage 2 映射级时钟门控实验](asic_clock_gating_experiment.md) · [结果](results.md)

本页是 Stage-1 `Buffered -> Direct-AXIS` 架构实验。Stage 2 以 Direct G0
为自己的 baseline，并独立报告。

<p align="center">
  <a href="../../evidence/rdtc_v1_power_architecture_ab/README.md"><img src="../assets/rdtc_stage1_architecture_ppa_power.svg" width="1000" alt="Stage-1 Buffered 与 Direct-AXIS 架构 PPA 和 mapped-power 对比"></a>
</p>

该协调图提供 Stage-1 总览；下文保留完整 workload、coverage、层级功耗与成熟度边界。

## 结论

经审阅的 315 MHz Buffered-to-Direct 对比分类为 `ARCH_POWER_POSITIVE`。
功能归一化、activity coverage、source/library/constraint 身份、时序、
electrical check 与两项功耗 promotion 条件均通过；本实验未修改 production RTL。

自动时钟门控属于独立实验。后续 mapped 结果不改变本 Stage-1 baseline，也不允许
把两阶段百分比相加。本架构比较本身不声明 ICG、route 后功耗或 PrimeTime-PX 结果。

## 固定对比条件

| 项目 | A0 Buffered | A1 Direct-AXIS |
|---|---|---|
| Top | `mrtc_rdtc_ddr_multiengine_wrapper` | `mrtc_rdtc_bounded_axis_multiengine_wrapper` |
| Profile | buffered register-expanded | direct register-expanded |
| Engine | 2 | 2 |
| 频率 | 315 MHz | 315 MHz |
| Library/corner | Nangate45 TT, 1.1 V, 25 C | 相同 |
| 工具 | Design Compiler `O-2018.06-SP1` | 相同 |
| Activity 方法 | RTL SAIF 映射到 mapped design | 同一层级、独立 SAIF |
| Default activity | toggle `0.0`、static probability `0.0` | 相同 |
| Retiming | disabled | disabled |

每个 workload pair 的逻辑输入 word、selected-k 序列、descriptor 序列、
always-ready 策略、期望 packet beat、归一化 packet trace、block 数、raw/compressed
byte 数与随机种子均 hash-identical。结构不同的每个 mapped point 使用自己的
activity artifact。

## Workload 与 Coverage

| Workload | Block | Raw bytes | Compressed bytes | A0/A1 测量周期 |
|---|---:|---:|---:|---:|
| BURST_IDLE | 32 | 131,072 | 23,536 | 14,701 / 14,373 |
| ACTIVE_LEGAL | 64 | 262,144 | 47,072 | 20,575 / 20,493 |

两组 workload 的 output ready 始终有效。能量由每个 point 的精确测量周期与完成
block 数直接计算。`IDLE` 只保留为诊断 workload，不参与架构 promotion。

每种架构在两组 workload 中的 coverage 保持一致：

| 架构 | Clock | Functional inputs | Sequential outputs | Internal leaf pins | Overall non-default |
|---|---:|---:|---:|---:|---:|
| A0 Buffered | 100% | 100% | 99.964% | 99.642% | 99.662% |
| A1 Direct | 100% | 100% | 99.617% | 98.807% | 98.856% |

没有用非零 default toggle rate 人为填高 coverage。

## 结果

| 指标 | A0 Buffered | A1 Direct | Candidate minus baseline |
|---|---:|---:|---:|
| Cell area | 1,529,495.20 um2 | 420,208.44 um2 | -72.53% |
| Cell count | 786,342 | 220,298 | -71.98% |
| Sequential cells | 200,572 | 50,999 | -74.57% |
| BURST_IDLE dynamic power | 436.4352 mW | 109.8717 mW | -74.83% |
| BURST_IDLE total power | 462.70 mW | 117.53 mW | -74.60% |
| BURST_IDLE energy/block | 674.82 nJ | 167.59 nJ | -75.17% |
| ACTIVE_LEGAL dynamic power | 435.6544 mW | 108.9786 mW | -74.99% |
| ACTIVE_LEGAL total power | 461.95 mW | 116.65 mW | -74.75% |
| ACTIVE_LEGAL energy/block | 471.46 nJ | 118.58 nJ | -74.85% |

确定性 gate 比上述显示百分比更保守：它以 baseline 减去自身 report quantization
bound、candidate 加上自身 bound 后再判定。BURST_IDLE dynamic 的保守节省为
`74.819%`，高于 `10%` 门槛；ACTIVE_LEGAL dynamic 的保守变化为 `-74.979%`，
满足最大允许回退 `+3%` 的限制。

## 层级解读

BURST_IDLE 下，Buffered hierarchy 的 root 约为 `463 mW`；两个 packet-buffer
hierarchy 各约 `156 mW`，两个 feeder hierarchy 约为 `20.4/20.0 mW`，两个 codec
Engine 各约 `54.6 mW`。Direct root 约为 `117 mW`，两个 Engine 各约 `55.7 mW`，
共享 output FIFO 约为 `4.79 mW`。

这与 storage/data-movement 重构相符：codec Engine 本体仍处于同一功耗量级，
而 Buffered feeder 与 payload-commit storage hierarchy 被移除。Hierarchy row
可能彼此嵌套且受显示精度限制，不能当作互斥 bucket 直接求和。

## 成熟度与未声明项

本结果是 **activity-driven mapped-netlist power estimate**，不是：

- route 后或 PrimeTime-PX 功耗；
- CTS clock-tree 功耗；
- 芯片实测或 foundry-signoff 功耗；
- maximum-frequency 结果；
- 对未测试流量模式的通用节省结论；
- 本 Stage-1 包内部的自动时钟门控证据。

两份 mapped report 都包含 `clock_mw = 0`。Evidence 将 zero-to-zero 对比保留为
零 delta，但不把它解释为物理 clock-network 测量。

机器可读 Evidence 与验证命令见
[架构功耗证据包](../../evidence/rdtc_v1_power_architecture_ab/README.md)。

下一阶段见独立的
[Direct G0/G1 映射级时钟门控实验](asic_clock_gating_experiment.md)。
