# 流时序与 Packet 服务

[English](../en/stream_timing.md) · [返回首页](../../README.md)

本页面向 IP 集成和数字 IC 代码审阅，区分 AXIS 协议合同、固定回归观测和历史吞吐结果。它不新增 RTL 功能，也不把协议 schematic 写成通用延迟保证。

<a id="protocol-timing-contract"></a>

## Protocol Timing 合同

当前 bounded Direct-AXIS profile 是一个固定双 Engine wrapper：单路输入每个 block 为 `256` 个完整 AXIS128 beat，descriptor 按 Engine `0 -> 1` 轮转，输出 packet 按 job 顺序选择并锁定到 `TLAST`。输入 producer 必须先完成 descriptor 预约，只在 wrapper 报告的合法 ready 窗口发送数据。

![Bounded Direct-AXIS protocol timing schematic](../assets/rdtc_stream_timing.svg)

上图是 protocol schematic，不是 measured waveform。协议上的时序关系是：

```text
input:       256 accepted AXIS128 beats; input TLAST on beat 255
prefix:      first 32 AXIS beats = 128 samples; selected_k becomes valid
ring:        legal capture writes, then ordered read requests after k
source II:   one ring/Bitpacker source request per cycle when legal
response:    fixed two-clock request-to-response contract
output:      4 header beats, then variable payload beats, then packet TLAST
backpressure: TVALID/TUSER/TDATA/TLAST hold while TREADY is low
```

`II=1` 只描述 ring/Bitpacker 每周期接收一个 128-bit source word 的 request cadence，不表示 `m_axis_comp_tvalid` 每周期都为 `1`。Rice token 累积和输出 word 对齐会产生合法 payload bubble；fail-stop halt 是普通 AXIS 保持语义的显式例外。

<a id="direct-engine0-trace"></a>

## Direct Engine 0 / Block 0 Trace

预留 Evidence：`evidence/rdtc_v1_direct_stream_timing_trace.yaml`。该记录应由固定 register-expanded ModelSim regression 生成，并绑定 nominal 与 backpressure 场景的逐周期 CSV、testbench/filelist 身份及 trace SHA256。

观测对象是**双 Engine wrapper 内 Engine 0 / Block 0 的切片**，不是把 wrapper 改成 `NUM_ENGINES=1`，也不是独立单 Engine 系统吞吐实验。nominal 场景保持输出 `TREADY=1`，用于观察输入 fire、prefix 完成、ring request、四拍 header、payload bubble 和 packet `TLAST`；backpressure 场景在 header 与 payload 各施加固定 stall，用于检查 stall 时 packet 数据和边界保持。

推荐的 trace 字段包括 `cycle`、`input_fire`、`prefix_done`、`selected_k_valid`、`ring_rd_req`、`m_axis_tvalid`、`m_axis_tready`、`m_axis_tlast`、`engine_id` 与 `block_id`。未来 Evidence 发布前，必须以实际 ModelSim 输出核对这些字段，不能从 schematic 推导周期数。

<a id="backpressure-hold"></a>

## Backpressure Hold

在正常非 fatal 路径中，当 `m_axis_comp_tvalid=1` 且 `m_axis_comp_tready=0` 时，当前 `TDATA`、`TUSER`、`TLAST` 和 packet owner 必须保持，直到握手完成。packet 内可以有空拍，但不能在一个 packet 内交织不同 Engine 的 beat。Direct output credit 耗尽会进入 sticky fatal；该 fail-stop 情况不应被描述为普通 backpressure hold 的成功案例。

<a id="multi-engine-packet-service"></a>

## Multi-Engine Packet Service

历史 buffered wrapper 的模型是 block 级 Round-Robin、每 Engine 独立 packet buffer、共享输出 packet-lock：

```text
Input blocks   B0 -------- B1 -------- B2 -------- B3
Dispatcher     E0          E1          E0          E1

Engine 0                 P0 ---------------- P2 ----
Engine 1                       P1 ---------------- P3

Shared AXIS     | Packet 0 | gap | Packet 1 | Packet 2 |
                <--- packet lock --->
```

这是 packet 原子性和可能存在 packet 间空拍的示意；实际完成顺序由数据相关编码长度决定。未来专用展示图预留为 `docs/assets/rdtc_multiengine_packet_timing.svg`，不把它与当前 Direct Engine 0 trace 或历史 scaling CSV 混成一个 workload。

历史 fixed-commit 256-block workload 的 Stage16D2 单 Engine reference 为 `785 cycles/block`，2/4 Engine buffered wrapper 为 `397.52 / 197.41 cycles/block`，扩展效率为 `98.7368% / 99.4115%`。其中 `785` 是导入 reference，不是 wrapper `NUM_ENGINES=1` 重跑；`8220 -> 785` 是平均 packet-completion spacing 的历史 A/B，和 `7693 -> 721` 的 payload interval 不是同一指标。

<a id="measurement-boundaries"></a>

## Measurement Boundaries

- `7693 -> 721 cycles`：固定 `smoke_zero_sparse` workload，从首个 payload valid 到 accepted `TLAST` 的 inclusive payload interval；不是 whole-block latency、Multi-Engine 吞吐或 Direct-AXIS 持续吞吐。
- `785 / 397.52 / 197.41 cycles/block`：历史 buffered profile 的 RTL simulation projection；不是 FPGA 时序、板级 DDR 或网络测量。
- 当前 Direct profile 的有序 packet service 约 `277 cycles/block`，而零间隔输入到达间隔为 `256 cycles/block`；这保留为 scheduler 限制，不升级为协议保证或持续吞吐 PASS。
- 未来 trace 是有限 ModelSim 观测，不是所有参数、所有压缩码长、所有 backpressure 模式的形式证明或 coverage closure。

相关规范入口：[接口合同](interfaces.md) · [码流格式](bitstream_format.md) · [四路浅输入 ring](architecture.md#four-way-shallow-input-ring) · [验证矩阵](verification.md)
