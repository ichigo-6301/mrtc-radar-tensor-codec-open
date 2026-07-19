# MRTC RDTC

[中文](README.md)

MRTC RDTC is a streaming lossless-compression digital IP for Range-Doppler tensors in OFDM sensing and mmWave radar pipelines.

## Current Public Release

The current public release is **RDTC v1 lossless codec IP `register550-rc2`**. This release hardens structure and reproducibility without changing RTL, reference behavior, bitstream, interfaces, register map, or published implementation metrics.

## Features

- RAW_BYPASS, ZERO_RICE, and DELTA_RICE encoding modes;
- Corresponding streaming decoder path;
- AXI-Stream data interfaces with backpressure support;
- AXI4-Lite configuration and status interface;
- Malformed-stream error detection;
- C/DPI-C bit-exact reference model;
- File-vector, loopback, and negative-test environments.

## Implementation Profiles

Both profiles preserve the same external RTL interfaces, AXI behavior, register map, and bitstream format. Only the physical implementation of the prefix buffer changes.

| Profile ID | Maturity | Scope | Current Result |
|---|---|---|---|
| `rdtc_v1_register_nangate45_550` | verified | Register-expanded Nangate45 | 700 MHz DC-closed netlist; 550 MHz OpenROAD/OpenRCX/PT internal reg-to-reg closure |
| `rdtc_v1_sram_nangate45_333` | partial | 2 x `64x128 1RW1R` SRAM macros | 333 MHz internal reg-to-reg result; analytical-SRAM and waiver caveats retained |
| `rdtc_v1_register_ics55_rvt_dc` | verified | Register-expanded ICS55 RVT | 400/800 MHz DC points are constraint-clean; highest setup-closed point is 800 MHz; DC-only |
| `rdtc_v1_register_ics55_ecos_preview` | planned | ICS55/ECOS preview | No public result, evidence, or implementation claim yet |

The 55 nm comparison uses the Apache-2.0 ICsprout55 `v1.10.100` public-preview PDK and publishes only register-expanded DC evidence. PDK payloads and raw commercial reports are not distributed, and no 15/55 nm post-route Fmax is claimed.

## System Position And Interfaces

RDTC consumes block-organized complex Range-Doppler samples and produces compressed AXI-Stream packets with block headers. The decoder reconstructs the corresponding sample stream. See [Interfaces](docs/en/interfaces.md) and [Bitstream Format](docs/en/bitstream_format.md).

## Verification Status

| Stage | Status | Current Result |
|---|---|---|
| C reference model and public vectors | verified | RAW/ZERO/DELTA tests pass |
| RTL elaboration and Questa regression | verified | Icarus PASS; public full regression PASS |
| SpyGlass Lint | partial | 0 fatal, 0 error, 225 warnings |
| Register-expanded 15/45/55 nm DC | verified | ICS55 RVT 400/800 MHz points are constraint-clean and 800 MHz is the highest setup-closed point; 600 MHz retains 2/3 transition/capacitance violations |
| Register-expanded 45 nm P&R/PT | verified | 550 MHz; zero route DRC/antenna violations; setup/hold WNS +0.26/+0.04 ns |
| SRAM-macro 45 nm P&R/PT | partial | 333 MHz; setup/hold WNS +0.57/+0.04 ns; analytical-SRAM and min-cap-waiver caveats retained |

Verified results, conditions, and nonclaims are listed in [Results](docs/en/results.md) and [Limitations](docs/en/limitations.md). These are academic implementation results, not complete top-level IO timing closure or foundry signoff.

## Quick Start

Open-source preflight:

```bash
make rdtc_v1_public_preflight_defconfig
make showconfig
make -C ref_model/c test
make rtl-smoke
```

Questa/ModelSim regression:

```bash
make sim
make sim-full
```

Select a profile with `make rdtc_v1_register_45nm_dc700_pnr550_cap60_defconfig` or `make rdtc_v1_45nm_dc900mapped_pnr333_spice_guardband_eco1_defconfig`. Commercial-tool, PDK, library, and macro paths belong only in ignored `flows/local/`. See [Verification](docs/en/verification.md) and [Implementation Flow](flows/README.md) for the complete contracts.

## Documentation

- [Architecture](docs/en/architecture.md)
- [Algorithm](docs/en/algorithm.md)
- [Verification](docs/en/verification.md)
- [FPGA Implementation](docs/en/fpga_implementation.md)
- [ASIC Implementation](docs/en/asic_implementation.md)
- [Implementation Flow](flows/README.md)
- [Release Model](docs/en/release_model.md)
- [Roadmap](docs/en/roadmap.md)
