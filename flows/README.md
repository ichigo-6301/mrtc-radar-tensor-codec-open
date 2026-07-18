# Implementation Flow

This directory provides public-safe entrypoints for the RDTC v1 implementation
flow. It contains scripts and configuration contracts, not EDA tools, PDKs,
standard-cell libraries, SRAM macros, generated FPGA IP, implementation
databases, or raw reports.

## Configuration

The top-level `Makefile` uses `Kconfig` for profile and stage selection.

```text
make rdtc_v1_45nm_defconfig
make rdtc_v1_tsmc90_rf64x128_partial_defconfig
make rdtc_v1_tsmc90_sram128x128_partial_defconfig
make menuconfig
make showconfig
make rtl-smoke
make sim
```

`make menuconfig` requires an `mconf`-compatible Kconfig frontend. On Linux,
install kconfig-frontends/mconf or Kconfiglib's `menuconfig` command and set
`KCONFIG_MCONF` when its executable has another name. WSL or MSYS2 is the
recommended Windows environment. The non-interactive `defconfig` target works
with GNU Make and Python 3.6 or newer.

Copy `flows/config/toolchain.mk.example` to `flows/local/toolchain.mk`, then
copy and complete the required local setup templates under `flows/config/`.
`flows/local/` and `.config` are ignored deliberately. They may contain local
tool, PDK, Liberty, SRAM, LEF, GDS, MMMC, SPEF, and license-related paths and
must never be committed.

OpenROAD runs in a digest-pinned ORFS container using the Nangate45 platform.
The exact ORFS Liberty must also be compiled to DB for Design Compiler and
PrimeTime; a similarly named Nangate library from another source is not an
equivalent timing view. Generated macros and physical outputs stay ignored.

## Stage Entry Points

```text
make sim[-dry-run]           Bounded Questa/ModelSim RTL regression
make sim-full                Extended bitpacker and loopback matrix
make sram-prep[-dry-run]     OpenRAM generation, view audit, and LC DB build
make rc-itf                   Derive an academic FreePDK45 ITF without StarRC
make rc-prep[-dry-run]        Derive ITF and generate TLUPlus with grdgenxo
make lint[-dry-run]          SpyGlass RTL lint
make cdc[-dry-run]           SpyGlass CDC/RDC
make dc-baseline[-dry-run]   Baseline Design Compiler synthesis
make dc-gated[-dry-run]      Clock-gated Design Compiler synthesis
make dft[-dry-run]           Scan insertion
make lec[-dry-run]           Formal equivalence check
make icc2-libs[-dry-run]     ICC2 Library Manager reference NDM
make pnr[-dry-run]           Selected OpenROAD or ICC2 physical backend
make pnr-floorplan           ICC2 import, macro placement, and PG diagnostic
make pnr-full                ICC2 full flow with mandatory RC preflight
make sta[-dry-run]           PrimeTime post-layout STA
```

`*-dry-run` prints the exact tool invocation without calling a commercial tool.
Normal targets fail closed when a local setup is missing or a stage is disabled
in `.config`. The physical candidate defconfig enables the SRAM-aware
pre-DFT path through OpenROAD/OpenRCX and PrimeTime. Clock gating, DFT, and LEC remain
disabled until their independent profiles are implemented.

SpyGlass may return process status zero even when rule checking reports errors.
The public runner therefore reads the generated `spyglass.log` and returns a
non-zero make status whenever fatal or error messages remain.

`make rtl-smoke` uses Icarus Verilog to elaborate the configured top from the
public source manifest. It is an open-source portability check, not a
replacement for RTL regression, lint, synthesis, or implementation evidence.

`make sim` runs dependency-closed prefix-buffer, bitpacker, and small-buffer loopback smoke
tests with Questa/ModelSim. `make sim-full` expands the Rice-parameter, codec,
fallback, and backpressure matrix. All simulator outputs stay under
`build/rtl_sim/`.

For OpenRAM profiles, `make sram-prep` generates one `64x128` 1R1W macro,
audits its Verilog/Liberty/LEF interface and timing tables, compiles Liberty to
DB with Synopsys Library Compiler, and writes SHA256 metadata under `build/`. The
OpenROAD adapter normalizes OpenRAM pin geometry to the Nangate45 manufacturing
grid in an ignored derived LEF, connects lowercase macro supply pins to VDD/VSS,
and exports the final ORFS netlist, SDC, and OpenRCX SPEF. No generated view is published.

The TSMC90 partial defconfigs select ICC2 plus one local legacy vendor-PDK
memory adapter. `rf64x128` is an exact two-port register-file organization;
`sram128x128` is an overprovisioned true dual-port SRAM whose upper address bit
is tied low. Behavioral Verilog is used only by simulation, while DC resolves
the selected leaf from the compiled Liberty DB. The ICC2 floorplan placer
selects horizontal or vertical symmetric placement from the actual macro
dimensions and fails on overlap, insufficient spacing, or core escape.
`make pnr-floorplan` remains valid when the technology file provides geometry
but no ICC2-readable TLUPlus. `make pnr-full` fails at RC preflight until exactly
one audited parasitic technology exists; PrimeTime post-route STA also requires
a matching netlist/SDC/SPEF handoff.

`make rc-itf` parses locally installed FreePDK45 v1.4 Calibre xRC,
design-rule, and Cadence technology files under their respective licenses and writes an academic ITF, layer
map, source hashes, and caveats to `RDTC_RC_OUTPUT_DIR`. `make rc-prep` then
invokes licensed Synopsys StarRC `grdgenxo` to create TLUPlus. These generated
technology assets remain outside Git. The model is suitable for academic
implementation analysis only and is not foundry-calibrated extraction data.

The intended IP workflow is MATLAB algorithm evaluation, C bit-exact reference
model, RTL verification, FPGA implementation/integration validation, and ASIC
implementation. A script or an enabled Kconfig symbol is not implementation
evidence; results become public claims only after profile-specific verification
and evidence review.

## Timing Audit

`make timing-audit` parses existing DC, OpenROAD, and PrimeTime artifacts. It
does not invoke synthesis, placement, routing, extraction, or STA. Configure
the local `RDTC_AUDIT_*` paths in `flows/local/toolchain.mk`; output is written
under the selected build root as `timing_audit/audit.json` and `audit.md`.

The audit checks clock and uncertainty propagation, mapped-netlist hashes,
library report equivalence, critical-path classes, IO constraint coverage,
SRAM-model warnings, CTS buffers, hold margins, and timing-repair buffer growth.
Audit output is diagnostic evidence and does not upgrade a public timing claim.
