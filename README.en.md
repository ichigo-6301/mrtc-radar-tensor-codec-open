# MRTC-RDTC Scalable Lossless Radar-Tensor Codec IP

[![Public preflight](https://github.com/ichigo-6301/mrtc-radar-tensor-codec-open/actions/workflows/public-preflight.yml/badge.svg)](https://github.com/ichigo-6301/mrtc-radar-tensor-codec-open/actions/workflows/public-preflight.yml) ![RTL](https://img.shields.io/badge/RTL-SystemVerilog-2f6f9f) [![License](https://img.shields.io/github/license/ichigo-6301/mrtc-radar-tensor-codec-open)](LICENSE)

[中文](README.md) · [Algorithm](docs/en/algorithm.md) · [Architecture](docs/en/architecture.md) · [Verification](docs/en/verification.md) · [Results](docs/en/results.md) · [Immutable RC3](docs/en/release_model.md)

**A streaming lossless codec for OFDM sensing and millimeter-wave radar Range-Doppler tensors, engineered from MATLAB algorithms and synthesizable RTL through Multi-Engine scheduling, FPGA emulation, and ASIC post-route STA.**

RDTC compresses I16Q16 samples block by block while preserving bit-exact reconstruction. Conventional packets carry mode, length, and Frame/Block identity in a 64-byte self-describing header; bounded Direct packets take physical length from TLAST/TUSER.

Hardware implementation and performance optimization are encoder-centric. A receiving PC/C decoder can reconstruct conventional header-length packets, while the RTL decoder provides protocol closure, bit-exact loopback, and a hardware-decoder reference. This repository does not claim that a production ASIC must instantiate the decoder.

![MRTC-RDTC end-to-end overview](docs/assets/rdtc_overview.svg)

<a id="resume-results"></a>

## 60-Second Overview

| Contribution | Result | Profile / boundary | Direct evidence |
|---|---|---|---|
| Three-mode AXIS128 codec and verification chain | `RAW_BYPASS`, `ZERO_RICE`, and `DELTA_RICE`; `1024` I16Q16 samples/block, 64-byte header; finite-vector MATLAB/C/DPI-C/RTL bit-exact agreement | Encoder/compression datapath is primary; RTL decoder supplies loopback and protocol closure | [Reference validation](evidence/rdtc_v1_reference_validation.yaml) · [verification matrix](docs/en/verification.md) |
| prefix-128 + lane-parallel Bitpacker | On the fixed `smoke_zero_sparse` RTL workload, the payload interval is `7693 -> 721 cycles`, a `10.67×` improvement; packet bytes match exactly | Historical fixed workload; this is a payload interval, not whole-block latency, sustained throughput, or Fmax | [YAML](evidence/rdtc_v1_bitpacker_pipeline_ab.yaml) · [CSV](evidence/data/rdtc_v1_bitpacker_pipeline_ab.csv) |
| Multi-Engine wrapper | Historical buffered profile reaches `785 / 397.52 / 197.41 cycles/block`, with `98.7368% / 99.4115%` 2/4-Engine scaling efficiency | `785` is the imported Stage16D2 reference, not a wrapper `NUM_ENGINES=1` rerun; historical average spacing is `8220 -> 785 cycles/block`, a `10.47×` change, detailed below | [YAML](evidence/rdtc_v1_multiengine_rtl.yaml) · [CSV](evidence/data/rdtc_v1_multiengine_scaling.csv) |
| Direct-AXIS low-storage refactor | Removes the DDR feeder and per-Engine payload commit; same-library, same-315 MHz DC A/B reduces cell area/count by `72.53% / 71.98%` | Dual Engine, register-expanded, DC-only architectural A/B; Direct RTL is `~277 > 256 cycles/block`, so sustained zero-gap scheduling is not claimed | [Direct RTL](evidence/rdtc_v1_bounded_direct_rtl.yaml) · [observed stream timing](evidence/rdtc_v1_direct_stream_timing_trace.yaml) · [DC A/B](evidence/rdtc_v1_bounded_buffered_vs_direct_dc_ab.yaml) |
| FPGA / ASIC implementation boundary | Direct FPGA OOC at 200 MHz; Direct register-expanded / eight-macro OpenRAM profiles complete fixed academic post-route PrimeTime setup/hold closure at `600/300 MHz` | FPGA result is not a bitstream/board claim; ASIC frequencies are not Fmax or foundry signoff | [FPGA evidence](evidence/rdtc_v1_bounded_direct_fpga_ooc200.yaml) · [ASIC evidence](evidence/rdtc_v1_bounded_direct_asic.yaml) · [result matrix](docs/en/results.md) |

<p align="center">
  <a href="evidence/rdtc_v1_bitpacker_pipeline_ab.yaml"><img src="docs/assets/bitpacker_pipeline_ab.svg" width="760" alt="Single-Engine steady-state RTL pipeline A/B"></a>
</p>
<p align="center">
  <a href="evidence/rdtc_v1_multiengine_rtl.yaml"><img src="docs/assets/engine_scaling.svg" width="760" alt="Historical buffered Multi-Engine average block-interval scaling"></a>
</p>

<a id="data-contract"></a>

## Data Contract: From A 4096-Byte Raw Block To A Variable-Length Packet

```text
Raw Tensor Block
1 beam x 64 Doppler
x 16 Range
       | range fastest
       v
256 x AXIS128
       |
       v
Predict / Map / Rice
       |
      Pack
       |
       v
+----------+------------+
|64B Header|Var. Payload|
|4 beats   |N beats     |
+----------+------------+
                    TLAST
```

- The producer flattens `S[spatial/beam, doppler, range]` with Range changing fastest. RTL consumes the flat sequence; it does not implement the upstream FFT.
- Each sample is `{Q[15:0], I[15:0]}`, and one AXIS128 beat carries four samples in ascending lane order.
- The default block is `1024 samples = 4096 B = 256 beats`, with input TLAST on zero-based beat 255.

`packet = four 128-bit header beats + variable payload beats`; TLAST/TUSER describe the physical tail. The fixed `delta_smooth` C demo encodes a `4096 B` raw block as a `360 B` packet (2365 payload bits and 23 AXIS128 beats), then reconstructs I/Q bit-exactly.

| Handshake / framing | Contract |
|---|---|
| Input | `256` fully populated AXIS128 beats; `s_axis_raw_tlast` is on beat `255` |
| Output | Four header beats, then variable payload; `m_axis_comp_tlast` is asserted only on packet end |
| Tail beat | `m_axis_comp_tuser[3:0] = valid_byte_count - 1`; the main AXIS128 path does not use TKEEP |
| Backpressure | On the normal non-fatal path, `TVALID=1, TREADY=0` holds `TDATA/TUSER/TLAST` stable |

[See the raw lane and packet wire layout](docs/en/bitstream_format.md#raw-axis-layout) · [See the 64-byte header, payload, and length contracts](docs/en/bitstream_format.md#header-layout) · [See the Direct four-way shallow input ring](docs/en/architecture.md#four-way-shallow-input-ring) · [See the observed stream timing and handshake](docs/en/stream_timing.md#direct-engine0-trace)

### Choose an integration entrypoint

| Goal | Canonical top | Filelist / check |
|---|---|---|
| Complete AXI4-Lite + AXIS128 IP | [`mrtc_top`](rtl/top/mrtc_top.sv) | [`rdtc_v1.f`](flows/manifests/rdtc_v1.f) · `make integration-smoke` |
| Single-Engine codec datapath | [`mrtc_rdtc_codec_top`](rtl/rdtc/mrtc_rdtc_codec_top.sv) | [`rdtc_v1.f`](flows/manifests/rdtc_v1.f) · `make integration-smoke` |
| Bounded Direct-AXIS dual Engine (opt-in) | [`mrtc_rdtc_bounded_axis_multiengine_wrapper`](rtl/rdtc/mrtc_rdtc_bounded_axis_multiengine_wrapper.sv) | Fixed `ZERO_RICE + prefix-128`; [`rdtc_v1_bounded_direct.f`](flows/manifests/rdtc_v1_bounded_direct.f) · `make bounded-direct-rtl-smoke` |
| Historical Zynq AXIS32 adaptation | [`mrtc_rdtc_axis32_wrapper`](rtl/rdtc/mrtc_rdtc_axis32_wrapper.sv) | [`rdtc_v1_fpga_wrapper_smoke.f`](flows/manifests/rdtc_v1_fpga_wrapper_smoke.f) · `make fpga-wrapper-smoke` |

The Direct profile is the final dual-Engine bounded-input contract: the producer must reserve a descriptor and send data only in the wrapper's legal ready window; `TVALID && !TREADY` must not be treated as indefinitely holdable ordinary input backpressure.

<a id="rtl-reading-path"></a>

## 10-Minute RTL Reading Path

| Order | File | Read for |
|---:|---|---|
| 1 | [`mrtc_top.sv`](rtl/top/mrtc_top.sv) | Start with the complete AXI4-Lite configuration, status, and bidirectional AXIS128 IP boundary. |
| 2 | [`mrtc_rdtc_codec_top.sv`](rtl/rdtc/mrtc_rdtc_codec_top.sv) | See how one Engine integrates the encoder and decoder around shared configuration. |
| 3 | [`mrtc_prefix_k_accum_stream.sv`](rtl/rdtc/mrtc_prefix_k_accum_stream.sv) | Follow ZERO/DELTA prediction, signed-residual mapping, 16 candidate costs, and the `k` reduction tree. |
| 4 | [`mrtc_rice_bitpacker_lane_axis.sv`](rtl/rdtc/mrtc_rice_bitpacker_lane_axis.sv) | Read the lane-parallel quotient/remainder token, normalization, and AXIS128 packing pipeline. |
| 5 | [`mrtc_header_gen.sv`](rtl/rdtc/mrtc_header_gen.sv) · [`mrtc_header_axis_streamer.sv`](rtl/rdtc/mrtc_header_axis_streamer.sv) · [`mrtc_rdtc_decoder_top.sv`](rtl/rdtc/mrtc_rdtc_decoder_top.sv) | Connect the 64-byte header, header/payload framing, and bit-exact reconstruction path. |
| 6 | [`mrtc_rdtc_ddr_multiengine_wrapper.sv`](rtl/rdtc/mrtc_rdtc_ddr_multiengine_wrapper.sv) · [`mrtc_axis_packet_buffer.sv`](rtl/rdtc/mrtc_axis_packet_buffer.sv) | Locate the block dispatcher, per-Engine packet buffers, and output grant held through `tlast`. |
| 7 | [`mrtc_rdtc_bounded_axis_multiengine_wrapper.sv`](rtl/rdtc/mrtc_rdtc_bounded_axis_multiengine_wrapper.sv) | Contrast the final Direct-AXIS dual-Engine job table, ordered packet mux, and bounded output credit. |
| 8 | [`mrtc_dpi_pkg.sv`](tb/dpi/mrtc_dpi_pkg.sv) · [`tb_rdtc_dpi_smoke.sv`](sv/tb_rdtc_dpi_smoke.sv) · [`tb_rdtc_codec_top_smoke.sv`](tb/sv/tb_rdtc_codec_top_smoke.sv) | Inspect the C/DPI-C boundary and the public RTL AXIS128 encode/decode smoke. |

[See parameters, ports, transactions, and the ordering contract](docs/en/interfaces.md)

<a id="technical-review-path"></a>

## Technical Review Quick Path (No Commercial EDA)

```bash
make rdtc_v1_public_preflight_defconfig
make codec-demo
make -C ref_model/c test
make rtl-smoke
make multiengine-smoke
make bitpacker-pipeline-ab-validate
make bounded-dc-ab-validate
make direct-stream-timing-validate
```

The first command creates the public-safe configuration; the next four compile or run published C/RTL entrypoints. The final three only validate sanitized public evidence, identities, and metric contracts; they do not rerun ModelSim, Design Compiler, P&R, or PrimeTime.

<a id="public-scope-provenance"></a>

## Public Scope / Provenance

This repository contains synthesizable RTL, public adaptations, verification entrypoints, and sanitized evidence. It excludes collaborator data, commercial-tool products, PDK payloads, and private system-integration assets. [Public Scope](PUBLIC_SCOPE.md), [Claims](provenance/claims.yaml), [Evidence](provenance/evidence.yaml), and [Nonclaims](provenance/nonclaims.yaml) jointly define the published boundary.

## 1. Algorithm: Why RDTC

The ZERO/DELTA paths map prediction residuals to non-negative integers, evaluate candidate Rice `k` values over each block, and emit a variable-length payload through a lane-parallel bitpacker. Encoder paths that implement fallback retain RAW payload when coding provides no benefit. Mode and fallback behavior remain explicit properties of each integration path rather than an unsupported universal auto-selection claim.

The MATLAB synthetic study compares ZERO_RICE and DELTA_RICE on controlled Range-Doppler-like scenes and checks `NMSE=0`, `max_abs_error=0`, and point-cloud match ratio `1` for the recorded cases. These are not measured radar captures, and PointCloud is not an RTL feature.

Data and boundaries: [algorithm theory and original MATLAB output](docs/en/algorithm.md) · [MATLAB evidence](evidence/rdtc_v1_matlab_algorithm_study.yaml) · [Multi-Engine evidence](evidence/rdtc_v1_multiengine_rtl.yaml)

## 2. Architecture: Single Engine to Multi-Engine

A Single Engine combines a ping-pong block buffer, predictor/residual mapper, prefix-cost and `k` selection, lane-parallel bitpacker, header generator, packet buffer, and decoder. Input capture overlaps current-block computation, while the packet buffer isolates variable-length encoding from AXI backpressure.

The parameterized Multi-Engine wrapper dispatches whole blocks round-robin and locks an output packet through `tlast`, preventing beat interleaving within a packet. Completion order remains data-dependent and is not guaranteed. Frame/Block metadata provides an indexed software-reconstruction interface; this repository does not claim a software reorder program PASS or turn an unobserved reorder event into a verification result.

The new opt-in Direct-AXIS profile removes the DDR feeder and per-Engine payload commit stores. It retains two Engines with four `32x128` 1RW ways each, a two-entry job table, and one global 16-beat output FIFO. Its domain is fixed to `ZERO_RICE + prefix-128 adaptive k`, with every Rice word constrained to `<=128 bits`. Output-credit exhaustion is sticky fatal and may expose a partial packet. Recorded ordered packet service is about `277 cycles/block`, above the `256 cycles/block` zero-gap arrival interval, so sustained zero-stall operation is not claimed.

[See the Single-Engine pipeline, Multi-Engine wrapper, and ordering contract](docs/en/architecture.md)

## 3. Verification: One Bitstream Contract Across Layers

```text
MATLAB synthetic study
        -> C reference model
        -> DPI-C / SystemVerilog bit-exact comparison
        -> Multi-Engine packet and backpressure regression
        -> FPGA emulation boundary
        -> ASIC P&R / same-run SPEF / PrimeTime
```

Public smoke tests cover the C reference model, RTL loopback, packet boundaries, `tuser/tlast` on the main AXIS128 interface, `tkeep/tlast` on the historical AXIS32 adaptation, randomized backpressure, and Multi-Engine arbitration. The public Icarus-compatible checks are portability/elaboration gates, not substitutes for ModelSim or Vivado evidence. Passing finite vectors and regressions is not formal exhaustiveness or coverage closure.

A fixed visible demo invokes the published C encoder and decoder: a 1024-sample `delta_smooth` input selects `DELTA_RICE` with `k=0`, produces a 360-byte self-describing packet from 4096 raw bytes, and reconstructs the original I/Q bytes exactly with `RDTC_CODEC_DEMO_PASS`. Input, packet, and decoded-output hashes are recorded in the [codec demo evidence](evidence/rdtc_v1_codec_demo.yaml).

[See the verification matrix and reproducible entrypoints](docs/en/verification.md)

## 4. FPGA: Layered Maturity

**FPGA emulation verified** still refers specifically to the fixed-source Vivado 2018.3 AXIS32 XSim `3/3` result from a single-`s0` testbench. Separately, the Direct-AXIS profile completes Vivado 2022.2 OOC post-route at 200 MHz on `xc7z100ffg900-2`: setup/hold WNS is `+0.001/+0.062 ns`, the structure contains two Engines, eight ways, and `1024 x RAM32X1S`, and utilization is `32,672 LUT / 18,519 FF / 0 BRAM`. This is an internal OOC fixed closure point, not Fmax, and it makes no bitstream, board-console, MCDMA/DDR runtime, or measured-throughput claim.

[See FPGA emulation and Zynq integration boundaries](docs/en/fpga_implementation.md)

## 5. ASIC: Architecture DC A/B and Post-Route STA

### Same-Constraint Architecture A/B (DC-only)

Under one Nangate45 typical library, one 315 MHz synchronous-boundary SDC, two Engines, register-expanded storage, `compile_ultra`, and disabled retiming, the buffered wrapper reports `1,529,495.20 um2 / 786,342 cells`; Direct-AXIS reports `420,208.44 um2 / 220,298 cells`. Removing the DDR feeder and per-Engine payload commit stores therefore reduces DC cell area by `72.53%` and cell count by `71.98%`. This is an architecture-level synthesis comparison, not SRAM-macro area, post-route area, power, or Fmax.

### Post-Route Closure Points

**The frequency closure points below come from PrimeTime setup/hold STA after routing, not from the DC A/B estimate.** STA uses the matching routed netlist, SDC, and same-run OpenRCX SPEF; DC supplies only the mapped netlist handed to physical implementation.

| Profile | Verified implementation result | Maturity boundary |
|---|---|---|
| `rdtc_v1_register_nangate45_550` | 550 MHz OpenROAD P&R + same-run OpenRCX SPEF + PrimeTime; configured die/core `1200 x 1200 um` / `1159.72 x 1155.20 um`; core area `421,120 um2`; route DRC `0`; antenna net/pin `0/0`; setup/hold WNS `+0.26/+0.04 ns` | internal register-to-register implementation/timing verified |
| `rdtc_v1_sram_nangate45_333` | Two `64x128 1RW1R` OpenRAM macros; 333 MHz chip-level P&R + same-run SPEF + internal PT; configured die/core `1200 x 1200 um` / `1159.72 x 1155.20 um`; route DRC `0`; antenna net/pin `0/0`; setup/hold WNS `+0.57/+0.04 ns` | chip-level P&R and internal timing verified; the academic Nangate45/OpenRAM platform makes no production-PDK, macro-signoff, or silicon-readiness claim; the 256-endpoint exact-set waiver remains separately disclosed |
| `rdtc_v1_bounded_direct_register_expanded` | Direct-AXIS, two Engines, `32,768` ring bits expanded to registers, zero macros; 600 MHz P&R + OpenRCX + PT; route DRC/antenna `0/0`; setup/hold WNS `+0.03/+0.02 ns` | fixed academic internal closure point; not Fmax or sustained zero-stall evidence |
| `rdtc_v1_bounded_direct_sram_macro` | Direct-AXIS with eight `32x128 1RW` OpenRAM macros; 300 MHz P&R + OpenRCX + PT; route DRC/antenna `0/0`; setup/hold WNS `+0.16/+0.02 ns` | top-level implementation and internal timing verified; macro DRC/LVS/PEX remains open; 600 MHz is `MACRO_MODEL_BLOCKED` |

These frequencies are fixed verified closure points for the stated profiles, not maximum frequencies. They remain inside the academic PDK/OpenRAM implementation scope and do not claim complete top-level IO timing, OCV/MMMC, foundry signoff, or silicon readiness.

[See the ASIC flow contract](docs/en/asic_implementation.md) · [DC A/B evidence](evidence/rdtc_v1_bounded_buffered_vs_direct_dc_ab.yaml) · [complete result matrix](docs/en/results.md) · [limitations and nonclaims](docs/en/limitations.md)

## Complete Public Gate

```bash
make rdtc_v1_public_preflight_defconfig
make public-preflight
make bounded-dc-ab-validate
```

This gate aggregates published C/RTL smoke tests, documentation, schemas, identities, checksums, assets, and leakage scans; `bounded-dc-ab-validate` remains evidence-only. Configured Questa/ModelSim environments can additionally run `make sim` and `make sim-full`. Commercial-tool, PDK, library, and macro paths are allowed only in ignored `flows/local/` files.

## Documentation and Release Boundary

[Interfaces](docs/en/interfaces.md) · [Bitstream format](docs/en/bitstream_format.md) · [Register map](docs/en/register_map.md) · [Public release model](docs/en/release_model.md) · [Evidence index](provenance/evidence.yaml) · [Claims](provenance/claims.yaml)

This showcase is a post-RC3 presentation update. The immutable annotated tag `rdtc-v1-register550-rc3` still identifies the original `register550-rc3` release and is not moved or recreated by documentation or public-adaptation changes.
