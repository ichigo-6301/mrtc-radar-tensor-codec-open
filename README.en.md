# MRTC RDTC

[中文](README.md)

MRTC RDTC is a streaming lossless-compression digital IP for Range-Doppler tensors in OFDM sensing and mmWave radar pipelines.

## Current Public Release

The current public release is **RDTC v1 lossless codec IP**. RDTC is placed between radar-sensing data producers and storage, transport, or downstream processing stages. It provides streaming compression and decompression with bit-exact recoverability for the currently supported modes.

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

| Profile | Prefix Buffer | Public Technology Scope | Current Status |
|---|---|---|---|
| `register-expanded` | Standard-cell registers; zero SRAM macros | 15 nm DC; 45 nm DC + OpenROAD/OpenRCX + PrimeTime | 15 nm 800 MHz DC internal timing passes; 45 nm uses a 700 MHz closed DC netlist and completes route plus internal reg-to-reg STA at 550 MHz |
| `sram-macro` | One `64x128 1RW1R` OpenRAM macro per engine; two total | 45 nm DC + OpenROAD/OpenRCX + PrimeTime | Route and internal reg-to-reg STA pass at 333 MHz; the overall profile remains `partial` |

The 55 nm register-expanded synthesis matrix remains private. Metrics are not published until license and publication authorization are confirmed, and no 15/55 nm post-route Fmax is claimed.

## System Position And Interfaces

RDTC consumes block-organized complex Range-Doppler samples and produces compressed AXI-Stream packets with block headers. The decoder reconstructs the corresponding sample stream. See [Interfaces](docs/en/interfaces.md) and [Bitstream Format](docs/en/bitstream_format.md).

## Verification Status

| Stage | Status | Current Result |
|---|---|---|
| C reference model and public vectors | verified | RAW/ZERO/DELTA tests pass |
| RTL elaboration and Questa regression | verified | Icarus PASS; public full regression PASS |
| SpyGlass Lint | partial | 0 fatal, 0 error, 225 warnings |
| Register-expanded 15/45 nm DC | verified | 400/600/700/800 MHz matrix recorded; the 45 nm 700 MHz point closes and 800 MHz does not |
| Register-expanded 45 nm P&R/PT | verified | 550 MHz; zero route DRC/antenna violations; setup/hold WNS +0.26/+0.04 ns |
| SRAM-macro 45 nm P&R/PT | partial | 333 MHz; setup/hold WNS +0.57/+0.04 ns; analytical-SRAM and min-cap-waiver caveats retained |

Verified results, conditions, and nonclaims are listed in [Results](docs/en/results.md) and [Limitations](docs/en/limitations.md). These are academic implementation results, not complete top-level IO timing closure or foundry signoff.

## Quick Start

Open-source preflight:

```bash
make rdtc_v1_45nm_defconfig
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
- [Roadmap](docs/en/roadmap.md)
