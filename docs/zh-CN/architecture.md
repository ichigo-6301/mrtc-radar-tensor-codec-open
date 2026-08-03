# 架构

[English](../en/architecture.md) · [返回首页](../../README.md)

## 系统合同

RDTC 接收 FFT backend 产生的 Range-Doppler-Beam 数据，位于感知数据生成与片外存储或传输之间；它不实现上游 FFT。硬件实现与性能优化以 Encoder/压缩数据面为主，packet 面向 DDR、互联或 PC 上传。接收端可由 PC/C decoder 从常规 self-describing packet 恢复原始 I/Q；RTL decoder 用于协议闭环、bit-exact loopback、malformed-packet 检查及硬件解码参考，不声明生产 ASIC 必须实例化 RTL decoder。

![OFDM sensing and RDTC system context](../assets/system_context.svg)

| 合同 | 公开基准 |
|---|---|
| Block | `1024` 个 I16Q16 sample，`4096` raw byte |
| Packet | 64-byte self-describing header + RAW/Rice payload |
| Stream | 主接口为 128-bit AXI-Stream；packet 以 TLAST 结束，尾拍字节数由 TUSER 给出 |
| Identity | Frame、Block 与 Range metadata 保留 packet 身份 |
| Reconstruction | PC/C decoder 恢复常规 header-length packet；RTL decoder 提供 bit-exact 验证与硬件参考 |

接口与 packet 格式分别见[接口](interfaces.md)和[码流格式](bitstream_format.md)。

| 架构层 | 对应公开 RTL |
|---|---|
| 完整控制面 | [`mrtc_top`](../../rtl/top/mrtc_top.sv) + [`mrtc_axi_lite_reg_block`](../../rtl/top/mrtc_axi_lite_reg_block.sv) |
| 单 Engine codec | [`mrtc_rdtc_codec_top`](../../rtl/rdtc/mrtc_rdtc_codec_top.sv) |
| DDR Multi-Engine | [`mrtc_rdtc_ddr_multiengine_wrapper`](../../rtl/rdtc/mrtc_rdtc_ddr_multiengine_wrapper.sv) |
| Bounded Direct-AXIS 双 Engine（opt-in） | [`mrtc_rdtc_bounded_axis_multiengine_wrapper`](../../rtl/rdtc/mrtc_rdtc_bounded_axis_multiengine_wrapper.sv) |
| AXIS32 FPGA adaptation | [`mrtc_rdtc_axis32_wrapper`](../../rtl/rdtc/mrtc_rdtc_axis32_wrapper.sv) |

## 历史 Full-Block 单 Engine Pipeline

![Historical full-block/ping-pong Single-Engine encoder and decoder pipeline](../assets/single_engine_pipeline.svg)

下图与本节描述历史 full-block/ping-pong profile，不是当前 bounded Direct-AXIS 的四路浅 ring。它用于解释 Lane4 Bitpacker 与 buffered Multi-Engine 结果所依赖的架构阶段。

单 Engine 按以下阶段工作：

1. **Capture**：AXI 输入捕获完整 block，ping-pong bank 让下一 block 接收与当前 block 计算重叠。
2. **Predict and map**：block 配置决定 ZERO 或 DELTA predictor；I/Q residual 分别映射为非负值。
3. **Cost and select**：prefix accumulator 对候选 `k` 统计代价，block policy 选择 `k`；仅支持 fallback 的 encoder path 才能改用 RAW。
4. **Pack and frame**：lane-parallel bitpacker 生成变长 payload，header generator 写入模式、长度与 Frame/Block metadata。
5. **Decouple output**：packet buffer 隔离计算侧与 AXI backpressure，并保持 packet 内容和边界稳定。
6. **Decode**：header parser 检查格式，Decoder 恢复 residual 与 I/Q sample，并严格使用 payload bit count。

DDR-backed `mrtc_rdtc_encoder_top` 支持基于编码代价的 RAW fallback；AXIS32 wrapper 使用的 small-buffer lane 未启用内部 RAW fallback。因此架构图把 RAW 标为 path-dependent 能力，而不是所有 wrapper 的共同保证。

## Descriptor/DDR Multi-Engine Wrapper

![Descriptor 与 DDR-backed MRTC-RDTC Multi-Engine architecture](../assets/multi_engine_wrapper.svg)

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

## Bounded Direct-AXIS Profile

![当前 bounded Direct-AXIS 双 Engine 架构](../assets/bounded_direct_dual_engine.svg)

opt-in Direct profile 面向受约束信号域，以更少存储完成双 Engine 调度。单路 AXIS128 每个 block 输入 256 拍；两项 job table 将完整 block 严格按 Engine 0、Engine 1 轮转，输出按输入 job 顺序选择 Engine，并锁定 packet 直到 `tlast`。

每个 Engine 包含四个 `32x128` true-1RW way、两项 registered ingress queue、prefix-128 estimator 与固定速率 bounded bitpacker。Estimator 直接观察已接收输入，不占用 RAM 读端口。Wrapper 删除 DDR feeder 和每 Engine payload commit store，仅使用全局 16-beat FIFO 吸收短输出 stall。双 Engine bulk ring 共 `32,768 bit`，而之前 payload-backed 实验的 bulk storage 为 `180,224 bit`。

<a id="four-way-shallow-input-ring"></a>

### 四路浅输入 Ring

该 ring 只属于 bounded Direct-AXIS Encoder。它位于 AXIS input capture 与 Bitpacker 之间，不是 output FIFO，也不是历史 full-block ping-pong buffer。每个 Engine 的物理容量为 `4 ways x 32 words x 128 bits = 2048 bytes`，即 4096-byte block 的一半。Prefix estimator 直接观察已握手输入；`prefix-128` 指前 128 个 complex sample，也就是前 32 个 AXIS128 beat，并不等于 128-beat ring 容量。

对 zero-based global AXIS word index：

```text
way    = floor(global_word_index / 32) mod 4
offset = global_word_index mod 32
```

| Global word | Physical way | 行为 |
|---|---:|---|
| `0-31` | 0 | 首次填充 |
| `32-63` | 1 | 首次填充 |
| `64-95` | 2 | 首次填充 |
| `96-127` | 3 | 首次填充 |
| `128-159` | 0 | 复用已释放 slot |
| `160-191` | 1 | 复用已释放 slot |
| `192-223` | 2 | 复用已释放 slot |
| `224-255` | 3 | 复用已释放 slot |

每个已接收输入 word 写入映射 slot 并设置 valid；已接受 ring read 清除该 slot 的 valid，使后续 wrap 可以复用。Read request 到对外 response 是固定两拍。不同 way 的 read/write 可以同周期重叠；true-1RW way 上同周期读写即使 offset 不同也非法，并产生 way conflict。写入仍 valid 的 slot 或读取 invalid slot 会产生 ring error，并由 bounded Encoder 上升为 sticky fatal。

<a id="stream-timing-contract"></a>

### Stream Timing 合同

时序图是 protocol schematic，不是 measured waveform。前 32 个已接收 beat 提供 128 个 prefix sample；prefix `k` 选定后可开始四拍 header，同时后续输入仍可写 ring。Header 完成后 Bitpacker 按原始顺序发起 ring read，连续合法请求的 source cadence 为 `II=1`，response 固定延迟两拍。

四个 header beat 各自在 `TVALID && TREADY` 时提交。Rice token 累加只有形成完整输出 word 时才产生 payload beat，因此 header 与 payload 之间以及 payload 内都允许 `TVALID` bubble。下游拉低 `TREADY` 时，当前 `TVALID`、`TDATA`、`TLAST` 与 `TUSER` 必须保持到握手；TLAST 只出现在物理 packet 末尾。Ring-read source `II=1` 不代表 compressed-output `TVALID` 每拍连续。

该简化结构采用明确的 fail-stop 语义：

- 只接受 `ZERO_RICE` 与 block-adaptive prefix `k`；
- 每个 8-sample Rice word 必须不超过 `128 bit`；
- `k` 可用后，一个 Engine 以 `II=1` 连续发出 256 个 ring read；
- 同 way 读写冲突、cadence 中断、block 格式错误或 output credit 耗尽均产生 sticky fatal；
- 因为没有 speculative payload storage，fatal 可能让外部看到半包，producer 与 receiver 必须一起 reset。

固定回归测得有序 packet service 约 `277 cycles`，而连续 block 每 `256 cycles` 到达；该差额会累计并最终触发合法 way conflict。这是 workload evidence，不是协议保证周期，也不画入时序 schematic。该 profile 验证 bounded datapath 与实现闭合，但不验证持续零间隔调度。

## 历史 Buffered 吞吐扩展

历史 fixed-commit 256-block workload 以同 workload 的 Stage16D2 `785 cycles/block` 单 Engine 结果作为 reference；2/4-Engine buffered-wrapper run 达到 `397.52 / 197.41 cycles/block`，efficiency 为 `98.7368% / 99.4115%`。该 1-Engine reference 未以 wrapper `NUM_ENGINES=1` 重新实测；一个 beam 在该记录中定义为 256 个 block。

![历史 buffered Multi-Engine RTL simulation scaling](../assets/engine_scaling.svg)

假设 200 MHz 时，由 CSV 中未舍入的总周期投影得到 `1965.3022 / 3957.4642 beam/s`。这些是 RTL simulation projection，不是 FPGA implemented timing、板级 DDR 测量或网络吞吐。当前公开 adaptation 仅运行 2-Engine、2-block correctness smoke，不重算历史性能矩阵。

来源：[Multi-Engine evidence](../../evidence/rdtc_v1_multiengine_rtl.yaml) · [公开 CSV](../../evidence/data/rdtc_v1_multiengine_scaling.csv)

## 存储实现边界

历史 `register-expanded` 与 `sram-macro` profile 保持相同外部 AXI、packet 和功能合同，只改变 prefix/sample buffer 的 binding。Direct profile 对 8 个 `32x128` way 使用同一原则：要么全部展开为标准单元，要么全部绑定 1RW OpenRAM 宏；16-beat output queue 与控制状态仍是寄存器。Memory binding 的变化不删除 buffer 功能，也不改变 packet bytes。

[查看 ASIC 实现与 profile maturity](asic_implementation.md)
