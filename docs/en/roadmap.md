# Roadmap

The public repository now records four independent academic physical comparison boundaries:

- historical `register-expanded`: 15 nm DC comparison plus the fixed Nangate45 550 MHz OpenROAD/OpenRCX/PrimeTime point;
- historical `sram-macro`: two `64x128 1RW1R` macros and the fixed Nangate45/OpenRAM 333 MHz point;
- bounded Direct `register-expanded`: two Engines, `32,768` expanded way-ring bits, and the fixed Nangate45 600 MHz point;
- bounded Direct `sram-macro`: eight `32x128 1RW` macros and the fixed Nangate45/OpenRAM 300 MHz point.

The Direct profile remains opt-in; `mrtc_top` remains the canonical integration top. Its next architectural task is to reduce ordered packet service from approximately `277 cycles/block` to at most the `256-cycle` zero-gap arrival interval, or to qualify a different Engine/bank scheduling geometry. Until then, sustained zero-stall remains explicitly not claimed even though the finite two-block regression and fixed FPGA/ASIC timing points pass.

Future implementation work is tracked per profile: complete IO timing, CDC/RDC, gated P&R/CTS power, scan DFT, LEC, macro DRC/LVS/PEX, OCV/MMMC, and node- and stack-matched signoff extraction. The Direct SRAM 600 MHz attempt is `MACRO_MODEL_BLOCKED`; revisiting it requires a legal characterized macro organization, not a relaxed clock check. FPGA follow-up requires a bitstream and board workload before any board claim. A stage changes status only after its scripts, configuration, executed output, and evidence are complete; none of the fixed points is an Fmax claim.
