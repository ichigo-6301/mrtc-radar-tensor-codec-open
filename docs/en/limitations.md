# Limitations

- PointCloud RTL, RLE_RICE RTL, AXI-MM, and DMA descriptor integration are not included;
- No board PASS, complete top-level IO timing closure, or silicon-readiness claim is made;
- No CDC/RDC, clock-gating, DFT/ATPG, LEC, GLS/SDF, or foundry-signoff closure is claimed;
- `register-expanded` maps the prefix buffer to standard-cell registers; it is not an SRAM-macro PPA result;
- The 15 nm and 55 nm DC-only profiles provide ideal-clock internal reg-to-reg synthesis boundaries. Removing SRAM does not provide matching parasitic technology, and DC closure does not imply P&R closure, so these results do not establish post-route Fmax;
- The 55 nm profile uses the Apache-2.0 ICsprout55 public-preview PDK. The public repository records source, version, hashes, and reviewed numerical summaries but does not distribute PDK/Liberty/DB payloads or raw commercial reports;
- The 55 nm 600 MHz point closes setup but retains two max-transition nets and three max-capacitance nets, so it is not fully constraint-clean;
- The latest 45 nm register-expanded 550 MHz result is internal reg-to-reg academic timing. It uses a 700 MHz setup-closed DC mapped netlist, OpenRCX SPEF, and PrimeTime. Setup/hold coverage is 100%, but 1,756 asynchronous-reset pins remain outside max-delay coverage; complete IO, reset recovery/removal, OCV/MMMC, macro DRC/LVS/PEX, and foundry signoff are not covered;
- The 45 nm `sram-macro` 333 MHz result uses two `64x128 1RW1R` OpenRAM macros. Its analytical characterization, minimum-capacitance waiver for 256 unused `dout0` endpoints, and macro-view boundaries remain explicit;
- The SRAM 333 MHz result must not be extended to 400 MHz. SRAM and register-expanded areas must not be compared directly without stating the physical-capacity and modeling differences;
- Public route DRC/antenna counts belong to the specified academic platform run and are not foundry DRC/LVS;
- `DC timing estimate`, internal post-route reg-to-reg timing, and complete IO timing closure are different levels of evidence and cannot substitute for one another;
- PDKs, Liberty/DB, LEF/GDS, SPEF, licenses, absolute paths, raw EDA work directories, and unauthorized sources are not distributed.
