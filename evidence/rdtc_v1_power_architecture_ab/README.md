# RDTC v1 Architecture Power A/B Evidence

This directory is the sanitized, machine-validated result of the 315 MHz
Buffered (`A0`) versus Direct-AXIS (`A1`) architecture-power comparison.
The deterministic classification is `ARCH_POWER_POSITIVE` and every declared
architecture promotion gate passes.

本目录保存 315 MHz Buffered (`A0`) 与 Direct-AXIS (`A1`) 架构功耗 A/B 的脱敏、
机器可校验证据。确定性分类为 `ARCH_POWER_POSITIVE`，已声明的架构 promotion
gate 全部通过。

## Scope

- Nangate45 TT, 1.1 V, 25 C; Design Compiler `O-2018.06-SP1`.
- Two Engines, register-expanded storage, 315 MHz, retiming disabled.
- Per-point RTL SAIF applied to each mapped design with zero default toggle and
  static-probability settings.
- Same logical inputs, selected-k sequence, descriptors, always-ready policy,
  expected packets, normalized packet trace, and random seed within each pair.
- Promotion workloads are `BURST_IDLE` (32 blocks) and `ACTIVE_LEGAL` (64
  blocks). `IDLE` is not part of this promoted package.

## Headline Results

| Workload | A0 dynamic | A1 dynamic | Change | A0 energy/block | A1 energy/block | Change |
|---|---:|---:|---:|---:|---:|---:|
| BURST_IDLE | 436.4352 mW | 109.8717 mW | -74.83% | 674.82 nJ | 167.59 nJ | -75.17% |
| ACTIVE_LEGAL | 435.6544 mW | 108.9786 mW | -74.99% | 471.46 nJ | 118.58 nJ | -74.85% |

The promotion gate uses paired report-quantization bounds, not the rounded
percentages above. Its conservative BURST_IDLE saving is `74.819%`; the
conservative ACTIVE_LEGAL change is `-74.979%` against a maximum allowed
regression of `+3%`.

## Files

- `points.csv`: full-precision observations and identities.
- `comparisons.csv`: deterministic deltas and energy metrics.
- `gates.csv` and `classifications.csv`: deterministic promotion decision.
- `hierarchy_power.csv`: display-quantized hierarchy observations.
- `verification.csv` and `raw_reports.csv`: verification and raw-report hashes.
- `source_contract.json`: source, library, constraint, and tool identities.
- `input_hashes.sha256`: sanitized collection/activity archive identities
  without raw artifacts or internal run names.
- `output_hashes.sha256`: hashes for the canonical package files.

Validate from the repository root:

```text
python flows/scripts/validate_rdtc_power_2a.py \
  evidence/rdtc_v1_power_architecture_ab --require-promotion
python -m unittest flows.scripts.test_rdtc_power_2a_evidence
```

## Boundary

These values are activity-driven mapped-netlist estimates, not post-route
power, CTS clock-tree power, silicon measurement, foundry signoff, or Fmax.
Both mapped reports show `clock_mw = 0`; that value is preserved as reported
and is not reinterpreted as a physical clock-network result. No clock-gating,
P&R, PrimeTime-PX, RTL hygiene, release-tag, or production-RTL claim is made by
this package.
