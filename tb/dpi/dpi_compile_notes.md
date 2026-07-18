# DPI-C Compile Notes

DPI-C is SystemVerilog's external language interface. It is suitable for online scoreboards and random simulation tests, but it is not synthesizable.

Use a SystemVerilog testbench, not a pure Verilog testbench, when importing DPI-C functions. The package `tb/dpi/mrtc_dpi_pkg.sv` declares block-level imports for RDTC encode/decode.

Expected VCS-style flow:

```sh
bash scripts/vcs_run_dpi_smoke.sh
```

Questa fallback flow:

```sh
bash scripts/questa_run_dpi_smoke.sh
```

The DPI wrapper has already been adapted to `svOpenArrayHandle`, so the SystemVerilog package API stays stable across simulators while `mrtc_dpi.c` handles open-array access in C.

Validation note for the current revision:

- IC_EDA `gcc/make` + MATLAB/C cross-check passed.
- IC_EDA Questa DPI smoke passed.
- The same host's old VCS wrapper/link path is not reliable enough to claim a full pass, so the VCS script remains best-effort rather than the only recorded simulator status.
