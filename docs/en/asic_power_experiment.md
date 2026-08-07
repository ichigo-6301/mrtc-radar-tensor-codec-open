# Activity-Driven Architecture Power A/B

[Chinese](../zh-CN/asic_power_experiment.md) · [Stage 2 mapped clock-gating study](asic_clock_gating_experiment.md) · [Results](results.md)

This page is the Stage-1 `Buffered -> Direct-AXIS` architecture study. Stage 2
uses Direct G0 as its own baseline and is reported separately.

<p align="center">
  <a href="../../evidence/rdtc_v1_power_architecture_ab/README.md"><img src="../assets/rdtc_stage1_architecture_ppa_power.svg" width="1000" alt="Stage-1 Buffered versus Direct-AXIS architecture PPA and mapped-power comparison"></a>
</p>

This coordinated figure is the Stage-1 overview; the complete workload,
coverage, hierarchy-power, and maturity boundaries remain below.

## Decision

The reviewed 315 MHz Buffered-to-Direct comparison is classified
`ARCH_POWER_POSITIVE`. Functional normalization, activity coverage,
source/library/constraint identity, timing, electrical checks, and both power
promotion criteria pass. The experiment changes no production RTL.

Clock-gating synthesis is a separate experiment. Its later mapped result does
not alter this Stage-1 baseline or authorize adding the two percentages. No
ICG, routed-power, or PrimeTime-PX claim follows from this architecture
comparison itself.

## Fixed Comparison

| Item | A0 Buffered | A1 Direct-AXIS |
|---|---|---|
| Top | `mrtc_rdtc_ddr_multiengine_wrapper` | `mrtc_rdtc_bounded_axis_multiengine_wrapper` |
| Profile | buffered register-expanded | direct register-expanded |
| Engines | 2 | 2 |
| Frequency | 315 MHz | 315 MHz |
| Library/corner | Nangate45 TT, 1.1 V, 25 C | same |
| Tool | Design Compiler `O-2018.06-SP1` | same |
| Activity method | RTL SAIF applied to mapped design | same tier, independent SAIF |
| Default activity | toggle `0.0`, static probability `0.0` | same |
| Retiming | disabled | disabled |

Within each workload pair, the logical input words, selected-k sequence,
descriptor sequence, always-ready policy, expected packet beats, normalized
packet trace, block count, raw-byte count, compressed-byte count, and random
seed are hash-identical. Each structurally different mapped point has its own
activity artifact.

## Workloads And Coverage

| Workload | Blocks | Raw bytes | Compressed bytes | A0/A1 measured cycles |
|---|---:|---:|---:|---:|
| BURST_IDLE | 32 | 131,072 | 23,536 | 14,701 / 14,373 |
| ACTIVE_LEGAL | 64 | 262,144 | 47,072 | 20,575 / 20,493 |

Both workloads keep output ready asserted. Energy uses each point's exact
measured cycle window and completed block count. `IDLE` remains diagnostic-only
and is excluded from architecture promotion.

Coverage is invariant across the two workloads for each architecture:

| Architecture | Clock | Functional inputs | Sequential outputs | Internal leaf pins | Overall non-default |
|---|---:|---:|---:|---:|---:|
| A0 Buffered | 100% | 100% | 99.964% | 99.642% | 99.662% |
| A1 Direct | 100% | 100% | 99.617% | 98.807% | 98.856% |

No nonzero default toggle rate was used to manufacture coverage.

## Results

| Metric | A0 Buffered | A1 Direct | Candidate minus baseline |
|---|---:|---:|---:|
| Cell area | 1,529,495.20 um2 | 420,208.44 um2 | -72.53% |
| Cell count | 786,342 | 220,298 | -71.98% |
| Sequential cells | 200,572 | 50,999 | -74.57% |
| BURST_IDLE dynamic power | 436.4352 mW | 109.8717 mW | -74.83% |
| BURST_IDLE total power | 462.70 mW | 117.53 mW | -74.60% |
| BURST_IDLE energy/block | 674.82 nJ | 167.59 nJ | -75.17% |
| ACTIVE_LEGAL dynamic power | 435.6544 mW | 108.9786 mW | -74.99% |
| ACTIVE_LEGAL total power | 461.95 mW | 116.65 mW | -74.75% |
| ACTIVE_LEGAL energy/block | 471.46 nJ | 118.58 nJ | -74.85% |

The deterministic gate is stricter than the displayed deltas: it evaluates
baseline minus its report-quantization bound against candidate plus its bound.
The conservative BURST_IDLE dynamic saving is `74.819%`, above the `10%`
threshold. The conservative ACTIVE_LEGAL dynamic change is `-74.979%`, within
the allowed maximum regression of `+3%`.

## Hierarchy Reading

For BURST_IDLE, the Buffered hierarchy reports about `463 mW` at the root,
about `156 mW` for each of the two packet-buffer hierarchies, and about
`20.4/20.0 mW` for the two feeder hierarchies. Its two codec Engines are about
`54.6 mW` each. Direct reports about `117 mW` at the root, about `55.7 mW` per
Engine, and about `4.79 mW` for the shared output FIFO.

This supports a storage/data-movement interpretation: the codec Engines remain
in the same power range while the Buffered feeder and payload-commit storage
hierarchies disappear. Hierarchy rows can be nested and are display-quantized;
they must not be summed as disjoint buckets.

## Maturity And Nonclaims

The result is an **activity-driven mapped-netlist power estimate**. It is not:

- post-route or PrimeTime-PX power;
- CTS clock-tree power;
- measured silicon or foundry-signoff power;
- a maximum-frequency result;
- a universal saving across untested traffic patterns;
- automatic clock-gating evidence within this Stage-1 package.

Both mapped reports contain `clock_mw = 0`. The evidence preserves the
zero-to-zero comparison as zero delta, but does not reinterpret it as a
physical clock-network measurement.

Machine-readable evidence and validation commands are in
[the architecture-power package](../../evidence/rdtc_v1_power_architecture_ab/README.md).

Continue to the independent
[Direct G0/G1 mapped clock-gating study](asic_clock_gating_experiment.md).
