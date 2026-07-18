# FPGA Integration

The public RDTC v1 sources include synthesizable codec, AXI-Stream, AXI4-Lite,
and top-level control RTL. The `rdtc_ooc_constraints.xdc` file is a starting
constraint template for an out-of-context codec build.

An FPGA integration must provide its own clock/reset infrastructure, board IO,
and any vendor-generated IP. Those generated artifacts are intentionally not
part of this repository. Keep the RDTC AXI-Stream block boundary and AXI4-Lite
register behavior consistent with the interface documentation.
