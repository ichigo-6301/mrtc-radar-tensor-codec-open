# Interfaces and Integration Entrypoints

[中文](../zh-CN/interfaces.md) · [Back to README](../../README.en.md)

## Which module should I instantiate?

| Use case | Canonical top | Filelist | Public check |
|---|---|---|---|
| Complete controlled IP with AXI4-Lite configuration and AXIS128 codec | [`mrtc_top`](../../rtl/top/mrtc_top.sv) | [`rdtc_v1.f`](../../flows/manifests/rdtc_v1.f) | `make integration-smoke` |
| Single-Engine encoder plus decoder | [`mrtc_rdtc_codec_top`](../../rtl/rdtc/mrtc_rdtc_codec_top.sv) | [`rdtc_v1.f`](../../flows/manifests/rdtc_v1.f) | `make integration-smoke`; see [`tb_rdtc_codec_top_smoke`](../../tb/sv/tb_rdtc_codec_top_smoke.sv) |
| Descriptor/DDR-feeder-driven N-Engine compression | [`mrtc_rdtc_ddr_multiengine_wrapper`](../../rtl/rdtc/mrtc_rdtc_ddr_multiengine_wrapper.sv) | [`rdtc_v1_multiengine_smoke.f`](../../flows/manifests/rdtc_v1_multiengine_smoke.f) | `make multiengine-smoke` |
| Bounded direct AXIS128 input with two Engines | [`mrtc_rdtc_bounded_axis_multiengine_wrapper`](../../rtl/rdtc/mrtc_rdtc_bounded_axis_multiengine_wrapper.sv) | [`rdtc_v1_bounded_direct.f`](../../flows/manifests/rdtc_v1_bounded_direct.f) | `make bounded-direct-rtl-smoke` and `make bounded-direct-rtl-identity-check` |
| AXIS32 adaptation from the historical Zynq trial | [`mrtc_rdtc_axis32_wrapper`](../../rtl/rdtc/mrtc_rdtc_axis32_wrapper.sv) | [`rdtc_v1_fpga_wrapper_smoke.f`](../../flows/manifests/rdtc_v1_fpga_wrapper_smoke.f) | `make fpga-wrapper-smoke` |

Start a new general integration from `mrtc_top`. Use `mrtc_rdtc_codec_top` when the surrounding system supplies configuration directly and needs only the codec datapath. The DDR and bounded Direct-AXIS wrappers are opt-in integration surfaces; neither replaces the AXI4-Lite control surface of `mrtc_top`.

## Fixed data contract

| Item | RDTC v1 contract |
|---|---|
| Raw sample | I16Q16 complex, signed 16-bit I and Q components |
| Tensor flattening | `S[spatial/beam, doppler, range]`; Range changes fastest; the producer supplies the flat sequence |
| Block | 1024 complex samples, 4096 raw bytes |
| Main datapath | 128-bit AXI-Stream, four I16Q16 samples per beat |
| Sample word | each 32-bit lane is `{Q[15:0], I[15:0]}`; bytes are little-endian I followed by Q |
| Packet | 64-byte little-endian header plus variable-length payload |
| Codec modes | `RAW_BYPASS`, `ZERO_RICE`, and `DELTA_RICE` |
| Tail bytes | on TLAST, `tuser[3:0] = valid_byte_count - 1`; the main AXIS128 interface has no TKEEP |

## Clock and reset

The published RTL uses one `clk` and an active-low synchronous datapath reset, `rst_n`. `i_clear_status` clears sticky status and counters only; it does not replace reset and must not interrupt an active AXI-Stream handshake. Every `tvalid/tready` transfer occurs on a rising `clk` edge.

## AXI-Stream encode transaction

1. Hold codec, Rice, and tensor-metadata configuration stable before the first block beat.
2. Submit an input beat only when `s_axis_raw_tvalid && s_axis_raw_tready`.
3. With zero-based indexing, assert `s_axis_raw_tlast` on beat 255, the 256th AXIS128 beat; it still carries four valid I16Q16 samples.
4. The encoder emits the 64-byte header before the payload.
5. The final output beat asserts `m_axis_comp_tlast`; on that beat `m_axis_comp_tuser[3:0]` carries valid-byte-count minus one, with `15` denoting a full 16-byte tail.
6. The consumer may deassert `m_axis_comp_tready` at any time; packet content and boundaries remain stable.

The decoder accepts the same physical packet boundary on `s_axis_comp_*` and reconstructs 1024 I16Q16 samples on `m_axis_raw_*`. Conventional C/RTL packets carry payload length in the header, while bounded Direct packets take physical length from TLAST/TUSER. See [Bitstream Format](bitstream_format.md#packet-length-contracts) for compatibility and the current C-decoder gap. Run `make codec-demo` for a fixed example whose input, packet, and decoded-output SHA256 values are recorded in the [codec demo evidence](../../evidence/rdtc_v1_codec_demo.yaml).

## Key parameters

| Module | Parameter | Meaning |
|---|---|---|
| `mrtc_top` | `AXIS_DATA_W=128` | Published datapath width; the current RDTC v1 contract fixes it at 128 bits |
| `mrtc_top` | `AXIL_ADDR_W=12`, `AXIL_DATA_W=32` | Control-plane address and data widths |
| codec/engine | `MRTC_K_POLICY_ARCH` | Full-adaptive or prefix-fast `k` selection architecture |
| codec/engine | `PREFIX_SAMPLES=256` | Published prefix-fast observation length |
| DDR wrapper | `NUM_ENGINES=2` | Engine count; public evidence covers the historical 2/4-Engine matrix and a 2-Engine adaptation smoke |
| DDR wrapper | `OUTPUT_IN_ORDER=0` | The only supported value; setting it to `1` fails fast |
| Direct wrapper | `NUM_ENGINES=2`, `ENGINE_BOUNDED_WAY_COUNT=4` | Fixed public dual-Engine, eight-way organization |
| Direct wrapper | `PREFIX_SAMPLES=128`, `OUTPUT_FIFO_DEPTH=16` | Fixed bounded prefix and global output-credit depth |

## Multi-Engine descriptor and output ordering

The DDR wrapper accepts raw address, Frame/Block ID, Range start, codec mode, and tensor shape through `s_desc_*`. Each Engine owns a feeder, codec, and packet buffer. Once the output arbiter selects a packet, it retains that Engine through `tlast`, so beats from different packets never interleave.

Completion order across blocks is not guaranteed. Frame/Block metadata in the header provides the identity needed for indexed software reconstruction, but this repository does not claim a software reorder program PASS. `OUTPUT_IN_ORDER=1` is unimplemented and explicitly fails fast.

## Bounded Direct-AXIS Contract

The Direct wrapper accepts a descriptor separately from the single `s_axis_raw_*` stream. The descriptor carries Block ID, Range start, Frame ID, tensor dimensions, codec/Rice fields, and `last_block`; it has no raw DDR address. A descriptor reserves exactly one Engine, and the following 256 accepted AXIS128 beats belong to that descriptor. Data arriving without a reserved descriptor is fatal.

The legal public configuration is `ZERO_RICE` plus block-adaptive prefix `k`. RAW, DELTA, fixed `k`, malformed early/late `tlast`, a Rice word above 128 bits, an `II=1` cadence break, or a same-way read/write collision fails closed. Descriptors rotate strictly through Engine `0 -> 1 -> 0 -> 1`; output remains job-table ordered and packet-locked to accepted `m_axis_comp_tlast`. Packet-internal `tvalid` gaps are legal, and `tlast` remains the only packet boundary.

The Direct input is a bounded fail-stop contract. Presenting `s_axis_raw_tvalid=1` while the reserved Engine is not ready raises `MRTC_ERR_BLOCK_NOT_READY`; it is not treated as indefinitely holdable ordinary input backpressure. The producer must complete a legal descriptor reservation and present data only in the ready window supported by this Direct wrapper. See [Architecture](architecture.md#four-way-shallow-input-ring) for ring capacity, reuse, and conflict rules.

The 16-beat output FIFO provides bounded backpressure credit. If downstream stalling consumes the emergency credit, `stat_error` becomes sticky `MRTC_ERR_OUTPUT_CREDIT` (`24`) and the wrapper stops accepting or emitting work. Because this path has no speculative payload commit store, already emitted beats cannot be rolled back. Recovery requires a real `rst_n` reset of both the wrapper and downstream packet receiver. `i_clear_status` clears counters only and cannot recover a fatal state.

## AXI4-Lite control plane

The `mrtc_top` AXI4-Lite interface exposes enable, soft reset, status clear, codec configuration, tensor metadata, counters, IRQ, and capability registers. See the [register map](register_map.md) for addresses and bit fields. The RTL [`mrtc_axi_lite_reg_block`](../../rtl/top/mrtc_axi_lite_reg_block.sv) is the final interface authority.

## Integration checklist

- Keep configuration stable for a complete block transaction.
- Align input `tlast` with the 1024-sample block boundary.
- Support arbitrary output `tready` backpressure and the TLAST/TUSER final-byte rule.
- Treat `tlast` as the packet-atomic boundary; do not assume Block IDs naturally emerge in order.
- For the Direct profile, submit a legal descriptor before data, enforce its bounded codec domain, avoid presenting input valid while ready is low, and reset both ends after any nonzero `stat_error`.
- Compile the tracked filelist for the selected top rather than manually omitting packages or helper modules.
- Run the corresponding smoke before delivery and leave the worktree clean apart from ignored build output.
