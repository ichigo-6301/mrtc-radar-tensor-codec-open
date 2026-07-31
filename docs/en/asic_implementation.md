# ASIC Implementation

Public ASIC content contains the historical wrapper's `register-expanded`/`sram-macro` pair and a separate bounded Direct-AXIS pair. Each pair preserves its own RTL interface and packet contract while changing only the bulk-memory leaf binding. The historical Nangate45 profiles use the configured `1200 x 1200 um` die and `1159.72 x 1155.20 um` core described below; the Direct profiles have independent floorplans derived from their own synthesized area and macro geometry. Configured geometry is not a post-hoc GDS measurement.

## Register-expanded

`register-expanded` binds no SRAM leaf; prefix buffers are implemented as standard-cell registers, so the SRAM macro count is zero. The primary public results use the NanGate15 and Nangate45 DC matrices; Nangate45 adds a 700 MHz point. NanGate15 Liberty uses a 1 ps time unit, so the flow applies `SDC_TIME_SCALE=1000.0`. Since 45 nm closes at 700 MHz but not at 800 MHz, the 700 MHz mapped netlist is selected for the latest physical handoff.

The public 45 nm physical profile uses OpenROAD/OpenRCX and PrimeTime. It imports the 700 MHz DC netlist, reapplies a 550 MHz P&R/STA constraint, and completes placement, CTS, route, and SPEF generation. Route DRC and antenna net/pin counts are zero; PrimeTime setup/hold WNS is +0.26/+0.04 ns with 100% setup/hold coverage. A total of 1,756 asynchronous-reset pins remain outside max-delay coverage. This is internal reg-to-reg academic timing, not complete IO, reset recovery/removal, OCV/MMMC, or foundry signoff.

## SRAM-macro

`sram-macro` instantiates two `64x128 1RW1R` OpenRAM macros, one per engine, while the wrapper preserves the one-cycle read latency, existing AXI protocol, and address behavior. The fixed verified closure point is 333 MHz: chip-level OpenROAD P&R completed, route DRC and antenna net/pin counts are 0/0, the same run produced the routed handoff and OpenRCX SPEF, and PrimeTime read the matching netlist, SDC, and SPEF. Setup/hold WNS/TNS is +0.57/+0.04 ns and 0/0, with zero constraint violations.

### Academic Scope And Result Interpretation

The chip-level implementation chain and measured internal post-route timing are verified results. This learning and engineering project uses an academic Nangate45/OpenRAM platform; it has no production foundry PDK or macro-signoff package, so it makes no production-PDK, macro DRC/LVS/PEX, or silicon-readiness claim. The OpenRAM timing model is analytically characterized, but that does not change the PrimeTime setup/hold result using the matching routed netlist, SDC, and same-run SPEF. The reviewed minimum-capacitance waiver is an exact, profile-specific set of 256 unused `dout0[127:0]` endpoints across the two macros; it permits no missing or extra objects and is neither a setup/hold waiver nor a waiver for functional read data.

Route-tool DRC 0 validates the routed top-level implementation within the academic platform and the macro abstract views. It does not validate the transistor-level interior of the OpenRAM macro. Complete IO timing, OCV/MMMC, foundry signoff, and silicon readiness are not claimed because they are outside the available academic-PDK environment. The frequency is governed by the macro-integrated implementation and available analytical timing model; no causal 400 MHz failure claim or 400 MHz macro-profile claim is made.

## Bounded Direct-AXIS Profiles

The Direct physical top is [`mrtc_rdtc_bounded_axis_multiengine_wrapper`](../../rtl/rdtc/mrtc_rdtc_bounded_axis_multiengine_wrapper.sv). Both bindings use two Engines, four `32x128` 1RW ways per Engine, `32,768` bulk ring bits, and one small 16-beat registered output queue. They contain no DDR feeder or payload commit store.

### Register-Expanded 600 MHz

The all-register profile expands all eight way memories into standard cells and contains zero SRAM macros. Design Compiler closes the 630 MHz mapping target with retiming disabled; the mapped netlist then completes OpenROAD route and same-run OpenRCX at the fixed 600 MHz physical target. Route DRC, antenna net/pin, and unrouted counts are all zero. PrimeTime reads the matching routed netlist, SDC, and SPEF and reports setup/hold WNS `+0.03/+0.02 ns`, zero constraint violations, and `50972/50972` setup and hold coverage. Final standard-cell area is `476,320 um2`. This is a fixed academic internal closure point, not Fmax.

### Eight-Macro SRAM 300 MHz

The all-SRAM profile binds exactly eight `32x128 1RW` OpenRAM macros, four per Engine; control and the output queue remain registers. At 300 MHz, OpenROAD route completes with DRC, antenna, and unrouted counts all zero. Same-run OpenRCX and matching PrimeTime report setup/hold WNS `+0.16/+0.02 ns`, zero minimum-period, pulse-width, max-transition, and max-capacitance violations, and `18276/18276` setup and hold coverage.

The characterized WPR2 macro has a governing period of `2.656 ns` and minimum high/low pulse of `1.328 ns`. WPR1 reaches `2.500/1.250 ns`, while WPR4 is unsupported by the pinned OpenRAM generator. None satisfies the 600 MHz gates of `1.666667 ns` period and `0.833333 ns` pulse, so the SRAM 600 MHz profile is `MACRO_MODEL_BLOCKED` and is not an executable public closure configuration.

Top-level P&R and internal post-route timing are verified for the 300 MHz SRAM point. Overall macro maturity remains partial because the timing model is academic analytical characterization and transistor-level macro DRC/LVS/PEX is not closed. The physical results also do not remove the `277 > 256 cycles/block` scheduler limitation.

Evidence: [bounded Direct ASIC summary](../../evidence/rdtc_v1_bounded_direct_asic.yaml).

## Flow Contract

The stage contract is:

```text
RTL/C verification
-> profile-specific DC synthesis
-> mapped-netlist identity check
-> OpenROAD placement/CTS/route (45 nm register-expanded or SRAM profile)
-> OpenRCX SPEF
-> PrimeTime setup/hold checks
```

Each DC, P&R, and STA run records its profile, source commit, clock period, PVT, tool version, RC mode, netlist/SDC/SPEF hashes, and caveats. When synthesis and physical targets differ, DC, P&R, and STA periods are recorded separately and checked against the tool clock objects; a lower P&R frequency is not itself DC guardband.

Commercial tools, PDKs, libraries, macros, and generated views belong only in ignored `flows/local/`. The public repository provides generic wrappers, configuration contracts, stage entrypoints, bilingual documentation, and allowed evidence summaries.
