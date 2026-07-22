# MRTC-RDTC Scalable Lossless Radar-Tensor Codec IP

[中文](README.md)

MRTC-RDTC targets continuous Range-Doppler tensors in OFDM sensing and mmWave radar. It compresses I16Q16 samples block by block, preserves bit-exact reconstruction, and connects algorithm selection, synthesizable RTL, Multi-Engine scheduling, verification, and ASIC implementation in one auditable engineering story.

![MRTC-RDTC Multi-Engine architecture](docs/assets/multi_engine_wrapper.svg)

## Motivation And Algorithm

Continuous sensing spectra require real-time throughput while quickly increasing off-chip DDR and interconnect traffic. Each block is configured for `RAW_BYPASS`, `ZERO_RICE`, or `DELTA_RICE`; prediction residuals on the ZERO/DELTA paths pass through signed mapping, block-level `k` selection, and Rice bit packing. Encoder paths that implement payload-cost fallback may select RAW when compression is not beneficial, avoiding a larger coded payload.

The MATLAB synthetic study compares these modes on controlled synthetic data and checks lossless reconstruction. The chart shows compression trends for that dataset only. It is not measured radar data and does not imply PointCloud RTL.

![Synthetic compression ratio versus SNR](docs/assets/compression_vs_snr.svg)

Sources: [MATLAB evidence](evidence/rdtc_v1_matlab_algorithm_study.yaml) · [public CSV](evidence/data/rdtc_v1_matlab_lossless_snr.csv)

## From One Engine To Many

A single Engine processes a block of `1024` I16Q16 samples, or `4096` raw bytes. The encoder emits a `64`-byte self-describing header over a 128-bit AXI-Stream. Its pipeline includes a ping-pong block buffer, prediction and residual mapping, prefix and `k` computation, a lane-parallel bitpacker, and a decoupled packet buffer.

The parameterized Multi-Engine wrapper distributes blocks by Round-Robin, gives every Engine an independent feeder, codec, and packet buffer, then uses a packet-locked arbiter so beats from different packets never interleave. Completion order is not guaranteed. Frame/Block metadata enables indexed software reconstruction, but no software reorder-program PASS is claimed.

![Multi-Engine RTL simulation scaling](docs/assets/engine_scaling.svg)

In the historical fixed-commit 256-block RTL workload, `1/2/4` Engines reach `785 / 397.52 / 197.41 cycles/block`. Two- and four-Engine scaling efficiency is `0.987368 / 0.994115`. This record defines one beam as 256 blocks; at an assumed 200 MHz, `1965.3022 / 3957.4642 beam/s` is derived from the unrounded `estimated_cycles_per_beam` values in the CSV and cannot be reproduced exactly from the displayed two-decimal cycles/block values alone. These are RTL simulation projections, not FPGA timing closure or measured board throughput. The current published adaptation uses only a two-Engine, two-block smoke to check dependency closure and packet/loopback correctness; it does not recompute that performance matrix.

Sources: [Multi-Engine evidence](evidence/rdtc_v1_multiengine_rtl.yaml) · [public CSV](evidence/data/rdtc_v1_multiengine_scaling.csv)

## Verification And FPGA

The verification chain covers MATLAB, C/DPI-C, SystemVerilog RTL, loopback, randomized backpressure, packet boundaries, and malformed-stream conditions.

**FPGA emulation verified.** At fixed source commit `43deb9f`, the Vivado 2018.3 AXIS32 wrapper passes `3/3` block-level XSim cases through the real encoder path and decoder golden comparison, including width conversion, variable-length packets, `tkeep/tlast`, input gaps, and output backpressure. The published wrapper and testbench are an Icarus-compatible adaptation of that historical source, not a new Vivado 2018.3 result. The XSim testbench drives only `s0`; dual-Engine scaling and arbitration are supported by separate fixed-commit RTL regression evidence. A historical Zynq-7000 trial copy completed RTL elaboration with a Vivado-2018.3-compatible copied RTL set and completed its SDK/ELF build. Direct Vivado 2018.3 elaboration of the current public RTL, a bitstream, board-console PASS, MCDMA/DDR runtime, FPGA timing, and resource results are not claimed.

Sources: [XSim evidence](evidence/rdtc_v1_fpga_axis32_emulation.yaml) · [Zynq trial-build evidence](evidence/rdtc_v1_zynq_trial_build.yaml) · [XSim case CSV](evidence/data/rdtc_v1_fpga_axis32_xsim_cases.csv)

## ASIC Results

| Profile | Fixed verified closure point | Result maturity |
|---|---|---|
| `rdtc_v1_register_nangate45_550` (`register-expanded`) | 550 MHz OpenROAD P&R + same-run OpenRCX SPEF + PrimeTime; core area `421,120 um2`; route DRC/antenna `0/0`; setup/hold WNS `+0.26/+0.04 ns` | Internal reg-to-reg implementation and timing verified |
| `rdtc_v1_sram_nangate45_333` (OpenRAM `sram-macro`) | 333 MHz chip-level P&R + same-run SPEF + internal PT; route DRC/antenna `0/0`; setup/hold WNS `+0.57/+0.04 ns` | Implementation chain verified; overall profile remains partial because the analytical macro model and macro DRC/LVS/PEX are not closed; the exact reviewed 256-endpoint waiver remains separately disclosed |

Each frequency is a fixed verified closure point for that profile, not a maximum-frequency claim. These are academic implementation results, not complete top-level IO timing, OCV/MMMC, foundry signoff, or silicon readiness.

ASIC evidence: [register-expanded](evidence/rdtc_v1_register_expanded.yaml) · [SRAM macro](evidence/rdtc_v1_sram_macro_333m.yaml)

## Quick Check

```bash
make rdtc_v1_public_preflight_defconfig
make showconfig
make -C ref_model/c test
make rtl-smoke
make multiengine-smoke
make fpga-wrapper-smoke
make showcase-assets-check
```

Questa/ModelSim environments may continue with `make sim` and `make sim-full`. Commercial-tool, PDK, library, and macro paths belong only in ignored `flows/local/`.

## Deep Dives

- [Algorithm and synthetic study](docs/en/algorithm.md)
- [Single-Engine and Multi-Engine architecture](docs/en/architecture.md)
- [Verification chain and evidence boundaries](docs/en/verification.md)
- [FPGA emulation and Zynq integration](docs/en/fpga_implementation.md)
- [Complete result matrix](docs/en/results.md)
- [ASIC implementation details](docs/en/asic_implementation.md)
- [Limitations and explicit nonclaims](docs/en/limitations.md)
- [Public release and integrity model](docs/en/release_model.md)

Current `main` contains post-RC3 presentation and clarification updates. The immutable annotated tag `rdtc-v1-register550-rc3` remains fixed to the original RC3 release and is not moved or recreated by these post-RC3 documentation changes.
