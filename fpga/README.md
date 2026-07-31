# FPGA Integration

The public RDTC v1 sources include synthesizable codec, AXI-Stream, AXI4-Lite,
and top-level control RTL. The `rdtc_ooc_constraints.xdc` file is a starting
constraint template for an out-of-context codec build.

An FPGA integration must provide its own clock/reset infrastructure, board IO,
and any vendor-generated IP. Those generated artifacts are intentionally not
part of this repository. Keep the RDTC AXI-Stream block boundary and AXI4-Lite
register behavior consistent with the interface documentation.

## Bounded Direct-AXIS OOC Target

The opt-in Direct wrapper uses
`mrtc_rdtc_bounded_axis_multiengine_wrapper` and
`flows/manifests/rdtc_v1_bounded_direct.f`. Its public Vivado 2022.2 target is
an out-of-context post-route check on `xc7z100ffg900-2` at the fixed 200 MHz
point:

```text
make bounded-direct-vivado-route200
make bounded-direct-vivado-route200-check
```

The runner uses the tracked Python, Tcl, and XDC entrypoints; no generated
project, DCP, bitstream, or private batch runner is part of the source identity.
The recorded result is `+0.001/+0.062 ns` setup/hold WNS with
`32,672 LUT / 18,519 FF / 0 BRAM` and exactly `1024 x RAM32X1S` across eight
ways. This is an internal OOC fixed closure point, not Fmax, board IO timing,
bitstream, board execution, or sustained zero-stall evidence.
