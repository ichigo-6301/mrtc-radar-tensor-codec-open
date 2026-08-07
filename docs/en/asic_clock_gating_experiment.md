# Direct Mapped Clock-Gating Power A/B

[Chinese](../zh-CN/asic_clock_gating_experiment.md) · [Stage 1 architecture-power study](asic_power_experiment.md) · [Results](results.md)

## Decision

This Stage-2 study compares the Direct-AXIS mapped implementation without
automatic clock gating (`G0`) against the same Direct-AXIS design with
automatic clock gating (`G1`). It is classified
`MRTC_CLOCK_GATING_MAPPED_POSITIVE_PRIVATE` by the private authority. The
public package reproduces the decision deterministically from sanitized
machine-readable evidence.

<p align="center">
  <a href="../../evidence/rdtc_v1_clock_gating_mapped_dc/README.md"><img src="../assets/rdtc_stage2_clock_gating_power.svg" width="1000" alt="Stage-2 Direct G0 versus G1 automatic clock-gating mapped-power comparison"></a>
</p>

This coordinated figure is the Stage-2 overview; the complete coverage
denominators, equivalence, activity, audit caveats, and maturity boundaries
remain below.

The two power studies answer different questions:

| Stage | Baseline | Candidate | Controlled variable |
|---|---|---|---|
| Stage 1 | Buffered | Direct-AXIS | wrapper architecture and storage responsibility |
| Stage 2 | Direct G0 | Direct G1 | Design Compiler automatic clock gating |

Stage-2 percentages are relative to Direct G0 only. They must not be added to
the Stage-1 percentages or presented as one combined saving.

## Fixed Contract

Both points use `mrtc_rdtc_bounded_axis_multiengine_wrapper`, two Engines, the
register-expanded Direct-AXIS profile, Nangate45 TT / 1.1 V / 25 C, 315 MHz
(`3.174603 ns`), and disabled retiming. G0 has clock gating disabled. G1 uses
272 `CLKGATETST_X1` cells with functional `test_enable=0`.

| Implementation metric | G0 ungated | G1 clock-gated | Candidate minus baseline |
|---|---:|---:|---:|
| Cell area | 420,208.442440 um2 | 354,760.204745 um2 | -15.58% |
| Setup WNS | +0.093015 ns | +0.0151572 ns | both closed |
| Setup TNS | 0 ns | 0 ns | unchanged |
| Electrical violations | 0 | 0 | unchanged |
| ICG count | 0 | 272 | `CLKGATETST_X1` only |
| Gating setup / hold WNS | N/A | +1.4645 / +0.18546 ns | both closed |

The negative area change is the mapped result of this controlled synthesis
pair; it is not generalized into a rule that clock gating reduces area.

## Coverage Denominators

The evidence keeps register bits and mapped sequential cells distinct:

| Quantity | Value | Meaning |
|---|---:|---|
| Gated bits | 34,816 | actual G1 gated register bits |
| Post-map sequential bits | 50,988 | G1 `all_registers` bit denominator; 68.28273319212363693418059151% gated |
| Precompile register bits | 55,929 | common-checkpoint bit denominator; 62.2503531262851114806272238% gated |
| Mapped sequential cells | G0 50,999 / G1 51,271 | `report_area` cell counts, not bit denominators |
| Ring data bits | 32,768 / 32,768 | 100% Ring data coverage |

No bare state-coverage percentage is used without its denominator.

## Workloads

- `IDLE`: 4,096 measured cycles, no descriptor or input traffic, zero
  completed blocks, and a continuously running clock.
- `BURST_IDLE`: 32 completed blocks in four groups of eight; each group is
  drained and followed by 1,024 idle cycles. Fixed P0/P1 vectors alternate and
  output `TREADY` remains high.
- `ACTIVE_LEGAL`: 64 completed blocks with alternating P0/P1 vectors and a
  320-cycle block-start interval, without an artificial long idle gap;
  output `TREADY` remains high.

P0 is an all-zero block with selected `k=0` and 20 packet beats. P1 is a fixed
bounded non-zero pattern with selected `k=2` and 72 packet beats.
`ACTIVE_LEGAL` is a high-duty legal compression workload. It is not 100%
compressed-output `TVALID` duty, zero-gap sustained input, maximum throughput,
or Fmax.

## Activity Method

```text
G0/G1 mapped netlist
        |
        v
Questa zero-delay mapped gate simulation
        |
        v
workload-gated VCD measurement window
        |
        v
clip and rebase VCD -> vcd2saif
        |
        v
Design Compiler / Power Compiler
read DDC + mapped SDC + SAIF
        |
        v
coverage checks -> report_power
```

All six points use `mapped_zero_delay`, `RACE_FREE_DRIVE`, functional SE=0,
independent activity artifacts, and default toggle/static probability 0.0.
Clock, functional-input, sequential-output, internal-leaf-pin, and overall
non-default Activity Annotation Coverage are each 100%.
Activity Annotation Coverage is not verification test coverage and does not imply code,
functional, assertion, toggle, or fault coverage closure.

## Functional Evidence And ICG Model

The accepted result is **gate-level regression equivalence evidence**, not a
Formality result. G0 and G1 are bit-exact for the minimal two-block case, the
32-block `BURST_IDLE` case, and the 64-block `ACTIVE_LEGAL` case, including
packet data, selected k, TLAST/TUSER, decoder output, status, count, and order.

The exact `CLKGATETST_X1` functional model resolves once, with no duplicate or
shadow definition. Its `CK/E/SE/GCK` pins and polarity match the audited
library, and canary cases A-F pass. The model contains no timing checks, so
that capability is recorded as `NOT_SUPPORTED_BY_MODEL`, not PASS.

The historical GLS mismatch was caused by an unresolved test-enable bind:
the top test port and 272 ICG `SE` pins were Z/X. A named
`.power_test_en(CG_TEST_ENABLE)` connection held at 0 restored functional
equivalence without changing production RTL. The SE=1 bypass run remains a
diagnostic and had one output mismatch; it is not DFT/scan evidence and is
never used for power.

## Results

| Workload / metric | G0 | G1 | Candidate minus baseline |
|---|---:|---:|---:|
| IDLE dynamic | 66.9676 mW | 27.7229 mW | -58.60% |
| IDLE total | 75.507 mW | 34.826 mW | -53.88% |
| BURST_IDLE dynamic | 107.3535 mW | 41.1522 mW | -61.67% |
| BURST_IDLE total | 115.4 mW | 47.942 mW | -58.46% |
| BURST_IDLE energy/block | 164.5480357 nJ | 68.3601554 nJ | -58.46% |
| ACTIVE_LEGAL dynamic | 107.2775 mW | 43.4293 mW | -59.52% |
| ACTIVE_LEGAL total | 115.3 mW | 50.209 mW | -56.45% |

For `BURST_IDLE`, sequential power changes by -61.41%, internal power by
-63.10%, switching power by -11.80%, and leakage by -15.53%. Exact decimal
authority remains in `points.csv` and `comparisons.csv`; this page rounds only
for presentation.

All promotion gates pass: equivalence, activity coverage, 34,816 gated bits,
68.28% post-map gated-bit coverage, 100% Ring coverage, BURST dynamic,
sequential/internal and energy reductions, ACTIVE dynamic non-regression,
area, setup, electrical, and clock-gating setup/hold checks.

## Audit Caveats

The exported mapped SDC emitted 8,136 paired vector-replay errors. The result
is accepted under
`MAPPED_SDC_VECTOR_REPLAY_ERRORS_DDC_CONSTRAINTS_PRESERVED` because the loaded
DDC retained constraints and the mapped-SDC hash, clock/period/corner,
WNS/TNS, zero electrical violations, and `check_timing` all matched. This does
not establish a portable mapped-SDC handoff.

The six reports were completed successfully. An outer exit code 2 came from a
legacy parser matching an echoed Tcl marker; the corrected parser re-read the
immutable reports only. No EDA tool was rerun, all six points were recovered,
and process ownership ended `FULL_RELEASED`.

## Maturity And Boundaries

This is an activity-driven mapped-netlist estimate. It does not claim routed
power, CTS clock-tree power, PrimeTime-PX analysis, silicon measurement,
foundry signoff, DFT/scan closure, Fmax, or workload-independent savings.
Mapped `clock_mw` values are retained as tool outputs and are not interpreted
as physical clock-tree power.

Machine-readable authority and deterministic validation are in
[the Stage-2 evidence package](../../evidence/rdtc_v1_clock_gating_mapped_dc/README.md).
