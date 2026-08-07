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
| RTL performance evolution | Bitpacker payload interval `7693 -> 721 cycles` (`10.67×`); historical single-Engine spacing `8220 -> 785 cycles/block` (`10.47×`), with 1/2/4 Engines at `785 / 397.52 / 197.41 cycles/block` | The first metric is a payload interval; the second is a historical buffered service rate, with `785` imported from Stage16D2; neither is Direct sustained throughput or Fmax | [Bitpacker YAML](evidence/rdtc_v1_bitpacker_pipeline_ab.yaml) · [CSV](evidence/data/rdtc_v1_bitpacker_pipeline_ab.csv) · [Multi-Engine YAML](evidence/rdtc_v1_multiengine_rtl.yaml) · [CSV](evidence/data/rdtc_v1_multiengine_scaling.csv) |
| Direct-AXIS architecture and Stage-1 PPA/power | Removes the DDR feeder and per-Engine payload commit; 315 MHz DC cell area/count fall by `72.53% / 71.98%`; BURST_IDLE dynamic is `436.4352 -> 109.8717 mW` (`-74.83%`) | Dual Engine and register-expanded; Direct RTL is `~277 > 256 cycles/block`; Stage 1 uses independent RTL-SAIF-to-mapped activity and remains a mapped estimate | [Direct RTL](evidence/rdtc_v1_bounded_direct_rtl.yaml) · [stream timing](evidence/rdtc_v1_direct_stream_timing_trace.yaml) · [DC A/B](evidence/rdtc_v1_bounded_buffered_vs_direct_dc_ab.yaml) · [Stage-1 evidence](evidence/rdtc_v1_power_architecture_ab/README.md) · [method](docs/en/asic_power_experiment.md) |
| Direct G0/G1 automatic clock-gating A/B | At 315 MHz, BURST_IDLE dynamic power is `107.3535 -> 41.1522 mW` (`-61.67%`) and energy/block is `164.55 -> 68.36 nJ` (`-58.46%`); ACTIVE_LEGAL dynamic changes by `-59.52%` | Independent Stage 2; 272 ICGs, 34,816 gated bits, mapped-GLS activity; relative to Direct G0 only and never added to Stage 1 | [evidence package](evidence/rdtc_v1_clock_gating_mapped_dc/README.md) · [method and boundary](docs/en/asic_clock_gating_experiment.md) |
| FPGA / ASIC implementation boundary | Direct FPGA OOC at 200 MHz; Direct register-expanded / eight-macro OpenRAM profiles complete fixed academic post-route PrimeTime setup/hold closure at `600/300 MHz` | FPGA result is not a bitstream/board claim; ASIC frequencies are not Fmax or foundry signoff | [FPGA evidence](evidence/rdtc_v1_bounded_direct_fpga_ooc200.yaml) · [ASIC evidence](evidence/rdtc_v1_bounded_direct_asic.yaml) · [result matrix](docs/en/results.md) |

## Performance, PPA and Power Evolution

<p align="center">
  <a href="docs/assets/rdtc_performance_evolution.svg"><img src="docs/assets/rdtc_performance_evolution.svg" width="1000" alt="RDTC RTL performance evolution from Bitpacker pipeline to historical Multi-Engine scaling"></a>
</p>

Figure 1 keeps the fixed `smoke_zero_sparse` Bitpacker payload interval separate from the historical buffered Multi-Engine service rate. Completion order is not guaranteed, and the simulated DDR feeder, assumed 200 MHz, and RTL simulation projection are not an implemented environment or measured board throughput. Machine sources are the [Bitpacker YAML](evidence/rdtc_v1_bitpacker_pipeline_ab.yaml), [Bitpacker CSV](evidence/data/rdtc_v1_bitpacker_pipeline_ab.csv), [Multi-Engine YAML](evidence/rdtc_v1_multiengine_rtl.yaml), and [Multi-Engine CSV](evidence/data/rdtc_v1_multiengine_scaling.csv).

<p align="center">
  <a href="docs/assets/rdtc_stage1_architecture_ppa_power.svg"><img src="docs/assets/rdtc_stage1_architecture_ppa_power.svg" width="1000" alt="Stage-1 Buffered versus Direct-AXIS architecture PPA and mapped-power comparison"></a>
</p>
<p align="center">
  <a href="docs/assets/rdtc_stage2_clock_gating_power.svg"><img src="docs/assets/rdtc_stage2_clock_gating_power.svg" width="1000" alt="Stage-2 Direct G0 versus G1 automatic clock-gating mapped-power comparison"></a>
</p>

Figures 2 and 3 are independent A/B studies with different baselines. Stage 1 compares Buffered with Direct-AXIS using RTL-SAIF-to-mapped activity; Stage 2 holds the Direct architecture fixed and compares G0/G1 using mapped zero-delay GLS activity with functional SE=0. Their percentages are not added. Activity Annotation Coverage is not verification test coverage. See the [Stage-1 Evidence package](evidence/rdtc_v1_power_architecture_ab/README.md) and [Stage-2 Evidence package](evidence/rdtc_v1_clock_gating_mapped_dc/README.md). These results do not claim CTS clock-tree or PrimeTime-PX power, Formality, DFT/scan closure, silicon measurement or foundry signoff, Fmax, or workload-universal savings.

### FPGA / ASIC Implementation Closure

| Fixed closure profile | Verified fixed point | Direct evidence | Boundary |
|---|---|---|---|
| Direct FPGA OOC | 200 MHz; setup/hold WNS `+0.001/+0.062 ns`; `32,672 LUT / 18,519 FF / 0 BRAM` | [FPGA 200 MHz evidence](evidence/rdtc_v1_bounded_direct_fpga_ooc200.yaml) | OOC internal timing; no bitstream, board IO, measured board throughput, or Fmax claim |
| Direct register-expanded ASIC | 600 MHz; 0 memory macros; standard-cell area `476,320 um2`; PT setup/hold WNS `+0.03/+0.02 ns` | [Register-expanded ASIC 600 MHz evidence](evidence/rdtc_v1_bounded_direct_asic.yaml) | Fixed academic internal closure; not complete IO, foundry signoff, or Fmax |
| Direct eight-macro OpenRAM ASIC | 300 MHz; 8 x `32x128 1RW` macros; PT setup/hold WNS `+0.16/+0.02 ns` | [Eight-macro OpenRAM ASIC 300 MHz evidence](evidence/rdtc_v1_bounded_direct_asic.yaml) | Top-level closure; macro DRC/LVS/PEX remains open and 600 MHz is `MACRO_MODEL_BLOCKED` |

The three rows are profile-specific fixed points and do not rank FPGA, register-expanded ASIC, and SRAM-macro ASIC profiles against each other.

<a id="data-contract"></a>

## Data Contract: From A 4096-Byte Raw Block To A Variable-Length Packet

```text
FFT backend output: S[beam][doppler][range]  (range fastest)
                              |
                              v
+----------------------------------------------------------------+
| 1 block = 1 beam x 64 Doppler x 16 Range                      |
|         = 1024 I16Q16 complex samples = 4096 B                |
+----------------------------------------------------------------+
                              |
                              | 256 AXIS128 beats
                              | 4 complex samples / beat
                              v
+-------------+------------+------------+-------------------------+
| Predictor   | Signed map | Adaptive k | Rice bitpacker          |
+-------------+------------+------------+-------------------------+
                              |
                              v
+----------------------+-----------------------------------------+
| 64 B header          | Variable-length payload                 |
| 4 AXIS128 beats      | N AXIS128 beats                         |
+----------------------+-----------------------------------------+
                                                 final TLAST/TUSER
                              |
                  +-----------+-----------+
                  |                       |
                  v                       v
       DDR / interconnect / 10G     RTL decoder
                  |                 loopback / reference
                  v
       PC/C decoder (header-length packet)
       restores the original I/Q samples
```

### How One AXIS128 Beat Becomes A Variable-Length Rice Fragment

```text
Bounded Direct: one AXIS128 beat -> one variable-length fragment

AXIS128 = 4 x I16Q16 = 8 x signed 16-bit components
                 | first 32 accepted beats        | every source beat
                 v                                v
       cost for k=0..15 -> selected k*   ZERO predict -> residual r
                              |                    |
                              |          signed map -> m
                              +---------+----------+
                                        v
                                q = m >> k*
                                rem = m[k*-1:0]
                                Rice = 1^q | 0 | rem
                                        |
                                        v
                         concatenate I0,Q0,...,I3,Q3
                                        |
                         word_bits = sum(q+1+k*) <= 128 ?
                                  |                         |
                                 yes                       no
                                  |                         |
                                  v                         v
                    variable-length fragment            fail-stop
                                  |
                                  v
                    bit reservoir -> AXIS128 payload
```

- `1^q` means `q` consecutive one-bits. The quotient is a unary count, not a fixed 18-bit binary field. Its zero terminator lets the Decoder recover `q` without separate quotient-width metadata; `rem` is the low `k*` bits of the mapped value.
- `word_bits <= 128` is a local bounded guard for each 128-bit source word, not a limit on the complete Payload or Packet. A violation reports `MRTC_ERR_BOUNDED_RICE_WORD` and fail-stops; this path does not fall back to RAW automatically.
- The first 32 accepted beats contain the 128-sample prefix. The estimator evaluates `q+1+k` for every I/Q component at `k=0..15` and selects the minimum accumulated prefix cost as `k*`. Those beats remain buffered in the ring; after `k*` is valid, the Bitpacker still reads and encodes all 256 source words in order, including the first 32 beats.
- The eight component codes concatenate as `I0,Q0,...,I3,Q3`. Fragments have no byte alignment; the width-packer reservoir appends their bits directly. Source-read `II=1` does not mean compressed AXIS `TVALID` is asserted every cycle.
- If all 256 source words satisfy the guard, the coded payload has the mathematical upper bound `256 x 128 bits = 4096 B`; the packet additionally includes its fixed 64-byte header. This is not a claim that every packet compresses or that output bandwidth is always lower.

- The producer flattens `S[spatial/beam, doppler, range]` with Range changing fastest. RTL consumes the flat sequence; it does not implement the upstream FFT.
- Each sample is `{Q[15:0], I[15:0]}`, and one AXIS128 beat carries four samples in ascending lane order.
- The default block is `1024 samples = 4096 B = 256 beats`, with input TLAST on zero-based beat 255.

`packet = four 128-bit header beats + variable payload beats`; TLAST/TUSER describe the physical tail.

**Fixed `delta_smooth` example:** `4096 B raw -> 64 B header + 296 B payload (2365 payload bits) = 360 B / 23 AXIS128 beats`, with bit-exact I/Q recovery by the C decoder.

| Handshake / framing | Contract |
|---|---|
| Input | `256` fully populated AXIS128 beats; `s_axis_raw_tlast` is on beat `255` |
| Output | Four header beats, then variable payload; `m_axis_comp_tlast` is asserted only on packet end |
| Tail beat | `m_axis_comp_tuser[3:0] = valid_byte_count - 1`; the main AXIS128 path does not use TKEEP |
| Backpressure | On the normal non-fatal path, `TVALID=1, TREADY=0` holds `TDATA/TUSER/TLAST` stable |

The current C decoder directly supports conventional header-length packets. Bounded Direct `STREAM_LENGTH_BY_TLAST` packets still require receive-side length adaptation; see the bitstream-format page.

[See the raw lane and packet wire layout](docs/en/bitstream_format.md#raw-axis-layout) · [See the 64-byte header, payload, and length contracts](docs/en/bitstream_format.md#header-layout) · [See the Direct four-way shallow input ring](docs/en/architecture.md#four-way-shallow-input-ring) · [See the beat-to-fragment pipeline](docs/en/architecture.md#beat-to-rice-fragment) · [See the observed stream timing and handshake](docs/en/stream_timing.md#direct-engine0-trace)

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
make power-architecture-ab-validate
make rdtc-clock-gating-power-validate
make rdtc-two-stage-power-validate
```

The first command creates the public-safe configuration; the next four compile or run published C/RTL entrypoints. The final four only validate sanitized public evidence, identities, and metric contracts; they do not rerun ModelSim, Design Compiler, P&R, or PrimeTime.

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

### Same-Workload Mapped Power A/B

At the same 315 MHz, with the same Nangate45 TT library and the same logical block, packet, selected-k, descriptor, and ready sequences, each mapped design uses its own RTL SAIF. BURST_IDLE dynamic power is `436.4352 -> 109.8717 mW` (`-74.83%`) and energy/block is `674.82 -> 167.59 nJ` (`-75.17%`); ACTIVE_LEGAL dynamic power changes by `-74.99%`. The conservative promotion gate still passes after accounting for both reports' quantization. This result claims only an activity-driven mapped-netlist power estimate, not post-route, CTS clock-tree, silicon, or foundry-signoff power. Both `clock_mw = 0` values remain tool-reported data and are not interpreted as physical clock-tree power.

[Power method and boundary](docs/en/asic_power_experiment.md) · [machine-readable evidence](evidence/rdtc_v1_power_architecture_ab/README.md)

### Stage 2: Direct G0 -> Direct G1 Automatic Clock Gating

Under the same Direct-AXIS, 315 MHz, Nangate45 TT/1.1 V/25 C contract, G1
inserts 272 `CLKGATETST_X1` cells and gates 34,816 bits, including
32,768/32,768 Ring data bits. BURST_IDLE dynamic power is
`107.3535 -> 41.1522 mW` (`-61.67%`) and energy/block is
`164.55 -> 68.36 nJ` (`-58.46%`); ACTIVE_LEGAL dynamic changes by `-59.52%`.
Both G0 and G1 are setup/electrical clean and the 2/32/64-block mapped
gate-level regressions are bit-exact. This result is relative to Direct G0
only; it must not be added to the Stage-1 architecture percentage.

[Clock-gating method and boundary](docs/en/asic_clock_gating_experiment.md) · [machine-readable evidence](evidence/rdtc_v1_clock_gating_mapped_dc/README.md)

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
