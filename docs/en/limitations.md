# Limitations

- PointCloud RTL, RLE_RICE RTL, AXI-MM, and DMA descriptor integration are not included;
- No board PASS, complete top-level IO timing closure, or silicon-readiness claim is made;
- No CDC/RDC, clock-gating, DFT/ATPG, LEC, GLS/SDF, or foundry-signoff closure is claimed;
- `register-expanded` maps the prefix buffer to standard-cell registers; it is not an SRAM-macro PPA result;
- 15 nm and 55 nm currently provide DC comparison boundaries only. Removing SRAM does not provide a matching parasitic technology for OpenROAD/ICC2, so no post-route Fmax is claimed for them;
- 55 nm metrics and proprietary/restricted library information are excluded from the public repository;
- The 45 nm register-expanded 400 MHz result is internal reg-to-reg academic timing. It uses a 600 MHz setup-closed DC mapped netlist, OpenRCX SPEF, and PrimeTime, but does not cover IO, OCV/MMMC, macro DRC/LVS/PEX, or foundry signoff;
- The 45 nm `sram-macro` 333 MHz result uses two `64x128 1RW1R` OpenRAM macros. Its analytical characterization, minimum-capacitance waiver for 256 unused `dout0` endpoints, and macro-view boundaries remain explicit;
- The SRAM 333 MHz result must not be extended to 400 MHz. SRAM and register-expanded areas must not be compared directly without stating the physical-capacity and modeling differences;
- Public route DRC/antenna counts belong to the specified academic platform run and are not foundry DRC/LVS;
- `DC timing estimate`, internal post-route reg-to-reg timing, and complete IO timing closure are different levels of evidence and cannot substitute for one another;
- PDKs, Liberty/DB, LEF/GDS, SPEF, licenses, absolute paths, raw EDA work directories, and unauthorized sources are not distributed.
