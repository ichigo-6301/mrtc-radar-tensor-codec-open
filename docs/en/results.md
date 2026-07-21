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
| `register-expanded` | ICS55 H7CR RVT TT/1.2 V/25 C | DC-only | 400/600/800 MHz setup closes; 800 MHz WNS/TNS is 0.00/0.00 ns with 566,341.71 um2 cell area; 600 MHz retains 2/3 transition/capacitance violations | verified (800 MHz) / partial (600 MHz) |
| `register-expanded` | ICS55/ECOS preview | Full-design 400 MHz P&R attempt | Floorplan through legalization complete; detailed route stopped after 1,058/4,761 boxes because violations grew and resource protection prevented an OOM event; no routed handoff or STA | not completed |
| `sram-macro` | Nangate45/OpenRAM/OpenROAD/OpenRCX | Two `64x128 1RW1R` macros; 333 MHz P&R, same-run SPEF and internal PT timing | Route DRC/antenna are 0/0; PT setup/hold WNS +0.57/+0.04 ns with zero constraint violations | Chip-level implementation verified; overall profile partial because the analytical SRAM model and macro DRC/LVS/PEX are not closed |

The NanGate15 Liberty uses a `1ps` time unit, so its DC profile explicitly applies `SDC_TIME_SCALE=1000.0`. The latest 45 nm register-expanded physical run uses the setup-closed 700 MHz DC netlist at a 550 MHz implementation target. Evidence records matching SHA256 values for the handoff netlist, SDC, and SPEF. PrimeTime setup/hold coverage is 100%; 1,756 unconstrained max-delay endpoints are asynchronous reset pins under the internal-only profile.

The 333 MHz SRAM-macro result completed verified chip-level OpenROAD P&R, same-run OpenRCX SPEF, and PrimeTime internal setup/hold timing. Its route DRC and antenna net/pin counts are zero, and setup/hold WNS is +0.57/+0.04 ns. The overall SRAM profile remains `partial` because OpenRAM characterization is analytical, an exact reviewed waiver covers 256 unused `dout0[127:0]` minimum-capacitance endpoints on the two macros, and macro DRC/LVS/PEX is not closed. The waiver is profile-specific, exact-set matched, permits neither missing nor extra objects, and is neither a setup/hold waiver nor applicable to functional read data. This is the fixed verified closure point for the current macro profile, not a 400 MHz claim.

The ICS55 DC profile uses the H7CR RVT Liberty from ICsprout55 public-preview `v1.10.100`. Evidence records Liberty/DB hashes together with filelist, RTL manifest, SDC, mapped-netlist, and output-SDC identities. This proves only an ideal-clock internal reg-to-reg DC estimate; 498 top-level inputs have no clock-relative input delay and 672 top-level output endpoints have no max-delay constraint.

The ICS55/ECOS full-design attempt must not be confused with the DC-only profile. Its default detailed router did not complete and no routed DEF/GDS/netlist, same-run SPEF/SDF, or post-route timing exists. The documented stop is a resource-protection boundary, not a physical implementation or frequency claim.

## Interpretation

- A `DC timing estimate` covers internal timing under the selected Liberty, ideal clock, and synthesis constraints only;
- `internal reg-to-reg post-route timing` uses a routed netlist, matching SDC, and same-run SPEF, but does not cover unmodelled system IO;
- Neither `top-level IO timing closure` nor `foundry signoff` is claimed.

Public evidence is under `evidence/`, with run conditions and boundaries under `provenance/`. PDKs, Liberty/DB, LEF/GDS, SPEF, and raw EDA work directories are not distributed.
