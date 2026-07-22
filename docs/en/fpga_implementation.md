# FPGA Emulation And Zynq Integration

[中文](../zh-CN/fpga_implementation.md)

## Conclusion

**FPGA emulation verified.** This statement maps specifically to the Vivado 2018.3 AXIS32 wrapper functional XSim result: `3/3` recorded cases pass. Separately, the historical Zynq-7000 trial copy has verified compatibility-copied RTL elaboration and SDK/ELF build results at those maturity layers. Direct Vivado 2018.3 elaboration of the current public RTL is not claimed. Neither is bitstream generation, board execution, or timing closure.

![Zynq FPGA emulation evidence layers](../assets/zynq_emulation_path.svg)

## AXIS32 Wrapper XSim

The Vivado 2018.3 XSim run passes `3/3` block-level cases:

- a ZERO_RICE block;
- a DELTA_RICE block with output backpressure;
- a mixed two-block sequence with packet-boundary checks.

The testbench traverses the real RDTC encoder path and uses decoder golden comparison for reconstructed data. It covers AXIS32 width conversion, variable-length packet serialization, final-beat `tkeep/tlast`, input gaps, and output stalls.

This testbench drives only `s0`; `s1` is not used as a concurrent input. It therefore does not claim XSim verification of dual-Engine scaling, concurrent dual-input behavior, or reordered output. Separate RTL regression supports Multi-Engine scaling and packet arbitration.

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
| FPGA timing/resources | not claimed | No device-bound WNS, Fmax, LUT/FF/BRAM/DSP result is published |

The recommended complete wording is:

> FPGA emulation result: the AXIS32 datapath XSim suite is verified `3/3`. Separate Zynq trial-copy maturity result: compatibility-copied RTL elaboration and SDK/ELF build are verified; direct elaboration of the current public RTL and board hardware execution are not claimed.

The historical platform includes BD/MCDMA structure and software interfaces, but the verified scope stops at trial-copy elaboration and SDK/ELF build. It is neither direct Vivado 2018.3 elaboration of the current public RTL nor an MCDMA runtime PASS.

Public evidence summary and data: [XSim evidence](../../evidence/rdtc_v1_fpga_axis32_emulation.yaml) · [Zynq trial-build evidence](../../evidence/rdtc_v1_zynq_trial_build.yaml) · [XSim case CSV](../../evidence/data/rdtc_v1_fpga_axis32_xsim_cases.csv)

## Relationship To Multi-Engine Results

The FPGA page and Multi-Engine RTL evidence answer different questions:

- FPGA XSim shows that the AXIS32 adapter, real codec path, and loopback checker work in the three recorded cases;
- Multi-Engine RTL regression checks block distribution, independent packet buffers, packet-locked output, and scaling;
- the two cannot be combined into a claim of a dual-Engine bitstream passing on board.

The `1965.3022 / 3957.4642 beam/s` values at an assumed 200 MHz are 2/4-Engine RTL simulation projections. One beam is 256 blocks in this record and throughput uses unrounded total cycles; this is not an FPGA implementation frequency. Any future board result must bind the device, Vivado version, constraints, bitstream hash, software hash, test vector, and console/result marker.
