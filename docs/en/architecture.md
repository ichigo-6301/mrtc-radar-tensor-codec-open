# Architecture

[中文](../zh-CN/architecture.md)

## System Position

RDTC sits between sensing-data production and off-chip storage or transport. The encoder converts continuous Range-Doppler blocks into lossless packets with metadata; the decoder restores the same I/Q samples at the consumer. See [Interfaces](interfaces.md) and [Bitstream Format](bitstream_format.md) for the external contracts.

![OFDM sensing and RDTC system context](../assets/system_context.svg)

## Single-Engine Data Path

![Single-Engine encoder and decoder pipeline](../assets/single_engine_pipeline.svg)

A single Engine contains these stages:

1. AXI input capture fills a complete block, while ping-pong buffering overlaps reception of the next block with computation on the current block;
2. the configured per-block predictor mode produces ZERO or DELTA residuals, and the signed mapper converts them to non-negative values;
3. the prefix accumulator evaluates candidate `k` costs, and the internal block policy selects `k`; encoder paths with payload-cost fallback may select RAW when a Rice payload is not beneficial;
4. the lane-parallel bitpacker emits a variable-length payload, while the header generator records mode, length, and Frame/Block metadata;
5. the packet buffer decouples computation from AXI output backpressure; where RAW fallback is enabled, it uses the same packet contract;
6. the decoder parses the header, checks format rules, reconstructs residuals and I/Q samples, and verifies packet boundaries.

The public benchmark block contains `1024` I16Q16 samples, or `4096` raw bytes. Packets use a `64`-byte header and a 128-bit AXI-Stream data path.

`ZERO_RICE` versus `DELTA_RICE` is supplied by the block descriptor or configuration; the internal `k` policy does not choose between those predictor modes. The DDR-backed `mrtc_rdtc_encoder_top` supports payload-cost RAW fallback, while the AXIS2Eng small-buffer lane used by the AXIS32 wrapper does not enable internal RAW fallback. Any integration claim must therefore name the encoder path whose fallback behavior was exercised.

## Multi-Engine Wrapper

![MRTC-RDTC Multi-Engine architecture](../assets/multi_engine_wrapper.svg)

The parameterized wrapper addresses the system-throughput gap between data-dependent Engine latency and input bandwidth:

- a Round-Robin dispatcher assigns whole blocks to available Engines;
- every Engine has an independent feeder, codec, and packet buffer, avoiding shared intermediate state;
- once the arbiter selects a packet, it remains locked until that packet's `tlast`, so beats from different packets never interleave;
- completion depends on block data and compressed length, so output order is not guaranteed;
- Frame/Block metadata in the header preserves identity and enables indexed reconstruction in software.

Each descriptor carries the configured codec mode into its assigned Engine. The Engine performs internal `k` selection, and RAW fallback is present only when that encoder variant implements the payload-cost fallback path.

The architecture chooses packet-atomic output with bounded reordering instead of a hardware Reorder Buffer, avoiding strict-order buffering, control complexity, and head-of-line blocking. `OUTPUT_IN_ORDER` is not an implemented mode; integrations must not interpret that parameter as a hardware ordering guarantee.

Existing regression checks packet contents, boundaries, and identity, but the recorded scenarios do not directly prove an observed out-of-order event and do not include a verified software reorder program. The accurate claim is therefore that metadata enables indexed software reconstruction, not that software reordering has passed.

## Throughput Scaling

On the historical fixed-commit 256-block workload, `1/2/4` Engines reach `785 / 397.52 / 197.41 cycles/block`. That workload defines one beam as 256 blocks. Two- and four-Engine efficiency is `0.987368 / 0.994115`; at an assumed 200 MHz, the unrounded total-cycle values project to `1965.3022 / 3957.4642 beam/s`.

![Multi-Engine RTL simulation scaling](../assets/engine_scaling.svg)

These results come from RTL simulation with a simulated DDR feeder. They are not implemented FPGA timing, measured board DDR performance, or network throughput. The current public adaptation has a two-Engine, two-block correctness smoke; it does not recompute the historical performance matrix.

## Memory-Implementation Boundary

The `register-expanded` and `sram-macro` profiles preserve the same external AXI, packet, and functional contracts. Only the physical binding of the prefix/sample buffer changes. A wrapper adapts the one-cycle synchronous SRAM read latency; the memory difference must not be described as removing the buffer function or changing the bitstream. See [ASIC Implementation](asic_implementation.md).
