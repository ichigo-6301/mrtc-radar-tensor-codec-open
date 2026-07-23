# 架构

[English](../en/architecture.md) · [返回首页](../../README.md)

## 系统合同

RDTC 位于感知数据生成与片外存储或传输之间。Encoder 将连续 Range-Doppler block 转成带 metadata 的无损 packet；Decoder 在消费端恢复相同 I/Q 样本。

![OFDM sensing and RDTC system context](../assets/system_context.svg)

| 合同 | 公开基准 |
|---|---|
| Block | `1024` 个 I16Q16 sample，`4096` raw byte |
| Packet | 64-byte self-describing header + RAW/Rice payload |
| Stream | 128-bit AXI-Stream，精确 `tkeep/tlast`，支持 backpressure |
| Identity | Frame、Block 与 Range metadata 保留 packet 身份 |
| Reconstruction | Decoder bit-exact 恢复 I/Q；malformed stream fail closed |

接口与 packet 格式分别见[接口](interfaces.md)和[码流格式](bitstream_format.md)。

| 架构层 | 对应公开 RTL |
|---|---|
| 完整控制面 | [`mrtc_top`](../../rtl/top/mrtc_top.sv) + [`mrtc_axi_lite_reg_block`](../../rtl/top/mrtc_axi_lite_reg_block.sv) |
| 单 Engine codec | [`mrtc_rdtc_codec_top`](../../rtl/rdtc/mrtc_rdtc_codec_top.sv) |
| DDR Multi-Engine | [`mrtc_rdtc_ddr_multiengine_wrapper`](../../rtl/rdtc/mrtc_rdtc_ddr_multiengine_wrapper.sv) |
| AXIS32 FPGA adaptation | [`mrtc_rdtc_axis32_wrapper`](../../rtl/rdtc/mrtc_rdtc_axis32_wrapper.sv) |

## 单 Engine Pipeline

![Single-Engine encoder and decoder pipeline](../assets/single_engine_pipeline.svg)

单 Engine 按以下阶段工作：

1. **Capture**：AXI 输入捕获完整 block，ping-pong bank 让下一 block 接收与当前 block 计算重叠。
2. **Predict and map**：block 配置决定 ZERO 或 DELTA predictor；I/Q residual 分别映射为非负值。
3. **Cost and select**：prefix accumulator 对候选 `k` 统计代价，block policy 选择 `k`；仅支持 fallback 的 encoder path 才能改用 RAW。
4. **Pack and frame**：lane-parallel bitpacker 生成变长 payload，header generator 写入模式、长度与 Frame/Block metadata。
5. **Decouple output**：packet buffer 隔离计算侧与 AXI backpressure，并保持 packet 内容和边界稳定。
6. **Decode**：header parser 检查格式，Decoder 恢复 residual 与 I/Q sample，并严格使用 payload bit count。

DDR-backed `mrtc_rdtc_encoder_top` 支持基于编码代价的 RAW fallback；AXIS32 wrapper 使用的 small-buffer lane 未启用内部 RAW fallback。因此架构图把 RAW 标为 path-dependent 能力，而不是所有 wrapper 的共同保证。

## Multi-Engine Wrapper

![MRTC-RDTC Multi-Engine architecture](../assets/multi_engine_wrapper.svg)

Multi-Engine wrapper 解决单 Engine 数据相关延迟与输入供给之间的系统吞吐问题：

- Round-Robin dispatcher 只分配完整 block，不拆分一个 block 的内部状态；
- 每个 Engine 拥有独立 feeder、codec state 和 packet buffer；
- arbiter 一旦选中 packet，就保持 grant 直到该 packet 的 `tlast`；
- 不同 packet 的 beat 不交织，但 packet 完成顺序可以变化；
- header metadata 保留 Frame/Block 身份，供消费端按索引重建序列。

### Ordering Contract

| 属性 | 保证 |
|---|---|
| Packet 原子性 | verified：一个 packet 内无 beat interleaving |
| 输入顺序保持 | 不保证；数据相关编码长度可能改变完成顺序 |
| `OUTPUT_IN_ORDER=1` | 未实现，公开 smoke 要求该配置 fail fast |
| 实际乱序事件 | 记录 workload 未直接观察到，因此不声明“乱序场景已触发” |
| 软件 reorder | metadata 支持 indexed reconstruction，但不声明软件程序 PASS |

该选择避免硬件 Reorder Buffer 的缓存开销、控制复杂度与 head-of-line blocking，同时把顺序恢复策略显式留在系统集成层。

## 吞吐扩展

历史 fixed-commit 256-block workload 使用 simulated DDR feeder，1/2/4 Engine 分别达到 `785 / 397.52 / 197.41 cycles/block`。2/4 Engine efficiency 为 `0.987368 / 0.994115`；一个 beam 在该记录中定义为 256 个 block。

![Multi-Engine RTL simulation scaling](../assets/engine_scaling.svg)

假设 200 MHz 时，由 CSV 中未舍入的总周期投影得到 `1965.3022 / 3957.4642 beam/s`。这些是 RTL simulation projection，不是 FPGA implemented timing、板级 DDR 测量或网络吞吐。当前公开 adaptation 仅运行 2-Engine、2-block correctness smoke，不重算历史性能矩阵。

来源：[Multi-Engine evidence](../../evidence/rdtc_v1_multiengine_rtl.yaml) · [公开 CSV](../../evidence/data/rdtc_v1_multiengine_scaling.csv)

## 存储实现边界

`register-expanded` 与 `sram-macro` profile 保持相同外部 AXI、packet 和功能合同，只改变 prefix/sample buffer 的物理 binding。同步 SRAM 的一拍读延迟由 wrapper 适配；存储实现差异不表示删除 buffer 功能或改变码流。

[查看 ASIC 实现与 profile maturity](asic_implementation.md)
