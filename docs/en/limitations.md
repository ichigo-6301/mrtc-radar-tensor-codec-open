# Limitations And Nonclaims

[中文](../zh-CN/limitations.md)

## Algorithm And Functional Scope

- The MATLAB compression-versus-SNR result uses controlled synthetic Range-Doppler-like data, not a measured radar capture. It does not establish a real-scene distribution or final compression bound;
- the MATLAB point-cloud comparison is a model-result check and does not include or imply PointCloud RTL;
- PointCloud RTL, RLE_RICE RTL, AXI-MM, and DMA descriptor integration are not included;
- bit-exact PASS applies to the recorded finite vector/regression set, not exhaustive formal proof or coverage closure;
- ZERO_RICE or DELTA_RICE is configured per block; internal policy selects `k`, not the predictor mode. RAW fallback exists only on encoder paths that implement payload-cost fallback;
- where RAW fallback is supported, it avoids a larger coded payload, but the packet still carries a `64`-byte header, so payload ratio is not automatically an end-to-end bandwidth ratio.

## Multi-Engine And Ordering

- The `785 / 397.52 / 197.41 cycles/block`, `0.987368 / 0.994115` efficiency, and `1965.3022 / 3957.4642 beam/s` at an assumed 200 MHz are RTL simulation projections with a simulated DDR feeder; one beam is 256 blocks in this record and throughput uses unrounded total cycles, not FPGA timing, board DDR, or network measurements;
- arbitration guarantees packet atomicity and no beat interleaving, but does not guarantee output in input-block order;
- Frame/Block metadata enables indexed software reconstruction, but no software reorder-program PASS is claimed, and recorded scenarios do not directly demonstrate an observed reordered event;
- `OUTPUT_IN_ORDER` is not an implemented mode and must not be presented as a hardware Reorder Buffer or strict-order guarantee.

## FPGA Boundary

- **FPGA emulation verified** refers only to the Vivado 2018.3 AXIS32 wrapper `3/3` XSim result;
- historical Zynq trial-copy elaboration with compatibility-copied RTL and SDK/ELF build is a separate build-layer maturity result; direct Vivado 2018.3 elaboration of the current public RTL is not claimed;
- the AXIS32 testbench drives only `s0`, so it is not evidence of dual-Engine scaling, concurrent dual-input behavior, or reordered output;
- no matching FPGA bitstream, board PASS, console-marker PASS, MCDMA/DDR/cache runtime, FPGA timing closure, or LUT/FF/BRAM/DSP resource result is claimed;
- an earlier Block Design and SDK project support structural and build-layer statements only; an intended loopback flow must not be described as an executed board workload;
- any future FPGA frequency or resource claim must bind the device, tool version, constraints, bitstream hash, software hash, and readable test result.

## ASIC And Signoff Boundary

- Complete top-level IO timing closure and silicon readiness are not claimed;
- no CDC/RDC, clock-gating, DFT/ATPG, LEC, GLS/SDF, or foundry-signoff closure is claimed;
- `register-expanded` maps the prefix buffer to standard-cell registers; it is not an SRAM-macro PPA result;
- the 15 nm and 55 nm DC-only profiles provide ideal-clock internal reg-to-reg synthesis boundaries. Removing SRAM does not provide matching parasitic technology, and DC closure does not imply P&R closure, so these results do not establish post-route Fmax;
- the 55 nm profile uses the Apache-2.0 ICsprout55 public-preview PDK. The public repository records source, version, hashes, and reviewed numerical summaries but does not distribute PDK/Liberty/DB payloads or raw commercial reports;
- the 55 nm 600 MHz point closes setup but retains two max-transition nets and three max-capacitance nets, so it is not fully constraint-clean;
- the ICS55/ECOS full-RDTC 400 MHz attempt completed through legalization but did not complete default detailed routing. The route reached 1,058 of 4,761 boxes while violations increased, then stopped under a documented memory-protection limit. It provides no routed netlist, GDS, SPEF, route-stage timing, or P&R/Fmax claim;
- the latest 45 nm register-expanded 550 MHz result is a fixed verified internal reg-to-reg academic closure point, not a maximum-frequency result. It uses a 700 MHz setup-closed DC mapped netlist, OpenRCX SPEF, and PrimeTime. Setup/hold coverage is 100%, but 1,756 asynchronous-reset pins remain outside max-delay coverage; complete IO, reset recovery/removal, OCV/MMMC, macro DRC/LVS/PEX, and foundry signoff are not covered;
- the 45 nm `sram-macro` 333 MHz result completed verified chip-level P&R, same-run SPEF, and internal PrimeTime setup/hold timing. Its overall profile remains partial because OpenRAM characterization is analytical and macro DRC/LVS/PEX is not closed;
- the reviewed waiver is profile-specific and exact-set matched to 256 unused `dout0[127:0]` minimum-capacitance endpoints on the two macros, with no missing or extra objects allowed. It is not a blanket capacitance, setup/hold, or functional-read-data waiver;
- the SRAM 333 MHz result is a fixed verified closure point and must not be extended to a 400 MHz or exact SRAM-Fmax claim. Without a controlled 400 MHz failure run and critical-path evidence, SRAM cannot be called the sole limiting cause;
- SRAM and register-expanded areas must not be compared directly without stating physical capacity, read latency, and modeling differences;
- public route DRC/antenna counts belong to the specified academic platform run and are not foundry DRC/LVS. Route-tool DRC 0 covers the routed top-level implementation and macro abstract views, not transistor-level macro DRC/LVS/PEX;
- `DC timing estimate`, internal post-route reg-to-reg timing, and complete IO timing closure are different evidence levels and cannot substitute for one another.

## Public Boundary

PDKs, Liberty/DB, LEF/GDS, SPEF, licenses, absolute paths, raw EDA work directories, generated Vivado projects/BD/IP, bitstreams, SDK workspaces, and unauthorized sources are not distributed. Post-RC3 presentation updates on current `main` do not change the immutable RC3 result identity or release boundary.
