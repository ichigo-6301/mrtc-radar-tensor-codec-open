# ASIC Implementation

Public ASIC content is organized as two independent profiles: `register-expanded` and `sram-macro`. Both share the RDTC v1 RTL, interfaces, AXI behavior, register map, and bitstream. Only the physical binding of the prefix buffer differs.

## Register-expanded

`register-expanded` binds no SRAM leaf; prefix buffers are implemented as standard-cell registers, so the SRAM macro count is zero. NanGate15, Nangate45, and ICsprout55 use 400/600/800 MHz DC matrices with 100 ps setup uncertainty and an internal single-clock constraint; Nangate45 adds a 700 MHz point. NanGate15 Liberty uses a 1 ps time unit, so the flow applies `SDC_TIME_SCALE=1000.0`. Since 45 nm closes at 700 MHz but not at 800 MHz, the 700 MHz mapped netlist is selected for the latest physical handoff.

The public 45 nm physical profile uses OpenROAD/OpenRCX and PrimeTime. It imports the 700 MHz DC netlist, reapplies a 550 MHz P&R/STA constraint, and completes placement, CTS, route, and SPEF generation. Route DRC and antenna net/pin counts are zero; PrimeTime setup/hold WNS is +0.26/+0.04 ns with 100% setup/hold coverage. A total of 1,756 asynchronous-reset pins remain outside max-delay coverage. This is internal reg-to-reg academic timing, not complete IO, reset recovery/removal, OCV/MMMC, or foundry signoff.

DC-only comparisons are published for both 15 nm and 55 nm. The 55 nm profile uses ICsprout55 public-preview `v1.10.100` H7CR RVT at TT/1.2 V/25 C: setup closes at 400/600/800 MHz, and 800 MHz is the highest executed constraint-clean setup-closed point. The 600 MHz point remains `partial` because two max-transition nets and three max-capacitance nets violate their limits. Removing SRAM does not provide matching parasitic technology, and DC closure does not imply P&R closure, so this DC claim makes no 55 nm post-route Fmax claim.

An ECOS/ICS55 full-RDTC 400 MHz attempt demonstrates that platform-canary success is not sufficient for the product top. Floorplan, placement, CTS, and legalization completed, but default detailed routing was stopped for a resource-protection boundary before it completed. No routed handoff or post-route STA exists, and the attempt is not an implementation profile. The precise conditions are recorded in [ICS55 ECOS Implementation Attempt](ics55_ecos_implementation.md).

## SRAM-macro

`sram-macro` instantiates two `64x128 1RW1R` OpenRAM macros, one per engine, while the wrapper preserves the one-cycle read latency, existing AXI protocol, and address behavior. The fixed public result is approximately 333 MHz: the same OpenROAD/OpenRCX run produces route, SPEF, and the handoff, and PrimeTime reads the matching netlist, SDC, and SPEF. Setup/hold WNS is +0.57/+0.04 ns.

The overall profile remains `partial` because the macro uses analytical characterization, retains a minimum-capacitance waiver for 256 unused `dout0` endpoints, and lacks macro DRC/LVS/PEX, complete IO timing, OCV/MMMC, and foundry signoff. The SRAM result must not be extended to 400 MHz or compared directly with register-expanded area without stating the capacity and physical-model differences.

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
