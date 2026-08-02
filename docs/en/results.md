# Verified Results

[中文](../zh-CN/results.md)

## Algorithm And Functional Verification

| Result | Profile | Status | Caveat |
|---|---|---|---|
| MATLAB synthetic ZERO/DELTA lossless reconstruction | Controlled synthetic study | verified for recorded cases | Not a measured radar dataset; does not imply PointCloud RTL. |
| MATLAB/C/DPI-C/RTL legal-vector bit-exact agreement | RDTC v1 public release | verified | Finite vector and regression set; not exhaustive formal proof. |
| Dual-AXIS128 wrapper VCS regression, 10 required cases | RDTC v1 public release | verified | Finite wrapper regression; not coverage closure. |
| Bounded Direct-AXIS two-block packet, selected-k, and decoder equivalence | Direct dual-Engine register profile | verified | Finite bounded-domain regression; sustained zero-gap scheduling fails at `277 > 256 cycles/block`. |

Direct functional source: [bounded Direct RTL evidence](../../evidence/rdtc_v1_bounded_direct_rtl.yaml)

Across synthetic SNR points from `-20` to `30 dB`, the ZERO_RICE compression ratios are `1.5817 / 1.8774 / 2.3470 / 3.0979 / 4.3915 / 7.5588`, while DELTA_RICE reaches `1.4997 / 1.7871 / 2.1852 / 2.8083 / 3.9669 / 6.1779`. See [Algorithm](algorithm.md) for interpretation.

![Synthetic compression ratio versus SNR](../assets/compression_vs_snr.svg)

Sources: [MATLAB evidence](../../evidence/rdtc_v1_matlab_algorithm_study.yaml) · [public CSV](../../evidence/data/rdtc_v1_matlab_lossless_snr.csv)

## Bitpacker Pipeline A/B

Historical Stage16C3 and Stage16D2 use the same `smoke_zero_sparse` input, the same latency monitor, the same `selected_k=0`, and the same `2158-bit / 270-byte` payload. Replacing the per-sample compressed path with the integrated four-lane word Bitpacker reduces the inclusive interval from first payload valid to accepted packet `TLAST` from `7693` to `721 cycles`: a `90.63%` reduction and `10.67×` speedup. Both points have zero input/output stalls, byte-identical 334-byte packets, and passing decoder loopback.

This result measures only the payload stream interval on one fixed historical RTL workload. It is not whole-block latency, Multi-Engine throughput, current Direct-AXIS sustained throughput, FPGA performance, ASIC frequency, or Fmax.

Sources: [Bitpacker A/B evidence](../../evidence/rdtc_v1_bitpacker_pipeline_ab.yaml) · [public two-point CSV](../../evidence/data/rdtc_v1_bitpacker_pipeline_ab.csv)

## Multi-Engine RTL Scaling

The historical fixed-commit 256-block prefix workload uses a simulated DDR feeder and checks byte-exact payloads, `selected_k`, compression ratio, packet completeness, and absence of beat interleaving. This record defines one beam as 256 blocks. `beam/s` is calculated from the unrounded `estimated_cycles_per_beam` values in the public CSV and cannot be reproduced exactly from the displayed two-decimal cycles/block values alone.

| Engines | Cycles/block | Scaling efficiency | Beam/s at assumed 200 MHz |
|---:|---:|---:|---:|
| 1 | 785 | baseline | - |
| 2 | 397.52 | 98.7368% | 1965.3022 |
| 4 | 197.41 | 99.4115% | 3957.4642 |

![Multi-Engine RTL simulation scaling](../assets/engine_scaling.svg)

These are RTL simulation projections, not FPGA timing closure, an implemented clock, or measured board DDR throughput. The current public adaptation has a separate two-Engine, two-block correctness smoke and does not recompute this matrix. Output packets remain atomic and beats from different packets do not interleave; completion order is not guaranteed. Frame/Block metadata enables indexed software reconstruction, but no software reorder-program PASS is claimed, and the recorded scenarios do not directly prove an observed reordered event.

Sources: [Multi-Engine evidence](../../evidence/rdtc_v1_multiengine_rtl.yaml) · [public CSV](../../evidence/data/rdtc_v1_multiengine_scaling.csv)

## FPGA Emulation

| Scope | Result | Status | Boundary |
|---|---|---|---|
| Fixed-commit Vivado 2018.3 AXIS32 wrapper XSim | ZERO_RICE, DELTA_RICE, and mixed two-block; `3/3` PASS | FPGA emulation verified | Current public adaptation has a separate Icarus smoke; XSim drives only `s0` and is not dual-Engine scaling evidence |
| Bounded Direct-AXIS Vivado 2022.2 OOC post-route | `xc7z100ffg900-2`, 200 MHz, setup/hold WNS `+0.001/+0.062 ns`, `32,672 LUT / 18,519 FF / 0 BRAM` | fixed internal timing/resource point verified | No board IO timing, Fmax, bitstream, board, or sustained zero-stall claim |
| Historical Zynq-7000 trial copy | Compatibility-copied RTL elaboration and SDK/ELF build | verified at trial-build layer | No direct Vivado 2018.3 elaboration claim for current public RTL; no matching bitstream or board execution claim |
| Bitstream/board/MCDMA runtime | No matching result published | not claimed | Not inferred from simulation, OOC implementation, or build status |

FPGA XSim covers the real encoder path, decoder golden comparison, width conversion, variable-length packets, `tkeep/tlast`, input gaps, and output backpressure. Dual-Engine distribution and arbitration come from separate RTL regression and are not merged into the single-input XSim scope.

Sources: [XSim evidence](../../evidence/rdtc_v1_fpga_axis32_emulation.yaml) · [Direct OOC evidence](../../evidence/rdtc_v1_bounded_direct_fpga_ooc200.yaml) · [Zynq trial-build evidence](../../evidence/rdtc_v1_zynq_trial_build.yaml) · [XSim case CSV](../../evidence/data/rdtc_v1_fpga_axis32_xsim_cases.csv)

## Implementation Profile Matrix

Historical rows use the internal single-clock reg-to-reg constraint of `mrtc_rdtc_wb_wrapper`; Direct rows use `mrtc_rdtc_bounded_axis_multiengine_wrapper`. Neither has complete top-level IO timing. `DC-only` and `DC matrix` rows are synthesis estimates. The 550/333 MHz historical and 600/300 MHz Direct rows are PrimeTime setup/hold closure results after placement and routing with matching routed netlist, SDC, and same-run OpenRCX SPEF; they must not be summarized as DC results.

The two historical Nangate45 physical profiles use the same floorplan configuration: a `1200 x 1200 um` die (`1.4400 mm2`) and a `1159.72 x 1155.20 um` core (`1.3397 mm2`). Direct profiles use independent area/macro-derived floorplans. Configured geometry is not a post-hoc measurement from an unpublished GDS, and standard-cell area is not core or die area.

| Memory Profile | Technology | Scope | Result | Status |
|---|---|---|---|---|
| `bounded-buffered-vs-direct` | Nangate45 TT/1.1 V/25 C | Same-library, same-315 MHz, register-expanded DC A/B | Buffered `1,529,495.20 um2 / 786,342 cells`; Direct `420,208.44 um2 / 220,298 cells`; reductions `72.53% / 71.98%` | verified `PASS_DC_ONLY`; not SRAM or post-route area |
| `register-expanded` | NanGate15 TT/0.8 V/25 C | DC-only | 400/600/800 MHz close; 800 MHz WNS +0.22945 ns and cell area 99,064.13 um2 | verified |
| `register-expanded` | Nangate45 TT/1.1 V/25 C | DC matrix | 400/600/700 MHz close; 700 MHz WNS/TNS is 0.00/0.00 ns; 800 MHz WNS/TNS is -0.14/-858.86 ns | verified |
| `register-expanded` | Nangate45/OpenROAD/OpenRCX | P&R + PT at 400 MHz | Route DRC 0, antenna net/pin 0/0, area 418,007 um2, utilization 31.2108%; PT setup/hold WNS +0.80/+0.04 ns with zero constraint violations | verified |
| `register-expanded` | Nangate45/OpenROAD/OpenRCX | Fixed verified P&R + PT closure point at 550 MHz | Uses the 700 MHz DC mapped netlist; configured die/core `1200 x 1200 um` / `1159.72 x 1155.20 um`; route DRC 0, antenna net/pin 0/0, area 421,120 um2, utilization 31.4432%; PT setup/hold WNS +0.26/+0.04 ns with zero constraint violations | verified |
| `sram-macro` | Nangate45/OpenRAM/OpenROAD/OpenRCX | Two `64x128 1RW1R` macros; fixed verified 333 MHz P&R, same-run SPEF, and internal PT timing closure point | Configured die/core `1200 x 1200 um` / `1159.72 x 1155.20 um`; route DRC is 0 and antenna net/pin is 0/0; PT setup/hold WNS +0.57/+0.04 ns with zero constraint violations | Chip-level implementation and internal timing verified; academic Nangate45/OpenRAM platform with no production-PDK, macro-signoff, or silicon-readiness claim |
| `bounded-direct-register-expanded` | Nangate45/OpenROAD/OpenRCX | Fixed verified 600 MHz P&R + same-run SPEF + internal PT point; 0 memory macros | Route DRC and antenna net/pin 0/0; area 476,320 um2; PT setup/hold WNS +0.03/+0.02 ns; setup/hold coverage 50972/50972 | verified internal implementation/timing; not Fmax or sustained zero-stall |
| `bounded-direct-sram-macro` | Nangate45/OpenRAM/OpenROAD/OpenRCX | Eight `32x128 1RW` macros; fixed verified 300 MHz P&R + same-run SPEF + internal PT point | Route DRC and antenna net/pin 0/0; PT setup/hold WNS +0.16/+0.02 ns; setup/hold coverage 18276/18276; macro period/pulse checks clean at 300 MHz | Top-level implementation/timing verified; macro DRC/LVS/PEX open; 600 MHz `MACRO_MODEL_BLOCKED` |

The NanGate15 Liberty uses a `1ps` time unit, so its DC profile explicitly applies `SDC_TIME_SCALE=1000.0`. The latest 45 nm register-expanded physical run uses the setup-closed 700 MHz DC netlist at a 550 MHz implementation target. Evidence records matching SHA256 values for the handoff netlist, SDC, and SPEF. PrimeTime setup/hold coverage is 100%; 1,756 unconstrained max-delay endpoints are asynchronous reset pins under the internal-only profile.

The 333 MHz SRAM-macro result completed verified chip-level OpenROAD P&R, same-run OpenRCX SPEF, and PrimeTime internal setup/hold timing. Its route DRC and antenna net/pin counts are zero, and setup/hold WNS is +0.57/+0.04 ns. It is presented as chip-level implementation evidence on an academic Nangate45/OpenRAM platform: OpenRAM characterization is analytical, and this project does not provide a production PDK, macro DRC/LVS/PEX, or silicon-signoff package. An exact reviewed waiver covers 256 unused `dout0[127:0]` minimum-capacitance endpoints on the two macros; it must remain disclosed but does not affect the verified setup/hold result. The waiver is profile-specific and exact-set matched, permits neither missing nor extra objects, and is not a blanket capacitance waiver, setup/hold waiver, or applicable to functional read data. This is the fixed verified closure point for the current macro profile, not a 400 MHz claim.

## Interpretation

- A `verified closure point` establishes the recorded checks at one explicit configuration and frequency; it is not a maximum-frequency claim;
- a `DC timing estimate` covers internal timing under the selected Liberty, ideal clock, and synthesis constraints only;
- `internal reg-to-reg post-route timing` uses a routed netlist, matching SDC, and same-run SPEF, but does not cover unmodelled system IO;
- route-tool DRC 0 and foundry DRC/LVS/PEX are different scopes;
- `top-level IO timing closure`, `OCV/MMMC`, and `foundry signoff` are not claimed.

ASIC evidence: [buffered versus Direct DC A/B](../../evidence/rdtc_v1_bounded_buffered_vs_direct_dc_ab.yaml) · [register-expanded](../../evidence/rdtc_v1_register_expanded.yaml) · [SRAM macro](../../evidence/rdtc_v1_sram_macro_333m.yaml) · [bounded Direct register/SRAM](../../evidence/rdtc_v1_bounded_direct_asic.yaml)

Public evidence is under `evidence/`, with run conditions and boundaries under `provenance/`. PDKs, Liberty/DB, LEF/GDS, SPEF, and raw EDA work directories are not distributed.
