# Interfaces and Integration Entrypoints

## Which module should I instantiate?

| Use case | Canonical top | Filelist | Public check |
|---|---|---|---|
| Complete controlled IP with AXI4-Lite configuration and AXIS128 codec | [`mrtc_top`](../../rtl/top/mrtc_top.sv) | [`rdtc_v1.f`](../../flows/manifests/rdtc_v1.f) | `make integration-smoke` |
| Single-Engine encoder plus decoder | [`mrtc_rdtc_codec_top`](../../rtl/rdtc/mrtc_rdtc_codec_top.sv) | [`rdtc_v1.f`](../../flows/manifests/rdtc_v1.f) | `make integration-smoke`; see [`tb_rdtc_codec_top_smoke`](../../tb/sv/tb_rdtc_codec_top_smoke.sv) |
| Descriptor/DDR-feeder-driven N-Engine compression | [`mrtc_rdtc_ddr_multiengine_wrapper`](../../rtl/rdtc/mrtc_rdtc_ddr_multiengine_wrapper.sv) | [`rdtc_v1_multiengine_smoke.f`](../../flows/manifests/rdtc_v1_multiengine_smoke.f) | `make multiengine-smoke` |
| AXIS32 adaptation from the historical Zynq trial | [`mrtc_rdtc_axis32_wrapper`](../../rtl/rdtc/mrtc_rdtc_axis32_wrapper.sv) | [`rdtc_v1_fpga_wrapper_smoke.f`](../../flows/manifests/rdtc_v1_fpga_wrapper_smoke.f) | `make fpga-wrapper-smoke` |

Start a new integration from `mrtc_top`. Use `mrtc_rdtc_codec_top` when the surrounding system supplies configuration directly and needs only the codec datapath. The Multi-Engine DDR wrapper is a throughput-oriented interface; it does not replace the AXI4-Lite control surface of `mrtc_top`.

## Fixed data contract

| Item | RDTC v1 contract |
|---|---|
| Raw sample | I16Q16 complex, signed 16-bit I and Q components |
| Block | 1024 complex samples, 4096 raw bytes |
| Main datapath | 128-bit AXI-Stream, four I16Q16 samples per beat |
| Packet | 64-byte little-endian header plus variable-length payload |
| Codec modes | `RAW_BYPASS`, `ZERO_RICE`, and `DELTA_RICE` |
| Tail bytes | `tuser[3:0] = valid_byte_count - 1` |

## Clock and reset

The published RTL uses one `clk` and an active-low synchronous datapath reset, `rst_n`. `i_clear_status` clears sticky status and counters only; it does not replace reset and must not interrupt an active AXI-Stream handshake. Every `tvalid/tready` transfer occurs on a rising `clk` edge.

## AXI-Stream encode transaction

1. Hold codec, Rice, and tensor-metadata configuration stable before the first block beat.
2. Submit an input beat only when `s_axis_raw_tvalid && s_axis_raw_tready`.
3. Assert `s_axis_raw_tlast` on AXIS128 beat 256; that beat still carries four valid I16Q16 samples.
4. The encoder emits the 64-byte header before the payload.
5. The final output beat asserts `m_axis_comp_tlast`; `m_axis_comp_tuser[3:0]` carries valid-byte-count minus one.
6. The consumer may deassert `m_axis_comp_tready` at any time; packet content and boundaries remain stable.

The decoder accepts the same packet contract on `s_axis_comp_*` and reconstructs 1024 I16Q16 samples on `m_axis_raw_*`. Run `make codec-demo` for a fixed example whose input, packet, and decoded-output SHA256 values are recorded in the [codec demo evidence](../../evidence/rdtc_v1_codec_demo.yaml).

## Key parameters

| Module | Parameter | Meaning |
|---|---|---|
| `mrtc_top` | `AXIS_DATA_W=128` | Published datapath width; the current RDTC v1 contract fixes it at 128 bits |
| `mrtc_top` | `AXIL_ADDR_W=12`, `AXIL_DATA_W=32` | Control-plane address and data widths |
| codec/engine | `MRTC_K_POLICY_ARCH` | Full-adaptive or prefix-fast `k` selection architecture |
| codec/engine | `PREFIX_SAMPLES=256` | Published prefix-fast observation length |
| DDR wrapper | `NUM_ENGINES=2` | Engine count; public evidence covers the historical 2/4-Engine matrix and a 2-Engine adaptation smoke |
| DDR wrapper | `OUTPUT_IN_ORDER=0` | The only supported value; setting it to `1` fails fast |

## Multi-Engine descriptor and output ordering

The DDR wrapper accepts raw address, Frame/Block ID, Range start, codec mode, and tensor shape through `s_desc_*`. Each Engine owns a feeder, codec, and packet buffer. Once the output arbiter selects a packet, it retains that Engine through `tlast`, so beats from different packets never interleave.

Completion order across blocks is not guaranteed. Frame/Block metadata in the header provides the identity needed for indexed software reconstruction, but this repository does not claim a software reorder program PASS. `OUTPUT_IN_ORDER=1` is unimplemented and explicitly fails fast.

## AXI4-Lite control plane

The `mrtc_top` AXI4-Lite interface exposes enable, soft reset, status clear, codec configuration, tensor metadata, counters, IRQ, and capability registers. See the [register map](register_map.md) for addresses and bit fields. The RTL [`mrtc_axi_lite_reg_block`](../../rtl/top/mrtc_axi_lite_reg_block.sv) is the final interface authority.

## Integration checklist

- Keep configuration stable for a complete block transaction.
- Align input `tlast` with the 1024-sample block boundary.
- Support arbitrary `tready` backpressure and the final-beat valid-byte rule.
- Treat `tlast` as the packet-atomic boundary; do not assume Block IDs naturally emerge in order.
- Compile the tracked filelist for the selected top rather than manually omitting packages or helper modules.
- Run the corresponding smoke before delivery and leave the worktree clean apart from ignored build output.
