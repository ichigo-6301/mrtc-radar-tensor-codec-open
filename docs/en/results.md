# Verified Results

## Functional Verification

| Result | Profile | Status | Caveat |
|---|---|---|---|
| MATLAB/C/DPI-C/RTL legal-vector bit-exact agreement | RDTC v1 public release | verified | Finite vector and regression set; not exhaustive formal proof. |
| Dual-AXIS128 wrapper VCS regression, 10 required cases | RDTC v1 public release | verified | Finite wrapper regression; not coverage closure. |

## Implementation Profile Matrix

All frequency results apply only to the internal single-clock reg-to-reg constraint of `mrtc_rdtc_wb_wrapper`, with 100 ps setup uncertainty and without complete top-level IO timing.

| Memory Profile | Technology | Scope | Result | Status |
|---|---|---|---|---|
| `register-expanded` | NanGate15 TT/0.8 V/25 C | DC-only | 400/600/800 MHz close; 800 MHz WNS +0.22945 ns and cell area 99,064.13 um2 | verified |
| `register-expanded` | Nangate45 TT/1.1 V/25 C | DC matrix | 400/600/700 MHz close; 700 MHz WNS/TNS is 0.00/0.00 ns; 800 MHz WNS/TNS is -0.14/-858.86 ns | verified |
| `register-expanded` | Nangate45/OpenROAD/OpenRCX | P&R + PT at 400 MHz | Route DRC 0, antenna net/pin 0/0, area 418,007 um2, utilization 31.2108%; PT setup/hold WNS +0.80/+0.04 ns with zero constraint violations | verified |
| `register-expanded` | Nangate45/OpenROAD/OpenRCX | P&R + PT at 550 MHz | Uses the 700 MHz DC mapped netlist; route DRC 0, antenna net/pin 0/0, area 421,120 um2, utilization 31.4432%; PT setup/hold WNS +0.26/+0.04 ns with zero constraint violations | verified |
| `register-expanded` | ICsprout55 | DC-only | Results remain in the private delivery; no metric is published until authorization is confirmed | private/not_claimed |
| `sram-macro` | Nangate45/OpenRAM/OpenROAD/OpenRCX | 2 x `64x128 1RW1R`; P&R + PT at 333 MHz | Route and same-run SPEF complete; PT setup/hold WNS +0.57/+0.04 ns with zero constraint violations | partial |

The NanGate15 Liberty uses a `1ps` time unit, so its DC profile explicitly applies `SDC_TIME_SCALE=1000.0`. The latest 45 nm register-expanded physical run uses the setup-closed 700 MHz DC netlist at a 550 MHz implementation target. Evidence records matching SHA256 values for the handoff netlist, SDC, and SPEF. PrimeTime setup/hold coverage is 100%; 1,756 unconstrained max-delay endpoints are asynchronous reset pins under the internal-only profile.

The 333 MHz SRAM-macro result retains OpenRAM analytical-characterization caveats, a minimum-capacitance waiver for 256 unused `dout0` endpoints, and incomplete macro DRC/LVS/PEX. It must not be extended to a 400 MHz claim or compared directly with register-expanded area without accounting for the SRAM area model.

## Interpretation

- A `DC timing estimate` covers internal timing under the selected Liberty, ideal clock, and synthesis constraints only;
- `internal reg-to-reg post-route timing` uses a routed netlist, matching SDC, and same-run SPEF, but does not cover unmodelled system IO;
- Neither `top-level IO timing closure` nor `foundry signoff` is claimed.

Public evidence is under `evidence/`, with run conditions and boundaries under `provenance/`. PDKs, Liberty/DB, LEF/GDS, SPEF, and raw EDA work directories are not distributed.
