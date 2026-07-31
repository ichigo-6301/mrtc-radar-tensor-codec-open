# FPGA Emulation, Direct OOC, And Zynq Integration

[中文](../zh-CN/fpga_implementation.md)

## Conclusion

**FPGA emulation verified** maps specifically to the historical Vivado 2018.3 AXIS32 XSim `3/3` result. Separately, the bounded Direct-AXIS dual-Engine top has a verified Vivado 2022.2 OOC post-route 200 MHz internal timing/resource point on `xc7z100ffg900-2`. Neither result claims a bitstream or board execution, and the historical AXIS32 result still has no timing/resource claim.

![Zynq FPGA emulation evidence layers](../assets/zynq_emulation_path.svg)

## AXIS32 Wrapper XSim

The Vivado 2018.3 XSim run passes `3/3` block-level cases:

- a ZERO_RICE block;
- a DELTA_RICE block with output backpressure;
- a mixed two-block sequence with packet-boundary checks.

The testbench traverses the real RDTC encoder path and uses decoder golden comparison for reconstructed data. It covers AXIS32 width conversion, variable-length packet serialization, final-beat `tkeep/tlast`, input gaps, and output stalls.

This testbench drives only `s0`; `s1` is not used as a concurrent input. It therefore does not claim XSim verification of dual-Engine scaling, concurrent dual-input behavior, or reordered output. Separate RTL regression supports Multi-Engine scaling and packet arbitration.

## Bounded Direct-AXIS OOC 200 MHz

The Direct profile uses the current AXIS128 top, two bounded Engines, eight distributed-RAM ways, and one 16-beat output FIFO. A fresh Vivado 2022.2 OOC implementation on `xc7z100ffg900-2` passes the fixed 5.000 ns internal timing gate:

| Post-route item | Result |
|---|---:|
| Setup WNS/TNS/failing endpoints | `+0.001 ns / 0 / 0` |
| Hold WNS/TNS/failing endpoints | `+0.062 ns / 0 / 0` |
| Pulse-width WNS/TNS/failing endpoints | `+1.732 ns / 0 / 0` |
| Slice LUT / registers | `32,672 / 18,519` |
| RAMB18 / RAMB36 | `0 / 0` |
| Ring primitives | `1024 x RAM32X1S` in exactly 8 ways |
| DDR feeder / payload commit / legacy packet buffer | `0 / 0 / 0` |

The old payload512 reference used `53,235 LUT / 85,269 FF / 4 RAMB36`; the Direct point removes `20,563 LUT`, `66,750 FF`, and all four RAMB36 at this fixed configuration. This is a structural comparison, not a board-power or application-throughput result.

The 1 ps setup margin is intentionally reported without rounding it into a broader claim. OOC constraints cover internal endpoints, not board-level IO delay. The worst path remains routing-dominated control from Engine error state through global fatal/output-ready control to the width-packer. No Fmax, bitstream, board, or sustained zero-gap claim follows from this point.

Evidence: [bounded Direct FPGA OOC summary](../../evidence/rdtc_v1_bounded_direct_fpga_ooc200.yaml).

## Zynq-7000 Platform Path

An earlier Vivado/SDK trial copy contains a Zynq PS, Block Design, MCDMA/DDR connectivity, and software test programs for a SoC loopback path. Vivado 2018.3 rejected the repository's `parameter string` declarations, so the recorded successful `synth_design -rtl` used a compatibility-modified copied RTL set. The public, evidence-bounded conclusions are:

| Layer | Status | What it establishes |
|---|---|---|
| Current public RTL source and wrapper | verified input | Available to modern SystemVerilog simulation; not direct Vivado 2018.3 elaboration evidence |
| Trial-copy RTL elaboration | verified with compatibility copy | Historical trial-copy structure, ports, and dependencies completed `synth_design -rtl` |
| SDK/ELF build | verified | The platform software project builds |
| Matching bitstream | not claimed | No claim that the current dual-Engine wrapper produced a matching bitstream |
| Board execution / console PASS | not claimed | No board workload or console-marker PASS is claimed |
| MCDMA/DDR/cache runtime | not claimed | No DMA descriptor, cache-coherency, or measured DDR behavior is claimed |
| Historical AXIS32 timing/resources | not claimed | This profile has no device-bound WNS, Fmax, LUT/FF/BRAM/DSP result; the Direct OOC result is separate |

The recommended complete wording is:

> FPGA emulation result: the AXIS32 datapath XSim suite is verified `3/3`. Separate Zynq trial-copy maturity result: compatibility-copied RTL elaboration and SDK/ELF build are verified; direct elaboration of the current public RTL and board hardware execution are not claimed.

The historical platform includes BD/MCDMA structure and software interfaces, but the verified scope stops at trial-copy elaboration and SDK/ELF build. It is neither direct Vivado 2018.3 elaboration of the current public RTL nor an MCDMA runtime PASS.

Public evidence summary and data: [XSim evidence](../../evidence/rdtc_v1_fpga_axis32_emulation.yaml) · [Zynq trial-build evidence](../../evidence/rdtc_v1_zynq_trial_build.yaml) · [XSim case CSV](../../evidence/data/rdtc_v1_fpga_axis32_xsim_cases.csv)

## Relationship To Multi-Engine Results

The FPGA page and Multi-Engine RTL evidence answer different questions:

- FPGA XSim shows that the AXIS32 adapter, real codec path, and loopback checker work in the three recorded cases;
- Multi-Engine RTL regression checks block distribution, independent packet buffers, packet-locked output, and scaling;
- Direct OOC verifies the separate bounded dual-Engine structure and internal timing at one fixed FPGA point;
- these layers cannot be combined into a claim of a dual-Engine bitstream passing on board.

The `1965.3022 / 3957.4642 beam/s` values at an assumed 200 MHz are 2/4-Engine RTL simulation projections. One beam is 256 blocks in this record and throughput uses unrounded total cycles; this is not an FPGA implementation frequency. Any future board result must bind the device, Vivado version, constraints, bitstream hash, software hash, test vector, and console/result marker.
