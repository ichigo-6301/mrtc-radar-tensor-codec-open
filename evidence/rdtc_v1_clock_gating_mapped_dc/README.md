# Direct G0/G1 Mapped Clock-Gating Power Evidence

This sanitized package records the independent Stage-2 comparison from the
Direct ungated mapped implementation to the Direct automatically clock-gated
mapped implementation at 315 MHz. Stage 1 remains the separate Buffered to
Direct architecture study.

The six points use zero-delay mapped gate simulation, race-free stimulus,
functional test-enable 0, and one distinct activity artifact per point. All
five Activity Annotation Coverage categories are 100%. Activity Annotation
Coverage is not verification test coverage and does not imply code,
functional, assertion, toggle, or fault coverage closure.

G1 contains 272 `CLKGATETST_X1` cells and gates 34,816 bits, including all
32,768 Ring data bits. BURST_IDLE dynamic power changes from 107.3535 to
41.1522 mW (-61.67%); energy per block changes from 164.5480 to 68.3602 nJ
(-58.46%). ACTIVE_LEGAL dynamic power changes by -59.52%. Mapped cell area
changes by -15.58%.

Equivalence is gate-level regression equivalence evidence for the minimal
two-block, 32-block BURST_IDLE, and 64-block ACTIVE_LEGAL workloads. It is not
a formal result. The historical mismatch came from an unresolved test-enable
connection in the old simulation harness; explicit named connection at the
functional value restored bit-exact equivalence without production RTL change.

The result is an activity-driven mapped-netlist estimate. It is not routed
power, physical clock-tree power, measured silicon power, DFT closure,
maximum-frequency evidence, or a universal workload-independent result. The
exported mapped-constraint replay caveat and parser-only recovery are retained
in `source_contract.json` and `parser_recovery.json`.

Validate with:

```text
python flows/scripts/rdtc_clock_gating_power_evidence.py validate --root .
python flows/scripts/rdtc_clock_gating_power_evidence.py validate-doc-values --root .
```
