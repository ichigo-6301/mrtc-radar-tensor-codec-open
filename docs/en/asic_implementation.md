# ASIC Implementation

Public ASIC content is organized as two independent profiles: `register-expanded` and `sram-macro`. Both share the RDTC v1 RTL, interfaces, AXI behavior, register map, and bitstream. Only the physical binding of the prefix buffer differs.

## Register-expanded

`register-expanded` binds no SRAM leaf; prefix buffers are implemented as standard-cell registers, so the SRAM macro count is zero. The primary public results use the NanGate15 and Nangate45 DC matrices; Nangate45 adds a 700 MHz point. NanGate15 Liberty uses a 1 ps time unit, so the flow applies `SDC_TIME_SCALE=1000.0`. Since 45 nm closes at 700 MHz but not at 800 MHz, the 700 MHz mapped netlist is selected for the latest physical handoff.

The public 45 nm physical profile uses OpenROAD/OpenRCX and PrimeTime. It imports the 700 MHz DC netlist, reapplies a 550 MHz P&R/STA constraint, and completes placement, CTS, route, and SPEF generation. Route DRC and antenna net/pin counts are zero; PrimeTime setup/hold WNS is +0.26/+0.04 ns with 100% setup/hold coverage. A total of 1,756 asynchronous-reset pins remain outside max-delay coverage. This is internal reg-to-reg academic timing, not complete IO, reset recovery/removal, OCV/MMMC, or foundry signoff.

## SRAM-macro

`sram-macro` instantiates two `64x128 1RW1R` OpenRAM macros, one per engine, while the wrapper preserves the one-cycle read latency, existing AXI protocol, and address behavior. The fixed verified closure point is 333 MHz: chip-level OpenROAD P&R completed, route DRC and antenna net/pin counts are 0/0, the same run produced the routed handoff and OpenRCX SPEF, and PrimeTime read the matching netlist, SDC, and SPEF. Setup/hold WNS/TNS is +0.57/+0.04 ns and 0/0, with zero constraint violations.

### Result maturity interpretation

The chip-level implementation chain and measured internal post-route timing are verified results. The overall profile remains `partial` only because the macro timing model is analytically characterized and macro-level DRC/LVS/PEX is not closed. The reviewed minimum-capacitance waiver is an exact, profile-specific set of 256 unused `dout0[127:0]` endpoints across the two macros; it permits no missing or extra objects and is neither a setup/hold waiver nor a waiver for functional read data.

Route-tool DRC 0 validates the routed top-level implementation within the academic platform and the macro abstract views. It does not validate the transistor-level interior of the OpenRAM macro, and its absence does not make the completed chip-level P&R partial. Complete IO timing, OCV/MMMC, foundry signoff, and silicon readiness are not claimed. The frequency is governed by the macro-integrated implementation and available analytical timing model; no causal 400 MHz failure claim or 400 MHz macro-profile claim is made.

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
