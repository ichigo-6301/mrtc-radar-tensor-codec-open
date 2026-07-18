# TSMC90 prefix memory contract

The RDTC prefix buffer has a fixed `64 x 128` logical contract and one-cycle
read latency. Two local-only memory variants preserve that contract:

- `rf64x128` uses an exact `64 x 128` `RF_2P_ADV` two-port register-file
  macro. Port A reads and port B writes.
- `sram128x128` uses a `128 x 128`, mux-4 `SRAM_DP_ADV` true dual-port SRAM.
  Port A reads, port B writes, and both address MSBs are tied low so RDTC uses
  only rows 0 through 63.

The second variant is intentionally overprovisioned and must be labelled as
such in profile and evidence metadata. Neither variant changes the external
RTL, AXI, bitstream, register, one-cycle-read, or same-address collision
contract. Generated technology models remain outside the RTL product boundary.

The generated behavioral Verilog is for simulation only. DC analyzes the
tracked adapter and resolves the leaf macro from the compiled Liberty DB.

Both generators can create Verilog, four Synopsys Liberty corners, VCLEF, and
antenna CLF in the audited installation. Their `gds2` and `lvs` subcommands
report unavailable, so the VCLEF has no audited same-source GDS/LVS closure.
Library Compiler and PrimeTime library-read smoke may be verified, but the
physical view remains `partial`.

The legacy Astro technology file supplies geometry for ICC2 Library Manager
and floorplanning, but ICC2 O-2018.06 ignores its `CapTable/CapModel` sections.
Without matching TLUPlus and a layer map, `make pnr-full` stops at RC preflight
with `blocked_missing_parasitic_tech`; place, CTS, route, SPEF, and post-route
PrimeTime STA are not claimed.
