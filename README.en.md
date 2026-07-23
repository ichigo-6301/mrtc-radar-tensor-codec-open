# MRTC-RDTC Scalable Lossless Radar-Tensor Codec IP

[中文](README.md) · [Algorithm](docs/en/algorithm.md) · [Architecture](docs/en/architecture.md) · [Verification](docs/en/verification.md) · [Results](docs/en/results.md) · [Immutable RC3](docs/en/release_model.md)

**A streaming lossless codec for OFDM sensing and millimeter-wave radar Range-Doppler tensors, engineered from MATLAB algorithms and synthesizable RTL through Multi-Engine scheduling, FPGA emulation, and ASIC post-route STA.**

RDTC compresses I16Q16 samples block by block while preserving bit-exact reconstruction. A 64-byte self-describing header carries mode, length, and Frame/Block identity so each packet can be stored, transported, and reconstructed independently.

![MRTC-RDTC end-to-end overview](docs/assets/rdtc_overview.svg)

## 60-Second Overview

| Dimension | Implemented and verified content |
|---|---|
| Lossless algorithm | `RAW_BYPASS`, `ZERO_RICE`, and `DELTA_RICE`; bit-exact I/Q reconstruction |
| Single Engine | `1024` I16Q16 samples/block, `4096` raw bytes, 64-byte header, 128-bit AXI-Stream |
| Multi-Engine | Round-robin block dispatch, independent feeder/codec/packet buffer, packet-locked arbitration |
| RTL throughput | 1/2/4 Engines: `785 / 397.52 / 197.41 cycles/block` on the fixed 256-block simulation workload |
| FPGA | Fixed-commit, single-`s0` Vivado 2018.3 AXIS32 XSim `3/3` passes; Zynq trial covers only compatibility-copied RTL elaboration + SDK/ELF build |
| ASIC | Nangate45 register-expanded at 550 MHz and dual-OpenRAM SRAM-macro at 333 MHz both complete OpenROAD P&R and pass PrimeTime post-route setup/hold STA using matching routed netlist/SDC and same-run OpenRCX SPEF; the overall SRAM profile remains partial |

## 1. Algorithm: Why RDTC

The ZERO/DELTA paths map prediction residuals to non-negative integers, evaluate candidate Rice `k` values over each block, and emit a variable-length payload through a lane-parallel bitpacker. Encoder paths that implement fallback retain RAW payload when coding provides no benefit. Mode and fallback behavior remain explicit properties of each integration path rather than an unsupported universal auto-selection claim.

The MATLAB synthetic study compares ZERO_RICE and DELTA_RICE on controlled Range-Doppler-like scenes and checks `NMSE=0`, `max_abs_error=0`, and point-cloud match ratio `1` for the recorded cases. These are not measured radar captures, and PointCloud is not an RTL feature.

<p align="center">
  <img src="docs/assets/compression_vs_snr.svg" width="49%" alt="Synthetic compression ratio versus SNR">
  <img src="docs/assets/engine_scaling.svg" width="49%" alt="Multi-Engine RTL simulation scaling">
</p>

Data and boundaries: [algorithm theory and original MATLAB output](docs/en/algorithm.md) · [MATLAB evidence](evidence/rdtc_v1_matlab_algorithm_study.yaml) · [Multi-Engine evidence](evidence/rdtc_v1_multiengine_rtl.yaml)

## 2. Architecture: Single Engine to Multi-Engine

A Single Engine combines a ping-pong block buffer, predictor/residual mapper, prefix-cost and `k` selection, lane-parallel bitpacker, header generator, packet buffer, and decoder. Input capture overlaps current-block computation, while the packet buffer isolates variable-length encoding from AXI backpressure.

The parameterized Multi-Engine wrapper dispatches whole blocks round-robin and locks an output packet through `tlast`, preventing beat interleaving within a packet. Completion order remains data-dependent and is not guaranteed. Frame/Block metadata provides an indexed software-reconstruction interface; this repository does not claim a software reorder program PASS or turn an unobserved reorder event into a verification result.

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

Public smoke tests cover the C reference model, RTL loopback, packet boundaries, `tkeep/tlast`, randomized backpressure, Multi-Engine arbitration, and the AXIS32 wrapper. Passing finite vectors and regressions is not formal exhaustiveness or coverage closure.

[See the verification matrix and reproducible entrypoints](docs/en/verification.md)

## 4. FPGA: Layered Maturity

**FPGA emulation verified.** At fixed source commit `43deb9f`, Vivado 2018.3 AXIS32 wrapper XSim passes `3/3` cases covering the real encoder/decoder path, width conversion, variable-length packets, `tkeep/tlast`, input gaps, and output backpressure. That testbench drives only `s0`; a separate RTL regression supports dual-Engine scaling. The public Icarus-compatible wrapper/testbench is an adaptation of the historical source, not a new Vivado result, and the current public RTL is not claimed to elaborate directly in Vivado 2018.3. The Zynq-7000 trial claims only compatibility-copied RTL elaboration and SDK/ELF build, not a matching bitstream, board-console PASS, MCDMA/DDR runtime, FPGA timing, or resource results.

[See FPGA emulation and Zynq integration boundaries](docs/en/fpga_implementation.md)

## 5. ASIC: Post-Route STA Closure, Not a DC Result or Fmax

**Both the 550 MHz and 333 MHz results below come from PrimeTime setup/hold STA after routing, not from a DC synthesis timing estimate.** STA uses the matching routed netlist, SDC, and same-run OpenRCX SPEF; DC supplies only the mapped netlist handed to physical implementation.

| Profile | Verified implementation result | Maturity boundary |
|---|---|---|
| `rdtc_v1_register_nangate45_550` | 550 MHz OpenROAD P&R + same-run OpenRCX SPEF + PrimeTime; core area `421,120 um2`; route DRC `0`; antenna net/pin `0/0`; setup/hold WNS `+0.26/+0.04 ns` | internal register-to-register implementation/timing verified |
| `rdtc_v1_sram_nangate45_333` | Two `64x128 1RW1R` OpenRAM macros; 333 MHz chip-level P&R + same-run SPEF + internal PT; route DRC `0`; antenna net/pin `0/0`; setup/hold WNS `+0.57/+0.04 ns` | implementation chain verified; overall profile remains partial because the analytical macro model and macro DRC/LVS/PEX are not closed; the 256-endpoint exact-set waiver remains separately disclosed |

These frequencies are fixed verified closure points for the stated profiles, not maximum frequencies. The results are academic implementation evidence and do not claim complete top-level IO timing, OCV/MMMC, foundry signoff, or silicon readiness.

[See the ASIC flow contract](docs/en/asic_implementation.md) · [complete result matrix](docs/en/results.md) · [limitations and nonclaims](docs/en/limitations.md)

## Quick Reproduction

```bash
make rdtc_v1_public_preflight_defconfig
make -C ref_model/c test
make rtl-smoke
make multiengine-smoke
make fpga-wrapper-smoke
make showcase-assets-check
```

Questa/ModelSim environments can additionally run `make sim` and `make sim-full`. Commercial-tool, PDK, library, and macro paths are allowed only in ignored `flows/local/` files.

## Documentation and Release Boundary

[Interfaces](docs/en/interfaces.md) · [Bitstream format](docs/en/bitstream_format.md) · [Register map](docs/en/register_map.md) · [Public release model](docs/en/release_model.md) · [Evidence index](provenance/evidence.yaml) · [Claims](provenance/claims.yaml)

This showcase is a post-RC3 presentation update. The immutable annotated tag `rdtc-v1-register550-rc3` still identifies the original `register550-rc3` release and is not moved or recreated by documentation or public-adaptation changes.
