# Limitations And Nonclaims

[中文](../zh-CN/limitations.md)

## Algorithm And Functional Scope

- The MATLAB compression-versus-SNR result uses controlled synthetic Range-Doppler-like data, not a measured radar capture. It does not establish a real-scene distribution or final compression bound;
- the MATLAB point-cloud comparison is a model-result check and does not include or imply PointCloud RTL;
- PointCloud RTL, RLE_RICE RTL, AXI-MM, and DMA descriptor integration are not included;
- bit-exact PASS applies to the recorded finite vector/regression set, not exhaustive formal proof or coverage closure;
- ZERO_RICE or DELTA_RICE is configured per block; internal policy selects `k`, not the predictor mode. RAW fallback exists only on encoder paths that implement payload-cost fallback;
- where RAW fallback is supported, it avoids a larger coded payload, but the packet still carries a `64`-byte header, so payload ratio is not automatically an end-to-end bandwidth ratio.
- the historical `7693 -> 721 cycles`, `10.67x` result measures only the inclusive first-payload-valid to accepted-`TLAST` interval on the fixed `smoke_zero_sparse` RTL workload. It is not whole-block latency, Multi-Engine throughput, current Direct-AXIS sustained throughput, FPGA performance, ASIC frequency, or Fmax.

## Multi-Engine And Ordering

- The `785 / 397.52 / 197.41 cycles/block`, `0.987368 / 0.994115` efficiency, and `1965.3022 / 3957.4642 beam/s` at an assumed 200 MHz are RTL simulation projections with a simulated DDR feeder; one beam is 256 blocks in this record and throughput uses unrounded total cycles, not FPGA timing, board DDR, or network measurements;
- arbitration guarantees packet atomicity and no beat interleaving, but does not guarantee output in input-block order;
- Frame/Block metadata enables indexed software reconstruction, but no software reorder-program PASS is claimed, and recorded scenarios do not directly demonstrate an observed reordered event;
- `OUTPUT_IN_ORDER` is not an implemented mode and must not be presented as a hardware Reorder Buffer or strict-order guarantee.
- the opt-in bounded Direct-AXIS wrapper does preserve descriptor order at its packet output, but its recorded ordered service is approximately `277 cycles/block`, above the `256-cycle` zero-gap arrival interval. A finite four-way ring delays the resulting conflict; it does not establish sustained zero-stall operation;
- Direct output-credit exhaustion (`MRTC_ERR_OUTPUT_CREDIT`, `24`) is sticky fatal. Because this profile intentionally has no speculative payload commit store, a partial packet can already be externally visible and recovery requires a real reset of both producer and receiver state.

## FPGA Boundary

- **FPGA emulation verified** refers only to the Vivado 2018.3 AXIS32 wrapper `3/3` XSim result;
- historical Zynq trial-copy elaboration with compatibility-copied RTL and SDK/ELF build is a separate build-layer maturity result; direct Vivado 2018.3 elaboration of the current public RTL is not claimed;
- the AXIS32 testbench drives only `s0`, so it is not evidence of dual-Engine scaling, concurrent dual-input behavior, or reordered output;
- the historical AXIS32/Zynq profile has no matching FPGA bitstream, board PASS, console-marker PASS, MCDMA/DDR/cache runtime, FPGA timing closure, or LUT/FF/BRAM/DSP resource claim;
- the separate bounded Direct-AXIS profile has one fixed Vivado 2022.2 OOC post-route point at 200 MHz on `xc7z100ffg900-2`: setup/hold WNS is `+0.001/+0.062 ns` and utilization is `32,672 LUT / 18,519 FF / 0 BRAM`. The 1 ps setup margin supports only that exact internal OOC point;
- the Direct result does not establish board IO timing, Fmax, a generated bitstream, board execution, MCDMA/DDR runtime, or measured/sustained throughput;
- an earlier Block Design and SDK project support structural and build-layer statements only; an intended loopback flow must not be described as an executed board workload;
- any future FPGA frequency or resource claim must bind the device, tool version, constraints, bitstream hash, software hash, and readable test result.

## ASIC And Signoff Boundary

- Complete top-level IO timing closure and silicon readiness are not claimed;
- no CDC/RDC, clock-gating, DFT/ATPG, LEC, GLS/SDF, or foundry-signoff closure is claimed;
- the `72.53%` cell-area and `71.98%` cell-count reductions are a same-library, same-315 MHz, register-expanded Design Compiler A/B. They are not SRAM-macro area, post-route area, power, Fmax, or signoff results;
- the historical `register-expanded` profile maps its prefix buffer to standard-cell registers. The Direct register profile similarly expands `32,768` way-ring bits. Neither result is an SRAM-macro PPA result;
- the 15 nm DC-only profile provides an ideal-clock internal reg-to-reg synthesis boundary. DC closure does not imply P&R closure, so this result does not establish post-route Fmax;
- the latest 45 nm register-expanded 550 MHz result is a fixed verified internal reg-to-reg academic closure point, not a maximum-frequency result. It uses a 700 MHz setup-closed DC mapped netlist, OpenRCX SPEF, and PrimeTime. Setup/hold coverage is 100%, but 1,756 asynchronous-reset pins remain outside max-delay coverage; complete IO, reset recovery/removal, OCV/MMMC, macro DRC/LVS/PEX, and foundry signoff are not covered;
- both Nangate45 physical profiles use a configured `1200 x 1200 um` die and `1159.72 x 1155.20 um` core from the public OpenROAD floorplan configuration; `421,120 um2` is final standard-cell design area for the 550 MHz register-expanded result only;
- the 45 nm `sram-macro` 333 MHz result completed verified chip-level P&R, same-run SPEF, and internal PrimeTime setup/hold timing. It uses academic Nangate45/OpenRAM data, so no production PDK, macro DRC/LVS/PEX, complete IO, OCV/MMMC, or silicon-signoff claim is made;
- the reviewed waiver is profile-specific and exact-set matched to 256 unused `dout0[127:0]` minimum-capacitance endpoints on the two macros, with no missing or extra objects allowed. It is not a blanket capacitance, setup/hold, or functional-read-data waiver;
- the SRAM 333 MHz result is a fixed verified closure point and must not be extended to a 400 MHz or exact SRAM-Fmax claim. Without a controlled 400 MHz failure run and critical-path evidence, SRAM cannot be called the sole limiting cause;
- the bounded Direct register-expanded profile is a fixed 600 MHz academic internal closure point with PrimeTime setup/hold WNS `+0.03/+0.02 ns`, zero memory macros, and `476,320 um2` final standard-cell area. It is not an Fmax, complete-IO, or sustained-throughput claim;
- the bounded Direct SRAM profile is a fixed 300 MHz academic internal closure point with eight `32x128 1RW` OpenRAM macros and PrimeTime setup/hold WNS `+0.16/+0.02 ns`. Route-tool DRC and antenna checks do not close transistor-level macro DRC/LVS/PEX;
- bounded Direct SRAM at 600 MHz is `MACRO_MODEL_BLOCKED`, not an executable verified profile. The characterized WPR2/WPR1 candidates exceed the `1.666667 ns` period and `0.833333 ns` pulse-width gates, while WPR4 is unsupported by the pinned OpenRAM generator;
- SRAM and register-expanded areas must not be compared directly without stating physical capacity, read latency, and modeling differences;
- public route DRC/antenna counts belong to the specified academic platform run and are not foundry DRC/LVS. Route-tool DRC 0 covers the routed top-level implementation and macro abstract views, not transistor-level macro DRC/LVS/PEX;
- `DC timing estimate`, internal post-route reg-to-reg timing, and complete IO timing closure are different evidence levels and cannot substitute for one another.

## Public Boundary

PDKs, SRAM Liberty/DB/LEF/GDS/SPICE, SPEF/DCP, licenses, absolute paths, raw EDA reports or work directories, generated Vivado projects/BD/IP, bitstreams, SDK workspaces, and unauthorized sources are not distributed. The Direct summaries publish bounded metrics and hashes only. Post-RC3 updates on current `main` do not change the immutable RC3 result identity or release boundary.
