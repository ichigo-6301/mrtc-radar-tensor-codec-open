# Verified Results

[中文](../zh-CN/results.md)

## Algorithm And Functional Verification

| Result | Profile | Status | Caveat |
|---|---|---|---|
| MATLAB synthetic ZERO/DELTA lossless reconstruction | Controlled synthetic study | verified for recorded cases | Not a measured radar dataset; does not imply PointCloud RTL. |
| MATLAB/C/DPI-C/RTL legal-vector bit-exact agreement | RDTC v1 public release | verified | Finite vector and regression set; not exhaustive formal proof. |
| Dual-AXIS128 wrapper VCS regression, 10 required cases | RDTC v1 public release | verified | Finite wrapper regression; not coverage closure. |

Across synthetic SNR points from `-20` to `30 dB`, the ZERO_RICE compression ratios are `1.5817 / 1.8774 / 2.3470 / 3.0979 / 4.3915 / 7.5588`, while DELTA_RICE reaches `1.4997 / 1.7871 / 2.1852 / 2.8083 / 3.9669 / 6.1779`. See [Algorithm](algorithm.md) for interpretation.

![Synthetic compression ratio versus SNR](../assets/compression_vs_snr.svg)

Sources: [MATLAB evidence](../../evidence/rdtc_v1_matlab_algorithm_study.yaml) · [public CSV](../../evidence/data/rdtc_v1_matlab_lossless_snr.csv)

## Multi-Engine RTL Scaling

The historical fixed-commit 256-block prefix workload uses a simulated DDR feeder and checks byte-exact payloads, `selected_k`, compression ratio, packet completeness, and absence of beat interleaving. This record defines one beam as 256 blocks. `beam/s` is calculated from the unrounded `estimated_cycles_per_beam` values in the public CSV and cannot be reproduced exactly from the displayed two-decimal cycles/block values alone.

| Engines | Cycles/block | Scaling efficiency | Beam/s at assumed 200 MHz |
|---:|---:|---:|---:|
| 1 | 785 | baseline | - |
| 2 | 397.52 | 0.987368 | 1965.3022 |
| 4 | 197.41 | 0.994115 | 3957.4642 |

![Multi-Engine RTL simulation scaling](../assets/engine_scaling.svg)

These are RTL simulation projections, not FPGA timing closure, an implemented clock, or measured board DDR throughput. The current public adaptation has a separate two-Engine, two-block correctness smoke and does not recompute this matrix. Output packets remain atomic and beats from different packets do not interleave; completion order is not guaranteed. Frame/Block metadata enables indexed software reconstruction, but no software reorder-program PASS is claimed, and the recorded scenarios do not directly prove an observed reordered event.

Sources: [Multi-Engine evidence](../../evidence/rdtc_v1_multiengine_rtl.yaml) · [public CSV](../../evidence/data/rdtc_v1_multiengine_scaling.csv)

## FPGA Emulation

| Scope | Result | Status | Boundary |
|---|---|---|---|
| Fixed-commit Vivado 2018.3 AXIS32 wrapper XSim | ZERO_RICE, DELTA_RICE, and mixed two-block; `3/3` PASS | FPGA emulation verified | Current public adaptation has a separate Icarus smoke; XSim drives only `s0` and is not dual-Engine scaling evidence |
| Historical Zynq-7000 trial copy | Compatibility-copied RTL elaboration and SDK/ELF build | verified at trial-build layer | No direct Vivado 2018.3 elaboration claim for current public RTL; no matching bitstream or board execution claim |
| Bitstream/board/MCDMA runtime/timing/resources | No matching result published | not claimed | Not inferred from simulation or build status |

FPGA XSim covers the real encoder path, decoder golden comparison, width conversion, variable-length packets, `tkeep/tlast`, input gaps, and output backpressure. Dual-Engine distribution and arbitration come from separate RTL regression and are not merged into the single-input XSim scope.

Sources: [XSim evidence](../../evidence/rdtc_v1_fpga_axis32_emulation.yaml) · [Zynq trial-build evidence](../../evidence/rdtc_v1_zynq_trial_build.yaml) · [XSim case CSV](../../evidence/data/rdtc_v1_fpga_axis32_xsim_cases.csv)

## Implementation Profile Matrix

All frequency results apply only to the internal single-clock reg-to-reg constraint of `mrtc_rdtc_wb_wrapper`, with 100 ps setup uncertainty and without complete top-level IO timing.

| Memory Profile | Technology | Scope | Result | Status |
|---|---|---|---|---|
| `register-expanded` | NanGate15 TT/0.8 V/25 C | DC-only | 400/600/800 MHz close; 800 MHz WNS +0.22945 ns and cell area 99,064.13 um2 | verified |
| `register-expanded` | Nangate45 TT/1.1 V/25 C | DC matrix | 400/600/700 MHz close; 700 MHz WNS/TNS is 0.00/0.00 ns; 800 MHz WNS/TNS is -0.14/-858.86 ns | verified |
| `register-expanded` | Nangate45/OpenROAD/OpenRCX | P&R + PT at 400 MHz | Route DRC 0, antenna net/pin 0/0, area 418,007 um2, utilization 31.2108%; PT setup/hold WNS +0.80/+0.04 ns with zero constraint violations | verified |
| `register-expanded` | Nangate45/OpenROAD/OpenRCX | Fixed verified P&R + PT closure point at 550 MHz | Uses the 700 MHz DC mapped netlist; route DRC 0, antenna net/pin 0/0, area 421,120 um2, utilization 31.4432%; PT setup/hold WNS +0.26/+0.04 ns with zero constraint violations | verified |
| `sram-macro` | Nangate45/OpenRAM/OpenROAD/OpenRCX | Two `64x128 1RW1R` macros; fixed verified 333 MHz P&R, same-run SPEF, and internal PT timing closure point | Route DRC is 0 and antenna net/pin is 0/0; PT setup/hold WNS +0.57/+0.04 ns with zero constraint violations | Chip-level implementation verified; overall profile partial because the analytical SRAM model and macro DRC/LVS/PEX are not closed |

The NanGate15 Liberty uses a `1ps` time unit, so its DC profile explicitly applies `SDC_TIME_SCALE=1000.0`. The latest 45 nm register-expanded physical run uses the setup-closed 700 MHz DC netlist at a 550 MHz implementation target. Evidence records matching SHA256 values for the handoff netlist, SDC, and SPEF. PrimeTime setup/hold coverage is 100%; 1,756 unconstrained max-delay endpoints are asynchronous reset pins under the internal-only profile.

The 333 MHz SRAM-macro result completed verified chip-level OpenROAD P&R, same-run OpenRCX SPEF, and PrimeTime internal setup/hold timing. Its route DRC and antenna net/pin counts are zero, and setup/hold WNS is +0.57/+0.04 ns. The overall SRAM profile remains `partial` because OpenRAM characterization is analytical and macro DRC/LVS/PEX is not closed. An exact reviewed waiver covers 256 unused `dout0[127:0]` minimum-capacitance endpoints on the two macros; it must remain disclosed, but it is not the reason the profile is partial. The waiver is profile-specific and exact-set matched, permits neither missing nor extra objects, and is not a blanket capacitance waiver, setup/hold waiver, or applicable to functional read data. This is the fixed verified closure point for the current macro profile, not a 400 MHz claim.

## Interpretation

- A `verified closure point` establishes the recorded checks at one explicit configuration and frequency; it is not a maximum-frequency claim;
- a `DC timing estimate` covers internal timing under the selected Liberty, ideal clock, and synthesis constraints only;
- `internal reg-to-reg post-route timing` uses a routed netlist, matching SDC, and same-run SPEF, but does not cover unmodelled system IO;
- route-tool DRC 0 and foundry DRC/LVS/PEX are different scopes;
- `top-level IO timing closure`, `OCV/MMMC`, and `foundry signoff` are not claimed.

ASIC evidence: [register-expanded](../../evidence/rdtc_v1_register_expanded.yaml) · [SRAM macro](../../evidence/rdtc_v1_sram_macro_333m.yaml)

Public evidence is under `evidence/`, with run conditions and boundaries under `provenance/`. PDKs, Liberty/DB, LEF/GDS, SPEF, and raw EDA work directories are not distributed.
