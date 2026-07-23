# Architecture

[中文](../zh-CN/architecture.md) · [Back to README](../../README.en.md)

## System Contract

RDTC sits between sensing-data generation and off-chip storage or transport. The Encoder converts consecutive Range-Doppler blocks into lossless packets with metadata, and the Decoder reconstructs the same I/Q samples at the consumer.

![OFDM sensing and RDTC system context](../assets/system_context.svg)

| Contract | Public reference configuration |
|---|---|
| Block | `1024` I16Q16 samples and `4096` raw bytes |
| Packet | 64-byte self-describing header + RAW/Rice payload |
| Stream | 128-bit AXI-Stream with exact `tkeep/tlast` and backpressure support |
| Identity | Frame, Block, and Range metadata preserve packet identity |
| Reconstruction | Decoder restores I/Q bit-exactly and fails closed on malformed streams |

See [Interfaces](interfaces.md) and [Bitstream Format](bitstream_format.md) for the external contract.

| Architecture layer | Published RTL |
|---|---|
| Complete control surface | [`mrtc_top`](../../rtl/top/mrtc_top.sv) plus [`mrtc_axi_lite_reg_block`](../../rtl/top/mrtc_axi_lite_reg_block.sv) |
| Single-Engine codec | [`mrtc_rdtc_codec_top`](../../rtl/rdtc/mrtc_rdtc_codec_top.sv) |
| DDR Multi-Engine | [`mrtc_rdtc_ddr_multiengine_wrapper`](../../rtl/rdtc/mrtc_rdtc_ddr_multiengine_wrapper.sv) |
| AXIS32 FPGA adaptation | [`mrtc_rdtc_axis32_wrapper`](../../rtl/rdtc/mrtc_rdtc_axis32_wrapper.sv) |

## Single-Engine Pipeline

![Single-Engine encoder and decoder pipeline](../assets/single_engine_pipeline.svg)

A Single Engine progresses through these stages:

1. **Capture**: AXI input captures a complete block; ping-pong banks overlap reception of the next block with computation on the current block.
2. **Predict and map**: the block configuration selects ZERO or DELTA prediction, and I/Q residuals are independently mapped to non-negative values.
3. **Cost and select**: the prefix accumulator evaluates candidate `k` values, and the block policy selects `k`; only supporting encoder paths may fall back to RAW.
4. **Pack and frame**: the lane-parallel bitpacker emits the variable-length payload, while the header generator writes mode, length, and Frame/Block metadata.
5. **Decouple output**: the packet buffer isolates computation from AXI backpressure while preserving packet content and boundaries.
6. **Decode**: the header parser validates the format, and the Decoder reconstructs residuals and I/Q using the exact payload-bit count.

The DDR-backed `mrtc_rdtc_encoder_top` supports coding-cost-based RAW fallback. The small-buffer lane used by the AXIS32 wrapper has internal RAW fallback disabled. The architecture therefore presents RAW fallback as a path-dependent capability, not a universal wrapper guarantee.

## Multi-Engine Wrapper

![MRTC-RDTC Multi-Engine architecture](../assets/multi_engine_wrapper.svg)

The Multi-Engine wrapper addresses system throughput when Single-Engine latency depends on block data:

- the round-robin dispatcher assigns complete blocks and never splits block-local state;
- every Engine has an independent feeder, codec state, and packet buffer;
- once the arbiter selects a packet, it holds the grant through that packet's `tlast`;
- beats from different packets do not interleave, while packet completion order may vary;
- header metadata preserves Frame/Block identity for indexed reconstruction at the consumer.

### Ordering Contract

| Property | Guarantee |
|---|---|
| Packet atomicity | verified: no beat interleaving within a packet |
| Input-order preservation | not guaranteed; data-dependent encoded length may change completion order |
| `OUTPUT_IN_ORDER=1` | not implemented; the public smoke requires this configuration to fail fast |
| Observed reorder event | the recorded workload did not directly observe one, so no triggered-reorder claim is made |
| Software reorder | metadata supports indexed reconstruction, but no software implementation PASS is claimed |

This choice avoids the buffering, control complexity, and head-of-line blocking of a hardware reorder buffer while leaving ordering policy explicit at the system-integration layer.

## Throughput Scaling

The historical fixed-commit 256-block workload uses a simulated DDR feeder. The 1/2/4-Engine configurations achieve `785 / 397.52 / 197.41 cycles/block`, with 2/4-Engine efficiencies of `0.987368 / 0.994115`. One beam is defined as 256 blocks in this record.

![Multi-Engine RTL simulation scaling](../assets/engine_scaling.svg)

At an assumed 200 MHz, unrounded total-cycle values in the CSV project `1965.3022 / 3957.4642 beam/s`. These are RTL simulation projections, not FPGA implemented timing, measured board DDR throughput, or network throughput. The current public adaptation runs only a 2-Engine, 2-block correctness smoke and does not recompute the historical performance matrix.

Sources: [Multi-Engine evidence](../../evidence/rdtc_v1_multiengine_rtl.yaml) · [public CSV](../../evidence/data/rdtc_v1_multiengine_scaling.csv)

## Memory-Implementation Boundary

The `register-expanded` and `sram-macro` profiles preserve the same external AXI, packet, and functional contract while changing only the physical binding of prefix/sample buffers. A wrapper adapts the synchronous SRAM read latency; the memory implementation does not remove buffering behavior or change the bitstream.

[See ASIC implementation and profile maturity](asic_implementation.md)
