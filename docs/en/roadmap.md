# Roadmap

The public repository has two stable implementation boundaries:

- `register-expanded`: 15 nm DC comparison and a 45 nm OpenROAD/OpenRCX/PrimeTime academic physical profile;
- `sram-macro`: 45 nm, two `64x128 1RW1R` macros, and a fixed approximately 333 MHz comparison result.

Future work is tracked per profile: IO timing constraints, CDC/RDC, clock gating, scan DFT, LEC, same-voltage SRAM characterization, macro DRC/LVS/PEX, and node- and stack-matched signoff extraction technology. A stage changes status only after its scripts, configuration, executed tool output, and evidence are complete.

No post-route Fmax is claimed for 15/55 nm in this candidate. Physical implementation for those profiles requires authorized parasitic technology matched to the node and layer stack. The SRAM profile will not continue a new high-frequency sweep; 333 MHz is the current public physical comparison boundary.

`rdtc_v1_register_ics55_ecos_preview` remains `planned` as a publishable implementation profile. A reproducible 400 MHz full-RDTC attempt reached detailed routing but stopped under documented resource protection before route completion; no P&R, STA, or frequency result is published. The next experiment must review floorplan, utilization, placement density, and routing-resource changes as a new run rather than shorten the default detailed router.
