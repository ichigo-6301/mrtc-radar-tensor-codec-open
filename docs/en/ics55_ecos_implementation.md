# ICS55 ECOS Implementation Attempt

## Scope

This page records the current physical-implementation boundary for the register-expanded RDTC wrapper. It is separate from the verified ICS55 Design Compiler profile and does not add a physical-performance claim.

| Item | Result |
|---|---|
| PDK | ICsprout55 public-preview `v1.10.100`, commit `e696e093129ca2212487aa169af74d06ebd86eb6` |
| Library | `ics55_LLSC_H7C_V1p10C100`, H7CR RVT, TT/1.2 V/25 C |
| Design | `mrtc_rdtc_wb_wrapper`, register-expanded, zero memory macros |
| DC handoff | 400 MHz mapped netlist and matching 2.500 ns SDC |
| Physical tool | ECOS Studio / iEDA stack, `0.1.0-alpha.5` |
| Route target | 400 MHz |
| Full-design status | not completed |

## Completed Stages

The full RDTC run completed floorplan, fanout repair, placement, CTS, and legalization. The physical die was 1145.211 by 1145.211 um at approximately 42% core utilization. Placement contained 207,829 instances and CTS served 38,574 sinks with a 0.080 ns target skew.

The memory-free platform canary completed synthesis through routed DEF/GDS and reported zero route-tool DRC violations. That result establishes only the selected platform capability; it is not RDTC product physical evidence.

## Route Attempt

The full 400 MHz route reached topology, layer assignment, and the first detailed-routing iteration. The default detailed router was intentionally left at its configured nine iterations. The route did not complete:

- final SpaceRouter resource overflow after its three configured iterations: 65,239;
- TrackAssigner initial route-tool violations: 136,290;
- DetailedRouter reached 529 of 4,761 boxes in 18:51 with 252,151 violations;
- DetailedRouter reached 1,058 of 4,761 boxes in a further 20:38 with 347,130 violations;
- the third box group was still active while RSS increased and available memory fell below 256 MiB.

The run was stopped with `SIGTERM` before an OOM-killer event. This is a resource-protection stop, not a successful route or an abbreviated pass. No routed DEF, routed GDS, routed netlist, route-stage SDC, SPEF, or SDF was produced.

## Timing Status

ECOS built-in ICS55 RC was identified as `ECOS_BUILTIN_RC`; it is not described as PDK-calibrated or foundry signoff RC. Because the route did not complete and no same-run routed netlist/SDC/SPEF exists, RCX, native route timing, OpenSTA, and PrimeTime post-route analysis were not run. No ICS55 post-route frequency or WNS/TNS claim is made.

## Interpretation

The public result remains a verified DC-only ICS55 profile. The full-design ECOS attempt is an incomplete engineering observation, not an implementation profile or evidence-backed physical claim. It does not alter the verified Nangate45 physical results.

The next physical experiment requires an explicitly reviewed change to the route problem, such as a floorplan, utilization, placement-density, or routing-resource study, followed by a new independently identified run. A faster or shorter detailed-router setting must not be substituted for the default run above.

