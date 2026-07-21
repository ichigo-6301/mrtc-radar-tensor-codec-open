# Limitations

- PointCloud RTL, RLE_RICE RTL, AXI-MM, and DMA descriptor integration are not included;
- No board PASS, complete top-level IO timing closure, or silicon-readiness claim is made;
- No CDC/RDC, clock-gating, DFT/ATPG, LEC, GLS/SDF, or foundry-signoff closure is claimed;
- `register-expanded` maps the prefix buffer to standard-cell registers; it is not an SRAM-macro PPA result;
- The 15 nm and 55 nm DC-only profiles provide ideal-clock internal reg-to-reg synthesis boundaries. Removing SRAM does not provide matching parasitic technology, and DC closure does not imply P&R closure, so these results do not establish post-route Fmax;
- The 55 nm profile uses the Apache-2.0 ICsprout55 public-preview PDK. The public repository records source, version, hashes, and reviewed numerical summaries but does not distribute PDK/Liberty/DB payloads or raw commercial reports;
- The 55 nm 600 MHz point closes setup but retains two max-transition nets and three max-capacitance nets, so it is not fully constraint-clean;
- The ICS55/ECOS full-RDTC 400 MHz attempt completed through legalization but did not complete default detailed routing. The route reached 1,058 of 4,761 boxes while violations increased, then stopped under a documented memory-protection limit. It provides no routed netlist, GDS, SPEF, route-stage timing, or P&R/Fmax claim;
- The latest 45 nm register-expanded 550 MHz result is internal reg-to-reg academic timing. It uses a 700 MHz setup-closed DC mapped netlist, OpenRCX SPEF, and PrimeTime. Setup/hold coverage is 100%, but 1,756 asynchronous-reset pins remain outside max-delay coverage; complete IO, reset recovery/removal, OCV/MMMC, macro DRC/LVS/PEX, and foundry signoff are not covered;
- The 45 nm `sram-macro` 333 MHz result completed verified chip-level P&R, same-run SPEF, and internal PrimeTime setup/hold timing. Its overall profile remains partial because OpenRAM characterization is analytical and macro DRC/LVS/PEX is not closed;
- The reviewed waiver is profile-specific and exact-set matched to 256 unused `dout0[127:0]` minimum-capacitance endpoints on the two macros, with no missing or extra objects allowed. It is not a blanket capacitance, setup/hold, or functional-read-data waiver;
- The SRAM 333 MHz result must not be extended to 400 MHz. SRAM and register-expanded areas must not be compared directly without stating the physical-capacity and modeling differences;
- Public route DRC/antenna counts belong to the specified academic platform run and are not foundry DRC/LVS. Route-tool DRC 0 covers the routed top-level implementation and macro abstract views, not transistor-level macro DRC/LVS/PEX;
- `DC timing estimate`, internal post-route reg-to-reg timing, and complete IO timing closure are different levels of evidence and cannot substitute for one another;
- PDKs, Liberty/DB, LEF/GDS, SPEF, licenses, absolute paths, raw EDA work directories, and unauthorized sources are not distributed.
