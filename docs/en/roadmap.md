# Roadmap

The public repository has two stable implementation boundaries:

- `register-expanded`: 15 nm DC comparison and a 45 nm OpenROAD/OpenRCX/PrimeTime academic physical profile;
- `sram-macro`: 45 nm, two `64x128 1RW1R` macros, and a fixed approximately 333 MHz comparison result.

Future work is tracked per profile: IO timing constraints, CDC/RDC, clock gating, scan DFT, LEC, same-voltage SRAM characterization, macro DRC/LVS/PEX, and node- and stack-matched signoff extraction technology. A stage changes status only after its scripts, configuration, executed tool output, and evidence are complete.

No post-route Fmax is claimed for the 15 nm profile in this candidate. Any physical implementation requires authorized parasitic technology matched to the node and layer stack. The SRAM profile will not continue a new high-frequency sweep; 333 MHz is the current public physical comparison boundary.
